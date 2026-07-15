// contracts/extensions/AgentWallet.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../interfaces/IERC8004Identity.sol";

/**
 * @title AgentWallet
 * @dev Enhanced wallet management for AI Agents and Users with secure fund handling
 * @notice Production-ready wallet system with multi-token support and auto-debit authorization
 */
contract AgentWallet is Ownable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;
    
    IERC8004Identity public immutable identityRegistry;
    IERC721 public immutable erc721Identity;
    
    struct WalletBalance {
        uint256 nativeBalance;
        mapping(address => uint256) tokenBalances;
        EnumerableSet.AddressSet supportedTokens;
    }
    
    struct UserBalance {
        uint256 nativeBalance;
        mapping(address => uint256) tokenBalances;
        EnumerableSet.AddressSet supportedTokens;
    }
    
    struct Transaction {
        uint256 transactionId;
        uint256 agentId;
        address from;
        address to;
        address token;
        uint256 amount;
        string description;
        uint256 timestamp;
        bool isIncoming;
        TransactionType transactionType;
    }
    
    struct PaymentAuthorization {
        address spender;
        address token;
        uint256 maxAmount;
        uint256 remainingAmount;
        uint256 expiresAt;
        bool isActive;
    }
    
    enum TransactionType {
        Deposit,
        Withdrawal,
        Transfer,
        Payment,
        AutoDebit
    }
    
    // Storage
    uint256 private _transactionCounter;
    uint256 private _authorizationCounter;
    
    // Agent wallets
    mapping(uint256 => WalletBalance) private _agentWallets;
    
    // User wallets
    mapping(address => UserBalance) private _userWallets;
    
    // Transactions
    mapping(uint256 => Transaction[]) private _agentTransactions;
    mapping(address => Transaction[]) private _userTransactions;
    
    // Payment authorizations (user => authorizationId => PaymentAuthorization)
    mapping(address => mapping(uint256 => PaymentAuthorization)) private _userAuthorizations;
    mapping(address => uint256[]) private _userAuthorizationIds;
    
    // Authorized spenders (user => spender => isAuthorized)
    mapping(address => mapping(address => bool)) private _authorizedSpenders;
    
    // Events
    event Deposit(
        address indexed account,
        uint256 indexed agentId,
        address indexed token,
        uint256 amount,
        uint256 timestamp
    );
    
    event Withdrawal(
        address indexed account,
        uint256 indexed agentId,
        address indexed token,
        uint256 amount,
        address to,
        uint256 timestamp
    );
    
    event Transfer(
        uint256 indexed fromAgentId,
        uint256 indexed toAgentId,
        address indexed token,
        uint256 amount,
        uint256 timestamp
    );
    
    event PaymentProcessed(
        address indexed from,
        address indexed to,
        uint256 indexed agentId,
        address token,
        uint256 amount,
        uint256 timestamp
    );
    
    event AutoDebitProcessed(
        address indexed from,
        address indexed to,
        uint256 indexed agentId,
        address token,
        uint256 amount,
        uint256 authorizationId,
        uint256 timestamp
    );
    
    event AuthorizationCreated(
        address indexed user,
        uint256 indexed authorizationId,
        address indexed spender,
        address token,
        uint256 maxAmount,
        uint256 expiresAt
    );
    
    event AuthorizationRevoked(
        address indexed user,
        uint256 indexed authorizationId
    );
    
    event AutoDebitAuthorization(
        address indexed user,
        address indexed spender,
        address token,
        uint256 maxAmountPerPeriod,
        uint256 periodInSeconds
    );
    
    event AutoDebitRevoked(
        address indexed user,
        address indexed spender,
        address token
    );
    
    // Custom errors
    error AgentWallet__AgentNotOwner();
    error AgentWallet__InsufficientBalance();
    error AgentWallet__InvalidAmount();
    error AgentWallet__TokenNotSupported();
    error AgentWallet__TransferFailed();
    error AgentWallet__InvalidAgent();
    error AgentWallet__AuthorizationNotFound();
    error AgentWallet__AuthorizationExpired();
    error AgentWallet__InsufficientAuthorization();
    error AgentWallet__NotAuthorizedSpender();
    error AgentWallet__InvalidRecipient();

    constructor(address _identityRegistry) Ownable(msg.sender) {
        if (_identityRegistry == address(0)) {
            revert AgentWallet__InvalidAgent();
        }
        identityRegistry = IERC8004Identity(_identityRegistry);
        erc721Identity = IERC721(_identityRegistry);
        _transactionCounter = 0;
        _authorizationCounter = 0;
    }
    
    /**
     * @dev Deposit native currency to user wallet
     */
    function depositNativeForUser() external payable nonReentrant {
        if (msg.value == 0) {
            revert AgentWallet__InvalidAmount();
        }
        
        UserBalance storage userBalance = _userWallets[msg.sender];
        userBalance.nativeBalance += msg.value;
        
        _recordUserTransaction(
            msg.sender,
            address(0),
            msg.value,
            msg.sender,
            address(this),
            "User native deposit",
            true,
            TransactionType.Deposit
        );
        
        emit Deposit(msg.sender, 0, address(0), msg.value, block.timestamp);
    }
    
    /**
     * @dev Deposit ERC20 tokens to user wallet
     */
    function depositTokenForUser(address token, uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert AgentWallet__InvalidAmount();
        }
        
        UserBalance storage userBalance = _userWallets[msg.sender];
        
        bool success = IERC20(token).transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert AgentWallet__TransferFailed();
        }
        
        userBalance.tokenBalances[token] += amount;
        userBalance.supportedTokens.add(token);
        
        _recordUserTransaction(
            msg.sender,
            token,
            amount,
            msg.sender,
            address(this),
            "User token deposit",
            true,
            TransactionType.Deposit
        );
        
        emit Deposit(msg.sender, 0, token, amount, block.timestamp);
    }
    
    /**
     * @dev Withdraw native currency from user wallet
     */
    function withdrawNativeFromUser(uint256 amount, address payable to) external nonReentrant {
        if (amount == 0 || to == address(0)) {
            revert AgentWallet__InvalidAmount();
        }
        
        UserBalance storage userBalance = _userWallets[msg.sender];
        if (userBalance.nativeBalance < amount) {
            revert AgentWallet__InsufficientBalance();
        }
        
        userBalance.nativeBalance -= amount;
        
        (bool success, ) = to.call{value: amount}("");
        if (!success) {
            revert AgentWallet__TransferFailed();
        }
        
        _recordUserTransaction(
            msg.sender,
            address(0),
            amount,
            address(this),
            to,
            "User native withdrawal",
            false,
            TransactionType.Withdrawal
        );
        
        emit Withdrawal(msg.sender, 0, address(0), amount, to, block.timestamp);
    }
    
    /**
     * @dev Withdraw ERC20 tokens from user wallet
     */
    function withdrawTokenFromUser(address token, uint256 amount, address to) external nonReentrant {
        if (amount == 0 || to == address(0)) {
            revert AgentWallet__InvalidAmount();
        }
        
        UserBalance storage userBalance = _userWallets[msg.sender];
        if (userBalance.tokenBalances[token] < amount) {
            revert AgentWallet__InsufficientBalance();
        }
        
        userBalance.tokenBalances[token] -= amount;
        
        bool success = IERC20(token).transfer(to, amount);
        if (!success) {
            revert AgentWallet__TransferFailed();
        }
        
        _recordUserTransaction(
            msg.sender,
            token,
            amount,
            address(this),
            to,
            "User token withdrawal",
            false,
            TransactionType.Withdrawal
        );
        
        emit Withdrawal(msg.sender, 0, token, amount, to, block.timestamp);
    }
    
    /**
     * @dev Deposit native currency to agent wallet
     */
    function depositNative(uint256 agentId) external payable nonReentrant {
        if (!identityRegistry.agentExists(agentId)) {
            revert AgentWallet__InvalidAgent();
        }
        
        if (msg.value == 0) {
            revert AgentWallet__InvalidAmount();
        }
        
        _agentWallets[agentId].nativeBalance += msg.value;
        
        _recordTransaction(
            agentId,
            address(0),
            msg.value,
            msg.sender,
            address(this),
            "Agent native deposit",
            true,
            TransactionType.Deposit
        );
        
        emit Deposit(msg.sender, agentId, address(0), msg.value, block.timestamp);
    }
    
    /**
     * @dev Deposit ERC20 tokens to agent wallet
     */
    function depositToken(uint256 agentId, address token, uint256 amount) external nonReentrant {
        if (!identityRegistry.agentExists(agentId)) {
            revert AgentWallet__InvalidAgent();
        }
        
        if (amount == 0) {
            revert AgentWallet__InvalidAmount();
        }
        
        bool success = IERC20(token).transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert AgentWallet__TransferFailed();
        }
        
        WalletBalance storage wallet = _agentWallets[agentId];
        wallet.tokenBalances[token] += amount;
        wallet.supportedTokens.add(token);
        
        _recordTransaction(
            agentId,
            token,
            amount,
            msg.sender,
            address(this),
            "Agent token deposit",
            true,
            TransactionType.Deposit
        );
        
        emit Deposit(msg.sender, agentId, token, amount, block.timestamp);
    }
    
    /**
     * @dev Withdraw native currency from agent wallet
     */
    function withdrawNative(uint256 agentId, uint256 amount, address payable to) external nonReentrant {
        _validateAgentWithdrawal(agentId, address(0), amount, to);
        
        WalletBalance storage wallet = _agentWallets[agentId];
        wallet.nativeBalance -= amount;
        
        (bool success, ) = to.call{value: amount}("");
        if (!success) {
            revert AgentWallet__TransferFailed();
        }
        
        _recordTransaction(
            agentId,
            address(0),
            amount,
            address(this),
            to,
            "Agent native withdrawal",
            false,
            TransactionType.Withdrawal
        );
        
        emit Withdrawal(msg.sender, agentId, address(0), amount, to, block.timestamp);
    }
    
    /**
     * @dev Withdraw ERC20 tokens from agent wallet
     */
    function withdrawToken(uint256 agentId, address token, uint256 amount, address to) external nonReentrant {
        _validateAgentWithdrawal(agentId, token, amount, to);
        
        WalletBalance storage wallet = _agentWallets[agentId];
        wallet.tokenBalances[token] -= amount;
        
        bool success = IERC20(token).transfer(to, amount);
        if (!success) {
            revert AgentWallet__TransferFailed();
        }
        
        _recordTransaction(
            agentId,
            token,
            amount,
            address(this),
            to,
            "Agent token withdrawal",
            false,
            TransactionType.Withdrawal
        );
        
        emit Withdrawal(msg.sender, agentId, token, amount, to, block.timestamp);
    }
    
    /**
     * @dev Transfer funds between agent wallets
     */
    function transferToAgent(
        uint256 fromAgentId,
        uint256 toAgentId,
        address token,
        uint256 amount,
        string memory description
    ) external nonReentrant {
        _validateTransfer(fromAgentId, toAgentId, token, amount);
        
        WalletBalance storage fromWallet = _agentWallets[fromAgentId];
        WalletBalance storage toWallet = _agentWallets[toAgentId];
        
        if (token == address(0)) {
            fromWallet.nativeBalance -= amount;
            toWallet.nativeBalance += amount;
        } else {
            fromWallet.tokenBalances[token] -= amount;
            toWallet.tokenBalances[token] += amount;
            toWallet.supportedTokens.add(token);
        }
        
        _recordTransaction(
            fromAgentId,
            token,
            amount,
            address(this),
            address(this),
            description,
            false,
            TransactionType.Transfer
        );
        
        _recordTransaction(
            toAgentId,
            token,
            amount,
            address(this),
            address(this),
            description,
            true,
            TransactionType.Transfer
        );
        
        emit Transfer(fromAgentId, toAgentId, token, amount, block.timestamp);
    }
    
    /**
     * @dev Create payment authorization for auto-debit
     */
    function createPaymentAuthorization(
        address spender,
        address token,
        uint256 maxAmount,
        uint256 durationInSeconds
    ) external returns (uint256 authorizationId) {
        if (spender == address(0) || maxAmount == 0) {
            revert AgentWallet__InvalidAmount();
        }
        
        _authorizationCounter++;
        authorizationId = _authorizationCounter;
        
        uint256 expiresAt = block.timestamp + durationInSeconds;
        
        PaymentAuthorization memory authorization = PaymentAuthorization({
            spender: spender,
            token: token,
            maxAmount: maxAmount,
            remainingAmount: maxAmount,
            expiresAt: expiresAt,
            isActive: true
        });
        
        _userAuthorizations[msg.sender][authorizationId] = authorization;
        _userAuthorizationIds[msg.sender].push(authorizationId);
        _authorizedSpenders[msg.sender][spender] = true;
        
        emit AuthorizationCreated(msg.sender, authorizationId, spender, token, maxAmount, expiresAt);
        return authorizationId;
    }
    
    /**
     * @dev Revoke payment authorization
     */
    function revokePaymentAuthorization(uint256 authorizationId) external {
        PaymentAuthorization storage authorization = _userAuthorizations[msg.sender][authorizationId];
        
        if (!authorization.isActive) {
            revert AgentWallet__AuthorizationNotFound();
        }
        
        authorization.isActive = false;
        
        emit AuthorizationRevoked(msg.sender, authorizationId);
    }
    
    /**
     * @dev Authorize auto-debit for subscription payments
     */
    function authorizeAutoDebit(
        address spender,
        address token,
        uint256 maxAmountPerPeriod,
        uint256 periodInSeconds
    ) external {
        if (spender == address(0)) {
            revert AgentWallet__InvalidAmount();
        }
        
        _authorizedSpenders[msg.sender][spender] = true;
        
        emit AutoDebitAuthorization(msg.sender, spender, token, maxAmountPerPeriod, periodInSeconds);
    }
    
    /**
     * @dev Revoke auto-debit authorization
     */
    function revokeAutoDebitAuthorization(address spender) external {
        _authorizedSpenders[msg.sender][spender] = false;
        
        emit AutoDebitRevoked(msg.sender, spender, address(0));
    }
    
    /**
     * @dev Process payment from user wallet (called by authorized spender)
     */
    function processPaymentFromUser(
        address user,
        address token,
        uint256 amount,
        string memory description
    ) external returns (bool) {
        return _processPayment(user, token, amount, description, false, 0);
    }
    
    /**
     * @dev Process auto-debit payment from user wallet (called by authorized spender)
     */
    function processAutoDebitPayment(
        address user,
        address token,
        uint256 amount,
        uint256 authorizationId,
        string memory description
    ) external returns (bool) {
        return _processPayment(user, token, amount, description, true, authorizationId);
    }
    
    /**
     * @dev Internal function to process payment from user wallet
     */
    function _processPayment(
        address user,
        address token,
        uint256 amount,
        string memory description,
        bool isAutoDebit,
        uint256 authorizationId
    ) internal returns (bool) {
        // Check if spender is authorized
        if (!_authorizedSpenders[user][msg.sender]) {
            revert AgentWallet__NotAuthorizedSpender();
        }
        
        if (isAutoDebit) {
            // Check authorization
            PaymentAuthorization storage authorization = _userAuthorizations[user][authorizationId];
            
            if (!authorization.isActive) {
                revert AgentWallet__AuthorizationNotFound();
            }
            
            if (authorization.expiresAt < block.timestamp) {
                revert AgentWallet__AuthorizationExpired();
            }
            
            if (authorization.token != token) {
                revert AgentWallet__TokenNotSupported();
            }
            
            if (authorization.remainingAmount < amount) {
                revert AgentWallet__InsufficientAuthorization();
            }
            
            authorization.remainingAmount -= amount;
        }
        
        // Check user balance
        UserBalance storage userBalance = _userWallets[user];
        
        if (token == address(0)) {
            if (userBalance.nativeBalance < amount) {
                revert AgentWallet__InsufficientBalance();
            }
            userBalance.nativeBalance -= amount;
        } else {
            if (userBalance.tokenBalances[token] < amount) {
                revert AgentWallet__InsufficientBalance();
            }
            userBalance.tokenBalances[token] -= amount;
        }
        
        // Record transaction
        if (isAutoDebit) {
            _recordUserTransaction(
                user,
                token,
                amount,
                address(this),
                msg.sender,
                description,
                false,
                TransactionType.AutoDebit
            );
            
            emit AutoDebitProcessed(user, msg.sender, 0, token, amount, authorizationId, block.timestamp);
        } else {
            _recordUserTransaction(
                user,
                token,
                amount,
                address(this),
                msg.sender,
                description,
                false,
                TransactionType.Payment
            );
            
            emit PaymentProcessed(user, msg.sender, 0, token, amount, block.timestamp);
        }
        
        return true;
    }
    
    /**
     * @dev Internal validation for agent withdrawals
     */
    function _validateAgentWithdrawal(uint256 agentId, address token, uint256 amount, address to) internal view {
        // Check agent ownership
        address agentOwner;
        try erc721Identity.ownerOf(agentId) returns (address owner) {
            agentOwner = owner;
        } catch {
            revert AgentWallet__AgentNotOwner();
        }
        
        if (agentOwner != msg.sender) {
            revert AgentWallet__AgentNotOwner();
        }
        
        if (amount == 0 || to == address(0)) {
            revert AgentWallet__InvalidAmount();
        }
        
        WalletBalance storage wallet = _agentWallets[agentId];
        
        if (token == address(0)) {
            if (wallet.nativeBalance < amount) {
                revert AgentWallet__InsufficientBalance();
            }
        } else {
            if (wallet.tokenBalances[token] < amount) {
                revert AgentWallet__InsufficientBalance();
            }
        }
    }
    
    /**
     * @dev Internal validation for transfers
     */
    function _validateTransfer(uint256 fromAgentId, uint256 toAgentId, address token, uint256 amount) internal view {
        // Check from agent ownership
        address fromAgentOwner;
        try erc721Identity.ownerOf(fromAgentId) returns (address owner) {
            fromAgentOwner = owner;
        } catch {
            revert AgentWallet__AgentNotOwner();
        }
        
        if (fromAgentOwner != msg.sender) {
            revert AgentWallet__AgentNotOwner();
        }
        
        if (!identityRegistry.agentExists(toAgentId)) {
            revert AgentWallet__InvalidAgent();
        }
        
        if (amount == 0) {
            revert AgentWallet__InvalidAmount();
        }
        
        WalletBalance storage wallet = _agentWallets[fromAgentId];
        
        if (token == address(0)) {
            if (wallet.nativeBalance < amount) {
                revert AgentWallet__InsufficientBalance();
            }
        } else {
            if (wallet.tokenBalances[token] < amount) {
                revert AgentWallet__InsufficientBalance();
            }
        }
    }
    
    /**
     * @dev Internal function to record agent transactions
     */
    function _recordTransaction(
        uint256 agentId,
        address token,
        uint256 amount,
        address from,
        address to,
        string memory description,
        bool isIncoming,
        TransactionType transactionType
    ) internal {
        _transactionCounter++;
        
        Transaction memory newTransaction = Transaction({
            transactionId: _transactionCounter,
            agentId: agentId,
            from: from,
            to: to,
            token: token,
            amount: amount,
            description: description,
            timestamp: block.timestamp,
            isIncoming: isIncoming,
            transactionType: transactionType
        });
        
        _agentTransactions[agentId].push(newTransaction);
    }
    
    /**
     * @dev Internal function to record user transactions
     */
    function _recordUserTransaction(
        address user,
        address token,
        uint256 amount,
        address from,
        address to,
        string memory description,
        bool isIncoming,
        TransactionType transactionType
    ) internal {
        _transactionCounter++;
        
        Transaction memory newTransaction = Transaction({
            transactionId: _transactionCounter,
            agentId: 0,
            from: from,
            to: to,
            token: token,
            amount: amount,
            description: description,
            timestamp: block.timestamp,
            isIncoming: isIncoming,
            transactionType: transactionType
        });
        
        _userTransactions[user].push(newTransaction);
    }
    
    /**
     * @dev Get agent wallet balance
     */
    function getAgentWalletBalance(uint256 agentId) external view returns (
        uint256 nativeBalance,
        address[] memory tokens,
        uint256[] memory tokenBalances
    ) {
        WalletBalance storage wallet = _agentWallets[agentId];
        nativeBalance = wallet.nativeBalance;
        
        uint256 tokenCount = wallet.supportedTokens.length();
        tokens = new address[](tokenCount);
        tokenBalances = new uint256[](tokenCount);
        
        for (uint256 i = 0; i < tokenCount; i++) {
            address token = wallet.supportedTokens.at(i);
            tokens[i] = token;
            tokenBalances[i] = wallet.tokenBalances[token];
        }
        
        return (nativeBalance, tokens, tokenBalances);
    }
    
    /**
     * @dev Get user wallet balance
     */
    function getUserWalletBalance(address user) external view returns (
        uint256 nativeBalance,
        address[] memory tokens,
        uint256[] memory tokenBalances
    ) {
        UserBalance storage userBalance = _userWallets[user];
        nativeBalance = userBalance.nativeBalance;
        
        uint256 tokenCount = userBalance.supportedTokens.length();
        tokens = new address[](tokenCount);
        tokenBalances = new uint256[](tokenCount);
        
        for (uint256 i = 0; i < tokenCount; i++) {
            address token = userBalance.supportedTokens.at(i);
            tokens[i] = token;
            tokenBalances[i] = userBalance.tokenBalances[token];
        }
        
        return (nativeBalance, tokens, tokenBalances);
    }
    
    /**
     * @dev Get user authorizations
     */
    function getUserAuthorizations(address user) external view returns (
        uint256[] memory authorizationIds,
        address[] memory spenders,
        address[] memory tokens,
        uint256[] memory maxAmounts,
        uint256[] memory remainingAmounts,
        uint256[] memory expiresAts,
        bool[] memory isActives
    ) {
        uint256[] storage ids = _userAuthorizationIds[user];
        uint256 count = ids.length;
        
        authorizationIds = new uint256[](count);
        spenders = new address[](count);
        tokens = new address[](count);
        maxAmounts = new uint256[](count);
        remainingAmounts = new uint256[](count);
        expiresAts = new uint256[](count);
        isActives = new bool[](count);
        
        for (uint256 i = 0; i < count; i++) {
            uint256 authId = ids[i];
            PaymentAuthorization storage auth = _userAuthorizations[user][authId];
            
            authorizationIds[i] = authId;
            spenders[i] = auth.spender;
            tokens[i] = auth.token;
            maxAmounts[i] = auth.maxAmount;
            remainingAmounts[i] = auth.remainingAmount;
            expiresAts[i] = auth.expiresAt;
            isActives[i] = auth.isActive;
        }
        
        return (authorizationIds, spenders, tokens, maxAmounts, remainingAmounts, expiresAts, isActives);
    }
    
    /**
     * @dev Get agent transactions with pagination
     */
    function getAgentTransactions(
        uint256 agentId,
        uint256 offset,
        uint256 limit
    ) external view returns (Transaction[] memory) {
        Transaction[] storage allTransactions = _agentTransactions[agentId];
        
        if (offset >= allTransactions.length) {
            return new Transaction[](0);
        }
        
        uint256 resultCount = allTransactions.length - offset;
        if (resultCount > limit) {
            resultCount = limit;
        }
        
        Transaction[] memory result = new Transaction[](resultCount);
        
        for (uint256 i = 0; i < resultCount; i++) {
            result[i] = allTransactions[offset + i];
        }
        
        return result;
    }
    
    /**
     * @dev Get user transactions with pagination
     */
    function getUserTransactions(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (Transaction[] memory) {
        Transaction[] storage allTransactions = _userTransactions[user];
        
        if (offset >= allTransactions.length) {
            return new Transaction[](0);
        }
        
        uint256 resultCount = allTransactions.length - offset;
        if (resultCount > limit) {
            resultCount = limit;
        }
        
        Transaction[] memory result = new Transaction[](resultCount);
        
        for (uint256 i = 0; i < resultCount; i++) {
            result[i] = allTransactions[offset + i];
        }
        
        return result;
    }
    
    /**
     * @dev Check if spender is authorized for user
     */
    function isSpenderAuthorized(address user, address spender) external view returns (bool) {
        return _authorizedSpenders[user][spender];
    }
    
    /**
     * @dev Get total transaction count
     */
    function getTotalTransactionCount() external view returns (uint256) {
        return _transactionCounter;
    }
    
    /**
     * @dev Get total authorization count
     */
    function getTotalAuthorizationCount() external view returns (uint256) {
        return _authorizationCounter;
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
                revert AgentWallet__TransferFailed();
            }
        }
    }
}
