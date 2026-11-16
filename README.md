# SENTINEL — AI Risk Guardian for DeFi Positions

**Reactive Omni Buildathon (DoraHacks) · Track: Reactive Meets AI**

> A small neural network watches an on-chain price stream, judges the market regime in real time, and — when it confirms real danger — a reactive contract on Reactive Lasna fires a cross-chain callback that moves a vault position to safety on Base Sepolia. No human, no keeper bot, no static threshold.

Built solo during the event window (Nov–Dec 2026). Everything below ran on public testnets (Ethereum Sepolia, Reactive Lasna, Base Sepolia) and every claim is backed by a transaction hash you can check yourself — see [Verify it yourself](#verify-it-yourself).

> **Sixty-second judge path:** the headline proof is the Phase 4 chain — AI verdict TX `0x609e8f42701286612c00ea2d28b6c8fbed8bcdc677627946f1267e0cabc3e352` (Sepolia, risk 83) → Lasna reaction TX `0xf2e837bb95f60a3e6d6e1d63a1294cef7d567e457d835c03b36ed6c45e8f8a7b` → Base Sepolia callback TX `0x50ce3b624014bd549989a51e323d64bc61f8671790e9325248e1f8b2dde48b57`, which moved the vault's position from 1,000,000 at-risk to 0 (1,000,000 safe). Full tables in [Proof](#proof--the-hash-chains); three `cast call` commands confirm the end state in [Verify it yourself](#verify-it-yourself).

---

## The problem

DeFi positions die in minutes. A leveraged position, an LP range, or a vault allocation can go from healthy to liquidated during a single sharp crash — usually while the owner is asleep. The tools that exist today each miss something:

- **Static stop-loss rules** ("sell if price drops 10%") fire on noise and can't tell a healthy pullback from the start of a crash.
- **Keeper/bot services** must be run, funded, and trusted by the user 24/7, and they see the market through one rigid rule set.
- **Manual monitoring** doesn't scale and doesn't work at 3 a.m.

What a position actually needs is a guardian that *understands the shape of the market* — calm, volatile, or genuinely crashing — and acts across chains the moment danger is confirmed, without anyone being online.

## The solution

SENTINEL puts a neural network **inside the reactive loop**, exactly where the Reactive Meets AI track asks for it:

1. **Prices are emitted on-chain** (Ethereum Sepolia) as `PriceUpdated` events.
2. **A local AI runner** (pure Python + numpy, no API keys) reads each new price, maintains a sliding window, and classifies the market regime — *calm*, *volatile*, or *crash-risk* — with a 0–100 risk score. Every verdict is **posted on-chain** to an `AIOracle` contract, together with a hash of the exact input window, so the model's decisions are public, permanent, and reproducible.
3. **A reactive guardian on Lasna** subscribes to *both* the raw price events *and* the AI verdicts. It fires a protection callback **only when danger is confirmed by two independent signals**: the AI says `crash-risk` with risk ≥ 80 **and** the live price has fallen ≥ 10% from its reference peak. A latch guarantees exactly one callback per danger episode.
4. **The destination vault on Base Sepolia** receives the callback through Reactive's official callback proxy and **executes the protection**: the entire at-risk position is moved to the safe balance, stamped with the risk score and the hash of the AI verdict transaction that caused it.

The result is a stop-loss that *thinks*: calm markets and ordinary volatility never trigger it (proven on-chain: 0 callbacks), a real crash triggers it exactly once (proven on-chain), and the action lands on a different chain from where the signal originated.

---

## Architecture

```
 Ethereum Sepolia (origin + AI layer)        Reactive Lasna (reactive layer)         Base Sepolia (action layer)
 ────────────────────────────────────        ───────────────────────────────         ───────────────────────────

 PriceEmitter                                SentinelGuardian                        SentinelVault
 publishPrice(p)                             subscribes to BOTH:                     holds a mock position
      │                                      · PriceUpdated  (from PriceEmitter)     positionAtRisk = 1,000,000
      │ PriceUpdated                              · VerdictPosted (from AIOracle)          │
      ▼                                            │                                       │ recordCallback(...)
 AI runner (local, Python/numpy)                   │ fires ONLY IF:                        │ via official callback
 polls eth_getLogs, 16-price window                │   regime == crash-risk              │ proxy, sender-checked
      │                                            │   AND riskScore >= 80               ▼
      │ MLP inference                              │   AND lastPrice >= 10% below     ProtectionExecuted:
      ▼                                            │   reference peak                    positionAtRisk ──▶ safeBalance
 AIOracle                                          │   (latched: 1 per episode)       (1,000,000 ──▶ 0 at risk,
 submitVerdict(inputHash, risk, ──VerdictPosted──▶ │                                       0 ──▶ 1,000,000 safe)
   regime, price)                                  └─── requestCallback ─────────────────┘
```

The same guardian code also ran with a Sepolia destination (Phase 3, `CallbackRecorder`), proving the design is destination-agnostic: the destination chain is a constructor parameter.

**Why two signals?** A price drop alone is a static rule; an AI verdict alone could be a model glitch. Requiring both — model says crash-risk *and* the market has actually fallen ≥ 10% — is what makes the protection trustworthy. The vault adds a third layer of defense: it independently rejects any callback carrying a risk score < 80.

---

## How the AI works

The model is deliberately small, fully local, and fully auditable — no external API, no keys, nothing hidden.

- **Input window:** the last **16 prices** from `PriceUpdated` events (the runner polls `eth_getLogs`; no verdict is issued until the window is full).
- **Features (8, all computed from log-returns of the window, so they are scale-free):** cumulative return, mean return, volatility (std of returns), max drawdown, last return, worst return, down-step fraction, log range (log max/min).
- **Model:** a pure-numpy multi-task MLP — input 8 → hidden layer 24 (tanh) → two heads: a 3-class **softmax** over regimes (0 = calm, 1 = volatile, 2 = crash-risk) and a **sigmoid risk head** (×100 → score 0–100). Trained with Adam, full-batch, 400 epochs, deterministic seed 42. Features are standardized with training statistics stored alongside the weights (`weights.npz`), so inference reproduces training preprocessing exactly.
- **Training data:** 3,000 synthetic labelled windows (1,000 per regime) of geometric random walks: calm (σ 0.12%/step, no drift), volatile (σ 2%/step, no drift), crash-risk (drift −3.8%/step, σ 1.6%). Target risk ranges: calm 5–30, volatile 40–70, crash 78–99. The model never sees the generator parameters — it must infer the regime from the window features.
- **Training results:** held-out regime accuracy **100%** (900 windows), risk-score MAE **6.56**. Offline sanity checks matched the on-chain behaviour step-for-step in every phase.
- **Verdict format (on-chain):** `submitVerdict(bytes32 inputHash, uint8 riskScore, uint8 regime, uint256 price)` on `AIOracle`, callable only by the runner. Each verdict stores `inputHash = keccak256(window)` — anyone can reconstruct the exact window from the `PriceEmitter` event history and re-run the model to check the score. No verdict is hardcoded; every score is computed from the live window.
- **Observed behaviour (Phase 2, on-chain):** a calm window scored **risk 16 / calm**; as a −52% crash entered the window, scores climbed monotonically 28 → 41 → 52 → … → **88–89 / crash-risk**; as the crash left the window during a volatile leg, scores decayed back to **52 / volatile**. Calm vs crash separation: **72 points**.

---

## Deployed contracts

All contracts were deployed during the event window from a dedicated testnet development wallet. Prices are quoted in USD cents (200000 = $2,000.00); the tracked mock asset is `0x0000000000000000000000000000000000001000`.

### Ethereum Sepolia (chain 11155111) — origin & AI layer

| Contract | Address | Deploy TX |
|---|---|---|
| OriginEmitter (Phase 1 skeleton) | `0x5135E5061eFC03639C365D697DBb7A5CA0Bc2f90` | `0xfd486ae7fc914e1ff24aa105cc23436658f39604739ff3a320c227d3e473b2c1` |
| CallbackRecorder #1 (Phase 1 destination) | `0x1555b4fEe6C125731e956e36B9e5DC2ca9B2F95c` | `0x2dad2179e436e3666d8ab586cd9aa28f0d02420a8aeab541909557e0d4ee2da9` |
| PriceEmitter (Phase 2, final) | `0xeD342ec1aEAC620143E20bed9C8068A134918019` | `0x87c8708520ed83c69b082c7010813a79068043f59d4ac5d6263c145caf1d87e4` |
| AIOracle (Phase 2) | `0xa09946e491bB94db2A8c02F12Cec1AA69f51CE92` | `0x47fd9e5f477e4b82154e82a2309d7284ce079124e8a65665bf4f96274c1dcdb7` |
| CallbackRecorder #3 (Phase 3 destination) | `0x8163af97465DeAA4Bdb9fd33563Dc35E17fE7fAc` | `0x22755bed45287edf917b712e317d136a3b51010713558e9dfadb9128ec955029` |

### Reactive Lasna (chain 5318007) — reactive layer

| Contract | Address | Deploy TX |
|---|---|---|
| SentinelReactive (Phase 1 skeleton) | `0x2a7855f146189b477A7b184aFF99a31A6b977918` | `0x86f37b4cd1939814662c752828dd6811b78eb143815ca7f38dfe1a043c57f434` |
| SentinelGuardian (Phase 3, destination: Sepolia) | `0x5135E5061eFC03639C365D697DBb7A5CA0Bc2f90` | `0xd28a65f3f5a9d6b2b3376a35032d8c474e94efe3d97854e1acfb89e8ebae8f33` |
| SentinelGuardian #4 (Phase 4, destination: Base Sepolia) | `0x39C0de948f401Fc8359ACC2F2ceF472F57426D6e` | `0x563c455abb4966dca9ed4c9b9e37a480680c12204e9372d198f8db4a98f523f8` |

### Base Sepolia (chain 84532) — action layer

| Contract | Address | Deploy TX |
|---|---|---|
| SentinelVault (Phase 4) | `0x2a7855f146189b477A7b184aFF99a31A6b977918` | `0xb0fada54ee9b868e6033c5acdc63ce2b10b31f685c734463694668e24c5aec30` |

**Address coincidences (not typos):** contract addresses derive from (deployer, nonce), and the same deployer hit the same nonce on different chains twice — the Lasna Phase 3 guardian shares its address with the Sepolia Phase 1 OriginEmitter (`0x5135…2f90`), and the Base Sepolia vault shares its address with the Lasna Phase 1 SentinelReactive (`0x2a78…7918`). Different chains, no role conflicts.

**Reactive infrastructure used:** Lasna system contract `0x8888888888888888888888888888888888888888`; Sepolia callback proxy `0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4`; Base Sepolia callback proxy `0x476F44b11F5C942c58f4c8E3d0300E5710743585`; official `reactive-lib-omni` v0.1.0.

**Diagnostic artifacts (not part of the final chains):** a test OriginEmitter at `0x01cE6f4eB729FD9A4F8E6d7003609C6be8eC5e5A` (Phase 1 tooling diagnosis) and the first PriceEmitter at `0x0A61cF1192720c3070F18bE4A69eBb880ba4D05B` (Phase 2 run interrupted by an environment restart; the scenario was re-run cleanly on the final emitter).

---

## Proof — the hash chains

### Phase 1 — the reactive loop itself (Sepolia → Lasna → Sepolia)

| Step | Chain | TX hash | Result |
|---|---|---|---|
| Origin event `ping(42)` | Sepolia | `0xc664144f1d6abd1c30be31e6222ee27d80487805a43b082d94f05bc7381d3112` | `Ping` emitted |
| Reactive reaction (Lasna block 8418814) | Lasna | `0x2b0de2ea5302bb397910164f9a936e6e234c32b375e67387e220b9b9f987cd56` | `ReactionRecorded` + `CallbackRequest` in the same TX |
| Callback executed (Sepolia block 12141156) | Sepolia | `0x14b0dd5f8666674aba6059b69e83a08580402978b9670b77e68dfe68e0b298a9` | `CallbackRecorded`, value 42 |

Final counters, independently re-read: `pingCount = 1`, `reactionCount = 1`, `callbackCount = 1`.

### Phase 2 — AI verdicts on-chain (Sepolia)

33 verdicts from one continuous scenario (16 calm prices → 16 crash prices, −52% → 16 volatile prices):

| Verdict | Window state | Risk | Regime | TX hash |
|---|---|---|---|---|
| #0 | calm, price 200330 | **16** | calm | `0x522788c48dcda23f5454d66b7bfa5c77202dbe02a47e8a2ca962f4bf890e906f` |
| #16 | crash complete, price 96000 | **88** | crash-risk | `0xdd9cd0fa328836acdfe48355ddd6fd20b80311f963b3c9b908b5b58e3e650fea` |
| #32 | volatile, price 97500 | **52** | volatile | `0xe9f77d680dbc37ceb2b560474c74a66804fcf273063398184c9c706592137009` |

### Phase 3 — the guardian fires only on confirmed danger (Sepolia → Lasna → Sepolia)

The Phase 3 guardian processed 48 prices + 48 verdicts across three legs:

- **Calm leg** (16 prices, verdicts up to risk 70, none crash-risk): **0 callbacks** — recorder `callbackCount` stayed 0.
- **Crash leg** (−52%): the first verdict satisfying both conditions — **risk 83 at price 140000 (−30.1% from the 200330 peak)** — fired exactly one protection callback. The 8 later crash verdicts (risk 86–89) were latched and produced no further callbacks.
- **Volatile/recovery leg:** a non-danger verdict reset the latch on-chain (`LatchReset`, Lasna block 8440871, TX `0xc5bd7f64f200be2b2de129fdd748733c06038db50c848e49ee17d4fb4bc3b690`); a shallow post-reset crash blip (risk 84 at 97000, only −3% from the re-anchored reference) did **not** refire.

| Step | Chain | TX hash |
|---|---|---|
| Triggering AI verdict (risk 83 @ 140000) | Sepolia | `0xd54cfcd35a0a46e2061400d2fc32cbad692a97d372d4734aad3f4b8c021d8259` |
| Guardian reaction (Lasna block 8440475) | Lasna | `0x5190d9c9292209f54c01cb3c51d8743b9d9a5c955c5422dd71dbfd2bfa20ad05` |
| Protection callback | Sepolia | `0x7f142c65ff6449087c467ce5a8150e7e3001ad5698fa45a3b9d052172b2b0ef7` |

Recorder #3 after the run: `callbackCount = 1`, `lastValue = 83`, `lastOriginTxHash = 0xd54cfcd35a0a46e2061400d2fc32cbad692a97d372d4734aad3f4b8c021d8259` (the triggering verdict TX). Guardian final state: `priceCount 48, verdictCount 48, protectionCount 1, dangerLatched false`. The untouched Phase 1 recorder still reads `callbackCount = 1` — a negative control.

### Phase 4 — the vault acts (Sepolia → Lasna → Base Sepolia) ★ headline proof

A fresh guardian instance (destination: Base Sepolia) watched a compact scenario: an 8-price calm prefix (verdicts 41, then 69×7 — all volatile, **0 callbacks**, vault untouched), then the full 16-price crash leg.

| Step | Chain | TX hash |
|---|---|---|
| Triggering AI verdict — risk **83** @ price **140000** (AIOracle verdict index 96) | Sepolia | `0x609e8f42701286612c00ea2d28b6c8fbed8bcdc677627946f1267e0cabc3e352` |
| Guardian #4 reaction (Lasna block 8442343) — `CallbackRequest` + `ProtectionTriggered(83, verdictTx)` in one TX | Lasna | `0xf2e837bb95f60a3e6d6e1d63a1294cef7d567e457d835c03b36ed6c45e8f8a7b` |
| Callback delivered via Base Sepolia callback proxy (block 59300567) | Base Sepolia | `0x50ce3b624014bd549989a51e323d64bc61f8671790e9325248e1f8b2dde48b57` |

**Vault state change executed by that callback:**

| Vault field | Before | After |
|---|---|---|
| `positionAtRisk` | 1,000,000 | **0** |
| `safeBalance` | 0 | **1,000,000** |
| `protectionCount` | 0 | **1** |
| `lastRiskScore` | — | **83** |
| `lastOriginTxHash` | — | `0x609e8f42701286612c00ea2d28b6c8fbed8bcdc677627946f1267e0cabc3e352` (the triggering verdict TX) |

The callback transaction's only log is the vault's `ProtectionExecuted(reactive = guardian #4, riskScore = 83, amountMoved = 1000000, originTxHash = triggering verdict TX)`. Nine subsequent crash verdicts (risk 86–89) were latched — no second callback. Guardian #4 final: `priceCount 24, verdictCount 24, protectionCount 1`.

Cross-confirmation: the Phase 3 guardian is subscribed to the same Sepolia streams, so it independently reacted to the same triggering verdict and fired its own single callback to the Sepolia recorder (TX `0x625a43df93212f8647ad1c92839ef663377c0274caa9f82e4c2c6130a938f8d2`) — two independent guardians, two destination chains, one AI verdict, one protection each.

Cumulative totals after Phase 4: `AIOracle.verdictCount = 105`, `PriceEmitter.updateCount = 120`. Foundry test suite: **21/21 passing** (5 skeleton loop + 5 Phase 2 + 4 guardian + 7 vault, including unauthorized-caller and low-risk rejection tests).

---

## Verify it yourself

You need [Foundry's](https://book.getfoundry.sh/) `cast`. RPC endpoints used throughout: Sepolia `https://ethereum-sepolia-rpc.publicnode.com`, Lasna `https://lasna-rpc.rnk.dev/`, Base Sepolia `https://sepolia.base.org`. (Lasna is also browsable on the Reactscan explorer; Sepolia and Base Sepolia on their usual Etherscan-family explorers.)

**The AI oracle (Sepolia):**

```bash
# total verdicts posted across all phases → 105
cast call 0xa09946e491bB94db2A8c02F12Cec1AA69f51CE92 "verdictCount()(uint256)" \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com

# the Phase 4 triggering verdict (index 96) → risk 83, regime 2 (crash-risk), price 140000
cast call 0xa09946e491bB94db2A8c02F12Cec1AA69f51CE92 "getVerdict(uint256)" 96 \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com

# first verdict ever (index 0) → risk 16, regime 0 (calm), price 200330
cast call 0xa09946e491bB94db2A8c02F12Cec1AA69f51CE92 "getVerdict(uint256)" 0 \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com

# total price events emitted → 120
cast call 0xeD342ec1aEAC620143E20bed9C8068A134918019 "updateCount()(uint256)" \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com
```

**The Phase 4 guardian (Lasna):**

```bash
cast call 0x39C0de948f401Fc8359ACC2F2ceF472F57426D6e "priceCount()(uint256)"    --rpc-url https://lasna-rpc.rnk.dev/   # → 24
cast call 0x39C0de948f401Fc8359ACC2F2ceF472F57426D6e "verdictCount()(uint256)"  --rpc-url https://lasna-rpc.rnk.dev/   # → 24
cast call 0x39C0de948f401Fc8359ACC2F2ceF472F57426D6e "protectionCount()(uint256)" --rpc-url https://lasna-rpc.rnk.dev/ # → 1
```

**The vault (Base Sepolia) — the protection, executed:**

```bash
cast call 0x2a7855f146189b477A7b184aFF99a31A6b977918 "positionAtRisk()(uint256)"  --rpc-url https://sepolia.base.org  # → 0
cast call 0x2a7855f146189b477A7b184aFF99a31A6b977918 "safeBalance()(uint256)"     --rpc-url https://sepolia.base.org  # → 1000000
cast call 0x2a7855f146189b477A7b184aFF99a31A6b977918 "protectionCount()(uint256)" --rpc-url https://sepolia.base.org  # → 1
cast call 0x2a7855f146189b477A7b184aFF99a31A6b977918 "lastRiskScore()(uint256)"   --rpc-url https://sepolia.base.org  # → 83
cast call 0x2a7855f146189b477A7b184aFF99a31A6b977918 "lastOriginTxHash()(bytes32)" --rpc-url https://sepolia.base.org # → 0x609e8f42…e352 (triggering verdict TX)
```

**Phase 3 guardian + recorder (Lasna / Sepolia):**

```bash
cast call 0x5135E5061eFC03639C365D697DBb7A5CA0Bc2f90 "protectionCount()(uint256)" --rpc-url https://lasna-rpc.rnk.dev/  # → 2 (its Phase 3 protection + 1 co-reaction during Phase 4, matching recorder #3's callbackCount of 2 below)
cast call 0x8163af97465DeAA4Bdb9fd33563Dc35E17fE7fAc "callbackCount()(uint256)" \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com  # → 2 (same reason)
cast call 0x8163af97465DeAA4Bdb9fd33563Dc35E17fE7fAc "lastValue()(uint256)" \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com  # → 83
```

Note on the two `→ 2` values: the Phase 3 guardian remains subscribed to the live Sepolia streams, so during the Phase 4 scenario it processed the same prices/verdicts and fired one additional protection to its own recorder — its counters advanced from the Phase 3 finals (48/48/1) to 72/72/2. The Phase 3 hash chain above is the historical record of its first protection.

**Phase 1 skeleton (Sepolia / Lasna):**

```bash
cast call 0x1555b4fEe6C125731e956e36B9e5DC2ca9B2F95c "callbackCount()(uint256)" \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com  # → 1 (untouched since Phase 1)
```

---

## Reproduce it

### Repository layout

```
sentinel/
├── src/
│   ├── OriginEmitter.sol      # Phase 1 skeleton origin (Ping events)
│   ├── SentinelReactive.sol   # Phase 1 skeleton reactive contract
│   ├── CallbackRecorder.sol   # Phase 1/3 callback destination (records)
│   ├── PriceEmitter.sol       # price source — PriceUpdated events
│   ├── AIOracle.sol           # on-chain store for AI verdicts
│   ├── SentinelGuardian.sol   # the two-signal reactive guardian (Phases 3–4)
│   └── SentinelVault.sol      # Base Sepolia vault that executes protection
├── test/                      # Foundry tests — 21 total, all passing
│   ├── SkeletonLoop.t.sol  ·  Phase2.t.sol  ·  Guardian.t.sol  ·  Vault.t.sol
├── ai/
│   ├── features.py            # 8 log-return features
│   ├── model.py               # pure-numpy MLP (regime softmax + risk sigmoid)
│   ├── train.py               # synthetic data generator + training
│   ├── weights.npz            # trained weights + feature standardization stats
│   ├── train_report.json      # held-out accuracy / MAE
│   ├── runner.py              # polls PriceUpdated → inference → submitVerdict
│   ├── emit_prices.py         # deterministic price-scenario emitter
│   └── runner_state.json      # persistent runner checkpoints + verdict TX log
├── run_phase1.sh … run_phase4.sh   # end-to-end orchestrators per phase
└── foundry.toml               # solc 0.8.38, reactive-lib-omni v0.1.0
```

### Dependencies

The contracts build against two libraries, expected under `lib/` (see the `foundry.toml` remappings):
- `forge-std` — install with `forge install foundry-rs/forge-std`
- `reactive-lib-omni` **v0.1.0** (the official Reactive Omni library) — place it at `lib/reactive-lib-omni` so the `@reactive/` remapping resolves.

The development copy used for the on-chain runs vendors both under `lib/`; a fresh clone of this repo needs the two installs above before `forge test`.

### Run the tests

```bash
forge test        # 21/21 — skeleton loop, oracle, guardian rule + latch, vault action + auth
```

The guardian tests replay the full simulated verdict arc step-for-step (including the post-reset shallow blip that must *not* fire — the case that forced the v2 reference-price re-anchoring described in the phase notes). The vault tests cover: valid callback executes the full protection; wrong injected sender → `CallbackNotAuthorized`; non-proxy caller → `NotAuthorized`; low risk score (52) → rejected; a second callback moves 0.

### Run the AI

```bash
cd ai
python3 train.py     # regenerates weights.npz + train_report.json (seed 42, deterministic)
python3 runner.py    # polls PriceEmitter events, posts a verdict per new price once the 16-price window is full
```

The runner is stateless across restarts in the ways that matter: it checkpoints the processed event cursor and every submitted verdict TX in `runner_state.json`, so it never double-posts. Retraining with seed 42 reproduces the exact weights used for all on-chain verdicts — and because every verdict carries `keccak256(window)`, any verdict can be audited by reconstructing its window from `PriceEmitter` history and re-running inference.

### Full loop

`run_phase1.sh` … `run_phase4.sh` replay each phase end-to-end (deploy → emit → infer → react → callback) against the public testnets; each phase's script has a `verify` mode that re-reads every counter cited in this README.

---

## Design decisions worth knowing

- **The callback sender is bound immutably at construction** (`AbstractCallback._CALLBACK_SENDER`). A destination contract can therefore never be re-pointed at a new guardian — Phase 3 needed a fresh recorder instance for the new guardian, and Phase 4 **predicted the guardian's Lasna address from the deployer nonce** (`cast compute-address`), deployed the vault bound to that prediction first, then deployed the guardian into exactly that address. The binding is verifiable on-chain: `vault._CALLBACK_SENDER() == guardian #4`.
- **The latch + reference re-anchoring (v2)** exists because v1 failed its own full-arc test: with a stale pre-crash peak, a shallow −3% post-recovery blip looked like −51.6% and fired a second, wrong callback. On latch reset, the reference price re-anchors to the current price, so each danger episode is measured from where the previous one ended. v2 is what is deployed.
- **Reactive contracts pay for their own reactions** from their lREACT balance (≈0.0134 lREACT per reaction, measured). A dual subscription (prices + verdicts) means two reactions per step — operating budget scales with event volume, not with callbacks.
- **Cross-subscription ordering is not strict** (observed in Phases 3–4): price-stream reactions can advance `lastPrice` before the verdict reaction that triggered on an earlier price executes. The firing rule is deliberately monotone under this reordering — the verdict is the deciding signal, and the price condition only becomes *more* satisfied as a crash continues.
- **Base Sepolia funding:** no account-free faucet could be completed from a headless environment, so the dev wallet was funded through the **official L1→L2 bridge** — a 0.05 SepETH deposit via `L1StandardBridge` `0xfd0Bf71F60660E2f608ed56e1659C450eB113120` (TX `0xa0b19fdd72e15f8bb749f961ee8e7b62ae32530a202915076c079f9a7789a923`), credited in full on Base Sepolia. Testnet funds only; no accounts created, nothing purchased.

---

## Honest limitations

- **Testnet demonstration.** All contracts run on Ethereum Sepolia, Reactive Lasna, and Base Sepolia with valueless testnet tokens. Nothing here has touched mainnet or real funds.
- **The vault position is a mock.** `positionAtRisk`/`safeBalance` are internal accounting units (seeded at 1,000,000 units = a $10,000 mock position at 1 unit = 1 cent) — the callback genuinely executes the state transition on-chain, but no real asset is swapped or withdrawn. A production version would wire the same callback to a real position manager (close the position, swap to a stable asset, or post collateral).
- **The price source is our own emitter.** `PriceEmitter` stands in for a real DEX pool / oracle feed so the demo scenarios are deterministic and reproducible. The guardian and the AI consume only the event interface, so a real feed emitting the same event shape can be substituted — but that integration is not built.
- **The AI is trained on synthetic data.** The MLP learns regime shapes from generated random walks, not from historical market data; its 100% held-out accuracy is measured against held-out *synthetic* windows from the same generator family. It demonstrates the architecture and the on-chain verdict loop, not production-grade market prediction.
- **The AI runner is a trusted off-chain component.** Only the runner address can post verdicts to `AIOracle`. The `inputHash` commitment makes every verdict auditable after the fact, but the oracle does not (and cannot) verify inference on-chain. Decentralizing or proving inference is future work.
- **One asset, one position, fixed thresholds.** The risk threshold (80), the price-drop condition (10%), and the latch rule are calibrated constants for this demo, not a risk-management product.

---

## Build notes

- Solidity 0.8.38, Foundry 1.9.0, official `reactive-lib-omni` v0.1.0; Python 3.12 + numpy for the AI (no other dependencies, no API keys).
- Built in four verified phases — skeleton loop → AI verdicts on-chain → two-signal guardian with latch → acting vault on Base Sepolia — each closed only after its counters and hash chains were re-read independently with `cast call`.
- **Team:** solo build by Masboy (independent developer), with an AI agent assisting development. Track rule honoured: the AI in the *product* is the numpy MLP in the loop above — not the coding assistance.

*Event: Reactive Omni Buildathon, DoraHacks, Nov 5 – Dec 5, 2026. Track prize: $1,000 for first place, paid in REACT.*
