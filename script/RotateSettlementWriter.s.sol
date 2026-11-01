// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

/**
 * @title RotateSettlementWriter
 * @notice 用于三链 SettlementRegistry 的 writer 授权/撤销。
 *
 *         背景：泄露 EOA `0x978e92477ff613c307e25Bf0ed1D50E9483782C4` 在
 *         BSC / Ethereum / Base 三个 SettlementRegistry 里都是已授权的 writer
 *         （`writers(0x978e…) == true`），且它的私钥还留在生产 `.env` 的
 *         `SETTLEMENT_WRITER_PRIVATE_KEY` 里。攻击者无需抢 owner 就能写结算记录。
 *
 *         正确顺序（避免网关写结算中断）：
 *           1. ACTION=grant  NEW_WRITER=<新热钱包>   —— 先授权新 writer；
 *           2. 换掉生产 `.env` 的 SETTLEMENT_WRITER_PRIVATE_KEY 并重启网关；
 *           3. ACTION=revoke OLD_WRITER=0x978e…     —— 再撤销泄露地址。
 *
 *         前置：签名者必须是该 SettlementRegistry 的 owner（当前仍是泄露地址，
 *         所以必须先于 transferOwnership 执行）。
 *
 *         用法（每链独立执行）：
 *           PRIVATE_KEY=<owner 私钥> \
 *           SETTLEMENT_REGISTRY=<addr> \
 *           ACTION=grant|revoke \
 *           WRITER=<addr> \
 *           forge script script/RotateSettlementWriter.s.sol:RotateSettlementWriter \
 *             --rpc-url <RPC> --broadcast --chain <ID>
 *
 *         可选 env：
 *           DRY_RUN=true   只做前置校验并打印计划，不广播
 *
 *         幂等：目标状态已达成时跳过，可安全重跑。
 */
interface ISettlementRegistry {
    function owner() external view returns (address);
    function writers(address writer) external view returns (bool);
    function setWriter(address writer, bool allowed) external;
}

contract RotateSettlementWriter is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(pk);
        address registryAddr = vm.envAddress("SETTLEMENT_REGISTRY");
        address writer = vm.envAddress("WRITER");
        string memory action = vm.envString("ACTION");
        bool dryRun = vm.envOr("DRY_RUN", false);

        require(registryAddr.code.length > 0, "SETTLEMENT_REGISTRY has no code");
        require(writer != address(0), "WRITER is zero");

        bool allow;
        if (keccak256(bytes(action)) == keccak256(bytes("grant"))) {
            allow = true;
        } else if (keccak256(bytes(action)) == keccak256(bytes("revoke"))) {
            allow = false;
        } else {
            revert("ACTION must be grant or revoke");
        }

        ISettlementRegistry registry = ISettlementRegistry(registryAddr);
        require(registry.owner() == signer, "PRIVATE_KEY is not the SettlementRegistry owner");

        bool current = registry.writers(writer);

        console.log("");
        console.log("==============================================");
        console.log("  RotateSettlementWriter");
        console.log("==============================================");
        console.log("  signer (owner):      ", signer);
        console.log("  registry:            ", registryAddr);
        console.log("  writer:              ", writer);
        console.log("  action:              ", action);
        console.log("  writers(writer) now: ", current);

        if (current == allow) {
            console.log("  [skip] already in target state");
            console.log("==============================================");
            return;
        }

        if (dryRun) {
            console.log("  [tx] setWriter(allowed=%s)", allow);
            console.log("  DRY_RUN=true - nothing broadcast.");
            console.log("==============================================");
            return;
        }

        vm.startBroadcast(pk);
        registry.setWriter(writer, allow);
        vm.stopBroadcast();

        require(registry.writers(writer) == allow, "writer state not updated");
        console.log("");
        console.log("  --- verify ---");
        console.log("  writers(writer) after:", registry.writers(writer));
        console.log("==============================================");
    }
}
