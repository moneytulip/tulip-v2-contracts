const hre = require("hardhat");

async function main() {
  const Tulip = await hre.ethers.getContractFactory("Tulip");
  const tulip = await Tulip.deploy(

  )
 
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
