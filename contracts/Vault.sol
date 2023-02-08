// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

//// @title A commodity vault contract
//// @author Reginald Dewil
//// @notice deposit collateral and mint/borrow commodity tokens valued according to separate price feed contracts
//// @dev based on sample stablecoin contract found here https://github.com/smartcontractkit/defi-minimal/blob/main/contracts/stablecoins/exogenousAnchoredCoin/DSCEngine.sol
////        modified to allow multiple collateral types and multiple price feeds - token to mint also has a price and is not assumed to be worth 1 USD as in stablecoin case

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./CAT.sol";
import "hardhat/console.sol";

error Vault__NeedsMoreThanZero();
error Vault__TokenNotAllowed();
error Vault__TransferFailed();
error Vault__BreaksHealthFactor();
error Vault__MintFailed();
error Vault__HealthFactorOk();
error Vault__SeizingTooMuchCollateral();

contract Vault is ReentrancyGuard, Ownable {
    struct Commodity {
        string name;
        uint id;
        CAT token;
        bool isCommodity;
    }
    Commodity[] public s_commodities;
    mapping(address => Commodity) public s_commoditiesByAddress;

    uint256 public immutable i_collateral_weight; //8 decimals depending on historic asset volatility, more or less collateral is required to secure a position. 67% weight implies together with minimum health-level that 150% collateral is required for a given mint position
    uint256 public constant MIN_HEALTH_FACTOR = 1e18; //
    uint256 public constant LIQUIDATION_DISCOUNT = 10; //10% discount when liquidating

    mapping(address => mapping(address => uint256)) public s_userToCollateralAddressToAmountDeposited;
    mapping(address => mapping(address => uint256)) public s_userToCATaddressToAmountMinted;

    address[] public s_collateralTokens;
    mapping(address => bool) public isCollateral;

    mapping(address => address) public s_priceFeeds;

    event CollateralDeposited(address indexed user, uint256 indexed amount);

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert Vault__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address tokenAddress) {
        if (!isCollateral[tokenAddress]) {
            revert Vault__TokenNotAllowed();
        }
        _;
    }

    constructor(
        string[] memory commodityNames,
        address[] memory commodityTokenAddresses,
        address[] memory priceFeedsCommodities,
        address[] memory allowedCollateralAddresses,
        address[] memory priceFeedsCollateral,
        uint256 collateral_weight
    ) {
        for (uint256 i = 0; i < commodityNames.length; i++) {
            s_commodities.push(Commodity(commodityNames[i], i, CAT(commodityTokenAddresses[i]), true));
            s_priceFeeds[commodityTokenAddresses[i]] = priceFeedsCommodities[i];
            s_commoditiesByAddress[commodityTokenAddresses[i]] = s_commodities[i];
        }
        for (uint256 i = 0; i < allowedCollateralAddresses.length; i++) {
            s_priceFeeds[allowedCollateralAddresses[i]] = priceFeedsCollateral[i];
            isCollateral[allowedCollateralAddresses[i]] = true;
            s_collateralTokens.push(allowedCollateralAddresses[i]);
        }
        i_collateral_weight = collateral_weight;
    }

    function addCollateralAndMintCAT(
        address collateralAddress,
        uint256 amountOfCollateral,
        address commodityTokenAddress,
        uint256 amountToMint
    ) external {
        addCollateral(collateralAddress, amountOfCollateral);
        mintCAT(commodityTokenAddress, amountToMint);
    }

    function addCollateral(
        address tokenCollateralAddress,
        uint256 amountOfCollateral
    ) public moreThanZero(amountOfCollateral) nonReentrant isAllowedToken(tokenCollateralAddress) {
        s_userToCollateralAddressToAmountDeposited[msg.sender][tokenCollateralAddress] += amountOfCollateral;
        emit CollateralDeposited(msg.sender, amountOfCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountOfCollateral);
        if (!success) {
            revert Vault__TransferFailed();
        }
    }

    function withdrawCollateral(
        address tokenCollateralAddress,
        uint256 amountOfCollateral
    ) public moreThanZero(amountOfCollateral) nonReentrant {
        _withdrawCollateral(tokenCollateralAddress, amountOfCollateral, msg.sender, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender);
    }

    function repayCATAndWithdrawCollateral(
        address tokenCollateralAddress,
        uint256 amountOfCollateral,
        address commodityTokenAddress,
        uint256 amountOfCATToBurn
    ) external {
        repayCAT(commodityTokenAddress, amountOfCATToBurn);
        withdrawCollateral(tokenCollateralAddress, amountOfCollateral);
    }

    function _withdrawCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        address from,
        address to /*private*/
    ) private {
        s_userToCollateralAddressToAmountDeposited[from][tokenCollateralAddress] -= amountCollateral;
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert Vault__TransferFailed();
        }
    }

    function repayCAT(
        address commodityTokenAddress,
        uint256 amountOfCATToBurn
    ) public moreThanZero(amountOfCATToBurn) nonReentrant {
        _repayCAT(commodityTokenAddress, amountOfCATToBurn, msg.sender, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender);
    }

    function _repayCAT(
        address commodityTokenAddress,
        uint256 amountOfCATToBurn,
        address onBehalfOf,
        address catFrom /*private*/
    ) private {
        uint256 actualAmountToBurn = amountOfCATToBurn >
            s_userToCATaddressToAmountMinted[onBehalfOf][commodityTokenAddress]
            ? s_userToCATaddressToAmountMinted[onBehalfOf][commodityTokenAddress]
            : amountOfCATToBurn;
        s_userToCATaddressToAmountMinted[onBehalfOf][commodityTokenAddress] -= actualAmountToBurn;
        CAT token = s_commoditiesByAddress[commodityTokenAddress].token;
        bool success = token.transferFrom(catFrom, address(this), actualAmountToBurn);
        if (!success) {
            revert Vault__TransferFailed();
        }
        token.burn(actualAmountToBurn);
    }

    function mintCAT(
        address commodityAddress,
        uint256 amountOfCATToMint
    ) public moreThanZero(amountOfCATToMint) nonReentrant {
        s_userToCATaddressToAmountMinted[msg.sender][commodityAddress] += amountOfCATToMint;
        revertIfHealthFactorIsBroken(msg.sender);
        bool minted = s_commoditiesByAddress[commodityAddress].token.mint(msg.sender, amountOfCATToMint);
        if (minted != true) {
            revert Vault__MintFailed();
        }
    }

    function getAccountInformation(
        address user
    ) public view returns (uint256 totalCATValueMintedInUsd, uint256 collateralValueInUsd) {
        totalCATValueMintedInUsd = getUsdValueMintedTokensForUser(user);
        collateralValueInUsd = getCollateralAmountUsdForUser(user);
    }

    function calculateHealthFactor(address user) public view returns (uint256) {
        (uint256 totalCATValueMintedInUsd, uint256 collateralValueInUsd) = getAccountInformation(user);
        if (totalCATValueMintedInUsd == 0) return 100e18;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * i_collateral_weight) / 10000000000;
        return (collateralAdjustedForThreshold * 1e18) / totalCATValueMintedInUsd;
    }

    function getUsdValueMintedTokensForUser(address user) public view returns (uint256 totalMintedValueInUsd) {
        for (uint i = 0; i < s_commodities.length; i++) {
            totalMintedValueInUsd += getUsdValue(
                address(s_commodities[i].token),
                s_userToCATaddressToAmountMinted[user][address(s_commodities[i].token)]
            );
        }
        return totalMintedValueInUsd;
    }

    function getCollateralAmountUsdForUser(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 index = 0; index < s_collateralTokens.length; index++) {
            address token = s_collateralTokens[index];
            uint256 amount = s_userToCollateralAddressToAmountDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getPrice(address tokenAddress) public view returns (int256 price, uint8 decimals) {
        (, price, , , ) = AggregatorV3Interface(s_priceFeeds[tokenAddress]).latestRoundData();
        decimals = AggregatorV3Interface(s_priceFeeds[tokenAddress]).decimals();
    }

    function getUsdValue(address tokenAddress, uint256 amount) public view returns (uint256) {
        (int256 price, uint8 decimals) = getPrice(tokenAddress);
        return ((uint256(price) * 10 ** (18 - decimals) * amount) / 1e18);
    }

    function getTokenAmountFromUsd(address tokenAddress, uint256 usdAmountInWei) public view returns (uint256) {
        (int256 price, uint8 decimals) = getPrice(tokenAddress);
        return (usdAmountInWei * 1e18) / (uint256(price) * 10 ** (18 - decimals)); //1 unit = 1e18 wei
    }

    function revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = calculateHealthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert Vault__BreaksHealthFactor();
        }
    }

    /*
        3rd party vigilante tracks positions. if health factor < min_health_factor, he/she can initiate liquidation
        liquidator chooses a single collateral type to seize
        //TODO: modify to restrict to partial liquidation, i.e. only liquidate enough to ensure health factor is < min_health_factor (+safety margin)
                current implementation allows for complete liquidation which is a bit excessive
    */
    function liquidate(
        address addressOfCollateralToBeSeized,
        address user,
        address commodityAddressToRepay,
        uint256 debtToCoverInNumberOfTokens
    ) external {
        uint256 startingUserHealthFactor = calculateHealthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert Vault__HealthFactorOk();
        }
        uint256 usdAmountOfDebtToCover = getUsdValue(commodityAddressToRepay, debtToCoverInNumberOfTokens);
        uint256 collateralAmountToSeize = getTokenAmountFromUsd(addressOfCollateralToBeSeized, usdAmountOfDebtToCover);
        uint256 bonusCollateral = (collateralAmountToSeize * LIQUIDATION_DISCOUNT) / 100;

        if (
            (collateralAmountToSeize + bonusCollateral) >
            s_userToCollateralAddressToAmountDeposited[user][addressOfCollateralToBeSeized]
        ) {
            revert Vault__SeizingTooMuchCollateral();
        }
        // Burn CAT equal to debtToCover
        // Figure out how much collateral to recover based on how much burnt
        _withdrawCollateral(addressOfCollateralToBeSeized, collateralAmountToSeize + bonusCollateral, user, msg.sender);
        _repayCAT(commodityAddressToRepay, debtToCoverInNumberOfTokens, user, msg.sender);

        uint256 endingUserHealthFactor = calculateHealthFactor(user);
        require(startingUserHealthFactor < endingUserHealthFactor);
    }

    function addNewCollateralType(address newCollateralAddress, address priceFeedAddress) public onlyOwner {
        s_collateralTokens.push(newCollateralAddress);
        isCollateral[newCollateralAddress] = true;
        s_priceFeeds[newCollateralAddress] = priceFeedAddress;
    }

    function updatePriceFeed(address oldAddress, address newAddress) public onlyOwner {
        s_priceFeeds[oldAddress] = newAddress;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralAmountOfTokenOfUser(address user, address tokenAddress) public view returns (uint256) {
        return s_userToCollateralAddressToAmountDeposited[user][tokenAddress];
    }

    function getAmountOfTokensMinted(address user, address commodityToken) public view returns (uint256) {
        return s_userToCATaddressToAmountMinted[user][commodityToken];
    }

    function getCommodities() public view returns (Commodity[] memory) {
        return s_commodities;
    }

    function getCommodity(address _address) public view returns (Commodity memory) {
        return s_commoditiesByAddress[_address];
    }

    function isValidCollateral(address _address) public view returns (bool) {
        return isCollateral[_address];
    }

    function getPriceFeed(address _tokenAddress) public view returns (address) {
        return s_priceFeeds[_tokenAddress];
    }
}
