const { networkConfig, developmentChains } = require("../helper-hardhat-config")
const { network, ethers } = require("hardhat")
const { verify } = require("../utils/verify")

module.exports = async ({ getNamedAccounts, deployments }) => {
    const { deploy, log } = deployments
    const [owner] = await ethers.getSigners()
    const chainId = network.config.chainId

    //set price feed addresses correctly depending on network
    let WETH_USD_PriceFeedaddress, WBTC_USD_PriceFeedAddress, LINK_USD_PriceFeedAddress, fWBTC_USD_PriceFeedAddress
    let contractAddress_WBTC, contractAddress_WETH, contractAddress_LINK, contractAddress_fWBTC

    let existingCommodities = networkConfig[chainId]["existingCommodities"]
    let newCommodities = networkConfig[chainId]["newCommodities"]
    let commodityPriceFeedAddresses = []

    if (developmentChains.includes(network.name)) {
        const BTC_USDAggregator = await deployments.get("MockV3AggregatorWBTC")
        WBTC_USD_PriceFeedAddress = BTC_USDAggregator.address
        fWBTC_USD_PriceFeedAddress = BTC_USDAggregator.address

        const ETH_USDAggregator = await deployments.get("MockV3AggregatorWETH")
        WETH_USD_PriceFeedaddress = ETH_USDAggregator.address

        const LINK_USDAggregator = await deployments.get("MockV3AggregatorLINK")
        LINK_USD_PriceFeedAddress = LINK_USDAggregator.address

        for (let i = 0; i < existingCommodities.length; i++) {
            let commodityName = existingCommodities[i]
            const COMMODITY_USD_AGGREGATOR = await deployments.get("MockV3Aggregator" + commodityName)
            commodityPriceFeedAddresses.push(COMMODITY_USD_AGGREGATOR.address)
        }

        contractAddress_WBTC = (await deployments.get("MockWBTC")).address
        contractAddress_WETH = (await deployments.get("MockWETH")).address
        contractAddress_LINK = (await deployments.get("MockLINK")).address
        contractAddress_fWBTC = (await deployments.get("MockfWBTC")).address
    } else {
        WBTC_USD_PriceFeedAddress = networkConfig[chainId]["pricefeeds"]["WBTC"]
        WETH_USD_PriceFeedaddress = networkConfig[chainId]["pricefeeds"]["WETH"]
        LINK_USD_PriceFeedAddress = networkConfig[chainId]["pricefeeds"]["LINK"]
        fWBTC_USD_PriceFeedAddress = networkConfig[chainId]["pricefeeds"]["fWBTC"]

        for (let i = 0; i < existingCommodities.length; i++) {
            let commodityName = existingCommodities[i]
            commodityPriceFeedAddresses.push(networkConfig[chainId]["pricefeeds"][commodityName])
        }

        contractAddress_WBTC = networkConfig[chainId]["tokenContracts"]["WBTC"]
        contractAddress_WETH = networkConfig[chainId]["tokenContracts"]["WETH"]
        contractAddress_LINK = networkConfig[chainId]["tokenContracts"]["LINK"]
        contractAddress_fWBTC = networkConfig[chainId]["tokenContracts"]["fWBTC"]
    }

    for (let i = 0; i < newCommodities.length; i++) {
        let commodityName = newCommodities[i]
        const COMMODITY_USD_AGGREGATOR = await deployments.get(commodityName + "_priceFeed")
        commodityPriceFeedAddresses.push(COMMODITY_USD_AGGREGATOR.address)
    }
    let commodities = existingCommodities.concat(newCommodities)

    const transactionCount = await owner.getTransactionCount()
    const vaultAddress = ethers.utils.getContractAddress({
        from: owner.address,
        nonce: transactionCount + commodities.length,
    })
    let commodityTokens = []
    let commodityArgs = []
    let commodityTokenAddresses = []

    //deploy commodities
    for (let i = 0; i < commodities.length; i++) {
        const args = [commodities[i], commodities[i], vaultAddress]
        const commodityToken = await deploy(commodities[i] + "_token", {
            contract: "CAT",
            from: owner.address,
            args: args,
            log: true,
        })
        commodityArgs.push(args)
        commodityTokens.push(commodityToken)
        commodityTokenAddresses.push(commodityToken.address)
        //console.log(`Deployed ${commodities[i]} token`)
    }

    //deploy vault
    const args = [
        commodities,
        commodityTokenAddresses,
        commodityPriceFeedAddresses,
        [contractAddress_WETH, contractAddress_WBTC, contractAddress_LINK, contractAddress_fWBTC],
        [WETH_USD_PriceFeedaddress, WBTC_USD_PriceFeedAddress, LINK_USD_PriceFeedAddress, fWBTC_USD_PriceFeedAddress],
        6666666667,
    ]
    const vault = await deploy("vault", {
        contract: "Vault",
        from: owner.address,
        args: args,
        log: true,
    })
    //console.log(`Deployed vault`)

    //verify
    if (!developmentChains.includes(network.name) && process.env.ETHERSCAN_API_KEY) {
        for (let i = 0; i < commodities.length; i++) {
            await verify(commodityTokens[i].address, commodityArgs[i])
        }
        await verify(vault.address, args)
    }

    log("-------------------------------")
}

module.exports.tags = ["all", "vault"]
