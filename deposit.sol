// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IToken {
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint256);
    function approve(address spender, uint value) external;
    function transfer(address spender, uint value) external;
    function transferFrom(address from, address to, uint value) external;
}

struct Staking {
    address stakeToken;
    uint256 stakeAmount;
    uint256 startTime;
    uint256 lastClaimTime;
    uint256 closeTime;
    uint256 blockRewards;
    address referrer;
    uint256 claimedAmount;
    bool closed;
    address staker;
    uint256 packageIdx;
}

struct Package {
    uint256 amount;
    uint256 period;
    uint256 rate;
}

contract SmarTradeContract {
    address public owner;
    Package[] public packages;
    Staking[] public stakings;
    mapping(address => uint256[]) public stakingsIdxForUser;
    mapping(address => uint256[]) public stakingsReferIdxForUser;
    
    uint256 public referrerRate;
    uint256 public precision;

    mapping(address => bool) public userInfo;
    bool public status;

    constructor() {
        owner = msg.sender;
    }

    function initialize() public {
        require(owner == address(0));
        owner = msg.sender;
    }

    function setPrecision(uint256 precision_) public onlyOwner {
        precision = precision_;
    }

    function setReferrerRate(uint256 rRate) public onlyOwner {
        referrerRate = rRate;
    }

    modifier onlyOwner() {
        require(owner == msg.sender, "not owner");
        _;
    }

    function renewOwner(address newOwner) public onlyOwner {
        owner = newOwner;
    }

    function addPackages(uint256[] memory amounts, uint256[] memory dayCounts, uint256[] memory rates) public onlyOwner {
        for(uint256 i = 0; i < amounts.length; ++i) {
            addPackage(amounts[i], dayCounts[i], rates[i]);
        }
    }

    function addPackage(uint256 amount, uint256 dayCount, uint256 rate) public onlyOwner {
        Package memory package;
        package.amount = amount;
        package.period = dayCount * 7200;
        package.rate = rate;
        packages.push(package);
    }

    function editPackage(uint256 packageIdx, uint256 amount, uint256 dayCount, uint256 rate) public onlyOwner {
        packages[packageIdx].amount = amount;
        packages[packageIdx].period = dayCount * 7200;
        packages[packageIdx].rate = rate;
    }

    function getAllPackages() public view returns(Package[] memory) {
        return packages;
    }

    function getStakingIdxForUser(address user) public view returns(uint256[] memory) {
        return stakingsIdxForUser[user];
    }

    function getStakingReferIdxForUser(address user) public view returns(uint256[] memory) {
        return stakingsReferIdxForUser[user];
    }

    function getActiveStakingsCount() public view returns(uint256) {
        uint256 count = 0;
        for(uint256 i = 0; i < stakings.length; i ++) {
            if(stakings[i].closed == false) {
                count ++;
            }
        }
        return count;
    }

    function getStakingsCount() public view returns(uint256) {
        return stakings.length;
    }

    function getActiveStakingsAmount() public view returns(uint256) {
        uint256 totalValue = 0;
        for(uint256 i = 0; i < stakings.length; i ++) {
            if(stakings[i].closed == true) continue;
            uint256 pi = stakings[i].packageIdx;
            totalValue += packages[pi].amount;
        }
        return totalValue;
    }

    function stake(uint256 packageIdx, address tokenAddr, address referrer) public onlyEOA {
        require(referrer != msg.sender && referrer != address(0), "equal to staker or null");
        Package memory package = packages[packageIdx];
        Staking memory newStaking;
        newStaking.stakeToken = tokenAddr;
        newStaking.stakeAmount = package.amount * (10 ** IToken(tokenAddr).decimals());
        newStaking.startTime = block.number;
        newStaking.lastClaimTime = block.number;
        newStaking.closeTime = block.number + package.period;
        newStaking.blockRewards = newStaking.stakeAmount * package.rate / precision / 7200;
        newStaking.referrer = referrer;
        newStaking.claimedAmount = 0;
        newStaking.closed = false;
        newStaking.staker = msg.sender;
        newStaking.packageIdx = packageIdx;

        IToken(newStaking.stakeToken).transferFrom(newStaking.staker, address(this), newStaking.stakeAmount);

        stakings.push(newStaking);
        stakingsIdxForUser[msg.sender].push(stakings.length - 1);
        stakingsReferIdxForUser[referrer].push(stakings.length - 1);
    }

    function claim() public onlyEOA {
        uint256[] storage stakingsIdxArray = stakingsIdxForUser[msg.sender];
        for(uint256 i = 0; i < stakingsIdxArray.length; ++i) {
            claimEachStaking(stakingsIdxArray[i]);
        }
    }

    function claimEachStaking(uint256 stakingId) public onlyEOA {
        Staking storage staking = stakings[stakingId];
        require(staking.staker == msg.sender, "not staker");
        if(staking.closed) return;

        uint256 rewards = calcRewards(stakingId);

        if(staking.closeTime <= block.number) {
            rewards += staking.stakeAmount;
            staking.closed = true;
        }

        staking.lastClaimTime = block.number;
        staking.claimedAmount = staking.claimedAmount + rewards;

        IToken(staking.stakeToken).transfer(staking.staker, rewards);
        if(staking.closed) {
            IToken(staking.stakeToken).transfer(staking.referrer, (staking.claimedAmount - staking.stakeAmount) * referrerRate / precision);
        }
    }

    function unStake(uint256 stakingId) public onlyEOA {
        Staking storage staking = stakings[stakingId];
        require(staking.staker == msg.sender, "not staker");
        require(staking.closed == false, "already closed");
        if(staking.closeTime < block.number) claimEachStaking(stakingId);

        if(staking.claimedAmount < staking.stakeAmount) {
            IToken(staking.stakeToken).transfer(staking.staker, staking.stakeAmount - staking.claimedAmount);
            staking.claimedAmount = staking.stakeAmount;
        }

        staking.closed = true;
        staking.lastClaimTime = block.number;
    }

    function calcRewards(uint256 stakeIdx) public view returns(uint256) {
        uint256 start = stakings[stakeIdx].lastClaimTime;
        uint256 end = stakings[stakeIdx].closeTime < block.number ? stakings[stakeIdx].closeTime : block.number;
        if(end <= start) return 0;
        uint256 rewards =  stakings[stakeIdx].blockRewards * (end - start);
        rewards = rewards + rewards * (end - start) / (stakings[stakeIdx].closeTime - start) * 4 / 11;
        return rewards;
    }

    function depositToVault(address token, address to, uint256 amount) public onlyOwner {
        IToken(token).transfer(to, amount);
    }
    
    modifier onlyEOA() {
        require(isContract(msg.sender) == false, "called by contract");
        _;
    }

    function isContract(address _addr) private view returns (bool){
        uint32 size;
        assembly {
            size := extcodesize(_addr)
        }
        return (size > 0);
    }

}