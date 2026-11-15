"""SENTINEL Phase 2 — scenario price emitter.

Publishes a deterministic price series to the PriceEmitter on Sepolia, one
`publishPrice` transaction per price, and prints each tx hash. Scenarios:

  calm  — 16 prices, ±0.15% jitter around $2,000.00 (feeds the first window)
  crash — 16 prices continuing from the calm series: a ~52% sell-off

Prices are integer USD cents. Usage:
  python3 emit_prices.py --emitter 0x... --scenario calm
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from train import DEMO_CALM, DEMO_CRASH, DEMO_VOLATILE  # noqa: E402
from wallet import load_dev_wallet  # noqa: E402

SEPOLIA_RPC = "https://ethereum-sepolia-rpc.publicnode.com"
CAST = str(Path.home() / ".foundry" / "bin" / "cast")

SCENARIOS = {"calm": DEMO_CALM, "crash": DEMO_CRASH, "volatile": DEMO_VOLATILE}


def cast_send(pk, to, signature, *args):
    """cast send with retries. On failure raise with cast's own stderr only —
    never the argument list (it contains the private key)."""
    import time

    last_err = ""
    for attempt in range(3):
        out = subprocess.run(
            [CAST, "send", to, signature, *args,
             "--private-key", pk, "--rpc-url", SEPOLIA_RPC, "--json"],
            capture_output=True, text=True,
        )
        if out.returncode == 0:
            return json.loads(out.stdout)["transactionHash"]
        last_err = (out.stderr or out.stdout).strip()
        print(f"[emit] send failed (attempt {attempt + 1}/3): {last_err[:200]}")
        time.sleep(5)
    raise RuntimeError(f"cast send failed after 3 attempts: {last_err[:200]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--emitter", required=True)
    ap.add_argument("--scenario", choices=sorted(SCENARIOS), required=True)
    ap.add_argument("--skip", type=int, default=0,
                    help="skip the first N prices (resume an interrupted emission)")
    args = ap.parse_args()

    _, pk = load_dev_wallet()
    prices = SCENARIOS[args.scenario][args.skip:]
    print(f"[emit] scenario={args.scenario} skip={args.skip} prices={len(prices)}")
    for i, price in enumerate(prices):
        tx = cast_send(pk, args.emitter, "publishPrice(uint256)", str(price))
        print(f"[emit] {i + 1:2d}/{len(prices)} price={price} tx={tx}")


if __name__ == "__main__":
    main()
