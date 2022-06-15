pragma solidity ^0.6.0;
import './libraries/Ownable.sol';
import './libraries/SafeMath.sol';
import './libraries/SafeERC20.sol';
import './interfaces/IERC20.sol';


contract ImpossibleStaking is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool.
        uint256 lastRewardTimestamp;  // Last timestamp number that IF distribution occurs.
        uint256 accRewardPerShare; // Accumulated IF per share, times 1e12. See below.
    }

    IERC20 public rewardToken;
    uint256 public startTimestamp;
    uint256 public endTimestamp;
    uint256 public rewardPerTimestamp;
    uint256 public totalAllocPoint = 0;

    PoolInfo[] public poolInfo;
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event DevWithdraw(address token, uint amount);

    constructor(
        IERC20 _if,
        uint256 _rewardPerTimestamp,
        uint256 _startTimestamp,
        uint256 _endTimestamp
    ) public {
        rewardToken = _if;
        rewardPerTimestamp = _rewardPerTimestamp;
        endTimestamp = _endTimestamp;
        startTimestamp = _startTimestamp;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IERC20 _lpToken) public onlyOwner {
        massUpdatePools();
        uint256 lastRewardTimestamp = block.timestamp > startTimestamp ? block.timestamp : startTimestamp;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardTimestamp: lastRewardTimestamp,
            accRewardPerShare: 0
        }));
    }

    function set(uint256 _pid, uint256 _allocPoint) public onlyOwner {
        massUpdatePools();
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        uint _endTimestamp = endTimestamp; // gas savings
        if (_from >= _endTimestamp) {
            return 0;
        } else {
            return _to >= _endTimestamp ? _endTimestamp.sub(_from) : _to.sub(_from);
        }
    }

    function pendingRewards(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accRewardPerShare = pool.accRewardPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTimestamp && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardTimestamp, block.timestamp);
            uint256 ifReward = multiplier.mul(rewardPerTimestamp).mul(pool.allocPoint).div(totalAllocPoint);
            accRewardPerShare = accRewardPerShare.add(ifReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accRewardPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTimestamp) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardTimestamp = block.timestamp;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardTimestamp, block.timestamp);
        uint256 ifReward = multiplier.mul(rewardPerTimestamp).mul(pool.allocPoint).div(totalAllocPoint);
        pool.accRewardPerShare = pool.accRewardPerShare.add(ifReward.mul(1e12).div(lpSupply));
        pool.lastRewardTimestamp = block.timestamp;
    }

    // Deposit LP tokens to ImpossibleStaking contract for IF allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accRewardPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                safeIFTransfer(msg.sender, pending);
            }
        }
        if(_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from impossible staking contract.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accRewardPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            safeIFTransfer(msg.sender, pending);
        }
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Safe if transfer function, just in case if rounding error causes pool to not have enough IFs.
    function safeIFTransfer(address _to, uint256 _amount) internal {
        uint256 ifBal = rewardToken.balanceOf(address(this));
        if (_amount > ifBal) {
            rewardToken.transfer(_to, ifBal);
        } else {
            rewardToken.transfer(_to, _amount);
        }
    }

    // Withdraws remaining IF balance in contract. Can only be called after endTimestamp
    function removeIFBal(uint amount) external onlyOwner {
        require(block.timestamp > endTimestamp, "only can withdraw IF after endTimestamp");
        safeIFTransfer(_msgSender(), amount);
        emit DevWithdraw(address(rewardToken), amount);
    }

    // retrieve other tokens erroneously sent in to this address
    // Cannot withdraw LP tokens!!
    function emergencyTokenRetrieve(address token) external onlyOwner {
        uint i;
        for (i = 0; i < poolInfo.length; i++) {
          require(token != address(poolInfo[i].lpToken), "Cannot withdraw LP tokens");
        }

        uint balance = IERC20(token).balanceOf(address(this));

        IERC20(token).safeTransfer(
            _msgSender(),
            balance
        );

        emit DevWithdraw(address(token), balance);
    }
}
