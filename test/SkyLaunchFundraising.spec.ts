import chai, { expect } from 'chai'
import { Contract, BigNumber, constants, Wallet, utils } from 'ethers'
import { solidity, MockProvider, createFixtureLoader, deployContract } from 'ethereum-waffle'
import { ecsign } from 'ethereumjs-util'

import { fundRaisingFixture } from './fixtures'
import { REWARDS_DURATION, SIX_MONTHS, expandTo18Decimals, mineBlock, getApprovalDigest } from './utils'

import StakingRewards from '../build/SkyLaunchFundRaising.json'
import kycMerkleRoot from './kycMerkleRoot.json';

chai.use(solidity)

const MINIMUM_LIQUIDITY = BigNumber.from("10").pow(3);

describe('SkyLaunchFundraising', () => {
    const AddressZero = "0x0000000000000000000000000000000000000000"
    const provider = new MockProvider({
        ganacheOptions: {
            hardfork: 'istanbul',
            mnemonic: 'horn horn horn horn horn horn horn horn horn horn horn horn',
            gasLimit: 9999999,
        },
    })
    const [wallet, nonOwner, secondStaker] = provider.getWallets()
    const thirdStaker = provider.getWallets()[3];
    const loadFixture = createFixtureLoader([wallet, secondStaker], provider)
    const overrides = {
        gasLimit: 9999999
    }

    let stakingRewards: Contract
    let rewardsToken: Contract
    let stakingToken: Contract
    let nonWithdrawalBoost: BigNumber
    let nonWithdrawalBoostPeriod: number
    let minimumLockDays: number
    let fundRaising: Contract
    let fundRaisingToken: Contract
    let testNFT: Contract
    beforeEach(async () => {
        const fixture = await loadFixture(fundRaisingFixture)
        fundRaising = fixture.fundRaising
        stakingRewards = fixture.stakingRewards
        rewardsToken = fixture.rewardsToken
        stakingToken = fixture.stakingToken
        testNFT = fixture.testNFT
        fundRaisingToken = fixture.fundRaisingToken
        nonWithdrawalBoost = fixture.nonWithdrawalBoost
        nonWithdrawalBoostPeriod = fixture.nonWithdrawalBoostPeriod
        minimumLockDays = fixture.minimumLockDays

        await fundRaising.setKYCMerkleRoot(kycMerkleRoot.merkleRoot);
        await fundRaising.addStakingRewards(stakingRewards.address);
    })

    it('deploy cost', async () => {
    })

    it('Only owner can create a new IDO pool', async () => {
        await expect(fundRaising.connect(nonOwner).add(rewardsToken.address, fundRaisingToken.address, 0, 1000, 2000, expandTo18Decimals(100000), utils.parseEther("0.01"), expandTo18Decimals(500), expandTo18Decimals(10000)))
            .to.revertedWith("Ownable: caller is not the owner");
        await fundRaising.connect(wallet).add(rewardsToken.address, fundRaisingToken.address, 0, 1000, 2000, expandTo18Decimals(100000), utils.parseEther("0.01"), expandTo18Decimals(500), expandTo18Decimals(10000))
    })

    it('Only valid user can subscribe to upcoming IDO after start time', async () => {
        const startTime: number = Math.floor(Date.now() / 1000);
        const subEndTime: number = startTime + 1000;
        const fundEndTime: number = subEndTime + 1000;
        mineBlock(provider, startTime - 100);
        await fundRaising.connect(wallet).add(rewardsToken.address, fundRaisingToken.address, startTime, subEndTime, fundEndTime, expandTo18Decimals(100000), utils.parseEther("0.01"), expandTo18Decimals(500), expandTo18Decimals(10000))
        
        //@ts-ignore
        const claim = kycMerkleRoot.kycRecords[secondStaker.address];

        await expect(fundRaising.connect(nonOwner).subscribe(0,0, [] ))
            .to.revertedWith("subscribe: subscription not started");

        mineBlock(provider, startTime + 1);

        await expect(fundRaising.connect(nonOwner).subscribe(0, claim.index, claim.proof))
            .to.revertedWith('subscribe: Invalid proof.');

        await fundRaising.connect(secondStaker).subscribe(0, claim.index, claim.proof);
    })

    it('Only subscribed users can fund IDO up to their allocation', async () => {
        const startTime: number = Math.floor(Date.now() / 1000);
        const subEndTime: number = startTime + 1000;
        const fundEndTime: number = subEndTime + 1000;
        mineBlock(provider, startTime - 100);
        await fundRaising.connect(wallet).add(rewardsToken.address, fundRaisingToken.address, startTime, subEndTime, fundEndTime, expandTo18Decimals(100000), utils.parseEther("0.01"), expandTo18Decimals(500), expandTo18Decimals(10000))
                
        //@ts-ignore
        const claim = kycMerkleRoot.kycRecords[secondStaker.address];

        mineBlock(provider, startTime + 1);

        await fundRaising.connect(secondStaker).subscribe(0, claim.index, claim.proof);

        mineBlock(provider, subEndTime + 1);

        await expect(fundRaising.connect(nonOwner).fundSubscription(0, 100))
            .to.revertedWith('fundSubscription: not subscribed');

        const allocation = await fundRaising.connect(secondStaker).getMaximumAllocation(0);
        
        await fundRaisingToken.transfer(secondStaker.address, allocation+10);
        await fundRaisingToken.connect(secondStaker).approve(fundRaising.address, allocation+10);
        await expect(fundRaising.connect(secondStaker).fundSubscription(0, allocation.add(10)))
            .to.revertedWith('fundSubscription: Too many tokens provided');

        await fundRaising.connect(secondStaker).fundSubscription(0, allocation);
    })

    it('Only subscribed users can fund IDO up to their allocation with Utility NFT', async () => {
        const startTime: number = Math.floor(Date.now() / 1000);
        const subEndTime: number = startTime + 1000;
        const fundEndTime: number = subEndTime + 1000;
        const guaranteedAllocation = expandTo18Decimals(1000);
        mineBlock(provider, startTime - 100);
        await fundRaising.connect(wallet).add(rewardsToken.address, fundRaisingToken.address, startTime, subEndTime, fundEndTime, expandTo18Decimals(100000), utils.parseEther("0.01"), expandTo18Decimals(500), expandTo18Decimals(10000))

        // mint utility NFT
        await testNFT.connect(wallet).mint(secondStaker.address, guaranteedAllocation)
                
        //@ts-ignore
        const claim = kycMerkleRoot.kycRecords[secondStaker.address];

        mineBlock(provider, startTime + 1);

        await fundRaising.connect(secondStaker).subscribeWithUtilityNFT(0, 0, claim.index, claim.proof);

        mineBlock(provider, subEndTime + 1);

        await expect(fundRaising.connect(nonOwner).fundSubscription(0, 100))
            .to.revertedWith('fundSubscription: not subscribed');

        const allocation = await fundRaising.connect(secondStaker).getMaximumAllocation(0);

        expect(allocation == guaranteedAllocation, "Allocations not matching");
        
        await fundRaisingToken.transfer(secondStaker.address, allocation+10);
        await fundRaisingToken.connect(secondStaker).approve(fundRaising.address, allocation+10);
        await expect(fundRaising.connect(secondStaker).fundSubscription(0, allocation.add(10)))
            .to.revertedWith('fundSubscription: Too many tokens provided');

        await fundRaising.connect(secondStaker).fundSubscription(0, allocation.div(2));

        expect(await testNFT.getAvailableAllocation(0) == guaranteedAllocation.div(2));
    })

    it('Vesting rewards can be setup only by owner and claimed by the users', async () => {
        const startTime: number = Math.floor(Date.now() / 1000);
        const subEndTime: number = startTime + 1000;
        const fundEndTime: number = subEndTime + 1000;
        const rewardStartTime: number = fundEndTime + 1000;
        const rewardCliffEndTime: number = rewardStartTime + 1000;
        const rewardEndTime: number = rewardCliffEndTime + 1000;

        mineBlock(provider, startTime - 100);

        await fundRaising.connect(wallet).add(rewardsToken.address, fundRaisingToken.address, startTime, subEndTime, fundEndTime, expandTo18Decimals(100000), utils.parseEther("0.01"), expandTo18Decimals(500), expandTo18Decimals(10000))

        //@ts-ignore
        const claim = kycMerkleRoot.kycRecords[secondStaker.address];

        mineBlock(provider, startTime + 1);

        await fundRaising.connect(secondStaker).subscribe(0, claim.index, claim.proof);

        mineBlock(provider, subEndTime + 1);

        const allocation = await  fundRaising.connect(secondStaker).getMaximumAllocation(0);
        
        await fundRaisingToken.transfer(secondStaker.address, allocation);
        await fundRaisingToken.connect(secondStaker).approve(fundRaising.address, allocation);
        await fundRaising.connect(secondStaker).fundSubscription(0, allocation);

        const rewardAmount = await fundRaising.getRequiredRewardAmountForAmountRaised(0);
        await rewardsToken.connect(wallet).approve(fundRaising.address, rewardAmount);

        await expect(fundRaising.connect(wallet).setupVestingRewards(0, rewardAmount, rewardStartTime, rewardCliffEndTime, rewardEndTime)).to.be.revertedWith("setupVestingRewards: Users are still funding");

        mineBlock(provider, fundEndTime + 1);

        await expect(fundRaising.connect(wallet).setupVestingRewards(0, 1000, rewardStartTime, rewardCliffEndTime, rewardEndTime)).to.be.revertedWith("setupVestingRewards: wrong reward amount provided");
        await expect(fundRaising.connect(nonOwner).setupVestingRewards(0, rewardAmount, rewardStartTime, rewardCliffEndTime, rewardEndTime)).to.be.revertedWith("Ownable: caller is not the owner");

        await fundRaising.connect(wallet).setupVestingRewards(0, rewardAmount, rewardStartTime, rewardCliffEndTime, rewardEndTime);

        await expect(fundRaising.connect(secondStaker).claimReward(0)).to.be.revertedWith("claimReward: Not past cliff");

        mineBlock(provider, rewardCliffEndTime + 1);
        await expect(fundRaising.connect(nonOwner).claimReward(0)).to.be.revertedWith("claimReward: Not funded"); 
        
        expect(await fundRaising.connect(secondStaker).claimReward(0)).to.emit(fundRaising, "RewardClaimed")

    })

    it('Fundraising can be claimed by the owner only', async () => {
        const startTime: number = Math.floor(Date.now() / 1000);
        const subEndTime: number = startTime + 1000;
        const fundEndTime: number = subEndTime + 1000;
        const rewardStartTime: number = fundEndTime + 1000;
        const rewardCliffEndTime: number = rewardStartTime + 1000;
        const rewardEndTime: number = rewardCliffEndTime + 1000;

        mineBlock(provider, startTime - 100);

        await fundRaising.connect(wallet).add(rewardsToken.address, fundRaisingToken.address, startTime, subEndTime, fundEndTime, expandTo18Decimals(100000), utils.parseEther("0.01"), expandTo18Decimals(500), expandTo18Decimals(10000))

        //@ts-ignore
        const claim = kycMerkleRoot.kycRecords[secondStaker.address];

        mineBlock(provider, startTime + 1);

        await fundRaising.connect(secondStaker).subscribe(0, claim.index, claim.proof);

        mineBlock(provider, subEndTime + 1);

        const allocation = await  fundRaising.connect(secondStaker).getMaximumAllocation(0);
        
        await fundRaisingToken.transfer(secondStaker.address, allocation);
        await fundRaisingToken.connect(secondStaker).approve(fundRaising.address, allocation);
        await fundRaising.connect(secondStaker).fundSubscription(0, allocation);

        const rewardAmount = await fundRaising.getRequiredRewardAmountForAmountRaised(0);
        await rewardsToken.connect(wallet).approve(fundRaising.address, rewardAmount);

        await expect(fundRaising.connect(wallet).setupVestingRewards(0, rewardAmount, rewardStartTime, rewardCliffEndTime, rewardEndTime)).to.be.revertedWith("setupVestingRewards: Users are still funding");

        mineBlock(provider, fundEndTime + 1);

        await expect(fundRaising.connect(wallet).setupVestingRewards(0, 1000, rewardStartTime, rewardCliffEndTime, rewardEndTime)).to.be.revertedWith("setupVestingRewards: wrong reward amount provided");
        await expect(fundRaising.connect(nonOwner).setupVestingRewards(0, rewardAmount, rewardStartTime, rewardCliffEndTime, rewardEndTime)).to.be.revertedWith("Ownable: caller is not the owner");

        await fundRaising.connect(wallet).setupVestingRewards(0, rewardAmount, rewardStartTime, rewardCliffEndTime, rewardEndTime);

        const totalRaised = await fundRaising.poolIdToTotalRaised(0);
        expect(await fundRaising.claimFundRaising(0)).to.emit(fundRaising, "FundRaisingClaimed").withArgs(0, wallet.address, totalRaised);
    })    
})