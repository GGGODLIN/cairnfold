package cairnfold

import (
	"crypto/merkle"
	"encoding/hex"
	"testing"
)

const (
	addrAlice = address("g104p7ldmmecudlgjt6q5ldwy25yj4t9lsxy7n9e")
	addrBob   = address("g1nngfjkxys8e9acal2pmk7k572gzq0fllahkyl5")
	addrOp    = address("g1st947gecd43mklw0l87x5f9x3a6fxen9m3hnu0")
)

// Independent recursive Tendermint Merkle oracle (used only in tests).
func oracleLargestPowerOfTwoLessThan(n int) int {
	k := 1
	for k*2 < n {
		k *= 2
	}
	return k
}

func oracleRoot(leaves [][]byte) []byte {
	switch len(leaves) {
	case 0:
		return nil
	case 1:
		return merkle.LeafHash(leaves[0])
	default:
		k := oracleLargestPowerOfTwoLessThan(len(leaves))
		left := oracleRoot(leaves[:k])
		right := oracleRoot(leaves[k:])
		return merkle.InnerHash(left, right)
	}
}

func oracleAunts(leaves [][]byte, idx int) []byte {
	if len(leaves) <= 1 {
		return nil
	}
	k := oracleLargestPowerOfTwoLessThan(len(leaves))
	if idx < k {
		sub := oracleAunts(leaves[:k], idx)
		right := oracleRoot(leaves[k:])
		return append(sub, right...)
	}
	sub := oracleAunts(leaves[k:], idx-k)
	left := oracleRoot(leaves[:k])
	return append(sub, left...)
}

func TestConcreteLeafEncodingAndRootMatchesOracle(t *testing.T) {
	leaf0, err := EncodeLeaf(1, addrAlice, 100, "builder")
	if err != nil {
		t.Fatalf("EncodeLeaf failed: %v", err)
	}
	wantLeaf0 := "cairnfold:v1|1|" + string(addrAlice) + "|100|builder"
	if string(leaf0) != wantLeaf0 {
		t.Fatalf("leaf mismatch: got %q want %q", string(leaf0), wantLeaf0)
	}

	leaf1, err := EncodeLeaf(1, addrBob, 250, "reviewer")
	if err != nil {
		t.Fatalf("EncodeLeaf 1 failed: %v", err)
	}
	leaf2, err := EncodeLeaf(1, addrOp, 500, "core_dev")
	if err != nil {
		t.Fatalf("EncodeLeaf 2 failed: %v", err)
	}

	members := []Member{
		{Addr: addrAlice, Weight: 100, Role: "builder"},
		{Addr: addrBob, Weight: 250, Role: "reviewer"},
		{Addr: addrOp, Weight: 500, Role: "core_dev"},
	}
	gotRoot, err := ComputeRoot(1, members)
	if err != nil {
		t.Fatalf("ComputeRoot failed: %v", err)
	}
	wantRoot := oracleRoot([][]byte{leaf0, leaf1, leaf2})
	if hex.EncodeToString(gotRoot) != hex.EncodeToString(wantRoot) {
		t.Fatalf("root mismatch: got %x want %x", gotRoot, wantRoot)
	}
}

func TestConcreteProofTokenRoundTripAndRejection(t *testing.T) {
	aunt := make([]byte, 32)
	for i := 0; i < 32; i++ {
		aunt[i] = byte(i + 1)
	}
	p := ProofToken{
		EpochID:  2,
		Index:    0,
		Total:    2,
		Addr:     addrAlice,
		Weight:   42,
		Role:     "early-bird",
		Aunts:    aunt,
		AuntsHex: hex.EncodeToString(aunt),
	}
	raw, err := EncodeProofToken(p)
	if err != nil {
		t.Fatalf("EncodeProofToken failed: %v", err)
	}
	dec, res := DecodeProofToken(raw)
	if !res.OK() {
		t.Fatalf("DecodeProofToken failed: %s (%s)", res.Code, res.Message)
	}
	if dec.EpochID != p.EpochID || dec.Index != p.Index || dec.Total != p.Total ||
		dec.Addr != p.Addr || dec.Weight != p.Weight || dec.Role != p.Role ||
		dec.AuntsHex != p.AuntsHex {
		t.Fatalf("decoded mismatch: got %+v want %+v", dec, p)
	}

	// Single-leaf (N=1) allows empty auntsHex.
	single := ProofToken{EpochID: 1, Index: 0, Total: 1, Addr: addrAlice, Weight: 10, Role: "solo"}
	rawSingle, err := EncodeProofToken(single)
	if err != nil {
		t.Fatalf("EncodeProofToken N=1 failed: %v", err)
	}
	if _, r := DecodeProofToken(rawSingle); !r.OK() {
		t.Fatalf("DecodeProofToken N=1 failed: %s (%s)", r.Code, r.Message)
	}

	// Invalid cases must return ERR_DECODE.
	badTokens := []string{
		"",
		"cf2:1:0:1:" + string(addrAlice) + ":10:solo:",
		"cf1:0:0:1:" + string(addrAlice) + ":10:solo:",
		"cf1:1:0:1:" + string(addrAlice) + ":0:solo:",
		"cf1:1:0:1:not-an-address:10:solo:",
		"cf1:1:0:1:" + string(addrAlice) + ":10:bad|role:",
		"cf1:1:0:2:" + string(addrAlice) + ":10:solo:",              // N=2 empty aunts
		"cf1:1:0:2:" + string(addrAlice) + ":10:solo:deadbeef",      // not 32-byte multiple
		"cf1:1:0:2:" + string(addrAlice) + ":10:solo:zzzz",          // non-hex
		"cf1:1:0:1:" + string(addrAlice) + ":10:solo:" + p.AuntsHex, // N=1 non-empty aunts
	}
	for _, bt := range badTokens {
		if _, r := DecodeProofToken(bt); r.Code != CodeErrDecode {
			t.Fatalf("expected ERR_DECODE for %q, got %s", bt, r.Code)
		}
	}
}

func TestConcreteVerifyTokenOrderedPipeline(t *testing.T) {
	members := []Member{
		{Addr: addrAlice, Weight: 100, Role: "builder"},
		{Addr: addrBob, Weight: 250, Role: "reviewer"},
		{Addr: addrOp, Weight: 500, Role: "core_dev"},
	}
	leaves := make([][]byte, len(members))
	for i, m := range members {
		b, err := EncodeLeaf(1, m.Addr, m.Weight, m.Role)
		if err != nil {
			t.Fatalf("EncodeLeaf %d failed: %v", i, err)
		}
		leaves[i] = b
	}
	root, err := ComputeRoot(1, members)
	if err != nil {
		t.Fatalf("ComputeRoot failed: %v", err)
	}
	epoch := &EpochView{
		ID:        1,
		Root:      root,
		RootHex:   hex.EncodeToString(root),
		LeafCount: len(members),
	}

	aunts0 := oracleAunts(leaves, 0)
	tok0, err := EncodeProofToken(ProofToken{
		EpochID:  1,
		Index:    0,
		Total:    3,
		Addr:     addrAlice,
		Weight:   100,
		Role:     "builder",
		Aunts:    aunts0,
		AuntsHex: hex.EncodeToString(aunts0),
	})
	if err != nil {
		t.Fatalf("EncodeProofToken failed: %v", err)
	}
	bm := make([]byte, BitmapSize(3))

	// Valid claim passes.
	if _, r := VerifyToken(tok0, addrAlice, epoch, bm); !r.OK() {
		t.Fatalf("expected OK, got %s: %s", r.Code, r.Message)
	}
	// Missing epoch -> ERR_EPOCH_NOT_FOUND.
	if _, r := VerifyToken(tok0, addrAlice, nil, bm); r.Code != CodeErrEpochNotFound {
		t.Fatalf("expected ERR_EPOCH_NOT_FOUND, got %s", r.Code)
	}
	// Caller mismatch -> ERR_CALLER_MISMATCH.
	if _, r := VerifyToken(tok0, addrBob, epoch, bm); r.Code != CodeErrCallerMismatch {
		t.Fatalf("expected ERR_CALLER_MISMATCH, got %s", r.Code)
	}
	// Total mismatch -> ERR_INDEX_OUT_OF_RANGE.
	wrongTotal := &EpochView{ID: 1, Root: root, LeafCount: 4}
	if _, r := VerifyToken(tok0, addrAlice, wrongTotal, bm); r.Code != CodeErrIndexOutOfRange {
		t.Fatalf("expected ERR_INDEX_OUT_OF_RANGE, got %s", r.Code)
	}
	// Already claimed -> ERR_ALREADY_CLAIMED.
	SetBit(bm, 0)
	if _, r := VerifyToken(tok0, addrAlice, epoch, bm); r.Code != CodeErrAlreadyClaimed {
		t.Fatalf("expected ERR_ALREADY_CLAIMED, got %s", r.Code)
	}
	// Tampered weight -> ERR_MERKLE_PROOF_MISMATCH on unclaimed bitmap.
	bmFresh := make([]byte, BitmapSize(3))
	tampered, _ := EncodeProofToken(ProofToken{
		EpochID:  1,
		Index:    0,
		Total:    3,
		Addr:     addrAlice,
		Weight:   101,
		Role:     "builder",
		Aunts:    aunts0,
		AuntsHex: hex.EncodeToString(aunts0),
	})
	if _, r := VerifyToken(tampered, addrAlice, epoch, bmFresh); r.Code != CodeErrMerkleProofMatch {
		t.Fatalf("expected ERR_MERKLE_PROOF_MISMATCH, got %s", r.Code)
	}
}

func TestConcreteBitmapSizeSetAndPopcount(t *testing.T) {
	if BitmapSize(0) != 0 || BitmapSize(-1) != 0 || BitmapSize(1) != 1 || BitmapSize(8) != 1 || BitmapSize(9) != 2 || BitmapSize(100) != 13 || BitmapSize(1000) != 125 {
		t.Fatalf("unexpected BitmapSize values")
	}
	// Regression from blind verification: prevent signed int overflow near MaxInt64.
	if got := BitmapSize(9223372036854775800); got != 1152921504606846975 {
		t.Fatalf("BitmapSize(MaxInt64-7) = %d, want 1152921504606846975", got)
	}
	if got := BitmapSize(9223372036854775801); got != 1152921504606846976 {
		t.Fatalf("BitmapSize(MaxInt64-6) = %d, want 1152921504606846976", got)
	}
	if got := BitmapSize(9223372036854775807); got != 1152921504606846976 {
		t.Fatalf("BitmapSize(MaxInt64) = %d, want 1152921504606846976", got)
	}
	bm := make([]byte, BitmapSize(10))
	if Popcount(bm) != 0 || IsBitSet(bm, 0) || IsBitSet(bm, 9) {
		t.Fatalf("expected empty bitmap")
	}
	if !SetBit(bm, 0) || SetBit(bm, 0) {
		t.Fatalf("expected first SetBit true and duplicate false")
	}
	if !SetBit(bm, 9) || !IsBitSet(bm, 9) || Popcount(bm) != 2 {
		t.Fatalf("expected bit 9 set and popcount 2, got %d", Popcount(bm))
	}
}
