// contracts/extensions/PaymentGateway.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../erc8004-interfaces/IERC8004Identity.sol";
import "./AgentWallet.sol";
import "./SubscriptionManager.sol";
import "./TokenPriceOracle.sol";

/**
 * @title PaymentGateway
 * @dev Unified payment processing for AI Agent services with support for all payment types
 * @notice Production-ready payment gateway that integrates with AgentWallet and SubscriptionManager
 */
contract PaymentGateway is Ownable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;
    
    IERC8004Identity public immutable identityRegistry;
    IERC721 public immutable erc721Identity;
    AgentWallet public immutable agentWallet;
    SubscriptionManager public immutable subscriptionManager;
    TokenPriceOracle public priceOracle;
    
    enum PaymentType {
        Subscription,
        Usage,
        OneTime,
        Escrow
    }
    
    enum PaymentStatus {
        Pending,
        Processing,
        Completed,
        Refunded,
        Failed,
        Cancelled,
        Disputed,
        Settled
    }
    
    struct UnifiedPayment {
        uint256 paymentId;
        uint256 agentId;
        address client;
        address token;
        uint256 amount;
        uint256 platformFee;
        uint256 agentAmount;
        PaymentType paymentType;
        PaymentStatus status;
        string serviceDescription;
        uint256 referenceId; // subscriptionId, taskId, etc.
        uint256 createdAt;
        uint256 completedAt;
        uint256 escrowReleaseTime;
        bool isEscrowed;
        bool autoDebitEnabled;
        uint256 autoDebitAuthorizationId;
    }
    
    struct Dispute {
        uint256 disputeId;
        uint256 paymentId;
        address raisedBy;
        string reason;
        uint256 raisedAt;
        bool resolved;
        address resolver;
        uint256 resolvedAt;
        bool refundApproved;
    }
    
    struct PaymentMethod {
        address token;
        bool isSupported;
        uint256 minAmount;
        uint256 maxAmount;
        bool autoDebitEnabled;
    }
    
    // Storage
    uint256 private _paymentCounter;
    uint256 private _disputeCounter;
    uint256 private _authorizationCounter;
    
    mapping(uint256 => UnifiedPayment) private _payments;
    mapping(uint256 => Dispute) private _disputes;
    mapping(uint256 => uint256[]) private _agentPayments;
    mapping(address => uint256[]) private _clientPayments;
    mapping(address => uint256[]) private _agentEarnings;
    mapping(uint256 => uint256[]) private _subscriptionPayments;
    mapping(address => PaymentMethod[]) private _userPaymentMethods;
    
    // Auto-debit authorizations
    mapping(address => mapping(uint256 => bool)) private _userAuthorizations;
    mapping(address => uint256[]) private _userAuthorizationIds;
    
    // Supported tokens for auto-debit
    EnumerableSet.AddressSet private _supportedAutoDebitTokens;
    
    // Configuration
    uint256 public escrowPeriod = 7 days;
    uint256 public platformFeePercentage = 0; // 0% initially, in basis points (100 = 1%)
    address public platformFeeCollector;
    uint256 public minPaymentAmount = 0;
    uint256 public maxPaymentAmount = type(uint256).max;
    uint256 public gracePeriod = 2 days;
    uint256 public disputeResolutionPeriod = 14 days;
    
    // Events
    event PaymentInitiated(
        uint256 indexed paymentId,
        uint256 indexed agentId,
        address indexed client,
        address token,
        uint256 amount,
        PaymentType paymentType,
        uint256 referenceId,
        string serviceDescription,
        bool autoDebit,
        bool isEscrowed
    );
    
    event PaymentCompleted(
        uint256 indexed paymentId,
        uint256 indexed agentId,
        address client,
        address token,
        uint256 amount,
        uint256 platformFee,
        uint256 agentAmount,
        uint256 completedAt
    );
    
    event PaymentRefunded(
        uint256 indexed paymentId,
        uint256 indexed agentId,
        address client,
        address token,
        uint256 amount,
        uint256 refundedAt
    );
    
    event PaymentFailed(
        uint256 indexed paymentId,
        uint256 indexed agentId,
        address client,
        string reason,
        uint256 failedAt
    );
    
    event AutoDebitPayment(
        uint256 indexed paymentId,
        address indexed client,
        uint256 authorizationId,
        address token,
        uint256 amount,
        uint256 processedAt
    );
    
    event AutoDebitAuthorizationCreated(
        address indexed user,
        uint256 indexed authorizationId,
        address token,
        uint256 maxAmount,
        uint256 expiresAt
    );
    
    event AutoDebitAuthorizationRevoked(
        address indexed user,
        uint256 indexed authorizationId
    );
    
    event DisputeRaised(
        uint256 indexed disputeId,
        uint256 indexed paymentId,
        address raisedBy,
        string reason,
        uint256 raisedAt
    );
    
    event DisputeResolved(
        uint256 indexed disputeId,
        uint256 indexed paymentId,
        address resolver,
        bool refundApproved,
        uint256 resolvedAt
    );
    
    event EscrowReleased(
        uint256 indexed paymentId,
        uint256 indexed agentId,
        address token,
        uint256 amount,
        uint256 releasedAt
    );
    
    event PlatformFeeUpdated(
        uint256 oldFee,
        uint256 newFee,
        address updatedBy,
        uint256 updatedAt
    );
    
    event PaymentMethodAdded(
        address indexed user,
        address token,
        uint256 minAmount,
        uint256 maxAmount,
        bool autoDebitEnabled
    );
    
    event PaymentMethodRemoved(
        address indexed user,
        address token
    );
    
    // Custom errors
    error PaymentGateway__InvalidAgent();
    error PaymentGateway__InvalidAmount();
    error PaymentGateway__InvalidToken();
    error PaymentGateway__PaymentNotFound();
    error PaymentGateway__NotAuthorized();
    error PaymentGateway__InvalidStatus();
    error PaymentGateway__TransferFailed();
    error PaymentGateway__DisputeNotFound();
    error PaymentGateway__DisputeAlreadyResolved();
    error PaymentGateway__PaymentAlreadyProcessed();
    error PaymentGateway__InvalidPaymentType();
    error PaymentGateway__InsufficientBalance();
    error PaymentGateway__AutoDebitNotAuthorized();
    error PaymentGateway__AutoDebitAuthorizationExpired();
    error PaymentGateway__AutoDebitAuthorizationInsufficient();
    error PaymentGateway__UnsupportedToken();
    error PaymentGateway__InvalidReference();
    error PaymentGateway__SubscriptionNotActive();

    constructor(
        address _identityRegistry,
        address _agentWallet,
        address _subscriptionManager,
        address _priceOracle,
        address _feeCollector
    ) Ownable(msg.sender) {
        if (_identityRegistry == address(0) || 
            _agentWallet == address(0) || 
            _subscriptionManager == address(0) || 
            _priceOracle == address(0) || 
            _feeCollector == address(0)) {
            revert PaymentGateway__InvalidAgent();
        }
        
        identityRegistry = IERC8004Identity(_identityRegistry);
        erc721Identity = IERC721(_identityRegistry);
        agentWallet = AgentWallet(_agentWallet);
        subscriptionManager = SubscriptionManager(_subscriptionManager);
        priceOracle = TokenPriceOracle(_priceOracle);
        platformFeeCollector = _feeCollector;
        platformFeePercentage = 0; // 0% platform fee initially
    }
    
    /**
     * @dev Initiate a payment for any type (one-time, subscription, usage, escrow)
     */
    function initiatePayment(
        uint256 agentId,
        address token,
        uint256 amount,
        PaymentType paymentType,
        uint256 referenceId,
        string memory serviceDescription,
        bool useEscrow,
        bool useAutoDebit
    ) public payable nonReentrant returns (uint256 paymentId) {
        // Validate agent exists
        if (!identityRegistry.agentExists(agentId)) {
            revert PaymentGateway__InvalidAgent();
        }
        
        // Validate amount
        if (amount < minPaymentAmount || amount > maxPaymentAmount) {
            revert PaymentGateway__InvalidAmount();
        }
        
        // Validate token
        if (token != address(0) && !priceOracle.isTokenSupported(token)) {
            revert PaymentGateway__InvalidToken();
        }
        
        // Validate payment type
        if (paymentType == PaymentType.Subscription) {
            // Check subscription is active
            bool isActive = subscriptionManager.isSubscriptionActive(referenceId);
            if (!isActive) {
                revert PaymentGateway__SubscriptionNotActive();
            }
        }
        
        _paymentCounter++;
        paymentId = _paymentCounter;
        
        // Calculate platform fee
        uint256 platformFee = (amount * platformFeePercentage) / 10000;
        uint256 agentAmount = amount - platformFee;
        
        uint256 escrowReleaseTime = useEscrow ? block.timestamp + escrowPeriod : 0;
        uint256 autoDebitAuthorizationId = 0;
        
        // Check if auto-debit is requested
        if (useAutoDebit) {
            // User must have authorized auto-debit for this token
            bool isAuthorized = _checkAutoDebitAuthorization(msg.sender, token, amount);
            if (!isAuthorized) {
                revert PaymentGateway__AutoDebitNotAuthorized();
            }
            
            // Get or create authorization ID
            autoDebitAuthorizationId = _getOrCreateAuthorizationId(msg.sender, token, amount);
        }
        
        UnifiedPayment memory newPayment = UnifiedPayment({
            paymentId: paymentId,
            agentId: agentId,
            client: msg.sender,
            token: token,
            amount: amount,
            platformFee: platformFee,
            agentAmount: agentAmount,
            paymentType: paymentType,
            status: PaymentStatus.Pending,
            serviceDescription: serviceDescription,
            referenceId: referenceId,
            createdAt: block.timestamp,
            completedAt: 0,
            escrowReleaseTime: escrowReleaseTime,
            isEscrowed: useEscrow,
            autoDebitEnabled: useAutoDebit,
            autoDebitAuthorizationId: autoDebitAuthorizationId
        });
        
        _payments[paymentId] = newPayment;
        _agentPayments[agentId].push(paymentId);
        _clientPayments[msg.sender].push(paymentId);
        
        if (paymentType == PaymentType.Subscription) {
            _subscriptionPayments[referenceId].push(paymentId);
        }
        
        // Process payment based on type
        if (useAutoDebit) {
            // Try auto-debit first
            bool autoDebitSuccess = _processAutoDebit(paymentId);
            
            if (!autoDebitSuccess) {
                // If auto-debit fails, mark as pending for manual payment
                newPayment.status = PaymentStatus.Pending;
                newPayment.autoDebitEnabled = false;
                _payments[paymentId] = newPayment;
            }
        } else if (!useEscrow) {
            // Direct payment (non-escrow)
            _processDirectPayment(paymentId, msg.value);
        }
        // For escrow payments, status remains Pending until completion
        
        emit PaymentInitiated(
            paymentId,
            agentId,
            msg.sender,
            token,
            amount,
            paymentType,
            referenceId,
            serviceDescription,
            useAutoDebit,
            useEscrow
        );
        
        return paymentId;
    }
    
    /**
     * @dev Process payment (for pending payments that weren't auto-debited)
     */
    function processPayment(uint256 paymentId) external payable nonReentrant {
        UnifiedPayment storage payment = _payments[paymentId];
        
        if (payment.paymentId == 0) {
            revert PaymentGateway__PaymentNotFound();
        }
        
        if (payment.client != msg.sender) {
            revert PaymentGateway__NotAuthorized();
        }
        
        if (payment.status != PaymentStatus.Pending) {
            revert PaymentGateway__PaymentAlreadyProcessed();
        }
        
        if (payment.isEscrowed) {
            // For escrow payments, just accept the payment
            _processEscrowPayment(paymentId, msg.value);
        } else {
            // For direct payments, process immediately
            _processDirectPayment(paymentId, msg.value);
        }
    }
    
    /**
     * @dev Complete an escrow payment (called by agent owner or client)
     */
    function completeEscrowPayment(uint256 paymentId) external nonReentrant {
        UnifiedPayment storage payment = _payments[paymentId];
        
        if (payment.paymentId == 0) {
            revert PaymentGateway__PaymentNotFound();
        }
        
        if (!payment.isEscrowed || payment.status != PaymentStatus.Processing) {
            revert PaymentGateway__InvalidStatus();
        }
        
        // Only agent owner or client can complete escrow
        address agentOwner = erc721Identity.ownerOf(payment.agentId);
        if (agentOwner != msg.sender && payment.client != msg.sender) {
            revert PaymentGateway__NotAuthorized();
        }
        
        // Check if escrow period has passed
        if (block.timestamp < payment.escrowReleaseTime) {
            // Early release requires mutual agreement
            if (agentOwner != msg.sender) {
                revert PaymentGateway__NotAuthorized();
            }
        }
        
        payment.status = PaymentStatus.Completed;
        payment.completedAt = block.timestamp;
        
        // Distribute funds
        _distributePayment(paymentId);
        
        emit PaymentCompleted(
            paymentId,
            payment.agentId,
            payment.client,
            payment.token,
            payment.amount,
            payment.platformFee,
            payment.agentAmount,
            block.timestamp
        );
    }
    
    /**
     * @dev Release escrow after timeout
     */
    function releaseEscrow(uint256 paymentId) external nonReentrant {
        UnifiedPayment storage payment = _payments[paymentId];
        
        if (payment.paymentId == 0) {
            revert PaymentGateway__PaymentNotFound();
        }
        
        if (!payment.isEscrowed || payment.status != PaymentStatus.Processing) {
            revert PaymentGateway__InvalidStatus();
        }
        
        if (block.timestamp < payment.escrowReleaseTime) {
            revert PaymentGateway__InvalidStatus();
        }
        
        payment.status = PaymentStatus.Completed;
        payment.completedAt = block.timestamp;
        
        // Distribute funds
        _distributePayment(paymentId);
        
        emit EscrowReleased(paymentId, payment.agentId, payment.token, payment.amount, block.timestamp);
    }
    
    /**
     * @dev Process a one-time payment for A2A usage
     */
    function processA2APayment(
        uint256 agentId,
        address token,
        uint256 amount,
        string memory serviceDescription
    ) external returns (uint256 paymentId) {
        // Check if user has auto-debit authorization
        bool hasAuthorization = _checkAutoDebitAuthorization(msg.sender, token, amount);
        
        if (!hasAuthorization) {
            // User needs to authorize first
            revert PaymentGateway__AutoDebitNotAuthorized();
        }
        
        paymentId = initiatePayment(
            agentId,
            token,
            amount,
            PaymentType.Usage,
            0, // No reference ID for one-time usage
            serviceDescription,
            false, // No escrow for immediate usage
            true // Use auto-debit
        );
        
        return paymentId;
    }
    
    /**
     * @dev Create auto-debit authorization
     */
    function createAutoDebitAuthorization(
        address token,
        uint256 maxAmount,
        uint256 durationInSeconds
    ) external payable returns (uint256 authorizationId) { // Fix: Add payable
        if (token == address(0) && msg.value < maxAmount) {
            // For native token, require deposit
            revert PaymentGateway__InsufficientBalance();
        }
        
        _authorizationCounter++;
        authorizationId = _authorizationCounter;
        
        // Record authorization
        _userAuthorizations[msg.sender][authorizationId] = true;
        _userAuthorizationIds[msg.sender].push(authorizationId);
        
        // Add token to supported auto-debit tokens
        _supportedAutoDebitTokens.add(token);
        
        // If token is native, deposit funds
        if (token == address(0) && msg.value > 0) {
            // Deposit to agent wallet for auto-debit
            agentWallet.depositNativeForUser{value: msg.value}();
        }
        
        emit AutoDebitAuthorizationCreated(
            msg.sender,
            authorizationId,
            token,
            maxAmount,
            block.timestamp + durationInSeconds
        );
        
        return authorizationId;
    }
    
    /**
     * @dev Revoke auto-debit authorization
     */
    function revokeAutoDebitAuthorization(uint256 authorizationId) external {
        if (!_userAuthorizations[msg.sender][authorizationId]) {
            revert PaymentGateway__AutoDebitNotAuthorized();
        }
        
        _userAuthorizations[msg.sender][authorizationId] = false;
        
        emit AutoDebitAuthorizationRevoked(msg.sender, authorizationId);
    }
    
    /**
     * @dev Raise a dispute for a payment
     */
    function raiseDispute(uint256 paymentId, string memory reason) external returns (uint256 disputeId) {
        UnifiedPayment storage payment = _payments[paymentId];
        
        if (payment.paymentId == 0) {
            revert PaymentGateway__PaymentNotFound();
        }
        
        if (payment.client != msg.sender) {
            revert PaymentGateway__NotAuthorized();
        }
        
        if (payment.status != PaymentStatus.Processing && payment.status != PaymentStatus.Completed) {
            revert PaymentGateway__InvalidStatus();
        }
        
        if (!payment.isEscrowed) {
            revert PaymentGateway__InvalidStatus();
        }
        
        _disputeCounter++;
        disputeId = _disputeCounter;
        
        Dispute memory newDispute = Dispute({
            disputeId: disputeId,
            paymentId: paymentId,
            raisedBy: msg.sender,
            reason: reason,
            raisedAt: block.timestamp,
            resolved: false,
            resolver: address(0),
            resolvedAt: 0,
            refundApproved: false
        });
        
        _disputes[disputeId] = newDispute;
        payment.status = PaymentStatus.Disputed;
        
        emit DisputeRaised(disputeId, paymentId, msg.sender, reason, block.timestamp);
        return disputeId;
    }
    
    /**
     * @dev Resolve a dispute
     */
    function resolveDispute(uint256 disputeId, bool refundApproved) external onlyOwner nonReentrant {
        Dispute storage dispute = _disputes[disputeId];
        
        if (dispute.disputeId == 0) {
            revert PaymentGateway__DisputeNotFound();
        }
        
        if (dispute.resolved) {
            revert PaymentGateway__DisputeAlreadyResolved();
        }
        
        UnifiedPayment storage payment = _payments[dispute.paymentId];
        
        dispute.resolved = true;
        dispute.resolver = msg.sender;
        dispute.resolvedAt = block.timestamp;
        dispute.refundApproved = refundApproved;
        
        if (refundApproved) {
            // Refund to client
            payment.status = PaymentStatus.Refunded;
            
            if (payment.token == address(0)) {
                _transferNative(payment.client, payment.amount);
            } else {
                _transferToken(payment.token, payment.client, payment.amount);
            }
            
            emit PaymentRefunded(dispute.paymentId, payment.agentId, payment.client, payment.token, payment.amount, block.timestamp);
        } else {
            // Pay to agent
            payment.status = PaymentStatus.Completed;
            payment.completedAt = block.timestamp;
            
            _distributePayment(dispute.paymentId);
            
            emit PaymentCompleted(
                dispute.paymentId,
                payment.agentId,
                payment.client,
                payment.token,
                payment.amount,
                payment.platformFee,
                payment.agentAmount,
                block.timestamp
            );
        }
        
        emit DisputeResolved(disputeId, dispute.paymentId, msg.sender, refundApproved, block.timestamp);
    }
    
    /**
     * @dev Internal function to process auto-debit
     */
    function _processAutoDebit(uint256 paymentId) internal returns (bool) {
        UnifiedPayment storage payment = _payments[paymentId];
        
        // Check if user has authorized auto-debit
        if (!_userAuthorizations[payment.client][payment.autoDebitAuthorizationId]) {
            return false;
        }
        
        // Try to process payment through agentWallet
        try agentWallet.processAutoDebitPayment(
            payment.client,
            payment.token,
            payment.amount,
            payment.autoDebitAuthorizationId,
            payment.serviceDescription
        ) returns (bool success) {
            if (success) {
                payment.status = payment.isEscrowed ? PaymentStatus.Processing : PaymentStatus.Completed;
                payment.completedAt = block.timestamp;
                
                if (!payment.isEscrowed) {
                    _distributePayment(paymentId);
                }
                
                emit AutoDebitPayment(
                    paymentId,
                    payment.client,
                    payment.autoDebitAuthorizationId,
                    payment.token,
                    payment.amount,
                    block.timestamp
                );
                
                return true;
            }
        } catch {
            // Auto-debit failed
            payment.status = PaymentStatus.Failed;
            
            emit PaymentFailed(
                paymentId,
                payment.agentId,
                payment.client,
                "Auto-debit failed",
                block.timestamp
            );
        }
        
        return false;
    }
    
    /**
     * @dev Internal function to process direct payment
     */
    function _processDirectPayment(uint256 paymentId, uint256 msgValue) internal {
        UnifiedPayment storage payment = _payments[paymentId];
        
        // Process payment
        if (payment.token == address(0)) {
            // Native token payment
            if (msgValue != payment.amount) {
                revert PaymentGateway__InvalidAmount();
            }
            
            payment.status = PaymentStatus.Completed;
            payment.completedAt = block.timestamp;
            
            _distributePayment(paymentId);
        } else {
            // ERC20 token payment
            if (msgValue > 0) {
                revert PaymentGateway__InvalidAmount();
            }
            
            // Transfer tokens from user to contract
            bool success = IERC20(payment.token).transferFrom(payment.client, address(this), payment.amount);
            if (!success) {
                revert PaymentGateway__TransferFailed();
            }
            
            payment.status = PaymentStatus.Completed;
            payment.completedAt = block.timestamp;
            
            _distributePayment(paymentId);
        }
        
        emit PaymentCompleted(
            paymentId,
            payment.agentId,
            payment.client,
            payment.token,
            payment.amount,
            payment.platformFee,
            payment.agentAmount,
            block.timestamp
        );
    }
    
    /**
     * @dev Internal function to process escrow payment
     */
    function _processEscrowPayment(uint256 paymentId, uint256 msgValue) internal {
        UnifiedPayment storage payment = _payments[paymentId];
        
        // Process payment to escrow
        if (payment.token == address(0)) {
            // Native token payment
            if (msgValue != payment.amount) {
                revert PaymentGateway__InvalidAmount();
            }
            
            payment.status = PaymentStatus.Processing;
        } else {
            // ERC20 token payment
            if (msgValue > 0) {
                revert PaymentGateway__InvalidAmount();
            }
            
            // Transfer tokens from user to contract (escrow)
            bool success = IERC20(payment.token).transferFrom(payment.client, address(this), payment.amount);
            if (!success) {
                revert PaymentGateway__TransferFailed();
            }
            
            payment.status = PaymentStatus.Processing;
        }
        
        emit PaymentCompleted(
            paymentId,
            payment.agentId,
            payment.client,
            payment.token,
            payment.amount,
            payment.platformFee,
            payment.agentAmount,
            block.timestamp
        );
    }
    
    /**
     * @dev Internal function to distribute payment
     */
    function _distributePayment(uint256 paymentId) internal {
        UnifiedPayment storage payment = _payments[paymentId];
        address agentOwner = erc721Identity.ownerOf(payment.agentId);
        
        if (payment.token == address(0)) {
            // Native token distribution
            if (payment.platformFee > 0) {
                _transferNative(platformFeeCollector, payment.platformFee);
            }
            
            _transferNative(agentOwner, payment.agentAmount);
            
            // Record earnings
            _agentEarnings[agentOwner].push(paymentId);
        } else {
            // ERC20 token distribution
            if (payment.platformFee > 0) {
                _transferToken(payment.token, platformFeeCollector, payment.platformFee);
            }
            
            _transferToken(payment.token, agentOwner, payment.agentAmount);
            
            // Record earnings
            _agentEarnings[agentOwner].push(paymentId);
        }
    }
    
    /**
     * @dev Internal function to check auto-debit authorization
     */
    function _checkAutoDebitAuthorization(
        address user,
        address, // token parameter unused, remove name to avoid warning
        uint256 // amount parameter unused, remove name to avoid warning
    ) internal view returns (bool) {
        // Check if user has any authorization for this token
        uint256[] storage authIds = _userAuthorizationIds[user];
        
        for (uint256 i = 0; i < authIds.length; i++) {
            if (_userAuthorizations[user][authIds[i]]) {
                // For now, we assume authorization is valid
                // In production, we should check amount limits and expiration
                return true;
            }
        }
        
        return false;
    }
    
    /**
     * @dev Internal function to get or create authorization ID
     */
    function _getOrCreateAuthorizationId(
        address user,
        address, // token parameter unused, remove name to avoid warning
        uint256 // amount parameter unused, remove name to avoid warning
    ) internal returns (uint256) {
        // For simplicity, we'll create a new authorization
        // In production, you might want to reuse existing ones
        
        _authorizationCounter++;
        uint256 authorizationId = _authorizationCounter;
        
        _userAuthorizations[user][authorizationId] = true;
        _userAuthorizationIds[user].push(authorizationId);
        
        return authorizationId;
    }
    
    /**
     * @dev Internal function to transfer native tokens
     */
    function _transferNative(address to, uint256 amount) internal {
        if (amount == 0) return;
        
        (bool success, ) = to.call{value: amount}("");
        if (!success) {
            revert PaymentGateway__TransferFailed();
        }
    }
    
    /**
     * @dev Internal function to transfer ERC20 tokens
     */
    function _transferToken(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        
        bool success = IERC20(token).transfer(to, amount);
        if (!success) {
            revert PaymentGateway__TransferFailed();
        }
    }
    
    /**
     * @dev Add payment method for user
     */
    function addPaymentMethod(
        address token,
        uint256 minAmount,
        uint256 maxAmount,
        bool autoDebitEnabled
    ) external {
        if (token != address(0) && !priceOracle.isTokenSupported(token)) {
            revert PaymentGateway__UnsupportedToken();
        }
        
        // Check if payment method already exists
        PaymentMethod[] storage methods = _userPaymentMethods[msg.sender];
        for (uint256 i = 0; i < methods.length; i++) {
            if (methods[i].token == token) {
                // Update existing
                methods[i].minAmount = minAmount;
                methods[i].maxAmount = maxAmount;
                methods[i].autoDebitEnabled = autoDebitEnabled;
                return;
            }
        }
        
        // Add new payment method
        methods.push(PaymentMethod({
            token: token,
            isSupported: true,
            minAmount: minAmount,
            maxAmount: maxAmount,
            autoDebitEnabled: autoDebitEnabled
        }));
        
        emit PaymentMethodAdded(msg.sender, token, minAmount, maxAmount, autoDebitEnabled);
    }
    
    /**
     * @dev Remove payment method
     */
    function removePaymentMethod(address token) external {
        PaymentMethod[] storage methods = _userPaymentMethods[msg.sender];
        
        for (uint256 i = 0; i < methods.length; i++) {
            if (methods[i].token == token) {
                // Remove by swapping with last element
                methods[i] = methods[methods.length - 1];
                methods.pop();
                
                emit PaymentMethodRemoved(msg.sender, token);
                return;
            }
        }
        
        revert PaymentGateway__InvalidToken();
    }
    
    /**
     * @dev Get payment details
     */
    function getPayment(uint256 paymentId) external view returns (UnifiedPayment memory) {
        UnifiedPayment memory payment = _payments[paymentId];
        if (payment.paymentId == 0) {
            revert PaymentGateway__PaymentNotFound();
        }
        return payment;
    }
    
    /**
     * @dev Get agent payments
     */
    function getAgentPayments(uint256 agentId) external view returns (UnifiedPayment[] memory) {
        uint256[] storage paymentIds = _agentPayments[agentId];
        UnifiedPayment[] memory payments = new UnifiedPayment[](paymentIds.length);
        
        for (uint256 i = 0; i < paymentIds.length; i++) {
            payments[i] = _payments[paymentIds[i]];
        }
        
        return payments;
    }
    
    /**
     * @dev Get client payments
     */
    function getClientPayments(address client) external view returns (UnifiedPayment[] memory) {
        uint256[] storage paymentIds = _clientPayments[client];
        UnifiedPayment[] memory payments = new UnifiedPayment[](paymentIds.length);
        
        for (uint256 i = 0; i < paymentIds.length; i++) {
            payments[i] = _payments[paymentIds[i]];
        }
        
        return payments;
    }
    
    /**
     * @dev Get subscription payments
     */
    function getSubscriptionPayments(uint256 subscriptionId) external view returns (UnifiedPayment[] memory) {
        uint256[] storage paymentIds = _subscriptionPayments[subscriptionId];
        UnifiedPayment[] memory payments = new UnifiedPayment[](paymentIds.length);
        
        for (uint256 i = 0; i < paymentIds.length; i++) {
            payments[i] = _payments[paymentIds[i]];
        }
        
        return payments;
    }
    
    /**
     * @dev Get dispute details
     */
    function getDispute(uint256 disputeId) external view returns (Dispute memory) {
        Dispute memory dispute = _disputes[disputeId];
        if (dispute.disputeId == 0) {
            revert PaymentGateway__DisputeNotFound();
        }
        return dispute;
    }
    
    /**
     * @dev Get user payment methods
     */
    function getUserPaymentMethods(address user) external view returns (PaymentMethod[] memory) {
        return _userPaymentMethods[user];
    }
    
    /**
     * @dev Get user authorizations
     */
    function getUserAuthorizations(address user) external view returns (uint256[] memory) {
        return _userAuthorizationIds[user];
    }
    
    /**
     * @dev Update platform fee percentage
     */
    function setPlatformFeePercentage(uint256 newFeePercentage) external onlyOwner {
        if (newFeePercentage > 10000) { // Max 100%
            revert PaymentGateway__InvalidAmount();
        }
        
        uint256 oldFee = platformFeePercentage;
        platformFeePercentage = newFeePercentage;
        
        emit PlatformFeeUpdated(oldFee, newFeePercentage, msg.sender, block.timestamp);
    }
    
    /**
     * @dev Update platform fee collector
     */
    function setPlatformFeeCollector(address newCollector) external onlyOwner {
        if (newCollector == address(0)) {
            revert PaymentGateway__InvalidAgent();
        }
        platformFeeCollector = newCollector;
    }
    
    /**
     * @dev Update escrow period
     */
    function setEscrowPeriod(uint256 newPeriod) external onlyOwner {
        escrowPeriod = newPeriod;
    }
    
    /**
     * @dev Update grace period
     */
    function setGracePeriod(uint256 newGracePeriod) external onlyOwner {
        gracePeriod = newGracePeriod;
    }
    
    /**
     * @dev Update dispute resolution period
     */
    function setDisputeResolutionPeriod(uint256 newPeriod) external onlyOwner {
        disputeResolutionPeriod = newPeriod;
    }
    
    /**
     * @dev Update min/max payment amounts
     */
    function setPaymentLimits(uint256 minAmount, uint256 maxAmount) external onlyOwner {
        minPaymentAmount = minAmount;
        maxPaymentAmount = maxAmount;
    }
    
    /**
     * @dev Get total payment count
     */
    function getTotalPaymentCount() external view returns (uint256) {
        return _paymentCounter;
    }
    
    /**
     * @dev Get agent earnings
     */
    function getAgentEarnings(address agentOwner) external view returns (uint256 totalEarnings) {
        uint256[] storage earningIds = _agentEarnings[agentOwner];
        
        for (uint256 i = 0; i < earningIds.length; i++) {
            UnifiedPayment memory payment = _payments[earningIds[i]];
            totalEarnings += payment.agentAmount;
        }
        
        return totalEarnings;
    }
    
    /**
     * @dev Get platform earnings
     */
    function getPlatformEarnings() external view returns (uint256 totalEarnings) {
        // This would require tracking platform fees separately
        // For simplicity, we'll calculate on the fly
        
        uint256 totalPayments = _paymentCounter;
        for (uint256 i = 1; i <= totalPayments; i++) {
            UnifiedPayment memory payment = _payments[i];
            if (payment.status == PaymentStatus.Completed || payment.status == PaymentStatus.Settled) {
                totalEarnings += payment.platformFee;
            }
        }
        
        return totalEarnings;
    }
    
    /**
     * @dev Check if payment can be auto-debited
     */
    function canAutoDebit(address user, address token, uint256 amount) external view returns (bool) {
        return _checkAutoDebitAuthorization(user, token, amount);
    }
    
    /**
     * @dev Get supported auto-debit tokens
     */
    function getSupportedAutoDebitTokens() external view returns (address[] memory) {
        return _supportedAutoDebitTokens.values();
    }
    
    /**
     * @dev Add supported auto-debit token
     */
    function addSupportedAutoDebitToken(address token) external onlyOwner {
        _supportedAutoDebitTokens.add(token);
    }
    
    /**
     * @dev Remove supported auto-debit token
     */
    function removeSupportedAutoDebitToken(address token) external onlyOwner {
        _supportedAutoDebitTokens.remove(token);
    }
    
    /**
     * @dev Emergency withdrawal for contract owner
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(0)) {
            payable(owner()).transfer(amount);
        } else {
            bool success = IERC20(token).transfer(owner(), amount);
            if (!success) {
                revert PaymentGateway__TransferFailed();
            }
        }
    }
}
