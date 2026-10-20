// contracts/erc8004-extensions/SettlementRegistry.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import {SettlementRecord, ISettlementVerifier} from "./PaymentReputationOracle.sol";

/**
 * @title SettlementRegistry
 * @notice WS9 的「链上结算承诺」件（Option A 兜底）：
 *         由授权的引擎中继把 infraX/WS2 的结算记录以 `settlementRef` 为键写入链上，
 *         供 `SettlementRegistryVerifier` 读取后与付款方的 `SettlementProof` 逐字段交叉核对。
 *
 * 信任模型：中继可信（relayer）。BSC 旗舰链上优先走 Option C（直读 ERC-8183，无信任），
 *           本件用于其他 rail / 其他链的兜底，以及 WS2 就绪前的过渡。
 */
contract SettlementRegistry is Ownable {
    mapping(address => bool) public writers;
    mapping(bytes32 => SettlementRecord) private _records;

    event WriterUpdated(address indexed writer, bool allowed);
    event SettlementWritten(
        bytes32 indexed settlementRef,
        uint256 indexed agentId,
        address payer,
        address asset,
        uint256 amount,
        string rail,
        uint64 settledAt
    );

    error Registry__NotWriter();
    error Registry__AlreadyWritten();

    constructor() Ownable(msg.sender) {}

    modifier onlyWriter() {
        if (!writers[msg.sender]) revert Registry__NotWriter();
        _;
    }

    function setWriter(address writer, bool allowed) external onlyOwner {
        writers[writer] = allowed;
        emit WriterUpdated(writer, allowed);
    }

    /// @notice 写入一笔结算承诺（幂等：同一 settlementRef 不可重复）。
    function writeSettlement(
        bytes32 settlementRef,
        uint256 agentId,
        address payer,
        address asset,
        uint256 amount,
        string calldata rail,
        uint64 settledAt
    ) external onlyWriter {
        if (_records[settlementRef].exists) revert Registry__AlreadyWritten();
        _records[settlementRef] = SettlementRecord({
            agentId: agentId,
            payer: payer,
            asset: asset,
            amount: amount,
            rail: rail,
            settledAt: settledAt,
            exists: true
        });
        emit SettlementWritten(settlementRef, agentId, payer, asset, amount, rail, settledAt);
    }

    function getRecord(bytes32 settlementRef) external view returns (SettlementRecord memory) {
        return _records[settlementRef];
    }
}

/**
 * @title SettlementRegistryVerifier
 * @notice `ISettlementVerifier` 的 Option A 实现：读 `SettlementRegistry`。
 */
contract SettlementRegistryVerifier is ISettlementVerifier {
    SettlementRegistry public immutable registry;

    error Verifier__ZeroAddress();

    constructor(address registry_) {
        if (registry_ == address(0)) revert Verifier__ZeroAddress();
        registry = SettlementRegistry(registry_);
    }

    function verifySettlement(
        uint256,
        address,
        address,
        uint256,
        string calldata,
        bytes32 settlementRef,
        uint64
    ) external view returns (SettlementRecord memory) {
        return registry.getRecord(settlementRef);
    }
}
