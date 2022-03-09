// SPDX-License-Identifier: MIT

pragma solidity 0.6.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/cryptography/MerkleProof.sol";
import "./interfaces/IStakingRewards.sol";

import { FundRaisingGuild } from "./FundRaisingGuild.sol";

/// @title Fund raising platform by SkyLaunch
/// @notice Developed by Chris Ciszak
/// @dev Only the owner can add new pools
contract SkyLaunchFundRaising is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /// @dev Details about each user in a pool
    struct UserInfo {
        uint256 amount;
        uint256 fundingAmount; // Based on staked tokens, the funding that has come from the user (or not if they choose to pull out)
        uint256 multiplier;
        uint256 nftValue;
        uint256 utilityNFTTokenId;
        uint256 collectedRewards;
    }

    /// @dev Info of each pool.
    struct PoolInfo {
        IERC20 rewardToken; // Address of the reward token contract.
        IERC20 fundRaisingToken;
        uint256 subscriptionStartTimestamp ; // Block when users stake counts towards earning reward token allocation
        uint256 subscriptionEndTimestamp; // Before this block, staking is permitted
        uint256 fundingEndTimestamp; // Between subscriptionEndTimestamp and this number pledge funding is permitted
        uint256 targetRaise; // Amount that the project wishes to raise
        uint256 price; // Price per token
        uint256 maxStakingAmountPerUser; // Max. amount of tokens that can be staked per account/user
        uint256 maxUtilityNFTsValue; // max amount of tokens that are permitted to participate in this pool
        uint256 rewardsStartTime;
        uint256 rewardsCliffEndTime;
        uint256 rewardsEndTime;
    }

    struct Multiplier {
        uint256 scoreFrom;
        uint256 multiplier; // 1.5 represented as 150 
    }

    // Utility NFTs with guaranteed allocations
    address utilityNFT;

    /// @notice staking token is fixed for all pools
    IERC20 public stakingFactory;

    /// @notice staking token is fixed for all pools
    address[] public stakingRewards;

    /// @notice Container for holding all rewards
    FundRaisingGuild public rewardGuildBank;

    /// @notice List of pools that users can stake into
    PoolInfo[] public poolInfo;

    // Pool to accumulated share counters
    mapping(uint256 => uint256) public poolIdToAccPercentagePerShare;
    mapping(uint256 => uint256) public poolIdToLastPercentageAllocBlock;

    // Number of reward tokens distributed per block for this pool
    mapping(uint256 => uint256) public poolIdToRewardPerBlock;

    // Last block number that reward token distribution took place
    mapping(uint256 => uint256) public poolIdToLastRewardBlock;

    // Block number when rewards start
    mapping(uint256 => uint256) public poolIdToRewardStartBlock;

    // Block number when cliff ends
    mapping(uint256 => uint256) public poolIdToRewardCliffEndBlock;

    // Block number when rewards end
    mapping(uint256 => uint256) public poolIdToRewardEndBlock;

    // Per LPOOL token staked, how much reward token earned in pool that users will get
    mapping(uint256 => uint256) public poolIdToAccRewardPerShareVesting;

    // Total rewards being distributed up to rewardEndBlock
    mapping(uint256 => uint256) public poolIdToMaxRewardTokensAvailableForVesting;

    // Total amount staked into the pool
    mapping(uint256 => uint256) public poolIdToTotalStaked;

    // Total amount of funding received by stakers after subscriptionEndTimestamp and before fundingEndTimestamp
    mapping(uint256 => uint256) public poolIdToTotalRaised;

    mapping(uint256 => uint256) public poolIdToTotalGuaranteedAllocationsRaised;

    mapping(uint256 => uint256) public poolIdToTotalGuaranteedAllocationsSubscribed;

    mapping(uint256 => uint256) public poolIdToTotalMultipliers;

    // For every staker that funded their pledge, the sum of all of their allocated percentages
    mapping(uint256 => uint256) public poolIdToTotalFundedPercentageOfTargetRaise;

    // True when funds have been claimed
    mapping(uint256 => bool) public poolIdToFundsClaimed;

    /// @notice Per pool, info of each user that stakes ERC20 tokens.
    /// @notice Pool ID => User Address => User Info
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Available before staking ends for any given project. Essentitally 100% to 18 dp
    uint256 public constant TOTAL_TOKEN_ALLOCATION_POINTS = (100 * (10 ** 18));

    // KYCed users Merkle Root
    bytes32 public merkleRootKYC;

    // multiplier brackets for score
    Multiplier[] public multipliers;

    event ContractDeployed(address indexed guildBank);
    event PoolAdded(uint256 indexed pid);
    event Subscribe(address indexed user, uint256 indexed pid);
    event SubscribeWithUtilityNFT(address indexed user, uint256 indexed pid, uint256 amount);
    event SubscriptionFunded(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardsSetUp(uint256 indexed pid, uint256 amount, uint256 rewardStartTime, uint256 rewardCliffEndTime, uint256 rewardEndTime);
    event RewardClaimed(address indexed user, uint256 indexed pid, uint256 amount);
    event FundRaisingClaimed(uint256 indexed pid, address indexed recipient, uint256 amount);

    constructor(uint256[] memory scores, uint256[] memory mps, address _utilityNFT) public {
        //require(address(_stakingRewards) != address(0), "constructor: stakingRewards must not be zero address");
        require(scores.length == mps.length, "constructor: incorrect multipliers");

        //stakingRewards = _stakingRewards;
        rewardGuildBank = new FundRaisingGuild(address(this));
        utilityNFT = _utilityNFT;

        for(uint256 i = 0; i < scores.length; i++){
            Multiplier memory mp;
            mp.scoreFrom = scores[i];
            mp.multiplier = mps[i];
            multipliers.push(mp);
        }

        emit ContractDeployed(address(rewardGuildBank));
    }

    function addStakingRewards(address _stakingRewards) onlyOwner external {
        stakingRewards.push(_stakingRewards);
    }

    function removeStakingRewards(address _stakingRewards) onlyOwner external {
        for(uint256 i = 0; i < stakingRewards.length; i++){
            if(stakingRewards[i] == _stakingRewards){
                stakingRewards[i] = stakingRewards[stakingRewards.length -1];
                stakingRewards.pop();
            }
        }
    }

    function setKYCMerkleRoot(bytes32 _merkleRootKYC) onlyOwner external {
        merkleRootKYC = _merkleRootKYC;
    }

    /// @notice Returns the number of pools that have been added by the owner
    /// @return Number of pools
    function numberOfPools() external view returns (uint256) {
        return poolInfo.length;
    }

    /// @dev Can only be called by the contract owner
    function add(
        IERC20 _rewardToken,
        IERC20 _fundRaisingToken,
        uint256 _subscriptionStartTimestamp,
        uint256 _subscriptionEndTimestamp,
        uint256 _fundingEndTimestamp,
        uint256 _targetRaise,
        uint256 _price,
        uint256 _maxStakingAmountPerUser,
        uint256 _maxUtilityNFTsValue
    ) public onlyOwner {
        address rewardTokenAddress = address(_rewardToken);
        require(rewardTokenAddress != address(0), "add: _rewardToken is zero address");
        address fundRaisingTokenAddress = address(_fundRaisingToken);

        require(_subscriptionStartTimestamp < _subscriptionEndTimestamp, "add: _subscriptionStartTimestamp must be before staking end");
        require(_subscriptionEndTimestamp < _fundingEndTimestamp, "add: staking end must be before funding end");
        require(_targetRaise > 0, "add: Invalid raise amount");
        require(_price > 0, "add: Invalid price amount");

        poolInfo.push(PoolInfo({
            rewardToken : _rewardToken,
            fundRaisingToken : _fundRaisingToken,
            subscriptionStartTimestamp: _subscriptionStartTimestamp,
            subscriptionEndTimestamp: _subscriptionEndTimestamp,
            fundingEndTimestamp: _fundingEndTimestamp,
            targetRaise: _targetRaise,
            price: _price,
            maxStakingAmountPerUser: _maxStakingAmountPerUser,
            maxUtilityNFTsValue: _maxUtilityNFTsValue,
            rewardsStartTime: 0,
            rewardsCliffEndTime: 0,
            rewardsEndTime: 0

        }));

        //poolIdToLastPercentageAllocBlock[poolInfo.length.sub(1)] = _subscriptionStartTimestamp;

        emit PoolAdded(poolInfo.length.sub(1));
    }

    // step 
    // subscribe
    function subscribe(uint256 _pid, uint256 _index, bytes32[] calldata _merkleProof) external nonReentrant {
        // join upcoming IDO
        require(_pid < poolInfo.length, "subscribe: Invalid PID");

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(block.timestamp >= pool.subscriptionStartTimestamp, "subscribe: subscription not started");
        require(block.timestamp <= pool.subscriptionEndTimestamp, "subscribe: subscription no longer permitted");

        // Verify the merkle proof.
        bytes32 node = keccak256(abi.encodePacked(_index, msg.sender));
        require(MerkleProof.verify(_merkleProof, merkleRootKYC, node), 'subscribe: Invalid proof.');

        // Collect the users multiplier
        uint256 userMultiplier = getMultiplier(msg.sender);
        require(userMultiplier > 0, "subscribe: not sufficient score");

        // Add user to the pool
        user.multiplier = userMultiplier;

        // update multipliers
        poolIdToTotalMultipliers[_pid] = poolIdToTotalMultipliers[_pid].add(userMultiplier);

        emit Subscribe(msg.sender, _pid);
    }

    // step 
    // subscribe
    function subscribeWithUtilityNFT(uint256 _pid, uint256 utilityNFTTokenId, uint256 _index, bytes32[] calldata _merkleProof) external nonReentrant {
        // join upcoming IDO
        require(_pid < poolInfo.length, "subscribeWithUtilityNFT: Invalid PID");

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(user.nftValue == 0, "subscribeWithUtilityNFT: already subscribed with utility nft");
        require(address(pool.fundRaisingToken) != address(0), "subscribeWithUtilityNFT: Utility NFTs cannot be used for native cryptocurrency fund raising");
        require(poolIdToTotalGuaranteedAllocationsSubscribed[_pid] < pool.maxUtilityNFTsValue, "subscribeWithUtilityNFT: Guaranteed allocations oversubscribed");

        require(block.timestamp >= pool.subscriptionStartTimestamp, "subscribe: subscription not started");
        require(block.timestamp <= pool.subscriptionEndTimestamp, "subscribe: subscription no longer permitted");

        // Verify the merkle proof.
        bytes32 node = keccak256(abi.encodePacked(_index, msg.sender));
        require(MerkleProof.verify(_merkleProof, merkleRootKYC, node), 'subscribe: Invalid proof.');

        require(UtilityNFT(utilityNFT).ownerOf(utilityNFTTokenId) == msg.sender, 'subscribe: This utility NFT id is not yours');
        uint256 nftValue = UtilityNFT(utilityNFT).getAvailableAllocation(utilityNFTTokenId);
        uint256 availableValue = pool.maxUtilityNFTsValue.sub(poolIdToTotalGuaranteedAllocationsSubscribed[_pid]);

        // Add user to the pool
        user.nftValue = nftValue > pool.maxStakingAmountPerUser ? pool.maxStakingAmountPerUser : nftValue;

        if(user.nftValue > availableValue)
            user.nftValue = availableValue;

        user.utilityNFTTokenId = utilityNFTTokenId;

        // update poolIdToTotalGuaranteedAllocationsSubscribed
        poolIdToTotalGuaranteedAllocationsSubscribed[_pid] = poolIdToTotalGuaranteedAllocationsSubscribed[_pid].add(user.nftValue);

        emit SubscribeWithUtilityNFT(msg.sender, _pid, user.nftValue);
    }

    function getMaximumAllocation(uint256 _pid) public view returns (uint256) {
        require(_pid < poolInfo.length, "getFundingAmount: Invalid PID");
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo memory user = userInfo[_pid][msg.sender];

        // utility nft has got priority
        if(user.nftValue > 0)
            return user.nftValue;

        // subtrack the utility NFTs
        uint256 singleAllocation = pool.targetRaise.sub(poolIdToTotalGuaranteedAllocationsSubscribed[_pid]).div(poolIdToTotalMultipliers[_pid]);
        return singleAllocation * user.multiplier / 100;
    }

    // step 2
    function fundSubscription(uint256 _pid, uint256 _amount) external payable nonReentrant {
        require(_pid < poolInfo.length, "fundSubscription: Invalid PID");

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(user.multiplier > 0 || user.nftValue > 0, "fundSubscription: not subscribed");
        require(user.fundingAmount == 0, "fundSubscription: Subscribe has already been funded");

        require(block.timestamp > pool.subscriptionEndTimestamp, "fundSubscription: Subscription is still taking place");
        require(block.timestamp <= pool.fundingEndTimestamp, "fundSubscription: Deadline has passed to fund your subscription");
        uint256 maximumAllocation = getMaximumAllocation(_pid);

        require(maximumAllocation > 0, "fundSubscription: must have positive allocation amount");

        // collecting the payment
        if(address(pool.fundRaisingToken) == address(0)){
            // ETH/BNB etc native cryptocurrency of the platform
            require(msg.value <= maximumAllocation, "fundSubscription: Too much value provided");
            require(msg.value == _amount, "fundSubscription: Incorrect amounts");
            poolIdToTotalRaised[_pid] = poolIdToTotalRaised[_pid].add(msg.value);
            user.fundingAmount = msg.value; // ensures pledges can only be done once
        }
        else {
            // this will fail if the sender does not have the right amount of the token or the allowance is not given
            require(_amount <= maximumAllocation, "fundSubscription: Too many tokens provided");
            pool.fundRaisingToken.safeTransferFrom(msg.sender, address(this), _amount);
            user.fundingAmount = _amount; // ensures pledges can only be done once
            poolIdToTotalRaised[_pid] = poolIdToTotalRaised[_pid].add(_amount);
            if(user.nftValue > 0){
                poolIdToTotalGuaranteedAllocationsRaised[_pid] = poolIdToTotalGuaranteedAllocationsRaised[_pid].add(_amount);
                UtilityNFT(utilityNFT).spendAllocation(user.utilityNFTTokenId, _amount);
            }
        }

        emit SubscriptionFunded(msg.sender, _pid, _amount);
    }

    // pre-step 3 for project
    function getTotalRaisedVsTarget(uint256 _pid) external view returns (uint256 raised, uint256 target) {
        return (poolIdToTotalRaised[_pid], poolInfo[_pid].targetRaise);
    }

    function getRequiredRewardAmountForAmountRaised(uint256 _pid) public view returns (uint256 rewardAmount) {
        PoolInfo memory pool = poolInfo[_pid];
        return poolIdToTotalRaised[_pid].mul(pool.price).div(10**18);
    }

    // step 3
    function setupVestingRewards(uint256 _pid, uint256 _rewardAmount,  uint256 _rewardStartTimestamp, uint256 _rewardCliffEndTimestamp, uint256 _rewardEndTimestamp)
    external nonReentrant onlyOwner {
        require(_pid < poolInfo.length, "setupVestingRewards: Invalid PID");
        require(_rewardStartTimestamp > block.timestamp, "setupVestingRewards: start block in the past");
        require(_rewardCliffEndTimestamp >= _rewardStartTimestamp, "setupVestingRewards: Cliff must be after or equal to start time");
        require(_rewardEndTimestamp > _rewardCliffEndTimestamp, "setupVestingRewards: end time must be after cliff time");
        PoolInfo storage pool = poolInfo[_pid];

        require(block.timestamp > pool.fundingEndTimestamp, "setupVestingRewards: Users are still funding");
        require(_rewardAmount == getRequiredRewardAmountForAmountRaised(_pid), "setupVestingRewards: wrong reward amount provided");

        uint256 vestingLength = _rewardEndTimestamp.sub(_rewardStartTimestamp);

        pool.rewardsStartTime = _rewardStartTimestamp;
        pool.rewardsCliffEndTime = _rewardCliffEndTimestamp;
        pool.rewardsEndTime = _rewardEndTimestamp;

        pool.rewardToken.safeTransferFrom(msg.sender, address(rewardGuildBank), _rewardAmount);

        emit RewardsSetUp(_pid, _rewardAmount, _rewardStartTimestamp, _rewardCliffEndTimestamp, _rewardEndTimestamp);
    }

    function pendingRewards(uint256 _pid, address _user) public view returns (uint256) {
        require(_pid < poolInfo.length, "pendingRewards: invalid _pid");

        UserInfo memory user = userInfo[_pid][_user];

        // not funded have no rewards
        if (user.fundingAmount == 0) {
            return 0;
        }

        PoolInfo memory pool = poolInfo[_pid];

        if (pool.rewardsStartTime > block.timestamp){
            return 0;
        }

        uint256 vestingLength = pool.rewardsEndTime.sub(pool.rewardsStartTime);
        uint256 totalReward = getTotalReward(_pid, _user);
        uint256 rewardPerSecond = totalReward.div(vestingLength);
        uint256 totalUnlocked = block.timestamp.sub(pool.rewardsStartTime).mul(rewardPerSecond);

        return totalUnlocked.sub(user.collectedRewards);
    }

    function getTotalReward(uint256 _pid, address _user) public view returns (uint256) {
        require(_pid < poolInfo.length, "pendingRewards: invalid _pid");

        UserInfo memory user = userInfo[_pid][_user];

        // not funded have no rewards
        if (user.fundingAmount == 0) {
            return 0;
        }
        
        PoolInfo memory pool = poolInfo[_pid];
        return user.fundingAmount.div(pool.price).mul(10**18);
    }

    function claimReward(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        require(block.timestamp >= pool.rewardsCliffEndTime, "claimReward: Not past cliff");

        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.fundingAmount > 0, "claimReward: Not funded");

        uint256 pending = pendingRewards(_pid, msg.sender);

        if (pending > 0) {
            user.collectedRewards = user.collectedRewards.add(pending);
            safeRewardTransfer(pool.rewardToken, msg.sender, pending);

            emit RewardClaimed(msg.sender, _pid, pending);
        }
    }

    function claimFundRaising(uint256 _pid) external nonReentrant onlyOwner {
        require(_pid < poolInfo.length, "claimFundRaising: invalid _pid");
        PoolInfo storage pool = poolInfo[_pid];

        require(pool.rewardsStartTime != 0, "claimFundRaising: rewards not yet sent");
        require(poolIdToFundsClaimed[_pid] == false, "claimFundRaising: Already claimed funds");

        poolIdToFundsClaimed[_pid] = true;

        if(address(pool.fundRaisingToken) == address(0)){
            owner().call{value: poolIdToTotalRaised[_pid]}("");
            //owner.transfer(poolIdToTotalRaised[_pid]);
        }
        else {
            pool.fundRaisingToken.transfer(owner(), poolIdToTotalRaised[_pid]);
        }        

        emit FundRaisingClaimed(_pid, owner(), poolIdToTotalRaised[_pid]);
    }

    ////////////
    // Private /
    ////////////

    /// @dev Safe reward transfer function, just in case if rounding error causes pool to not have enough rewards.

    function safeRewardTransfer(IERC20 _rewardToken, address _to, uint256 _amount) private {
        uint256 bal = rewardGuildBank.tokenBalance(_rewardToken);
        if (_amount > bal) {
            rewardGuildBank.withdrawTo(_rewardToken, _to, bal);
        } else {
            rewardGuildBank.withdrawTo(_rewardToken, _to, _amount);
        }
    }

    /// @notice Return reward multiplier.
    /// @param _account account
    /// @return Multiplier
    function getMultiplier(address _account) private view returns (uint256) {
        // connect to the factory
        // loop through the pools and get the user score
        uint256 score;
        uint256 multiplier = 0;

        for(uint256 i = 0; i < stakingRewards.length; i++){
            score = score.add(IStakingRewards(stakingRewards[i]).getUserScore(_account));
        }

        // get the multiplier based on the score
        for (uint256 i = 0; i < multipliers.length - 1; i++){
            Multiplier memory mp = multipliers[i];
            if(score >= mp.scoreFrom){
                return mp.multiplier;
                break;
            }
        }

        return multiplier;
    }
}

interface UtilityNFT {
    function getAvailableAllocation(uint256 id) external view returns (uint256);
    function spendAllocation(uint256 id, uint256 amount) external;
    function ownerOf(uint256 tokenId) external view returns (address owner);
}