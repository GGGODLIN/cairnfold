package proofgen

import (
	"bytes"
	"crypto/sha256"
	"encoding/csv"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

const bech32Charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

// MaxLeafCount matches cairnfold.MaxLeafCount in gno/p/cairnfold/v1.
const MaxLeafCount = 1_000_000

type Member struct {
	Addr   string `json:"addr"`
	Weight uint64 `json:"weight"`
	Role   string `json:"role"`
}

type Snapshot struct {
	EpochID   uint64   `json:"epoch_id"`
	SchemaID  uint32   `json:"schema_id"`
	RootHex   string   `json:"root_hex,omitempty"`
	LeafCount int      `json:"leaf_count"`
	Purpose   string   `json:"purpose,omitempty"`
	Members   []Member `json:"members"`
}

type ProofEntry struct {
	Index    int    `json:"index"`
	Addr     string `json:"addr"`
	Weight   uint64 `json:"weight"`
	Role     string `json:"role"`
	AuntsHex string `json:"aunts_hex"`
	Token    string `json:"token"`
}

type ProofBundle struct {
	Mode      string       `json:"mode"`
	EpochID   uint64       `json:"epoch_id"`
	SchemaID  uint32       `json:"schema_id"`
	RootHex   string       `json:"root_hex"`
	LeafCount int          `json:"leaf_count"`
	Proofs    []ProofEntry `json:"proofs"`
}

func isValidRole(role string) bool {
	if len(role) == 0 || len(role) > 32 {
		return false
	}
	for i := 0; i < len(role); i++ {
		c := role[i]
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-'
		if !ok {
			return false
		}
	}
	return true
}

func bech32Polymod(values []byte) uint32 {
	gen := [5]uint32{0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3}
	chk := uint32(1)
	for _, v := range values {
		b := chk >> 25
		chk = (chk&0x1ffffff)<<5 ^ uint32(v)
		for i := 0; i < 5; i++ {
			if (b>>uint(i))&1 == 1 {
				chk ^= gen[i]
			}
		}
	}
	return chk
}

func bech32HRPExpand(hrp string) []byte {
	out := make([]byte, 0, len(hrp)*2+1)
	for i := 0; i < len(hrp); i++ {
		out = append(out, hrp[i]>>5)
	}
	out = append(out, 0)
	for i := 0; i < len(hrp); i++ {
		out = append(out, hrp[i]&31)
	}
	return out
}

// IsValidGnoAddress verifies canonical lowercase bech32 "g1..." 20-byte Gno address.
func IsValidGnoAddress(addr string) bool {
	if len(addr) != 40 || !strings.HasPrefix(addr, "g1") {
		return false
	}
	dataPart := addr[2:]
	data := make([]byte, len(dataPart))
	for i := 0; i < len(dataPart); i++ {
		idx := strings.IndexByte(bech32Charset, dataPart[i])
		if idx < 0 {
			return false
		}
		data[i] = byte(idx)
	}
	values := append(bech32HRPExpand("g"), data...)
	return bech32Polymod(values) == 1
}

func leafHash(leaf []byte) []byte {
	h := sha256.New()
	h.Write([]byte{0x00})
	h.Write(leaf)
	return h.Sum(nil)
}

func innerHash(left, right []byte) []byte {
	h := sha256.New()
	h.Write([]byte{0x01})
	h.Write(left)
	h.Write(right)
	return h.Sum(nil)
}

func largestPowerOfTwoLessThan(n int) int {
	k := 1
	for k*2 < n {
		k *= 2
	}
	return k
}

func computeTreeRoot(leaves [][]byte) []byte {
	switch len(leaves) {
	case 0:
		return nil
	case 1:
		return leafHash(leaves[0])
	default:
		k := largestPowerOfTwoLessThan(len(leaves))
		return innerHash(computeTreeRoot(leaves[:k]), computeTreeRoot(leaves[k:]))
	}
}

// buildAunts returns the flat 32-byte sibling hashes ordered bottom-up,
// matching Tendermint SimpleProofsFromByteSlices and GnoVM crypto/merkle.VerifySimpleProof.
func buildAunts(leaves [][]byte, idx int) []byte {
	if len(leaves) <= 1 {
		return nil
	}
	k := largestPowerOfTwoLessThan(len(leaves))
	if idx < k {
		sub := buildAunts(leaves[:k], idx)
		right := computeTreeRoot(leaves[k:])
		return append(sub, right...)
	}
	sub := buildAunts(leaves[k:], idx-k)
	left := computeTreeRoot(leaves[:k])
	return append(sub, left...)
}

func encodeLeaf(epochID uint64, m Member) []byte {
	return []byte(fmt.Sprintf("cairnfold:v1|%d|%s|%d|%s", epochID, m.Addr, m.Weight, m.Role))
}

func validateSnapshot(snap *Snapshot) error {
	if snap == nil {
		return errors.New("nil snapshot")
	}
	if snap.EpochID == 0 {
		return errors.New("epoch_id must be >= 1")
	}
	if snap.SchemaID == 0 {
		snap.SchemaID = 1
	}
	if snap.SchemaID != 1 {
		return fmt.Errorf("unsupported schema_id %d (expected 1)", snap.SchemaID)
	}
	if len(snap.Members) == 0 {
		return errors.New("snapshot contains no members")
	}
	if len(snap.Members) > MaxLeafCount {
		return fmt.Errorf("snapshot exceeds MaxLeafCount (%d)", MaxLeafCount)
	}
	if snap.LeafCount != 0 && snap.LeafCount != len(snap.Members) {
		return fmt.Errorf("leaf_count mismatch: header=%d actual=%d", snap.LeafCount, len(snap.Members))
	}
	snap.LeafCount = len(snap.Members)
	if snap.RootHex != "" {
		norm := strings.ToLower(strings.TrimSpace(snap.RootHex))
		if len(norm) != 64 {
			return errors.New("snapshot root_hex must be 64 hex chars")
		}
		if _, err := hex.DecodeString(norm); err != nil {
			return errors.New("snapshot root_hex must be valid hex")
		}
		snap.RootHex = norm
	}
	seen := make(map[string]struct{}, len(snap.Members))
	for i, m := range snap.Members {
		if !IsValidGnoAddress(m.Addr) {
			return fmt.Errorf("member[%d]: invalid gno address %q", i, m.Addr)
		}
		if _, dup := seen[m.Addr]; dup {
			return fmt.Errorf("duplicate member address %q", m.Addr)
		}
		seen[m.Addr] = struct{}{}
		if m.Weight == 0 {
			return fmt.Errorf("member[%d]: weight must be >= 1", i)
		}
		if !isValidRole(m.Role) {
			return fmt.Errorf("member[%d]: invalid role %q", i, m.Role)
		}
	}
	return nil
}

// ParseCanonicalSnapshot parses either JSON or ExportCanonicalSnapshot CSV format.
func ParseCanonicalSnapshot(raw []byte) (*Snapshot, error) {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 {
		return nil, errors.New("empty snapshot input")
	}
	if trimmed[0] == '{' {
		var snap Snapshot
		dec := json.NewDecoder(bytes.NewReader(trimmed))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&snap); err != nil {
			return nil, fmt.Errorf("parse snapshot json: %w", err)
		}
		if err := dec.Decode(&struct{}{}); err != io.EOF {
			return nil, errors.New("trailing data after snapshot json")
		}
		if err := validateSnapshot(&snap); err != nil {
			return nil, err
		}
		return &snap, nil
	}
	return parseCanonicalCSV(string(trimmed))
}

func parseCanonicalCSV(text string) (*Snapshot, error) {
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	snap := &Snapshot{SchemaID: 1}
	var csvLines []string
	for _, ln := range lines {
		ln = strings.TrimSpace(ln)
		if ln == "" {
			continue
		}
		if strings.HasPrefix(ln, "#") {
			meta := strings.TrimSpace(strings.TrimPrefix(ln, "#"))
			// Peel trailing ",purpose=..." first so commas inside purpose cannot spoof metadata keys.
			if before, after, ok := strings.Cut(meta, ",purpose="); ok {
				snap.Purpose = strings.TrimSpace(after)
				meta = before
			} else if strings.HasPrefix(meta, "purpose=") {
				snap.Purpose = strings.TrimSpace(strings.TrimPrefix(meta, "purpose="))
				meta = ""
			}
			for _, kv := range strings.Split(meta, ",") {
				parts := strings.SplitN(strings.TrimSpace(kv), "=", 2)
				if len(parts) != 2 {
					continue
				}
				k, v := strings.TrimSpace(parts[0]), strings.TrimSpace(parts[1])
				switch k {
				case "epoch_id":
					id, err := strconv.ParseUint(v, 10, 64)
					if err != nil {
						return nil, fmt.Errorf("invalid csv header epoch_id: %w", err)
					}
					snap.EpochID = id
				case "schema_id":
					id, err := strconv.ParseUint(v, 10, 32)
					if err != nil {
						return nil, fmt.Errorf("invalid csv header schema_id: %w", err)
					}
					snap.SchemaID = uint32(id)
				case "leaf_count":
					n, err := strconv.Atoi(v)
					if err != nil {
						return nil, fmt.Errorf("invalid csv header leaf_count: %w", err)
					}
					snap.LeafCount = n
				case "root_hex":
					snap.RootHex = v
				case "purpose":
					snap.Purpose = v
				}
			}
			continue
		}
		csvLines = append(csvLines, ln)
	}
	if len(csvLines) < 2 {
		return nil, errors.New("csv snapshot missing header or rows")
	}
	r := csv.NewReader(strings.NewReader(strings.Join(csvLines, "\n")))
	records, err := r.ReadAll()
	if err != nil {
		return nil, fmt.Errorf("parse csv rows: %w", err)
	}
	if len(records) < 2 || strings.Join(records[0], ",") != "index,addr,weight,role" {
		return nil, errors.New("csv header must be index,addr,weight,role")
	}
	for i, row := range records[1:] {
		if len(row) != 4 {
			return nil, fmt.Errorf("csv row %d: expected 4 columns, got %d", i, len(row))
		}
		idx, err := strconv.Atoi(strings.TrimSpace(row[0]))
		if err != nil || idx != i {
			return nil, fmt.Errorf("csv row %d: unexpected index %q", i, row[0])
		}
		weight, err := strconv.ParseUint(strings.TrimSpace(row[2]), 10, 64)
		if err != nil {
			return nil, fmt.Errorf("csv row %d: invalid weight %q", i, row[2])
		}
		snap.Members = append(snap.Members, Member{
			Addr:   strings.TrimSpace(row[1]),
			Weight: weight,
			Role:   strings.TrimSpace(row[3]),
		})
	}
	if err := validateSnapshot(snap); err != nil {
		return nil, err
	}
	return snap, nil
}

// BuildProofsFromSnapshot canonically sorts members, computes the Tendermint Merkle root,
// checks root parity against expectedRootHex/snap.RootHex, and emits cf1:... proof tokens.
func BuildProofsFromSnapshot(snap *Snapshot, expectedRootHex string) (*ProofBundle, error) {
	if err := validateSnapshot(snap); err != nil {
		return nil, err
	}
	sorted := make([]Member, len(snap.Members))
	copy(sorted, snap.Members)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i].Addr < sorted[j].Addr
	})

	leaves := make([][]byte, len(sorted))
	for i, m := range sorted {
		leaves[i] = encodeLeaf(snap.EpochID, m)
	}
	root := computeTreeRoot(leaves)
	rootHex := hex.EncodeToString(root)

	if snap.RootHex != "" && snap.RootHex != rootHex {
		return nil, fmt.Errorf("root mismatch: snapshot header=%s computed=%s", snap.RootHex, rootHex)
	}
	if expectedRootHex != "" {
		norm := strings.ToLower(strings.TrimSpace(expectedRootHex))
		if norm != rootHex {
			return nil, fmt.Errorf("root mismatch: expected=%s computed=%s", norm, rootHex)
		}
	}

	entries := make([]ProofEntry, len(sorted))
	total := len(sorted)
	for i, m := range sorted {
		aunts := buildAunts(leaves, i)
		auntsHex := hex.EncodeToString(aunts)
		tok := fmt.Sprintf("cf1:%d:%d:%d:%s:%d:%s:%s", snap.EpochID, i, total, m.Addr, m.Weight, m.Role, auntsHex)
		entries[i] = ProofEntry{
			Index:    i,
			Addr:     m.Addr,
			Weight:   m.Weight,
			Role:     m.Role,
			AuntsHex: auntsHex,
			Token:    tok,
		}
	}

	return &ProofBundle{
		Mode:      "DETERMINISTIC_REPLAY",
		EpochID:   snap.EpochID,
		SchemaID:  snap.SchemaID,
		RootHex:   rootHex,
		LeafCount: total,
		Proofs:    entries,
	}, nil
}

// WriteProofBundleAtomic writes bundle JSON to a temp file and atomically renames to path.
func WriteProofBundleAtomic(path string, bundle *ProofBundle) error {
	if bundle == nil {
		return errors.New("nil proof bundle")
	}
	data, err := json.MarshalIndent(bundle, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".cairnproof-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	success := false
	defer func() {
		if !success {
			_ = os.Remove(tmpName)
		}
	}()
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		return err
	}
	success = true
	return nil
}

// RunBuildProofsCLI executes `cairnproof build-proofs --input <file> --out <file> [--expected-root <hex>]`.
func RunBuildProofsCLI(args []string) error {
	if len(args) == 0 || args[0] != "build-proofs" {
		return errors.New("usage: cairnproof build-proofs --input <snapshot> --out <proofs.json> [--expected-root <hex>]")
	}
	fs := flag.NewFlagSet("build-proofs", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	inputPath := fs.String("input", "", "path to canonical snapshot JSON or CSV")
	outPath := fs.String("out", "", "path to write proof bundle JSON")
	expectedRoot := fs.String("expected-root", "", "optional expected 64-char hex root from Onyx")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if *inputPath == "" || *outPath == "" {
		return errors.New("both --input and --out are required")
	}
	raw, err := os.ReadFile(*inputPath)
	if err != nil {
		return fmt.Errorf("read input: %w", err)
	}
	snap, err := ParseCanonicalSnapshot(raw)
	if err != nil {
		return err
	}
	bundle, err := BuildProofsFromSnapshot(snap, *expectedRoot)
	if err != nil {
		return err
	}
	return WriteProofBundleAtomic(*outPath, bundle)
}
