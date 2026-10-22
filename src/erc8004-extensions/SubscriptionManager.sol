// contracts/extensions/SubscriptionManager.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../erc8004-interfaces/IERC8004Identity.sol";
import "./TokenPriceOracle.sol";

/**
 * @title SubscriptionManager
 * @dev Enhanced subscription management for AI Agent services with recurring and usage-based payments
 * @notice Production-ready subscription system with flexible billing
 *
 *         订阅续费由外部编排（网关 AA session key 重新调用 `subscribe(planId)`）；
 *         本合约不持有用户余额、不做代扣，因此不依赖 AgentWallet。
 */
contract ERC8004SubscriptionManager is Ownable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.UintSet;
    
    IERC8004Identity public identityRegistry;
    IERC721 public erc721Identity;
    TokenPriceOracle public priceOracle;
    
    enum SubscriptionStatus {
        Active,
        Cancelled,
        Expired,
        PaymentFailed,
        Suspended
    }
    
    enum BillingPeriod {
        Daily,
        Weekly,
        Monthly,
        Quarterly,
        Yearly
    }
    
    enum PlanType {
        Subscription,
        UsageBased,
        Hybrid
    }
    
    struct SubscriptionPlan {
        uint256 planId;
        uint256 agentId;
        string name;
        string description;
        PlanType planType;
        address token;
        uint256 subscriptionPrice; // For recurring subscription
        uint256 usagePrice; // For per-use payment (if planType is UsageBased or Hybrid)
        BillingPeriod billingPeriod;
        uint256 maxUsage; // Max usage per billing period (0 means unlimited)
        uint256 totalUsageLimit; // Total usage limit for usage-based plans
        bool isActive;
        uint256 createdAt;
        uint256 platformFeePercentage; // Platform fee percentage (in basis points, 100 = 1%)
    }
    
    struct Subscription {
        uint256 subscriptionId;
        uint256 planId;
        uint256 agentId;
        address subscriber;
        SubscriptionStatus status;
        PlanType planType;
        uint256 startDate;
        uint256 nextBillingDate;
        uint256 endDate;
        uint256 currentPeriodUsage;
        uint256 totalUsage;
        uint256 remainingUsage; // For usage-based plans
        uint256 totalPaid;
        uint256 createdAt;
        uint256 lastPaymentDate;
        address paymentToken;
    }
    
    /// @notice P1.7：存量计划的导入载荷
    /// @dev planId 由合约自增分配；planType / 价格 / 周期等字段原样落库
    struct ImportedPlan {
        uint256 agentId;
        string name;
        string description;
        PlanType planType;
        address token;
        uint256 subscriptionPrice;
        uint256 usagePrice;
        BillingPeriod billingPeriod;
        uint256 maxUsage;
        uint256 totalUsageLimit;
        bool isActive;
        uint256 createdAt;
        uint256 platformFeePercentage;
    }
    
    /// @notice M3：存量子订阅的导入载荷
    /// @dev agentId / planType / paymentToken 由 `_subscriptionPlans[planId]` 派生，不接受调用方指定
    struct ImportedSubscription {
        uint256 planId;
        address subscriber;
        SubscriptionStatus status;
        uint256 startDate;
        uint256 nextBillingDate;
        uint256 endDate;
        uint256 totalPaid;
    }
    
    // Storage
    uint256 private _planCounter;
    uint256 private _subscriptionCounter;
    
    mapping(uint256 => SubscriptionPlan) private _subscriptionPlans;
    mapping(uint256 => Subscription) private _subscriptions;
    mapping(uint256 => EnumerableSet.UintSet) private _agentPlans;
    mapping(uint256 => EnumerableSet.UintSet) private _agentSubscriptions;
    mapping(address => EnumerableSet.UintSet) private _userSubscriptions;
    mapping(uint256 => EnumerableSet.UintSet) private _planSubscriptions;
    
    // Revenue tracking
    mapping(uint256 => uint256) private _agentTotalRevenue;
    mapping(uint256 => uint256) private _agentPlatformRevenue;
    mapping(uint256 => uint256) private _platformTotalRevenue;
    
    // Active subscription tracking
    EnumerableSet.UintSet private _activeSubscriptionIds;
    
    // Configuration
    uint256 public gracePeriod = 3 days;
    uint256 public defaultPlatformFee = 0; // 0% initially, in basis points (100 = 1%)
    address public platformFeeCollector;
    
    /// @notice M3：存量订阅是否已完成一次性导入（导入后不可再调用）
    bool public subscriptionsImported;
    
    /// @notice P1.7：存量计划是否已完成一次性导入（导入后不可再调用）
    bool public plansImported;
    
    // Events
    event PlanCreated(
        uint256 indexed planId,
        uint256 indexed agentId,
        string name,
        PlanType planType,
        address token,
        uint256 subscriptionPrice,
        uint256 usagePrice,
        BillingPeriod billingPeriod,
        uint256 platformFeePercentage
    );
    
    event PlanUpdated(
        uint256 indexed planId,
        uint256 indexed agentId,
        string name,
        uint256 subscriptionPrice,
        uint256 usagePrice,
        BillingPeriod billingPeriod
    );
    
    event PlanDeactivated(
        uint256 indexed planId,
        uint256 indexed agentId,
        address deactivatedBy,
        uint256 deactivatedAt
    );
    
    event SubscriptionCreated(
        uint256 indexed subscriptionId,
        uint256 indexed planId,
        uint256 indexed agentId,
        address subscriber,
        PlanType planType,
        uint256 startDate,
        uint256 nextBillingDate
    );
    
    event SubscriptionRenewed(
        uint256 indexed subscriptionId,
        uint256 indexed planId,
        address subscriber,
        uint256 amount,
        uint256 nextBillingDate
    );
    
    event SubscriptionCancelled(
        uint256 indexed subscriptionId,
        uint256 indexed planId,
        address subscriber,
        uint256 cancelledAt
    );
    
    event PaymentProcessed(
        uint256 indexed subscriptionId,
        uint256 indexed planId,
        address subscriber,
        address token,
        uint256 amount,
        uint256 platformFee,
        uint256 agentAmount,
        uint256 processedAt
    );
    
    event UsageRecorded(
        uint256 indexed subscriptionId,
        uint256 indexed planId,
        address subscriber,
        uint256 usage,
        uint256 remainingUsage,
        uint256 amount,
        uint256 recordedAt
    );
    
    event PlatformFeeUpdated(
        uint256 indexed agentId,
        uint256 oldFee,
        uint256 newFee,
        address updatedBy,
        uint256 updatedAt
    );
    
    event IdentityRegistryUpdated(address indexed previous, address indexed current);
    
    event SubscriptionsImported(uint256 count);
    
    event PlansImported(uint256 count);
    
    // Custom errors
    error SubscriptionManager__InvalidAgent();
    error SubscriptionManager__InvalidPlan();
    error SubscriptionManager__InvalidAmount();
    error SubscriptionManager__PlanNotActive();
    error SubscriptionManager__SubscriptionNotFound();
    error SubscriptionManager__NotAuthorized();
    error SubscriptionManager__InvalidStatus();
    error SubscriptionManager__PaymentFailed();
    error SubscriptionManager__UsageLimitExceeded();
    error SubscriptionManager__PlanHasActiveSubscriptions();
    error SubscriptionManager__InvalidPagination();
    error SubscriptionManager__InvalidPlanType();
    error SubscriptionManager__InsufficientUsage();
    error SubscriptionManager__InvalidPaymentMethod();
    error SubscriptionManager__InvalidToken();
    error SubscriptionManager__InvalidSubscriber();
    error SubscriptionManager__AlreadyImported();

    constructor(
        address _identityRegistry,
        address _priceOracle,
        address _feeCollector
    ) Ownable(msg.sender) {
        if (_identityRegistry == address(0) || 
            _priceOracle == address(0) || 
            _feeCollector == address(0)) {
            revert SubscriptionManager__InvalidAgent();
        }
        
        identityRegistry = IERC8004Identity(_identityRegistry);
        erc721Identity = IERC721(_identityRegistry);
        priceOracle = TokenPriceOracle(_priceOracle);
        platformFeeCollector = _feeCollector;
        defaultPlatformFee = 0; // 0% platform fee initially
    }
    
    /// @notice WS4：切换本合约指向的 ERC-8004 identity 注册表（自有 core 或官方部署）
    /// @dev 仅 owner 可调用；不迁移既有数据，切换前须确保 agentId 语义连续
    function setIdentityRegistry(address newIdentityRegistry) external onlyOwner {
        if (newIdentityRegistry == address(0)) revert SubscriptionManager__InvalidAgent();
        address previous = address(identityRegistry);
        identityRegistry = IERC8004Identity(newIdentityRegistry);
        erc721Identity = IERC721(newIdentityRegistry);
        emit IdentityRegistryUpdated(previous, newIdentityRegistry);
    }
    
    /**
     * @dev Create a subscription plan
     */
    function createPlan(
        uint256 agentId,
        string memory name,
        string memory description,
        PlanType planType,
        address token,
        uint256 subscriptionPrice,
        uint256 usagePrice,
        BillingPeriod billingPeriod,
        uint256 maxUsage,
        uint256 totalUsageLimit
    ) external returns (uint256 planId) {
        // Verify agent ownership
        address agentOwner;
        try erc721Identity.ownerOf(agentId) returns (address owner) {
            agentOwner = owner;
        } catch {
            revert SubscriptionManager__InvalidAgent();
        }
        
        if (agentOwner != msg.sender) {
            revert SubscriptionManager__NotAuthorized();
        }
        
        if (bytes(name).length == 0) {
            revert SubscriptionManager__InvalidAmount();
        }
        
        // Validate plan type and prices
        if (planType == PlanType.Subscription) {
            if (subscriptionPrice == 0) {
                revert SubscriptionManager__InvalidAmount();
            }
        } else if (planType == PlanType.UsageBased) {
            if (usagePrice == 0) {
                revert SubscriptionManager__InvalidAmount();
            }
        } else if (planType == PlanType.Hybrid) {
            if (subscriptionPrice == 0 || usagePrice == 0) {
                revert SubscriptionManager__InvalidAmount();
            }
        }
        
        // Validate token
        if (token != address(0) && !priceOracle.isTokenSupported(token)) {
            revert SubscriptionManager__InvalidToken();
        }
        
        _planCounter++;
        planId = _planCounter;
        
        SubscriptionPlan memory newPlan = SubscriptionPlan({
            planId: planId,
            agentId: agentId,
            name: name,
            description: description,
            planType: planType,
            token: token,
            subscriptionPrice: subscriptionPrice,
            usagePrice: usagePrice,
            billingPeriod: billingPeriod,
            maxUsage: maxUsage,
            totalUsageLimit: totalUsageLimit,
            isActive: true,
            createdAt: block.timestamp,
            platformFeePercentage: defaultPlatformFee
        });
        
        _subscriptionPlans[planId] = newPlan;
        _agentPlans[agentId].add(planId);
        
        emit PlanCreated(
            planId, 
            agentId, 
            name, 
            planType, 
            token, 
            subscriptionPrice, 
            usagePrice, 
            billingPeriod,
            defaultPlatformFee
        );
        return planId;
    }
    
    /**
     * @dev P1.7：一次性导入存量计划（平台非 agent owner，无法代发 createPlan）
     *      仅 owner 可调用且仅可执行一次；planId 自增分配，其余字段原样落库。
     */
    function importPlans(ImportedPlan[] calldata items)
        external
        onlyOwner
        nonReentrant
        returns (uint256 imported)
    {
        if (plansImported) {
            revert SubscriptionManager__AlreadyImported();
        }
        
        for (uint256 i = 0; i < items.length; i++) {
            ImportedPlan calldata item = items[i];
            
            // agentId 必须存在（迁移后为 canonical id）
            try erc721Identity.ownerOf(item.agentId) returns (address) {} catch {
                revert SubscriptionManager__InvalidAgent();
            }
            
            if (bytes(item.name).length == 0) {
                revert SubscriptionManager__InvalidAmount();
            }
            if (item.platformFeePercentage > 10000) {
                revert SubscriptionManager__InvalidAmount();
            }
            
            // 与 createPlan 相同的计划类型/价格校验
            if (item.planType == PlanType.Subscription) {
                if (item.subscriptionPrice == 0) revert SubscriptionManager__InvalidAmount();
            } else if (item.planType == PlanType.UsageBased) {
                if (item.usagePrice == 0) revert SubscriptionManager__InvalidAmount();
            } else {
                if (item.subscriptionPrice == 0 || item.usagePrice == 0) {
                    revert SubscriptionManager__InvalidAmount();
                }
            }
            
            if (item.token != address(0) && !priceOracle.isTokenSupported(item.token)) {
                revert SubscriptionManager__InvalidToken();
            }
            
            uint256 planId = ++_planCounter;
            
            _subscriptionPlans[planId] = SubscriptionPlan({
                planId: planId,
                agentId: item.agentId,
                name: item.name,
                description: item.description,
                planType: item.planType,
                token: item.token,
                subscriptionPrice: item.subscriptionPrice,
                usagePrice: item.usagePrice,
                billingPeriod: item.billingPeriod,
                maxUsage: item.maxUsage,
                totalUsageLimit: item.totalUsageLimit,
                isActive: item.isActive,
                createdAt: item.createdAt == 0 ? block.timestamp : item.createdAt,
                platformFeePercentage: item.platformFeePercentage
            });
            
            _agentPlans[item.agentId].add(planId);
            
            emit PlanCreated(
                planId,
                item.agentId,
                item.name,
                item.planType,
                item.token,
                item.subscriptionPrice,
                item.usagePrice,
                item.billingPeriod,
                item.platformFeePercentage
            );
            
            imported++;
        }
        
        plansImported = true;
        emit PlansImported(imported);
    }
    
    /**
     * @dev Subscribe to a plan (with initial payment)
     */
    function subscribe(uint256 planId) external payable nonReentrant returns (uint256 subscriptionId) {
        SubscriptionPlan memory plan = _subscriptionPlans[planId];
        
        if (plan.planId == 0) {
            revert SubscriptionManager__InvalidPlan();
        }
        
        if (!plan.isActive) {
            revert SubscriptionManager__PlanNotActive();
        }
        
        // Check if user already has an active subscription for this agent
        bool hasActiveSubscription = false;
        uint256[] memory userSubscriptions = _userSubscriptions[msg.sender].values();
        for (uint256 i = 0; i < userSubscriptions.length; i++) {
            Subscription memory existing = _subscriptions[userSubscriptions[i]];
            if (existing.agentId == plan.agentId && 
                existing.status == SubscriptionStatus.Active) {
                hasActiveSubscription = true;
                break;
            }
        }
        
        // Allow multiple subscriptions to same agent for different plans
        // But not the same plan if active
        
        _subscriptionCounter++;
        subscriptionId = _subscriptionCounter;
        
        uint256 nextBillingDate = block.timestamp;
        uint256 remainingUsage = 0;
        
        if (plan.planType == PlanType.Subscription || plan.planType == PlanType.Hybrid) {
            nextBillingDate = _calculateNextBillingDate(block.timestamp, plan.billingPeriod);
        }
        
        if (plan.planType == PlanType.UsageBased || plan.planType == PlanType.Hybrid) {
            remainingUsage = plan.totalUsageLimit;
        }
        
        Subscription memory newSubscription = Subscription({
            subscriptionId: subscriptionId,
            planId: planId,
            agentId: plan.agentId,
            subscriber: msg.sender,
            status: SubscriptionStatus.Active,
            planType: plan.planType,
            startDate: block.timestamp,
            nextBillingDate: nextBillingDate,
            endDate: 0,
            currentPeriodUsage: 0,
            totalUsage: 0,
            remainingUsage: remainingUsage,
            totalPaid: 0,
            createdAt: block.timestamp,
            lastPaymentDate: block.timestamp,
            paymentToken: plan.token
        });
        
        _subscriptions[subscriptionId] = newSubscription;
        _agentSubscriptions[plan.agentId].add(subscriptionId);
        _userSubscriptions[msg.sender].add(subscriptionId);
        _planSubscriptions[planId].add(subscriptionId);
        _activeSubscriptionIds.add(subscriptionId);
        
        // Process initial payment
        uint256 amountToPay = 0;
        
        if (plan.planType == PlanType.Subscription || plan.planType == PlanType.Hybrid) {
            amountToPay = plan.subscriptionPrice;
        }
        
        if (amountToPay > 0) {
            // Fix: Store msg.value in a local variable to pass
            uint256 msgValue = msg.value;
            _processPayment(
                subscriptionId,
                amountToPay,
                plan.token,
                msgValue,  // Fix: Use local variable instead of directly using msg.value
                "Initial subscription payment"
            );
        }
        
        emit SubscriptionCreated(
            subscriptionId,
            planId,
            plan.agentId,
            msg.sender,
            plan.planType,
            block.timestamp,
            nextBillingDate
        );
        
        return subscriptionId;
    }
    
    /**
     * @dev M3：一次性导入存量订阅（按剩余时长与状态原样落库，不触发付款）
     *      仅 owner 可调用且仅可执行一次；agentId / planType / paymentToken 由计划派生。
     *      UsageBased / Hybrid 计划的 remainingUsage 取计划 totalUsageLimit。
     */
    function importSubscriptions(ImportedSubscription[] calldata items)
        external
        onlyOwner
        nonReentrant
        returns (uint256 imported)
    {
        if (subscriptionsImported) {
            revert SubscriptionManager__AlreadyImported();
        }
        
        for (uint256 i = 0; i < items.length; i++) {
            ImportedSubscription calldata item = items[i];
            SubscriptionPlan memory plan = _subscriptionPlans[item.planId];
            
            if (plan.planId == 0) {
                revert SubscriptionManager__InvalidPlan();
            }
            if (item.subscriber == address(0)) {
                revert SubscriptionManager__InvalidSubscriber();
            }
            
            uint256 subscriptionId = ++_subscriptionCounter;
            uint256 remainingUsage = 0;
            if (plan.planType == PlanType.UsageBased || plan.planType == PlanType.Hybrid) {
                remainingUsage = plan.totalUsageLimit;
            }
            
            _subscriptions[subscriptionId] = Subscription({
                subscriptionId: subscriptionId,
                planId: item.planId,
                agentId: plan.agentId,
                subscriber: item.subscriber,
                status: item.status,
                planType: plan.planType,
                startDate: item.startDate,
                nextBillingDate: item.nextBillingDate,
                endDate: item.endDate,
                currentPeriodUsage: 0,
                totalUsage: 0,
                remainingUsage: remainingUsage,
                totalPaid: item.totalPaid,
                createdAt: item.startDate,
                lastPaymentDate: item.startDate,
                paymentToken: plan.token
            });
            
            _agentSubscriptions[plan.agentId].add(subscriptionId);
            _userSubscriptions[item.subscriber].add(subscriptionId);
            _planSubscriptions[item.planId].add(subscriptionId);
            if (item.status == SubscriptionStatus.Active) {
                _activeSubscriptionIds.add(subscriptionId);
            }
            
            emit SubscriptionCreated(
                subscriptionId,
                item.planId,
                plan.agentId,
                item.subscriber,
                plan.planType,
                item.startDate,
                item.nextBillingDate
            );
            
            imported++;
        }
        
        subscriptionsImported = true;
        emit SubscriptionsImported(imported);
    }
    
    /**
     * @dev Record usage for usage-based or hybrid plans
     */
    function recordUsage(
        uint256 subscriptionId,
        uint256 usage,
        string memory /*description*/
    ) external nonReentrant {
        Subscription storage subscription = _subscriptions[subscriptionId];
        
        if (subscription.subscriptionId == 0) {
            revert SubscriptionManager__SubscriptionNotFound();
        }
        
        // Check authorization - only agent owner can record usage
        address agentOwner;
        try erc721Identity.ownerOf(subscription.agentId) returns (address owner) {
            agentOwner = owner;
        } catch {
            revert SubscriptionManager__InvalidAgent();
        }
        
        if (agentOwner != msg.sender) {
            revert SubscriptionManager__NotAuthorized();
        }
        
        if (subscription.status != SubscriptionStatus.Active) {
            revert SubscriptionManager__InvalidStatus();
        }
        
        SubscriptionPlan memory plan = _subscriptionPlans[subscription.planId];
        
        // Check plan type supports usage-based billing
        if (plan.planType != PlanType.UsageBased && plan.planType != PlanType.Hybrid) {
            revert SubscriptionManager__InvalidPlanType();
        }
        
        // Check usage limits
        if (plan.maxUsage > 0 && subscription.currentPeriodUsage + usage > plan.maxUsage) {
            revert SubscriptionManager__UsageLimitExceeded();
        }
        
        if (plan.totalUsageLimit > 0 && subscription.remainingUsage < usage) {
            revert SubscriptionManager__InsufficientUsage();
        }
        
        // 用量计费：本合约不再做代扣，按次结算由 x402 / 链下账单完成；
        // 这里只更新链上用量与额度，供订阅状态与前台展示使用。
        uint256 usageAmount = usage * plan.usagePrice;
        
        // Update usage
        subscription.currentPeriodUsage += usage;
        subscription.totalUsage += usage;
        
        if (plan.totalUsageLimit > 0) {
            subscription.remainingUsage -= usage;
            
            // Check if usage limit reached
            if (subscription.remainingUsage == 0) {
                subscription.status = SubscriptionStatus.Expired;
                subscription.endDate = block.timestamp;
                _activeSubscriptionIds.remove(subscriptionId);
            }
        }
        
        emit UsageRecorded(
            subscriptionId,
            subscription.planId,
            subscription.subscriber,
            usage,
            subscription.remainingUsage,
            usageAmount,
            block.timestamp
        );
    }
    
    /**
     * @dev Internal function to process payment (for manual payments)
     */
    function _processPayment(
        uint256 subscriptionId,
        uint256 amount,
        address token,
        uint256 msgValue, // Use the passed parameter
        string memory /*description*/ // Remove unused parameter name to avoid warning
    ) internal {
        Subscription storage subscription = _subscriptions[subscriptionId];
        SubscriptionPlan memory plan = _subscriptionPlans[subscription.planId];
        
        address agentOwner = erc721Identity.ownerOf(subscription.agentId);
        
        uint256 platformFee = (amount * plan.platformFeePercentage) / 10000;
        uint256 agentAmount = amount - platformFee;
        
        if (token == address(0)) {
            // Native token payment
            if (msgValue != amount) { // Use the passed msgValue parameter
                revert SubscriptionManager__InvalidAmount();
            }
            
            // Transfer to agent owner
            (bool successAgent, ) = agentOwner.call{value: agentAmount}("");
            if (!successAgent) {
                subscription.status = SubscriptionStatus.PaymentFailed;
                revert SubscriptionManager__PaymentFailed();
            }
            
            // Transfer platform fee
            if (platformFee > 0) {
                (bool successPlatform, ) = platformFeeCollector.call{value: platformFee}("");
                if (!successPlatform) {
                    subscription.status = SubscriptionStatus.PaymentFailed;
                    revert SubscriptionManager__PaymentFailed();
                }
            }
        } else {
            // ERC20 token payment
            if (msgValue > 0) { // Use the passed msgValue parameter
                revert SubscriptionManager__InvalidAmount();
            }
            
            // Transfer from user to agent owner
            bool successAgent = IERC20(token).transferFrom(msg.sender, agentOwner, agentAmount);
            if (!successAgent) {
                subscription.status = SubscriptionStatus.PaymentFailed;
                revert SubscriptionManager__PaymentFailed();
            }
            
            // Transfer platform fee
            if (platformFee > 0) {
                bool successPlatform = IERC20(token).transferFrom(msg.sender, platformFeeCollector, platformFee);
                if (!successPlatform) {
                    subscription.status = SubscriptionStatus.PaymentFailed;
                    revert SubscriptionManager__PaymentFailed();
                }
            }
        }
        
        subscription.totalPaid += amount;
        subscription.lastPaymentDate = block.timestamp;
        
        // Update revenue tracking
        _agentTotalRevenue[subscription.agentId] += agentAmount;
        _agentPlatformRevenue[subscription.agentId] += platformFee;
        _platformTotalRevenue[subscription.agentId] += platformFee;
        
        emit PaymentProcessed(
            subscriptionId,
            subscription.planId,
            subscription.subscriber,
            token,
            amount,
            platformFee,
            agentAmount,
            block.timestamp
        );
    }
    
    /**
     * @dev Cancel subscription
     */
    function cancelSubscription(uint256 subscriptionId) external {
        Subscription storage subscription = _subscriptions[subscriptionId];
        
        if (subscription.subscriptionId == 0) {
            revert SubscriptionManager__SubscriptionNotFound();
        }
        
        if (subscription.subscriber != msg.sender) {
            revert SubscriptionManager__NotAuthorized();
        }
        
        if (subscription.status != SubscriptionStatus.Active) {
            revert SubscriptionManager__InvalidStatus();
        }
        
        subscription.status = SubscriptionStatus.Cancelled;
        subscription.endDate = block.timestamp;
        
        _activeSubscriptionIds.remove(subscriptionId);
        
        emit SubscriptionCancelled(subscriptionId, subscription.planId, subscription.subscriber, block.timestamp);
    }
    
    /**
     * @dev Update a subscription plan
     */
    function updatePlan(
        uint256 planId,
        string memory name,
        string memory description,
        uint256 subscriptionPrice,
        uint256 usagePrice,
        BillingPeriod billingPeriod,
        uint256 maxUsage,
        uint256 totalUsageLimit
    ) external {
        SubscriptionPlan storage plan = _subscriptionPlans[planId];
        
        if (plan.planId == 0) {
            revert SubscriptionManager__InvalidPlan();
        }
        
        address agentOwner;
        try erc721Identity.ownerOf(plan.agentId) returns (address owner) {
            agentOwner = owner;
        } catch {
            revert SubscriptionManager__InvalidAgent();
        }
        
        if (agentOwner != msg.sender) {
            revert SubscriptionManager__NotAuthorized();
        }
        
        plan.name = name;
        plan.description = description;
        plan.subscriptionPrice = subscriptionPrice;
        plan.usagePrice = usagePrice;
        plan.billingPeriod = billingPeriod;
        plan.maxUsage = maxUsage;
        plan.totalUsageLimit = totalUsageLimit;
        
        emit PlanUpdated(planId, plan.agentId, name, subscriptionPrice, usagePrice, billingPeriod);
    }
    
    /**
     * @dev Deactivate a subscription plan
     */
    function deactivatePlan(uint256 planId) external {
        SubscriptionPlan storage plan = _subscriptionPlans[planId];
        
        if (plan.planId == 0) {
            revert SubscriptionManager__InvalidPlan();
        }
        
        address agentOwner;
        try erc721Identity.ownerOf(plan.agentId) returns (address owner) {
            agentOwner = owner;
        } catch {
            revert SubscriptionManager__InvalidAgent();
        }
        
        if (agentOwner != msg.sender) {
            revert SubscriptionManager__NotAuthorized();
        }
        
        // Check if there are active subscriptions
        uint256 activeCount = 0;
        uint256[] memory subscriptionIds = _planSubscriptions[planId].values();
        for (uint256 i = 0; i < subscriptionIds.length; i++) {
            Subscription memory subscription = _subscriptions[subscriptionIds[i]];
            if (subscription.status == SubscriptionStatus.Active) {
                activeCount++;
            }
        }
        
        if (activeCount > 0) {
            revert SubscriptionManager__PlanHasActiveSubscriptions();
        }
        
        plan.isActive = false;
        
        emit PlanDeactivated(planId, plan.agentId, msg.sender, block.timestamp);
    }
    
    /**
     * @dev Set platform fee percentage for an agent
     */
    function setAgentPlatformFee(uint256 agentId, uint256 feePercentage) external onlyOwner {
        if (feePercentage > 10000) { // Max 100%
            revert SubscriptionManager__InvalidAmount();
        }
        
        // Get all plans for this agent
        uint256[] memory planIds = _agentPlans[agentId].values();
        
        for (uint256 i = 0; i < planIds.length; i++) {
            SubscriptionPlan storage plan = _subscriptionPlans[planIds[i]];
            uint256 oldFee = plan.platformFeePercentage;
            plan.platformFeePercentage = feePercentage;
            
            emit PlatformFeeUpdated(agentId, oldFee, feePercentage, msg.sender, block.timestamp);
        }
    }
    
    /**
     * @dev Calculate next billing date
     */
    function _calculateNextBillingDate(uint256 currentDate, BillingPeriod period) internal pure returns (uint256) {
        if (period == BillingPeriod.Daily) {
            return currentDate + 1 days;
        } else if (period == BillingPeriod.Weekly) {
            return currentDate + 7 days;
        } else if (period == BillingPeriod.Monthly) {
            return currentDate + 30 days;
        } else if (period == BillingPeriod.Quarterly) {
            return currentDate + 90 days;
        } else if (period == BillingPeriod.Yearly) {
            return currentDate + 365 days;
        }
        return currentDate + 30 days;
    }
    
    /**
     * @dev Get subscriptions due for renewal
     */
    function getDueSubscriptions() external view returns (uint256[] memory) {
        uint256 count = 0;
        uint256[] memory allSubscriptionIds = _activeSubscriptionIds.values();
        
        // First pass: count due subscriptions
        for (uint256 i = 0; i < allSubscriptionIds.length; i++) {
            Subscription memory subscription = _subscriptions[allSubscriptionIds[i]];
            if (subscription.status == SubscriptionStatus.Active && 
                subscription.planType != PlanType.UsageBased &&
                block.timestamp >= subscription.nextBillingDate) {
                count++;
            }
        }
        
        uint256[] memory dueSubscriptions = new uint256[](count);
        uint256 index = 0;
        
        // Second pass: collect due subscription IDs
        for (uint256 i = 0; i < allSubscriptionIds.length; i++) {
            Subscription memory subscription = _subscriptions[allSubscriptionIds[i]];
            if (subscription.status == SubscriptionStatus.Active && 
                subscription.planType != PlanType.UsageBased &&
                block.timestamp >= subscription.nextBillingDate) {
                dueSubscriptions[index] = allSubscriptionIds[i];
                index++;
            }
        }
        
        return dueSubscriptions;
    }
    
    /**
     * @dev Check if subscription is active and paid
     */
    function isSubscriptionActive(uint256 subscriptionId) external view returns (bool) {
        Subscription memory subscription = _subscriptions[subscriptionId];
        
        if (subscription.subscriptionId == 0) {
            return false;
        }
        
        if (subscription.status != SubscriptionStatus.Active) {
            return false;
        }
        
        // For subscription-based plans, check if payment is due
        if (subscription.planType == PlanType.Subscription || subscription.planType == PlanType.Hybrid) {
            if (block.timestamp > subscription.nextBillingDate + gracePeriod) {
                return false;
            }
        }
        
        // For usage-based plans, check if there's remaining usage
        if (subscription.planType == PlanType.UsageBased || subscription.planType == PlanType.Hybrid) {
            SubscriptionPlan memory plan = _subscriptionPlans[subscription.planId];
            if (plan.totalUsageLimit > 0 && subscription.remainingUsage == 0) {
                return false;
            }
        }
        
        return true;
    }
    
    /**
     * @dev Get subscription plan
     */
    function getPlan(uint256 planId) external view returns (SubscriptionPlan memory) {
        SubscriptionPlan memory plan = _subscriptionPlans[planId];
        if (plan.planId == 0) {
            revert SubscriptionManager__InvalidPlan();
        }
        return plan;
    }
    
    /**
     * @dev Get subscription
     */
    function getSubscription(uint256 subscriptionId) external view returns (Subscription memory) {
        Subscription memory subscription = _subscriptions[subscriptionId];
        if (subscription.subscriptionId == 0) {
            revert SubscriptionManager__SubscriptionNotFound();
        }
        return subscription;
    }
    
    /**
     * @dev Get agent plans
     */
    function getAgentPlans(uint256 agentId) external view returns (SubscriptionPlan[] memory) {
        uint256[] memory planIds = _agentPlans[agentId].values();
        SubscriptionPlan[] memory plans = new SubscriptionPlan[](planIds.length);
        
        for (uint256 i = 0; i < planIds.length; i++) {
            plans[i] = _subscriptionPlans[planIds[i]];
        }
        
        return plans;
    }
    
    /**
     * @dev Get user subscriptions
     */
    function getUserSubscriptions(address user) external view returns (Subscription[] memory) {
        uint256[] memory subscriptionIds = _userSubscriptions[user].values();
        Subscription[] memory subscriptions = new Subscription[](subscriptionIds.length);
        
        for (uint256 i = 0; i < subscriptionIds.length; i++) {
            subscriptions[i] = _subscriptions[subscriptionIds[i]];
        }
        
        return subscriptions;
    }
    
    /**
     * @dev Get active subscriptions for an agent
     */
    function getActiveSubscriptionsForAgent(uint256 agentId) external view returns (uint256[] memory) {
        uint256[] memory subscriptionIds = _agentSubscriptions[agentId].values();
        uint256 activeCount = 0;
        
        // First pass: count active subscriptions
        for (uint256 i = 0; i < subscriptionIds.length; i++) {
            Subscription memory subscription = _subscriptions[subscriptionIds[i]];
            if (subscription.status == SubscriptionStatus.Active) {
                activeCount++;
            }
        }
        
        uint256[] memory activeSubscriptions = new uint256[](activeCount);
        uint256 index = 0;
        
        // Second pass: collect active subscription IDs
        for (uint256 i = 0; i < subscriptionIds.length; i++) {
            Subscription memory subscription = _subscriptions[subscriptionIds[i]];
            if (subscription.status == SubscriptionStatus.Active) {
                activeSubscriptions[index] = subscriptionIds[i];
                index++;
            }
        }
        
        return activeSubscriptions;
    }
    
    /**
     * @dev Get total revenue for an agent
     */
    function getAgentTotalRevenue(uint256 agentId) external view returns (uint256) {
        return _agentTotalRevenue[agentId];
    }
    
    /**
     * @dev Get platform revenue for an agent
     */
    function getAgentPlatformRevenue(uint256 agentId) external view returns (uint256) {
        return _agentPlatformRevenue[agentId];
    }
    
    /**
     * @dev Get subscription usage
     */
    function getSubscriptionUsage(uint256 subscriptionId) external view returns (
        uint256 currentPeriodUsage,
        uint256 totalUsage,
        uint256 remainingUsage,
        uint256 maxUsage,
        uint256 totalUsageLimit
    ) {
        Subscription memory subscription = _subscriptions[subscriptionId];
        if (subscription.subscriptionId == 0) {
            revert SubscriptionManager__SubscriptionNotFound();
        }
        
        SubscriptionPlan memory plan = _subscriptionPlans[subscription.planId];
        
        currentPeriodUsage = subscription.currentPeriodUsage;
        totalUsage = subscription.totalUsage;
        remainingUsage = subscription.remainingUsage;
        maxUsage = plan.maxUsage;
        totalUsageLimit = plan.totalUsageLimit;
    }
    
    /**
     * @dev Get all active subscriptions with pagination
     */
    function getAllActiveSubscriptionsPaginated(
        uint256 page, 
        uint256 limit
    ) external view returns (uint256[] memory activeSubscriptions, uint256 totalActive) {
        if (page == 0 || limit == 0) {
            revert SubscriptionManager__InvalidPagination();
        }
        
        totalActive = _activeSubscriptionIds.length();
        uint256 start = (page - 1) * limit;
        uint256 end = start + limit;
        
        if (start >= totalActive) {
            return (new uint256[](0), totalActive);
        }
        
        if (end > totalActive) {
            end = totalActive;
        }
        
        uint256 resultSize = end - start;
        activeSubscriptions = new uint256[](resultSize);
        uint256[] memory allIds = _activeSubscriptionIds.values();
        
        for (uint256 i = 0; i < resultSize; i++) {
            activeSubscriptions[i] = allIds[start + i];
        }
        
        return (activeSubscriptions, totalActive);
    }
    
    /**
     * @dev Update grace period
     */
    function setGracePeriod(uint256 newGracePeriod) external onlyOwner {
        gracePeriod = newGracePeriod;
    }
    
    /**
     * @dev Update platform fee collector
     */
    function setPlatformFeeCollector(address newCollector) external onlyOwner {
        if (newCollector == address(0)) {
            revert SubscriptionManager__InvalidAgent();
        }
        platformFeeCollector = newCollector;
    }
    
    /**
     * @dev Update default platform fee
     */
    function setDefaultPlatformFee(uint256 newFee) external onlyOwner {
        if (newFee > 10000) { // Max 100%
            revert SubscriptionManager__InvalidAmount();
        }
        defaultPlatformFee = newFee;
    }
    
    /**
     * @dev Get total plan count
     */
    function getTotalPlanCount() external view returns (uint256) {
        return _planCounter;
    }
    
    /**
     * @dev Get total subscription count
     */
    function getTotalSubscriptionCount() external view returns (uint256) {
        return _subscriptionCounter;
    }
    
    /**
     * @dev Get agent subscription count
     */
    function getAgentSubscriptionCount(uint256 agentId) external view returns (uint256) {
        return _agentSubscriptions[agentId].length();
    }
    
    /**
     * @dev Get agent active subscription count
     */
    function getAgentActiveSubscriptionCount(uint256 agentId) external view returns (uint256) {
        uint256 count = 0;
        uint256[] memory subscriptionIds = _agentSubscriptions[agentId].values();
        
        for (uint256 i = 0; i < subscriptionIds.length; i++) {
            if (_subscriptions[subscriptionIds[i]].status == SubscriptionStatus.Active) {
                count++;
            }
        }
        
        return count;
    }
    
    /**
     * @dev Get platform total revenue
     */
    function getPlatformTotalRevenue(uint256 agentId) external view returns (uint256) {
        return _platformTotalRevenue[agentId];
    }
}
