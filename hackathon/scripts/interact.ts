import { network } from "hardhat";

async function main() {
  const { ethers } = await network.connect();

  //const oracleStorage = await ethers.getContractAt("OracleStorage", "0xe08A85857C6E24ABBF36651C9cDA9535820a5A2C");
  const p2pMarket = await ethers.getContractAt("P2PEnergyMarket", "0xD2F1222cC2B72ECEfE1B8B633BbF85AaD4E74CDf");

  //await oracleStorage.authorizeOracle("0xORACLE_WALLET_ADDR");
  const txt1 = await p2pMarket.registerHousehold("0xcA5028BEfC157773f7cd7D3047C18eEbD9009c3C");
  const receipt1 = await txt1.wait();
  console.log("registerHousehold tx:", receipt1?.hash, "status:", receipt1?.status);
  const txt2 = await p2pMarket.registerHousehold("0x6FbB837b9aF78FE3152fC1a5cd31b3B684799415");
  const receipt2 = await txt2.wait();
  console.log("registerHousehold tx:", receipt2?.hash, "status:", receipt2?.status);
  const txt3 = await p2pMarket.registerHousehold("0x3973ccb4950F2c283Cd593288A1Bcff74dd3097F");
  const receipt3 = await txt3.wait();
  console.log("registerHousehold tx:", receipt3?.hash, "status:", receipt3?.status);
  const txt4 = await p2pMarket.registerHousehold("0xfc12C5a77C30692D4738E92371152E85fc028705");
  const receipt4 = await txt4.wait();
  console.log("registerHousehold tx:", receipt4?.hash, "status:", receipt4?.status);
}

main().catch(console.error);