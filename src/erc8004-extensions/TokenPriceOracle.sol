// contracts/extensions/TokenPriceOracle.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TokenPriceOracle
 * @dev Price oracle for token conversions with fallback mechanisms
 * @notice Production-ready price oracle with multiple data sources
 */
contract TokenPriceOracle is Ownable {
    struct PriceData {
        uint256 price;
        uint256 timestamp;
        uint256 confidence;
        string source;
    }
    
    struct TokenConfig {
        address token;
        string symbol;
        uint256 decimals;
        bool isActive;
        uint256 lastUpdate;
    }
    
    // Storage
    mapping(address => PriceData) private _tokenPrices;
    mapping(address => TokenConfig) private _tokenConfigs;
    mapping(string => address) private _symbolToToken;
    address[] private _supportedTokens;
    
    // 修复：添加事件
    event PriceUpdated(
        address indexed token,
        uint256 price,
        uint256 timestamp,
        string source,
        uint256 confidence
    );
    
    event TokenAdded(
        address indexed token,
        string symbol,
        uint256 decimals,
        bool isActive
    );
    
    event TokenRemoved(address indexed token);
    
    // Custom errors
    error TokenPriceOracle__InvalidToken();
    error TokenPriceOracle__InvalidPrice();
    error TokenPriceOracle__StalePrice();
    error TokenPriceOracle__TokenNotSupported();
    error TokenPriceOracle__InvalidInput();

    constructor() Ownable(msg.sender) {
        // 初始化常用代币
        _initializeDefaultTokens();
    }
    
    /**
     * @dev Add supported token
     */
    function addToken(
        address token,
        string memory symbol,
        uint256 decimals
    ) external onlyOwner {
        if (token == address(0)) {
            revert TokenPriceOracle__InvalidToken();
        }
        
        if (bytes(symbol).length == 0) {
            revert TokenPriceOracle__InvalidInput();
        }
        
        _tokenConfigs[token] = TokenConfig({
            token: token,
            symbol: symbol,
            decimals: decimals,
            isActive: true,
            lastUpdate: 0
        });
        
        _symbolToToken[symbol] = token;
        _supportedTokens.push(token);
        
        emit TokenAdded(token, symbol, decimals, true);
    }
    
    /**
     * @dev Get token price
     */
    function getPrice(address token) external view returns (uint256 price, uint256 timestamp, uint256 confidence) {
        if (!_tokenConfigs[token].isActive) {
            revert TokenPriceOracle__TokenNotSupported();
        }
        
        PriceData memory priceData = _tokenPrices[token];
        
        if (priceData.timestamp == 0) {
            revert TokenPriceOracle__StalePrice();
        }
        
        // 修复：检查价格是否过时（超过1小时）
        if (block.timestamp - priceData.timestamp > 1 hours) {
            revert TokenPriceOracle__StalePrice();
        }
        
        return (priceData.price, priceData.timestamp, priceData.confidence);
    }
    
    /**
     * @dev Update token price
     */
    function updatePrice(
        address token,
        uint256 price,
        uint256 confidence,
        string memory source
    ) external onlyOwner {
        if (token == address(0)) {
            revert TokenPriceOracle__InvalidToken();
        }
        
        if (price == 0) {
            revert TokenPriceOracle__InvalidPrice();
        }
        
        if (!_tokenConfigs[token].isActive) {
            revert TokenPriceOracle__TokenNotSupported();
        }
        
        _tokenPrices[token] = PriceData({
            price: price,
            timestamp: block.timestamp,
            confidence: confidence,
            source: source
        });
        
        _tokenConfigs[token].lastUpdate = block.timestamp;
        
        emit PriceUpdated(token, price, block.timestamp, source, confidence);
    }
    
    /**
     * @dev Update multiple prices in batch
     */
    function updatePricesBatch(
        address[] memory tokens,
        uint256[] memory prices,
        uint256[] memory confidences,
        string[] memory sources
    ) external onlyOwner {
        if (tokens.length != prices.length || 
            tokens.length != confidences.length || 
            tokens.length != sources.length) {
            revert TokenPriceOracle__InvalidInput();
        }
        
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] != address(0) && prices[i] > 0 && _tokenConfigs[tokens[i]].isActive) {
                _tokenPrices[tokens[i]] = PriceData({
                    price: prices[i],
                    timestamp: block.timestamp,
                    confidence: confidences[i],
                    source: sources[i]
                });
                
                _tokenConfigs[tokens[i]].lastUpdate = block.timestamp;
                
                emit PriceUpdated(tokens[i], prices[i], block.timestamp, sources[i], confidences[i]);
            }
        }
    }
    
    /**
     * @dev Remove supported token
     */
    function removeToken(address token) external onlyOwner {
        if (!_tokenConfigs[token].isActive) {
            revert TokenPriceOracle__TokenNotSupported();
        }
        
        _tokenConfigs[token].isActive = false;
        
        // 修复：从支持代币列表中移除
        for (uint256 i = 0; i < _supportedTokens.length; i++) {
            if (_supportedTokens[i] == token) {
                _supportedTokens[i] = _supportedTokens[_supportedTokens.length - 1];
                _supportedTokens.pop();
                break;
            }
        }
        
        delete _symbolToToken[_tokenConfigs[token].symbol];
        
        emit TokenRemoved(token);
    }
    
    /**
     * @dev Get token price by symbol
     */
    function getPriceBySymbol(string memory symbol) external view returns (uint256 price, uint256 timestamp, uint256 confidence) {
        address token = _symbolToToken[symbol];
        if (token == address(0)) {
            revert TokenPriceOracle__TokenNotSupported();
        }
        
        return this.getPrice(token);
    }
    
    /**
     * @dev Convert token amount to USD
     */
    function convertToUSD(address token, uint256 amount) external view returns (uint256 usdAmount) {
        (uint256 price, , ) = this.getPrice(token);
        TokenConfig memory config = _tokenConfigs[token];
        
        // 修复：考虑代币小数位数
        usdAmount = (amount * price) / (10 ** config.decimals);
        return usdAmount;
    }
    
    /**
     * @dev Convert USD amount to token amount
     */
    function convertFromUSD(address token, uint256 usdAmount) external view returns (uint256 tokenAmount) {
        (uint256 price, , ) = this.getPrice(token);
        TokenConfig memory config = _tokenConfigs[token];
        
        if (price == 0) {
            revert TokenPriceOracle__InvalidPrice();
        }
        
        // 修复：考虑代币小数位数
        tokenAmount = (usdAmount * (10 ** config.decimals)) / price;
        return tokenAmount;
    }
    
    /**
     * @dev Convert between tokens
     */
    function convert(
        address fromToken,
        address toToken,
        uint256 amount
    ) external view returns (uint256 convertedAmount) {
        (uint256 fromPrice, , ) = this.getPrice(fromToken);
        (uint256 toPrice, , ) = this.getPrice(toToken);
        
        TokenConfig memory fromConfig = _tokenConfigs[fromToken];
        TokenConfig memory toConfig = _tokenConfigs[toToken];
        
        if (fromPrice == 0 || toPrice == 0) {
            revert TokenPriceOracle__InvalidPrice();
        }
        
        // 修复：考虑不同代币的小数位数
        uint256 usdValue = (amount * fromPrice) / (10 ** fromConfig.decimals);
        convertedAmount = (usdValue * (10 ** toConfig.decimals)) / toPrice;
        
        return convertedAmount;
    }
    
    /**
     * @dev Get all supported tokens
     */
    function getSupportedTokens() external view returns (address[] memory) {
        return _supportedTokens;
    }
    
    /**
     * @dev Get token configuration
     */
    function getTokenConfig(address token) external view returns (TokenConfig memory) {
        if (!_tokenConfigs[token].isActive) {
            revert TokenPriceOracle__TokenNotSupported();
        }
        
        return _tokenConfigs[token];
    }
    
    /**
     * @dev Check if token is supported
     */
    function isTokenSupported(address token) external view returns (bool) {
        return _tokenConfigs[token].isActive;
    }
    
    /**
     * @dev Get price data with full details
     */
    function getPriceData(address token) external view returns (PriceData memory) {
        if (!_tokenConfigs[token].isActive) {
            revert TokenPriceOracle__TokenNotSupported();
        }
        
        return _tokenPrices[token];
    }
    
    /**
     * @dev Initialize default tokens
     */
    function _initializeDefaultTokens() internal {
        // 修复：直接初始化代币配置，不调用外部函数
        address usdt = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        address dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        address wbtc = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        
        // USDT
        _tokenConfigs[usdt] = TokenConfig({
            token: usdt,
            symbol: "USDT",
            decimals: 6,
            isActive: true,
            lastUpdate: 0
        });
        _symbolToToken["USDT"] = usdt;
        _supportedTokens.push(usdt);
        emit TokenAdded(usdt, "USDT", 6, true);
        
        // USDC
        _tokenConfigs[usdc] = TokenConfig({
            token: usdc,
            symbol: "USDC",
            decimals: 6,
            isActive: true,
            lastUpdate: 0
        });
        _symbolToToken["USDC"] = usdc;
        _supportedTokens.push(usdc);
        emit TokenAdded(usdc, "USDC", 6, true);
        
        // DAI
        _tokenConfigs[dai] = TokenConfig({
            token: dai,
            symbol: "DAI",
            decimals: 18,
            isActive: true,
            lastUpdate: 0
        });
        _symbolToToken["DAI"] = dai;
        _supportedTokens.push(dai);
        emit TokenAdded(dai, "DAI", 18, true);
        
        // WETH
        _tokenConfigs[weth] = TokenConfig({
            token: weth,
            symbol: "WETH",
            decimals: 18,
            isActive: true,
            lastUpdate: 0
        });
        _symbolToToken["WETH"] = weth;
        _supportedTokens.push(weth);
        emit TokenAdded(weth, "WETH", 18, true);
        
        // WBTC
        _tokenConfigs[wbtc] = TokenConfig({
            token: wbtc,
            symbol: "WBTC",
            decimals: 8,
            isActive: true,
            lastUpdate: 0
        });
        _symbolToToken["WBTC"] = wbtc;
        _supportedTokens.push(wbtc);
        emit TokenAdded(wbtc, "WBTC", 8, true);
    }
    
    /**
     * @dev Set fallback price for emergency situations
     */
    function setFallbackPrice(address token, uint256 price) external onlyOwner {
        if (!_tokenConfigs[token].isActive) {
            revert TokenPriceOracle__TokenNotSupported();
        }
        
        _tokenPrices[token] = PriceData({
            price: price,
            timestamp: block.timestamp,
            confidence: 50, // Low confidence for fallback
            source: "fallback"
        });
        
        _tokenConfigs[token].lastUpdate = block.timestamp;
        
        emit PriceUpdated(token, price, block.timestamp, "fallback", 50);
    }
}
