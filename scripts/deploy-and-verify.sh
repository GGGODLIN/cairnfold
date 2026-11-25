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
    --keyhome) KEYHOME="$2"; shift 2 ;;
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
  local out
  out="$(printf '%s\n' "$KEYPASS" | "$GNOKEY" "$@" -home "$KEYHOME" -insecure-password-stdin)"
  printf '%s\n' "$out"
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
  echo "Waiting for $pkg to transition from inert -> live on Onyx..."
  for _ in $(seq 1 30); do
    local meta
    meta="$("$GNOKEY" query vm/qpkgmeta_json -data "$pkg" -remote "$REMOTE" 2>&1 || true)"
    if echo "$meta" | grep -qi '"live"'; then
      echo "  $pkg is LIVE"
      return 0
    fi
    sleep 2
  done
  echo "Timed out waiting for $pkg to reach live state" >&2
  return 1
}

extract_tx_hash() {
  grep -Eo 'TX HASH:[[:space:]]+[^[:space:]]+' | awk '{print $NF}' | tail -n 1
}

extract_height() {
  grep -Eo 'HEIGHT:[[:space:]]+[0-9]+' | awk '{print $NF}' | tail -n 1
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

# 3. Seal Epoch 1
echo "Sealing Epoch 1..."
TX_SEAL_EP1="$(run_gnokey maketx call -pkgpath "$PKG_CENSUS" -func "SealEpoch" -args "Cohort 1 Snapshot (32 synthetic members)" -gas-fee 120000ugnot -gas-wanted 120000000 -max-deposit 20000000ugnot -chainid "$CHAIN_ID" -remote "$REMOTE" "$OPERATOR_KEY")"
echo "$TX_SEAL_EP1"
Q_CENSUS_SEALED="$(query_storage "$PKG_CENSUS")"

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

cd "$REPO_ROOT"
go run ./cmd/cairnproof build-proofs --input "$TMP_DIR/epoch-1-exported.csv" --out "$TMP_DIR/epoch-1-proofs.json"

ALICE_TOKEN="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print([p["token"] for p in d["proofs"] if p["addr"]==sys.argv[2]][0])' "$TMP_DIR/epoch-1-proofs.json" "$ALICE_ADDR")"
BOB_TOKEN="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print([p["token"] for p in d["proofs"] if p["addr"]==sys.argv[2]][0])' "$TMP_DIR/epoch-1-proofs.json" "$BOB_ADDR")"
EP1_ROOT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["root_hex"])' "$TMP_DIR/epoch-1-proofs.json")"

# 5. Confirm snapshot canary on-chain
echo "Confirming snapshot canary on-chain..."
TX_CONFIRM_EP1="$(run_gnokey maketx call -pkgpath "$PKG_CENSUS" -func "ConfirmSnapshotVerified" -args "1" -args "${SNAPSHOT_BASE_URL}/epoch-1.json" -args "$ALICE_TOKEN" -gas-fee 60000ugnot -gas-wanted 60000000 -max-deposit 10000000ugnot -chainid "$CHAIN_ID" -remote "$REMOTE" "$OPERATOR_KEY")"
echo "$TX_CONFIRM_EP1"

# 6. FoldRoster: delete AVL entries and reclaim storage deposit!
echo "Folding Epoch 1 roster to reclaim storage deposit..."
TX_FOLD_EP1="$(run_gnokey maketx call -pkgpath "$PKG_CENSUS" -func "FoldRoster" -args "1" -gas-fee 120000ugnot -gas-wanted 120000000 -max-deposit 10000000ugnot -chainid "$CHAIN_ID" -remote "$REMOTE" "$OPERATOR_KEY")"
echo "$TX_FOLD_EP1"

# Checkpoint 3: Post-fold storage
Q_CENSUS_FOLDED="$(query_storage "$PKG_CENSUS")"

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

# Checkpoint 4: Post-claims gate storage
Q_GATE_AFTER_CLAIMS="$(query_storage "$PKG_GATE")"

# 9. Verify negative rejections via read-only CheckProof (zero gas, exact stage codes)
UNCLAIMED_TOKEN="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["proofs"][1]["token"])' "$TMP_DIR/epoch-1-proofs.json")"
UNCLAIMED_ADDR="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["proofs"][1]["addr"])' "$TMP_DIR/epoch-1-proofs.json")"
TAMPERED_TOKEN="$(python3 -c 'import sys; parts=sys.argv[1].split(":"); parts[5]=str(int(parts[5])+1); print(":".join(parts))' "$UNCLAIMED_TOKEN")"

NEG_DOUBLE="$("$GNOKEY" query vm/qeval -data "${PKG_GATE}.CheckProof(\"${ALICE_TOKEN}\", \"${ALICE_ADDR}\")" -remote "$REMOTE")"
NEG_CALLER="$("$GNOKEY" query vm/qeval -data "${PKG_GATE}.CheckProof(\"${ALICE_TOKEN}\", \"${BOB_ADDR}\")" -remote "$REMOTE")"
NEG_TAMPER="$("$GNOKEY" query vm/qeval -data "${PKG_GATE}.CheckProof(\"${TAMPERED_TOKEN}\", \"${UNCLAIMED_ADDR}\")" -remote "$REMOTE")"

echo "Negative CheckProof results:"
echo "  double-claim: $NEG_DOUBLE"
echo "  wrong-caller: $NEG_CALLER"
echo "  tampered:     $NEG_TAMPER"

echo "$NEG_DOUBLE" | grep -q "ERR_ALREADY_CLAIMED"
echo "$NEG_CALLER" | grep -q "ERR_CALLER_MISMATCH"
echo "$NEG_TAMPER" | grep -q "ERR_MERKLE_PROOF_MISMATCH"

# 10. Check gnoweb HTTP 200
CENSUS_HTTP="$(curl -s -o /dev/null -w '%{http_code}' "${GNOWEB_BASE}/r/${OP_ADDR}/census/v1")"
GATE_HTTP="$(curl -s -o /dev/null -w '%{http_code}' "${GNOWEB_BASE}/r/${OP_ADDR}/gate/v1")"
echo "gnoweb HTTP codes: census=$CENSUS_HTTP gate=$GATE_HTTP"
[[ "$CENSUS_HTTP" == "200" && "$GATE_HTTP" == "200" ]]

# 11. Atomically write receipts JSON
mkdir -p "$(dirname "$RECEIPT_OUT")"
python3 - "$TMP_DIR/receipt.json" "$RECEIPT_OUT" <<PY
import json, os, re, sys

def parse_storage(txt):
    size_m = re.search(r"storage:\s*(\d+)", txt)
    dep_m = re.search(r"deposit:\s*(\d+)", txt)
    if not size_m:
        size_m = re.search(r"storage_size:\s*(\d+)", txt)
    if not dep_m:
        dep_m = re.search(r"storage_deposit:\s*(\d+)", txt)
    return {
        "raw": txt.strip(),
        "bytes": int(size_m.group(1)) if size_m else None,
        "deposit_ugnot": int(dep_m.group(1)) if dep_m else None,
    }

def parse_tx(txt):
    h = re.search(r"TX HASH:\s*(\S+)", txt)
    ht = re.search(r"HEIGHT:\s*(\d+)", txt)
    sd = re.search(r"STORAGE DELTA:\s*([-+]?\d+)", txt)
    sf = re.search(r"STORAGE FEE:\s*([-+]?\d+ugnot)", txt)
    sr = re.search(r"STORAGE REFUND:\s*([-+]?\d+ugnot)", txt)
    gu = re.search(r"GAS USED:\s*(\d+)", txt)
    return {
        "tx_hash": h.group(1) if h else None,
        "height": int(ht.group(1)) if ht else None,
        "gas_used": int(gu.group(1)) if gu else None,
        "storage_delta_bytes": int(sd.group(1)) if sd else None,
        "storage_fee": sf.group(1) if sf else None,
        "storage_refund": sr.group(1) if sr else None,
    }

receipt = {
    "mode": "${MODE_LABEL}",
    "chain_id": "${CHAIN_ID}",
    "remote": "${REMOTE}",
    "gnoweb_census_url": "${GNOWEB_BASE}/r/${OP_ADDR}/census/v1",
    "gnoweb_gate_url": "${GNOWEB_BASE}/r/${OP_ADDR}/gate/v1",
    "gnoweb_http_status": {"census": int("${CENSUS_HTTP}"), "gate": int("${GATE_HTTP}")},
    "packages": {
        "cairnfold": "${PKG_PURE}",
        "census": "${PKG_CENSUS}",
        "gate": "${PKG_GATE}",
    },
    "epoch_1_root_hex": "${EP1_ROOT}",
    "storage_checkpoints": {
        "census_empty": parse_storage("""${Q_CENSUS_EMPTY}"""),
        "census_32_seeded": parse_storage("""${Q_CENSUS_SEEDED}"""),
        "census_ep1_sealed": parse_storage("""${Q_CENSUS_SEALED}"""),
        "census_ep1_folded": parse_storage("""${Q_CENSUS_FOLDED}"""),
        "gate_empty": parse_storage("""${Q_GATE_EMPTY}"""),
        "gate_after_2_claims": parse_storage("""${Q_GATE_AFTER_CLAIMS}"""),
    },
    "transactions": {
        "deploy_pure": parse_tx("""${TX_DEPLOY_PURE}"""),
        "deploy_census": parse_tx("""${TX_DEPLOY_CENSUS}"""),
        "deploy_gate": parse_tx("""${TX_DEPLOY_GATE}"""),
        "seed_ep1": parse_tx("""${TX_SEED_EP1}"""),
        "seal_ep1": parse_tx("""${TX_SEAL_EP1}"""),
        "confirm_ep1": parse_tx("""${TX_CONFIRM_EP1}"""),
        "fold_ep1": parse_tx("""${TX_FOLD_EP1}"""),
        "seed_ep2": parse_tx("""${TX_SEED_EP2}"""),
        "seal_ep2": parse_tx("""${TX_SEAL_EP2}"""),
        "claim_alice_ep1": parse_tx("""${TX_CLAIM_ALICE}"""),
        "claim_bob_ep1": parse_tx("""${TX_CLAIM_BOB}"""),
    },
    "negative_checks": {
        "double_claim": """${NEG_DOUBLE}""".strip(),
        "wrong_caller": """${NEG_CALLER}""".strip(),
        "tampered_leaf": """${NEG_TAMPER}""".strip(),
    },
}

tmp_path, dst_path = sys.argv[1], sys.argv[2]
with open(tmp_path, "w", encoding="utf-8") as fh:
    json.dump(receipt, fh, indent=2)
    fh.write("\n")
os.replace(tmp_path, dst_path)
print("Wrote receipt atomically to", dst_path)
PY
