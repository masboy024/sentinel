# SENTINEL — Laporan Fase 4 (Vault Sungguhan di Base Sepolia: Callback yang Bertindak)

Tanggal: Senin, 16 Nov 2026 (WITA). Acuan: `PHASE3.md` §"Yang Harus Dilakukan Fase 4".
Lingkungan: testnet saja (Ethereum Sepolia + Reactive Lasna + Base Sepolia), nol biaya riil, wallet dev khusus testnet (bukan wallet user).

## Status: LOLOS — VAULT DI BASE SEPOLIA MENGEKSEKUSI AKSI PROTEKSI ON-CHAIN ✅

Rantai penuh berjalan lintas **tiga chain**: 24 event harga di Sepolia → 24 verdict AI (runner/model Fase 2, tidak diubah) → guardian baru di Lasna memproses 24 harga + 24 verdict → leg calm **0 callback** → leg crash **tepat 1 callback proteksi** (terpicu verdict risk 83 @ harga 140000, −30,1% dari puncak) → callback tiba di **SentinelVault, Base Sepolia**, dan vault **mengeksekusi aksi proteksi**: seluruh posisi mock 1.000.000 unit dipindahkan dari `positionAtRisk` ke `safeBalance`, tercatat dengan risk score pemicu (83) dan hash TX verdict pemicu. Semua angka diverifikasi ulang independen via `cast call` di ketiga chain; `forge test` 21/21. Log mentah: `phase4-run-output.txt`; state runner: `sentinel/ai/runner_state.json` (105 verdict kumulatif).

**Gerbang Fase 4 LULUS.** Yang tersisa adalah Fase 5 (paket submission).

## Desain

### SentinelVault (Base Sepolia) — `sentinel/src/SentinelVault.sol`

Kontrak tujuan yang **bertindak**, bukan sekadar mencatat (beda dari CallbackRecorder Fase 1–3):

- Mengikuti pola `AbstractCallback` yang sama: callback harus datang dari callback proxy resmi Base Sepolia (`onlyServiceProvider`, proxy `0x476F44b11F5C942c58f4c8E3d0300E5710743585` — dari PREP §1; ukuran kode on-chain 218 byte, identik dengan proxy Sepolia yang terbukti di Fase 1–3), dan argumen pertama yang diinjeksi jaringan harus sama dengan alamat guardian yang terikat **immutable** sejak konstruksi (`onlyCallbackSender`).
- State posisi mock: `positionAtRisk` / `safeBalance` (unit mock; 1 unit = 1 sen USD — deployment men-seed 1.000.000 unit = posisi mock $10.000), `protectionCount`, `totalProtected`, `lastRiskScore`, `lastOriginTxHash`, `lastProtectedAmount`, `lastProtectionTimestamp` (memakai `block.timestamp`, sesuai aturan Base Sepolia di PREP §1: timestamp, bukan hitungan blok).
- Entry point callback memakai signature yang sama persis dengan payload guardian Fase 3/4, `recordCallback(address,uint256,uint256)`. Saat callback valid tiba, aksi proteksi tereksekusi seketika: seluruh `positionAtRisk` → `safeBalance`, event `ProtectionExecuted(reactive, riskScore, amountMoved, originTxHash)`.
- **Defense in depth:** vault menolak callback dengan risk score < 80 (`MIN_PROTECTION_RISK`, ambang yang sama dengan guardian) — guardian hanya pernah mengirim skor bahaya terkonfirmasi, jadi skor rendah di vault berarti sinyal tidak asli. Caller bukan proxy → revert `NotAuthorized`; argumen sender salah → revert `CallbackNotAuthorized` (keduanya dibuktikan di test lokal; yang pertama juga dibuktikan on-chain, lihat §Verifikasi).
- Saldo ETH vault (0,02 saat deploy) terpisah dari unit posisi mock: ia membayar biaya eksekusi callback ke proxy (model debt `AbstractPayer`, pola Fase 1–3). Biaya terukur eksekusi proteksi ini: hanya ±0,0000016 ETH.
- `depositPosition(uint256)` (owner) memodelkan setoran posisi baru; `coverDebt()` standar.

### Penjajaran alamat (pelajaran Fase 3 diterapkan)

`_CALLBACK_SENDER` immutable ⇒ vault harus dideploy dengan alamat guardian **final**, padahal guardian belum ada. Solusi yang dieksekusi persis seperti direncanakan: alamat guardian **diprediksi** dari nonce wallet dev di Lasna (`cast compute-address` pada nonce 4 → `0x39C0de948f401Fc8359ACC2F2ceF472F57426D6e`), vault dideploy lebih dulu di Base Sepolia terikat ke prediksi itu, lalu guardian dideploy di Lasna (mengonsumsi nonce 4) dan alamat aktualnya **sama persis** dengan prediksi — diasertasi di script deploy dan terbaca on-chain (`vault._CALLBACK_SENDER() == guardian`). Tidak ada TX Lasna lain yang dikirim di antara pembacaan nonce dan deploy guardian.

### Guardian Fase 4 (Lasna)

Instance `SentinelGuardian` baru — kode yang sama persis dengan Fase 3, tanpa modifikasi — dengan `destinationChainId = 84532` dan recipient = vault. AI (runner, model, weights Fase 2) dipakai **tanpa perubahan**. Modal awal 0,68 lREACT + top-up 0,1 lREACT di tengah run (lihat §Saldo & Belanja).

### Skenario ringkas (sesuai titik masuk Fase 4)

Simulasi offline (`sentinel/ai/sim_phase4.py`, jendela runner yang persisten) dijalankan sebelum gas dibelanjakan. Seri on-chain: **calm prefix 8 harga** (potongan pertama `DEMO_CALM`) lalu **crash 16 harga** (`DEMO_CRASH` utuh). Prediksi simulasi: calm 41 lalu 69×7 (semua volatile, tanpa bahaya); crash naik 69→74 (volatile), verdict bahaya pertama **risk 83 @ 140000** di langkah gabungan ke-16, lalu crash-risk 86–89 ter-latch. **Busur on-chain identik langkah-per-langkah dengan simulasi** di kedua leg — bukti determinisme model dari state runner yang berlanjut, sama seperti Fase 3.

## Pendanaan Base Sepolia (STEP 0) — faucet dicoba, jembatan resmi yang berhasil

Wallet dev di Base Sepolia awalnya 0. Faucet tanpa akun yang dicoba lebih dulu:

| Faucet | Hasil |
|---|---|
| QuickNode (faucet.quicknode.com/base/sepolia) | Halaman berupa aplikasi JS (butuh interaksi browser); endpoint drip API yang dicoba membalas kosong — tidak bisa diselesaikan secara programatik |
| Coinbase Developer Platform faucet API | API claim membalas kosong tanpa kredensial CDP — butuh akun CDP + API key |
| Chainlink (faucets.chain.link/base-sepolia) | Alur mewajibkan connect wallet di browser (+ atestasi) — tidak bisa diselesaikan dari lingkungan ini |
| Bware Labs faucet | Situs tidak terjangkau via curl (koneksi gagal) |
| Alchemy faucet | Butuh sign-in akun Alchemy |
| L2Faucet / Superchain faucet | Butuh sign-in GitHub / atestasi |

Tidak ada akun yang dibuat atas nama siapa pun dan tidak ada kredensial yang diminta/dipakai. Karena tidak ada faucet tanpa-akun yang bisa diselesaikan, pendanaan diselesaikan lewat **jembatan resmi L1→L2 Base** (bukan faucet): deposit 0,05 SepETH dari wallet dev sendiri di Sepolia ke `L1StandardBridge` `0xfd0Bf71F60660E2f608ed56e1659C450eB113120` (terverifikasi on-chain: `l2TokenBridge()` = predeploy kanonik `0x4200…0010`; log `ETHDepositInitiated` from=to=wallet dev, 0,05 ETH), TX `0xa0b19fdd72e15f8bb749f961ee8e7b62ae32530a202915076c079f9a7789a923` (blok Sepolia 12143127). Dana terkredit penuh 0,05 ETH di Base Sepolia setelah jeda derivasi beberapa menit (lihat §Catatan Kegagalan no. 2). Mekanisme ini tidak memakai akun, tidak membeli apa pun, dan hanya memindahkan dana testnet milik wallet dev antar-testnet — dicatat transparan sebagai penyimpangan prosedural dari rencana "faucet dulu", dengan seluruh percobaan faucet terdokumentasi di atas.

## Kontrak Ter-deploy

| Kontrak | Chain | Alamat | TX Deploy |
|---|---|---|---|
| SentinelVault (modal 0,02 ETH; posisi seed 1.000.000 unit) | Base Sepolia (84532) | `0x2a7855f146189b477A7b184aFF99a31A6b977918` | `0xb0fada54ee9b868e6033c5acdc63ce2b10b31f685c734463694668e24c5aec30` |
| SentinelGuardian #4 (modal 0,68 lREACT) | Lasna (5318007) | `0x39C0de948f401Fc8359ACC2F2ceF472F57426D6e` | `0x563c455abb4966dca9ed4c9b9e37a480680c12204e9372d198f8db4a98f523f8` |
| setRecipient(vault) di guardian #4 | Lasna | — | `0x36f3d5b70cbdeeea5fc5b47e3ed7441aebc6451297062fccff9eb56cb75f5a81` |
| Top-up guardian #4 (+0,1 lREACT, dari wallet dev) | Lasna | — | `0xe9e399f2dd6b2ec8f263e8309a794f4838d6de2a0201f333f235aa39d64d0d40` |

Catatan alamat (agar tidak membingungkan pembaca): alamat vault di Base Sepolia sama persis dengan alamat `SentinelReactive` Fase 1 di Lasna (`0x2a7855…7918`) — lagi-lagi kebetulan (deployer, nonce) lintas chain seperti di Fase 3; beda chain, tidak ada konflik peran.

Baseline sebelum emisi: guardian #4 priceCount/verdictCount/protectionCount = 0/0/0; vault positionAtRisk/safeBalance/protectionCount = 1.000.000/0/0; AIOracle verdictCount = 81; PriceEmitter updateCount = 96.

## Bukti On-Chain — Dua Leg

Urutan tiap leg: `publishPrice` (Sepolia) → runner Fase 2 (tidak diubah) memposting verdict ke AIOracle → guardian #4 bereaksi di Lasna.

### Leg A — CALM PREFIX (8 harga ±0,15% di sekitar $2.000)

- Emisi harga: 8 TX, pertama `0x784fed8b561a809fe6fa185bece3cd12ac61d48575e80691aa0d885ca4fc57b6` (200000), terakhir `0x787f6856ea8710de6ae1280ebd57f8c0569139a442b921c64aad614ae542acda` (200180). Daftar lengkap di `phase4-run-output.txt`.
- Verdict (AIOracle #82–#89): volatile **41, 69, 69, 69, 69, 69, 69, 69** — identik dengan simulasi offline. Tidak ada verdict regime 2; skor tertinggi 69 < 80.
- Guardian sesudah leg: `priceCount 8, verdictCount 8, protectionCount 0, dangerLatched false, lastPrice 200180, referencePrice 200240, lastRisk 69, lastRegime 1`. Vault `protectionCount 0`, posisi tidak tersentuh. **→ Calm TIDAK menembak callback. ✓**

### Leg B — CRASH (−52%: 200240 → 96000)

- Emisi harga: 16 TX, pertama `0x9e983e260812b7a3525fa7b1e731133bb1988690e79edeaf5a02f6b3b07ddbe5` (196000), emisi harga pemicu (140000) `0x1eb39f0c427a02f0b6ca7260d2663a0945c3aceed14dfad71483f85e0ae2a118`, terakhir `0x795ae06b2e7f99a59cd19f8dd872f4b40751b515329afa801d670fa0e3708110` (96000).
- Verdict (AIOracle #90–#105) — identik langkah-per-langkah dengan simulasi offline:

| Harga | Risk | Rezim | TX submitVerdict |
|---|---|---|---|
| 196000 | 69 | volatile | `0xef7c1f93d3748aa4b3fb3af8d2216ad50b8b595f00504cab371fa5ea8ae0a98f` |
| 190500 | 71 | volatile | `0x28ebe376ad443b77c50ed0a61baf9899263e0518dc96e8b6c646d4fa0f80e6ee` |
| 184000 | 72 | volatile | `0xe9e5cfc35c6d9d71aa01b106a5f912aad7b24d22510f28b7568e24823de5b448` |
| 176500 | 73 | volatile | `0x6a4d30baebc22351f9dfaf7c22cdb780ede5a7032482ef690e5e25b5c71cfa37` |
| 168000 | 72 | volatile | `0x86a15ebc7ba374da1072c15d0da3a5accbb3d3349f5b622e68ab15455a4f6809` |
| 159000 | 74 | volatile | `0xfdc8cf39ed01b72f0c9fe7234af49c6540074d6d3e11f2d5853af649661a6a43` |
| 149500 | 74 | volatile | `0x2d2d4831b6fbcb5f8c90a02c3531e5d6c0656721b1672c1b793c2cc543896cc9` |
| **140000** | **83** | **crash-risk** | **`0x609e8f42701286612c00ea2d28b6c8fbed8bcdc677627946f1267e0cabc3e352` ← PEMICU** (verdict kumulatif ke-97 / indeks 96; `getVerdict(96)` terverifikasi: risk 83, regime 2, price 140000) |
| 131000 | 86 | crash-risk | `0x3c11662f57ac5879103eb667cc1edaefeff44dd02b74e18f66edf8af496fa8e5` |
| 123500 | 88 | crash-risk | `0x65d5bb057bffeb506ecdbf532b52aea378827b5da304fe676bb27b2a1ab45826` |
| 117000 | 89 | crash-risk | `0x7f9a9dead37fcbf89d3b4430dd3e5d04635407d6d265f460a0a434af3fbe582d` |
| 111500 | 89 | crash-risk | `0x16ec42714ef136b68d63c9b675a7611393141cfc4dc40157b2b0f1923e716f40` |
| 107000 | 88 | crash-risk | `0xd689d5f8a1177511f209e7c4b943d0fd3d358f20b4cbf089f2f0ad4312231711` |
| 103000 | 88 | crash-risk | `0x2918919a1e0176e90bbe6be27eafef4cb257d9d33070dc52e75b6c0789289d5a` |
| 99500 | 88 | crash-risk | `0x4a4c7246512989b6314c2848cf046680f187f45efc5a2bd63950a59e7a4cd125` |
| 96000 | 88 | crash-risk | `0x47adb8b47994f870464f3f35d29bf8fdf93fe2dfba3491229a0a0e8819a4f1d2` |

- **Reaksi Lasna (blok 8442343):** TX `0xf2e837bb95f60a3e6d6e1d63a1294cef7d567e457d835c03b36ed6c45e8f8a7b` — memuat `CallbackRequest` dari system contract `0x8888…8888` DAN `ProtectionTriggered(riskScore=83, verdictTxHash=0x609e8f42…e352)` dari guardian #4 dalam TX yang sama (pola Fase 1/3).
- **Callback + aksi vault (Base Sepolia, blok 59300567):** TX `0x50ce3b624014bd549989a51e323d64bc61f8671790e9325248e1f8b2dde48b57` — ditujukan ke callback proxy `0x476F44b1…3585`, gasUsed 228.821, satu-satunya log adalah `ProtectionExecuted(reactive=guardian#4, riskScore=83, amountMoved=1000000, originTxHash=0x609e8f42…e352)` dari vault.
- Guardian sesudah leg: `priceCount 24, verdictCount 24, protectionCount 1, dangerLatched true, lastPrice 96000, referencePrice 200240, lastRisk 88, lastRegime 2`. Sembilan verdict crash sesudah pemicu semuanya ter-latch — tidak ada callback tambahan. **→ Crash menembak TEPAT SATU callback. ✓**
- Vault sesudah leg: `positionAtRisk 0, safeBalance 1000000, totalProtected 1000000, protectionCount 1, lastRiskScore 83, lastOriginTxHash 0x609e8f42…e352 (= TX verdict pemicu, terverifikasi), lastProtectedAmount 1000000, lastProtectionTimestamp 1794781982`. **→ Aksi proteksi tereksekusi on-chain di Base Sepolia, bukan hanya tercatat. ✓**

### Ko-reaksi guardian Fase 3 (observasi penting, jujur)

Guardian Fase 3 berlangganan event PriceEmitter + AIOracle **yang sama**, jadi ia ikut memproses seluruh aliran Fase 4: state-nya maju 48/48 → **72/72**, dan pada verdict pemicu yang sama ia menembak callback proteksi keduanya ke CallbackRecorder #3 (callback Sepolia TX `0x625a43df93212f8647ad1c92839ef663377c0274caa9f82e4c2c6130a938f8d2`, blok 12143206; recorder #3 kini `callbackCount 2, lastValue 83, lastOriginTxHash 0x609e8f42…e352` — pemicu yang sama persis). Saldo guardian Fase 3 terpakai oleh reaksi-reaksinya sendiri: 0,7133 → 0,0770 lREACT (±0,0131/reaksi, konsisten). **Tidak ada dana yang dipindahkan keluar dari guardian Fase 3** — konsumsi ini adalah biaya reaksi kontrak itu sendiri atas subscription yang masih live, dan bukti Fase 3 tetap utuh sebagai catatan historis (rantai hashnya sendiri). Sisi baiknya: dua guardian independen di Lasna, dua destination berbeda (Sepolia + Base Sepolia), keduanya menembak tepat satu kali pada verdict AI yang sama — konfirmasi silang atas pemicu. Sisi yang harus diingat untuk Fase 5: **setiap emisi harga baru akan menghidupkan kedua guardian**; anggarkan lREACT untuk keduanya bila demo final memakai aliran yang sama, dan saldo guardian Fase 3 kini tipis (0,0770).

## Verifikasi Akhir

Dijalankan ulang independen setelah run (`run_phase4.sh verify` + pembacaan log):

```
cast call Guardian4.priceCount()        → 24         cast call Vault.positionAtRisk()     → 0
cast call Guardian4.verdictCount()      → 24         cast call Vault.safeBalance()        → 1000000
cast call Guardian4.protectionCount()   → 1          cast call Vault.protectionCount()    → 1
cast call Guardian4.dangerLatched()     → true       cast call Vault.totalProtected()     → 1000000
cast call Guardian4.lastRiskScore()     → 88         cast call Vault.lastRiskScore()      → 83
cast call Guardian4.referencePrice()    → 200240     cast call Vault.lastOriginTxHash()   → 0x609e8f42…e352 (= TX verdict pemicu)
cast call Guardian4.lastVerdictTxHash() → 0x47adb8b4…a4f1d2 (= verdict crash terakhir)
cast call AIOracle.verdictCount()       → 105 (81 + 24)    cast call PriceEmitter.updateCount() → 120 (96 + 24)
cast call AIOracle.getVerdict(96)       → risk 83, regime 2, price 140000 (verdict pemicu)
cast call Vault.recordCallback(guardian, 83, …) dari wallet dev → REVERT NotAuthorized(dev, proxy) — bukti on-chain penolakan caller tak sah
forge test                              → 21/21 lulus (5 Fase 1 + 5 Fase 2 + 4 Guardian + 7 Vault)
```

Test lokal Vault (7) mencakup: callback valid mengeksekusi proteksi penuh; argumen sender salah → `CallbackNotAuthorized`; caller bukan proxy → `NotAuthorized`; skor risiko rendah (52) → revert ambang; callback kedua memindahkan 0 (idempoten terhadap pengulangan); `depositPosition` hanya owner.

## Saldo & Belanja

| Pemilik | Chain | Sebelum Fase 4 | Sesudah Fase 4 |
|---|---|---|---|
| Wallet dev `0x7eCbaa4fcCA36eBA9860C15d12e21929CAa0d53D` | Sepolia | 0,6769572929 SepETH | 0,6268130007 SepETH |
| Wallet dev | Lasna | 1,0048323000 lREACT | 0,0790431000 lREACT |
| Wallet dev | Base Sepolia | 0 → +0,05 (jembatan) | 0,0299954826 ETH |
| SentinelGuardian #4 (modal 0,68 + top-up 0,1) | Lasna | 0,78 lREACT | 0,1300223000 lREACT |
| SentinelVault (modal 0,02 ETH) | Base Sepolia | 0,02 ETH | 0,0199983692 ETH |
| SentinelGuardian Fase 3 (ko-reaksi, bukan dana Fase 4) | Lasna | 0,7133424000 lREACT | 0,0770447000 lREACT |

Rincian belanja:
- **Sepolia ±0,0501 SepETH** — 0,05 deposit jembatan + ±0,00014 gas untuk 24 `publishPrice` + 24 `submitVerdict`.
- **Lasna dari wallet dev ±0,9258 lREACT** — 0,68 modal guardian #4 + 0,1 top-up + ±0,1458 gas (deploy guardian ±0,139 pada harga efektif ±100 gwei seperti Fase 3, `setRecipient`, TX top-up).
- **Guardian #4 sendiri ±0,6500 lREACT** untuk 48 reaksi + 1 permintaan callback (±0,0135/reaksi — konsisten dengan Fase 3 ±0,0134). Sisa 0,1300 cukup untuk ±9 reaksi lagi; demo berikutnya perlu top-up.
- **Base Sepolia dari wallet dev ±0,0200 ETH** — 0,02 modal vault + ±0,0000045 gas deploy vault. **Vault membayar ±0,0000016 ETH** ke proxy untuk eksekusi callback proteksi (228.821 gas).
- Tidak ada faucet yang berhasil dipakai; tidak ada biaya riil; tidak ada akun yang dibuat.

## Revisi Berdasarkan Perilaku Teramati (tahapan bangun)

1. **Tahap 1:** `SentinelVault.sol` + `test/Vault.t.sol` (7 test) ditulis dan seluruh suite lulus 21/21 sebelum satu pun TX on-chain; simulasi offline busur verdict (`ai/sim_phase4.py`) memprediksi titik tembak persis (langkah 16, risk 83 @ 140000).
2. **Revisi script deploy (idempotensi + gas eksplisit):** percobaan deploy pertama gagal di tengah (vault sudah terlanjur ter-deploy di Base Sepolia ketika deploy guardian di Lasna gagal estimasi). `run_phase4.sh` direvisi: langkah vault menjadi idempoten (pakai ulang vault yang ada setelah memverifikasi `_CALLBACK_SENDER` on-chain == prediksi, bukan deploy ulang), dan deploy guardian memakai `--gas-limit` eksplisit yang dihitung dari perilaku node (lihat §Catatan Kegagalan no. 3) dengan modal diturunkan 0,8 → 0,68 lREACT agar lolos pre-check node. Deploy ulang kemudian berhasil dan asersi alamat lulus.
3. **Top-up terukur di tengah run:** setelah leg calm, laju konsumsi guardian terukur 0,0139 lREACT/reaksi — proyeksi leg crash (32 reaksi + callback ±0,46) mepet terhadap sisa 0,4573. Ditambah 0,1 lREACT dari sumber yang sama (wallet dev di Lasna) sebelum leg crash; guardian mengakhiri run dengan sisa sehat 0,1300.

## Catatan Kegagalan & Observasi (jujur)

1. **Tidak ada faucet tanpa-akun yang bisa diselesaikan** dari lingkungan eksekusi ini (rinci di §Pendanaan). Pendanaan akhirnya lewat jembatan resmi L1→L2 memakai dana testnet wallet dev sendiri — tanpa akun, tanpa kredensial, tanpa pembelian. Dicatat apa adanya sebagai jalur yang benar-benar terjadi.
2. **Keterlambatan kredit jembatan + inkonsistensi RPC publik Base Sepolia.** Deposit L1 sukses pukul awal run, tetapi saldo L2 terbaca 0 selama beberapa menit di dua provider independen (satu pembacaan sesaat menunjukkan 0,0498 lalu kembali 0 — gejala derivasi/head yang belum sinkron), dan percobaan deploy vault pertama gagal `insufficient funds: have 0`. Setelah derivasi selesai, saldo terkredit **penuh 0,05 ETH** dan deploy ulang berhasil. Bukan kegagalan kontrak — artefak infrastruktur testnet; penanganannya: tunggu + verifikasi saldo di dua provider sebelum deploy.
3. **Node Lasna: estimasi gas dan pre-check yang tidak ramah saldo tipis.** Deploy guardian pertama gagal di `eth_estimateGas` dengan `contract creation code storage out of gas` (flakiness node pada konstruktor yang memanggil `subscribe`, padahal kontrak identik ter-deploy mulus di Fase 3). Dengan `--gas-limit 3000000`, node menolak di pre-check `eth_sendRawTransaction`: `value + gasLimit × harga kini (±200 gwei)` = 1,4 lREACT > saldo 1,0048. Kombinasi yang lolos: `--gas-limit 1500000` (pemakaian aktual Fase 3: 1.389.168) + modal 0,68 — harga efektif yang akhirnya dibebankan tetap ±100 gwei seperti Fase 3 (total gas deploy+setRecipient+top-up ±0,1458). Pelajaran: di Lasna, upfront check memakai batas gas × harga spot, jadi batas gas harus diukur ketat terhadap pemakaian aktual, bukan dibulatkan longgar.
4. **Ko-reaksi guardian Fase 3** (lihat §khusus di atas): subscription yang berbagi origin akan selalu ikut bereaksi. Bukti Fase 3 tidak rusak, tetapi state "akhir" Fase 3 di laporan lamanya kini sudah maju (72/72, protectionCount 2) dan saldonya tipis. Untuk Fase 5, perlakukan kedua guardian sebagai konsumen aliran yang sama dalam penganggaran demo.
5. **Urutan eksekusi lintas-subscription tidak ketat** (pengulangan observasi Fase 3): field `price` pada `ProtectionTriggered` terbaca 96000 (harga terakhir leg crash), bukan 140000 (harga verdict pemicu) — reaksi aliran harga untuk sisa leg sudah lebih dulu memajukan `lastPrice` saat reaksi verdict pemicu tereksekusi. Data yang mengikat (risk 83 + hash TX verdict) persis di guardian, recorder, dan vault; kondisi penurunan memang dirancang monoton terhadap keterlambatan ini.
6. **RPC Base Sepolia membatasi `eth_getLogs` ke rentang 200 blok** — pencarian TX callback vault dilakukan dengan pemindaian berpotong 200 blok dari blok sebelum leg crash sampai head; ditemukan tepat satu `ProtectionExecuted` (blok 59300567).
7. **Satu kegagalan transient `nonce too low`** pada emisi harga crash ke-8 (140000) terserap retry 3× helper Fase 2 (versi tersanitasi — tidak ada kunci yang tercetak; log Fase 4 dipindai: 0 kemunculan kunci). Hitungan akhir selalu cocok: emitter 120, oracle 105, guardian #4 24/24 — tidak ada TX dobel atau hilang.

## Yang Harus Dilakukan Fase 5 (paket submission)

1. **Dokumentasi submission:** README + dokumen arsitektur yang merangkai Fase 1–4 (diagram aliran Sepolia → AI runner → Lasna → Base Sepolia), tabel alamat kontrak final di tiga chain, dan rantai hash bukti per fase (PHASE1–4.md sebagai sumber). Sorot rantai Fase 4 sebagai bukti utama kriteria Execution/Integration: event harga → verdict AI → reaksi Lasna → callback → **aksi vault**.
2. **Repo publik + formulir BUIDL DoraHacks:** siapkan repo (kode kontrak + AI + script run + laporan fase), lalu isi formulir submission (judul, deskripsi, track Reactive Meets AI, logo/tangkapan layar) sebelum deadline **5 Des 2026 20:00 UTC** (PREP §1).
3. **Video demo < 3 menit:** skenario paling meyakinkan adalah putar ulang ringkas Fase 4 (calm prefix singkat → crash → vault terlindungi) dengan hash terlihat. Anggarkan dulu: top-up guardian #4 (sisa 0,13 ≈ 9 reaksi — tidak cukup untuk 48 reaksi penuh; butuh ±0,55 lREACT lagi dari swap faucet Sepolia→Lasna pola Fase 1) dan ingat guardian Fase 3 ikut bereaksi (sisa 0,077 — akan kehabisan di tengah demo; itu wajar, tetapi jangan jadikan state-nya bagian dari klaim demo). Alternatif hemat: demo memakai ulang hash yang sudah ada (tanpa emisi baru).
4. **Kebersihan akhir:** pertimbangkan rotasi wallet dev sebelum submission final (catatan Fase 2: kunci dev testnet sempat tercetak di log lokal saat itu dan sudah diskrub; log Fase 4 bersih terverifikasi). Verifikasi source kontrak di explorer (Lasna/Base Sepolia) bila waktunya cukup.
5. **Yang TIDAK perlu dikerjakan lagi:** loop reaktif (Fase 1), AI on-chain (Fase 2), logika bahaya dua-sinyal + latch (Fase 3), dan vault yang bertindak di Base Sepolia (Fase 4) semuanya sudah terbukti on-chain dengan rantai hash lengkap.
