#!/usr/bin/env bash
# Slice B end-to-end round trip (prototype-and-technology.md §2.4).
# Deliberately hard-coded, test-specific plumbing; not a reusable harness.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
RPC=http://127.0.0.1:8545
CHAIN_ID=31337

# anvil's deterministic accounts 0 and 1
PK_WA=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
AD_WA=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
PK_WB=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
AD_WB=0x70997970C51812dc3A010C7d01b50e0d17dc79C8

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; exit 1; }

# --- local chain ------------------------------------------------------------
anvil --silent --port 8545 &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
up=""
for _ in $(seq 1 50); do
  if cast chain-id --rpc-url $RPC >/dev/null 2>&1; then up=1; break; fi
  sleep 0.1
done
[ -n "$up" ] || fail "anvil did not come up on $RPC"
pass "anvil up (chain-id $(cast chain-id --rpc-url $RPC))"

# --- deploy -----------------------------------------------------------------
cd "$DIR/contracts"
forge build --silent
CONTRACT=$(forge create src/BattleSettlement.sol:BattleSettlement \
  --rpc-url $RPC --private-key $PK_WA --broadcast --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["deployedTo"])')
pass "deployed BattleSettlement at $CONTRACT"

AUTH_TAG=$(cast keccak "blockmon/battle-key-auth/v0")
CK_TAG=$(cast keccak "blockmon/battle-checkpoint/v0")

# --- probe: channel material and deterministic local result ------------------
mkdir -p "$REPO/build" "$DIR/fixtures"
odin build "$DIR/probe" -out:"$REPO/build/probe" -o:none
"$REPO/build/probe" > "$DIR/fixtures/probe-vectors.json"
eval "$(python3 - "$DIR/fixtures/probe-vectors.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
for k in ("battle_id","ruleset_hash","ed_pk_a","ed_pk_b","x_pk_a","x_pk_b","state_commitment"):
    print(f"{k.upper()}={d[k]}")
print(f"FINAL_SEQ={d['final_seq']}")
print(f"RESULT={d['result']}")
EOF
)"
pass "probe: session secret agreed, ops cross-verified, result=$RESULT seq=$FINAL_SEQ"

NOW=$(cast block latest --rpc-url $RPC --field timestamp)
DEADLINE=$((NOW + 3600))
EXPIRY=$((NOW + 7200))

send() { cast send --rpc-url $RPC --private-key "$1" "$CONTRACT" "${@:2}" >/dev/null; }

auth_sig() { # 1=wallet pk, 2=battle id, 3=ed pk, 4=x pk
  local inner
  inner=$(cast keccak "$(cast abi-encode 'x(bytes32,uint256,address,bytes32,bytes32,bytes32,bytes32,uint64)' \
    "$AUTH_TAG" $CHAIN_ID "$CONTRACT" "$2" "$RULESET_HASH" "$3" "$4" $EXPIRY)")
  cast wallet sign --private-key "$1" "$inner"
}

ck_sig() { # 1=wallet pk, 2=battle id, 3=seq, 4=commitment, 5=result
  local inner
  inner=$(cast keccak "$(cast abi-encode 'x(bytes32,uint256,address,bytes32,bytes32,uint64,bytes32,uint8)' \
    "$CK_TAG" $CHAIN_ID "$CONTRACT" "$2" "$RULESET_HASH" "$3" "$4" "$5")")
  cast wallet sign --private-key "$1" "$inner"
}

result_of() { cast call --rpc-url $RPC "$CONTRACT" "resultOf(bytes32)(uint8,uint8,uint64,bytes32)" "$1" | tr '\n' ' '; }

# --- cooperative path ---------------------------------------------------------
send $PK_WA "createBattle(bytes32,address,address,bytes32,uint64)" \
  "$BATTLE_ID" $AD_WA $AD_WB "$RULESET_HASH" $DEADLINE
send $PK_WA "registerKeys(bytes32,address,bytes32,bytes32,uint64,bytes)" \
  "$BATTLE_ID" $AD_WA "$ED_PK_A" "$X_PK_A" $EXPIRY "$(auth_sig $PK_WA "$BATTLE_ID" "$ED_PK_A" "$X_PK_A")"
send $PK_WB "registerKeys(bytes32,address,bytes32,bytes32,uint64,bytes)" \
  "$BATTLE_ID" $AD_WB "$ED_PK_B" "$X_PK_B" $EXPIRY "$(auth_sig $PK_WB "$BATTLE_ID" "$ED_PK_B" "$X_PK_B")"
pass "battle created; both ephemeral battle public keys anchored (wallet-authorised)"

SIG_A=$(ck_sig $PK_WA "$BATTLE_ID" "$FINAL_SEQ" "$STATE_COMMITMENT" "$RESULT")
SIG_B=$(ck_sig $PK_WB "$BATTLE_ID" "$FINAL_SEQ" "$STATE_COMMITMENT" "$RESULT")
send $PK_WA "settle(bytes32,uint64,bytes32,uint8,bytes,bytes)" \
  "$BATTLE_ID" "$FINAL_SEQ" "$STATE_COMMITMENT" "$RESULT" "$SIG_A" "$SIG_B"

read -r STATUS GOT_RESULT GOT_SEQ GOT_COMMITMENT <<<"$(result_of "$BATTLE_ID")"
[ "$STATUS" = "3" ] && [ "$GOT_RESULT" = "$RESULT" ] && [ "$GOT_SEQ" = "$FINAL_SEQ" ] \
  && [ "$GOT_COMMITMENT" = "$STATE_COMMITMENT" ] \
  || fail "on-chain state (status=$STATUS result=$GOT_RESULT seq=$GOT_SEQ state=$GOT_COMMITMENT) disagrees with probe"
pass "cooperative settlement: chain state agrees with deterministic local state"

# --- negative: duplicate settlement -------------------------------------------
if cast send --rpc-url $RPC --private-key $PK_WA "$CONTRACT" \
  "settle(bytes32,uint64,bytes32,uint8,bytes,bytes)" \
  "$BATTLE_ID" "$FINAL_SEQ" "$STATE_COMMITMENT" "$RESULT" "$SIG_A" "$SIG_B" >/dev/null 2>&1; then
  fail "duplicate settlement was accepted"
fi
pass "duplicate settlement rejected"

# --- negative: timeout path (default outcome after deadline + window) ----------
B2=$(cast keccak "blockmon/test-battle/2")
NOW=$(cast block latest --rpc-url $RPC --field timestamp)
send $PK_WA "createBattle(bytes32,address,address,bytes32,uint64)" \
  "$B2" $AD_WA $AD_WB "$RULESET_HASH" $((NOW + 5))
send $PK_WA "registerKeys(bytes32,address,bytes32,bytes32,uint64,bytes)" \
  "$B2" $AD_WA "$ED_PK_A" "$X_PK_A" $EXPIRY "$(auth_sig $PK_WA "$B2" "$ED_PK_A" "$X_PK_A")"
send $PK_WB "registerKeys(bytes32,address,bytes32,bytes32,uint64,bytes)" \
  "$B2" $AD_WB "$ED_PK_B" "$X_PK_B" $EXPIRY "$(auth_sig $PK_WB "$B2" "$ED_PK_B" "$X_PK_B")"

cast rpc --rpc-url $RPC evm_increaseTime 60 >/dev/null
cast rpc --rpc-url $RPC evm_mine >/dev/null
send $PK_WA "initiateTimeout(bytes32,uint64,bytes32,uint8,bytes,bytes)" "$B2" 0 \
  0x0000000000000000000000000000000000000000000000000000000000000000 0 0x 0x
cast rpc --rpc-url $RPC evm_increaseTime 3700 >/dev/null
cast rpc --rpc-url $RPC evm_mine >/dev/null
send $PK_WB "finalizeTimeout(bytes32)" "$B2"

read -r STATUS GOT_RESULT GOT_SEQ GOT_COMMITMENT <<<"$(result_of "$B2")"
ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000
[ "$STATUS" = "3" ] && [ "$GOT_RESULT" = "3" ] && [ "$GOT_SEQ" = "0" ] && [ "$GOT_COMMITMENT" = "$ZERO32" ] \
  || fail "timeout state wrong (status=$STATUS result=$GOT_RESULT seq=$GOT_SEQ state=$GOT_COMMITMENT)"
pass "timeout settlement: default outcome after deadline + response window"

echo
echo "E2E OK; fixtures written to prototype/slice-b/fixtures/probe-vectors.json"
