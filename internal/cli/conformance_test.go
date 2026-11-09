// SPDX-License-Identifier: MIT OR Apache-2.0

package cli

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/3leaps/canondocs/internal/yamljcs"
)

const vectorDir = "../../testdata/yaml-jcs-rfc8785-v0"

type vectorCase struct {
	ID      string `json:"id"`
	Input   string `json:"input"`
	Options *struct {
		AllowMergeKeys bool `json:"allow_merge_keys"`
	} `json:"options"`
	Expect struct {
		Canonical       *string `json:"canonical"`
		CanonicalSHA256 string  `json:"canonical_sha256"`
		Refusal         string  `json:"refusal"`
	} `json:"expect"`
}

func loadVectors(t *testing.T) []vectorCase {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(vectorDir, "cases.json"))
	if err != nil {
		t.Fatal(err)
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	var cases []vectorCase
	if err := dec.Decode(&cases); err != nil {
		t.Fatal(err)
	}
	return cases
}

// TestVectorIndex checks the index itself: unique ids, one input file per
// case and no unreferenced files, exactly one kind of expectation, and
// digests that match the canonical text.
func TestVectorIndex(t *testing.T) {
	cases := loadVectors(t)
	if len(cases) < 36 {
		t.Fatalf("%d cases, want at least 36", len(cases))
	}
	ids := map[string]bool{}
	inputs := map[string]bool{"cases.json": true}
	for _, c := range cases {
		if ids[c.ID] {
			t.Errorf("duplicate id %s", c.ID)
		}
		ids[c.ID] = true
		inputs[c.Input] = true
		if (c.Expect.Canonical == nil) == (c.Expect.Refusal == "") {
			t.Errorf("%s: want exactly one of canonical or refusal", c.ID)
		}
		if c.Expect.Canonical != nil {
			sum := sha256.Sum256([]byte(*c.Expect.Canonical))
			if hex.EncodeToString(sum[:]) != c.Expect.CanonicalSHA256 {
				t.Errorf("%s: canonical_sha256 does not match canonical", c.ID)
			}
		}
	}
	entries, err := os.ReadDir(vectorDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if !inputs[e.Name()] {
			t.Errorf("unreferenced file %s", e.Name())
		}
	}
}

func TestVectorsLibrary(t *testing.T) {
	for _, c := range loadVectors(t) {
		t.Run(c.ID, func(t *testing.T) {
			input, err := os.ReadFile(filepath.Join(vectorDir, c.Input))
			if err != nil {
				t.Fatal(err)
			}
			o := yamljcs.Options{Limits: yamljcs.DefaultLimits()}
			if c.Options != nil {
				o.AllowMergeKeys = c.Options.AllowMergeKeys
			}
			got, err := yamljcs.Canonicalize(input, o)
			if c.Expect.Refusal != "" {
				var r *yamljcs.Refusal
				if !errors.As(err, &r) {
					t.Fatalf("got %q, %v; want refusal %s", got, err, c.Expect.Refusal)
				}
				if string(r.Code) != c.Expect.Refusal {
					t.Fatalf("refusal %s (%v), want %s", r.Code, r, c.Expect.Refusal)
				}
				return
			}
			if err != nil {
				t.Fatalf("refused: %v", err)
			}
			checkCanonical(t, got, c)
		})
	}
}

func TestVectorsCLI(t *testing.T) {
	for _, c := range loadVectors(t) {
		t.Run(c.ID, func(t *testing.T) {
			path := filepath.Join(vectorDir, c.Input)
			args := []string{"jcs"}
			if c.Options != nil && c.Options.AllowMergeKeys {
				args = append(args, "--allow-merge-keys")
			}
			// Detected from the .yaml suffix.
			stdout, stderr, code := run(t, "", append(args, path)...)
			// And from stdin with an explicit format.
			input, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			stdout2, stderr2, code2 := run(t, string(input), append(args, "--from", "yaml")...)
			if stdout != stdout2 || stderr != stderr2 || code != code2 {
				t.Fatalf("file and stdin differ: %q/%q/%d vs %q/%q/%d", stdout, stderr, code, stdout2, stderr2, code2)
			}
			if c.Expect.Refusal != "" {
				if code != ExitRefused || stdout != "" {
					t.Fatalf("exit %d stdout %q, want exit 1 and no output", code, stdout)
				}
				if !strings.HasPrefix(stderr, "canondocs: yaml: "+c.Expect.Refusal+": ") {
					t.Fatalf("stderr %q, want refusal %s", stderr, c.Expect.Refusal)
				}
				return
			}
			if code != ExitOK || stderr != "" {
				t.Fatalf("exit %d stderr %q", code, stderr)
			}
			checkCanonical(t, []byte(stdout), c)
			dstdout, _, dcode := run(t, "", append(args, "--digest", path)...)
			if dcode != ExitOK || dstdout != "sha256:"+c.Expect.CanonicalSHA256+"\n" {
				t.Fatalf("--digest: exit %d %q", dcode, dstdout)
			}
		})
	}
}

func checkCanonical(t *testing.T, got []byte, c vectorCase) {
	t.Helper()
	if string(got) != *c.Expect.Canonical {
		t.Fatalf("got %q, want %q", got, *c.Expect.Canonical)
	}
	sum := sha256.Sum256(got)
	if hex.EncodeToString(sum[:]) != c.Expect.CanonicalSHA256 {
		t.Fatalf("sha256 mismatch")
	}
}
