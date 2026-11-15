# SENTINEL — Laporan Fase 3 (Otak Reaktif: Proteksi Hanya Saat Bahaya Terkonfirmasi)

Tanggal: Senin, 16 Nov 2026 (WITA). Acuan: `PHASE2.md` §"Yang Harus Dilakukan Fase 3".
Lingkungan: testnet saja (Ethereum Sepolia + Reactive Lasna), nol biaya riil, wallet dev khusus testnet (bukan wallet user).

## Status: LOLOS — PROTEKSI HANYA MENEMBAK SAAT BAHAYA TERKONFIRMASI, TEPAT SATU KALI ✅

Guardian Lasna memproses **48 event harga + 48 verdict** dari aliran Sepolia yang sama. Leg **calm**: 0 callback. Leg **crash**: tepat **1 callback proteksi** (terpicu verdict risk 83 @ harga 140000, −30,1% dari puncak), tercatat di CallbackRecorder Sepolia dengan `lastValue = 83` dan `lastOriginTxHash` = TX verdict pemicu. Leg **volatile/recovery**: latch ter-reset oleh verdict non-bahaya (event `LatchReset` on-chain), blip crash pasca-reset (risk 84 @ 97000) TIDAK menembak lagi, total tetap 1 callback. Semua angka diverifikasi ulang independen via `cast call` setelah run; `forge test` 14/14. Log mentah: `phase3-run-output.txt`; state runner: `sentinel/ai/runner_state.json` (81 verdict kumulatif).

**Gerbang Fase 3 LULUS.** Fase 4 (Vault sungguhan di Base Sepolia sebagai destination) bisa dimulai dari guardian yang terbukti ini.

## Desain

Kontrak reaktif baru **`SentinelGuardian`** (`sentinel/src/SentinelGuardian.sol`) di Lasna menggabungkan DUA sinyal Sepolia yang sudah terbukti di Fase 2 — ia subscribe ke keduanya sekaligus:

| Sinyal | Sumber | Event | topic0 |
|---|---|---|---|
| Harga mentah | PriceEmitter `0xeD342ec1aEAC620143E20bed9C8068A134918019` | `PriceUpdated(address,uint256,uint256)` | `0xb556fac5…3e0c0` |
| Verdict AI | AIOracle `0xa09946e491bB94db2A8c02F12Cec1AA69f51CE92` | `VerdictPosted(uint256,bytes32,uint8,uint8,uint256,uint256)` | `0x4f036d86…b3825` (diverifikasi dari log on-chain asli) |

**State gabungan:** `lastPrice` + `referencePrice` (puncak berjalan dari aliran harga), `lastRiskScore`/`lastRegime`/`lastVerdictPrice`/`lastVerdictTxHash` (verdict AI terakhir), counter `priceCount`/`verdictCount`/`protectionCount`, dan latch `dangerLatched`.

**Aturan keputusan (inti Fase 3).** Callback proteksi diminta HANYA bila bahaya terkonfirmasi dua sinyal sekaligus, dievaluasi saat verdict tiba:
- verdict terbaru `regime == 2` (crash-risk) **dan** `riskScore >= 80` — kalibrasi Fase 2: calm 16, volatile ±52, crash 83–89, jadi ambang 80 memisahkan dengan bersih; **dan**
- kondisi harga dari aliran harga: `lastPrice` sudah turun **≥ 10%** dari `referencePrice` (puncak sejak reset terakhir).

Verdict calm/volatile, atau verdict crash tanpa penurunan harga yang cukup, TIDAK pernah menembak callback (keduanya dibuktikan di test lokal dan on-chain).

**Latch/cooldown.** Satu episode bahaya = tepat SATU callback. Latch terpasang saat callback diminta dan hanya reset setelah verdict non-bahaya berikutnya teramati (`regime != 2` atau `risk < 80`). Saat reset, `referencePrice` **di-anchor ulang** ke `lastPrice` — episode baru diukur dari level harga saat episode lama dinyatakan berakhir (lihat §Revisi: tanpa ini, blip crash dangkal pasca-recovery menembak callback kedua).

**Payload callback.** `recordCallback(address, uint256 value, uint256 originTxHash)` dengan `value` = skor risiko verdict pemicu dan `originTxHash` = hash TX verdict pemicu — recorder menyimpan persis mengapa proteksi menembak dan verdict mana yang menyebabkannya.

**AI tidak diubah.** Runner, model, dan weights Fase 2 dipakai persis (`sentinel/ai/runner.py`, `weights.npz`); yang berubah hanya kontrak reaktif. Sebelum gas dibelanjakan, seluruh busur verdict Fase 3 disimulasikan offline dari state runner yang tersimpan — prediksi: leg calm menghasilkan verdict volatile 41–70 lalu calm 16; leg crash mereproduksi persis verdict Fase 2 #1–#16 (verdict bahaya pertama: harga 140000, risk 83); leg volatile meluruh 87→52 dengan satu blip crash (84 di harga 97000) setelah latch reset.

## Catatan Destination (penting, jujur)

Destination Fase 3 adalah kontrak `CallbackRecorder` Fase 1 — **tetapi instance baru** di Sepolia (`0x8163af97465DeAA4Bdb9fd33563Dc35E17fE7fAc`), bukan instance Fase 1 `0x1555b4fEe6C125731e956e36B9e5DC2ca9B2F95c`. Alasannya teknis dan terverifikasi on-chain: `AbstractCallback._CALLBACK_SENDER` bersifat `immutable` dan instance Fase 1 terikat ke kontrak reaktif Fase 1 (`_CALLBACK_SENDER() = 0x2a7855…7918`); callback dari guardian baru akan selalu revert `CallbackNotAuthorized` di instance lama. Jadi instance baru dari kontrak yang sama persis dideploy dengan sender = guardian Fase 3 — pola yang sama seperti test Fase 1. Instance Fase 1 tidak disentuh (callbackCount-nya tetap 1 sebagai kontrol negatif tambahan). Vault sungguhan di Base Sepolia tetap Fase 4.

## Kontrak Ter-deploy

| Kontrak | Chain | Alamat | TX Deploy |
|---|---|---|---|
| SentinelGuardian (modal 2 lREACT) | Lasna (5318007) | `0x5135E5061eFC03639C365D697DBb7A5CA0Bc2f90` | `0xd28a65f3f5a9d6b2b3376a35032d8c474e94efe3d97854e1acfb89e8ebae8f33` |
| CallbackRecorder #3 (modal 0,02 SepETH) | Sepolia (11155111) | `0x8163af97465DeAA4Bdb9fd33563Dc35E17fE7fAc` | `0x22755bed45287edf917b712e317d136a3b51010713558e9dfadb9128ec955029` |
| setRecipient(Recorder#3) di guardian | Lasna | — | `0x0ccd807124ac720e49eee60f29a3baee02809cca2e48868d3eecfa921e1f588e` |

Kebetulan yang perlu dicatat agar tidak membingungkan pembaca: alamat guardian di Lasna sama persis dengan alamat OriginEmitter Fase 1 di Sepolia (`0x5135…2f90`) — alamat kontrak diturunkan dari (deployer, nonce), dan nonce wallet dev di Lasna saat deploy guardian sama dengan nonce-nya di Sepolia saat deploy OriginEmitter. Beda chain, tidak ada konflik peran.

Baseline sebelum emisi: guardian priceCount/verdictCount/protectionCount = 0/0/0, recorder#3 callbackCount = 0, recorder#1 callbackCount = 1, AIOracle verdictCount = 33, PriceEmitter updateCount = 48.

## Revisi Berdasarkan Perilaku Teramati (tahapan bangun)

1. **v1** — kontrak ditulis dengan `referencePrice` sebagai puncak berjalan yang tidak pernah di-anchor ulang. Test busur penuh lokal (`test/Guardian.t.sol`, mereplikasi arc simulasi offline langkah demi langkah) **GAGAL** persis di leg volatile: `post-reset blip must not fire: 2 != 1` — setelah latch reset di verdict volatile (84 @ 100000), verdict crash berikutnya (84 @ 97000) masih terlihat sebagai −51,6% dari puncak pra-crash 200330, sehingga callback kedua menembak.
2. **v2 (revisi)** — saat latch reset, `referencePrice := lastPrice`. Test yang sama lulus; seluruh suite 14/14 (5 Fase 1 + 5 Fase 2 + 4 Guardian). v2 inilah yang dideploy on-chain.

## Bukti On-Chain — Tiga Leg

Urutan tiap leg: 16× `publishPrice` (Sepolia) → runner Fase 2 (tidak diubah) memposting 16 verdict ke AIOracle → guardian bereaksi di Lasna. Busur verdict on-chain **identik langkah-per-langkah dengan simulasi offline** yang dijalankan sebelum emisi — bukti determinisme model dari state runner yang berlanjut.

### Leg A — CALM (harga ±0,15% di sekitar $2.000; jendela runner bergeser dari leg volatile Fase 2)

- Emisi harga: 16 TX, pertama `0xb9cb401f8f98b27c2a1b4787ce8aca8f63d91d5a5bf5311a1b7e56bc4850a9fe` (200000), terakhir `0x1fbf75ffc60a87e7d5904f8ec2c91548d60b1f532d714c15d721bccc75d9d5d1` (200330). Daftar lengkap di `phase3-run-output.txt`.
- Verdict (AIOracle #33–#48): transisi volatile risk 41, 69, 69, 69, 69, 69, 69, 69, 68, 69, 68, 68, 69, 68, 70 — verdict pertama `0xe19a1ff157736de54e3d851699316276a7416147f1f016c7a7e2d3a690620fad` — ditutup calm **risk 16** `0x312f4f2ff11a0641eb1529fe04cfa43fea20480d880aef8f22a4d2949e6756e2`. Tidak ada verdict regime 2; skor tertinggi 70 < 80.
- Guardian sesudah leg: `priceCount 16, verdictCount 16, protectionCount 0, dangerLatched false, lastPrice 200330, referencePrice 200330, lastRisk 16, lastRegime 0`. Recorder#3 `callbackCount 0`. **→ Calm TIDAK menembak callback. ✓**

### Leg B — CRASH (−52%: 200330 → 96000)

- Emisi harga: 16 TX, pertama `0xd329d6c474fbb65688a04c34570870c934c9c541f3f174554ba97f44fed29d54` (196000), emisi harga pemicu (140000) `0xee21444b8e99a439b031d85931010d591ea62822d15d971f84e1313679f7cb58`, terakhir `0xed91fedbb33f1908cb47b32d83e387288b01089233c10cb08c14e3befac37f8c` (96000).
- Verdict (AIOracle #49–#64) — mereproduksi persis busur Fase 2 #1–#16:

| Harga | Risk | Rezim | TX submitVerdict |
|---|---|---|---|
| 196000 | 28 | calm | `0x03de933434108ee10a49eeb2cb54d91d209c092301f3360e431b5b05d402416d` |
| 190500 | 41 | volatile | `0xfd589c9bd6e5ee930bb460879a2aa45e5a6fa7e24b75768d0713fc2ad7c5a3b5` |
| 184000 | 52 | volatile | `0xa9af7007043d37c7dec250992265330e75d77d11c6353a18b85c711f61c7d9fd` |
| 176500 | 59 | volatile | `0xab0692401f74d027efbc914a20cbbc371db6b1e7e2eda4859f79f3a28d1ea537` |
| 168000 | 63 | volatile | `0xeb65e25de2220a8b0e56ed0eb9163d991d9e340e4d5ee1a68fc4a8bebf1587ea` |
| 159000 | 71 | volatile | `0x0443ddf879ebb75e05bfdfe026cca7c04a7bebdbd1db3e76f36a8a3e915fa31a` |
| 149500 | 77 | volatile | `0xf35e497e338a8af30343517a2c63fbf06495f361ec2acd79d400de9c4b88edbb` |
| **140000** | **83** | **crash-risk** | **`0xd54cfcd35a0a46e2061400d2fc32cbad692a97d372d4734aad3f4b8c021d8259` ← PEMICU** |
| 131000 | 86 | crash-risk | `0x46d005e49ca916e13678004126789072f2114e2cca7ad5213261469605376b8e` |
| 123500 | 87 | crash-risk | `0x67e70b204f2340d5056b2eacba28cc67286395e401ff646b889882e2d40d7ebb` |
| 117000 | 88 | crash-risk | `0xd810648de6cf38ea8ab8d35a8bf847367ff924152a001f21b30dc5bf58efb412` |
| 111500 | 89 | crash-risk | `0x0329b41dd3fd3613bfefc612300899c2f163238a9c102d0f6533f6f030411d9b` |
| 107000 | 88 | crash-risk | `0xfb0d6daae9903a293b2794e26b04ac919cda3a739838af3737bb5f369371fd16` |
| 103000 | 88 | crash-risk | `0x761604d021203628b95052788279f845ff89fc899608b595b6c8faa786272746` |
| 99500 | 88 | crash-risk | `0x8026bf59de0cfae88856d5aff16e7140301ca70d2714bbc5a1261dc65cd5eb0d` |
| 96000 | 88 | crash-risk | `0xcb1d34b933e6f18e255ce303afdafa3e78765308609f2a1e94cf9c12e871d7e8` |

- **Reaksi Lasna (blok 8440475):** TX `0x5190d9c9292209f54c01cb3c51d8743b9d9a5c955c5422dd71dbfd2bfa20ad05` — memuat `CallbackRequest` dari system contract `0x8888…8888` DAN `ProtectionTriggered(riskScore=83, verdictTxHash=0xd54cfcd3…8259)` dari guardian dalam TX yang sama (pola yang sama dengan Fase 1).
- **Callback Sepolia:** TX `0x7f142c65ff6449087c467ce5a8150e7e3001ad5698fa45a3b9d052172b2b0ef7` — `CallbackRecorded(reactive=guardian, value=83, originTxHash=0xd54cfcd3…8259)` di Recorder#3.
- Guardian sesudah leg: `priceCount 32, verdictCount 32, protectionCount 1, dangerLatched true, lastPrice 96000, referencePrice 200330, lastRisk 88, lastRegime 2`. Delapan verdict crash sesudah pemicu semuanya ter-latch — tidak ada callback tambahan. **→ Crash menembak TEPAT SATU callback. ✓**

### Leg C — VOLATILE / RECOVERY (chop ±3% di sekitar $975–$1.005)

- Emisi harga: 16 TX, pertama `0xa32cc82be9cd2cdc2be4442f32d198f4b8ec718fe2e747679d6af5402bf2f14a` (98500), terakhir `0xb9c2cec50027c64ca22c15f76ff1ad3447a205e031d4e1c84e82e2765178dba2` (97500).
- Verdict (AIOracle #65–#80): crash-risk 87, 88, 87, 88 (masih ter-latch — tidak menembak), lalu **volatile 84 @ 100000** (TX `0x8bda3570725dbe62119cd0ea7a8eca0f3100cdc6c2e70c92709a8def0035884d`) → latch reset; **crash blip 84 @ 97000** (TX `0x6982a151825f9e4ea4c5dacae5e76c8be3ba2a7c401747d561f348c6d5425cf5`) → TIDAK menembak (penurunan dari anchor reset hanya ±3%); sisanya meluruh volatile 77, 74, 61, 61, 54, 55, 50, 52, 50, 52.
- **Bukti reset on-chain:** event `LatchReset(risk=84, regime=1, referencePrice=97500)` di Lasna blok 8440871, TX `0xc5bd7f64f200be2b2de129fdd748733c06038db50c848e49ee17d4fb4bc3b690`. Jumlah `ProtectionTriggered` pada rentang leg C: **0**.
- Guardian sesudah leg: `priceCount 48, verdictCount 48, protectionCount 1, dangerLatched false, lastPrice 97500, referencePrice 97500 (ter-anchor ulang), lastRisk 52, lastRegime 1`. Recorder#3 `callbackCount` tetap **1**. **→ Latch reset terbukti, tanpa callback ekstra. ✓**

## Verifikasi Akhir

Dijalankan ulang independen setelah run:

```
cast call Guardian.priceCount()        → 48        cast call Guardian.lastRegime()      → 1
cast call Guardian.verdictCount()      → 48        cast call Recorder#3.callbackCount() → 1
cast call Guardian.protectionCount()   → 1         cast call Recorder#3.lastValue()     → 83
cast call Guardian.dangerLatched()     → false     cast call Recorder#3.lastOriginTxHash() → 0xd54cfcd3…8259 (= TX verdict pemicu)
cast call Guardian.lastPrice()         → 97500     cast call Recorder#1.callbackCount() → 1 (Fase 1, tidak berubah)
cast call Guardian.referencePrice()    → 97500     cast call AIOracle.verdictCount()    → 81 (33 Fase 2 + 48 Fase 3)
cast call Guardian.lastRiskScore()     → 52        cast call PriceEmitter.updateCount() → 96 (48 + 48)
forge test                                           → 14/14 lulus (5 Fase 1 + 5 Fase 2 + 4 Guardian)
```

## Saldo & Belanja

| Pemilik | Chain | Sebelum Fase 3 | Sesudah Fase 3 |
|---|---|---|---|
| Wallet dev `0x7eCbaa4fcCA36eBA9860C15d12e21929CAa0d53D` | Sepolia | 0,6972589078 SepETH | 0,6769572929 SepETH |
| Wallet dev | Lasna | 3,1485160000 lREACT | 1,0048323000 lREACT |
| SentinelGuardian (modal awal 2 lREACT) | Lasna | 2,0 lREACT | 0,7133424000 lREACT |

Rincian belanja: Sepolia ±0,0203 SepETH (0,02 modal Recorder#3 + ±0,0003 untuk deploy recorder dan 96 `publishPrice` + 48 `submitVerdict`). Lasna dari wallet dev ±2,1437 lREACT (2,0 modal guardian + ±0,1437 gas deploy guardian & `setRecipient`). Guardian sendiri mengonsumsi ±1,2867 lREACT untuk 96 reaksi + 1 permintaan callback (±0,0134 lREACT per reaksi — kontrak reaktif membayar eksekusi reaksinya sendiri dari saldonya; sisa 0,7133 lREACT cukup untuk ±50 reaksi lagi). Tidak ada faucet tambahan; tidak ada biaya riil.

## Catatan Kegagalan & Observasi (jujur)

1. **Instance recorder Fase 1 tidak bisa dipakai ulang** (lihat §Catatan Destination): `_CALLBACK_SENDER` immutable terikat ke kontrak Fase 1 — terverifikasi on-chain sebelum deploy, jadi instance baru dari kontrak yang sama dideploy. Bukan kegagalan run, tetapi penyimpangan sadar dari bayangan awal "callback ke recorder Fase 1" — substansinya sama (kontrak, pola, dan peran identik), dan instance lama sengaja dibiarkan sebagai kontrol negatif.
2. **Urutan eksekusi reaksi lintas-subscription tidak ketat mengikuti urutan log.** Bukti: field `price` pada event `ProtectionTriggered` terbaca 96000 (harga terakhir leg crash), bukan 140000 (harga verdict pemicu) — saat reaksi atas verdict pemicu dieksekusi, reaksi aliran harga untuk sisa leg crash sudah lebih dulu memajukan `lastPrice`. Konsekuensi desain: kondisi penurunan selalu dievaluasi terhadap harga terbaru yang diketahui (dalam crash berjalan, ini hanya membuat kondisi makin terpenuhi; verdict tetap sinyal penentu, dan data yang mengikat — risk 83 + hash TX verdict — persis). Untuk Fase 4 perlu diingat: jangan mengandalkan keserentakan antar-subscription; rancang kondisi yang monoton terhadap keterlambatan salah satu aliran.
3. **Kegagalan transient RPC publik** (sama seperti Fase 2): beberapa `cast send` sempat gagal percobaan pertama dengan `nonce too low` / `replacement transaction underpriced` dari node load-balanced; semuanya terserap retry 3× di `emit_prices.py`/`runner.py` (versi tersanitasi Fase 2 — tidak ada kunci yang tercetak; log bersih). Hitungan akhir selalu cocok: emitter 96, oracle 81, guardian 48/48 — tidak ada TX dobel atau hilang.
4. **Biaya reaksi Lasna nyata dan terukur** (±0,0134 lREACT/reaksi): subscription ganda berarti dua reaksi per langkah harga+verdict. Untuk operasi jangka panjang, modal guardian harus dianggarkan per volume event, bukan per callback — dicatat untuk Fase 4/5.

## Yang Harus Dilakukan Fase 4 (titik masuk persis)

1. **Vault sungguhan di Base Sepolia** (chain 84532) sebagai destination callback: kontrak vault yang menerima callback proteksi dari guardian (pola `AbstractCallback`, `_CALLBACK_SENDER` = alamat guardian `0x5135E5061eFC03639C365D697DBb7A5CA0Bc2f90` — ingat pelajaran Fase 3: sender terikat immutable sejak konstruksi, jadi vault harus dideploy dengan alamat guardian final) dan mengeksekusi aksi proteksi atas posisi mock (mis. menarik likuiditas / menukar ke aset aman) saat `recordCallback`-ekuivalen tiba.
2. Guardian Fase 3 sudah chain-agnostic soal destination (`destinationChainId` parameter konstruktor) — tetapi alamat guardian ini terkonfigurasi ke Sepolia; untuk destination Base Sepolia, deploy guardian baru dengan `destinationChainId = 84532` (atau terima guardian ini khusus Sepolia dan deploy pasangan guardian+vault untuk Base Sepolia), lalu ulangi bukti tiga leg secara ringkas (crash leg saja cukup untuk regresi).
3. **Base Sepolia butuh bahan bakar sendiri:** wallet dev perlu sedikit Base Sepolia ETH (testnet) untuk deploy vault + modal callback; saldo Sepolia/Lasna tidak berlaku di sana. Sumber: faucet Base Sepolia (mungkin perlu akun/attestation; siapkan waktu). Perhatikan juga aturan timestamp Base Sepolia dari PREP §1 saat menulis vault.
4. Setelah vault live: ulangi skenario crash Fase 2/3 dan buktikan aksi proteksi vault tereksekusi on-chain di Base Sepolia (bukan hanya tercatat), dengan rantai hash lengkap event → verdict → reaksi → callback → aksi vault.
