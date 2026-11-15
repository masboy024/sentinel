# SENTINEL — Laporan Fase 2 (AI di Dalam Sistem, Verdict On-Chain)

Tanggal: Senin, 16 Nov 2026 (WITA). Acuan rencana: `PREP.md` §6 (Fase 2/3 versi PREP digabung: kontrak inti + otak AI). Lingkungan: testnet saja (Ethereum Sepolia), nol biaya riil, wallet dev khusus testnet (bukan wallet user).

## Status: LOLOS — AI LOKAL BERJALAN DI DALAM SISTEM, 33 VERDICT TERCATAT ON-CHAIN ✅

Sebuah MLP numpy lokal (tanpa kunci API eksternal) membaca event harga on-chain, menilai rezim pasar, dan memposting verdict-nya ke kontrak `AIOracle` di Sepolia. Bukti end-to-end: jendela harga **calm** menghasilkan verdict **risk 16 / regime calm**; jendela **crash** (−52%) menghasilkan **risk 88–89 / regime crash-risk**; jendela **volatile** (wave 2) menghasilkan **risk 52 / regime volatile**. Semua verdict diverifikasi ulang secara independen via `cast call` (verdictCount, getVerdict, latestVerdict). Log mentah: `phase2-run-output.txt`; status runner: `sentinel/ai/runner_state.json`.

**Gerbang Fase 2 LULUS.** Fase 3 (kontrak reaktif Lasna menggabungkan sinyal harga + verdict AI → callback proteksi) bisa dimulai dari komponen yang terbukti ini.

## Arsitektur Fase 2

```
PriceEmitter (Sepolia)                AI runner (lokal, Python+numpy)          AIOracle (Sepolia)
─────────────────────                 ──────────────────────────────           ──────────────────
publishPrice(p) ──PriceUpdated──▶  poll eth_getLogs ─▶ sliding window 16
                                   ─▶ fitur (8, dari log-return)
                                   ─▶ MLP: regime softmax + risk sigmoid
                                   ─▶ inputHash = keccak256(window)
                                   ──submitVerdict(hash, risk, regime, price)──▶  tersimpan + event
                                                                                    VerdictPosted
```

- **PriceEmitter** (`sentinel/src/PriceEmitter.sol`) — sumber event harga: `publishPrice(uint256)` memancarkan `PriceUpdated(address indexed asset, uint256 price, uint256 timestamp)` (topic0 `0xb556fac5…3e0c0`). Peran MockPool versi minimal; di Fase 3 kontrak reaktif Lasna subscribe ke signature event yang sama.
- **AIOracle** (`sentinel/src/AIOracle.sol`) — `submitVerdict(bytes32 inputHash, uint8 riskScore, uint8 regime, uint256 price)` hanya bisa dipanggil alamat `runner` (wallet dev). Setiap verdict menyimpan hash jendela input, skor 0–100, kode rezim (0 calm, 1 volatile, 2 crash-risk), harga terakhir, dan `block.timestamp`. Getter publik: `verdictCount()`, `getVerdict(i)`, `latestVerdict()`, `runner()`. Event `VerdictPosted` adalah titik subscribe Fase 3.
- **AI** (`sentinel/ai/`) — `features.py` (ekstraksi fitur), `model.py` (MLP numpy murni), `train.py` (generator data sintetis + pelatihan), `runner.py` (poll event → inferensi → posting verdict via `cast send`; state persisten di `runner_state.json` agar tidak dobel), `emit_prices.py` (pengemisi skenario harga deterministik), `wallet.py` (parser wallet dev; kunci tidak pernah dicetak).

## Kontrak Ter-deploy (Ethereum Sepolia, chain 11155111)

| Kontrak | Alamat | TX Deploy |
|---|---|---|
| PriceEmitter (final, seri bersih) | `0xeD342ec1aEAC620143E20bed9C8068A134918019` | `0x87c8708520ed83c69b082c7010813a79068043f59d4ac5d6263c145caf1d87e4` |
| AIOracle (runner = wallet dev) | `0xa09946e491bB94db2A8c02F12Cec1AA69f51CE92` | `0x47fd9e5f477e4b82154e82a2309d7284ce079124e8a65665bf4f96274c1dcdb7` |

Artefak diagnostik (BUKAN bagian rantai final): PriceEmitter pertama `0x0A61cF1192720c3070F18bE4A69eBb880ba4D05B` (TX `0x648c75e03ceaa9c7ef2f707f8e61ab4f9d68038c93729b6d1646690372712a08`) — seri calm-nya terpotong restart runtime (lihat §Catatan Kegagalan), jadi skenario diulang bersih di emitter kedua. Aset mock yang dilacak: `0x0000000000000000000000000000000000001000`. Harga dalam sen USD (200000 = $2.000,00).

## Cara AI Bekerja

**Jendela & cold start.** Runner memelihara jendela geser 16 harga terakhir dari event `PriceUpdated`. Tidak ada verdict sebelum jendela penuh (cold start = 15 event pemanasan, verdict pertama tepat di harga ke-16) — teramati persis seperti itu di run on-chain.

**Fitur (8, semuanya dari log-return jendela — bebas skala):** `cum_return` (log harga akhir/awal), `mean_return`, `volatility` (std return), `max_drawdown`, `last_return`, `worst_return`, `down_fraction` (porsi langkah turun), `log_range` (log max/min).

**Model.** MLP multi-task numpy murni: input 8 → hidden 24 (tanh) → dua head: softmax 3 kelas rezim + sigmoid skor risiko (×100). Loss = cross-entropy rezim + MSE risiko; Adam, full-batch, 400 epoch, seed deterministik 42. Fitur distandardisasi dengan statistik training yang disimpan bersama bobot (`sentinel/ai/weights.npz`), sehingga inferensi runner mereproduksi preprocessing yang sama persis.

**Data latih.** 3.000 jendela sintetis (1.000/rezim) berupa geometric random walk berlabel: calm (σ 0,12%/langkah, tanpa drift), volatile (σ 2%/langkah, tanpa drift), crash-risk (drift −3,8%/langkah, σ 1,6%). Target risiko per rezim: calm 5–30, volatile 40–70, crash 78–99. Model tidak pernah melihat parameter generator — rezim harus disimpulkan dari fitur jendela.

**Hasil pelatihan** (`sentinel/ai/train_report.json`): akurasi rezim held-out (900 jendela) **100%** (per rezim 100%/100%/100%), MAE skor risiko **6,56**. Sanity offline atas jendela demo sebelum gas dibelanjakan: calm → risk 16,4/calm; crash → risk 87,5/crash-risk — cocok dengan hasil on-chain (16 dan 88).

**Kejujuran model.** Tidak ada verdict hardcode: setiap skor dihitung dari harga jendela saat itu. Komitmen `inputHash = keccak256(window sebagai uint256[])` di setiap verdict membuat siapa pun bisa merekonstruksi jendela dari riwayat event PriceEmitter dan menjalankan ulang model untuk memeriksa skornya.

## Bukti On-Chain — Busur Verdict (semua di AIOracle)

Skenario: 16 harga calm (±0,15% di sekitar $2.000) → 16 harga crash (turun ke $960, −52%) → 16 harga volatile (chop ±3% menyamping). Runner memposting satu verdict per harga baru setelah jendela penuh: **33 verdict**.

| # | Harga terakhir | Risk | Rezim | TX submitVerdict |
|---|---|---|---|---|
| 0 | 200330 (calm penuh) | **16** | calm | `0x522788c48dcda23f5454d66b7bfa5c77202dbe02a47e8a2ca962f4bf890e906f` |
| 1 | 196000 | 28 | calm | `0x1a11e49674fe380a8935e4144f8a43ec43f1ef267ff8a5f3c2feca350052287c` |
| 2 | 190500 | 41 | volatile | `0x62baacb161440dd1bf3a14f7cedb12f8849fb5c6cf26461a80623cf85a208aff` |
| 3 | 184000 | 52 | volatile | `0xc1df18dedff8da10e290636b7f1d3289a0ce026cf9c6eefe774a8c854dc64407` |
| 4 | 176500 | 59 | volatile | `0xd029c8588b76ac8c9a5390d3450a7fa42eaacd639c711fa59d6ce3506cb428ba` |
| 5 | 168000 | 63 | volatile | `0xaa90220c3dbe1d730e34624563e920fa945476e31b25039fc2b76ac5f0af47a1` |
| 6 | 159000 | 71 | volatile | `0x5ef24721660af759faa9ba7c50a518d16affb1d600056d262b16ab46492d7c1e` |
| 7 | 149500 | 77 | volatile | `0xc5030b22179d0d2c0680ea5e72ce1a8e67e16971d090058a5dc96d3b552c351d` |
| 8 | 140000 | 83 | crash-risk | `0x27b5daf07b1d8b180b19480c91ab777c548cc02e9f1342214868de359a94b2e8` |
| 9 | 131000 | 86 | crash-risk | `0x19208638369486283b837715bf62dbda80eadb0bf7ceda4ce54fc2333f67cc7a` |
| 10 | 123500 | 87 | crash-risk | `0x8099aa687e56042f7218144d157a7620a7534962136f8c8cd7df2249a0b2b2a4` |
| 11 | 117000 | 88 | crash-risk | `0x1ba5614c5a0f647a16ab1092cb0be094a20ef7d064c70ab731179b6a62d3f66a` |
| 12 | 111500 | 89 | crash-risk | `0x5854d5bd0f0b14ecfcc8b9261001e109f728290cd22863567ac0d593ba826d01` |
| 13 | 107000 | 88 | crash-risk | `0xdac300ce810bc723bdd9daa99dbcc98cbe5d1d8626464a5566c6da0c33f2c243` |
| 14 | 103000 | 88 | crash-risk | `0xd852c9c59b952e35a898496b8c73daf5005416f5d2fbe92e45e97f9388387eee` |
| 15 | 99500 | 88 | crash-risk | `0x7ded2069a19924fe860fc24355c98fdac630ffd26e3ba2d805fc8eca489ee4e6` |
| 16 | 96000 (crash penuh) | **88** | crash-risk | `0xdd9cd0fa328836acdfe48355ddd6fd20b80311f963b3c9b908b5b58e3e650fea` |
| 17–32 | volatile (berakhir 97500) | 87 → **52** | crash-risk → **volatile** | verdict terakhir `0xe9f77d680dbc37ceb2b560474c74a66804fcf273063398184c9c706592137009`; lengkapnya di `phase2-run-output.txt` §WAVE-2 & `runner_state.json` |

**Angka kunci:** calm **16** vs crash **88** — selisih **72 poin**, persis tuntutan gerbang Fase 2 (crash-risk harus material lebih tinggi dari calm). Busurnya juga berperilaku benar secara kualitatif: risiko naik monoton saat crash masuk jendela, rezim berpindah calm → volatile → crash-risk, lalu membusuk kembali ke volatile (risk 52, probabilitas rezim 1,0) saat harga crash keluar dari jendela pada leg volatile. Busur leg volatile on-chain **identik langkah-per-langkah dengan simulasi offline** yang dijalankan sebelum emisi (87, 88, 87, 88, 84, 84, 77, 74, 61, 61, 54, 55, 50, 52, 50, 52) — bukti reproduktibilitas model yang deterministik.

TX emisi harga: 32 TX `publishPrice` untuk calm+crash di emitter final dan 16 TX volatile — daftar lengkap per harga ada di `phase2-run-output.txt`.

## Verifikasi (dijalankan ulang secara independen setelah run)

```
cast call AIOracle verdictCount()            → 33
cast call AIOracle getVerdict(0)             → inputHash 0xc8d0efe6…43c, risk 16, regime 0, price 200330
cast call AIOracle getVerdict(16)            → inputHash 0xa92f16ad…066, risk 88, regime 2, price 96000
cast call AIOracle getVerdict(32)            → inputHash 0x1f2b133b…713, risk 52, regime 1, price 97500
cast call AIOracle latestVerdict()           → = getVerdict(32): risk 52, regime 1 (volatile)
cast call PriceEmitter#2 updateCount()       → 48
cast call AIOracle runner()                  → 0x7eCbaa4fcCA36eBA9860C15d12e21929CAa0d53D (wallet dev)
forge test                                   → 10/10 lulus (5 Fase 1 + 5 Fase 2)
```

Catatan verifikasi: pembacaan `latestVerdict()` pertama sesaat setelah run sempat menunjukkan verdict ke-15 (harga 99500) karena node RPC publik yang load-balanced tertinggal satu blok; pembacaan ulang menunjukkan verdict ke-16 dengan benar. Bukan inkonsistensi kontrak — artefak konsistensi-akhir RPC publik.

## Saldo Akhir

| Pemilik | Chain | Saldo |
|---|---|---|
| Wallet dev `0x7eCbaa4fcCA36eBA9860C15d12e21929CAa0d53D` | Ethereum Sepolia | 0,697258907752394935 SepETH (total belanja Fase 2 hanya ±0,00023 ETH untuk ±85 TX) |
| Wallet dev | Reactive Lasna | 3,1485 lREACT (tidak tersentuh di Fase 2) |

## Gelombang Bangun & Revisi (kebersihan submission)

- **Gelombang 1:** kontrak + test Foundry (10/10), modul AI (`features`/`model`/`train`), pelatihan + sanity offline, `runner.py` + `emit_prices.py`, orchestrator `run_phase2.sh`, lalu uji end-to-end on-chain pertama.
- **Revisi nyata setelah uji pertama (gelombang 2):**
  1. `emit_prices.py` + `runner.py`: `cast send` dibungkus helper dengan **retry 3× + backoff** dan **pelaporan error yang disanitasi** (hanya stderr cast; daftar argumen — yang memuat kunci privat — tidak pernah lagi digaungkan Python). Pemicu: satu send gagal transient di tengah emisi dan traceback Python sempat menulis kunci dev testnet ke log lokal (sudah diskrub dari `phase2-run-output.txt`, 8 kemunculan; lihat §Catatan Kegagalan).
  2. `runner.py`: `fetch_price_events` dibuat toleran terhadap balapan head RPC publik (clamp range ke head segar + retry) — pemicu: error `block range extends beyond current head block` dari node load-balanced.
  3. `emit_prices.py`: opsi `--skip N` untuk melanjutkan emisi yang terputus dari checkpoint terverifikasi, bukan mengulang dari nol.
  4. **Skenario ketiga `volatile`** ditambahkan (`train.py` `DEMO_VOLATILE`, `emit_prices.py`, `run_phase2.sh` langkah 3b) dan dibuktikan on-chain: rezim 1 kini punya bukti live, bukan hanya calm vs crash.

## Catatan Kegagalan (jujur)

1. **Restart runtime memutus run pertama.** Proses latar `run_phase2.sh` terputus oleh restart runtime saat emisi calm baru mencapai 5/16 harga (terverifikasi: `updateCount = 5`, `lastPrice = 200150` = harga calm ke-5). Pemulihan dilakukan dari checkpoint on-chain, bukan mengulang deploy.
2. **Satu `cast send` gagal transient** pada harga calm ke-11 (200140) di upaya pemulihan pertama; traceback `CalledProcessError` dari Python **mencetak daftar argumen cast termasuk kunci privat wallet dev** ke log proses dan `phase2-run-output.txt`. Tindakan: run dihentikan, rantai emisi dinilai ulang (10 calm + 1 crash sudah terlanjur masuk emitter pertama), log proyek **diskrub** (8 kemunculan kunci diganti `0x<REDACTED-KEY>`), kode diperbaiki (revisi no. 1 di atas), dan skenario diulang bersih di PriceEmitter kedua. Kunci yang bocor adalah kunci **wallet dev testnet khusus** (dana testnet tak bernilai; tidak terhubung ke wallet user) — tetapi dicatat apa adanya: untuk Fase 3+, pola aman yang baru (error tersanitasi) sudah menjadi default, dan rotasi wallet dev layak dipertimbangkan sebelum submission final.
3. **RPC publik load-balanced tidak konsisten sesaat** — tiga gejala dari akar yang sama: `replacement transaction underpriced`, `nonce too low`, dan range getLogs melampaui head. Semuanya teratasi oleh retry + clamp; tidak ada TX dobel yang terposting (verdictCount dan updateCount selalu cocok dengan hitungan skenario).
4. **Emitter pertama menjadi artefak diagnostik** (11 harga campuran) — didokumentasikan di atas, mengikuti preseden Fase 1 (OriginEmitter uji ekstra).

## Yang Harus Dilakukan Fase 3 (titik masuk persis)

1. **Kontrak reaktif baru di Lasna** (perluas pola `SentinelReactive` Fase 1): subscribe ke DUA event Sepolia — `PriceUpdated` dari PriceEmitter final `0xeD342ec1aEAC620143E20bed9C8068A134918019` dan `VerdictPosted` dari AIOracle `0xa09946e491bB94db2A8c02F12Cec1AA69f51CE92`. Simpan state terakhir: harga terbaru + (riskScore, regime, timestamp verdict).
2. **Aturan gabungan (inti Fase 3):** minta callback proteksi HANYA bila bahaya nyata terkonfirmasi dua sinyal — mis. verdict terbaru `regime == 2 && riskScore >= 80` DAN harga terakhir sudah turun ≥ ambang (mis. ≥10% dari harga referensi saat verdict calm terakhir / jendela berjalan). Verdict volatile (regime 1) atau risk < 80 TIDAK boleh menembak callback — busur Fase 2 memberi data kalibrasi: calm 16, volatile ±52, crash 83–89, jadi ambang 80 memisahkan dengan bersih.
3. **Cooldown & anti-spam:** satu callback per episode bahaya (latch sampai verdict kembali < ambang aman, mis. risk < 60), agar 17 verdict tidak menjadi 17 callback; gas callback dibayar dari saldo lREACT kontrak (pola Fase 1: isi ±2 lREACT saat deploy).
4. **Destination:** callback ke `CallbackRecorder` Fase 1 `0x1555b4fEe6C125731e956e36B9e5DC2ca9B2F95c` sebagai bukti rantai dulu; kontrak Vault sungguhan di Base Sepolia adalah Fase 4 (perhatikan aturan timestamp Base Sepolia dari PREP §1).
5. **Uji Fase 3:** putar ulang tiga skenario Fase 2 (runner + weights yang sama persis) dan buktikan: callback HANYA terpicu pada leg crash, tidak pada calm/volatile; kumpulkan rantai hash event origin → verdict → reaksi Lasna → callback.
6. Runner Fase 2 tetap menjadi komponen AI yang berjalan — Fase 3 tidak mengubah model; bila ambang perlu kalibrasi, ubah di kontrak reaktif, bukan di model.
