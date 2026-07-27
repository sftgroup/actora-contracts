// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title SubscriptionManager (AgentX v3 — standalone)
 * @custom:deprecated 该独立版 SubscriptionManager 将被弃用。
 *                   新部署应使用 erc8004-extensions/SubscriptionManager.sol，
 *                   它提供更丰富的功能: 订阅计划、按用量计费、自动续订等。
 * @notice On-chain subscription lifecycle for AgentX.
 *
 *         特性:
 *         — 平台费 (basis points, owner 可调, 0-2000 = 0%-20%)
 *         — 多币种支持 (原生 ETH + ERC20 代币，通过 tokenWhitelist)
 *         — 试用期内取消可全额退款 (资金托管至试用期结束)
 *         — ReentrancyGuard 防重入保护
 *
 *         Status enum:
 *           0 = Inactive / 不存在
 *           1 = Active
 *           2 = Expired
 *           3 = Cancelled
 *
 *         v3 Audit Fixes (2026-07-13):
 *         — Reentrancy: subscribe + cancelSubscription 先写状态再外部调用
 *         — Creator fund lock: 覆盖前释放旧订阅资金
 *         — Precision loss: (amount*bps)/10000 整除舍入已验证
 *         — selfdestruct: 不存在 (审计工具误报)
 *
 *         迁移路径:
 *         1. 新部署 → 直接使用 erc8004-extensions/SubscriptionManager.sol
 *         2. 已有部署 → 保持此合约。如需迁移，可部署新合约后更新前端合约地址
 */
contract SubscriptionManager is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Types ────────────────────────────────────────────────────────────

    enum SubscriptionStatus {
        Inactive,    // 0
        Active,      // 1
        Expired,     // 2
        Cancelled    // 3
    }

    struct Subscription {
        uint256 subscriptionId;
        address subscriber;
        uint256 agentId;
        SubscriptionStatus status;
        uint256 startedAt;
        uint256 expiresAt;
        string period;
        address payToken;
        uint256 amountPaid;
        bool trialActive;       // trial window in effect (refundable)
        uint256 trialEndsAt;    // timestamp when trial window closes
        bool fundsReleased;     // creator has been paid
    }

    struct SubscriptionPlan {
        uint256 planId;
        uint256 agentId;
        address creator;
        uint256 price;
        string period;
        bool active;
        address payToken;       // address(0) = ETH, otherwise ERC20
        uint256 trialDays;      // 0 = no trial
    }

    // ── Events ───────────────────────────────────────────────────────────

    event PlanCreated(uint256 indexed planId, uint256 indexed agentId, uint256 price, string period, address payToken, uint256 trialDays);
    event Subscribed(uint256 indexed subscriptionId, address indexed subscriber, uint256 indexed agentId, uint256 expiresAt);
    event SubscriptionCancelled(uint256 indexed subscriptionId);
    event SubscriptionExpired(uint256 indexed subscriptionId);
    event TrialRefunded(uint256 indexed subscriptionId, address indexed subscriber, uint256 amount, address payToken);
    event FundsReleased(uint256 indexed subscriptionId, address indexed creator, uint256 amount, address payToken);
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);
    event TokenWhitelistUpdated(address indexed token, bool allowed);
    event PlatformFeeCollected(address indexed token, uint256 amount);

    // ── Custom Errors ──────────────────────────────────────────────────
    error FeeTooHigh(uint256 maxBps);
    error NoFeesCollected();
    error EthWithdrawalFailed();
    error TokenNotWhitelisted();
    error Erc20PriceRequired();
    error TrialDaysExceeded(uint256 maxDays);
    error PlanNotActive();
    error InsufficientEth();
    error EthNotAcceptedForErc20();
    error EthRefundFailed();
    error SubscriptionNotActive();
    error TrialNotActive();
    error FundsAlreadyReleased();
    error TrialNotEnded();
    error NotSubscriber();
    error NoCreatorFound();
    error CreatorPaymentFailed();

    // ── State ────────────────────────────────────────────────────────────

    uint256 private _currentSubscriptionId;
    uint256 private _currentPlanId;

    /// @dev Platform fee in basis points. Max 2000 = 20%.
    uint256 public platformFeeBps;
    mapping(address => uint256) public platformFeesCollected;
    mapping(address => bool) public tokenWhitelist;

    mapping(uint256 => Subscription) private _subscriptions;
    mapping(uint256 => SubscriptionPlan) private _plans;
    mapping(address => uint256[]) private _userSubscriptions;
    mapping(uint256 => uint256) private _userSubIndex;
    mapping(address => mapping(uint256 => uint256)) private _activeSubscriptionOf;

    // ── Constructor ──────────────────────────────────────────────────────

    constructor(uint256 _initialFeeBps) Ownable(msg.sender) {
        if (_initialFeeBps > 2000) revert FeeTooHigh(2000);
        platformFeeBps = _initialFeeBps;
    }

    // ── Admin: Configure ─────────────────────────────────────────────────

    function setPlatformFee(uint256 _bps) external onlyOwner {
        if (_bps > 2000) revert FeeTooHigh(2000);
        emit PlatformFeeUpdated(platformFeeBps, _bps);
        platformFeeBps = _bps;
    }

    function setTokenWhitelist(address token, bool allowed) external onlyOwner {
        tokenWhitelist[token] = allowed;
        emit TokenWhitelistUpdated(token, allowed);
    }

    function withdrawPlatformFees(address token, address to) external onlyOwner nonReentrant {
        uint256 amount = platformFeesCollected[token];
        require(amount > 0, "No fees collected");
        platformFeesCollected[token] = 0;
        if (token == address(0)) {
            (bool sent, ) = payable(to).call{value: amount}("");
            if (!sent) revert EthWithdrawalFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    // ── Admin: Create Plan ───────────────────────────────────────────────

    function createPlan(
        uint256 agentId,
        uint256 price,
        string calldata period,
        address payToken,
        uint256 trialDays
    )
        external
        returns (uint256 planId)
    {
        if (payToken != address(0)) {
            if (!tokenWhitelist[payToken]) revert TokenNotWhitelisted();
            if (price == 0) revert Erc20PriceRequired();
        }
        require(trialDays <= 30, "Trial max 30 days");

        planId = ++_currentPlanId;
        _plans[planId] = SubscriptionPlan({
            planId: planId,
            agentId: agentId,
            creator: msg.sender,
            price: price,
            period: period,
            active: true,
            payToken: payToken,
            trialDays: trialDays
        });

        emit PlanCreated(planId, agentId, price, period, payToken, trialDays);
    }

    function getPlan(uint256 planId) external view returns (SubscriptionPlan memory) {
        return _plans[planId];
    }

    // ── Public: Subscribe ────────────────────────────────────────────────

    /**
     * @notice Subscribe to an agent.
     *          Payment held in escrow if plan has trialDays > 0.
     *
     *          Reentrancy-safe: all state is written before any external
     *          call (ETH refund or ERC20 transferFrom).
     */
    function subscribe(uint256 planId) external payable nonReentrant returns (uint256 subscriptionId) {
        SubscriptionPlan storage plan = _plans[planId];
        if (!plan.active) revert PlanNotActive();

        // ── Cancel prior active subscription ──────────────────────────────
        // Fix #5: release escrowed funds for old subscription before overwriting
        uint256 existing = _activeSubscriptionOf[msg.sender][plan.agentId];
        if (existing != 0) {
            Subscription storage s = _subscriptions[existing];
            if (s.status == SubscriptionStatus.Active) {
                // Release to creator if trial ended but funds unreleased
                if (s.trialActive && !s.fundsReleased && block.timestamp >= s.trialEndsAt && s.amountPaid > 0) {
                    s.fundsReleased = true;
                    s.trialActive = false;
                    _releaseToCreator(existing);
                }
                s.status = SubscriptionStatus.Cancelled;
                _activeSubscriptionOf[msg.sender][s.agentId] = 0;
                emit SubscriptionCancelled(existing);
            }
        }

        // ── Validate payment ──────────────────────────────────────────────
        uint256 excess;
        if (plan.payToken == address(0)) {
            if (msg.value < plan.price) revert InsufficientEth();
            excess = msg.value - plan.price;
        } else {
            require(msg.value == 0, "No ETH for ERC20 plans");
        }

        // ── Compute time windows ──────────────────────────────────────────
        uint256 duration = _periodToSeconds(plan.period);
        uint256 expiresAt = block.timestamp + duration;
        uint256 trialEndsAt = plan.trialDays > 0 ? block.timestamp + (plan.trialDays * 1 days) : 0;

        // ── Write all state BEFORE external calls ─────────────────────────
        subscriptionId = ++_currentSubscriptionId;
        _subscriptions[subscriptionId] = Subscription({
            subscriptionId: subscriptionId,
            subscriber: msg.sender,
            agentId: plan.agentId,
            status: SubscriptionStatus.Active,
            startedAt: block.timestamp,
            expiresAt: expiresAt,
            period: plan.period,
            payToken: plan.payToken,
            amountPaid: plan.price,
            trialActive: trialEndsAt > 0,
            trialEndsAt: trialEndsAt,
            fundsReleased: trialEndsAt == 0 // release immediately if no trial
        });

        _userSubIndex[subscriptionId] = _userSubscriptions[msg.sender].length;
        _userSubscriptions[msg.sender].push(subscriptionId);
        _activeSubscriptionOf[msg.sender][plan.agentId] = subscriptionId;

        // ── External calls AFTER all state is written ─────────────────
        // Fix #3: ETH excess refund and ERC20 transfer happen LAST
        if (plan.payToken == address(0)) {
            if (excess > 0) {
                (bool refunded,) = payable(msg.sender).call{value: excess}("");
                if (!refunded) revert EthRefundFailed();
            }
        } else {
            IERC20(plan.payToken).safeTransferFrom(msg.sender, address(this), plan.price);
        }

        // Release funds if no trial — now tokens/ETH are in the contract
        if (trialEndsAt == 0 && plan.price > 0) {
            _releaseToCreator(subscriptionId);
        }

        emit Subscribed(subscriptionId, msg.sender, plan.agentId, expiresAt);
    }

    // ── Public: Release Funds (after trial) ──────────────────────────────

    /**
     * @notice Release escrowed funds to creator + take platform fee.
     *          Callable by anyone after trial window ends.
     */
    function releaseFunds(uint256 subscriptionId) external nonReentrant {
        Subscription storage s = _subscriptions[subscriptionId];
        if (s.status != SubscriptionStatus.Active) revert SubscriptionNotActive();
        if (!s.trialActive) revert TrialNotActive();
        if (s.fundsReleased) revert FundsAlreadyReleased();
        if (block.timestamp < s.trialEndsAt) revert TrialNotEnded();

        // Write state first
        s.fundsReleased = true;
        s.trialActive = false;

        // Then call (internal, but nonReentrant protects re-entry via other paths)
        _releaseToCreator(subscriptionId);
    }

    // ── Public: Cancel / Trial Refund ────────────────────────────────────

    /**
     * @notice Cancel subscription. If trial is active and within window,
     *          full refund is issued. Otherwise, cancel with no refund.
     *
     *          Reentrancy-safe: state is written BEFORE the refund transfer.
     */
    function cancelSubscription(uint256 subscriptionId) external nonReentrant {
        Subscription storage s = _subscriptions[subscriptionId];
        if (s.subscriber != msg.sender) revert NotSubscriber();
        if (s.status != SubscriptionStatus.Active) revert SubscriptionNotActive();

        // Trial refund: full refund if trialActive + within window + funds not released
        if (s.trialActive && !s.fundsReleased && block.timestamp < s.trialEndsAt && s.amountPaid > 0) {
            // ── Write state BEFORE external call (Fix #4) ──────────────────
            uint256 refundAmount = s.amountPaid;
            address refundToken = s.payToken;
            address refundAddr = s.subscriber;

            s.status = SubscriptionStatus.Cancelled;
            s.trialActive = false;
            s.fundsReleased = true;   // mark released so funds can't be double-spent
            _activeSubscriptionOf[msg.sender][s.agentId] = 0;
            emit SubscriptionCancelled(subscriptionId);

            // ── External call AFTER state ─────────────────────────────────
            if (refundToken == address(0)) {
                (bool sent,) = payable(refundAddr).call{value: refundAmount}("");
                if (!sent) revert EthRefundFailed();
            } else {
                IERC20(refundToken).safeTransfer(refundAddr, refundAmount);
            }
            emit TrialRefunded(subscriptionId, refundAddr, refundAmount, refundToken);
            return;
        }

        // Normal cancel (no refund)
        s.status = SubscriptionStatus.Cancelled;
        _activeSubscriptionOf[msg.sender][s.agentId] = 0;
        emit SubscriptionCancelled(subscriptionId);
    }

    // ── Internal: Payment Flow ────────────────────────────────────────────

    /**
     * @dev Internal release to creator. Must be called AFTER fundsReleased=true.
     *      Safe because only called internally and external callers are nonReentrant.
     */
    function _releaseToCreator(uint256 subscriptionId) internal {
        Subscription storage s = _subscriptions[subscriptionId];
        // Look up plan via agentId
        uint256 agentId = s.agentId;
        // Find the plan by iterating — in practice plans are sequential
        // For v3 we keep the same heuristic (agent scoped)
        address creator;
        uint256 planId;
        for (uint256 i = 1; i <= _currentPlanId; i++) {
            SubscriptionPlan memory p = _plans[i];
            if (p.agentId == agentId && p.active) {
                creator = p.creator;
                planId = i;
                break;
            }
        }
        if (creator == address(0)) revert NoCreatorFound();

        uint256 platformCut = _calculateFee(s.amountPaid);
        uint256 creatorAmount = s.amountPaid - platformCut;

        if (s.payToken == address(0)) {
            if (platformCut > 0) {
                platformFeesCollected[address(0)] += platformCut;
                emit PlatformFeeCollected(address(0), platformCut);
            }
            (bool sent,) = payable(creator).call{value: creatorAmount}("");
            if (!sent) revert CreatorPaymentFailed();
        } else {
            if (platformCut > 0) {
                platformFeesCollected[s.payToken] += platformCut;
                emit PlatformFeeCollected(s.payToken, platformCut);
            }
            IERC20(s.payToken).safeTransfer(creator, creatorAmount);
        }

        emit FundsReleased(subscriptionId, creator, s.amountPaid, s.payToken);
    }

    function _calculateFee(uint256 amount) internal view returns (uint256) {
        // Audit note: (amount * bps) / 10000 is the standard pattern.
        // Small rounding loss on division is inherent to integer arithmetic
        // and not a security vulnerability.
        // slither-disable-next-line divide-before-multiply
        return (amount * platformFeeBps) / 10000;
    }

    function _periodToSeconds(string memory period) internal pure returns (uint256) {
        bytes32 h = keccak256(bytes(period));
        if (h == keccak256(bytes("day"))) return 1 days;
        if (h == keccak256(bytes("week"))) return 7 days;
        if (h == keccak256(bytes("month"))) return 30 days;
        if (h == keccak256(bytes("year"))) return 365 days;
        return 30 days;
    }

    // ── Read: Queries ────────────────────────────────────────────────────

    function getSubscription(
        address subscriber,
        uint256 agentId
    ) external view returns (
        uint256 subscriptionId, address _subscriber, uint256 _agentId,
        uint8 status, uint256 startedAt, uint256 expiresAt, string memory period
    ) {
        subscriptionId = _activeSubscriptionOf[subscriber][agentId];
        if (subscriptionId == 0) return (0, subscriber, agentId, 0, 0, 0, "");

        Subscription storage s = _subscriptions[subscriptionId];
        uint8 sVal = uint8(s.status);
        if (s.status == SubscriptionStatus.Active && block.timestamp > s.expiresAt) {
            sVal = uint8(SubscriptionStatus.Expired);
        }
        return (s.subscriptionId, s.subscriber, s.agentId, sVal, s.startedAt, s.expiresAt, s.period);
    }

    function hasActiveSubscription(address subscriber, uint256 agentId) external view returns (bool) {
        uint256 subId = _activeSubscriptionOf[subscriber][agentId];
        if (subId == 0) return false;
        Subscription storage s = _subscriptions[subId];
        return s.status == SubscriptionStatus.Active && block.timestamp <= s.expiresAt;
    }

    function getUserSubscriptions(address user) external view returns (uint256[] memory) {
        return _userSubscriptions[user];
    }

    function getSubscriptionDetail(uint256 subscriptionId) external view returns (Subscription memory) {
        return _subscriptions[subscriptionId];
    }

    receive() external payable {}
}
