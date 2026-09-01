// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/// Slice B stand-in for the canonical constitutional layer (battle-channel.md §1).
/// Thin verifier only (battle-channel.md §5): existence/participants, binding,
/// final checkpoint, authorisations/signatures, supersession, non-duplication.
/// Deliberately not generalised (prototype-and-technology.md §2.2).
///
/// Stand-in limitation, on purpose: channel operations are Ed25519-signed
/// off-chain and the EVM cannot verify those cheaply, so settlement here is
/// authorised by wallet co-signatures over the checkpoint digest. The
/// stateCommitment commits to the Ed25519-signed transcript head, so the
/// channel evidence is bound. In production the anchor venue (the canonical
/// layer) verifies the ephemeral signatures directly.
contract BattleSettlement {
    enum Status {
        None,
        Open,
        TimeoutPending,
        Settled
    }

    struct Keys {
        bytes32 edPk;
        bytes32 xPk;
        bool registered;
    }

    struct Battle {
        address playerA;
        address playerB;
        bytes32 rulesetHash;
        uint64 deadline;
        Status status;
        uint8 result; // 0 none, 1 A, 2 B, 3 default/draw
        uint64 finalSeq;
        bytes32 finalCommitment; // the settled state, so a reader can bind it to a transcript
        address claimant;
        uint64 responseWindowEnd;
        uint64 pendingSeq;
        uint8 pendingResult;
        bytes32 pendingCommitment;
    }

    bytes32 public constant KEY_AUTH_TAG = keccak256("blockmon/battle-key-auth/v0");
    bytes32 public constant CHECKPOINT_TAG = keccak256("blockmon/battle-checkpoint/v0");
    uint64 public constant RESPONSE_WINDOW = 1 hours;

    // Private: the auto-generated getter for a struct this wide exceeds the EVM
    // stack without the optimizer. bindingOf/resultOf are the read surface.
    mapping(bytes32 => Battle) private battles;
    mapping(bytes32 => mapping(address => Keys)) public keysOf;

    function createBattle(bytes32 battleId, address playerA, address playerB, bytes32 rulesetHash, uint64 deadline)
        external
    {
        Battle storage b = battles[battleId];
        require(b.status == Status.None, "battle exists");
        require(playerA != playerB && playerA != address(0) && playerB != address(0), "bad players");
        b.playerA = playerA;
        b.playerB = playerB;
        b.rulesetHash = rulesetHash;
        b.deadline = deadline;
        b.status = Status.Open;
    }

    /// Wallet-authorised anchoring of ephemeral battle public keys
    /// (battle-channel.md §3). The authorisation binds battleId + keys +
    /// rulesetHash + expiry; an unbound authorisation would replay.
    function registerKeys(
        bytes32 battleId,
        address player,
        bytes32 edPk,
        bytes32 xPk,
        uint64 expiry,
        bytes calldata sig
    ) external {
        Battle storage b = battles[battleId];
        require(b.status == Status.Open, "not open");
        require(player == b.playerA || player == b.playerB, "not a participant");
        require(block.timestamp <= expiry, "authorisation expired");
        require(!keysOf[battleId][player].registered, "already registered");
        bytes32 digest = _ethHash(
            keccak256(
                abi.encode(KEY_AUTH_TAG, block.chainid, address(this), battleId, b.rulesetHash, edPk, xPk, expiry)
            )
        );
        require(_recover(digest, sig) == player, "bad authorisation");
        keysOf[battleId][player] = Keys(edPk, xPk, true);
    }

    /// Cooperative settlement: one compact dual-authorised final checkpoint.
    function settle(
        bytes32 battleId,
        uint64 seq,
        bytes32 stateCommitment,
        uint8 result,
        bytes calldata sigA,
        bytes calldata sigB
    ) external {
        Battle storage b = battles[battleId];
        require(b.status == Status.Open || b.status == Status.TimeoutPending, "not settleable");
        // Supersession (battle-channel.md §§4-5): a checkpoint at or below the
        // pending timeout claim must not settle over it. pendingSeq is 0 while
        // Open, so this also excludes the reserved no-checkpoint seq 0.
        require(seq > b.pendingSeq, "stale checkpoint");
        require(result == 1 || result == 2 || result == 3, "bad result");
        _checkDualSigned(b, battleId, seq, stateCommitment, result, sigA, sigB);
        b.status = Status.Settled; // non-duplication: Settled is terminal
        b.result = result;
        b.finalSeq = seq;
        b.finalCommitment = stateCommitment;
    }

    /// Timeout path (battle-channel.md §6): after the channel deadline, either
    /// player claims from the highest dual-signed checkpoint they hold.
    /// seq 0 means no checkpoint exists: default outcome from the anchored
    /// opening state (severity is ruleset policy, register Q2).
    function initiateTimeout(
        bytes32 battleId,
        uint64 seq,
        bytes32 stateCommitment,
        uint8 result,
        bytes calldata sigA,
        bytes calldata sigB
    ) external {
        Battle storage b = battles[battleId];
        require(b.status == Status.Open, "not open");
        require(msg.sender == b.playerA || msg.sender == b.playerB, "not a participant");
        require(block.timestamp > b.deadline, "deadline not reached");
        if (seq == 0) {
            result = 3;
        } else {
            require(result == 1 || result == 2 || result == 3, "bad result");
            _checkDualSigned(b, battleId, seq, stateCommitment, result, sigA, sigB);
        }
        b.status = Status.TimeoutPending;
        b.claimant = msg.sender;
        b.responseWindowEnd = uint64(block.timestamp) + RESPONSE_WINDOW;
        b.pendingSeq = seq;
        b.pendingResult = result;
        b.pendingCommitment = stateCommitment;
    }

    /// Supersession: a strictly higher-sequence dual-signed checkpoint governs
    /// (battle-channel.md §4).
    function counterTimeout(
        bytes32 battleId,
        uint64 seq,
        bytes32 stateCommitment,
        uint8 result,
        bytes calldata sigA,
        bytes calldata sigB
    ) external {
        Battle storage b = battles[battleId];
        require(b.status == Status.TimeoutPending, "no pending timeout");
        require(block.timestamp <= b.responseWindowEnd, "window closed");
        require(seq > b.pendingSeq, "stale checkpoint");
        require(result == 1 || result == 2 || result == 3, "bad result");
        _checkDualSigned(b, battleId, seq, stateCommitment, result, sigA, sigB);
        b.pendingSeq = seq;
        b.pendingResult = result;
        b.pendingCommitment = stateCommitment;
    }

    function finalizeTimeout(bytes32 battleId) external {
        Battle storage b = battles[battleId];
        require(b.status == Status.TimeoutPending, "no pending timeout");
        require(block.timestamp > b.responseWindowEnd, "window open");
        b.status = Status.Settled;
        b.result = b.pendingResult;
        b.finalSeq = b.pendingSeq;
        b.finalCommitment = b.pendingCommitment; // zero when no checkpoint existed
    }

    /// Participant read surface for the anchored battle (battle-channel.md §3):
    /// what a joining participant checks before treating the battle as its own.
    function bindingOf(bytes32 battleId) external view returns (address playerA, address playerB, bytes32 rulesetHash) {
        Battle storage b = battles[battleId];
        return (b.playerA, b.playerB, b.rulesetHash);
    }

    /// Participant read surface for the outcome (battle-channel.md §§2, 5):
    /// everything a participant checks against its own channel state, in one call.
    function resultOf(bytes32 battleId)
        external
        view
        returns (uint8 status, uint8 result, uint64 finalSeq, bytes32 stateCommitment)
    {
        Battle storage b = battles[battleId];
        return (uint8(b.status), b.result, b.finalSeq, b.finalCommitment);
    }

    function _checkDualSigned(
        Battle storage b,
        bytes32 battleId,
        uint64 seq,
        bytes32 stateCommitment,
        uint8 result,
        bytes calldata sigA,
        bytes calldata sigB
    ) private view {
        require(keysOf[battleId][b.playerA].registered && keysOf[battleId][b.playerB].registered, "keys not anchored");
        bytes32 digest = _ethHash(
            keccak256(
                abi.encode(
                    CHECKPOINT_TAG, block.chainid, address(this), battleId, b.rulesetHash, seq, stateCommitment, result
                )
            )
        );
        require(_recover(digest, sigA) == b.playerA, "bad sig A");
        require(_recover(digest, sigB) == b.playerB, "bad sig B");
    }

    function _ethHash(bytes32 h) private pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h));
    }

    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address) {
        require(sig.length == 65, "bad sig length");
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        address a = ecrecover(digest, v, r, s);
        require(a != address(0), "bad signature");
        return a;
    }
}
