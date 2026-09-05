// ╔══════════════════════════════════════════════════════════════════════╗
// ║  TWOFOLD                                                             ║
// ║  TwoStakingUSDG                                                      ║
// ║  TWO staking vault 2: stake TWO, earn USDG                           ║
// ╚══════════════════════════════════════════════════════════════════════╝
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract TwoStakingUSDG is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant PRECISION = 1e27;

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

    error ZeroAmount();
    error ZeroDuration();
    error StakingPaused();
    error CapExceeded();
    error CooldownActive();
    error NothingToClaim();
    error NotRewarder();
    error ZeroAddress();
    error RenounceDisabled();

    event Staked(address indexed account, uint256 amount);
    event UnstakeStarted(address indexed account, uint256 amount, uint256 unlockTime);
    event UnstakeClaimed(address indexed account, uint256 amount);
    event RewardNotified(uint256 amount, uint256 rate, uint256 periodFinish);
    event RewardsClaimed(address indexed account, uint256 amount);
    event CapSet(uint256 cap);
    event StakingPausedSet(bool paused);
    event RewarderSet(address indexed account, bool ok);

    IERC20 public immutable stakeToken;
    IERC20 public immutable rewardToken;
    uint256 public immutable cooldown;
    uint256 public immutable duration;

    uint256 public cap;
    bool public stakingPaused;
    uint256 public totalStaked;
    Stream public stream;
    mapping(address => uint256) public staked;
    mapping(address => Pending) public pending;
    mapping(address => uint256) public debt;
    mapping(address => uint256) public owed;
    mapping(address => bool) public rewarder;

    constructor(
        address owner_,
        address stakeToken_,
        address rewardToken_,
        uint256 cooldown_,
        uint256 duration_,
        uint256 cap_
    ) Ownable(owner_) {
        if (duration_ == 0) revert ZeroDuration();
        if (stakeToken_ == address(0) || rewardToken_ == address(0)) revert ZeroAddress();
        stakeToken = IERC20(stakeToken_);
        rewardToken = IERC20(rewardToken_);
        cooldown = cooldown_;
        duration = duration_;
        cap = cap_;
        emit CapSet(cap_);
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    function setCap(uint256 cap_) external onlyOwner nonReentrant {
        cap = cap_;
        emit CapSet(cap_);
    }

    function setStakingPaused(bool paused) external onlyOwner nonReentrant {
        stakingPaused = paused;
        emit StakingPausedSet(paused);
    }

    function setRewarder(address a, bool ok) external onlyOwner nonReentrant {
        rewarder[a] = ok;
        emit RewarderSet(a, ok);
    }

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (stakingPaused) revert StakingPaused();
        if (totalStaked + amount > cap) revert CapExceeded();
        _settle(msg.sender);
        staked[msg.sender] += amount;
        totalStaked += amount;
        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function startUnstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _settle(msg.sender);
        staked[msg.sender] -= amount;
        totalStaked -= amount;
        Pending storage p = pending[msg.sender];
        p.amount += amount;
        p.unlockTime = block.timestamp + cooldown;
        emit UnstakeStarted(msg.sender, amount, p.unlockTime);
    }

    function claimUnstaked() external nonReentrant {
        Pending memory p = pending[msg.sender];
        if (p.unlockTime == 0) revert NothingToClaim();
        if (block.timestamp < p.unlockTime) revert CooldownActive();
        delete pending[msg.sender];
        stakeToken.safeTransfer(msg.sender, p.amount);
        emit UnstakeClaimed(msg.sender, p.amount);
    }

    function notifyReward(uint256 amount) external nonReentrant {
        if (!rewarder[msg.sender]) revert NotRewarder();
        if (amount == 0) revert ZeroAmount();
        _updateStream();
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        Stream storage s = stream;
        uint256 scaled = amount * PRECISION + s.unallocated;
        s.unallocated = 0;
        if (block.timestamp < s.periodFinish) {
            scaled += (s.periodFinish - block.timestamp) * s.rate;
        }
        uint256 rate = scaled / duration;
        s.rate = rate;
        s.lastUpdate = block.timestamp;
        s.periodFinish = block.timestamp + duration;
        emit RewardNotified(amount, rate, s.periodFinish);
    }

    function claimRewards() external nonReentrant {
        _settle(msg.sender);
        uint256 amount = owed[msg.sender];
        if (amount == 0) return;
        owed[msg.sender] = 0;
        rewardToken.safeTransfer(msg.sender, amount);
        emit RewardsClaimed(msg.sender, amount);
    }

    function earned(address account) external view returns (uint256) {
        uint256 acc = _projectedAccPerShare();
        return owed[account] + (staked[account] * (acc - debt[account])) / PRECISION;
    }

    function stakeRoom() external view returns (uint256) {
        return totalStaked >= cap ? 0 : cap - totalStaked;
    }

    function _projectedAccPerShare() internal view returns (uint256) {
        Stream storage s = stream;
        uint256 upTo = block.timestamp < s.periodFinish ? block.timestamp : s.periodFinish;
        if (upTo <= s.lastUpdate || totalStaked == 0) return s.accPerShare;
        return s.accPerShare + ((upTo - s.lastUpdate) * s.rate) / totalStaked;
    }

    function _updateStream() internal {
        Stream storage s = stream;
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
        _updateStream();
        uint256 acc = stream.accPerShare;
        uint256 snapshot = debt[account];
        if (acc != snapshot) {
            owed[account] += (staked[account] * (acc - snapshot)) / PRECISION;
            debt[account] = acc;
        }
    }
}
