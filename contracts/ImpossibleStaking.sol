pragma solidity ^0.6.0;
import './libraries/Ownable.sol';
import './libraries/SafeMath.sol';
import './libraries/SafeERC20.sol';
import './interfaces/IERC20.sol';
import './interfaces/IImpossibleMigrator.sol';


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
        uint256 lastRewardBlock;  // Last block number that IF distribution occurs.
        uint256 accIFPerShare; // Accumulated IF per share, times 1e12. See below.
    }

    IERC20 public ifToken;
    address public devaddr;
    uint256 public startBlock;
    uint256 public endBlock;
    uint256 public ifPerBlock;
    uint256 public totalAllocPoint = 0;
    IImpossibleMigrator public migrator;

    PoolInfo[] public poolInfo;
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event DevWithdraw(address token, uint amount);

    constructor(
        IERC20 _if,
        address _devaddr,
        uint256 _ifPerBlock,
        uint256 _startBlock,
        uint256 _bonusEndBlock
    ) public {
        ifToken = _if;
        devaddr = _devaddr;
        ifPerBlock = _ifPerBlock;
        bonusEndBlock = _bonusEndBlock;
        startBlock = _startBlock;
    }

    function setMigrator(IImpossibleMigrator _migrator) public onlyOwner {
        migrator = _migrator;
    }

    function migrate(uint256 _pid) public {
        require(address(migrator) != address(0), "migrate: no migrator");
        PoolInfo storage pool = poolInfo[_pid];
        IERC20 lpToken = pool.lpToken;
        uint256 bal = lpToken.balanceOf(address(this));
        lpToken.safeApprove(address(migrator), bal);
        IERC20 newLpToken = migrator.migrate(lpToken);
        require(bal == newLpToken.balanceOf(address(this)), "migrate: bad");
        pool.lpToken = newLpToken;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IERC20 _lpToken) public onlyOwner {
        massUpdatePools();
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accIFPerShare: 0
        }));
    }

    function set(uint256 _pid, uint256 _allocPoint) public onlyOwner {
        massUpdatePools();
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        uint _endBlock = endBlock; // gas savings
        if (_from >= _endBlock) {
            return 0;
        } else {
            return _to >= _endBlock ? _endBlock.sub(_from) : _to.sub(_from);
        }
    }

    function pendingIF(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accIFPerShare = pool.accIFPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 ifReward = multiplier.mul(ifPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accIFPerShare = accIFPerShare.add(ifReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accIFPerShare).div(1e12).sub(user.rewardDebt);
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
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 ifReward = multiplier.mul(ifPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        pool.accIFPerShare = pool.accIFPerShare.add(ifReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to ImpossibleStaking contract for IF allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accIFPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                safeIFTransfer(msg.sender, pending);
            }
        }
        if(_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accIFPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from impossible staking contract.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accIFPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            safeIFTransfer(msg.sender, pending);
        }
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accIFPerShare).div(1e12);
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
        uint256 ifBal = ifToken.balanceOf(address(this));
        if (_amount > ifBal) {
            ifToken.transfer(_to, ifBal);
        } else {
            ifToken.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }

    // Withdraws remaining IF balance in contract. Can only be called after endblock
    function removeIFBal(uint amount) external onlyOwner {
        require(block.number > endBlock, "only can withdraw IF after endBlock");
        safeIFTransfer(_msgSender(), amount);
        emit DevWithdraw(ifToken, amount);
    }

    // retrieve other tokens erroneously sent in to this address
    // Cannot withdraw LP tokens!!
    function emergencyTokenRetrieve(address token) external onlyOwner {
        uint i;
        for (i = 0; i < poolInfo.length; i++) {
          require(token != poolInfo[i].lpToken, "Cannot withdraw LP tokens");
        }

        uint balance = IERC20(token).balanceOf(address(this));

        IERC20(token).safeTransfer(
            _msgSender(),
            balance
        );

        emit DevWithdraw(token, balance);
    }
}
