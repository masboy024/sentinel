#!/usr/bin/env bash
# SENTINEL Phase 3 — reactive brain (Lasna) combining price stream + AI verdicts.
#
# Subcommands:
#   deploy    Deploy SentinelGuardian (Lasna, 2 lREACT) + a fresh CallbackRecorder
#             instance (Sepolia, 0.02 SepETH, sender = the new guardian; the
#             Phase 1 recorder's authorized sender is immutable and bound to
#             the Phase 1 reactive contract), then setRecipient + baselines.
#   calm      Emit DEMO_CALM via the Phase 2 runner path; expect 0 callbacks.
#   crash     Emit DEMO_CRASH; expect exactly 1 protection callback.
#   volatile  Emit DEMO_VOLATILE; expect latch reset, still 1 callback.
#   verify    Final independent state readback on both chains.
#
# The Phase 2 AI (runner.py, model, weights) is used UNCHANGED. Testnet only.
# The private key is loaded into a shell variable and never echoed.
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"

ROOT="$HOME/workspace/bounty-hunt/reactive-omni"
PROJ="$ROOT/sentinel"
OUT="$ROOT/phase3-run-output.txt"
ENVF="$ROOT/phase3-addresses.env"

SEPOLIA_RPC="https://ethereum-sepolia-rpc.publicnode.com"
LASNA_RPC="https://lasna-rpc.rnk.dev/"
SEPOLIA_ID=11155111
CALLBACK_PROXY="0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4"
EMITTER="0xeD342ec1aEAC620143E20bed9C8068A134918019"  # Phase 2 PriceEmitter (final)
ORACLE="0xa09946e491bB94db2A8c02F12Cec1AA69f51CE92"   # Phase 2 AIOracle
OLD_RECORDER="0x1555b4fEe6C125731e956e36B9e5DC2ca9B2F95c" # Phase 1 recorder (untouched)

PK="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^0x[0-9a-fA-F]{64}$/){print $i; exit}}' "$ROOT/dev-wallet.txt")"
ADDR="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^0x[0-9a-fA-F]{40}$/){print $i; exit}}' "$ROOT/dev-wallet.txt")"
if [ -z "$PK" ] || [ -z "$ADDR" ]; then echo "dev wallet tidak terbaca"; exit 1; fi

log() { echo "[phase3] $*" | tee -a "$OUT"; }

gcall() { cast call "$GUARDIAN" "$1" --rpc-url "$LASNA_RPC" 2>/dev/null || echo "ERR"; }
[ -f "$ENVF" ] && source "$ENVF"

cmd_deploy() {
  log "=== DEPLOY ==="
  log "Dev wallet: $ADDR"
  log "Saldo Sepolia: $(cast balance "$ADDR" --rpc-url "$SEPOLIA_RPC") wei"
  log "Saldo Lasna:   $(cast balance "$ADDR" --rpc-url "$LASNA_RPC") wei"
  cd "$PROJ"

  G_JSON="$(forge create src/SentinelGuardian.sol:SentinelGuardian \
    --rpc-url "$LASNA_RPC" --private-key "$PK" --value 2ether --broadcast --json \
    --constructor-args $SEPOLIA_ID "$EMITTER" "$ORACLE" $SEPOLIA_ID)"
  GUARDIAN="$(echo "$G_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["deployedTo"])')"
  G_TX="$(echo "$G_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["transactionHash"])')"
  [ -z "$GUARDIAN" ] && { log "GAGAL: deploy SentinelGuardian."; exit 6; }
  log "SentinelGuardian (Lasna): $GUARDIAN (deploy tx $G_TX)"

  R_JSON="$(forge create src/CallbackRecorder.sol:CallbackRecorder \
    --rpc-url "$SEPOLIA_RPC" --private-key "$PK" --value 0.02ether --broadcast --json \
    --constructor-args "$CALLBACK_PROXY" "$GUARDIAN")"
  RECORDER="$(echo "$R_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["deployedTo"])')"
  R_TX="$(echo "$R_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["transactionHash"])')"
  [ -z "$RECORDER" ] && { log "GAGAL: deploy CallbackRecorder."; exit 7; }
  log "CallbackRecorder#3 (Sepolia): $RECORDER (deploy tx $R_TX)"

  echo "GUARDIAN=$GUARDIAN" > "$ENVF"
  echo "GUARDIAN_TX=$G_TX" >> "$ENVF"
  echo "RECORDER=$RECORDER" >> "$ENVF"
  echo "RECORDER_TX=$R_TX" >> "$ENVF"

  SET_JSON="$(cast send "$GUARDIAN" "setRecipient(address)" "$RECORDER" \
    --rpc-url "$LASNA_RPC" --private-key "$PK" --json)"
  SET_TX="$(echo "$SET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["transactionHash"])')"
  echo "SETRECIPIENT_TX=$SET_TX" >> "$ENVF"
  log "setRecipient tx: $SET_TX"

  log "--- baseline ---"
  log "guardian.recipient      = $(gcall 'recipient()(address)')"
  log "guardian.priceCount     = $(gcall 'priceCount()(uint256)')"
  log "guardian.verdictCount   = $(gcall 'verdictCount()(uint256)')"
  log "guardian.protectionCount= $(gcall 'protectionCount()(uint256)')"
  log "recorder#3.callbackCount= $(cast call "$RECORDER" 'callbackCount()(uint256)' --rpc-url "$SEPOLIA_RPC")"
  log "recorder#1.callbackCount= $(cast call "$OLD_RECORDER" 'callbackCount()(uint256)' --rpc-url "$SEPOLIA_RPC") (Phase 1, harus tetap 1)"
  log "oracle.verdictCount     = $(cast call "$ORACLE" 'verdictCount()(uint256)' --rpc-url "$SEPOLIA_RPC")"
  log "emitter.updateCount     = $(cast call "$EMITTER" 'updateCount()(uint256)' --rpc-url "$SEPOLIA_RPC")"
  log "DEPLOY SELESAI"
}

# Poll the guardian until priceCount/verdictCount reach targets (or timeout).
wait_counts() {
  local want_price="$1" want_verdict="$2" label="$3"
  for i in $(seq 1 36); do
    local pc vc
    pc="$(gcall 'priceCount()(uint256)')"; vc="$(gcall 'verdictCount()(uint256)')"
    log "  poll $label: priceCount=$pc verdictCount=$vc protectionCount=$(gcall 'protectionCount()(uint256)') latched=$(gcall 'dangerLatched()(bool)')"
    if [ "$pc" = "$want_price" ] && [ "$vc" = "$want_verdict" ]; then return 0; fi
    sleep 20
  done
  log "TIMEOUT menunggu $label (price=$want_price verdict=$want_verdict)"
  return 1
}

cmd_leg() {
  local scenario="$1" want_price="$2" want_verdict="$3"
  log "=== LEG: $scenario ==="
  log "Lasna block sebelum: $(cast block-number --rpc-url "$LASNA_RPC")"
  log "Sepolia block sebelum: $(cast block-number --rpc-url "$SEPOLIA_RPC")"
  python3 "$PROJ/ai/emit_prices.py" --emitter "$EMITTER" --scenario "$scenario" 2>&1 | tee -a "$OUT"
  python3 "$PROJ/ai/runner.py" --emitter "$EMITTER" --oracle "$ORACLE" 2>&1 | tee -a "$OUT"
  wait_counts "$want_price" "$want_verdict" "$scenario"
  log "guardian.lastPrice      = $(gcall 'lastPrice()(uint256)')"
  log "guardian.referencePrice = $(gcall 'referencePrice()(uint256)')"
  log "guardian.lastRiskScore  = $(gcall 'lastRiskScore()(uint8)')"
  log "guardian.lastRegime     = $(gcall 'lastRegime()(uint8)')"
  log "guardian.protectionCount= $(gcall 'protectionCount()(uint256)')"
  log "guardian.dangerLatched  = $(gcall 'dangerLatched()(bool)')"
  log "recorder#3.callbackCount= $(cast call "$RECORDER" 'callbackCount()(uint256)' --rpc-url "$SEPOLIA_RPC")"
  log "LEG $scenario SELESAI"
}

cmd_verify() {
  log "=== VERIFY ==="
  log "guardian.priceCount     = $(gcall 'priceCount()(uint256)')"
  log "guardian.verdictCount   = $(gcall 'verdictCount()(uint256)')"
  log "guardian.protectionCount= $(gcall 'protectionCount()(uint256)')"
  log "guardian.dangerLatched  = $(gcall 'dangerLatched()(bool)')"
  log "guardian.lastPrice      = $(gcall 'lastPrice()(uint256)')"
  log "guardian.referencePrice = $(gcall 'referencePrice()(uint256)')"
  log "guardian.lastRiskScore  = $(gcall 'lastRiskScore()(uint8)')"
  log "guardian.lastRegime     = $(gcall 'lastRegime()(uint8)')"
  log "guardian.lastVerdictTx  = $(gcall 'lastVerdictTxHash()(uint256)')"
  log "guardian saldo Lasna    = $(cast balance "$GUARDIAN" --rpc-url "$LASNA_RPC") wei"
  log "recorder#3.callbackCount= $(cast call "$RECORDER" 'callbackCount()(uint256)' --rpc-url "$SEPOLIA_RPC")"
  log "recorder#3.lastValue    = $(cast call "$RECORDER" 'lastValue()(uint256)' --rpc-url "$SEPOLIA_RPC")"
  log "recorder#3.lastOriginTx = $(cast call "$RECORDER" 'lastOriginTxHash()(uint256)' --rpc-url "$SEPOLIA_RPC")"
  log "recorder#1.callbackCount= $(cast call "$OLD_RECORDER" 'callbackCount()(uint256)' --rpc-url "$SEPOLIA_RPC") (Phase 1, harus tetap 1)"
  log "oracle.verdictCount     = $(cast call "$ORACLE" 'verdictCount()(uint256)' --rpc-url "$SEPOLIA_RPC")"
  log "emitter.updateCount     = $(cast call "$EMITTER" 'updateCount()(uint256)' --rpc-url "$SEPOLIA_RPC")"
  log "Saldo Sepolia dev: $(cast balance "$ADDR" --rpc-url "$SEPOLIA_RPC") wei"
  log "Saldo Lasna dev:   $(cast balance "$ADDR" --rpc-url "$LASNA_RPC") wei"
  log "VERIFY SELESAI"
}

case "${1:-}" in
  deploy) cmd_deploy ;;
  calm) cmd_leg calm 16 16 ;;
  crash) cmd_leg crash 32 32 ;;
  volatile) cmd_leg volatile 48 48 ;;
  verify) cmd_verify ;;
  *) echo "usage: $0 deploy|calm|crash|volatile|verify"; exit 64 ;;
esac
