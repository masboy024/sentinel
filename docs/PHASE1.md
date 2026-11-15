# SENTINEL — Laporan Fase 1 (Loop Kerangka Reaktif)

Tanggal: Minggu, 15 Nov 2026 malam (WITA). Acuan rencana: `PREP.md` §5–§6.
Lingkungan: testnet saja, nol biaya riil, wallet dev khusus testnet (bukan wallet user).

## Status Loop: LOLOS — LOOP REAKTIF PENUH TEMBUS ON-CHAIN ✅

Loop kerangka (event origin di Sepolia → reaksi di Lasna → callback di Sepolia) **berhasil dieksekusi end-to-end di testnet** pada 15 Nov 2026 malam, setelah wallet dev terisi 0,7675 SepETH dari mining faucet pk910 oleh user. Script `sentinel/run_phase1.sh` selesai dengan exit code 0 dan vonis `LOOP PENUH BERHASIL`; semua counter diverifikasi ulang secara independen via `cast call` (pingCount = 1, reactionCount = 1, callbackCount = 1). Log mentah run final tersimpan di `phase1-run-output.txt`.

**Gerbang Fase 1 LULUS.** Fase 2+ (sinyal harga nyata + verdict AI on-chain + vault di Base Sepolia) bisa dimulai dari kerangka yang terbukti ini.

## Rantai Hash Bukti (semua terverifikasi on-chain)

| Langkah | Chain | TX Hash | Hasil |
|---|---|---|---|
| Pendanaan wallet dev (payout mining pk910) | Sepolia | `0xc34c06bc3252793c1efb965b93e81e024f06897449911a9565f10eaab4b64232` | +0,7675 SepETH masuk |
| Swap 0,05 SepETH → lREACT (faucet resmi Reactive `0x9b9BB25f…Cf434`, `request(address)`) | Sepolia → Lasna | `0xc21275479c7f15a14dcb05093a2b2eeab4aae7c1089e20faf341d38caa7f4444` | 5,25 lREACT terkredit di Lasna |
| Deploy OriginEmitter | Sepolia | `0xfd486ae7fc914e1ff24aa105cc23436658f39604739ff3a320c227d3e473b2c1` | `0x5135E5061eFC03639C365D697DBb7A5CA0Bc2f90` |
| Deploy SentinelReactive (dibiayai 2 lREACT) | Lasna | `0x86f37b4cd1939814662c752828dd6811b78eb143815ca7f38dfe1a043c57f434` | `0x2a7855f146189b477A7b184aFF99a31A6b977918` |
| Deploy CallbackRecorder (dibiayai 0,02 SepETH) | Sepolia | `0x2dad2179e436e3666d8ab586cd9aa28f0d02420a8aeab541909557e0d4ee2da9` | `0x1555b4fEe6C125731e956e36B9e5DC2ca9B2F95c` |
| `setRecipient(recorder)` di kontrak reaktif | Lasna | `0x3735154aa2856318747f1802b4036a2f9787e1102fa712f540984aebc794df17` | recipient terdaftar |
| Event origin `ping(42)` | Sepolia | `0xc664144f1d6abd1c30be31e6222ee27d80487805a43b082d94f05bc7381d3112` | event `Ping` ter-emit |
| Reaksi reaktif (blok Lasna 8418814) | Lasna | `0x2b0de2ea5302bb397910164f9a936e6e234c32b375e67387e220b9b9f987cd56` | event `ReactionRecorded` (topic = hash TX origin, data = 42) + event `CallbackRequest` dari system contract `0x8888…8888` dalam TX yang sama |
| Callback tereksekusi (blok Sepolia 12141156) | Sepolia | `0x14b0dd5f8666674aba6059b69e83a08580402978b9670b77e68dfe68e0b298a9` | event `CallbackRecorded` (sender = kontrak reaktif, value = 42, origin TX hash cocok) |

Catatan artefak diagnostik: selama diagnosis masalah `forge create` (lihat §Perbaikan Script), satu OriginEmitter uji ekstra ter-deploy di Sepolia (`0x01cE6f4eB729FD9A4F8E6d7003609C6be8eC5e5A`, TX `0x0fc7ff9930cde8c2b6ded4da009c520028e22f09314b6c756645c57e2b80b0c5`). Kontrak itu **bukan** bagian rantai final di atas.

## Saldo Akhir (terverifikasi via `cast balance` setelah run)

| Pemilik | Chain | Saldo |
|---|---|---|
| Wallet dev `0x7eCbaa4fcCA36eBA9860C15d12e21929CAa0d53D` | Ethereum Sepolia | 0,697491131337299870 SepETH (697491131337299870 wei) |
| Wallet dev | Reactive Lasna | 3,148515999998985160 lREACT (3148515999998985160 wei) |
| SentinelReactive `0x2a78…7918` | Lasna | 1,9804285 lREACT (dari 2 lREACT modal; ±0,0196 terpakai untuk gas callback) |
| CallbackRecorder `0x1555…F95c` | Sepolia | 0,019999999991243108 SepETH (±utuh 0,02) |

Sisa dana cukup untuk iterasi Fase 2 di pasangan chain yang sama tanpa faucet ulang.

## Perbaikan Script Selama Eksekusi (semua di dalam proyek sentinel)

Run pertama gagal sebelum on-chain; tiga cacat script/config ditemukan dan diperbaiki, lalu run ulang bersih:

1. **Parsing wallet** — `dev-wallet.txt` ternyata berformat satu baris tanpa label (`<address> <privatekey>`), sedangkan script mencari label `private key`/`Address`. Ditambahkan fallback ekstraksi berdasarkan pola hex (alamat 40 hex, kunci 64 hex); terverifikasi kunci menurunkan alamat dev yang benar. Private key tidak pernah dicetak ke log/laporan.
2. **`forge create` tanpa `--broadcast`** — di Foundry 1.9.0, `forge create` tanpa flag itu hanya dry-run: JSON keluar tanpa `deployedTo` dan tidak ada transaksi terkirim (nonce tidak bergerak — terbukti saat diagnosis). Ditambahkan `--broadcast` di ketiga pemanggilan deploy; JSON kemudian mengembalikan `deployedTo` + `transactionHash` persis seperti yang script harapkan.
3. **`bc` tidak terpasang** — perbandingan saldo minimum diganti `awk`; ditambah guard berhenti-dini bila ada deploy yang tidak menghasilkan alamat, agar kegagalan tidak merambat diam-diam.

## Yang Sudah Selesai Sebelum Eksekusi On-Chain (dari laporan sebelumnya)

1. **Toolchain** — Foundry **1.9.0** via `foundryup`.
2. **Wallet dev testnet** — `~/workspace/bounty-hunt/reactive-omni/dev-wallet.txt` (mode 600), alamat `0x7eCbaa4fcCA36eBA9860C15d12e21929CAa0d53D`. Khusus testnet; private key tidak ditampilkan di laporan ini.
3. **Proyek Foundry** — `~/workspace/bounty-hunt/reactive-omni/sentinel/`, library resmi **`reactive-lib-omni` v0.1.0**, pola mengikuti dokumentasi resmi dev.reactive.network.
4. **Tiga kontrak kerangka** (compile sukses, solc 0.8.38): `OriginEmitter` (emit `Ping`), `SentinelReactive` (subscribe + `react()` + `requestCallbackV_1_0`), `CallbackRecorder` (callback dijaga ganda `onlyServiceProvider` + `onlyCallbackSender`).
5. **Uji logika lokal 5/5 LULUS** (`forge test` dengan mock system contract).

## Keputusan Desain Fase 1

- **Origin dan destination sama-sama Ethereum Sepolia (11155111)** untuk loop kerangka: satu sesi faucet menutup semua kebutuhan. Kontrak chain-agnostic (chain id parameter constructor), jadi rencana Fase 2+ (origin/destination Base Sepolia) tidak berubah.
- Parameter resmi: Lasna chain **5318007**, RPC `https://lasna-rpc.rnk.dev/`; system contract `0x8888888888888888888888888888888888888888`; callback proxy Ethereum Sepolia `0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4`; kontrak faucet lREACT `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434` (metode `request(address)`).

## Kesimpulan Fase 1

Gerbang Fase 1 **LOLUS penuh**: loop reaktif dibuktikan on-chain dengan rantai hash lengkap dari pendanaan → swap → deploy → event → reaksi → callback, tanpa biaya riil, tanpa menyentuh mainnet, dan tanpa kredensial user. Bukti mentah: `phase1-run-output.txt` + hash-hash di tabel atas (dapat dicek ulang di explorer Sepolia/Lasna kapan pun).
