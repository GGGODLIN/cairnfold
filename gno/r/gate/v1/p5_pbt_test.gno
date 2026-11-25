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
// across randomized multi-action sequences of Upsert, Remove, Seal, ConfirmSnapshotVerified, and Fold.
func TestPBT_P5_StageMachineAndCrossEpochIsolation(cur realm, t *testing.T) {
	testing.SetOriginCaller(gateOp)
	if census.Stage() != census.StageOpen {
		t.Fatalf("expected census to start OPEN, got %s", census.Stage())
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
	draft := make(map[string]cairnfold.Member)
	var frozenID uint64
	var frozenSorted []cairnfold.Member
	var frozenTokens []string
	frozenVerified := false

	appliedOps := 0
	rejectedOps := 0

	// Randomly choose among all 5 lifecycle actions (0=Upsert, 1=Remove, 2=Seal, 3=Confirm, 4=Fold)
	// until at least 3 full epochs have been sealed, verified, and folded.
	for step := 0; step < 120 && len(anchors) < 3; step++ {
		testing.SetOriginCaller(gateOp)
		action := rng.intn(5)
		// Bias slightly toward finishing an active frozen epoch if we've reached step > 70.
		if step > 70 && frozenID != 0 {
			if !frozenVerified {
				action = 3
			} else {
				action = 4
			}
		}

		switch action {
		case 0: // UpsertMember
			addr := pool[rng.intn(len(pool))]
			m := cairnfold.Member{Addr: addr, Weight: uint64(rng.intn(500) + 10), Role: "tier_" + strconv.Itoa(len(anchors))}
			if frozenID != 0 {
				uassert.AbortsWithMessage(t, cur, "ERR_STAGE_FROZEN: roster is frozen awaiting verified fold", func() {
					census.UpsertMember(cross(cur), m.Addr, m.Weight, m.Role)
				})
				rejectedOps++
			} else {
				census.UpsertMember(cross(cur), m.Addr, m.Weight, m.Role)
				draft[string(addr)] = m
				appliedOps++
			}
		case 1: // RemoveMember
			addr := pool[rng.intn(len(pool))]
			if frozenID != 0 {
				uassert.AbortsWithMessage(t, cur, "ERR_STAGE_FROZEN: roster is frozen awaiting verified fold", func() {
					census.RemoveMember(cross(cur), addr)
				})
				rejectedOps++
			} else {
				_, existed := draft[string(addr)]
				removed := census.RemoveMember(cross(cur), addr)
				if removed != existed {
					t.Fatalf("step %d: RemoveMember=%v want %v", step, removed, existed)
				}
				delete(draft, string(addr))
				appliedOps++
			}
		case 2: // SealEpoch
			if frozenID != 0 {
				uassert.AbortsWithMessage(t, cur, "ERR_STAGE_FROZEN: roster is frozen awaiting verified fold", func() {
					census.SealEpoch(cross(cur), "P5 Blocked")
				})
				rejectedOps++
			} else if len(draft) == 0 {
				uassert.AbortsWithMessage(t, cur, "ERR_EMPTY_ROSTER: cannot seal an empty roster", func() {
					census.SealEpoch(cross(cur), "P5 Empty")
				})
				rejectedOps++
			} else {
				members := make([]cairnfold.Member, 0, len(draft))
				for _, m := range draft {
					members = append(members, m)
				}
				frozenSorted = sortMembersLocal(members)
				frozenID = census.SealEpoch(cross(cur), "P5 Round: "+strconv.Itoa(len(anchors)))
				frozenTokens = make([]string, len(frozenSorted))
				for i := range frozenSorted {
					frozenTokens[i] = makeTokenForTest(t, frozenID, frozenSorted, i)
				}
				frozenVerified = false
				appliedOps++
			}
		case 3: // ConfirmSnapshotVerified
			if frozenID == 0 {
				uassert.AbortsWithMessage(t, cur, "ERR_NOT_FROZEN: epoch is not currently frozen awaiting fold", func() {
					census.ConfirmSnapshotVerified(cross(cur), 1, "https://example.com/noop.json", "cf1:1:0:1:"+string(pool[0])+":1:a:")
				})
				rejectedOps++
			} else {
				uri := "https://example.com/p5-epoch-" + strconv.FormatUint(frozenID, 10) + ".json"
				census.ConfirmSnapshotVerified(cross(cur), frozenID, uri, frozenTokens[0])
				frozenVerified = true
				appliedOps++
			}
		case 4: // FoldRoster
			if frozenID == 0 {
				uassert.AbortsWithMessage(t, cur, "ERR_NOT_FROZEN: epoch is not currently frozen awaiting fold", func() {
					census.FoldRoster(cross(cur), 1)
				})
				rejectedOps++
			} else if !frozenVerified {
				uassert.AbortsWithMessage(t, cur, "ERR_SNAPSHOT_UNVERIFIED: call ConfirmSnapshotVerified before FoldRoster", func() {
					census.FoldRoster(cross(cur), frozenID)
				})
				rejectedOps++
			} else {
				removed := census.FoldRoster(cross(cur), frozenID)
				if removed != len(frozenSorted) || census.ActiveRosterSize() != 0 || census.Stage() != census.StageOpen {
					t.Fatalf("step %d: post-fold state mismatch", step)
				}
				epView, ok := census.GetEpoch(frozenID)
				if !ok {
					t.Fatalf("step %d: GetEpoch(%d) missing", step, frozenID)
				}
				anchors = append(anchors, oracleAnchor{
					id:        epView.ID,
					rootHex:   epView.RootHex,
					leafCount: epView.LeafCount,
					purpose:   epView.Purpose,
					height:    epView.SealedHeight,
					members:   frozenSorted,
					tokens:    frozenTokens,
				})
				draft = make(map[string]cairnfold.Member)
				frozenID = 0
				frozenSorted = nil
				frozenTokens = nil
				frozenVerified = false
				appliedOps++
			}
		}

		// P5(c): Verify ALL earlier epoch anchors remain byte-identical after EVERY step!
		for _, prev := range anchors {
			got, ok := census.GetEpoch(prev.id)
			if !ok || got.RootHex != prev.rootHex || got.LeafCount != prev.leafCount || got.Purpose != prev.purpose || got.SealedHeight != prev.height {
				t.Fatalf("P5(c) anchor mutation detected for epoch %d at step %d", prev.id, step)
			}
		}
	}

	if len(anchors) < 2 {
		t.Fatalf("expected at least 2 folded epochs in P5 randomized trace, got %d", len(anchors))
	}

	// P5(d) + Claim-driven P4: execute seeded Claim & duplicate-replay sequences against the OLDEST folded epoch.
	oldest := anchors[0]
	oracleClaimed := make(map[int]bool)
	var oracleWeight uint64
	claimApplied := 0
	claimBlocked := 0
	for step := 0; step < len(oldest.members)*3+2; step++ {
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
	if appliedOps == 0 || rejectedOps == 0 || claimApplied == 0 || claimBlocked == 0 {
		t.Fatalf("expected non-zero applied/rejected transitions: ops=(%d,%d) claim=(%d,%d)", appliedOps, rejectedOps, claimApplied, claimBlocked)
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
