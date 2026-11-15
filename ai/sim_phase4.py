"""SENTINEL Phase 4 — offline verdict-arc simulation (posts NOTHING).

Replays the candidate Phase 4 price series through the Phase 2 model using
the persisted runner window, exactly like the runner would, so the on-chain
run has no surprises:

  calm prefix — first 8 prices of DEMO_CALM (short, shows no false trigger)
  crash leg   — the full DEMO_CRASH series

Usage: python3 sim_phase4.py
"""

import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from features import WINDOW, extract_features  # noqa: E402
from model import REGIME_NAMES, SentinelMLP  # noqa: E402
from train import DEMO_CALM, DEMO_CRASH  # noqa: E402

HERE = Path(__file__).resolve().parent


def main():
    state = json.loads((HERE / "runner_state.json").read_text())
    window = list(state["window"])
    net = SentinelMLP.load(str(HERE / "weights.npz"))

    series = [("calm", p) for p in DEMO_CALM[:8]] + [
        ("crash", p) for p in DEMO_CRASH
    ]
    peak = 0
    danger_steps = []
    for i, (leg, price) in enumerate(series):
        window = (window + [price])[-WINDOW:]
        peak = max(peak, price)
        feats = extract_features(window)
        regime_arr, risk_arr, probs = net.predict(feats.reshape(1, -1))
        regime = int(regime_arr[0])
        risk = int(round(float(risk_arr[0])))
        drop = 100.0 * (peak - price) / peak if peak else 0.0
        danger = regime == 2 and risk >= 80 and drop >= 10.0
        if danger:
            danger_steps.append(i + 1)
        print(
            f"step {i + 1:2d} [{leg:5s}] price={price:6d} risk={risk:3d} "
            f"regime={REGIME_NAMES[regime]:10s} peak={peak:6d} drop={drop:5.1f}% "
            f"probs={np.round(probs[0], 3).tolist()}"
            + ("  <-- GUARDIAN WOULD FIRE" if danger and len(danger_steps) == 1 else "")
        )
    print(f"\ndanger steps (regime2 & risk>=80 & drop>=10%): {danger_steps}")
    print(f"first fire step: {danger_steps[0] if danger_steps else 'NONE'}")


if __name__ == "__main__":
    main()
