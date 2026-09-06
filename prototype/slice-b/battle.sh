#!/usr/bin/env bash
# Slice B dual-process battle run: two independent Odin participant processes
# execute one battle channel across a loopback socket, then this harness settles
# the agreed result at the stand-in anchor venue.
#
#   battle.sh auto     launch both participants, assert, exit
#   battle.sh manual   set the battle up, print the two participant commands,
#                      settle once both have produced channel evidence
#
# Deliberately hard-coded, test-specific plumbing; not a reusable harness
# (prototype-and-technology.md §2.2). Uses its own chain port so it can run
# beside e2e.sh.
set -euo pipefail

MODE="${1:-auto}"
case "$MODE" in
auto | manual) ;;
*)
  printf 'usage: %s [auto|manual]\n' "$0" >&2
  exit 2
  ;;
esac

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
RUN="$REPO/build/battle-run"
ANVIL_PORT=8546
RPC=http://127.0.0.1:$ANVIL_PORT
CHAIN_ID=31337
CHANNEL_HOST=127.0.0.1
CHANNEL_PORT=47301
SESSION_WAIT_S=45
EXIT_WAIT_S=30
HOLD_S=900

# anvil's deterministic accounts 0 and 1
PK_WA=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
AD_WA=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
PK_WB=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
AD_WB=0x70997970C51812dc3A010C7d01b50e0d17dc79C8

PID_A=""
PID_B=""

pass() { printf 'PASS  %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  dump_player_logs
  exit 1
}

dump_player_logs() {
  for role in a b; do
    for stream in out err; do
      f="$RUN/player-$role.$stream"
      if [ -s "$f" ]; then
        printf -- '--- player-%s std%s ---\n' "$role" "$stream"
        cat "$f"
      fi
    done
  done
}

assert_absent() { # 1=file or directory 2=literal 3=what
  if grep -rqF -- "$2" "$1"; then fail "$3"; fi
}

check_selector() { # 1=Odin constant 2=contract signature
  local sel
  sel=$(cast sig "$2")
  grep -qF "$1 :: \"$sel\"" "$DIR/channel/chain.odin" ||
    fail "$1 is not the contract's selector for $2 ($sel)"
}

# --- run directory ----------------------------------------------------------
mkdir -p "$RUN"
rm -f "$RUN"/*.json "$RUN"/*.log "$RUN"/*.out "$RUN"/*.err "$RUN"/*.tmp

cleanup() {
  [ -n "$PID_A" ] && kill "$PID_A" 2>/dev/null || true
  [ -n "$PID_B" ] && kill "$PID_B" 2>/dev/null || true
  [ -n "${ANVIL_PID:-}" ] && kill "$ANVIL_PID" 2>/dev/null || true
}
trap cleanup EXIT

# --- secret boundary, checked at the source ---------------------------------
# The participants share protocol code and no key material: each player program
# declares its own ephemeral seeds and nothing of its counterparty's.
assert_absent "$DIR/channel" "SEED_" "the shared channel package declares seed material"
assert_absent "$DIR/player-a/main.odin" "0x21, 0x22, 0x23" "player-a holds B's ed25519 seed"
assert_absent "$DIR/player-a/main.odin" "0x61, 0x62, 0x63" "player-a holds B's x25519 seed"
assert_absent "$DIR/player-b/main.odin" "0x01, 0x02, 0x03" "player-b holds A's ed25519 seed"
assert_absent "$DIR/player-b/main.odin" "0x41, 0x42, 0x43" "player-b holds A's x25519 seed"
pass "secret boundary: neither participant's source holds the other's ephemeral seeds"

# --- the participants' pinned selectors are the contract's -------------------
# Ethereum Keccak-256 stays out of Odin, so the selectors are constants there
# and this is what stops them going stale (architecture.md §21). Each constant
# is checked by name, so a swap between two of them fails here too.
check_selector SEL_BINDING_OF "bindingOf(bytes32)"
check_selector SEL_KEYS_OF "keysOf(bytes32,address)"
check_selector SEL_RESULT_OF "resultOf(bytes32)"
pass "participant read path: all three pinned selectors match the contract"

# --- build ------------------------------------------------------------------
mkdir -p "$REPO/build"
odin build "$DIR/probe" -out:"$REPO/build/probe" -o:none
odin build "$DIR/player-a" -out:"$REPO/build/player-a" -o:none
odin build "$DIR/player-b" -out:"$REPO/build/player-b" -o:none

# The single-process probe is the determinism reference for the pair.
"$REPO/build/probe" >"$RUN/probe.json"

# --- local chain ------------------------------------------------------------
anvil --silent --port $ANVIL_PORT &
ANVIL_PID=$!
up=""
for _ in $(seq 1 50); do
  if cast chain-id --rpc-url $RPC >/dev/null 2>&1; then
    up=1
    break
  fi
  sleep 0.1
done
[ -n "$up" ] || fail "anvil did not come up on $RPC"
pass "anvil up (chain-id $(cast chain-id --rpc-url $RPC))"

# --- deploy -----------------------------------------------------------------
cd "$DIR/contracts"
forge build --silent
CONTRACT=$(forge create src/BattleSettlement.sol:BattleSettlement \
  --rpc-url $RPC --private-key $PK_WA --broadcast --json |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["deployedTo"])')
pass "deployed BattleSettlement at $CONTRACT"

AUTH_TAG=$(cast keccak "blockmon/battle-key-auth/v0")
CK_TAG=$(cast keccak "blockmon/battle-checkpoint/v0")

# --- battle identity, shared with the single-process probe -------------------
eval "$(python3 - "$RUN/probe.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"BATTLE_ID={d['battle_id']}")
print(f"RULESET_HASH={d['ruleset_hash']}")
EOF
)"

# --- each participant reports its own public battle material -----------------
keys_json() { "$1" keys | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["ed_pk"], d["x_pk"])'; }
read -r ED_PK_A X_PK_A <<<"$(keys_json "$REPO/build/player-a" || true)"
read -r ED_PK_B X_PK_B <<<"$(keys_json "$REPO/build/player-b" || true)"
for k in "$ED_PK_A" "$X_PK_A" "$ED_PK_B" "$X_PK_B"; do
  [ ${#k} -eq 66 ] && [ "${k#0x}" != "$k" ] || fail "a participant did not report usable public battle material"
done

NOW=$(cast block latest --rpc-url $RPC --field timestamp)
DEADLINE=$((NOW + 3600))
EXPIRY=$((NOW + 7200))

send() { cast send --rpc-url $RPC --private-key "$1" "$CONTRACT" "${@:2}" >/dev/null; }

auth_sig() { # 1=wallet pk, 2=ed pk, 3=x pk
  local inner
  inner=$(cast keccak "$(cast abi-encode 'x(bytes32,uint256,address,bytes32,bytes32,bytes32,bytes32,uint64)' \
    "$AUTH_TAG" $CHAIN_ID "$CONTRACT" "$BATTLE_ID" "$RULESET_HASH" "$2" "$3" $EXPIRY)")
  cast wallet sign --private-key "$1" "$inner"
}

ck_sig() { # 1=wallet pk, 2=seq, 3=commitment, 4=result
  local inner
  inner=$(cast keccak "$(cast abi-encode 'x(bytes32,uint256,address,bytes32,bytes32,uint64,bytes32,uint8)' \
    "$CK_TAG" $CHAIN_ID "$CONTRACT" "$BATTLE_ID" "$RULESET_HASH" "$2" "$3" "$4")")
  cast wallet sign --private-key "$1" "$inner"
}

send $PK_WA "createBattle(bytes32,address,address,bytes32,uint64)" \
  "$BATTLE_ID" $AD_WA $AD_WB "$RULESET_HASH" $DEADLINE
send $PK_WA "registerKeys(bytes32,address,bytes32,bytes32,uint64,bytes)" \
  "$BATTLE_ID" $AD_WA "$ED_PK_A" "$X_PK_A" $EXPIRY "$(auth_sig $PK_WA "$ED_PK_A" "$X_PK_A")"
send $PK_WB "registerKeys(bytes32,address,bytes32,bytes32,uint64,bytes)" \
  "$BATTLE_ID" $AD_WB "$ED_PK_B" "$X_PK_B" $EXPIRY "$(auth_sig $PK_WB "$ED_PK_B" "$X_PK_B")"
pass "one battle created; both participants' ephemeral keys anchored (wallet-authorised)"

# --- early diagnostic: did the anchoring transactions take? ------------------
# Not the authoritative check. Each participant verifies the descriptor against
# the chain itself; this only catches a broken anchor before two processes are
# spawned to discover it the long way round.
keys_of() { cast call --rpc-url $RPC "$CONTRACT" "keysOf(bytes32,address)(bytes32,bytes32,bool)" "$BATTLE_ID" "$1" | tr '\n' ' '; }
read -r CED_A CX_A CREG_A <<<"$(keys_of $AD_WA)"
read -r CED_B CX_B CREG_B <<<"$(keys_of $AD_WB)"
[ "$CED_A" = "$ED_PK_A" ] && [ "$CX_A" = "$X_PK_A" ] && [ "$CREG_A" = "true" ] || fail "A's anchored keys disagree with A's own report"
[ "$CED_B" = "$ED_PK_B" ] && [ "$CX_B" = "$X_PK_B" ] && [ "$CREG_B" = "true" ] || fail "B's anchored keys disagree with B's own report"

python3 - "$RUN/battle.json" <<EOF
import json
json.dump({
    "battle_id": "$BATTLE_ID",
    "ruleset_hash": "$RULESET_HASH",
    "ed_pk_a": "$ED_PK_A", "x_pk_a": "$X_PK_A",
    "ed_pk_b": "$ED_PK_B", "x_pk_b": "$X_PK_B",
    "player_a_wallet": "$AD_WA", "player_b_wallet": "$AD_WB",
    "contract": "$CONTRACT", "chain_id": $CHAIN_ID, "deadline": $DEADLINE,
    "rpc_host": "127.0.0.1",
    "rpc_port": $ANVIL_PORT,
    "transport_host": "$CHANNEL_HOST",
    "transport_port": $CHANNEL_PORT,
    "transport_listener": "a",
}, open(__import__("sys").argv[1], "w"), indent=2)
EOF
pass "battle descriptor written from anchored state only (no secrets): $RUN/battle.json"

# --- participants -----------------------------------------------------------
if [ "$MODE" = auto ]; then
  "$REPO/build/player-a" play "$RUN/battle.json" "$RUN" >"$RUN/player-a.out" 2>"$RUN/player-a.err" &
  PID_A=$!
  "$REPO/build/player-b" play "$RUN/battle.json" "$RUN" >"$RUN/player-b.out" 2>"$RUN/player-b.err" &
  PID_B=$!
  printf 'launched player-a (pid %s) and player-b (pid %s)\n' "$PID_A" "$PID_B"
else
  printf '\nbattle is open. Run these in two terminals:\n\n'
  printf '  Terminal 1:  just slice-b-player-a\n'
  printf '  Terminal 2:  just slice-b-player-b\n\n'
  printf 'waiting for both participants to produce channel evidence...\n'
fi

# --- wait for both sides' channel evidence ----------------------------------
got=""
for _ in $(seq 1 $((SESSION_WAIT_S * 10))); do
  if [ -s "$RUN/session-a.json" ] && [ -s "$RUN/session-b.json" ]; then
    got=1
    break
  fi
  if [ "$MODE" = auto ]; then
    kill -0 "$PID_A" 2>/dev/null || fail "player-a exited before producing channel evidence"
    kill -0 "$PID_B" 2>/dev/null || fail "player-b exited before producing channel evidence"
  fi
  sleep 0.1
done
[ -n "$got" ] || fail "no channel evidence from both participants within ${SESSION_WAIT_S}s (deadlock)"
pass "both participants produced independent channel evidence"

# --- convergence: the two processes agree, and agree with the probe ----------
eval "$(python3 - "$RUN/session-a.json" "$RUN/session-b.json" "$RUN/probe.json" <<'EOF'
import json, sys

a, b, probe = (json.load(open(p)) for p in sys.argv[1:4])


def die(msg):
    print(f'fail "{msg}"')
    raise SystemExit(0)


for k in ("battle_id", "ruleset_hash", "session_check", "transcript_head",
          "final_seq", "result", "state_commitment", "checkpoint_hash"):
    if a[k] != b[k]:
        die(f"participants disagree on {k}: {a[k]} vs {b[k]}")

if a["ck_sig_self"] != b["ck_sig_peer"] or b["ck_sig_self"] != a["ck_sig_peer"]:
    die("each side does not hold the other's checkpoint signature")
if a["peer_ed_pk"] == b["peer_ed_pk"]:
    die("both sides authenticated the same peer key")

for k in ("transcript_head", "state_commitment", "final_seq", "result"):
    if a[k] != probe[k]:
        die(f"two-process {k} differs from the single-process probe: {a[k]} vs {probe[k]}")
if [o["op_hash"] for o in a["ops"]] != [o["op_hash"] for o in probe["ops"]]:
    die("two-process op hashes differ from the single-process probe")
if a["ck_sig_self"] != probe["ck_sig_ed_a"] or b["ck_sig_self"] != probe["ck_sig_ed_b"]:
    die("two-process checkpoint signatures differ from the single-process probe")

print(f'FINAL_SEQ={a["final_seq"]}')
print(f'RESULT={a["result"]}')
print(f'STATE_COMMITMENT={a["state_commitment"]}')
print(f'HEAD={a["transcript_head"]}')
EOF
)"
pass "convergence: same session witness, transcript head $HEAD, checkpoint and dual signatures"
pass "convergence: two-process transcript equals the single-process probe's promoted vectors"

# --- the wire is the whole story --------------------------------------------
sent_a=$(sed -n 's/^> //p' "$RUN/wire-a.log")
recv_b=$(sed -n 's/^< //p' "$RUN/wire-b.log")
sent_b=$(sed -n 's/^> //p' "$RUN/wire-b.log")
recv_a=$(sed -n 's/^< //p' "$RUN/wire-a.log")
[ "$sent_a" = "$recv_b" ] || fail "what A sent is not what B received"
[ "$sent_b" = "$recv_a" ] || fail "what B sent is not what A received"
kinds=$(sed -n 's/^[<>] \([0-9a-f][0-9a-f]\).*/\1/p' "$RUN/wire-a.log" | tr '\n' ' ')
[ "$kinds" = "01 01 02 02 03 03 04 04 " ] || fail "unexpected frame sequence on the wire: $kinds"
pass "transport: 4 frame kinds, hello/op/checkpoint-signature/done, logged in full both sides"

# --- settlement, from the agreed checkpoint only ----------------------------
SIG_A=$(ck_sig $PK_WA "$FINAL_SEQ" "$STATE_COMMITMENT" "$RESULT")
SIG_B=$(ck_sig $PK_WB "$FINAL_SEQ" "$STATE_COMMITMENT" "$RESULT")
send $PK_WA "settle(bytes32,uint64,bytes32,uint8,bytes,bytes)" \
  "$BATTLE_ID" "$FINAL_SEQ" "$STATE_COMMITMENT" "$RESULT" "$SIG_A" "$SIG_B"

read -r STATUS GOT_RESULT GOT_SEQ GOT_COMMITMENT <<<"$(cast call --rpc-url $RPC "$CONTRACT" "resultOf(bytes32)(uint8,uint8,uint64,bytes32)" "$BATTLE_ID" | tr '\n' ' ')"
[ "$STATUS" = "3" ] && [ "$GOT_RESULT" = "$RESULT" ] && [ "$GOT_SEQ" = "$FINAL_SEQ" ] && [ "$GOT_COMMITMENT" = "$STATE_COMMITMENT" ] ||
  fail "on-chain state (status=$STATUS result=$GOT_RESULT seq=$GOT_SEQ state=$GOT_COMMITMENT) disagrees with the channel"
pass "settled on chain: status $STATUS result $GOT_RESULT seq $GOT_SEQ, settled state recorded"

# --- both participants read the outcome from the chain themselves -----------
if [ "$MODE" = auto ]; then
  done_a=""
  done_b=""
  for _ in $(seq 1 $((EXIT_WAIT_S * 10))); do
    [ -n "$done_a" ] || kill -0 "$PID_A" 2>/dev/null || done_a=1
    [ -n "$done_b" ] || kill -0 "$PID_B" 2>/dev/null || done_b=1
    [ -n "$done_a" ] && [ -n "$done_b" ] && break
    sleep 0.1
  done
  [ -n "$done_a" ] && [ -n "$done_b" ] || fail "a participant did not observe settlement and exit within ${EXIT_WAIT_S}s"

  RC_A=0
  RC_B=0
  wait "$PID_A" || RC_A=$?
  wait "$PID_B" || RC_B=$?
  PID_A=""
  PID_B=""
  [ "$RC_A" = 0 ] && [ "$RC_B" = 0 ] || fail "participant exit codes: a=$RC_A b=$RC_B"
  pass "both participants read the settled outcome from the chain, checked it against their own state, exited 0"

  printf '\n--- player-a ---\n'
  cat "$RUN/player-a.out"
  printf '\n--- player-b ---\n'
  cat "$RUN/player-b.out"
fi

printf '\nchannel evidence digests (identical across runs by construction):\n'
shasum -a 256 "$RUN/session-a.json" "$RUN/session-b.json" "$RUN/wire-a.log" "$RUN/wire-b.log"

if [ "$MODE" = manual ]; then
  printf '\nsettled. Chain still up on %s for inspection; Ctrl-C to stop.\n' "$RPC"
  sleep $HOLD_S
else
  printf '\nDUAL-PROCESS E2E OK; run artefacts in %s\n' "$RUN"
fi
