#!/usr/bin/env bash
# SENTINEL Phase 2 — AI verdicts on-chain (Ethereum Sepolia only).
#
# 1. Deploy PriceEmitter + AIOracle (runner = dev wallet).
# 2. Emit the CALM price scenario (16 prices), run the AI runner -> verdicts.
# 3. Emit the CRASH price scenario (16 prices), run the AI runner -> verdicts.
# 4. Verify on-chain state with cast call and log everything to
#    ../phase2-run-output.txt
#
# Testnet saja. Tidak menyentuh mainnet. Private key tidak pernah dicetak.
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"

ROOT="$HOME/workspace/bounty-hunt/reactive-omni"
PROJ="$ROOT/sentinel"
OUT="$ROOT/phase2-run-output.txt"
SEPOLIA_RPC="https://ethereum-sepolia-rpc.publicnode.com"
ASSET="0x0000000000000000000000000000000000001000"  # mock asset id

PK="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^0x[0-9a-fA-F]{64}$/){print $i; exit}}' "$ROOT/dev-wallet.txt")"
ADDR="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^0x[0-9a-fA-F]{40}$/){print $i; exit}}' "$ROOT/dev-wallet.txt")"
if [ -z "$PK" ] || [ -z "$ADDR" ]; then echo "dev wallet tidak terbaca"; exit 1; fi

log() { echo "[phase2] $*" | tee -a "$OUT"; }
: > "$OUT"
log "Dev wallet: $ADDR"

BAL="$(cast balance "$ADDR" --rpc-url "$SEPOLIA_RPC")"
log "Saldo Sepolia: $BAL wei"
MIN=100000000000000000
if [ "$(awk -v b="$BAL" -v m="$MIN" 'BEGIN{print (b<m)?1:0}')" = "1" ]; then
  log "BLOCKER: saldo SepETH di bawah 0.1."
  exit 2
fi

cd "$PROJ"

# --- 1. Deploy ----------------------------------------------------------------
EMIT_JSON="$(forge create src/PriceEmitter.sol:PriceEmitter \
  --rpc-url "$SEPOLIA_RPC" --private-key "$PK" --broadcast --json \
  --constructor-args "$ASSET")"
EMITTER="$(echo "$EMIT_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["deployedTo"])')"
EMITTER_TX="$(echo "$EMIT_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["transactionHash"])')"
[ -z "$EMITTER" ] && { log "GAGAL: deploy PriceEmitter."; exit 6; }
log "PriceEmitter (Sepolia): $EMITTER (deploy tx $EMITTER_TX)"

ORACLE_JSON="$(forge create src/AIOracle.sol:AIOracle \
  --rpc-url "$SEPOLIA_RPC" --private-key "$PK" --broadcast --json \
  --constructor-args "$ADDR")"
ORACLE="$(echo "$ORACLE_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["deployedTo"])')"
ORACLE_TX="$(echo "$ORACLE_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["transactionHash"])')"
[ -z "$ORACLE" ] && { log "GAGAL: deploy AIOracle."; exit 7; }
log "AIOracle (Sepolia): $ORACLE (deploy tx $ORACLE_TX)"

echo "EMITTER=$EMITTER" > "$ROOT/phase2-addresses.env"
echo "ORACLE=$ORACLE" >> "$ROOT/phase2-addresses.env"

FROM_BLOCK="$(cast block-number --rpc-url "$SEPOLIA_RPC")"
log "Runner mulai scan dari blok $FROM_BLOCK"
rm -f "$PROJ/ai/runner_state.json"

# --- 2. Calm scenario -----------------------------------------------------------
log "Emit skenario CALM (16 harga)..."
python3 "$PROJ/ai/emit_prices.py" --emitter "$EMITTER" --scenario calm 2>&1 | tee -a "$OUT"
log "Runner setelah CALM:"
python3 "$PROJ/ai/runner.py" --emitter "$EMITTER" --oracle "$ORACLE" --from-block "$FROM_BLOCK" 2>&1 | tee -a "$OUT"

# --- 3. Crash scenario ----------------------------------------------------------
log "Emit skenario CRASH (16 harga)..."
python3 "$PROJ/ai/emit_prices.py" --emitter "$EMITTER" --scenario crash 2>&1 | tee -a "$OUT"
log "Runner setelah CRASH:"
python3 "$PROJ/ai/runner.py" --emitter "$EMITTER" --oracle "$ORACLE" 2>&1 | tee -a "$OUT"

# --- 3b. Volatile scenario (wave-2 revision: third-regime proof) -----------------
log "Emit skenario VOLATILE (16 harga)..."
python3 "$PROJ/ai/emit_prices.py" --emitter "$EMITTER" --scenario volatile 2>&1 | tee -a "$OUT"
log "Runner setelah VOLATILE:"
python3 "$PROJ/ai/runner.py" --emitter "$EMITTER" --oracle "$ORACLE" 2>&1 | tee -a "$OUT"

# --- 4. Verifikasi ---------------------------------------------------------------
log "Verifikasi on-chain:"
log "PriceEmitter.updateCount = $(cast call "$EMITTER" 'updateCount()(uint256)' --rpc-url "$SEPOLIA_RPC")"
log "AIOracle.verdictCount    = $(cast call "$ORACLE" 'verdictCount()(uint256)' --rpc-url "$SEPOLIA_RPC")"
log "Verdict[0] (calm)        = $(cast call "$ORACLE" 'getVerdict(uint256)(bytes32,uint8,uint8,uint256,uint256)' 0 --rpc-url "$SEPOLIA_RPC" | tr '\n' ' ')"
log "LatestVerdict (crash)    = $(cast call "$ORACLE" 'latestVerdict()(bytes32,uint8,uint8,uint256,uint256)' --rpc-url "$SEPOLIA_RPC" | tr '\n' ' ')"
log "Saldo Sepolia akhir: $(cast balance "$ADDR" --rpc-url "$SEPOLIA_RPC") wei"
log "SELESAI."
