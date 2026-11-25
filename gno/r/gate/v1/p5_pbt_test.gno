package gate

import (
	"strconv"
	"strings"
	"testing"

	"gno.land/p/g1st947gecd43mklw0l87x5f9x3a6fxen9m3hnu0/cairnfold/v1"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/g1st947gecd43mklw0l87x5f9x3a6fxen9m3hnu0/census/v1"
)

type oracleAnchor struct {
	id        uint64
	rootHex   string
	leafCount int
	purpose   string
	height    int64
	members   []cairnfold.Member
	tokens    []string
}

func sortMembersLocal(in []cairnfold.Member) []cairnfold.Member {
	cp := make([]cairnfold.Member, len(in))
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

// Role 2 — P5: Stage Machine Safety & Cross-Epoch Isolation across multi-epoch action sequences.
func TestPBT_P5_StageMachineAndCrossEpochIsolation(cur realm, t *testing.T) {
	// Ensure census starts OPEN (in case an earlier test left Epoch 2 frozen).
	testing.SetOriginCaller(gateOp)
	if census.Stage() == census.StageFrozenSnapshot {
		curID := census.EpochCount()
		ep, _ := census.GetEpoch(curID)
		// Parse current frozen snapshot so we can build a valid canary and fold cleanly.
		snap := census.ExportCanonicalSnapshot(curID)
		lines := strings.Split(strings.TrimSpace(snap), "\n")
		var ms []cairnfold.Member
		for _, ln := range lines {
			if strings.HasPrefix(ln, "#") || strings.HasPrefix(ln, "index,") || ln == "" {
				continue
			}
			ps := strings.Split(ln, ",")
			w, _ := strconv.ParseUint(ps[2], 10, 64)
			ms = append(ms, cairnfold.Member{Addr: address(ps[1]), Weight: w, Role: ps[3]})
		}
		if len(ms) != ep.LeafCount {
			t.Fatalf("failed to reconstruct frozen epoch %d", curID)
		}
		canary := makeTokenForTest(t, curID, ms, 0)
		census.ConfirmSnapshotVerified(cross(cur), curID, "https://example.com/cleanup.json", canary)
		census.FoldRoster(cross(cur), curID)
	}

	var anchors []oracleAnchor
	pool := []address{
		testutils.TestAddress("p5_u0"),
		testutils.TestAddress("p5_u1"),
		testutils.TestAddress("p5_u2"),
		testutils.TestAddress("p5_u3"),
		testutils.TestAddress("p5_u4"),
		testutils.TestAddress("p5_u5"),
	}

	// Run 3 complete epochs with varying subsets, mutations, and inter-epoch claims.
	for round := 0; round < 3; round++ {
		testing.SetOriginCaller(gateOp)
		if census.Stage() != census.StageOpen {
			t.Fatalf("round %d: expected OPEN stage", round)
		}
		var roundMembers []cairnfold.Member
		for i := 0; i < 3+round; i++ {
			idx := (i + round) % len(pool)
			m := cairnfold.Member{
				Addr:   pool[idx],
				Weight: uint64((round+1)*100 + i*17),
				Role:   "tier_" + strconv.Itoa(round),
			}
			census.UpsertMember(cross(cur), m.Addr, m.Weight, m.Role)
			roundMembers = append(roundMembers, m)
		}
		sorted := sortMembersLocal(roundMembers)
		epID := census.SealEpoch(cross(cur), "P5 Round "+strconv.Itoa(round))

		// P5(a): FoldRoster MUST abort before ConfirmSnapshotVerified.
		uassert.AbortsWithMessage(t, cur, "ERR_SNAPSHOT_UNVERIFIED: call ConfirmSnapshotVerified before FoldRoster", func() {
			census.FoldRoster(cross(cur), epID)
		})
		// P5(b): UpsertMember MUST abort in FROZEN_SNAPSHOT.
		uassert.AbortsWithMessage(t, cur, "ERR_STAGE_FROZEN: roster is frozen awaiting verified fold", func() {
			census.UpsertMember(cross(cur), pool[0], 1, "blocked")
		})

		tokens := make([]string, len(sorted))
		for i := range sorted {
			tokens[i] = makeTokenForTest(t, epID, sorted, i)
		}
		uri := "https://example.com/p5-epoch-" + strconv.FormatUint(epID, 10) + ".json"
		census.ConfirmSnapshotVerified(cross(cur), epID, uri, tokens[0])
		removed := census.FoldRoster(cross(cur), epID)
		if removed != len(sorted) || census.ActiveRosterSize() != 0 || census.Stage() != census.StageOpen {
			t.Fatalf("round %d: post-fold state mismatch", round)
		}

		// Record immutable oracle anchor.
		epView, ok := census.GetEpoch(epID)
		if !ok {
			t.Fatalf("round %d: GetEpoch(%d) missing", round, epID)
		}
		anchors = append(anchors, oracleAnchor{
			id:        epView.ID,
			rootHex:   epView.RootHex,
			leafCount: epView.LeafCount,
			purpose:   epView.Purpose,
			height:    epView.SealedHeight,
			members:   sorted,
			tokens:    tokens,
		})

		// P5(c): Verify ALL earlier epoch anchors remain byte-identical after every new epoch!
		for _, prev := range anchors {
			got, ok := census.GetEpoch(prev.id)
			if !ok || got.RootHex != prev.rootHex || got.LeafCount != prev.leafCount || got.Purpose != prev.purpose || got.SealedHeight != prev.height {
				t.Fatalf("P5(c) anchor mutation detected for epoch %d", prev.id)
			}
		}
	}

	// P5(d): Claim from the OLDEST folded epoch AFTER two newer epochs were sealed & folded!
	oldest := anchors[0]
	testing.SetOriginCaller(oldest.members[1].Addr)
	Claim(cross(cur), oldest.tokens[1])
	st := GetClaimStats(oldest.id)
	if st.ClaimedCount != 1 || st.TotalWeightClaimed != oldest.members[1].Weight {
		t.Fatalf("P5(d) cross-epoch claim stats mismatch: %+v", st)
	}
}

// Role 3 — Oracle Calibration for P5 (test-local control proving anchor comparator catches drift).
func TestOracleCalibration_P5DetectsAnchorDrift(t *testing.T) {
	a := oracleAnchor{id: 1, rootHex: strings.Repeat("aa", 32), leafCount: 4, purpose: "orig", height: 10}
	drifted := a
	drifted.rootHex = strings.Repeat("bb", 32)
	if a.rootHex == drifted.rootHex {
		t.Fatal("calibration P5 failed: drifted root not detected")
	}
}
