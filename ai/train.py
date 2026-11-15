"""SENTINEL AI — synthetic training data + model training.

Three market regimes are simulated as geometric random walks with distinct
drift/volatility signatures, then labelled with a regime and a plausible risk
target. The model never sees the generator's parameters — it must infer the
regime from the window's features alone.

Run: python3 train.py   (deterministic, seed 42)
Outputs: weights.npz, train_report.json
"""

import json

import numpy as np

from features import WINDOW, extract_batch
from model import REGIME_NAMES, SentinelMLP

SEED = 42
BASE_PRICE = 200_000  # $2,000.00 in cents

# Demo windows that will be emitted on-chain in Phase 2 (sanity targets).
DEMO_CALM = [
    200000, 200120, 200060, 200210, 200150, 200090, 200240, 200180,
    200260, 200200, 200140, 200290, 200230, 200310, 200250, 200330,
]
DEMO_CRASH = [  # continuation after the calm window: sharp sell-off
    196000, 190500, 184000, 176500, 168000, 159000, 149500, 140000,
    131000, 123500, 117000, 111500, 107000, 103000, 99500, 96000,
]
DEMO_VOLATILE = [  # wave-2 addition: choppy sideways market after the crash
    98500, 95500, 99000, 96000, 100000, 97000, 99500, 96500,
    100500, 97500, 99000, 96000, 98500, 95500, 99000, 97500,
]


def gen_window(rng, regime):
    """One synthetic price window of length WINDOW for the given regime."""
    if regime == 0:  # calm: tiny noise, no drift
        steps = rng.normal(0.0, 0.0012, WINDOW - 1)
    elif regime == 1:  # volatile: big noise, no drift
        steps = rng.normal(0.0, 0.02, WINDOW - 1)
    else:  # crash-risk: strong negative drift + elevated noise
        steps = rng.normal(-0.038, 0.016, WINDOW - 1)
    prices = BASE_PRICE * np.exp(np.concatenate([[0.0], np.cumsum(steps)]))
    return np.maximum(prices, 1.0).round().astype(np.int64)


def risk_target(rng, regime):
    """Plausible risk-score label per regime (with overlap at the edges)."""
    if regime == 0:
        return float(rng.uniform(5, 30))
    if regime == 1:
        return float(rng.uniform(40, 70))
    return float(rng.uniform(78, 99))


def gen_dataset(rng, per_regime):
    windows, regimes, risks = [], [], []
    for regime in range(3):
        for _ in range(per_regime):
            windows.append(gen_window(rng, regime))
            regimes.append(regime)
            risks.append(risk_target(rng, regime))
    return windows, np.array(regimes), np.array(risks)


def main():
    rng = np.random.default_rng(SEED)
    tr_w, tr_y, tr_r = gen_dataset(rng, 1000)
    te_w, te_y, te_r = gen_dataset(rng, 300)
    Xtr, Xte = extract_batch(tr_w), extract_batch(te_w)

    net = SentinelMLP(n_features=Xtr.shape[1], hidden=24, seed=SEED)
    net.fit(Xtr, tr_y, tr_r, epochs=400, lr=0.01, seed=SEED)

    pred_y, pred_r, _ = net.predict(Xte)
    acc = float(np.mean(pred_y == te_y))
    mae = float(np.mean(np.abs(pred_r - te_r)))
    per_regime = {
        REGIME_NAMES[k]: float(np.mean(pred_y[te_y == k] == k)) for k in range(3)
    }

    # Calm demo: the calm window itself. Crash demo: the final full window a
    # live runner sees after the sell-off = last 16 prices of calm+crash.
    from features import extract_features

    demo = {}

    full = DEMO_CALM + DEMO_CRASH
    for name, window in [("calm_window", DEMO_CALM), ("crash_window", full[-WINDOW:])]:
        reg, risk, probs = net.predict(extract_features(window).reshape(1, -1))
        demo[name] = {
            "regime": REGIME_NAMES[int(reg[0])],
            "risk": round(float(risk[0]), 1),
            "probs": [round(float(x), 3) for x in probs[0]],
        }

    net.save("weights.npz")
    report = {
        "seed": SEED,
        "train_windows": len(tr_w),
        "test_windows": len(te_w),
        "held_out_regime_accuracy": round(acc, 4),
        "held_out_risk_mae": round(mae, 2),
        "per_regime_accuracy": {k: round(v, 4) for k, v in per_regime.items()},
        "demo_windows": demo,
    }
    with open("train_report.json", "w") as f:
        json.dump(report, f, indent=2)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
