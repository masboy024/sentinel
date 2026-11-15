"""SENTINEL AI — a small multi-task MLP in pure numpy (no API keys, no torch).

Architecture: input (8 features) -> hidden layer (tanh) -> two heads:
  * regime head: softmax over 3 classes (0=calm, 1=volatile, 2=crash-risk)
  * risk head:   sigmoid scaled to 0-100

Loss = cross-entropy(regime) + MSE(risk/100). Trained with Adam, full batch,
deterministic seed. Weights + feature standardisation stats are saved to a
single .npz so the runner reproduces training-time preprocessing exactly.
"""

import numpy as np

REGIME_NAMES = ["calm", "volatile", "crash-risk"]


class SentinelMLP:
    def __init__(self, n_features=8, hidden=24, seed=42):
        rng = np.random.default_rng(seed)
        self.W1 = rng.normal(0, np.sqrt(2.0 / n_features), (n_features, hidden))
        self.b1 = np.zeros(hidden)
        self.Wr = rng.normal(0, np.sqrt(2.0 / hidden), (hidden, 3))
        self.br = np.zeros(3)
        self.Ws = rng.normal(0, np.sqrt(2.0 / hidden), (hidden, 1))
        self.bs = np.zeros(1)
        self.mu = np.zeros(n_features)
        self.sigma = np.ones(n_features)

    # ---- forward -----------------------------------------------------------
    def _forward(self, X):
        Xs = (X - self.mu) / self.sigma
        H = np.tanh(Xs @ self.W1 + self.b1)
        logits = H @ self.Wr + self.br
        logits = logits - logits.max(axis=1, keepdims=True)
        exp = np.exp(logits)
        probs = exp / exp.sum(axis=1, keepdims=True)
        risk01 = 1.0 / (1.0 + np.exp(-(H @ self.Ws + self.bs)))
        return Xs, H, probs, risk01

    def predict(self, X):
        """X: (n, n_features) raw features -> (regime (n,), risk 0-100 (n,), probs (n,3))."""
        X = np.atleast_2d(np.asarray(X, dtype=np.float64))
        _, _, probs, risk01 = self._forward(X)
        return probs.argmax(axis=1), risk01[:, 0] * 100.0, probs

    # ---- training ----------------------------------------------------------
    def fit(self, X, y_regime, y_risk, epochs=400, lr=0.01, seed=42):
        X = np.asarray(X, dtype=np.float64)
        self.mu = X.mean(axis=0)
        self.sigma = X.std(axis=0) + 1e-9
        n = len(X)
        Y = np.zeros((n, 3))
        Y[np.arange(n), y_regime] = 1.0
        R = (np.asarray(y_risk, dtype=np.float64) / 100.0).reshape(-1, 1)

        params = [self.W1, self.b1, self.Wr, self.br, self.Ws, self.bs]
        m = [np.zeros_like(p) for p in params]
        v = [np.zeros_like(p) for p in params]
        b1_, b2_, eps = 0.9, 0.999, 1e-8

        for t in range(1, epochs + 1):
            Xs, H, probs, risk01 = self._forward(X)
            # gradients (softmax CE + sigmoid MSE, averaged)
            dlogits = (probs - Y) / n
            drisk = (2.0 * (risk01 - R) * risk01 * (1.0 - risk01)) / n
            gWr = H.T @ dlogits
            gbr = dlogits.sum(axis=0)
            gWs = H.T @ drisk
            gbs = drisk.sum(axis=0)
            dH = dlogits @ self.Wr.T + drisk @ self.Ws.T
            dZ = dH * (1.0 - H**2)
            gW1 = Xs.T @ dZ
            gb1 = dZ.sum(axis=0)
            grads = [gW1, gb1, gWr, gbr, gWs, gbs]
            for i in range(len(params)):
                m[i] = b1_ * m[i] + (1 - b1_) * grads[i]
                v[i] = b2_ * v[i] + (1 - b2_) * grads[i] ** 2
                mh = m[i] / (1 - b1_**t)
                vh = v[i] / (1 - b2_**t)
                params[i] -= lr * mh / (np.sqrt(vh) + eps)
            self.W1, self.b1, self.Wr, self.br, self.Ws, self.bs = params
        return self

    # ---- persistence ---------------------------------------------------------
    def save(self, path):
        np.savez(
            path,
            W1=self.W1, b1=self.b1, Wr=self.Wr, br=self.br,
            Ws=self.Ws, bs=self.bs, mu=self.mu, sigma=self.sigma,
        )

    @classmethod
    def load(cls, path):
        d = np.load(path)
        net = cls(n_features=d["W1"].shape[0], hidden=d["W1"].shape[1])
        net.W1, net.b1 = d["W1"], d["b1"]
        net.Wr, net.br = d["Wr"], d["br"]
        net.Ws, net.bs = d["Ws"], d["bs"]
        net.mu, net.sigma = d["mu"], d["sigma"]
        return net
