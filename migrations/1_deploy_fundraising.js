const { ethers, BigNumber } = require("ethers"); 
const SkyLaunchFundRaising = artifacts.require("SkyLaunchFundRaising");
const testNFT = artifacts.require("TestNFT");
const testERC20 = artifacts.require("TestERC20");
const StakingRewards = artifacts.require("TestStakingRewards");
const TestStakingToken = artifacts.require("TestStakingToken");

function expandTo18Decimals(n) {
  return BigNumber.from(n).mul(BigNumber.from(10).pow(18))
}

function expandTo17Decimals(n) {
  return BigNumber.from(n).mul(BigNumber.from(10).pow(17))
}

module.exports = async function (deployer) {  
  const scores = [399, 299, 199, 99, 10]
  const multipliers = [300, 250, 200, 150, 100]
  const rewardsDistribution = "0x1CE9a65c6b32aB58ad748AC3E3dbE9c15E112182"
  const nonWithdrawalBoost = expandTo17Decimals(5);
  const nonWithdrawalBoostPeriod = 356;
  const minimumLockDays = 7;
  await deployer.deploy(testNFT).then(async (testNFT) => {
        await deployer.deploy(SkyLaunchFundRaising, scores, multipliers, testNFT.address);  
  });

  await deployer.deploy(testERC20, expandTo18Decimals(1000000));  
  const testToken = await testERC20.deployed();
  await deployer.deploy(TestStakingToken, expandTo18Decimals(1000000))  
  const stakingToken = await TestStakingToken.deployed()
  await deployer.deploy(StakingRewards, 
    rewardsDistribution,
    testToken.address,    
    stakingToken.address,
    nonWithdrawalBoost,
    nonWithdrawalBoostPeriod,
    minimumLockDays,
    true
  )
};
