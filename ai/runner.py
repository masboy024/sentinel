"""SENTINEL AI runner — the AI inside the system.

Loop:
  1. Poll `PriceUpdated` events from the PriceEmitter on Sepolia (eth_getLogs).
  2. Maintain the sliding price window (persisted in a state file).
  3. Once the window is full (cold start needs WINDOW prices), run the local
     MLP on the window's features for every new price.
  4. Post each verdict to the AIOracle via `cast send` (dev wallet = runner).
     The verdict commits to keccak256(window) so anyone can reproduce it from
     the public event history.

Usage:
  python3 runner.py --emitter 0x... --oracle 0x... --from-block 12345
State: runner_state.json next to this file (last block, window, tx hashes).
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

import numpy as np
import requests

sys.path.insert(0, str(Path(__file__).resolve().parent))
from features import WINDOW, extract_features  # noqa: E402
from model import REGIME_NAMES, SentinelMLP  # noqa: E402
from wallet import load_dev_wallet  # noqa: E402

HERE = Path(__file__).resolve().parent
SEPOLIA_RPC = "https://ethereum-sepolia-rpc.publicnode.com"
PRICE_UPDATED_TOPIC = "0xb556fac599c3c70efb9ab1fa725ecace6c81cc48d1455f886607def065f3e0c0"
CAST = str(Path.home() / ".foundry" / "bin" / "cast")


def rpc(method, params):
    r = requests.post(
        SEPOLIA_RPC,
        json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params},
        timeout=30,
    )
    r.raise_for_status()
    out = r.json()
    if "error" in out:
        raise RuntimeError(f"RPC {method}: {out['error']}")
    return out["result"]


def fetch_price_events(emitter, from_block, to_block):
    """Return [(blockNumber, price)] for PriceUpdated logs, in chain order.

    Public RPC endpoints are load-balanced; a node can report a head that is
    one block behind the node serving eth_blockNumber. Clamp the range to a
    freshly read head and retry once on a range error.
    """
    events = []
    start = from_block
    while start <= to_block:
        end = min(start + 2000, to_block)
        try:
            logs = rpc(
                "eth_getLogs",
                [
                    {
                        "address": emitter,
                        "topics": [PRICE_UPDATED_TOPIC],
                        "fromBlock": hex(start),
                        "toBlock": hex(end),
                    }
                ],
            )
        except RuntimeError:
            end = int(rpc("eth_blockNumber", []), 16)
            if end < start:
                break
            logs = rpc(
                "eth_getLogs",
                [
                    {
                        "address": emitter,
                        "topics": [PRICE_UPDATED_TOPIC],
                        "fromBlock": hex(start),
                        "toBlock": hex(end),
                    }
                ],
            )
        for log in logs:
            data = log["data"][2:]
            price = int(data[0:64], 16)
            events.append((int(log["blockNumber"], 16), price))
        start = end + 1
    return events


def window_input_hash(window):
    """keccak256 of the window encoded as concatenated uint256 words."""
    payload = "0x" + "".join(f"{int(p):064x}" for p in window)
    out = subprocess.run(
        [CAST, "keccak", payload], capture_output=True, text=True, check=True
    )
    return out.stdout.strip()


def post_verdict(oracle, pk, input_hash, risk, regime, price):
    """cast send with retries. On failure raise with cast's own stderr only —
    never the argument list (it contains the private key)."""
    import time

    last_err = ""
    for attempt in range(3):
        out = subprocess.run(
            [
                CAST, "send", oracle,
                "submitVerdict(bytes32,uint8,uint8,uint256)",
                input_hash, str(risk), str(regime), str(price),
                "--private-key", pk, "--rpc-url", SEPOLIA_RPC, "--json",
            ],
            capture_output=True, text=True,
        )
        if out.returncode == 0:
            return json.loads(out.stdout)["transactionHash"]
        last_err = (out.stderr or out.stdout).strip()
        print(f"[runner] verdict send failed (attempt {attempt + 1}/3): {last_err[:200]}")
        time.sleep(5)
    raise RuntimeError(f"submitVerdict failed after 3 attempts: {last_err[:200]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--emitter", required=True)
    ap.add_argument("--oracle", required=True)
    ap.add_argument("--from-block", type=int, default=None,
                    help="first block to scan (only used when no state exists)")
    ap.add_argument("--state", default=str(HERE / "runner_state.json"))
    ap.add_argument("--weights", default=str(HERE / "weights.npz"))
    args = ap.parse_args()

    state_path = Path(args.state)
    if state_path.exists():
        state = json.loads(state_path.read_text())
    else:
        if args.from_block is None:
            sys.exit("no state file and no --from-block given")
        state = {"next_block": args.from_block, "window": [], "verdicts": []}

    _, pk = load_dev_wallet()
    net = SentinelMLP.load(args.weights)

    latest = int(rpc("eth_blockNumber", []), 16)
    events = fetch_price_events(args.emitter, state["next_block"], latest)
    print(f"[runner] blocks {state['next_block']}..{latest}: {len(events)} new price events")

    for block, price in events:
        state["window"] = (state["window"] + [price])[-WINDOW:]
        if len(state["window"]) < WINDOW:
            print(f"[runner] block {block} price {price}: warming up "
                  f"({len(state['window'])}/{WINDOW})")
            continue
        feats = extract_features(state["window"])
        regime_arr, risk_arr, probs = net.predict(feats.reshape(1, -1))
        regime = int(regime_arr[0])
        risk = int(round(float(risk_arr[0])))
        ihash = window_input_hash(state["window"])
        tx = post_verdict(args.oracle, pk, ihash, risk, regime, price)
        state["verdicts"].append(
            {"block": block, "price": price, "risk": risk,
             "regime": REGIME_NAMES[regime], "inputHash": ihash, "tx": tx}
        )
        print(f"[runner] block {block} price {price}: risk={risk} "
              f"regime={REGIME_NAMES[regime]} probs={np.round(probs[0], 3).tolist()} tx={tx}")
        state_path.write_text(json.dumps(state, indent=2))

    state["next_block"] = latest + 1
    state_path.write_text(json.dumps(state, indent=2))
    print(f"[runner] done. total verdicts posted: {len(state['verdicts'])}")


if __name__ == "__main__":
    main()
