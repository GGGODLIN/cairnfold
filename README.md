# CairnFold

**Epoch-Sealed Tendermint Merkle Snapshots & Storage-Deposit Reclamation for Gno.land**

> Built for **Gnome Tavern Hackathon | Gno.land** (Onyx testnet `onyx-1`, Gno `v1.8.0` / `gno = "0.9"`).

## Why CairnFold?

On Gno.land, persistent realm state locks **`100 ugnot` per byte** as a storage deposit (`params/vm:p:storage_price`), refunded only when a realm genuinely deletes data from state. Builders maintaining on-chain rosters (DAO snapshots, allowlists, cohort distributions) hit three real failure modes:

1. **Perpetual storage lock**: Storing raw AVL rosters on-chain locks ~`2.58 KB` (`0.258 GNOT`) per member indefinitely — and naive 32-byte per-claim AVL nullifier maps in consumer realms re-lock comparable storage as members claim.
2. **Retroactive mutation**: When downstream realms read a producer realm's live roster directly, later updates silently rewrite historical eligibility.
3. **Proof lockout after deletion**: Simply deleting a roster after sealing a Merkle root leaves unexported members unable to reconstruct Tendermint `SimpleProof` siblings.

**CairnFold** solves all three using GnoVM's native `crypto/merkle` (`HashFromByteSlices` + `VerifySimpleProof`), cross-realm composition, and 1-bit-per-leaf bitmap nullifiers:

- **`gno/p/cairnfold/v1` (reusable pure package)**: Canonical `schemaID=1` leaf codec (`cairnfold:v1|<epoch>|<addr>|<weight>|<role>`), Tendermint big-endian framing (`EncodeByteSlices`), copy-pasteable single-string proof tokens (`cf1:...`), ordered 6-code verification (`VerifyToken`), and overflow-safe 1-bit epoch bitmap helpers (`BitmapSize`, `IsBitSet`, `SetBit`, `Popcount`).
- **`gno/r/census/v1` (producer realm)**: Owner-guarded `OPEN <-> FROZEN_SNAPSHOT` AVL roster. `SealEpoch` freezes an append-only immutable Tendermint Merkle root; `ExportCanonicalSnapshot` exports the exact sorted CSV; `ConfirmSnapshotVerified` verifies an off-chain-rebuilt canary `cf1:...` token **on-chain** before unlocking `FoldRoster`, which deletes the AVL tree to refund real `100 ugnot/byte` storage deposits and reopens `OPEN` for the next epoch.
- **`gno/r/gate/v1` (downstream consumer realm)**: Imports only `census/v1.GetEpoch(epochID)` (never trusting caller-supplied roots), binds direct user caller (`cur.Previous().Address() == leaf.Addr`), verifies historical epochs even **after `FoldRoster` and newer epochs**, and tracks claims in a **`ceil(N/8)`-byte Epoch Bitmap** (`4 B` for 32 members, `125 B` for 1,000 members).
- **`cmd/cairnproof` (offline Go CLI)**: Rebuilds Tendermint `SimpleProof` sibling hashes from any exported canonical snapshot, verifies exact root parity against chain state, and atomically writes per-member `cf1:...` tokens.

## Live Onyx Testnet (`onyx-1`) Deployment

All three packages are deployed on-chain on **Gno.land Onyx (`onyx-1`)** under `g1st947gecd43mklw0l87x5f9x3a6fxen9m3hnu0` (`docs/onyx-deploy-receipts.json`). Because Onyx runs `code_submission_policy = "inert"`, packages automatically pass through the Onyx Gno Package Approval Service (**GPAS**) with a 1-hour activation timelock per dependency layer:

| Package | On-Chain Path | Onyx Height | Tx Hash | GPAS Status |
| --- | --- | ---: | --- | --- |
| Pure package | `gno.land/p/g1st947gecd43mklw0l87x5f9x3a6fxen9m3hnu0/cairnfold/v1` | `1398065` | `RPSV+mLAldIVk9uLzA4Z78M6OjfW9Z8pJbQX2YfkCvw=` | [GPAS passed](https://gpas.onyx.testnets.gno.land/?path=gno.land/p/g1st947gecd43mklw0l87x5f9x3a6fxen9m3hnu0/cairnfold/v1) (auto-enabling `2026-11-25T10:10:02Z`) |
| Producer realm | [`gno.land/r/g1st947gecd43mklw0l87x5f9x3a6fxen9m3hnu0/census/v1`](https://onyx.testnets.gno.land/r/g1st947gecd43mklw0l87x5f9x3a6fxen9m3hnu0/census/v1) | `1398165` | `HtBqVSh2IpB8qeln5QIhV78HTvPQB/ZnYJHUfKbvdnk=` | [GPAS queue](https://gpas.onyx.testnets.gno.land/?path=gno.land/r/g1st947gecd43mklw0l87x5f9x3a6fxen9m3hnu0/census/v1) |
| Consumer realm | [`gno.land/r/g1st947gecd43mklw0l87x5f9x3a6fxen9m3hnu0/gate/v1`](https://onyx.testnets.gno.land/r/g1st947gecd43mklw0l87x5f9x3a6fxen9m3hnu0/gate/v1) | `1398167` | `A5ELiznsa3HXX/WRQGQS4et/xxGIKA21KYpk2XCCYH8=` | [GPAS queue](https://gpas.onyx.testnets.gno.land/?path=gno.land/r/g1st947gecd43mklw0l87x5f9x3a6fxen9m3hnu0/gate/v1) |

## Measured GnoVM `v1.8.0` Storage Reclamation (`32-Member Synthetic Roster`)

> Source: `docs/local-gnodev-receipts.json` (`MODE: DETERMINISTIC_REPLAY`, Gno `v1.8.0` `gnodev`, `storage_price = 100ugnot/byte`). Live Onyx `onyx-1` E2E receipts (`MODE: LIVE`) are captured via `./scripts/deploy-and-verify.sh --network onyx --skip-deploy` once all three GPAS layers finish their automatic activation timelock.

| Checkpoint | `census/v1` Storage | `gate/v1` Storage | Combined State Above Code | Deposit Delta (`100 ugnot/B`) |
| --- | ---: | ---: | ---: | ---: |
| 1. Empty deployed code | `21,202 B` | `11,035 B` | `0 B` | `0 ugnot` |
| 2. 32-member AVL seeded (`SeedRosterBatch`) | `103,691 B` | `11,035 B` | **`+82,489 B`** | **`+8,248,900 ugnot` (`8.25 GNOT`)** |
| 3. Epoch 1 sealed (`SealEpoch`) | `105,580 B` | `11,035 B` | `+84,378 B` | `+8,437,800 ugnot` |
| 4. Canary verified + **`FoldRoster(1)`** | **`23,237 B`** | `11,035 B` | **`+2,035 B`** | **`-8,246,600 ugnot` REFUNDED (`99.97%` of roster)** |
| 5. Post-fold Epoch 1 claims (`Alice` + `Bob`, isolated Epoch 1 footprint) | `23,237 B` | **`13,332 B`** | **`+4,332 B`** | **`94.75%` net Epoch 1 storage reduction across BOTH realms** |
| 6. After Epoch 2 seeded & sealed (unfolded 6-member active roster + 2 Epoch 1 claims) | `39,496 B` | `13,332 B` | `+20,591 B` | `+16,259 B` active Epoch 2 AVL roster (reclaimable via `FoldRoster(2)`) |

- 1st claim (`Alice`, index `0`) allocates the Epoch 1 bitmap struct (`+2,272 B`); 2nd claim (`Bob`, index `19`) adds only **`+25 B` (`2,500 ugnot`)**.
- Negative checks (live `Claim` entrypoint rejections):
  - Duplicate claim → `ERR_ALREADY_CLAIMED`
  - Wrong caller → `ERR_CALLER_MISMATCH`
  - Epoch-2-only member forging Epoch 1 → `ERR_MERKLE_PROOF_MISMATCH`

## Quick Start & Reproduction

### Prerequisites

- Go `1.24+`
- Gno toolchain `v1.8.0` (`gno`, `gnokey`, `gnodev`) and `GNOROOT` pointing to a `gnolang/gno` `v1.8.0` checkout

### 1. Run GnoVM Unit & Property-Based Tests (`P1..P5` + Oracle Calibration)

```bash
cd gno
GNOROOT="$HOME/.gno/src" gno lint ./p/cairnfold/v1 ./r/census/v1 ./r/gate/v1
GNOROOT="$HOME/.gno/src" gno test -v ./p/cairnfold/v1 ./r/census/v1 ./r/gate/v1
```

### 2. Run Offline Go CLI & Cross-Implementation GnoVM Parity (`N = 1, 2, 3, 7, 16, 32`)

```bash
go vet ./internal/proofgen ./cmd/cairnproof
go test -v ./internal/proofgen
go run ./cmd/cairnproof build-proofs --input snapshots/epoch-1.json --out /tmp/epoch-1-proofs.json
```

### 3. Deploy & Verify End-to-End (`dev` or Live Onyx `onyx-1`)

```bash
# Local gnodev replay (MODE: DETERMINISTIC_REPLAY)
./scripts/deploy-and-verify.sh --network dev

# Live Gno.land Onyx testnet (MODE: LIVE; requires funded operator key on onyx-1)
./scripts/deploy-and-verify.sh --network onyx
```

## Architecture & Repository Layout

```text
gno/
  gnowork.toml                 # Gno v1.8.0 workspace linking local p/ and r/ packages
  p/cairnfold/v1/              # Reusable pure package + P1..P4 PBT & oracle calibration
  r/census/v1/                 # Producer realm: OPEN <-> FROZEN_SNAPSHOT, SealEpoch, FoldRoster
  r/gate/v1/                   # Consumer realm: cross-realm GetEpoch, 1-bit bitmap Claim, P5 PBT
cmd/cairnproof/                # Pure Go offline Tendermint proof builder CLI
internal/proofgen/             # Snapshot parser, Tendermint SimpleProof builder, GnoVM parity tests
snapshots/                     # Synthetic 32-member Epoch 1 & 6-member Epoch 2 snapshots + proofs
scripts/deploy-and-verify.sh   # Automated deploy, vm/qstorage measurement, and gnoweb HTTP 200 E2E
docs/                          # Machine-readable E2E receipts (DETERMINISTIC_REPLAY / LIVE)
```

## License

MIT — see [LICENSE](LICENSE).
