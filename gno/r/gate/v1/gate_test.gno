package gate

import (
	"crypto/merkle"
	"encoding/hex"
	"strings"
	"testing"

	"gno.land/p/g1st947gecd43mklw0l87x5f9x3a6fxen9m3hnu0/cairnfold/v1"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/g1st947gecd43mklw0l87x5f9x3a6fxen9m3hnu0/census/v1"
)

const (
	gateAlice = address("g104p7ldmmecudlgjt6q5ldwy25yj4t9lsxy7n9e")
	gateBob   = address("g1nngfjkxys8e9acal2pmk7k572gzq0fllahkyl5")
	gateOp    = census.DefaultOwner
)

func gateLargestPow2(n int) int {
	k := 1
	for k*2 < n {
		k *= 2
	}
	return k
}

func gateSimpleRoot(leaves [][]byte) []byte {
	if len(leaves) == 1 {
		return merkle.LeafHash(leaves[0])
	}
	k := gateLargestPow2(len(leaves))
	return merkle.InnerHash(gateSimpleRoot(leaves[:k]), gateSimpleRoot(leaves[k:]))
}

func gateBuildAunts(leaves [][]byte, idx int) []byte {
	if len(leaves) <= 1 {
		return nil
	}
	k := gateLargestPow2(len(leaves))
	if idx < k {
		return append(gateBuildAunts(leaves[:k], idx), gateSimpleRoot(leaves[k:])...)
	}
	return append(gateBuildAunts(leaves[k:], idx-k), gateSimpleRoot(leaves[:k])...)
}

func makeTokenForTest(t *testing.T, epochID uint64, sorted []cairnfold.Member, idx int) string {
	t.Helper()
	leaves := make([][]byte, len(sorted))
	for i, m := range sorted {
		b, err := cairnfold.EncodeLeaf(epochID, m.Addr, m.Weight, m.Role)
		if err != nil {
			t.Fatalf("EncodeLeaf: %v", err)
		}
		leaves[i] = b
	}
	aunts := gateBuildAunts(leaves, idx)
	tok, err := cairnfold.EncodeProofToken(cairnfold.ProofToken{
		EpochID:  epochID,
		Index:    idx,
		Total:    len(sorted),
		Addr:     sorted[idx].Addr,
		Weight:   sorted[idx].Weight,
		Role:     sorted[idx].Role,
		Aunts:    aunts,
		AuntsHex: hex.EncodeToString(aunts),
	})
	if err != nil {
		t.Fatalf("EncodeProofToken: %v", err)
	}
	return tok
}

func TestGatePostFoldCrossEpochClaimAndBitmap(cur realm, t *testing.T) {
	// Seed Epoch 1 (alice + bob), seal, verify snapshot, and fold roster.
	testing.SetOriginCaller(gateOp)
	census.UpsertMember(cross(cur), gateAlice, 100, "builder")
	census.UpsertMember(cross(cur), gateBob, 250, "reviewer")
	ep1 := census.SealEpoch(cross(cur), "Epoch One")

	sorted1 := []cairnfold.Member{
		{Addr: gateAlice, Weight: 100, Role: "builder"},
		{Addr: gateBob, Weight: 250, Role: "reviewer"},
	}
	tokAliceEp1 := makeTokenForTest(t, ep1, sorted1, 0)
	tokBobEp1 := makeTokenForTest(t, ep1, sorted1, 1)

	census.ConfirmSnapshotVerified(cross(cur), ep1, "https://raw.githubusercontent.com/GGGODLIN/cairnfold/main/snapshots/epoch-1.json", tokAliceEp1)
	census.FoldRoster(cross(cur), ep1)

	// Start Epoch 2 with modified weights + operator added (alice removed!) to prove Epoch 1 isolation.
	census.UpsertMember(cross(cur), gateBob, 999, "core_dev")
	census.UpsertMember(cross(cur), gateOp, 500, "core_dev")
	ep2 := census.SealEpoch(cross(cur), "Epoch Two")
	if ep2 != ep1+1 {
		t.Fatalf("expected sequential epoch %d, got %d", ep1+1, ep2)
	}

	// Wrong caller trying Alice's Epoch 1 token -> ERR_CALLER_MISMATCH.
	testing.SetOriginCaller(gateBob)
	uassert.AbortsWithMessage(t, cur, cairnfold.CodeErrCallerMismatch+": caller does not match proof address", func() {
		Claim(cross(cur), tokAliceEp1)
	})

	// Alice claims Epoch 1 AFTER FoldRoster AND AFTER Epoch 2 removed her!
	testing.SetOriginCaller(gateAlice)
	if res := CheckProof(tokAliceEp1, gateAlice); !strings.HasPrefix(res, cairnfold.CodeOK) {
		t.Fatalf("expected CheckProof OK, got %q", res)
	}
	Claim(cross(cur), tokAliceEp1)

	stats := GetClaimStats(ep1)
	if stats.LeafCount != 2 || stats.BitmapBytes != 1 || stats.ClaimedCount != 1 || stats.TotalWeightClaimed != 100 {
		t.Fatalf("unexpected ClaimStats: %+v", stats)
	}

	// Duplicate claim -> ERR_ALREADY_CLAIMED.
	uassert.AbortsWithMessage(t, cur, cairnfold.CodeErrAlreadyClaimed+": leaf index already claimed for this epoch", func() {
		Claim(cross(cur), tokAliceEp1)
	})

	// Epoch-2-only member (gateOp) forging Epoch 1 claim -> ERR_MERKLE_PROOF_MISMATCH.
	testing.SetOriginCaller(gateOp)
	fakeEp1ForOp := makeTokenForTest(t, ep1, []cairnfold.Member{
		{Addr: gateBob, Weight: 999, Role: "core_dev"},
		{Addr: gateOp, Weight: 500, Role: "core_dev"},
	}, 1)
	uassert.AbortsWithMessage(t, cur, cairnfold.CodeErrMerkleProofMatch+": tendermint merkle proof verification failed", func() {
		Claim(cross(cur), fakeEp1ForOp)
	})

	// Bob still claims Epoch 1 cleanly too.
	testing.SetOriginCaller(gateBob)
	Claim(cross(cur), tokBobEp1)
	stats2 := GetClaimStats(ep1)
	if stats2.ClaimedCount != 2 || stats2.TotalWeightClaimed != 350 || stats2.BitmapBytes != 1 {
		t.Fatalf("unexpected ClaimStats after Bob: %+v", stats2)
	}

	// Render includes gno-form, gnokey command, bitmap stats, and mode label.
	md := Render("")
	if !strings.Contains(md, "<gno-form") || !strings.Contains(md, "onyx-1") || !strings.Contains(md, "Bitmap") || !strings.Contains(md, "DETERMINISTIC_REPLAY") {
		t.Fatalf("gate Render missing expected UI elements: %q", md)
	}
}
