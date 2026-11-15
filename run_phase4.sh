#!/usr/bin/env bash
# SENTINEL Phase 4 — real Vault on Base Sepolia as the protection destination.
#
# Subcommands:
#   deploy    Predict the new guardian's Lasna address from the dev wallet
#             nonce (the vault's authorized callback sender is IMMUTABLE, so
#             the vault must be deployed with the guardian's final address —
#             Phase 3 lesson), deploy SentinelVault on Base Sepolia bound to
#             the predicted guardian, then deploy SentinelGuardian#4 on Lasna
#             (destinationChainId = 84532), assert the addresses line up, and
#             setRecipient(vault). Baselines on all three chains.
#   calm      Emit the compact calm prefix (8 prices) via the Phase 2 runner
#             path; expect guardian 8/8, 0 callbacks, vault untouched.
#   crash     Emit DEMO_CRASH (16 prices); expect guardian 24/24, exactly 1
#             protection callback, vault position fully protected on
#             Base Sepolia.
#   verify    Final independent state readback on all three chains +
#             negative checks (unauthorized vault call reverts; Phase 3
#             contracts untouched).
#
# The Phase 2 AI (runner.py, model, weights) is used UNCHANGED. Testnet only
# (Sepolia + Lasna + Base Sepolia). The private key is loaded into a shell
# variable and never echoed.
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"

ROOT="$HOME/workspace/bounty-hunt/reactive-omni"
PROJ="$ROOT/sentinel"
OUT="$ROOT/phase4-run-output.txt"
ENVF="$ROOT/phase4-addresses.env"

SEPOLIA_RPC="https://ethereum-sepolia-rpc.publicnode.com"
LASNA_RPC="https://lasna-rpc.rnk.dev/"
BASE_RPC="https://sepolia.base.org"
SEPOLIA_ID=11155111
BASE_ID=84532
BASE_CALLBACK_PROXY="0x476F44b11F5C942c58f4c8E3d0300E5710743585"
EMITTER="0xeD342ec1aEAC620143E20bed9C8068A134918019"  # Phase 2 PriceEmitter (final)
ORACLE="0xa09946e491bB94db2A8c02F12Cec1AA69f51CE92"   # Phase 2 AIOracle
GUARDIAN3="0x5135E5061eFC03639C365D697DBb7A5CA0Bc2f90" # Phase 3 guardian (untouched)
RECORDER3="0x8163af97465DeAA4Bdb9fd33563Dc35E17fE7fAc" # Phase 3 recorder (untouched)
INITIAL_POSITION=1000000                               # mock units ($10,000 in cents)
GUARDIAN_FUND="0.68ether"
VAULT_FUND="0.02ether"

PK="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^0x[0-9a-fA-F]{64}$/){print $i; exit}}' "$ROOT/dev-wallet.txt")"
ADDR="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^0x[0-9a-fA-F]{40}$/){print $i; exit}}' "$ROOT/dev-wallet.txt")"
if [ -z "$PK" ] || [ -z "$ADDR" ]; then echo "dev wallet tidak terbaca"; exit 1; fi

log() { echo "[phase4] $*" | tee -a "$OUT"; }

gcall() { cast call "$GUARDIAN" "$1" --rpc-url "$LASNA_RPC" 2>/dev/null || echo "ERR"; }
vcall() { cast call "$VAULT" "$1" --rpc-url "$BASE_RPC" 2>/dev/null || echo "ERR"; }
[ -f "$ENVF" ] && source "$ENVF"

cmd_deploy() {
  log "=== DEPLOY ==="
  log "Dev wallet: $ADDR"
  log "Saldo Sepolia:    $(cast balance "$ADDR" --rpc-url "$SEPOLIA_RPC") wei"
  log "Saldo Lasna:      $(cast balance "$ADDR" --rpc-url "$LASNA_RPC") wei"
  log "Saldo BaseSepolia:$(cast balance "$ADDR" --rpc-url "$BASE_RPC") wei"
  cd "$PROJ"

  # 1) Predict the guardian address from the CURRENT Lasna nonce. No Lasna tx
  #    may be sent between this read and the guardian deploy.
  NONCE="$(cast nonce "$ADDR" --rpc-url "$LASNA_RPC")"
  PREDICTED="$(cast compute-address "$ADDR" --nonce "$NONCE")"
  log "Lasna nonce: $NONCE -> predicted guardian: $PREDICTED"

  # 2) Vault on Base Sepolia, bound to the predicted guardian. Idempotent:
  #    if a previous (partially failed) run already deployed the vault, reuse
  #    it after verifying on-chain that its immutable sender binding matches
  #    the prediction — redeploying would waste funds and orphan the first.
  if [ -n "${VAULT:-}" ]; then
    BOUND="$(cast call "$VAULT" '_CALLBACK_SENDER()(address)' --rpc-url "$BASE_RPC" 2>/dev/null || echo ERR)"
    log "Vault sudah ada: $VAULT (_CALLBACK_SENDER on-chain: $BOUND)"
    if [ "$(echo "$BOUND" | tr 'A-F' 'a-f')" != "$(echo "$PREDICTED" | tr 'A-F' 'a-f')" ]; then
      log "FATAL: vault yang ada terikat ke $BOUND, bukan prediksi $PREDICTED. STOP."
      exit 9
    fi
    V_TX="${VAULT_TX:-unknown}"
  else
    V_JSON="$(forge create src/SentinelVault.sol:SentinelVault \
      --rpc-url "$BASE_RPC" --private-key "$PK" --value $VAULT_FUND --broadcast --json \
      --constructor-args "$BASE_CALLBACK_PROXY" "$PREDICTED" $INITIAL_POSITION)"
    VAULT="$(echo "$V_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["deployedTo"])')"
    V_TX="$(echo "$V_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["transactionHash"])')"
    [ -z "$VAULT" ] && { log "GAGAL: deploy SentinelVault."; exit 6; }
    log "SentinelVault (Base Sepolia): $VAULT (deploy tx $V_TX)"
  fi

  # 3) Guardian on Lasna (destination = Base Sepolia). Must consume nonce $NONCE.
  #    Explicit gas limit, sized from observed behavior: the Lasna node's
  #    eth_estimateGas flaked with "contract creation code storage out of
  #    gas", and its send pre-check charges gasLimit x current price
  #    (~200 gwei at run time) against the balance on top of the value.
  #    Phase 3's identical deploy used 1,389,168 gas, so 1,500,000 is a
  #    tight-but-safe cap that keeps value+reserve within the dev balance;
  #    the funding was likewise trimmed 0.8 -> 0.68 lREACT (see PHASE4.md).
  G_JSON="$(forge create src/SentinelGuardian.sol:SentinelGuardian \
    --rpc-url "$LASNA_RPC" --private-key "$PK" --value $GUARDIAN_FUND --broadcast --json \
    --gas-limit 1500000 \
    --constructor-args $SEPOLIA_ID "$EMITTER" "$ORACLE" $BASE_ID)"
  GUARDIAN="$(echo "$G_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["deployedTo"])')"
  G_TX="$(echo "$G_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["transactionHash"])')"
  [ -z "$GUARDIAN" ] && { log "GAGAL: deploy SentinelGuardian#4."; exit 7; }
  log "SentinelGuardian#4 (Lasna): $GUARDIAN (deploy tx $G_TX)"
  if [ "$(echo "$GUARDIAN" | tr 'A-F' 'a-f')" != "$(echo "$PREDICTED" | tr 'A-F' 'a-f')" ]; then
    log "FATAL: guardian address $GUARDIAN != predicted $PREDICTED — vault sender binding is wrong. STOP."
    exit 8
  fi
  log "Address line-up OK: vault._CALLBACK_SENDER == guardian"

  echo "GUARDIAN=$GUARDIAN" > "$ENVF"
  echo "GUARDIAN_TX=$G_TX" >> "$ENVF"
  echo "VAULT=$VAULT" >> "$ENVF"
  echo "VAULT_TX=$V_TX" >> "$ENVF"

  SET_JSON="$(cast send "$GUARDIAN" "setRecipient(address)" "$VAULT" \
    --rpc-url "$LASNA_RPC" --private-key "$PK" --json)"
  SET_TX="$(echo "$SET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["transactionHash"])')"
  echo "SETRECIPIENT_TX=$SET_TX" >> "$ENVF"
  log "setRecipient(vault) tx: $SET_TX"

  log "--- baseline ---"
  log "guardian.recipient      = $(gcall 'recipient()(address)')"
  log "guardian.priceCount     = $(gcall 'priceCount()(uint256)')"
  log "guardian.verdictCount   = $(gcall 'verdictCount()(uint256)')"
  log "guardian.protectionCount= $(gcall 'protectionCount()(uint256)')"
  log "vault._CALLBACK_SENDER  = $(vcall '_CALLBACK_SENDER()(address)')"
  log "vault.positionAtRisk    = $(vcall 'positionAtRisk()(uint256)')"
  log "vault.safeBalance       = $(vcall 'safeBalance()(uint256)')"
  log "vault.protectionCount   = $(vcall 'protectionCount()(uint256)')"
  log "vault ETH (Base Sepolia)= $(cast balance "$VAULT" --rpc-url "$BASE_RPC") wei"
  log "oracle.verdictCount     = $(cast call "$ORACLE" 'verdictCount()(uint256)' --rpc-url "$SEPOLIA_RPC")"
  log "emitter.updateCount     = $(cast call "$EMITTER" 'updateCount()(uint256)' --rpc-url "$SEPOLIA_RPC")"
  log "DEPLOY SELESAI"
}

wait_counts() {
  local want_price="$1" want_verdict="$2" label="$3"
  for i in $(seq 1 40); do
    local pc vc
    pc="$(gcall 'priceCount()(uint256)')"; vc="$(gcall 'verdictCount()(uint256)')"
    log "  poll $label: priceCount=$pc verdictCount=$vc protectionCount=$(gcall 'protectionCount()(uint256)') latched=$(gcall 'dangerLatched()(bool)')"
    if [ "$pc" = "$want_price" ] && [ "$vc" = "$want_verdict" ]; then return 0; fi
    sleep 20
  done
  log "TIMEOUT menunggu $label (price=$want_price verdict=$want_verdict)"
  return 1
}

wait_vault_protection() {
  for i in $(seq 1 30); do
    local pc
    pc="$(vcall 'protectionCount()(uint256)')"
    log "  poll vault: protectionCount=$pc safeBalance=$(vcall 'safeBalance()(uint256)') positionAtRisk=$(vcall 'positionAtRisk()(uint256)')"
    if [ "$pc" = "1" ]; then return 0; fi
    sleep 20
  done
  log "TIMEOUT menunggu vault protectionCount=1"
  return 1
}

cmd_leg() {
  local series="$1" want_price="$2" want_verdict="$3"
  log "=== LEG: $series ==="
  log "Lasna block sebelum:   $(cast block-number --rpc-url "$LASNA_RPC")"
  log "Sepolia block sebelum: $(cast block-number --rpc-url "$SEPOLIA_RPC")"
  log "BaseSep block sebelum: $(cast block-number --rpc-url "$BASE_RPC")"
  python3 "$PROJ/ai/emit_phase4.py" --emitter "$EMITTER" --series "$series" 2>&1 | tee -a "$OUT"
  python3 "$PROJ/ai/runner.py" --emitter "$EMITTER" --oracle "$ORACLE" 2>&1 | tee -a "$OUT"
  wait_counts "$want_price" "$want_verdict" "$series"
  log "guardian.lastPrice      = $(gcall 'lastPrice()(uint256)')"
  log "guardian.referencePrice = $(gcall 'referencePrice()(uint256)')"
  log "guardian.lastRiskScore  = $(gcall 'lastRiskScore()(uint8)')"
  log "guardian.lastRegime     = $(gcall 'lastRegime()(uint8)')"
  log "guardian.protectionCount= $(gcall 'protectionCount()(uint256)')"
  log "guardian.dangerLatched  = $(gcall 'dangerLatched()(bool)')"
  log "vault.protectionCount   = $(vcall 'protectionCount()(uint256)')"
  log "LEG $series SELESAI"
}

cmd_crash() {
  cmd_leg crash 24 24
  log "=== menunggu callback tiba di vault (Base Sepolia) ==="
  wait_vault_protection
  log "vault.positionAtRisk    = $(vcall 'positionAtRisk()(uint256)')"
  log "vault.safeBalance       = $(vcall 'safeBalance()(uint256)')"
  log "vault.totalProtected    = $(vcall 'totalProtected()(uint256)')"
  log "vault.lastRiskScore     = $(vcall 'lastRiskScore()(uint256)')"
  log "vault.lastOriginTxHash  = $(vcall 'lastOriginTxHash()(uint256)')"
  log "vault.lastProtectedAmt  = $(vcall 'lastProtectedAmount()(uint256)')"
  log "vault.lastProtectionTs  = $(vcall 'lastProtectionTimestamp()(uint256)')"
  log "vault ETH (Base Sepolia)= $(cast balance "$VAULT" --rpc-url "$BASE_RPC") wei"
}

cmd_verify() {
  log "=== VERIFY ==="
  log "guardian4.priceCount    = $(gcall 'priceCount()(uint256)')"
  log "guardian4.verdictCount  = $(gcall 'verdictCount()(uint256)')"
  log "guardian4.protectionCnt = $(gcall 'protectionCount()(uint256)')"
  log "guardian4.dangerLatched = $(gcall 'dangerLatched()(bool)')"
  log "guardian4.lastPrice     = $(gcall 'lastPrice()(uint256)')"
  log "guardian4.referencePrice= $(gcall 'referencePrice()(uint256)')"
  log "guardian4.lastRiskScore = $(gcall 'lastRiskScore()(uint8)')"
  log "guardian4.lastRegime    = $(gcall 'lastRegime()(uint8)')"
  log "guardian4.lastVerdictTx = $(gcall 'lastVerdictTxHash()(uint256)')"
  log "guardian4 saldo Lasna   = $(cast balance "$GUARDIAN" --rpc-url "$LASNA_RPC") wei"
  log "vault.positionAtRisk    = $(vcall 'positionAtRisk()(uint256)')"
  log "vault.safeBalance       = $(vcall 'safeBalance()(uint256)')"
  log "vault.protectionCount   = $(vcall 'protectionCount()(uint256)')"
  log "vault.totalProtected    = $(vcall 'totalProtected()(uint256)')"
  log "vault.lastRiskScore     = $(vcall 'lastRiskScore()(uint256)')"
  log "vault.lastOriginTxHash  = $(vcall 'lastOriginTxHash()(uint256)')"
  log "vault ETH (Base Sepolia)= $(cast balance "$VAULT" --rpc-url "$BASE_RPC") wei"
  log "--- negative checks ---"
  log "unauthorized vault call (from dev wallet, bukan proxy) harus REVERT:"
  cast call "$VAULT" 'recordCallback(address,uint256,uint256)' "$GUARDIAN" 83 12345 \
    --from "$ADDR" --rpc-url "$BASE_RPC" 2>&1 | head -3 | tee -a "$OUT"
  log "--- Phase 3 untouched ---"
  log "guardian3.protectionCnt = $(cast call "$GUARDIAN3" 'protectionCount()(uint256)' --rpc-url "$LASNA_RPC") (harus 1)"
  log "guardian3.price/verdict = $(cast call "$GUARDIAN3" 'priceCount()(uint256)' --rpc-url "$LASNA_RPC")/$(cast call "$GUARDIAN3" 'verdictCount()(uint256)' --rpc-url "$LASNA_RPC") (harus 48/48)"
  log "guardian3 saldo Lasna   = $(cast balance "$GUARDIAN3" --rpc-url "$LASNA_RPC") wei (harus 0.7133...)"
  log "recorder3.callbackCount = $(cast call "$RECORDER3" 'callbackCount()(uint256)' --rpc-url "$SEPOLIA_RPC") (harus 1)"
  log "oracle.verdictCount     = $(cast call "$ORACLE" 'verdictCount()(uint256)' --rpc-url "$SEPOLIA_RPC") (81 + 24 = 105)"
  log "emitter.updateCount     = $(cast call "$EMITTER" 'updateCount()(uint256)' --rpc-url "$SEPOLIA_RPC") (96 + 24 = 120)"
  log "Saldo Sepolia dev:    $(cast balance "$ADDR" --rpc-url "$SEPOLIA_RPC") wei"
  log "Saldo Lasna dev:      $(cast balance "$ADDR" --rpc-url "$LASNA_RPC") wei"
  log "Saldo BaseSepolia dev:$(cast balance "$ADDR" --rpc-url "$BASE_RPC") wei"
  log "VERIFY SELESAI"
}

case "${1:-}" in
  deploy) cmd_deploy ;;
  calm) cmd_leg calm-prefix 8 8 ;;
  crash) cmd_crash ;;
  verify) cmd_verify ;;
  *) echo "usage: $0 deploy|calm|crash|verify"; exit 64 ;;
esac
