// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title ERC8004Bootstrap
 * @notice 部署引导垫片，等价于 canonical 仓库（erc-8004/erc-8004-contracts, CC0）的 MinimalUUPS，
 *         **唯一差异**：owner 由部署者传入，而非硬编码为 ERC-8004 团队地址
 *         `0x547289319C3e6aedB179C0b8e8aF0B5ACd062603`（自建链上无法使用该 owner）。
 *
 *         它不承载任何业务逻辑，仅用于引导代理初始化：
 *           1) 初始化代理的 Ownable owner —— 真实实现的 `initialize()` 是 `onlyOwner`，
 *              在全新代理上 owner 为 address(0) 会 revert，必须先用垫片写入 owner；
 *           2) 在 slot 0 预留 `_identityRegistry`（与三个真实实现的存储布局一致）。
 *
 *         部署流程（每个注册表代理一次）：
 *           new ERC1967Proxy(bootstrap, abi.encodeCall(initialize, (owner, identityRegistry)))
 *             → upgradeToAndCall(真实实现, initialize 数据)
 *         垫片用的是 `initializer`(v1)，真实实现用的是 `reinitializer(2)`，版本号恰好衔接。
 */
contract ERC8004Bootstrap is OwnableUpgradeable, UUPSUpgradeable {
    /// @dev 与真实实现一致的 slot 0 布局（identity 注册表地址）
    address private _identityRegistry;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address identityRegistry_) public initializer {
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        _identityRegistry = identityRegistry_;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
