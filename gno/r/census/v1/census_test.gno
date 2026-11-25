package census

import (
	"crypto/merkle"
	"encoding/hex"
	"strings"
	"testing"

	"gno.land/p/g1st947gecd43mklw0l87x5f9x3a6fxen9m3hnu0/cairnfold/v1"
	"gno.land/p/nt/uassert/v0"
)

const (
	testAlice = address("g104p7ldmmecudlgjt6q5ldwy25yj4t9lsxy7n9e")
	testBob   = address("g1nngfjkxys8e9acal2pmk7k572gzq0fllahkyl5")
	testOp    = DefaultOwner
)

func TestCensusLifecycleAndOwnerGuards(cur realm, t *testing.T) {
	// Non-owner rejected on every write entrypoint.
	testing.SetOriginCaller(testAlice)
	uassert.AbortsWithMessage(t, cur, "ERR_UNAUTHORIZED: caller is not census owner", func() {
		UpsertMember(cross(cur), testAlice, 100, "builder")
	})
	uassert.AbortsWithMessage(t, cur, "ERR_UNAUTHORIZED: caller is not census owner", func() {
		RemoveMember(cross(cur), testAlice)
	})
	uassert.AbortsWithMessage(t, cur, "ERR_UNAUTHORIZED: caller is not census owner", func() {
		SeedRosterBatch(cross(cur), string(testAlice)+",100,builder")
	})
	uassert.AbortsWithMessage(t, cur, "ERR_UNAUTHORIZED: caller is not census owner", func() {
		SealEpoch(cross(cur), "unauthorized")
	})

	// Owner cannot seal empty roster.
	testing.SetOriginCaller(testOp)
	uassert.AbortsWithMessage(t, cur, "ERR_EMPTY_ROSTER: cannot seal an empty roster", func() {
		SealEpoch(cross(cur), "Empty")
	})

	// Invalid SeedRosterBatch aborts atomically without mutating activeRoster.
	uassert.AbortsWithMessage(t, cur, "ERR_INVALID_BATCH: invalid weight", func() {
		SeedRosterBatch(cross(cur), string(testAlice)+",100,builder\n"+string(testBob)+",0,reviewer")
	})
	if ActiveRosterSize() != 0 {
		t.Fatalf("failed batch should not mutate activeRoster, got size %d", ActiveRosterSize())
	}

	// Owner seeds 2 members and seals Epoch 1.
	UpsertMember(cross(cur), testBob, 250, "reviewer")
	UpsertMember(cross(cur), testAlice, 100, "builder")
	if ActiveRosterSize() != 2 {
		t.Fatalf("expected ActiveRosterSize=2, got %d", ActiveRosterSize())
	}

	epID := SealEpoch(cross(cur), "Cohort 1 Snapshot")
	if epID != 1 || Stage() != StageFrozenSnapshot {
		t.Fatalf("expected epoch 1 and FROZEN_SNAPSHOT, got id=%d stage=%s", epID, Stage())
	}

	// Mutations blocked while FROZEN_SNAPSHOT; FoldRoster blocked before snapshot verified.
	uassert.AbortsWithMessage(t, cur, "ERR_STAGE_FROZEN: roster is frozen awaiting verified fold", func() {
		UpsertMember(cross(cur), testOp, 50, "core_dev")
	})
	uassert.AbortsWithMessage(t, cur, "ERR_STAGE_FROZEN: roster is frozen awaiting verified fold", func() {
		RemoveMember(cross(cur), testAlice)
	})
	uassert.AbortsWithMessage(t, cur, "ERR_SNAPSHOT_UNVERIFIED: call ConfirmSnapshotVerified before FoldRoster", func() {
		FoldRoster(cross(cur), 1)
	})

	// Non-owner blocked on ConfirmSnapshotVerified and FoldRoster too.
	snapURI := "https://raw.githubusercontent.com/GGGODLIN/cairnfold/main/snapshots/epoch-1.json"
	testing.SetOriginCaller(testAlice)
	uassert.AbortsWithMessage(t, cur, "ERR_UNAUTHORIZED: caller is not census owner", func() {
		ConfirmSnapshotVerified(cross(cur), 1, snapURI, "cf1:1:0:2:"+string(testAlice)+":100:builder:"+strings.Repeat("00", 32))
	})
	uassert.AbortsWithMessage(t, cur, "ERR_UNAUTHORIZED: caller is not census owner", func() {
		FoldRoster(cross(cur), 1)
	})
	testing.SetOriginCaller(testOp)

	// ExportCanonicalSnapshot returns canonical rows while frozen.
	snap := ExportCanonicalSnapshot(1)
	if !strings.Contains(snap, "index,addr,weight,role") || !strings.Contains(snap, string(testAlice)) {
		t.Fatalf("unexpected snapshot output: %q", snap)
	}

	// Tampered canary rejected on ConfirmSnapshotVerified.
	uassert.AbortsWithMessage(t, cur, "ERR_CANARY_INVALID: ERR_MERKLE_PROOF_MISMATCH: tendermint merkle proof verification failed", func() {
		ConfirmSnapshotVerified(cross(cur), 1, snapURI, "cf1:1:0:2:"+string(testAlice)+":999:builder:"+strings.Repeat("00", 32))
	})

	// Valid canary unlocks FoldRoster (in a 2-leaf tree, Alice's only sibling is Bob's leaf hash).
	bobLeaf, err := cairnfold.EncodeLeaf(1, testBob, 250, "reviewer")
	if err != nil {
		t.Fatalf("encode bob leaf: %v", err)
	}
	aunts0 := merkle.LeafHash(bobLeaf)
	canary, err := cairnfold.EncodeProofToken(cairnfold.ProofToken{
		EpochID:  1,
		Index:    0,
		Total:    2,
		Addr:     testAlice,
		Weight:   100,
		Role:     "builder",
		Aunts:    aunts0,
		AuntsHex: hex.EncodeToString(aunts0),
	})
	if err != nil {
		t.Fatalf("encode canary: %v", err)
	}
	ConfirmSnapshotVerified(cross(cur), 1, snapURI, canary)

	// FoldRoster clears AVL and returns to OPEN.
	removed := FoldRoster(cross(cur), 1)
	if removed != 2 || ActiveRosterSize() != 0 || Stage() != StageOpen {
		t.Fatalf("expected removed=2 size=0 OPEN, got removed=%d size=%d stage=%s", removed, ActiveRosterSize(), Stage())
	}

	// After fold, ExportCanonicalSnapshot points to SnapshotURI.
	postSnap := ExportCanonicalSnapshot(1)
	if !strings.Contains(postSnap, snapURI) {
		t.Fatalf("expected post-fold snapshot output to reference %q, got %q", snapURI, postSnap)
	}

	// Render includes mode banner, epoch table, and snapshot link.
	md := Render("")
	if !strings.Contains(md, "CairnFold") || !strings.Contains(md, "Cohort 1 Snapshot") || !strings.Contains(md, snapURI) || !strings.Contains(md, "DETERMINISTIC_REPLAY") {
		t.Fatalf("Render missing expected sections: %q", md)
	}
}

func TestCensusRegressionGuards(cur realm, t *testing.T) {
	testing.SetOriginCaller(testOp)

	// Regression: uint64 epochID > MaxInt64 must return not-found without negative slice index panic.
	if _, ok := GetEpoch(^uint64(0)); ok {
		t.Fatal("GetEpoch(MaxUint64) must return false")
	}
	if got := ExportCanonicalSnapshot(^uint64(0)); got != "ERR_EPOCH_NOT_FOUND" {
		t.Fatalf("ExportCanonicalSnapshot(MaxUint64) = %q, want ERR_EPOCH_NOT_FOUND", got)
	}

	// Regression: non-canonical uppercase Gno address rejected.
	upperAlice := address(strings.ToUpper(string(testAlice)))
	uassert.AbortsWithMessage(t, cur, "ERR_INVALID_MEMBER: invalid canonical lowercase gno address", func() {
		UpsertMember(cross(cur), upperAlice, 10, "builder")
	})

	// Regression: SealEpoch rejects roster whose weights would overflow uint64.
	UpsertMember(cross(cur), testAlice, ^uint64(0)-5, "builder")
	UpsertMember(cross(cur), testBob, 10, "reviewer")
	uassert.AbortsWithMessage(t, cur, "ERR_WEIGHT_OVERFLOW: sum of epoch weights exceeds uint64", func() {
		SealEpoch(cross(cur), "Overflow Cohort")
	})
	RemoveMember(cross(cur), testAlice)
	RemoveMember(cross(cur), testBob)
}
