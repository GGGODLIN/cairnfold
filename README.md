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

## Measured GnoVM `v1.8.0` Storage Reclamation (`32-Member Synthetic Roster`)

> Source: `docs/local-gnodev-receipts.json` (`MODE: DETERMINISTIC_REPLAY`, Gno `v1.8.0` `gnodev`, `storage_price = 100ugnot/byte`). Live Onyx `onyx-1` receipts (`MODE: LIVE`) will be recorded in `docs/onyx-e2e-receipts.json` upon testnet deployment via `scripts/deploy-and-verify.sh --network onyx`.

| Checkpoint | `census/v1` Storage | `gate/v1` Storage | Combined State Above Code | Deposit Delta (`100 ugnot/B`) |
| --- | ---: | ---: | ---: | ---: |
| 1. Empty deployed code | `21,077 B` | `10,933 B` | `0 B` | `0 ugnot` |
| 2. 32-member AVL seeded (`SeedRosterBatch`) | `103,569 B` | `10,933 B` | **`+82,492 B`** | **`+8,249,200 ugnot` (`8.25 GNOT`)** |
| 3. Epoch 1 sealed (`SealEpoch`) | `105,607 B` | `10,933 B` | `+84,530 B` | `+8,453,000 ugnot` |
| 4. Canary verified + **`FoldRoster(1)`** | **`23,250 B`** | `10,933 B` | **`+2,173 B`** | **`-8,248,000 ugnot` REFUNDED (`99.99%` of roster)** |
| 5. Post-fold Epoch 1 claims (`Alice` + `Bob` after Epoch 2 removed Alice) | `23,250 B` | **`13,268 B`** | **`+4,508 B`** | **`94.5%` net storage reduction across BOTH realms** |

- 1st claim (`Alice`, index `0`) allocates the Epoch 1 bitmap struct (`+2,310 B`); 2nd claim (`Bob`, index `19`) adds only **`+25 B` (`2,500 ugnot`)**.
- Negative checks (`CheckProof` read-only `vm/qeval`):
  - Duplicate claim → `ERR_ALREADY_CLAIMED`
  - Wrong caller → `ERR_CALLER_MISMATCH`
  - Tampered leaf weight → `ERR_MERKLE_PROOF_MISMATCH`

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
