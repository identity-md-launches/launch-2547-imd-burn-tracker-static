// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BurnTracker} from "../src/BurnTracker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IIntakeRecords {
    function requests(bytes32 id) external view returns (address payer, address target, bytes4 selector, bool done);
    function failureSelectorOf(bytes32 id) external view returns (bytes4);
}

interface IFrameGas {
    struct Gas {
        uint64 gasLimit;
        uint64 gasTotalUsed;
        uint64 gasMemoryUsed;
        int64 gasRefunded;
        uint64 gasRemaining;
        int64 gasStateUsed;
    }
    function lastFrameGas() external view returns (Gas memory);
}

/// @notice Run with --fork-url URL --fork-block-number 26263700 for the real mainnet fork.
/// Without a fork, replays the recorded bytecode/storage of exactly that block, with no network.
contract MainnetIntakeTest is Test {
    address internal constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint256 internal constant BLOCK = 26_263_700;
    bytes32 internal constant OPEN = bytes32("job.open@job-1");
    bytes32 internal constant CONTINUE = bytes32("job.continue@job-1");
    BurnTracker internal tracker;
    address internal owner = makeAddr("mainnet test owner");
    address internal sponsor = makeAddr("mainnet test sponsor");
    bool internal liveFork;

    function setUp() public {
        try vm.activeFork() returns (uint256) {
            liveFork = true;
            assertEq(block.chainid, 1);
            assertEq(block.number, BLOCK);
        } catch {
            _loadSnapshot();
        }
        assertGt(INTAKE.code.length, 0);
        assertGt(IMD.code.length, 0);
        tracker = new BurnTracker(owner, INTAKE, IMD, OPEN, CONTINUE, 1 days, 2 days);
        deal(IMD, owner, 10 ether);
        deal(IMD, sponsor, 10 ether);
        vm.prank(owner);
        IERC20(IMD).approve(address(tracker), type(uint256).max);
        vm.prank(sponsor);
        IERC20(IMD).approve(address(tracker), type(uint256).max);
    }

    function testMainnetOpenRecordsContractAsPayerAndPaysTreasury() public {
        uint256 amount = tracker.price();
        vm.recordLogs();
        vm.prank(owner);
        bytes32 id = tracker.open('{"objective":"Build the IMD burn tracker","skill":"build-website","host":true}');
        _assertRecord(id);
        assertEq(IERC20(IMD).balanceOf(owner), 10 ether - amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool paid;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == IMD && logs[i].topics.length == 3
                    && logs[i].topics[0] == keccak256("Transfer(address,address,uint256)")
                    && logs[i].topics[1] == bytes32(uint256(uint160(address(tracker))))
            ) {
                assertTrue(logs[i].topics[2] != 0);
                assertEq(abi.decode(logs[i].data, (uint256)), amount);
                paid = true;
            }
        }
        assertTrue(paid, "real Intake did not forward the payment");
        assertEq(IERC20(IMD).balanceOf(address(tracker)), 0);
        assertEq(IERC20(IMD).allowance(address(tracker), INTAKE), 0);
        emit log_named_uint("live fork (1) / recorded mainnet state (0)", liveFork ? 1 : 0);
    }

    function testMainnetContinuationWithRealCompletedResultProof() public {
        bytes memory proof = vm.readFileBinary("test/fixtures/result-754.json");
        bytes32 hash = 0x4b562eab02d12668fe65883883f307d8f0616882478620f898a52c4cc6b6dce5;
        assertEq(keccak256(proof), hash);
        vm.prank(owner);
        bytes32 first = tracker.open('{"objective":"Build the IMD burn tracker","skill":"build-website","host":true}');
        vm.prank(INTAKE);
        tracker.onResult(first, hash, "ipfs://bafybeichhdoipncypsg4qxz6yzsqhbapakkg57uk4cimt66er6n6helwx4/result.json");
        vm.warp(tracker.nextUpdateAt());
        uint256 amount = tracker.price();
        bytes memory body =
            bytes.concat(tracker.bodyPrefix(), bytes("5143db98-ff5c-4864-8da4-09e94860f6dc"), tracker.bodySuffix());
        vm.recordLogs();
        vm.prank(sponsor);
        bytes32 id = tracker.updateBurntracker(proof, amount);
        _assertRecord(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool requested;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == INTAKE
                    && logs[i].topics[0]
                        == keccak256("Requested(bytes32,address,bytes32,bytes,address,bytes4,address,uint256)")
            ) {
                (bytes memory actual, address target, bytes4 selector, address paidAsset, uint256 paidAmount) =
                    abi.decode(logs[i].data, (bytes, address, bytes4, address, uint256));
                assertEq(logs[i].topics[1], id);
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(tracker)))));
                assertEq(logs[i].topics[3], CONTINUE);
                assertEq(actual, body);
                assertEq(target, address(tracker));
                assertEq(selector, tracker.onResult.selector);
                assertEq(paidAsset, IMD);
                assertEq(paidAmount, amount);
                requested = true;
            }
        }
        assertTrue(requested);
    }

    function testMainnetUpdate4545BytesUnder300k() public {
        bytes memory resultJson = vm.readFileBinary("test/fixtures/result-gas-4545.json");
        assertEq(resultJson.length, 4545);
        vm.prank(owner);
        bytes32 id = tracker.open('{"objective":"Build the IMD burn tracker","skill":"build-website","host":true}');
        vm.prank(INTAKE);
        tracker.onResult(id, keccak256(resultJson), "ipfs://fixture/result.json");
        vm.warp(tracker.nextUpdateAt());
        uint256 amount = tracker.price();
        // Foundry top-level calls have separate transaction access lists. Explicit cooling also
        // makes the intended cold-account measurement clear to older Forge versions.
        vm.cool(address(tracker));
        vm.cool(INTAKE);
        vm.cool(IMD);
        vm.prank(sponsor);
        bytes32 continuation = tracker.updateBurntracker(resultJson, amount);
        IFrameGas.Gas memory measured = IFrameGas(address(vm)).lastFrameGas();
        // foundry.toml enables isolation: gasTotalUsed includes intrinsic calldata gas, before
        // refunds. Count the actual capped refund, and separately bound gross execution gas.
        bytes memory callData = abi.encodeCall(tracker.updateBurntracker, (resultJson, amount));
        uint256 intrinsic = 21_000;
        for (uint256 i; i < callData.length; ++i) {
            intrinsic += callData[i] == 0 ? 4 : 16;
        }
        uint256 spent = measured.gasTotalUsed;
        uint256 refund = measured.gasRefunded > 0 ? uint256(uint64(measured.gasRefunded)) : 0;
        if (refund > spent / 5) refund = spent / 5;
        uint256 settled = uint256(int256(spent - refund) + measured.gasStateUsed);
        emit log_named_uint("4545-byte gross execution gas (before refunds, excluding intrinsic)", spent - intrinsic);
        emit log_named_uint("4545-byte transaction gas (including intrinsic, after capped refunds)", settled);
        emit log_named_uint("4545-byte transaction gas before refunds", spent);
        assertLt(spent - intrinsic, 300_000);
        assertLt(settled, 300_000);
        _assertRecord(continuation);
        assertEq(IERC20(IMD).balanceOf(sponsor), 10 ether - amount);
        assertEq(IERC20(IMD).balanceOf(address(tracker)), 0);
        assertEq(IERC20(IMD).allowance(address(tracker), INTAKE), 0);
    }

    function _assertRecord(bytes32 id) internal view {
        (address payer, address target, bytes4 selector, bool done) = IIntakeRecords(INTAKE).requests(id);
        assertEq(payer, address(tracker));
        assertEq(target, address(tracker));
        assertEq(selector, tracker.onResult.selector);
        assertFalse(done);
        assertEq(IIntakeRecords(INTAKE).failureSelectorOf(id), tracker.onFailure.selector);
    }

    function _loadSnapshot() internal {
        string memory data = vm.readFile("test/fixtures/mainnet-state.json");
        vm.chainId(1);
        vm.roll(vm.parseJsonUint(data, ".blockNumber"));
        vm.warp(vm.parseJsonUint(data, ".timestamp"));
        uint256 count = vm.parseJsonUint(data, ".accountCount");
        for (uint256 i; i < count; ++i) {
            string memory base = string.concat(".accounts[", vm.toString(i), "]");
            address account = vm.parseJsonAddress(data, string.concat(base, ".address"));
            vm.etch(account, vm.parseJsonBytes(data, string.concat(base, ".code")));
            uint256 slots = vm.parseJsonUint(data, string.concat(base, ".slotCount"));
            for (uint256 j; j < slots; ++j) {
                string memory path = string.concat(base, ".storage[", vm.toString(j), "]");
                vm.store(
                    account,
                    vm.parseJsonBytes32(data, string.concat(path, ".key")),
                    vm.parseJsonBytes32(data, string.concat(path, ".value"))
                );
            }
        }
    }
}
