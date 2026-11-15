"""SENTINEL AI — feature extraction from a price window.

A window is a list of integer prices (USD cents in the demo). All features are
computed from log returns so they are scale-free: the same window shape gives
the same features regardless of the asset's absolute price level.
"""

import numpy as np

WINDOW = 16  # prices per window -> 15 log returns
N_FEATURES = 8

FEATURE_NAMES = [
    "cum_return",    # log(p_last / p_first): total move across the window
    "mean_return",   # average per-step log return (drift)
    "volatility",    # std of per-step log returns
    "max_drawdown",  # worst peak-to-trough decline inside the window (fraction)
    "last_return",   # most recent per-step log return
    "worst_return",  # most negative single step
    "down_fraction", # share of steps that went down
    "log_range",     # log(max / min) across the window
]


def extract_features(prices) -> np.ndarray:
    """Return the (8,) float64 feature vector for one price window."""
    p = np.asarray(prices, dtype=np.float64)
    if p.ndim != 1 or len(p) < 2:
        raise ValueError("window needs at least 2 prices")
    if np.any(p <= 0):
        raise ValueError("prices must be positive")

    rets = np.diff(np.log(p))

    running_max = np.maximum.accumulate(p)
    drawdowns = (running_max - p) / running_max

    return np.array(
        [
            np.log(p[-1] / p[0]),
            rets.mean(),
            rets.std(),
            drawdowns.max(),
            rets[-1],
            rets.min(),
            float(np.mean(rets < 0)),
            np.log(p.max() / p.min()),
        ],
        dtype=np.float64,
    )


def extract_batch(windows) -> np.ndarray:
    """(n_windows, 8) feature matrix."""
    return np.stack([extract_features(w) for w in windows])
