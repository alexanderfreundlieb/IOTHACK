import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();

  //const oracleStorage = await ethers.getContractAt("OracleStorage", "0xe08A85857C6E24ABBF36651C9cDA9535820a5A2C");
  const p2pMarket = await ethers.getContractAt("P2PEnergyMarket", "0xAc0BC3c9d523CfEe5726C1863a98b3eDf8B927b9");

  //await oracleStorage.authorizeOracle("0xORACLE_WALLET_ADDR");
  const txt1 = await p2pMarket.registerHousehold("0xcA5028BEfC157773f7cd7D3047C18eEbD9009c3C");
  const receipt1 = await txt1.wait();
  console.log("registerHousehold tx:", receipt1?.hash, "status:", receipt1?.status);
}

main().catch(console.error);