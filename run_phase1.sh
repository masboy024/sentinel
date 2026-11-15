#!/usr/bin/env bash
# SENTINEL Phase 1 — on-chain skeleton loop runner.
#
# Prasyarat: dev wallet (../dev-wallet.txt) terisi >= 0.15 SepETH di Ethereum Sepolia.
# Cara termudah mengisi: buka https://sepolia-faucet.pk910.de di browser,
# selesaikan captcha, masukkan alamat dev wallet, mining sampai saldo >= 0.15 SepETH, lalu claim.
#
# Script ini akan:
#   1. Menukar 0.05 SepETH -> 5 lREACT lewat kontrak faucet resmi Reactive (Ethereum Sepolia).
#   2. Deploy OriginEmitter (Sepolia), SentinelReactive (Lasna, dibiayai 2 lREACT),
#      CallbackRecorder (Sepolia, dibiayai 0.02 SepETH).
#   3. setRecipient di kontrak reaktif.
#   4. Memicu ping(42) di origin, menunggu reaksi di Lasna, menunggu callback di Sepolia.
#   5. Menulis rantai hash + alamat kontrak ke ../phase1-run-output.txt
#
# Testnet saja. Tidak menyentuh mainnet.
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"

ROOT="$HOME/workspace/bounty-hunt/reactive-omni"
PROJ="$ROOT/sentinel"
OUT="$ROOT/phase1-run-output.txt"

SEPOLIA_RPC="https://ethereum-sepolia-rpc.publicnode.com"
LASNA_RPC="https://lasna-rpc.rnk.dev/"
SEPOLIA_ID=11155111
CALLBACK_PROXY="0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4"   # Ethereum Sepolia (docs: origins-and-destinations)
REACTIVE_FAUCET="0x9b9BB25f1A81078C544C829c5EB7822d747Cf434" # Ethereum Sepolia (docs: reactive-mainnet)

PK="$(grep -i 'private key' "$ROOT/dev-wallet.txt" | awk '{print $NF}')"
ADDR="$(grep -i '^Address' "$ROOT/dev-wallet.txt" | awk '{print $NF}')"
# Fallback: format file tanpa label "<address> <privatekey>" dalam satu baris.
if [ -z "$ADDR" ]; then
  ADDR="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^0x[0-9a-fA-F]{40}$/){print $i; exit}}' "$ROOT/dev-wallet.txt")"
fi
if [ -z "$PK" ]; then
  PK="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^0x[0-9a-fA-F]{64}$/){print $i; exit}}' "$ROOT/dev-wallet.txt")"
fi
if [ -z "$PK" ] || [ -z "$ADDR" ]; then echo "dev wallet tidak terbaca"; exit 1; fi

log() { echo "[phase1] $*" | tee -a "$OUT"; }
: > "$OUT"
log "Dev wallet: $ADDR"

BAL="$(cast balance "$ADDR" --rpc-url "$SEPOLIA_RPC")"
log "Saldo Sepolia: $BAL wei"
# butuh >= 0.12 ETH (swap 0.05 + deploy/funding/gas)
MIN=120000000000000000
if [ "$(awk -v b="$BAL" -v m="$MIN" 'BEGIN{print (b<m)?1:0}')" = "1" ]; then
  log "BLOCKER: saldo SepETH di bawah 0.12. Isi dulu via faucet (lihat header script)."
  exit 2
fi

cd "$PROJ"

# --- 1. Swap SepETH -> lREACT -------------------------------------------------
LBAL="$(cast balance "$ADDR" --rpc-url "$LASNA_RPC")"
if [ "$LBAL" = "0" ]; then
  log "Menukar 0.05 SepETH -> lREACT via faucet Reactive..."
  SWAP_JSON="$(cast send "$REACTIVE_FAUCET" "request(address)" "$ADDR" \
    --value 0.05ether --rpc-url "$SEPOLIA_RPC" --private-key "$PK" --json)"
  echo "SWAP_TX_JSON: $SWAP_JSON" >> "$OUT"
  for i in $(seq 1 30); do
    sleep 10
    LBAL="$(cast balance "$ADDR" --rpc-url "$LASNA_RPC")"
    [ "$LBAL" != "0" ] && break
  done
fi
log "Saldo lREACT (Lasna): $LBAL wei"
[ "$LBAL" = "0" ] && { log "BLOCKER: lREACT belum tiba setelah swap."; exit 3; }

# --- 2. Deploy OriginEmitter (Sepolia) ---------------------------------------
ORIGIN_JSON="$(forge create src/OriginEmitter.sol:OriginEmitter \
  --rpc-url "$SEPOLIA_RPC" --private-key "$PK" --broadcast --json)"
ORIGIN="$(echo "$ORIGIN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["deployedTo"])')"
[ -z "$ORIGIN" ] && { log "GAGAL: deploy OriginEmitter tidak menghasilkan alamat."; exit 6; }
log "OriginEmitter (Sepolia): $ORIGIN"

# --- 3. Deploy SentinelReactive (Lasna) --------------------------------------
REACTIVE_JSON="$(forge create src/SentinelReactive.sol:SentinelReactive \
  --rpc-url "$LASNA_RPC" --private-key "$PK" --value 2ether --broadcast --json \
  --constructor-args $SEPOLIA_ID "$ORIGIN" $SEPOLIA_ID)"
REACTIVE="$(echo "$REACTIVE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["deployedTo"])')"
[ -z "$REACTIVE" ] && { log "GAGAL: deploy SentinelReactive tidak menghasilkan alamat."; exit 7; }
log "SentinelReactive (Lasna): $REACTIVE"

# --- 4. Deploy CallbackRecorder (Sepolia) ------------------------------------
RECORDER_JSON="$(forge create src/CallbackRecorder.sol:CallbackRecorder \
  --rpc-url "$SEPOLIA_RPC" --private-key "$PK" --value 0.02ether --broadcast --json \
  --constructor-args "$CALLBACK_PROXY" "$REACTIVE")"
RECORDER="$(echo "$RECORDER_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["deployedTo"])')"
[ -z "$RECORDER" ] && { log "GAGAL: deploy CallbackRecorder tidak menghasilkan alamat."; exit 8; }
log "CallbackRecorder (Sepolia): $RECORDER"

# --- 5. setRecipient ----------------------------------------------------------
cast send "$REACTIVE" "setRecipient(address)" "$RECORDER" \
  --rpc-url "$LASNA_RPC" --private-key "$PK" > /dev/null
log "Recipient diset: $RECORDER"

# --- 6. Picu event origin -----------------------------------------------------
LASNA_BLOCK_BEFORE="$(cast block-number --rpc-url "$LASNA_RPC")"
SEPOLIA_BLOCK_BEFORE="$(cast block-number --rpc-url "$SEPOLIA_RPC")"
PING_JSON="$(cast send "$ORIGIN" "ping(uint256)" 42 \
  --rpc-url "$SEPOLIA_RPC" --private-key "$PK" --json)"
PING_TX="$(echo "$PING_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["transactionHash"])')"
log "TX origin (ping): $PING_TX"

# --- 7. Tunggu reaksi di Lasna ------------------------------------------------
REACT_COUNT=0
for i in $(seq 1 60); do
  sleep 10
  REACT_COUNT="$(cast call "$REACTIVE" "reactionCount()(uint256)" --rpc-url "$LASNA_RPC" 2>/dev/null || echo 0)"
  [ "$REACT_COUNT" != "0" ] && break
done
log "reactionCount di Lasna: $REACT_COUNT"
[ "$REACT_COUNT" = "0" ] && { log "GAGAL: tidak ada reaksi di Lasna dalam 10 menit."; exit 4; }

REACT_LOGS="$(cast logs --rpc-url "$LASNA_RPC" --address "$REACTIVE" \
  --from-block "$LASNA_BLOCK_BEFORE" \
  "ReactionRecorded(uint256,uint256)" 2>/dev/null)"
echo "--- ReactionRecorded logs (Lasna) ---" >> "$OUT"
echo "$REACT_LOGS" >> "$OUT"
REACT_TX="$(echo "$REACT_LOGS" | grep -i 'transactionHash' | head -1 | awk '{print $NF}')"
log "TX reaksi (Lasna): $REACT_TX"

# Bukti tambahan: event CallbackRequest dari system contract di Lasna (best effort)
cast logs --rpc-url "$LASNA_RPC" --address 0x8888888888888888888888888888888888888888 \
  --from-block "$LASNA_BLOCK_BEFORE" \
  "CallbackRequest(uint256,address,address,uint8,bytes)" >> "$OUT" 2>/dev/null || true

# --- 8. Tunggu callback di Sepolia --------------------------------------------
CB_COUNT=0
for i in $(seq 1 60); do
  sleep 10
  CB_COUNT="$(cast call "$RECORDER" "callbackCount()(uint256)" --rpc-url "$SEPOLIA_RPC" 2>/dev/null || echo 0)"
  [ "$CB_COUNT" != "0" ] && break
done
log "callbackCount di Sepolia: $CB_COUNT"
[ "$CB_COUNT" = "0" ] && { log "GAGAL: callback tidak tiba di Sepolia dalam 10 menit."; exit 5; }

CB_LOGS="$(cast logs --rpc-url "$SEPOLIA_RPC" --address "$RECORDER" \
  --from-block "$SEPOLIA_BLOCK_BEFORE" \
  "CallbackRecorded(address,uint256,uint256)" 2>/dev/null)"
echo "--- CallbackRecorded logs (Sepolia) ---" >> "$OUT"
echo "$CB_LOGS" >> "$OUT"
CB_TX="$(echo "$CB_LOGS" | grep -i 'transactionHash' | head -1 | awk '{print $NF}')"
log "TX callback (Sepolia): $CB_TX"

log "LOOP PENUH BERHASIL: origin $PING_TX -> reaksi $REACT_TX -> callback $CB_TX"
