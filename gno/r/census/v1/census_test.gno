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

func largestPow2(n int) int {
	k := 1
	for k*2 < n {
		k *= 2
	}
	return k
}

func simpleRoot(leaves [][]byte) []byte {
	if len(leaves) == 1 {
		return merkle.LeafHash(leaves[0])
	}
	k := largestPow2(len(leaves))
	return merkle.InnerHash(simpleRoot(leaves[:k]), simpleRoot(leaves[k:]))
}

func buildSimpleAunts(leaves [][]byte, idx int) []byte {
	if len(leaves) <= 1 {
		return nil
	}
	k := largestPow2(len(leaves))
	if idx < k {
		return append(buildSimpleAunts(leaves[:k], idx), simpleRoot(leaves[k:])...)
	}
	return append(buildSimpleAunts(leaves[k:], idx-k), simpleRoot(leaves[:k])...)
}

func testOracleAunts(epochID uint64, sorted []cairnfold.Member, idx int) []byte {
	leaves := make([][]byte, len(sorted))
	for i, m := range sorted {
		b, _ := cairnfold.EncodeLeaf(epochID, m.Addr, m.Weight, m.Role)
		leaves[i] = b
	}
	return buildSimpleAunts(leaves, idx)
}

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
	testing.SetOriginCaller(testAlice)
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
	snapURI := "https://raw.githubusercontent.com/GGGODLIN/cairnfold/main/snapshots/epoch-1.json"
	uassert.AbortsWithMessage(t, cur, "ERR_CANARY_INVALID: ERR_MERKLE_PROOF_MISMATCH: tendermint merkle proof verification failed", func() {
		ConfirmSnapshotVerified(cross(cur), 1, snapURI, "cf1:1:0:2:"+string(testAlice)+":999:builder:"+strings.Repeat("00", 32))
	})

	// Valid canary unlocks FoldRoster.
	sorted := []cairnfold.Member{
		{Addr: testAlice, Weight: 100, Role: "builder"},
		{Addr: testBob, Weight: 250, Role: "reviewer"},
	}
	aunts0 := testOracleAunts(1, sorted, 0)
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
