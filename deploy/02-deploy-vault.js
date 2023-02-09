const { networkConfig, developmentChains } = require("../helper-hardhat-config")
const { network, ethers } = require("hardhat")
const { verify } = require("../utils/verify")

module.exports = async ({ getNamedAccounts, deployments }) => {
    const { deploy, log } = deployments
    const [owner] = await ethers.getSigners()
    let chainId = network.config.chainId

    //set price feed addresses correctly depending on network

    let existingCommodities = networkConfig[chainId]["existingCommodities"]
    let newCommodities = networkConfig[chainId]["newCommodities"]
    let commodityPriceFeedAddresses = []

    let collateralContracts, priceFeedsCollaterals

    if (developmentChains.includes(network.name)) {
        collateralContracts = [
            (await deployments.get("MockWBTC")).address,
            (await deployments.get("MockWETH")).address,
            (await deployments.get("MockLINK")).address,
            (await deployments.get("MockfWBTC")).address,
        ]
        const BTC_USDAggregator = await deployments.get("MockV3AggregatorWBTC")
        const ETH_USDAggregator = await deployments.get("MockV3AggregatorWETH")
        const LINK_USDAggregator = await deployments.get("MockV3AggregatorLINK")

        priceFeedsCollaterals = [
            BTC_USDAggregator.address,
            ETH_USDAggregator.address,
            LINK_USDAggregator.address,
            BTC_USDAggregator.address,
        ]

        for (let i = 0; i < existingCommodities.length; i++) {
            let commodityName = existingCommodities[i]
            const COMMODITY_USD_AGGREGATOR = await deployments.get("MockV3Aggregator" + commodityName)
            commodityPriceFeedAddresses.push(COMMODITY_USD_AGGREGATOR.address)
        }
    } else {
        for (let i = 0; i < existingCommodities.length; i++) {
            let commodityName = existingCommodities[i]
            commodityPriceFeedAddresses.push(networkConfig[chainId]["pricefeeds"][commodityName])
        }

        const collateralTokens = networkConfig[chainId]["collateralTokens"]
        collateralContracts = []
        priceFeedsCollaterals = []
        for (let i = 0; i < collateralTokens.length; i++) {
            const token = collateralTokens[i]
            collateralContracts.push(networkConfig[chainId]["tokenContracts"][token])
            priceFeedsCollaterals.push(networkConfig[chainId]["pricefeeds"][token])
        }
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
        collateralContracts,
        priceFeedsCollaterals,
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
