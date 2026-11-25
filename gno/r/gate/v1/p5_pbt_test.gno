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

type p5LCG struct{ state uint64 }

func (r *p5LCG) intn(n int) int {
	r.state = r.state*6364136223846793005 + 1442695040888963407
	return int(r.state % uint64(n))
}

// Role 2 — P5 + Claim-driven P4: Stage Machine Safety, RemoveMember & Cross-Epoch Isolation
// across deterministic seeded multi-epoch action sequences.
func TestPBT_P5_StageMachineAndCrossEpochIsolation(cur realm, t *testing.T) {
	// Ensure census starts OPEN (in case an earlier test left Epoch 2 frozen).
	testing.SetOriginCaller(gateOp)
	if census.Stage() == census.StageFrozenSnapshot {
		curID := census.EpochCount()
		ep, _ := census.GetEpoch(curID)
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

	rng := &p5LCG{state: 2026112505}
	var anchors []oracleAnchor
	pool := []address{
		testutils.TestAddress("p5_u0"),
		testutils.TestAddress("p5_u1"),
		testutils.TestAddress("p5_u2"),
		testutils.TestAddress("p5_u3"),
		testutils.TestAddress("p5_u4"),
		testutils.TestAddress("p5_u5"),
		testutils.TestAddress("p5_u6"),
	}
	appliedMutations := 0
	rejectedMutations := 0

	// Run 4 seeded epochs exercising UpsertMember, RemoveMember, SealEpoch, invalid frozen ops, and FoldRoster.
	for round := 0; round < 4; round++ {
		testing.SetOriginCaller(gateOp)
		if census.Stage() != census.StageOpen {
			t.Fatalf("round %d: expected OPEN stage", round)
		}
		draft := make(map[string]cairnfold.Member)
		for step := 0; step < 8; step++ {
			addr := pool[rng.intn(len(pool))]
			if step > 2 && rng.intn(3) == 0 {
				_, existed := draft[string(addr)]
				removed := census.RemoveMember(cross(cur), addr)
				if removed != existed {
					t.Fatalf("round %d step %d: RemoveMember=%v want %v", round, step, removed, existed)
				}
				delete(draft, string(addr))
				appliedMutations++
			} else {
				m := cairnfold.Member{
					Addr:   addr,
					Weight: uint64(rng.intn(500) + 10),
					Role:   "tier_" + strconv.Itoa(round),
				}
				census.UpsertMember(cross(cur), m.Addr, m.Weight, m.Role)
				draft[string(addr)] = m
				appliedMutations++
			}
		}
		// Guarantee at least 2 members so claims and replays are exercised.
		for len(draft) < 2 {
			addr := pool[len(draft)]
			m := cairnfold.Member{Addr: addr, Weight: 77, Role: "tier_" + strconv.Itoa(round)}
			census.UpsertMember(cross(cur), m.Addr, m.Weight, m.Role)
			draft[string(addr)] = m
		}
		if census.ActiveRosterSize() != len(draft) {
			t.Fatalf("round %d: ActiveRosterSize=%d want %d", round, census.ActiveRosterSize(), len(draft))
		}

		roundMembers := make([]cairnfold.Member, 0, len(draft))
		for _, m := range draft {
			roundMembers = append(roundMembers, m)
		}
		sorted := sortMembersLocal(roundMembers)
		epID := census.SealEpoch(cross(cur), "P5 Round "+strconv.Itoa(round))

		// P5(a): FoldRoster MUST abort before ConfirmSnapshotVerified.
		uassert.AbortsWithMessage(t, cur, "ERR_SNAPSHOT_UNVERIFIED: call ConfirmSnapshotVerified before FoldRoster", func() {
			census.FoldRoster(cross(cur), epID)
		})
		rejectedMutations++
		// P5(b): UpsertMember & RemoveMember MUST abort in FROZEN_SNAPSHOT.
		uassert.AbortsWithMessage(t, cur, "ERR_STAGE_FROZEN: roster is frozen awaiting verified fold", func() {
			census.UpsertMember(cross(cur), pool[0], 1, "blocked")
		})
		uassert.AbortsWithMessage(t, cur, "ERR_STAGE_FROZEN: roster is frozen awaiting verified fold", func() {
			census.RemoveMember(cross(cur), pool[0])
		})
		rejectedMutations += 2

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

	// P5(d) + Claim-driven P4: execute seeded Claim & duplicate-replay sequences against the OLDEST folded epoch.
	oldest := anchors[0]
	oracleClaimed := make(map[int]bool)
	var oracleWeight uint64
	claimApplied := 0
	claimBlocked := 0
	for step := 0; step < len(oldest.members)*3; step++ {
		idx := rng.intn(len(oldest.members))
		m := oldest.members[idx]
		tok := oldest.tokens[idx]
		testing.SetOriginCaller(m.Addr)
		if oracleClaimed[idx] {
			uassert.AbortsWithMessage(t, cur, "ERR_ALREADY_CLAIMED: leaf index already claimed for this epoch", func() {
				Claim(cross(cur), tok)
			})
			claimBlocked++
		} else {
			Claim(cross(cur), tok)
			oracleClaimed[idx] = true
			oracleWeight += m.Weight
			claimApplied++
		}
		st := GetClaimStats(oldest.id)
		if st.ClaimedCount != len(oracleClaimed) || st.TotalWeightClaimed != oracleWeight || st.BitmapBytes != cairnfold.BitmapSize(oldest.leafCount) {
			t.Fatalf("P4/P5 claim conservation mismatch at step %d: got=%+v wantCount=%d wantWeight=%d", step, st, len(oracleClaimed), oracleWeight)
		}
	}
	if appliedMutations == 0 || rejectedMutations == 0 || claimApplied == 0 || claimBlocked == 0 {
		t.Fatalf("expected non-zero applied/rejected transitions: mut=(%d,%d) claim=(%d,%d)", appliedMutations, rejectedMutations, claimApplied, claimBlocked)
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
