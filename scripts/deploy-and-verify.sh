#!/usr/bin/env bash
# CairnFold end-to-end deploy, storage-reclamation measurement, and verification script.
# Supports both local gnodev (MODE: DETERMINISTIC_REPLAY) and live Onyx onyx-1 (MODE: LIVE).
set -euo pipefail

NETWORK="dev"
KEYHOME="${CAIRNFOLD_KEYHOME:-$HOME/.cairnfold-onyx-keys}"
KEYPASS="${CAIRNFOLD_KEYPASS:-cairnfold-dev-only}"
GNOKEY="${GNOKEY_BIN:-$HOME/.gno/bin/gnokey}"
RECEIPT_OUT=""
OPERATOR_KEY="operator"
ALICE_KEY="alice"
BOB_KEY="bob"
SNAPSHOT_BASE_URL="${CAIRNFOLD_SNAPSHOT_BASE:-https://raw.githubusercontent.com/GGGODLIN/cairnfold/main/snapshots}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network) NETWORK="$2"; shift 2 ;;
    --out) RECEIPT_OUT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ "$NETWORK" == "onyx" ]]; then
  CHAIN_ID="onyx-1"
  REMOTE="https://rpc.onyx.testnets.gno.land:443"
  GNOWEB_BASE="https://onyx.testnets.gno.land"
  MODE_LABEL="LIVE"
  RECEIPT_OUT="${RECEIPT_OUT:-$REPO_ROOT/docs/onyx-e2e-receipts.json}"
elif [[ "$NETWORK" == "dev" ]]; then
  CHAIN_ID="dev"
  REMOTE="${GNODEV_RPC:-http://127.0.0.1:26657}"
  GNOWEB_BASE="${GNODEV_WEB:-http://127.0.0.1:8888}"
  MODE_LABEL="DETERMINISTIC_REPLAY"
  RECEIPT_OUT="${RECEIPT_OUT:-$REPO_ROOT/docs/local-gnodev-receipts.json}"
else
  echo "Unsupported --network: $NETWORK (expected dev or onyx)" >&2
  exit 2
fi

OP_ADDR="g1st947gecd43mklw0l87x5f9x3a6fxen9m3hnu0"
ALICE_ADDR="g104p7ldmmecudlgjt6q5ldwy25yj4t9lsxy7n9e"
BOB_ADDR="g1nngfjkxys8e9acal2pmk7k572gzq0fllahkyl5"

PKG_PURE="gno.land/p/${OP_ADDR}/cairnfold/v1"
PKG_CENSUS="gno.land/r/${OP_ADDR}/census/v1"
PKG_GATE="gno.land/r/${OP_ADDR}/gate/v1"

run_gnokey() {
  local out rc=0
  out="$(printf '%s\n' "$KEYPASS" | "$GNOKEY" "$@" -home "$KEYHOME" -insecure-password-stdin)" || rc=$?
  printf '%s\n' "$out"
  if (( rc != 0 )); then
    return "$rc"
  fi
  sleep 1.2
}

query_storage() {
  local pkg="$1"
  "$GNOKEY" query vm/qstorage -data "$pkg" -remote "$REMOTE" 2>&1
}

wait_package_live() {
  local pkg="$1"
  if [[ "$NETWORK" != "onyx" ]]; then
    return 0
  fi
  echo "Waiting for $pkg to transition from inert -> live on Onyx (120s wall-clock deadline)..."
  local deadline=$(( SECONDS + 120 ))
  while (( SECONDS < deadline )); do
    local meta
    meta="$(python3 - "$GNOKEY" "$pkg" "$REMOTE" <<'PY' || true
import subprocess, sys
try:
    out = subprocess.check_output(
        [sys.argv[1], "query", "vm/qpkgmeta_json", "-data", sys.argv[2], "-remote", sys.argv[3]],
        stderr=subprocess.STDOUT,
        timeout=15,
        text=True,
    )
    print(out)
except Exception as e:
    print(str(e))
PY
)"
    if echo "$meta" | grep -qi '"live"'; then
      echo "  $pkg is LIVE"
      return 0
    fi
    sleep 2
  done
  echo "Timed out after 120s waiting for $pkg to reach live state" >&2
  return 1
}

echo "=== CairnFold E2E ($MODE_LABEL / $CHAIN_ID) ==="
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# 0. On Onyx, verify operator balance and top up alice/bob if needed.
if [[ "$NETWORK" == "onyx" ]]; then
  echo "Checking Onyx balances..."
  BAL="$("$GNOKEY" query "bank/balances/${OP_ADDR}" -remote "$REMOTE" 2>&1)"
  echo "  operator: $BAL"
  if ! echo "$BAL" | grep -q 'ugnot'; then
    echo "Operator $OP_ADDR has 0 ugnot on Onyx. Fund via https://faucet.gno.land/ first." >&2
    exit 1
  fi
  for dst in "$ALICE_ADDR" "$BOB_ADDR"; do
    DBAL="$("$GNOKEY" query "bank/balances/${dst}" -remote "$REMOTE" 2>&1 || true)"
    if ! echo "$DBAL" | grep -q 'ugnot'; then
      echo "Funding $dst with 5000000ugnot from operator..."
      run_gnokey maketx send -to "$dst" -send 5000000ugnot -gas-fee 2000ugnot -gas-wanted 2000000 -chainid "$CHAIN_ID" -remote "$REMOTE" "$OPERATOR_KEY"
    fi
  done
fi

stage_pkg_no_tests() {
  local src="$1"
  local dst="$2"
  mkdir -p "$dst"
  cp "$src/gnomod.toml" "$dst/"
  for f in "$src"/*.gno; do
    case "$(basename "$f")" in
      *_test.gno) continue ;;
      *) cp "$f" "$dst/" ;;
    esac
  done
}

# 1. Deploy packages in dependency order: p/cairnfold/v1 -> r/census/v1 -> r/gate/v1
# Stage production-only files (excluding *_test.gno) to avoid unnecessary storage deposit and addpkg test-file quirks.
stage_pkg_no_tests "$REPO_ROOT/gno/p/cairnfold/v1" "$TMP_DIR/pkg_pure"
stage_pkg_no_tests "$REPO_ROOT/gno/r/census/v1" "$TMP_DIR/pkg_census"
stage_pkg_no_tests "$REPO_ROOT/gno/r/gate/v1" "$TMP_DIR/pkg_gate"

echo "Deploying $PKG_PURE..."
TX_DEPLOY_PURE="$(run_gnokey maketx addpkg -pkgpath "$PKG_PURE" -pkgdir "$TMP_DIR/pkg_pure" -gas-fee 120000ugnot -gas-wanted 120000000 -max-deposit 50000000ugnot -chainid "$CHAIN_ID" -remote "$REMOTE" "$OPERATOR_KEY")"
echo "$TX_DEPLOY_PURE"
wait_package_live "$PKG_PURE"

echo "Deploying $PKG_CENSUS..."
TX_DEPLOY_CENSUS="$(run_gnokey maketx addpkg -pkgpath "$PKG_CENSUS" -pkgdir "$TMP_DIR/pkg_census" -gas-fee 120000ugnot -gas-wanted 120000000 -max-deposit 50000000ugnot -chainid "$CHAIN_ID" -remote "$REMOTE" "$OPERATOR_KEY")"
echo "$TX_DEPLOY_CENSUS"
wait_package_live "$PKG_CENSUS"

echo "Deploying $PKG_GATE..."
TX_DEPLOY_GATE="$(run_gnokey maketx addpkg -pkgpath "$PKG_GATE" -pkgdir "$TMP_DIR/pkg_gate" -gas-fee 120000ugnot -gas-wanted 120000000 -max-deposit 50000000ugnot -chainid "$CHAIN_ID" -remote "$REMOTE" "$OPERATOR_KEY")"
echo "$TX_DEPLOY_GATE"
wait_package_live "$PKG_GATE"

# Checkpoint 1: Empty deployed realms
Q_CENSUS_EMPTY="$(query_storage "$PKG_CENSUS")"
Q_GATE_EMPTY="$(query_storage "$PKG_GATE")"

# 2. Seed 32-member synthetic roster from snapshots/epoch-1.json via SeedRosterBatch
CSV_BATCH="$(python3 - "$REPO_ROOT/snapshots/epoch-1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print("\n".join(f"{m['addr']},{m['weight']},{m['role']}" for m in d["members"]))
PY
)"

echo "Seeding 32-member Epoch 1 roster..."
TX_SEED_EP1="$(run_gnokey maketx call -pkgpath "$PKG_CENSUS" -func "SeedRosterBatch" -args "$CSV_BATCH" -gas-fee 120000ugnot -gas-wanted 120000000 -max-deposit 50000000ugnot -chainid "$CHAIN_ID" -remote "$REMOTE" "$OPERATOR_KEY")"
echo "$TX_SEED_EP1"

# Checkpoint 2: Roster seeded (pre-seal, full AVL live)
Q_CENSUS_SEEDED="$(query_storage "$PKG_CENSUS")"
Q_GATE_SEEDED="$(query_storage "$PKG_GATE")"

# 3. Seal Epoch 1
echo "Sealing Epoch 1..."
TX_SEAL_EP1="$(run_gnokey maketx call -pkgpath "$PKG_CENSUS" -func "SealEpoch" -args "Cohort 1 Snapshot (32 synthetic members)" -gas-fee 120000ugnot -gas-wanted 120000000 -max-deposit 20000000ugnot -chainid "$CHAIN_ID" -remote "$REMOTE" "$OPERATOR_KEY")"
echo "$TX_SEAL_EP1"
Q_CENSUS_SEALED="$(query_storage "$PKG_CENSUS")"
Q_GATE_SEALED="$(query_storage "$PKG_GATE")"

# 4. Export canonical snapshot from chain and rebuild proofs offline via cmd/cairnproof
echo "Exporting canonical snapshot from chain..."
EXPORTED_RAW="$("$GNOKEY" query vm/qeval -data "${PKG_CENSUS}.ExportCanonicalSnapshot(1)" -remote "$REMOTE")"
EXPORTED_RAW="$EXPORTED_RAW" python3 - "$TMP_DIR/epoch-1-exported.csv" <<'PY'
import os, re, sys
text = os.environ["EXPORTED_RAW"]
m = re.search(r'data:\s*\("(.*)"\s+string\)', text, re.S)
if not m:
    raise SystemExit("failed to parse ExportCanonicalSnapshot output: " + text)
raw = m.group(1).encode("utf-8").decode("unicode_escape")
open(sys.argv[1], "w", encoding="utf-8").write(raw)
PY

ONCHAIN_ROOT="$(python3 - "$TMP_DIR/epoch-1-exported.csv" <<'PY'
import re, sys
first = open(sys.argv[1], encoding="utf-8").readline()
m = re.search(r'root_hex=([0-9a-fA-F]{64})', first)
if not m:
    raise SystemExit("failed to parse root_hex from ExportCanonicalSnapshot header: " + first)
print(m.group(1).lower())
PY
)"

cd "$REPO_ROOT"
EP1_SNAP_URI="${SNAPSHOT_BASE_URL}/epoch-1.json"
if [[ "$NETWORK" == "onyx" ]]; then
  echo "Fetching published snapshot from $EP1_SNAP_URI to prove off-chain availability before FoldRoster..."
  curl -fsSL "$EP1_SNAP_URI" -o "$TMP_DIR/epoch-1-published.json"
  go run ./cmd/cairnproof build-proofs --input "$TMP_DIR/epoch-1-published.json" --expected-root "$ONCHAIN_ROOT" --out "$TMP_DIR/epoch-1-proofs.json"
else
  go run ./cmd/cairnproof build-proofs --input "$TMP_DIR/epoch-1-exported.csv" --expected-root "$ONCHAIN_ROOT" --out "$TMP_DIR/epoch-1-proofs.json"
fi

ALICE_TOKEN="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print([p["token"] for p in d["proofs"] if p["addr"]==sys.argv[2]][0])' "$TMP_DIR/epoch-1-proofs.json" "$ALICE_ADDR")"
BOB_TOKEN="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print([p["token"] for p in d["proofs"] if p["addr"]==sys.argv[2]][0])' "$TMP_DIR/epoch-1-proofs.json" "$BOB_ADDR")"
EP1_ROOT="$ONCHAIN_ROOT"

# 5. Confirm snapshot canary on-chain
echo "Confirming snapshot canary on-chain..."
TX_CONFIRM_EP1="$(run_gnokey maketx call -pkgpath "$PKG_CENSUS" -func "ConfirmSnapshotVerified" -args "1" -args "$EP1_SNAP_URI" -args "$ALICE_TOKEN" -gas-fee 60000ugnot -gas-wanted 60000000 -max-deposit 10000000ugnot -chainid "$CHAIN_ID" -remote "$REMOTE" "$OPERATOR_KEY")"
echo "$TX_CONFIRM_EP1"

# 6. FoldRoster: delete AVL entries and reclaim storage deposit!
echo "Folding Epoch 1 roster to reclaim storage deposit..."
TX_FOLD_EP1="$(run_gnokey maketx call -pkgpath "$PKG_CENSUS" -func "FoldRoster" -args "1" -gas-fee 120000ugnot -gas-wanted 120000000 -max-deposit 10000000ugnot -chainid "$CHAIN_ID" -remote "$REMOTE" "$OPERATOR_KEY")"
echo "$TX_FOLD_EP1"

# Checkpoint 3: Post-fold storage (both realms)
Q_CENSUS_FOLDED="$(query_storage "$PKG_CENSUS")"
Q_GATE_FOLDED="$(query_storage "$PKG_GATE")"

# 7. Seed & seal Epoch 2 (removing Alice, changing Bob weight) to prove Epoch 1 immutability!
CSV_BATCH_2="$(python3 - "$REPO_ROOT/snapshots/epoch-2.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print("\n".join(f"{m['addr']},{m['weight']},{m['role']}" for m in d["members"]))
PY
)"
echo "Seeding & sealing Epoch 2 (Alice removed, Bob weight changed)..."
TX_SEED_EP2="$(run_gnokey maketx call -pkgpath "$PKG_CENSUS" -func "SeedRosterBatch" -args "$CSV_BATCH_2" -gas-fee 60000ugnot -gas-wanted 60000000 -max-deposit 10000000ugnot -chainid "$CHAIN_ID" -remote "$REMOTE" "$OPERATOR_KEY")"
TX_SEAL_EP2="$(run_gnokey maketx call -pkgpath "$PKG_CENSUS" -func "SealEpoch" -args "Cohort 2 Snapshot (Alice removed)" -gas-fee 60000ugnot -gas-wanted 60000000 -max-deposit 10000000ugnot -chainid "$CHAIN_ID" -remote "$REMOTE" "$OPERATOR_KEY")"

# 8. Cross-account claims on gate/v1 for FOLDED Epoch 1 AFTER Epoch 2 removed Alice!
echo "Claiming Epoch 1 as Alice (post-fold, post-Epoch-2)..."
TX_CLAIM_ALICE="$(run_gnokey maketx call -pkgpath "$PKG_GATE" -func "Claim" -args "$ALICE_TOKEN" -gas-fee 60000ugnot -gas-wanted 60000000 -max-deposit 5000000ugnot -chainid "$CHAIN_ID" -remote "$REMOTE" "$ALICE_KEY")"
echo "$TX_CLAIM_ALICE"

echo "Claiming Epoch 1 as Bob..."
TX_CLAIM_BOB="$(run_gnokey maketx call -pkgpath "$PKG_GATE" -func "Claim" -args "$BOB_TOKEN" -gas-fee 60000ugnot -gas-wanted 60000000 -max-deposit 5000000ugnot -chainid "$CHAIN_ID" -remote "$REMOTE" "$BOB_KEY")"
echo "$TX_CLAIM_BOB"

# Checkpoint 4: Final post-claims storage (both realms, including live Epoch 2 active roster in census)
Q_CENSUS_FINAL="$(query_storage "$PKG_CENSUS")"
Q_GATE_AFTER_CLAIMS="$(query_storage "$PKG_GATE")"

# Query on-chain GetClaimStats(1) to confirm both claims persisted in gate/v1
Q_CLAIM_STATS_EP1="$("$GNOKEY" query vm/qeval -data "${PKG_GATE}.GetClaimStats(1)" -remote "$REMOTE")"
echo "GetClaimStats(1): $Q_CLAIM_STATS_EP1"

# 9. Verify negative rejections against BOTH real Claim entrypoint AND read-only CheckProof
#    including duplicate claim, wrong caller, and Epoch-2-only member (operator) forging Epoch 1!
OP_FORGED_EP1_TOKEN="$(python3 - "$TMP_DIR/epoch-1-proofs.json" "$OP_ADDR" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
parts = d["proofs"][1]["token"].split(":")
parts[4] = sys.argv[2]
print(":".join(parts))
PY
)"

NEG_DOUBLE="$(printf '%s\n' "$KEYPASS" | "$GNOKEY" maketx call -pkgpath "$PKG_GATE" -func "Claim" -args "$ALICE_TOKEN" -gas-fee 60000ugnot -gas-wanted 60000000 -chainid "$CHAIN_ID" -remote "$REMOTE" -home "$KEYHOME" -insecure-password-stdin "$ALICE_KEY" 2>&1 || true)"
NEG_CALLER="$(printf '%s\n' "$KEYPASS" | "$GNOKEY" maketx call -pkgpath "$PKG_GATE" -func "Claim" -args "$ALICE_TOKEN" -gas-fee 60000ugnot -gas-wanted 60000000 -chainid "$CHAIN_ID" -remote "$REMOTE" -home "$KEYHOME" -insecure-password-stdin "$BOB_KEY" 2>&1 || true)"
NEG_TAMPER="$(printf '%s\n' "$KEYPASS" | "$GNOKEY" maketx call -pkgpath "$PKG_GATE" -func "Claim" -args "$OP_FORGED_EP1_TOKEN" -gas-fee 60000ugnot -gas-wanted 60000000 -chainid "$CHAIN_ID" -remote "$REMOTE" -home "$KEYHOME" -insecure-password-stdin "$OPERATOR_KEY" 2>&1 || true)"

echo "Negative live Claim results:"
echo "  double-claim: $(echo "$NEG_DOUBLE" | tr '\n' ' ' | head -c 220)"
echo "  wrong-caller: $(echo "$NEG_CALLER" | tr '\n' ' ' | head -c 220)"
echo "  ep2-only-on-ep1: $(echo "$NEG_TAMPER" | tr '\n' ' ' | head -c 220)"

echo "$NEG_DOUBLE" | grep -q "ERR_ALREADY_CLAIMED"
echo "$NEG_CALLER" | grep -q "ERR_CALLER_MISMATCH"
echo "$NEG_TAMPER" | grep -q "ERR_MERKLE_PROOF_MISMATCH"

# 10. Check gnoweb HTTP 200 AND rendered HTML content markers
CENSUS_HTTP="$(curl -s -o "$TMP_DIR/census.html" -w '%{http_code}' "${GNOWEB_BASE}/r/${OP_ADDR}/census/v1")"
GATE_HTTP="$(curl -s -o "$TMP_DIR/gate.html" -w '%{http_code}' "${GNOWEB_BASE}/r/${OP_ADDR}/gate/v1")"
echo "gnoweb HTTP codes: census=$CENSUS_HTTP gate=$GATE_HTTP"
[[ "$CENSUS_HTTP" == "200" && "$GATE_HTTP" == "200" ]]
grep -q "Cohort 1 Snapshot" "$TMP_DIR/census.html"
grep -q "CairnFold" "$TMP_DIR/gate.html"
grep -q "Claim" "$TMP_DIR/gate.html"

# 11. Assert all storage/claim invariants and atomically write receipts JSON (env-passed, no code injection)
mkdir -p "$(dirname "$RECEIPT_OUT")"
export MODE_LABEL CHAIN_ID REMOTE GNOWEB_BASE OP_ADDR CENSUS_HTTP GATE_HTTP
export PKG_PURE PKG_CENSUS PKG_GATE EP1_ROOT EP1_SNAP_URI
export Q_CENSUS_EMPTY Q_GATE_EMPTY Q_CENSUS_SEEDED Q_GATE_SEEDED Q_CENSUS_SEALED Q_GATE_SEALED
export Q_CENSUS_FOLDED Q_GATE_FOLDED Q_CENSUS_FINAL Q_GATE_AFTER_CLAIMS Q_CLAIM_STATS_EP1
export TX_DEPLOY_PURE TX_DEPLOY_CENSUS TX_DEPLOY_GATE TX_SEED_EP1 TX_SEAL_EP1 TX_CONFIRM_EP1
export TX_FOLD_EP1 TX_SEED_EP2 TX_SEAL_EP2 TX_CLAIM_ALICE TX_CLAIM_BOB
export NEG_DOUBLE NEG_CALLER NEG_TAMPER

python3 - "$TMP_DIR/receipt.json" "$RECEIPT_OUT" <<'PY'
import json, os, re, sys

def parse_storage(txt, label):
    size_m = re.search(r"storage:\s*(\d+)", txt) or re.search(r"storage_size:\s*(\d+)", txt)
    dep_m = re.search(r"deposit:\s*(\d+)", txt) or re.search(r"storage_deposit:\s*(\d+)", txt)
    if not size_m or not dep_m:
        raise SystemExit(f"failed to parse storage checkpoint {label}: {txt!r}")
    return {
        "raw": txt.strip(),
        "bytes": int(size_m.group(1)),
        "deposit_ugnot": int(dep_m.group(1)),
    }

def parse_tx(txt, label):
    h = re.search(r"TX HASH:\s*(\S+)", txt)
    ht = re.search(r"HEIGHT:\s*(\d+)", txt)
    sd = re.search(r"STORAGE DELTA:\s*([-+]?\d+)", txt)
    sf = re.search(r"STORAGE FEE:\s*([-+]?\d+ugnot)", txt)
    sr = re.search(r"STORAGE REFUND:\s*([-+]?\d+ugnot)", txt)
    gu = re.search(r"GAS USED:\s*(\d+)", txt)
    if not h or not ht:
        raise SystemExit(f"missing tx hash/height for {label}: {txt!r}")
    return {
        "tx_hash": h.group(1),
        "height": int(ht.group(1)),
        "gas_used": int(gu.group(1)) if gu else None,
        "storage_delta_bytes": int(sd.group(1)) if sd else None,
        "storage_fee": sf.group(1) if sf else None,
        "storage_refund": sr.group(1) if sr else None,
    }

checkpoints = {
    "census_empty": parse_storage(os.environ["Q_CENSUS_EMPTY"], "census_empty"),
    "gate_empty": parse_storage(os.environ["Q_GATE_EMPTY"], "gate_empty"),
    "census_32_seeded": parse_storage(os.environ["Q_CENSUS_SEEDED"], "census_32_seeded"),
    "gate_32_seeded": parse_storage(os.environ["Q_GATE_SEEDED"], "gate_32_seeded"),
    "census_ep1_sealed": parse_storage(os.environ["Q_CENSUS_SEALED"], "census_ep1_sealed"),
    "gate_ep1_sealed": parse_storage(os.environ["Q_GATE_SEALED"], "gate_ep1_sealed"),
    "census_ep1_folded": parse_storage(os.environ["Q_CENSUS_FOLDED"], "census_ep1_folded"),
    "gate_ep1_folded": parse_storage(os.environ["Q_GATE_FOLDED"], "gate_ep1_folded"),
    "census_after_ep2_and_claims": parse_storage(os.environ["Q_CENSUS_FINAL"], "census_after_ep2_and_claims"),
    "gate_after_2_claims": parse_storage(os.environ["Q_GATE_AFTER_CLAIMS"], "gate_after_2_claims"),
}

txs = {
    "deploy_pure": parse_tx(os.environ["TX_DEPLOY_PURE"], "deploy_pure"),
    "deploy_census": parse_tx(os.environ["TX_DEPLOY_CENSUS"], "deploy_census"),
    "deploy_gate": parse_tx(os.environ["TX_DEPLOY_GATE"], "deploy_gate"),
    "seed_ep1": parse_tx(os.environ["TX_SEED_EP1"], "seed_ep1"),
    "seal_ep1": parse_tx(os.environ["TX_SEAL_EP1"], "seal_ep1"),
    "confirm_ep1": parse_tx(os.environ["TX_CONFIRM_EP1"], "confirm_ep1"),
    "fold_ep1": parse_tx(os.environ["TX_FOLD_EP1"], "fold_ep1"),
    "seed_ep2": parse_tx(os.environ["TX_SEED_EP2"], "seed_ep2"),
    "seal_ep2": parse_tx(os.environ["TX_SEAL_EP2"], "seal_ep2"),
    "claim_alice_ep1": parse_tx(os.environ["TX_CLAIM_ALICE"], "claim_alice_ep1"),
    "claim_bob_ep1": parse_tx(os.environ["TX_CLAIM_BOB"], "claim_bob_ep1"),
}

# Hard invariants: FoldRoster must refund real bytes, combined Epoch 1 footprint must shrink, and 2 claims must persist.
fold_delta = txs["fold_ep1"]["storage_delta_bytes"]
if fold_delta is None or fold_delta >= 0:
    raise SystemExit(f"FoldRoster did not reclaim storage bytes: {fold_delta}")

ep1_seeded_above_code = (
    (checkpoints["census_32_seeded"]["bytes"] - checkpoints["census_empty"]["bytes"])
    + (checkpoints["gate_32_seeded"]["bytes"] - checkpoints["gate_empty"]["bytes"])
)
ep1_folded_plus_claims_above_code = (
    (checkpoints["census_ep1_folded"]["bytes"] - checkpoints["census_empty"]["bytes"])
    + (checkpoints["gate_after_2_claims"]["bytes"] - checkpoints["gate_empty"]["bytes"])
)
if ep1_folded_plus_claims_above_code >= ep1_seeded_above_code:
    raise SystemExit(
        f"Expected combined Epoch 1 storage after fold+claims ({ep1_folded_plus_claims_above_code} B) "
        f"< seeded roster ({ep1_seeded_above_code} B)"
    )

stats_raw = os.environ["Q_CLAIM_STATS_EP1"].strip()
if "(2 int)" not in stats_raw and "ClaimedCount: 2" not in stats_raw:
    raise SystemExit(f"GetClaimStats(1) did not report 2 claims: {stats_raw}")

op_addr = os.environ["OP_ADDR"]
gnoweb_base = os.environ["GNOWEB_BASE"]
def parse_neg(txt, expected_code):
    m = re.search(rf"Data:\s*({re.escape(expected_code)}[^\n]*)", txt)
    gu = re.search(r"GAS USED:\s*(\d+)", txt)
    if not m:
        raise SystemExit(f"expected {expected_code} in negative Claim output: {txt[:300]!r}")
    return {
        "error": m.group(1).strip(),
        "gas_used": int(gu.group(1)) if gu else None,
    }

receipt = {
    "mode": os.environ["MODE_LABEL"],
    "chain_id": os.environ["CHAIN_ID"],
    "remote": os.environ["REMOTE"],
    "gnoweb_census_url": f"{gnoweb_base}/r/{op_addr}/census/v1",
    "gnoweb_gate_url": f"{gnoweb_base}/r/{op_addr}/gate/v1",
    "gnoweb_http_status": {
        "census": int(os.environ["CENSUS_HTTP"]),
        "gate": int(os.environ["GATE_HTTP"]),
    },
    "packages": {
        "cairnfold": os.environ["PKG_PURE"],
        "census": os.environ["PKG_CENSUS"],
        "gate": os.environ["PKG_GATE"],
    },
    "epoch_1_root_hex": os.environ["EP1_ROOT"],
    "epoch_1_snapshot_uri": os.environ["EP1_SNAP_URI"],
    "claim_stats_epoch_1_raw": stats_raw,
    "summary_metrics": {
        "ep1_seeded_state_above_code_bytes": ep1_seeded_above_code,
        "ep1_folded_plus_2_claims_above_code_bytes": ep1_folded_plus_claims_above_code,
        "ep1_net_reduction_pct": round((1.0 - ep1_folded_plus_claims_above_code / ep1_seeded_above_code) * 100.0, 2),
        "ep2_unfolded_active_roster_delta_bytes": (
            checkpoints["census_after_ep2_and_claims"]["bytes"] - checkpoints["census_ep1_folded"]["bytes"]
        ),
    },
    "storage_checkpoints": checkpoints,
    "transactions": txs,
    "negative_checks": {
        "double_claim": parse_neg(os.environ["NEG_DOUBLE"], "ERR_ALREADY_CLAIMED"),
        "wrong_caller": parse_neg(os.environ["NEG_CALLER"], "ERR_CALLER_MISMATCH"),
        "ep2_only_member_on_ep1": parse_neg(os.environ["NEG_TAMPER"], "ERR_MERKLE_PROOF_MISMATCH"),
    },
}

tmp_path, dst_path = sys.argv[1], sys.argv[2]
with open(tmp_path, "w", encoding="utf-8") as fh:
    json.dump(receipt, fh, indent=2)
    fh.write("\n")
os.replace(tmp_path, dst_path)
print("Wrote receipt atomically to", dst_path)
PY
