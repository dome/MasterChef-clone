// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RewardToken} from "./RewardToken.sol";

contract MasterChef is Ownable {
    struct UserInfo {
        uint256 amount; // how many lp user has provided.
        uint256 rewardDebt;
    }

    struct PoolInfo {
        IERC20 lpToken; // address of lp token.
        uint256 allocPoint; // SUSHIs to distribute per block.
        uint256 lastRewardBlock; // last block number that SUSHIs distributed.
        uint256 accSushiPerShare; // Accumulated SUSHIs per share. 1e12.
    }

    RewardToken public sushi; // SUSHI token.
    address public devaddr; // Dev addr.
    uint256 public bonusEndBlock; // Block number when bonus SUSHI period ends.
    uint256 public sushiPerBlock; // SUSHI tokens created per block.
    uint256 public constant BONUS_MULTIPLIER = 10; // bonus for early sushi makers.
    address public migrator; // migrator contract. can only be set by owner.

    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    uint256 public totalAllocPoint = 0; // Must be the sum of all allocation point in all pools.
    uint256 public startBlock; // block number when SUSHI mining starts.

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Claim(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        RewardToken _sushi,
        address _devaddr,
        uint256 _sushiPerBlock,
        uint256 _startBlock,
        uint256 _bonusEndBlock
    ) Ownable(msg.sender) {
        sushi = _sushi;
        devaddr = _devaddr;
        sushiPerBlock = _sushiPerBlock;
        startBlock = _startBlock;
        bonusEndBlock = _bonusEndBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function setsushiPerBlock(uint256 _sushiPerBlock) public onlyOwner {
        require(_sushiPerBlock > 0, "setsushiPerBlock: _sushiPerBlock <= 0");
        sushiPerBlock = _sushiPerBlock;
    }
    // can be called only by owner. Do not add the same lp token more than once. Rewards will be messed.

    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePool();
            // mass update functions ...
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint += _allocPoint;
        poolInfo.push(
            PoolInfo({lpToken: _lpToken, allocPoint: _allocPoint, lastRewardBlock: lastRewardBlock, accSushiPerShare: 0})
        );
    }

    // Update the given pool's SUSHI allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePool();
            // mass update functions ...
        }
        totalAllocPoint = totalAllocPoint - poolInfo[_pid].allocPoint + _allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Return reward multiplier over the _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (_to <= bonusEndBlock) {
            return (_to - _from) * BONUS_MULTIPLIER;
        } else if (_from >= bonusEndBlock) {
            return _to - _from;
        } else {
            return (bonusEndBlock - _from) * BONUS_MULTIPLIER + (_to - bonusEndBlock);
        }
    }

    // View function to see pending SUSHIs on frontend;
    function pendingSushi(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint256 accSushiPerShare = pool.accSushiPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 sushiReward = (multiplier * sushiPerBlock * pool.allocPoint) / totalAllocPoint;

            accSushiPerShare += sushiReward * 1e12 / lpSupply;
        }

        return user.amount * accSushiPerShare / 1e12 - user.rewardDebt;
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 sushiReward = (multiplier * sushiPerBlock * pool.allocPoint) / totalAllocPoint;

        sushi.mint(devaddr, sushiReward / 10);
        sushi.mint(address(this), sushiReward);

        pool.accSushiPerShare += sushiReward * 1e12 / lpSupply;
        pool.lastRewardBlock = block.number;
    }

    function massUpdatePool() public {
        for (uint256 pid = 0; pid < poolInfo.length; pid++) {
            updatePool(pid);
        }
    }

    // Deposit LP tokens to MasterChef for SUSHI allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);

        if (user.amount > 0) {
            uint256 pending = user.amount * pool.accSushiPerShare / 1e12 - user.rewardDebt;
            safeSushiTransfer(msg.sender, pending);
        }
        pool.lpToken.transferFrom(msg.sender, address(this), _amount);
        user.amount += _amount;
        user.rewardDebt = user.amount * pool.accSushiPerShare / 1e12;
        emit Deposit(msg.sender, _pid, _amount);
    }

    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (user.amount < _amount) revert("Not enough");
        updatePool(_pid);

        uint256 pending = user.amount * pool.accSushiPerShare / 1e12 - user.rewardDebt;
        safeSushiTransfer(msg.sender, pending);

        user.amount -= _amount;
        user.rewardDebt = user.amount * pool.accSushiPerShare / 1e12;
        pool.lpToken.transfer(msg.sender, _amount);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // View function to see pending SUSHIs on frontend;
    function claim(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);

        uint256 pending = user.amount * pool.accSushiPerShare / 1e12 - user.rewardDebt;
        safeSushiTransfer(msg.sender, pending);
        emit Claim(msg.sender, _pid, pending);
    }

    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        pool.lpToken.transfer(msg.sender, user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);

        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Safe sushi transfer, if rounding error causes pool to not have enough SUSHIs.
    function safeSushiTransfer(address _to, uint256 _amount) internal {
        uint256 sushiBal = sushi.balanceOf(address(this));
        if (_amount > sushiBal) {
            sushi.transfer(_to, sushiBal);
        } else {
            sushi.transfer(_to, _amount);
        }
    }
}
