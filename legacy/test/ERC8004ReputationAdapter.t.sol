// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/erc8004-extensions/ERC8004ReputationAdapter.sol";

/**
 * @dev 最小 legacy 信誉注册表模拟（自研 erc8004-core 口径：uint8 score / bytes32 标签），
 *      **有** `getReputationSummary`（用于触发适配器的 legacy 模式探测）。
 */
contract MockLegacyReputation {
    address private _identity;

    mapping(uint256 => address[]) private _clients;
    mapping(uint256 => mapping(address => uint64)) private _lastIndex;
    mapping(uint256 => mapping(address => mapping(uint64 => uint8))) private _scores;
    mapping(uint256 => mapping(address => mapping(uint64 => bytes32))) private _tag1;
    mapping(uint256 => mapping(address => mapping(uint64 => bytes32))) private _tag2;

    constructor(address identity) {
        _identity = identity;
    }

    function setFeedback(
        uint256 agentId,
        address client,
        uint64 index,
        uint8 score,
        bytes32 tag1,
        bytes32 tag2
    ) external {
        if (_lastIndex[agentId][client] == 0) {
            _clients[agentId].push(client);
        }
        _scores[agentId][client][index] = score;
        _tag1[agentId][client][index] = tag1;
        _tag2[agentId][client][index] = tag2;
        if (index > _lastIndex[agentId][client]) {
            _lastIndex[agentId][client] = index;
        }
    }

    function getReputationSummary(
        uint256 agentId,
        address[] calldata clientAddresses,
        bytes32 tag1,
        bytes32 tag2
    ) external view returns (uint64 count, uint8 averageScore) {
        address[] memory clients;
        if (clientAddresses.length > 0) {
            clients = clientAddresses;
        } else {
            clients = _clients[agentId];
        }

        uint256 total;
        for (uint256 i; i < clients.length; i++) {
            uint64 last = _lastIndex[agentId][clients[i]];
            for (uint64 j = 1; j <= last; j++) {
                if (tag1 != bytes32(0) && _tag1[agentId][clients[i]][j] != tag1) continue;
                if (tag2 != bytes32(0) && _tag2[agentId][clients[i]][j] != tag2) continue;
                total += _scores[agentId][clients[i]][j];
                count++;
            }
        }
        if (count > 0) {
            averageScore = uint8(total / count);
        }
    }

    function readFeedback(
        uint256 agentId,
        address clientAddress,
        uint64 index
    ) external view returns (uint8 score, bytes32 tag1, bytes32 tag2, bool isRevoked) {
        return (
            _scores[agentId][clientAddress][index],
            _tag1[agentId][clientAddress][index],
            _tag2[agentId][clientAddress][index],
            false
        );
    }

    function getClients(uint256 agentId) external view returns (address[] memory) {
        return _clients[agentId];
    }

    function getLastIndex(uint256 agentId, address clientAddress) external view returns (uint64) {
        return _lastIndex[agentId][clientAddress];
    }

    function getIdentityRegistry() external view returns (address) {
        return _identity;
    }
}

/**
 * @dev 最小 canonical 信誉注册表模拟（标准口径：int128 value / uint8 decimals / string 标签），
 *      **无** `getReputationSummary` → 触发适配器 canonical 模式探测。
 */
contract MockCanonicalReputation {
    address private _identity;

    mapping(uint256 => address[]) private _clients;
    mapping(uint256 => mapping(address => uint64)) private _lastIndex;
    mapping(uint256 => mapping(address => mapping(uint64 => int128))) private _values;
    mapping(uint256 => mapping(address => mapping(uint64 => uint8))) private _decimals;
    mapping(uint256 => mapping(address => mapping(uint64 => string))) private _tag1;
    mapping(uint256 => mapping(address => mapping(uint64 => string))) private _tag2;

    constructor(address identity) {
        _identity = identity;
    }

    function setFeedback(
        uint256 agentId,
        address client,
        uint64 index,
        int128 value,
        uint8 decimals,
        string calldata tag1,
        string calldata tag2
    ) external {
        if (_lastIndex[agentId][client] == 0) {
            _clients[agentId].push(client);
        }
        _values[agentId][client][index] = value;
        _decimals[agentId][client][index] = decimals;
        _tag1[agentId][client][index] = tag1;
        _tag2[agentId][client][index] = tag2;
        if (index > _lastIndex[agentId][client]) {
            _lastIndex[agentId][client] = index;
        }
    }

    function getSummary(
        uint256 agentId,
        address[] calldata clientAddresses,
        string calldata tag1,
        string calldata tag2
    ) external view returns (uint64 count, int128 value, uint8 valueDecimals) {
        require(clientAddresses.length > 0, "clientAddresses required");

        int256 sum;
        uint8 dec;
        bool found;
        bytes32 t1Hash = keccak256(bytes(tag1));
        bytes32 t2Hash = keccak256(bytes(tag2));
        bytes32 emptyHash = keccak256(bytes(""));

        for (uint256 i; i < clientAddresses.length; i++) {
            uint64 last = _lastIndex[agentId][clientAddresses[i]];
            for (uint64 j = 1; j <= last; j++) {
                if (emptyHash != t1Hash && t1Hash != keccak256(bytes(_tag1[agentId][clientAddresses[i]][j]))) continue;
                if (emptyHash != t2Hash && t2Hash != keccak256(bytes(_tag2[agentId][clientAddresses[i]][j]))) continue;
                if (!found) {
                    dec = _decimals[agentId][clientAddresses[i]][j];
                    found = true;
                }
                sum += int256(_values[agentId][clientAddresses[i]][j]);
                count++;
            }
        }
        if (count > 0) {
            value = int128(sum / int256(uint256(count)));
            valueDecimals = dec;
        }
    }

    function readFeedback(
        uint256 agentId,
        address clientAddress,
        uint64 index
    ) external view returns (int128 value, uint8 valueDecimals, string memory tag1, string memory tag2, bool isRevoked) {
        return (
            _values[agentId][clientAddress][index],
            _decimals[agentId][clientAddress][index],
            _tag1[agentId][clientAddress][index],
            _tag2[agentId][clientAddress][index],
            false
        );
    }

    function getClients(uint256 agentId) external view returns (address[] memory) {
        return _clients[agentId];
    }

    function getLastIndex(uint256 agentId, address clientAddress) external view returns (uint64) {
        return _lastIndex[agentId][clientAddress];
    }

    function getIdentityRegistry() external view returns (address) {
        return _identity;
    }
}

/**
 * @title ERC8004ReputationAdapter 测试
 * @notice 验证 WS9 A 类前置：信誉只读桥在 legacy（erc8004-core）与 canonical（官方标准）
 *         两种模式下均可读；legacy 兼容面与标准面互转正确；写路径拒绝。
 */
contract ERC8004ReputationAdapterTest is Test {
    address internal identity = makeAddr("identity");
    address internal oracle = makeAddr("oracle");
    address internal client2 = makeAddr("client2");

    // ── 构造守卫 ────────────────────────────────────────────────────────

    function test_Constructor_RejectsZeroAddress() public {
        vm.expectRevert(ERC8004ReputationAdapter.ReputationAdapter__ZeroAddress.selector);
        new ERC8004ReputationAdapter(address(0));
    }

    function test_Constructor_RejectsNonContract() public {
        vm.expectRevert(ERC8004ReputationAdapter.ReputationAdapter__NotAContract.selector);
        new ERC8004ReputationAdapter(oracle);
    }

    // ── legacy 模式 ─────────────────────────────────────────────────────

    function test_LegacyMode_DetectedAndReads() public {
        MockLegacyReputation legacy = new MockLegacyReputation(identity);
        legacy.setFeedback(1, oracle, 1, 80, bytes32("research"), bytes32(0));
        legacy.setFeedback(1, oracle, 2, 90, bytes32("research"), bytes32(0));
        legacy.setFeedback(1, client2, 1, 70, bytes32("research"), bytes32(0));

        ERC8004ReputationAdapter adapter = new ERC8004ReputationAdapter(address(legacy));
        assertFalse(adapter.canonicalMode());
        assertEq(adapter.getIdentityRegistry(), identity);

        address[] memory empty = new address[](0);
        (uint64 count, uint8 averageScore) = adapter.getReputationSummary(1, empty, bytes32(0), bytes32(0));
        assertEq(count, 3);
        assertEq(averageScore, 80); // (80+90+70)/3

        // 标准面归一化：legacy 均分 → (count, avg, 0)
        (uint64 c2, int128 value, uint8 dec) = adapter.getSummary(1, empty, "", "");
        assertEq(c2, 3);
        assertEq(value, int128(80));
        assertEq(dec, 0);

        (uint8 score, bytes32 tag1, , bool revoked) = adapter.readFeedback(1, oracle, 1);
        assertEq(score, 80);
        assertEq(tag1, bytes32("research"));
        assertFalse(revoked);

        (int128 v, uint8 d, string memory s1, , ) = adapter.getFeedback(1, oracle, 1);
        assertEq(v, int128(80));
        assertEq(d, 0);
        assertEq(s1, "research");

        assertEq(adapter.getLastIndex(1, oracle), 2);
        assertEq(adapter.getClients(1).length, 2);
    }

    function test_LegacyMode_TagTooLongReverts() public {
        MockLegacyReputation legacy = new MockLegacyReputation(identity);
        ERC8004ReputationAdapter adapter = new ERC8004ReputationAdapter(address(legacy));

        address[] memory empty = new address[](0);
        // 33 字节标签无法编码为 legacy bytes32
        vm.expectRevert(ERC8004ReputationAdapter.ReputationAdapter__TagTooLong.selector);
        adapter.getSummary(1, empty, "0123456789012345678901234567890123", "");
    }

    // ── canonical（官方标准）模式 ───────────────────────────────────────

    function test_CanonicalMode_DetectedAndReads() public {
        MockCanonicalReputation canon = new MockCanonicalReputation(identity);
        canon.setFeedback(0, oracle, 1, 95, 0, "payment-settlement", "");
        canon.setFeedback(0, oracle, 2, 85, 0, "payment-settlement", "");

        ERC8004ReputationAdapter adapter = new ERC8004ReputationAdapter(address(canon));
        assertTrue(adapter.canonicalMode());
        assertEq(adapter.getIdentityRegistry(), identity);

        address[] memory clients = new address[](1);
        clients[0] = oracle;

        (uint64 count, int128 value, uint8 dec) = adapter.getSummary(0, clients, "payment-settlement", "");
        assertEq(count, 2);
        assertEq(value, int128(90));
        assertEq(dec, 0);

        // canonical：空 clients 直接转调标准 → revert（标准要求显式传入客户地址）
        address[] memory empty = new address[](0);
        vm.expectRevert();
        adapter.getSummary(0, empty, "payment-settlement", "");

        (int128 v, uint8 d, string memory s1, , ) = adapter.getFeedback(0, oracle, 1);
        assertEq(v, int128(95));
        assertEq(d, 0);
        assertEq(s1, "payment-settlement");

        assertEq(adapter.getLastIndex(0, oracle), 2);
        assertEq(adapter.getClients(0).length, 1);
    }

    function test_CanonicalMode_LegacyCompatDerivesScore() public {
        MockCanonicalReputation canon = new MockCanonicalReputation(identity);
        canon.setFeedback(0, oracle, 1, 95, 0, "payment-settlement", "");
        canon.setFeedback(0, oracle, 2, 85, 0, "payment-settlement", "");

        ERC8004ReputationAdapter adapter = new ERC8004ReputationAdapter(address(canon));

        address[] memory clients = new address[](1);
        clients[0] = oracle;

        (uint64 count, uint8 averageScore) = adapter.getReputationSummary(
            0,
            clients,
            bytes32("payment-settlement"),
            bytes32(0)
        );
        assertEq(count, 2);
        assertEq(averageScore, 90);

        (uint8 score, bytes32 tag1, , ) = adapter.readFeedback(0, oracle, 1);
        assertEq(score, 95);
        assertEq(tag1, bytes32("payment-settlement"));
    }

    function test_CanonicalMode_ScoreClampedTo0To100() public {
        MockCanonicalReputation canon = new MockCanonicalReputation(identity);
        canon.setFeedback(0, oracle, 1, 150, 0, "", "");
        canon.setFeedback(0, oracle, 2, -10, 0, "", "");

        ERC8004ReputationAdapter adapter = new ERC8004ReputationAdapter(address(canon));
        address[] memory clients = new address[](1);
        clients[0] = oracle;

        (uint64 count, uint8 averageScore) = adapter.getReputationSummary(0, clients, bytes32(0), bytes32(0));
        assertEq(count, 2);
        assertEq(averageScore, 70); // (150 + (-10)) / 2 = 70

        // 单条越界值 → 夹取到边界
        (uint8 high, , , ) = adapter.readFeedback(0, oracle, 1);
        assertEq(high, 100); // 150 → 100
        (uint8 low, , , ) = adapter.readFeedback(0, oracle, 2);
        assertEq(low, 0); // -10 → 0
    }

    // ── 写路径拒绝 ──────────────────────────────────────────────────────

    function test_WritesRevertReadOnly() public {
        MockCanonicalReputation canon = new MockCanonicalReputation(identity);
        ERC8004ReputationAdapter adapter = new ERC8004ReputationAdapter(address(canon));

        vm.expectRevert(ERC8004ReputationAdapter.ReputationAdapter__ReadOnly.selector);
        adapter.giveFeedback(0, 90, bytes32("t"), bytes32(0), "", bytes32(0), "");
        vm.expectRevert(ERC8004ReputationAdapter.ReputationAdapter__ReadOnly.selector);
        adapter.revokeFeedback(0, 1);
        vm.expectRevert(ERC8004ReputationAdapter.ReputationAdapter__ReadOnly.selector);
        adapter.appendResponse(0, oracle, 1, "uri", bytes32(0));
    }
}
