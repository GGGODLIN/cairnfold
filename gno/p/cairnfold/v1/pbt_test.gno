package cairnfold

import (
	"crypto/merkle"
	"encoding/hex"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
)

// Deterministic PRNG for reproducible GnoVM property-based tests.
type lcg struct{ state uint64 }

func newLCG(seed uint64) *lcg { return &lcg{state: seed} }

func (r *lcg) next() uint64 {
	r.state = r.state*6364136223846793005 + 1442695040888963407
	return r.state
}

func (r *lcg) intn(n int) int {
	return int(r.next() % uint64(n))
}

func makeSyntheticMembers(count int, seed uint64) []Member {
	rng := newLCG(seed)
	roles := []string{"builder", "reviewer", "core_dev", "early-bird", "auditor_1"}
	seen := make(map[string]bool, count)
	out := make([]Member, 0, count)
	idx := 0
	for len(out) < count {
		addr := testutils.TestAddress("cf_member_" + hex.EncodeToString([]byte{byte(seed), byte(idx >> 8), byte(idx)}))
		idx++
		if seen[string(addr)] {
			continue
		}
		seen[string(addr)] = true
		out = append(out, Member{
			Addr:   addr,
			Weight: uint64(rng.intn(10000) + 1),
			Role:   roles[rng.intn(len(roles))],
		})
	}
	return out
}

func sortMembersCanonical(in []Member) []Member {
	cp := make([]Member, len(in))
	copy(cp, in)
	for i := 1; i < len(cp); i++ {
		cur := cp[i]
		j := i - 1
		for j >= 0 && string(cp[j].Addr) > string(cur.Addr) {
			cp[j+1] = cp[j]
			j--
		}
		cp[j+1] = cur
	}
	return cp
}

// Role 2 — P1: Order-Independent Root Determinism (N = 1..64 across random AVL insertion orders).
func checkP1OrderIndependentRoot(epochID uint64, members []Member, seed uint64) bool {
	rng := newLCG(seed)
	perm := make([]Member, len(members))
	copy(perm, members)
	for i := len(perm) - 1; i > 0; i-- {
		j := rng.intn(i + 1)
		perm[i], perm[j] = perm[j], perm[i]
	}

	tree := avl.NewTree()
	for _, m := range perm {
		tree.Set(string(m.Addr), m)
	}
	fromAVL := make([]Member, 0, tree.Size())
	tree.Iterate("", "", func(_ string, v interface{}) bool {
		fromAVL = append(fromAVL, v.(Member))
		return false
	})

	gotRoot, err := ComputeRoot(epochID, fromAVL)
	if err != nil {
		return false
	}

	// Independent oracle: sort directly + recursive LeafHash/InnerHash.
	sorted := sortMembersCanonical(members)
	leaves := make([][]byte, len(sorted))
	for i, m := range sorted {
		leaf, err := EncodeLeaf(epochID, m.Addr, m.Weight, m.Role)
		if err != nil {
			return false
		}
		leaves[i] = leaf
	}
	wantRoot := oracleRoot(leaves)
	return hex.EncodeToString(gotRoot) == hex.EncodeToString(wantRoot)
}

func TestPBT_P1_OrderIndependentRootDeterminism(t *testing.T) {
	sizes := []int{1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 32, 64}
	for idx, n := range sizes {
		members := makeSyntheticMembers(n, uint64(100+idx))
		for trial := 0; trial < 5; trial++ {
			if !checkP1OrderIndependentRoot(uint64(trial+1), members, uint64(1000+idx*17+trial)) {
				t.Fatalf("P1 failed for n=%d trial=%d", n, trial)
			}
		}
	}
}

// Role 2 — P2: Token Round-Trip Injectivity.
func checkP2TokenRoundTrip(p ProofToken) bool {
	raw, err := EncodeProofToken(p)
	if err != nil {
		return false
	}
	dec, res := DecodeProofToken(raw)
	if !res.OK() {
		return false
	}
	raw2, err := EncodeProofToken(dec)
	if err != nil {
		return false
	}
	return raw == raw2 &&
		dec.EpochID == p.EpochID &&
		dec.Index == p.Index &&
		dec.Total == p.Total &&
		dec.Addr == p.Addr &&
		dec.Weight == p.Weight &&
		dec.Role == p.Role &&
		dec.AuntsHex == hex.EncodeToString(p.Aunts)
}

func TestPBT_P2_TokenRoundTripInjectivity(t *testing.T) {
	rng := newLCG(20261125)
	for _, n := range []int{1, 2, 3, 7, 16, 33} {
		members := sortMembersCanonical(makeSyntheticMembers(n, uint64(200+n)))
		leaves := make([][]byte, n)
		for i, m := range members {
			leaves[i], _ = EncodeLeaf(3, m.Addr, m.Weight, m.Role)
		}
		for i := 0; i < n; i++ {
			aunts := oracleAunts(leaves, i)
			p := ProofToken{
				EpochID:  uint64(rng.intn(50) + 1),
				Index:    i,
				Total:    n,
				Addr:     members[i].Addr,
				Weight:   members[i].Weight,
				Role:     members[i].Role,
				Aunts:    aunts,
				AuntsHex: hex.EncodeToString(aunts),
			}
			if !checkP2TokenRoundTrip(p) {
				t.Fatalf("P2 round-trip failed for n=%d i=%d", n, i)
			}
		}
	}
}

// Role 2 — P3: Merkle Completeness & Single-Bit Soundness.
func checkP3CompletenessAndSoundness(epochID uint64, members []Member) bool {
	sorted := sortMembersCanonical(members)
	leaves := make([][]byte, len(sorted))
	for i, m := range sorted {
		b, err := EncodeLeaf(epochID, m.Addr, m.Weight, m.Role)
		if err != nil {
			return false
		}
		leaves[i] = b
	}
	root, err := ComputeRoot(epochID, sorted)
	if err != nil {
		return false
	}
	epoch := &EpochView{ID: epochID, Root: root, RootHex: hex.EncodeToString(root), LeafCount: len(sorted)}

	for i, m := range sorted {
		aunts := oracleAunts(leaves, i)
		p := ProofToken{
			EpochID:  epochID,
			Index:    i,
			Total:    len(sorted),
			Addr:     m.Addr,
			Weight:   m.Weight,
			Role:     m.Role,
			Aunts:    aunts,
			AuntsHex: hex.EncodeToString(aunts),
		}
		raw, err := EncodeProofToken(p)
		if err != nil {
			return false
		}
		bm := make([]byte, BitmapSize(len(sorted)))
		if _, res := VerifyToken(raw, m.Addr, epoch, bm); !res.OK() {
			return false
		}

		// Flip 1 bit in root -> must fail.
		badRoot := make([]byte, 32)
		copy(badRoot, root)
		badRoot[i%32] ^= 0x01
		badEpoch := &EpochView{ID: epochID, Root: badRoot, LeafCount: len(sorted)}
		if _, res := VerifyToken(raw, m.Addr, badEpoch, bm); res.OK() {
			return false
		}

		// Flip weight -> must fail.
		pBadWeight := p
		pBadWeight.Weight = m.Weight + 1
		rawBadWeight, _ := EncodeProofToken(pBadWeight)
		if _, res := VerifyToken(rawBadWeight, m.Addr, epoch, bm); res.OK() {
			return false
		}

		// Flip role -> must fail.
		pBadRole := p
		pBadRole.Role = m.Role + "_x"
		rawBadRole, _ := EncodeProofToken(pBadRole)
		if _, res := VerifyToken(rawBadRole, m.Addr, epoch, bm); res.OK() {
			return false
		}

		// Flip epochID -> must fail.
		pBadEpoch := p
		pBadEpoch.EpochID = epochID + 1
		rawBadEpoch, _ := EncodeProofToken(pBadEpoch)
		if _, res := VerifyToken(rawBadEpoch, m.Addr, epoch, bm); res.OK() {
			return false
		}

		// Flip total -> must fail.
		pBadTotal := p
		pBadTotal.Total = len(sorted) + 1
		if len(pBadTotal.Aunts) == 0 {
			pBadTotal.Aunts = make([]byte, 32)
			pBadTotal.AuntsHex = hex.EncodeToString(pBadTotal.Aunts)
		}
		rawBadTotal, _ := EncodeProofToken(pBadTotal)
		if _, res := VerifyToken(rawBadTotal, m.Addr, epoch, bm); res.OK() {
			return false
		}

		// Flip index and swap addr (when total > 1) -> must fail.
		if len(sorted) > 1 {
			pBadIndex := p
			pBadIndex.Index = (i + 1) % len(sorted)
			rawBadIndex, _ := EncodeProofToken(pBadIndex)
			if _, res := VerifyToken(rawBadIndex, m.Addr, epoch, bm); res.OK() {
				return false
			}

			otherAddr := sorted[(i+1)%len(sorted)].Addr
			pBadAddr := p
			pBadAddr.Addr = otherAddr
			rawBadAddr, _ := EncodeProofToken(pBadAddr)
			if _, res := VerifyToken(rawBadAddr, otherAddr, epoch, bm); res.OK() {
				return false
			}
		}

		// Flip 1 bit in aunts (when total > 1) -> must fail.
		if len(aunts) > 0 {
			badAunts := make([]byte, len(aunts))
			copy(badAunts, aunts)
			badAunts[0] ^= 0x80
			pBadAunts := p
			pBadAunts.Aunts = badAunts
			pBadAunts.AuntsHex = hex.EncodeToString(badAunts)
			rawBadAunts, _ := EncodeProofToken(pBadAunts)
			if _, res := VerifyToken(rawBadAunts, m.Addr, epoch, bm); res.OK() {
				return false
			}
		}
	}
	return true
}

func TestPBT_P3_MerkleCompletenessAndSingleBitSoundness(t *testing.T) {
	for _, n := range []int{1, 2, 3, 5, 7, 16, 25} {
		members := makeSyntheticMembers(n, uint64(300+n))
		if !checkP3CompletenessAndSoundness(7, members) {
			t.Fatalf("P3 failed for n=%d", n)
		}
	}
}

// Role 2 — P4: Epoch Bitmap Conservation & Replay Immunity (N = 1..128).
func checkP4BitmapConservation(n int, actions []int, weights []uint64) (bool, int, int) {
	bm := make([]byte, BitmapSize(n))
	if len(bm) != (n+7)/8 {
		return false, 0, 0
	}
	// Independent set oracle.
	oracleClaimed := make(map[int]bool, n)
	claimedCount := 0
	var totalWeight uint64
	applied := 0
	blocked := 0

	for _, idx := range actions {
		wasSet := oracleClaimed[idx]
		changed := SetBit(bm, idx)
		if wasSet {
			if changed {
				return false, applied, blocked
			}
			blocked++
		} else {
			if !changed {
				return false, applied, blocked
			}
			oracleClaimed[idx] = true
			claimedCount++
			totalWeight += weights[idx]
			applied++
		}

		// Check invariants after EVERY step.
		if Popcount(bm) != claimedCount || claimedCount > n || len(oracleClaimed) != claimedCount {
			return false, applied, blocked
		}
		var oracleWeight uint64
		for k := range oracleClaimed {
			if !IsBitSet(bm, k) {
				return false, applied, blocked
			}
			oracleWeight += weights[k]
		}
		if oracleWeight != totalWeight {
			return false, applied, blocked
		}
	}
	return true, applied, blocked
}

func TestPBT_P4_BitmapConservationAndReplayImmunity(t *testing.T) {
	rng := newLCG(999111)
	totalApplied := 0
	totalBlocked := 0
	for _, n := range []int{1, 7, 8, 9, 32, 65, 128} {
		weights := make([]uint64, n)
		for i := 0; i < n; i++ {
			weights[i] = uint64(i*10 + 5)
		}
		actions := make([]int, n*2)
		for i := range actions {
			actions[i] = rng.intn(n)
		}
		ok, app, blk := checkP4BitmapConservation(n, actions, weights)
		if !ok {
			t.Fatalf("P4 failed for n=%d", n)
		}
		totalApplied += app
		totalBlocked += blk
	}
	// Aggregate reachability witness after batch completes.
	if totalApplied == 0 || totalBlocked == 0 {
		t.Fatalf("expected both applied (%d) and blocked (%d) transitions", totalApplied, totalBlocked)
	}
}

// Role 3 — Individual Oracle Calibration Controls (test-local defects only; zero prod switches).
func TestOracleCalibration_P1ToP4IndividuallyCatchKnownBadStates(t *testing.T) {
	// Calibrate P1 oracle: corrupted leaf order breaks root equality.
	m := sortMembersCanonical(makeSyntheticMembers(3, 501))
	l0, _ := EncodeLeaf(1, m[0].Addr, m[0].Weight, m[0].Role)
	l1, _ := EncodeLeaf(1, m[1].Addr, m[1].Weight, m[1].Role)
	l2, _ := EncodeLeaf(1, m[2].Addr, m[2].Weight, m[2].Role)
	goodRoot := oracleRoot([][]byte{l0, l1, l2})
	swappedRoot := oracleRoot([][]byte{l1, l0, l2})
	if hex.EncodeToString(goodRoot) == hex.EncodeToString(swappedRoot) {
		t.Fatal("calibration P1 failed: swapped leaves produced identical root")
	}

	// Calibrate P2 oracle: uppercase hex is rejected by strict canonical decoder.
	aunt := make([]byte, 32)
	for i := range aunt {
		aunt[i] = 0xab
	}
	upperRaw := "cf1:1:0:2:" + string(addrAlice) + ":10:builder:" + "AB" + hex.EncodeToString(aunt[1:])
	if _, res := DecodeProofToken(upperRaw); res.OK() {
		t.Fatal("calibration P2 failed: non-canonical uppercase hex passed")
	}

	// Calibrate P3 oracle: internal node hash spoofed as raw leaf fails domain separation (0x00 vs 0x01).
	fakeLeaf := append(merkle.LeafHash(l0), merkle.LeafHash(l1)...)
	if merkle.VerifySimpleProof(goodRoot, fakeLeaf, 0, 2, merkle.LeafHash(l2)) {
		t.Fatal("calibration P3 failed: domain-separation spoof passed")
	}

	// Calibrate P4 oracle: manually corrupted bitmap byte breaks popcount vs claimedCount.
	bm := make([]byte, BitmapSize(8))
	SetBit(bm, 0)
	bm[0] |= 0x04 // test-local known-bad extra bit
	if Popcount(bm) == 1 {
		t.Fatal("calibration P4 failed: corrupted bitmap still matched count 1")
	}
}
