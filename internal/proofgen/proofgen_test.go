package proofgen

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

var validAddrs = []string{
	"g104p7ldmmecudlgjt6q5ldwy25yj4t9lsxy7n9e",
	"g1nngfjkxys8e9acal2pmk7k572gzq0fllahkyl5",
	"g1st947gecd43mklw0l87x5f9x3a6fxen9m3hnu0",
}

func encodeTestGnoAddress(raw20 []byte) string {
	groups := make([]byte, 0, 32)
	acc, bits := 0, 0
	for _, b := range raw20 {
		acc = (acc << 8) | int(b)
		bits += 8
		for bits >= 5 {
			bits -= 5
			groups = append(groups, byte((acc>>bits)&31))
		}
	}
	values := append(bech32HRPExpand("g"), groups...)
	values = append(values, 0, 0, 0, 0, 0, 0)
	polymod := bech32Polymod(values) ^ 1
	var sb strings.Builder
	sb.WriteString("g1")
	for _, v := range groups {
		sb.WriteByte(bech32Charset[v])
	}
	for i := 0; i < 6; i++ {
		sb.WriteByte(bech32Charset[(polymod>>uint(5*(5-i)))&31])
	}
	return sb.String()
}

func syntheticMembers(t *testing.T, count int) []Member {
	t.Helper()
	roles := []string{"builder", "reviewer", "core_dev", "early-bird"}
	out := make([]Member, 0, count)
	for i := 0; i < count; i++ {
		if i < len(validAddrs) {
			out = append(out, Member{
				Addr:   validAddrs[i],
				Weight: uint64(100 + i*25),
				Role:   roles[i%len(roles)],
			})
			continue
		}
		sum := sha256.Sum256([]byte(fmt.Sprintf("cairnfold-synth-%d", i)))
		addr := encodeTestGnoAddress(sum[:20])
		out = append(out, Member{
			Addr:   addr,
			Weight: uint64(100 + i*25),
			Role:   roles[i%len(roles)],
		})
	}
	return out
}

func TestBuildProofsMatchesGnoVMAcrossTreeSizes(t *testing.T) {
	sizes := []int{1, 2, 3, 7, 16, 32}
	bundles := make([]*ProofBundle, 0, len(sizes))

	for _, n := range sizes {
		members := syntheticMembers(t, n)
		// Reverse input order to verify canonical sorting is order-independent.
		rev := make([]Member, n)
		for i := 0; i < n; i++ {
			rev[i] = members[n-1-i]
		}
		snapJSON, err := json.Marshal(Snapshot{
			EpochID:   uint64(n),
			SchemaID:  1,
			LeafCount: n,
			Members:   rev,
		})
		if err != nil {
			t.Fatalf("marshal n=%d: %v", n, err)
		}
		snap, err := ParseCanonicalSnapshot(snapJSON)
		if err != nil {
			t.Fatalf("ParseCanonicalSnapshot n=%d: %v", n, err)
		}
		bundle, err := BuildProofsFromSnapshot(snap, "")
		if err != nil {
			t.Fatalf("BuildProofsFromSnapshot n=%d: %v", n, err)
		}
		if bundle.LeafCount != n || len(bundle.Proofs) != n || len(bundle.RootHex) != 64 {
			t.Fatalf("unexpected bundle shape for n=%d", n)
		}
		for i := 1; i < n; i++ {
			if bundle.Proofs[i].Addr <= bundle.Proofs[i-1].Addr {
				t.Fatalf("n=%d proofs not strictly ascending at %d", n, i)
			}
		}
		bundles = append(bundles, bundle)
	}

	// Cross-implementation parity: verify EVERY Go-built root & token for N=1,2,3,7,16,32 inside real GnoVM!
	gnoBin := filepath.Join(os.Getenv("HOME"), ".gno", "bin", "gno")
	gnoRoot := filepath.Join(os.Getenv("HOME"), ".gno", "src")
	if _, err := os.Stat(gnoBin); err != nil {
		t.Fatalf("gno binary required for cross-impl parity not found at %s", gnoBin)
	}
	if _, err := os.Stat(gnoRoot); err != nil {
		t.Fatalf("GNOROOT required for cross-impl parity not found at %s", gnoRoot)
	}
	verifyBundlesInGnoVM(t, gnoBin, gnoRoot, bundles)
}

func verifyBundlesInGnoVM(t *testing.T, gnoBin, gnoRoot string, bundles []*ProofBundle) {
	t.Helper()
	tmpDir := t.TempDir()
	repoRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("abs repoRoot: %v", err)
	}
	pkgDst := filepath.Join(tmpDir, "p", "cairnfold", "v1")
	if err := os.MkdirAll(pkgDst, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(tmpDir, "gnowork.toml"), nil, 0o644); err != nil {
		t.Fatalf("write gnowork: %v", err)
	}
	for _, fn := range []string{"gnomod.toml", "cairnfold.gno"} {
		data, err := os.ReadFile(filepath.Join(repoRoot, "gno", "p", "cairnfold", "v1", fn))
		if err != nil {
			t.Fatalf("read %s: %v", fn, err)
		}
		if err := os.WriteFile(filepath.Join(pkgDst, fn), data, 0o644); err != nil {
			t.Fatalf("write %s: %v", fn, err)
		}
	}

	var body strings.Builder
	for _, b := range bundles {
		fmt.Fprintf(&body, "\t{\n")
		fmt.Fprintf(&body, "\t\tmembers := []Member{\n")
		for _, pe := range b.Proofs {
			fmt.Fprintf(&body, "\t\t\t{Addr: address(%q), Weight: %d, Role: %q},\n", pe.Addr, pe.Weight, pe.Role)
		}
		fmt.Fprintf(&body, "\t\t}\n")
		fmt.Fprintf(&body, "\t\tgotRoot, err := ComputeRoot(%d, members)\n", b.EpochID)
		fmt.Fprintf(&body, "\t\tif err != nil { t.Fatalf(\"ComputeRoot n=%d: %%v\", err) }\n", b.LeafCount)
		fmt.Fprintf(&body, "\t\tif hex.EncodeToString(gotRoot) != %q { t.Fatalf(\"root parity mismatch n=%d: gno=%%x go=%s\", gotRoot) }\n", b.RootHex, b.LeafCount, b.RootHex)
		fmt.Fprintf(&body, "\t\tep := &EpochView{ID: %d, Root: gotRoot, RootHex: %q, LeafCount: %d}\n", b.EpochID, b.RootHex, b.LeafCount)
		fmt.Fprintf(&body, "\t\tbm := make([]byte, BitmapSize(%d))\n", b.LeafCount)
		for _, pe := range b.Proofs {
			fmt.Fprintf(&body, "\t\tif _, res := VerifyToken(%q, address(%q), ep, bm); !res.OK() { t.Fatalf(\"VerifyToken n=%d idx=%d failed: %%s (%%s)\", res.Code, res.Message) }\n", pe.Token, pe.Addr, b.LeafCount, pe.Index)
		}
		fmt.Fprintf(&body, "\t}\n")
	}

	testSrc := fmt.Sprintf(`package cairnfold

import (
	"encoding/hex"
	"testing"
)

func TestGoToGnoVMParity(t *testing.T) {
%s}
`, body.String())

	if err := os.WriteFile(filepath.Join(pkgDst, "go_parity_test.gno"), []byte(testSrc), 0o644); err != nil {
		t.Fatalf("write parity test: %v", err)
	}
	cmd := exec.Command(gnoBin, "test", "-v", "./p/cairnfold/v1", "-run", "TestGoToGnoVMParity")
	cmd.Dir = tmpDir
	cmd.Env = append(os.Environ(), "GNOROOT="+gnoRoot)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	if err := cmd.Run(); err != nil {
		t.Fatalf("GnoVM parity test failed: %v\n%s", err, out.String())
	}
}

func TestBuildProofsRejectsBadInputsAndPreservesExistingOutputOnError(t *testing.T) {
	dir := t.TempDir()
	outPath := filepath.Join(dir, "proofs.json")
	sentinel := []byte(`{"existing":"keep-me"}`)
	if err := os.WriteFile(outPath, sentinel, 0o644); err != nil {
		t.Fatalf("seed existing output: %v", err)
	}

	snapPath := filepath.Join(dir, "snap.json")
	snapJSON, _ := json.Marshal(Snapshot{
		EpochID:   1,
		SchemaID:  1,
		LeafCount: 1,
		Members:   []Member{{Addr: validAddrs[0], Weight: 10, Role: "solo"}},
	})
	if err := os.WriteFile(snapPath, snapJSON, 0o644); err != nil {
		t.Fatalf("write snap: %v", err)
	}

	// Mismatched expected root must return "root mismatch" and NOT overwrite outPath.
	err := RunBuildProofsCLI([]string{
		"build-proofs",
		"--input", snapPath,
		"--out", outPath,
		"--expected-root", strings.Repeat("00", 32),
	})
	if err == nil || !strings.Contains(err.Error(), "root mismatch") {
		t.Fatalf("expected root mismatch error, got: %v", err)
	}
	got, _ := os.ReadFile(outPath)
	if !bytes.Equal(got, sentinel) {
		t.Fatalf("existing valid output file was overwritten on error: got %q", string(got))
	}

	// Positive control: matching run writes valid bundle atomically.
	if err := RunBuildProofsCLI([]string{"build-proofs", "--input", snapPath, "--out", outPath}); err != nil {
		t.Fatalf("expected valid CLI run to succeed, got: %v", err)
	}
	written, err := os.ReadFile(outPath)
	if err != nil {
		t.Fatalf("read written bundle: %v", err)
	}
	var parsed ProofBundle
	if err := json.Unmarshal(written, &parsed); err != nil {
		t.Fatalf("unmarshal written bundle: %v", err)
	}
	if parsed.LeafCount != 1 || len(parsed.Proofs) != 1 || !strings.HasPrefix(parsed.Proofs[0].Token, "cf1:1:0:1:") {
		t.Fatalf("unexpected written bundle: %+v", parsed)
	}

	// Malformed inputs: truncated JSON, duplicate addr, zero weight, bad role, bad checksum addr.
	badPayloads := []string{
		`{not-json`,
		`{"epoch_id":1,"schema_id":1,"leaf_count":2,"members":[{"addr":"g104p7ldmmecudlgjt6q5ldwy25yj4t9lsxy7n9e","weight":1,"role":"a"},{"addr":"g104p7ldmmecudlgjt6q5ldwy25yj4t9lsxy7n9e","weight":2,"role":"b"}]}`,
		`{"epoch_id":1,"schema_id":1,"leaf_count":1,"members":[{"addr":"g104p7ldmmecudlgjt6q5ldwy25yj4t9lsxy7n9e","weight":0,"role":"a"}]}`,
		`{"epoch_id":1,"schema_id":1,"leaf_count":1,"members":[{"addr":"g104p7ldmmecudlgjt6q5ldwy25yj4t9lsxy7n9e","weight":1,"role":"bad|role"}]}`,
		`{"epoch_id":1,"schema_id":1,"leaf_count":1,"members":[{"addr":"g104p7ldmmecudlgjt6q5ldwy25yj4t9lsxy7n9a","weight":1,"role":"a"}]}`,
	}
	for i, raw := range badPayloads {
		if _, err := ParseCanonicalSnapshot([]byte(raw)); err == nil {
			t.Fatalf("expected ParseCanonicalSnapshot error for bad payload %d", i)
		}
	}
}

func TestParseCanonicalCSVSnapshot(t *testing.T) {
	csvData := strings.Join([]string{
		"# epoch_id=1,schema_id=1,leaf_count=2,root_hex=",
		"index,addr,weight,role",
		"0," + validAddrs[0] + ",100,builder",
		"1," + validAddrs[1] + ",250,reviewer",
	}, "\n") + "\n"
	snap, err := ParseCanonicalSnapshot([]byte(csvData))
	if err != nil {
		t.Fatalf("ParseCanonicalSnapshot CSV failed: %v", err)
	}
	if snap.EpochID != 1 || snap.LeafCount != 2 || len(snap.Members) != 2 {
		t.Fatalf("unexpected CSV parsed snapshot: %+v", snap)
	}
	bundle, err := BuildProofsFromSnapshot(snap, "")
	if err != nil {
		t.Fatalf("BuildProofsFromSnapshot failed: %v", err)
	}
	// Regression: uppercase root_hex in snapshot header is normalized consistently with --expected-root.
	upperCSV := strings.Replace(csvData, "root_hex=", "root_hex="+strings.ToUpper(bundle.RootHex), 1)
	snapUpper, err := ParseCanonicalSnapshot([]byte(upperCSV))
	if err != nil {
		t.Fatalf("expected uppercase root_hex CSV to normalize cleanly: %v", err)
	}
	if snapUpper.RootHex != bundle.RootHex {
		t.Fatalf("expected normalized lowercase root_hex %q, got %q", bundle.RootHex, snapUpper.RootHex)
	}

	// Regression: commas inside purpose must not spoof earlier metadata keys (e.g. schema_id=2).
	commaPurposeCSV := strings.Replace(
		csvData,
		"root_hex=",
		"root_hex="+bundle.RootHex+",purpose=Cohort 1,schema_id=2,leaf_count=99",
		1,
	)
	snapComma, err := ParseCanonicalSnapshot([]byte(commaPurposeCSV))
	if err != nil {
		t.Fatalf("CSV with comma inside purpose failed: %v", err)
	}
	if snapComma.SchemaID != 1 || snapComma.LeafCount != 2 || snapComma.Purpose != "Cohort 1,schema_id=2,leaf_count=99" {
		t.Fatalf("purpose comma spoofed metadata: %+v", snapComma)
	}
}
