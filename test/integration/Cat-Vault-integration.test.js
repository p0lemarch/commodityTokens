const { ethers } = require("hardhat")
const { assert, expect } = require("chai")
const { developmentChains } = require("../../helper-hardhat-config")
const { Contract } = require("ethers")

!developmentChains.includes(network.name)
    ? describe.skip
    : describe("Integration Vault-CAT", function () {
          let vault

          beforeEach(async () => {
              await deployments.fixture(["all"])
              vault = await ethers.getContract("vault")
          })

          describe("CAT contract creation", function () {
              it("owner of tokens is the vault", async () => {
                  const commodities = await vault.getCommodities()
                  for (let i = 0; i < commodities.length; i++) {
                      let commodityContract = await ethers.getContract(commodities[i].name + "_token")
                      assert(await commodityContract.totalSupply(), 0)
                  }
              })
          })
      })
