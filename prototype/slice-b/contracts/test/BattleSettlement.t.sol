// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {BattleSettlement} from "../src/BattleSettlement.sol";

// Minimal cheatcode surface; deliberately no forge-std dependency
// (prototype-and-technology.md §2.2 generalisation constraint).
interface Vm {
    function sign(uint256 privateKey, bytes32 digest) external pure returns (uint8 v, bytes32 r, bytes32 s);
    function addr(uint256 privateKey) external pure returns (address);
    function warp(uint256 newTimestamp) external;
    function prank(address sender) external;
    function expectRevert(bytes calldata revertData) external;
}

contract BattleSettlementTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    BattleSettlement c;

    uint256 constant PK_A = 0xA11CE;
    uint256 constant PK_B = 0xB0B;
    uint256 constant PK_EVE = 0xE7E;
    address playerA;
    address playerB;

    bytes32 constant BATTLE_ID = keccak256("battle-1");
    bytes32 constant RULESET = keccak256("blockmon/ruleset/v0-test");
    bytes32 constant ED_PK_A = bytes32(uint256(0xaa));
    bytes32 constant X_PK_A = bytes32(uint256(0xab));
    bytes32 constant ED_PK_B = bytes32(uint256(0xba));
    bytes32 constant X_PK_B = bytes32(uint256(0xbb));
    uint64 constant DEADLINE = 1_000_000;
    uint64 constant EXPIRY = 2_000_000;

    function setUp() public {
        c = new BattleSettlement();
        playerA = vm.addr(PK_A);
        playerB = vm.addr(PK_B);
        vm.warp(1000);
        c.createBattle(BATTLE_ID, playerA, playerB, RULESET, DEADLINE);
    }

    // -- helpers ------------------------------------------------------------

    function authDigest(bytes32 edPk, bytes32 xPk) internal view returns (bytes32) {
        return ethHash(
            keccak256(abi.encode(c.KEY_AUTH_TAG(), block.chainid, address(c), BATTLE_ID, RULESET, edPk, xPk, EXPIRY))
        );
    }

    function checkpointDigest(uint64 seq, bytes32 commitment, uint8 result) internal view returns (bytes32) {
        return ethHash(
            keccak256(
                abi.encode(c.CHECKPOINT_TAG(), block.chainid, address(c), BATTLE_ID, RULESET, seq, commitment, result)
            )
        );
    }

    function ethHash(bytes32 h) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h));
    }

    function sig(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // Own stack frame: the crowded tests cannot afford a fourth return value.
    function settledCommitment(bytes32 id) internal view returns (bytes32) {
        (,,, bytes32 sc) = c.resultOf(id);
        return sc;
    }

    function registerBoth() internal {
        c.registerKeys(BATTLE_ID, playerA, ED_PK_A, X_PK_A, EXPIRY, sig(PK_A, authDigest(ED_PK_A, X_PK_A)));
        c.registerKeys(BATTLE_ID, playerB, ED_PK_B, X_PK_B, EXPIRY, sig(PK_B, authDigest(ED_PK_B, X_PK_B)));
    }

    // -- cooperative path ---------------------------------------------------

    function test_cooperativeSettle() public {
        registerBoth();
        bytes32 commitment = keccak256("state");
        bytes32 d = checkpointDigest(7, commitment, 1);
        c.settle(BATTLE_ID, 7, commitment, 1, sig(PK_A, d), sig(PK_B, d));
        (uint8 status, uint8 result, uint64 finalSeq,) = c.resultOf(BATTLE_ID);
        require(status == 3 && result == 1 && finalSeq == 7, "settle state wrong");
        require(settledCommitment(BATTLE_ID) == commitment, "settled state commitment not recorded");
    }

    // -- negative paths -----------------------------------------------------

    function test_invalidSignatureRejected() public {
        registerBoth();
        bytes32 commitment = keccak256("state");
        bytes32 d = checkpointDigest(7, commitment, 1);
        vm.expectRevert(bytes("bad sig B"));
        c.settle(BATTLE_ID, 7, commitment, 1, sig(PK_A, d), sig(PK_EVE, d));
    }

    function test_duplicateSettlementRejected() public {
        registerBoth();
        bytes32 commitment = keccak256("state");
        bytes32 d = checkpointDigest(7, commitment, 1);
        c.settle(BATTLE_ID, 7, commitment, 1, sig(PK_A, d), sig(PK_B, d));
        bytes32 d2 = checkpointDigest(8, commitment, 2);
        vm.expectRevert(bytes("not settleable"));
        c.settle(BATTLE_ID, 8, commitment, 2, sig(PK_A, d2), sig(PK_B, d2));
    }

    function test_settleWithoutAnchoredKeysRejected() public {
        bytes32 commitment = keccak256("state");
        bytes32 d = checkpointDigest(7, commitment, 1);
        vm.expectRevert(bytes("keys not anchored"));
        c.settle(BATTLE_ID, 7, commitment, 1, sig(PK_A, d), sig(PK_B, d));
    }

    function test_authorisationReplayAcrossBattlesRejected() public {
        registerBoth();
        // same players, new battle: A's old authorisation must not transplant
        bytes32 otherId = keccak256("battle-2");
        c.createBattle(otherId, playerA, playerB, RULESET, DEADLINE);
        bytes memory replayed = sig(PK_A, authDigest(ED_PK_A, X_PK_A)); // bound to BATTLE_ID
        vm.expectRevert(bytes("bad authorisation"));
        c.registerKeys(otherId, playerA, ED_PK_A, X_PK_A, EXPIRY, replayed);
    }

    function test_expiredAuthorisationRejected() public {
        bytes memory s = sig(PK_A, authDigest(ED_PK_A, X_PK_A));
        vm.warp(EXPIRY + 1);
        vm.expectRevert(bytes("authorisation expired"));
        c.registerKeys(BATTLE_ID, playerA, ED_PK_A, X_PK_A, EXPIRY, s);
    }

    // -- timeout / supersession ----------------------------------------------

    function test_timeoutDefaultOutcome() public {
        registerBoth();
        vm.warp(DEADLINE + 1);
        vm.prank(playerA);
        c.initiateTimeout(BATTLE_ID, 0, bytes32(0), 0, "", "");
        vm.warp(DEADLINE + 1 + c.RESPONSE_WINDOW() + 1);
        c.finalizeTimeout(BATTLE_ID);
        (uint8 status, uint8 result, uint64 finalSeq,) = c.resultOf(BATTLE_ID);
        require(status == 3 && result == 3 && finalSeq == 0, "default outcome wrong");
        require(settledCommitment(BATTLE_ID) == bytes32(0), "default outcome must record no state");
    }

    function test_staleCheckpointSuperseded() public {
        registerBoth();
        bytes32 stale = keccak256("state-4");
        bytes32 fresh = keccak256("state-9");
        vm.warp(DEADLINE + 1);
        bytes32 d4 = checkpointDigest(4, stale, 2);
        vm.prank(playerB);
        c.initiateTimeout(BATTLE_ID, 4, stale, 2, sig(PK_A, d4), sig(PK_B, d4));
        bytes32 d9 = checkpointDigest(9, fresh, 1);
        c.counterTimeout(BATTLE_ID, 9, fresh, 1, sig(PK_A, d9), sig(PK_B, d9));
        vm.warp(DEADLINE + 1 + c.RESPONSE_WINDOW() + 1);
        c.finalizeTimeout(BATTLE_ID);
        (, uint8 result, uint64 finalSeq,) = c.resultOf(BATTLE_ID);
        require(result == 1 && finalSeq == 9, "supersession failed");
        require(settledCommitment(BATTLE_ID) == fresh, "superseding checkpoint's state not recorded");
    }

    function test_lowerSeqCounterRejected() public {
        registerBoth();
        bytes32 fresh = keccak256("state-9");
        vm.warp(DEADLINE + 1);
        bytes32 d9 = checkpointDigest(9, fresh, 1);
        vm.prank(playerA);
        c.initiateTimeout(BATTLE_ID, 9, fresh, 1, sig(PK_A, d9), sig(PK_B, d9));
        bytes32 stale = keccak256("state-4");
        bytes32 d4 = checkpointDigest(4, stale, 2);
        vm.expectRevert(bytes("stale checkpoint"));
        c.counterTimeout(BATTLE_ID, 4, stale, 2, sig(PK_A, d4), sig(PK_B, d4));
    }

    function test_finalizeBeforeWindowRejected() public {
        registerBoth();
        vm.warp(DEADLINE + 1);
        vm.prank(playerA);
        c.initiateTimeout(BATTLE_ID, 0, bytes32(0), 0, "", "");
        vm.expectRevert(bytes("window open"));
        c.finalizeTimeout(BATTLE_ID);
    }

    function test_timeoutBeforeDeadlineRejected() public {
        registerBoth();
        vm.prank(playerA);
        vm.expectRevert(bytes("deadline not reached"));
        c.initiateTimeout(BATTLE_ID, 0, bytes32(0), 0, "", "");
    }

    function test_staleCooperativeSettleRejected() public {
        registerBoth();
        bytes32 fresh = keccak256("state-9");
        vm.warp(DEADLINE + 1);
        bytes32 d9 = checkpointDigest(9, fresh, 1);
        vm.prank(playerA);
        c.initiateTimeout(BATTLE_ID, 9, fresh, 1, sig(PK_A, d9), sig(PK_B, d9));
        bytes32 stale = keccak256("state-4");
        bytes32 d4 = checkpointDigest(4, stale, 2);
        bytes memory sA = sig(PK_A, d4);
        bytes memory sB = sig(PK_B, d4);
        vm.expectRevert(bytes("stale checkpoint"));
        c.settle(BATTLE_ID, 4, stale, 2, sA, sB);
        bytes32 d10 = checkpointDigest(10, fresh, 1);
        c.settle(BATTLE_ID, 10, fresh, 1, sig(PK_A, d10), sig(PK_B, d10));
        (uint8 status, uint8 result, uint64 finalSeq,) = c.resultOf(BATTLE_ID);
        require(status == 3 && result == 1 && finalSeq == 10, "higher-seq settle failed");
    }

    function test_cooperativeSettleSupersedesPendingTimeout() public {
        registerBoth();
        vm.warp(DEADLINE + 1);
        vm.prank(playerA);
        c.initiateTimeout(BATTLE_ID, 0, bytes32(0), 0, "", "");
        bytes32 commitment = keccak256("state");
        bytes32 d = checkpointDigest(7, commitment, 2);
        c.settle(BATTLE_ID, 7, commitment, 2, sig(PK_A, d), sig(PK_B, d));
        (uint8 status, uint8 result,,) = c.resultOf(BATTLE_ID);
        require(status == 3 && result == 2, "cooperative supersede failed");
    }
}
