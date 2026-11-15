"""SENTINEL Phase 4 — compact-scenario price emitter.

Phase 4 reuses the Phase 2 scenarios but only needs a compact series:

  calm-prefix — first 8 prices of DEMO_CALM (short calm prefix: the new
                guardian must process non-danger verdicts without firing)
  crash       — the full DEMO_CRASH series (guardian must fire exactly once)

Emission uses the same sanitized cast-send helper as emit_prices.py (error
output never contains the argument list / private key). The Phase 2 runner
and model are untouched.

Usage:
  python3 emit_phase4.py --emitter 0x... --series calm-prefix
  python3 emit_phase4.py --emitter 0x... --series crash [--skip N]
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from emit_prices import cast_send  # noqa: E402  (sanitized, retrying)
from train import DEMO_CALM, DEMO_CRASH  # noqa: E402
from wallet import load_dev_wallet  # noqa: E402

SERIES = {"calm-prefix": DEMO_CALM[:8], "crash": DEMO_CRASH}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--emitter", required=True)
    ap.add_argument("--series", choices=sorted(SERIES), required=True)
    ap.add_argument("--skip", type=int, default=0,
                    help="skip the first N prices (resume an interrupted emission)")
    args = ap.parse_args()

    _, pk = load_dev_wallet()
    prices = SERIES[args.series][args.skip:]
    print(f"[emit4] series={args.series} skip={args.skip} prices={len(prices)}")
    for i, price in enumerate(prices):
        tx = cast_send(pk, args.emitter, "publishPrice(uint256)", str(price))
        print(f"[emit4] {i + 1:2d}/{len(prices)} price={price} tx={tx}")


if __name__ == "__main__":
    main()
