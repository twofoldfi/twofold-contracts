// ╔══════════════════════════════════════════════════════════════════════╗
// ║  TWOFOLD                                                              ║
// ║  StakingVaultV2                                                       ║
// ╚══════════════════════════════════════════════════════════════════════╝
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract StakingVaultV2 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant PRECISION = 1e27;
    uint256 public constant MAX_REWARD_TOKENS = 16;

    struct Pending {
        uint256 amount;
        uint256 unlockTime;
    }

    struct Stream {
        uint256 rate;
        uint256 periodFinish;
        uint256 lastUpdate;
        uint256 accPerShare;
        uint256 unallocated;
    }

    error CooldownActive();
    error NothingToClaim();
    error NotRewarder();
    error ZeroAmount();
    error ZeroDuration();
    error TooManyRewardTokens();

    event Staked(address indexed account, uint256 amount);
    event UnstakeStarted(address indexed account, uint256 amount, uint256 unlockTime);
    event UnstakeClaimed(address indexed account, uint256 amount);
    event RewardNotified(address indexed token, uint256 amount, uint256 rate, uint256 periodFinish);
    event RewardsClaimed(address indexed account, address indexed token, uint256 amount);
    event RewarderSet(address indexed account, bool ok);

    IERC20 public immutable stakeToken;
    uint256 public immutable cooldown;
    uint256 public immutable duration;

    uint256 public totalStaked;
    mapping(address => uint256) public staked;
    mapping(address => Pending) public pending;
    mapping(address => bool) public rewarder;

    address[] public rewardTokens;
    mapping(address => bool) internal _isRewardToken;
    mapping(address => Stream) public streams;
    mapping(address => mapping(address => uint256)) public debt;
    mapping(address => mapping(address => uint256)) public owed;

    constructor(address owner_, address stakeToken_, uint256 cooldown_, uint256 duration_) Ownable(owner_) {
        if (duration_ == 0) revert ZeroDuration();
        stakeToken = IERC20(stakeToken_);
        cooldown = cooldown_;
        duration = duration_;
    }

    function setRewarder(address a, bool ok) external onlyOwner nonReentrant {
        rewarder[a] = ok;
        emit RewarderSet(a, ok);
    }

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _settle(msg.sender);
        staked[msg.sender] += amount;
        totalStaked += amount;
        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function startUnstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (pending[msg.sender].unlockTime != 0) revert CooldownActive();
        _settle(msg.sender);
        staked[msg.sender] -= amount;
        totalStaked -= amount;
        uint256 unlockTime = block.timestamp + cooldown;
        pending[msg.sender] = Pending({amount: amount, unlockTime: unlockTime});
        emit UnstakeStarted(msg.sender, amount, unlockTime);
    }

    function claimUnstaked() external nonReentrant {
        Pending memory p = pending[msg.sender];
        if (p.unlockTime == 0) revert NothingToClaim();
        if (block.timestamp < p.unlockTime) revert CooldownActive();
        delete pending[msg.sender];
        stakeToken.safeTransfer(msg.sender, p.amount);
        emit UnstakeClaimed(msg.sender, p.amount);
    }

    function notifyReward(address token, uint256 amount) external nonReentrant {
        if (!rewarder[msg.sender]) revert NotRewarder();
        if (amount == 0) revert ZeroAmount();
        if (!_isRewardToken[token]) {
            if (rewardTokens.length >= MAX_REWARD_TOKENS) revert TooManyRewardTokens();
            _isRewardToken[token] = true;
            rewardTokens.push(token);
        }
        _updateStream(token);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        Stream storage s = streams[token];
        uint256 scaled = amount * PRECISION + s.unallocated;
        s.unallocated = 0;
        if (block.timestamp < s.periodFinish) {
            scaled += (s.periodFinish - block.timestamp) * s.rate;
        }
        uint256 rate = scaled / duration;
        s.rate = rate;
        s.lastUpdate = block.timestamp;
        s.periodFinish = block.timestamp + duration;
        emit RewardNotified(token, amount, rate, s.periodFinish);
    }

    function claimRewards(address[] calldata tokens) external nonReentrant {
        _settle(msg.sender);
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 amount = owed[msg.sender][token];
            if (amount == 0) continue;
            owed[msg.sender][token] = 0;
            IERC20(token).safeTransfer(msg.sender, amount);
            emit RewardsClaimed(msg.sender, token, amount);
        }
    }

    function earned(address account, address token) external view returns (uint256) {
        uint256 acc = _projectedAccPerShare(token);
        uint256 accrued = (staked[account] * (acc - debt[account][token])) / PRECISION;
        return owed[account][token] + accrued;
    }

    function rewardTokensLength() external view returns (uint256) {
        return rewardTokens.length;
    }

    function _projectedAccPerShare(address token) internal view returns (uint256) {
        Stream storage s = streams[token];
        uint256 upTo = block.timestamp < s.periodFinish ? block.timestamp : s.periodFinish;
        if (upTo <= s.lastUpdate || totalStaked == 0) return s.accPerShare;
        return s.accPerShare + ((upTo - s.lastUpdate) * s.rate) / totalStaked;
    }

    function _updateStream(address token) internal {
        Stream storage s = streams[token];
        uint256 upTo = block.timestamp < s.periodFinish ? block.timestamp : s.periodFinish;
        if (upTo <= s.lastUpdate) return;
        uint256 accrued = (upTo - s.lastUpdate) * s.rate;
        if (totalStaked == 0) {
            s.unallocated += accrued;
        } else {
            s.accPerShare += accrued / totalStaked;
        }
        s.lastUpdate = upTo;
    }

    function _settle(address account) internal {
        uint256 amount = staked[account];
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            _updateStream(token);
            uint256 acc = streams[token].accPerShare;
            uint256 snapshot = debt[account][token];
            if (acc != snapshot) {
                owed[account][token] += (amount * (acc - snapshot)) / PRECISION;
                debt[account][token] = acc;
            }
        }
    }
}
