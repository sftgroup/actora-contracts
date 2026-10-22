// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {ValidationRegistryUpgradeable} from "../src/erc8004-canonical/ValidationRegistryUpgradeable.sol";
import {ERC8004Bootstrap} from "../src/erc8004-canonical/ERC8004Bootstrap.sol";
import {TokenPriceOracle} from "../src/erc8004-extensions/TokenPriceOracle.sol";
import {ERC8004SubscriptionManager} from "../src/erc8004-extensions/SubscriptionManager.sol";
import {A2AProtocolRegistry} from "../src/erc8004-extensions/A2AProtocolRegistry.sol";
import {ConfigurationRegistry} from "../src/erc8004-extensions/ConfigurationRegistry.sol";
import {MultiEndpointRegistry} from "../src/erc8004-extensions/MultiEndpointRegistry.sol";
import {AgentFactory} from "../src/erc8004-extensions/AgentFactory.sol";

interface IVersioned {
    function getVersion() external view returns (string memory);
}

/**
 * @title ForkCanonicalExtensionsTest
 * @notice P1.2：三链 fork 干跑。用真实链上状态验证
 *         `DeployCanonicalExtensions.s.sol` 的接线断言在 ETH / Base / BSC 上全部成立。
 *
 *         运行方式（三链各自独立 fork；未设置 URL 的链自动 skip，不影响 `forge test` 离线跑）：
 *           FORK_RPC_ETHEREUM=https://ethereum-rpc.publicnode.com \
 *           FORK_RPC_BASE=https://base-rpc.publicnode.com \
 *           FORK_RPC_BSC=https://bsc-rpc.publicnode.com \
 *           forge test --match-contract ForkCanonicalExtensionsTest -vv
 *
 *         只读最新状态（`getVersion` / `ownerOf` / 构造参数），**不需要 archive 节点**。
 */
contract ForkCanonicalExtensionsTest is Test {
    /// @dev 官方 canonical 单例（三链同址）
    address internal constant CANONICAL_IDENTITY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address internal constant CANONICAL_REPUTATION = 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63;

    address internal deployer = address(this);
    address internal feeCollector = address(0xFEE);

    /// @dev 选择 fork；URL 未配置返回 false（调用方 vm.skip）
    function _fork(string memory envKey) internal returns (bool) {
        string memory url = vm.envOr(envKey, string(""));
        if (bytes(url).length == 0) return false;
        vm.createSelectFork(url);
        return true;
    }

    /// @dev 与部署脚本逐行等价的部署 + 接线断言
    function _deployAndAssert() internal {
        assertGt(CANONICAL_IDENTITY.code.length, 0, "canonical identity has no code");
        assertGt(CANONICAL_REPUTATION.code.length, 0, "canonical reputation has no code");
        assertEq(IVersioned(CANONICAL_IDENTITY).getVersion(), "2.0.0", "identity version");
        assertEq(IVersioned(CANONICAL_REPUTATION).getVersion(), "2.0.0", "reputation version");

        TokenPriceOracle priceOracle = new TokenPriceOracle();
        ERC8004SubscriptionManager subscriptions =
            new ERC8004SubscriptionManager(CANONICAL_IDENTITY, address(priceOracle), feeCollector);
        subscriptions.setDefaultPlatformFee(250);

        A2AProtocolRegistry a2a = new A2AProtocolRegistry(CANONICAL_IDENTITY);
        ConfigurationRegistry config = new ConfigurationRegistry(CANONICAL_IDENTITY);
        MultiEndpointRegistry endpoints = new MultiEndpointRegistry(CANONICAL_IDENTITY);
        AgentFactory factory = new AgentFactory(CANONICAL_IDENTITY, address(endpoints));

        ValidationRegistryUpgradeable impl = new ValidationRegistryUpgradeable();
        ERC8004Bootstrap bootstrap = new ERC8004Bootstrap();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(bootstrap), abi.encodeCall(ERC8004Bootstrap.initialize, (deployer, CANONICAL_IDENTITY)));
        UUPSUpgradeable(address(proxy)).upgradeToAndCall(
            address(impl), abi.encodeCall(ValidationRegistryUpgradeable.initialize, (CANONICAL_IDENTITY))
        );

        // 地址非零
        assertGt(address(priceOracle).code.length, 0, "oracle");
        assertGt(address(subscriptions).code.length, 0, "sm");
        assertGt(address(a2a).code.length, 0, "a2a");
        assertGt(address(config).code.length, 0, "config");
        assertGt(address(endpoints).code.length, 0, "endpoints");
        assertGt(address(factory).code.length, 0, "factory");
        assertGt(address(proxy).code.length, 0, "validation");

        // identity 接线
        assertEq(address(subscriptions.identityRegistry()), CANONICAL_IDENTITY, "sm: identity");
        assertEq(address(a2a.identityRegistry()), CANONICAL_IDENTITY, "a2a: identity");
        assertEq(address(config.identityRegistry()), CANONICAL_IDENTITY, "config: identity");
        assertEq(address(endpoints.identityRegistry()), CANONICAL_IDENTITY, "endpoints: identity");
        assertEq(address(factory.identityRegistry()), CANONICAL_IDENTITY, "factory: identity");

        // 扩展间接线
        assertEq(address(subscriptions.priceOracle()), address(priceOracle), "sm: oracle");
        assertEq(address(factory.endpointRegistry()), address(endpoints), "factory: endpoints");
        assertTrue(factory.canonicalMode(), "factory: canonical not detected");

        // Validation 代理接线（canonical tag 为 string，6 返回值）
        assertEq(ValidationRegistryUpgradeable(address(proxy)).getIdentityRegistry(), CANONICAL_IDENTITY, "validation: identity");
        assertEq(ValidationRegistryUpgradeable(address(proxy)).getVersion(), "2.0.0", "validation: version");
    }

    function test_ForkEthereum_Wiring() public {
        if (!_fork("FORK_RPC_ETHEREUM")) vm.skip(true);
        _deployAndAssert();
    }

    function test_ForkBase_Wiring() public {
        if (!_fork("FORK_RPC_BASE")) vm.skip(true);
        _deployAndAssert();
    }

    function test_ForkBsc_Wiring() public {
        if (!_fork("FORK_RPC_BSC")) vm.skip(true);
        _deployAndAssert();
    }
}
