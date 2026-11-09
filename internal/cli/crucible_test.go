// SPDX-License-Identifier: MIT OR Apache-2.0

package cli

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"testing"
)

// TestCrucibleDurableRecordCuts is a differential test against the crucible
// reference canonicalizer. It runs only when CANONDOCS_CRUCIBLE_DIR names a
// crucible checkout. For every durable-record/v1 vector with a source
// journal, the journal is written as NDJSON (one compact line per entry) and
// each prefix cut k = 1..len+1 is digested by both canondocs and the
// reference script; outcomes (digest, or refusal) must agree.
func TestCrucibleDurableRecordCuts(t *testing.T) {
	dir := os.Getenv("CANONDOCS_CRUCIBLE_DIR")
	if dir == "" {
		t.Skip("CANONDOCS_CRUCIBLE_DIR not set")
	}
	script := filepath.Join(dir, "scripts", "rfc8785-canonicalize.py")
	if _, err := os.Stat(script); err != nil {
		t.Fatal(err)
	}
	python, err := exec.LookPath("python3")
	if err != nil {
		t.Fatal("python3 not found")
	}
	files, err := filepath.Glob(filepath.Join(dir, "schemas", "durable-record", "v1", "vectors", "*.json"))
	if err != nil || len(files) == 0 {
		t.Fatalf("no vectors: %v", err)
	}
	sort.Strings(files)
	tmp := t.TempDir()
	journals, cuts := 0, 0
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		var v map[string]json.RawMessage
		if err := json.Unmarshal(raw, &v); err != nil {
			t.Fatalf("%s: %v", f, err)
		}
		sj, ok := v["source_journal"]
		if !ok {
			continue
		}
		var entries []json.RawMessage
		if err := json.Unmarshal(sj, &entries); err != nil {
			t.Fatalf("%s: source_journal: %v", f, err)
		}
		var nd bytes.Buffer
		for _, e := range entries {
			if err := json.Compact(&nd, e); err != nil {
				t.Fatal(err)
			}
			nd.WriteByte('\n')
		}
		journal := filepath.Join(tmp, filepath.Base(f)+".ndjson")
		if err := os.WriteFile(journal, nd.Bytes(), 0o600); err != nil {
			t.Fatal(err)
		}
		journals++
		for k := 1; k <= len(entries)+1; k++ {
			head := fmt.Sprint(k)
			out, _, code := run(t, "", "jcs", "--ndjson-array", "--head", head, "--digest", journal)
			cmd := exec.Command(python, "-I", "-B", script, "--ndjson-array", "--head", head, "--digest", journal)
			var refOut bytes.Buffer
			cmd.Stdout = &refOut
			refCode := 0
			if err := cmd.Run(); err != nil {
				var ee *exec.ExitError
				if !errors.As(err, &ee) {
					t.Fatal(err)
				}
				refCode = ee.ExitCode()
			}
			if code != refCode || out != refOut.String() {
				t.Errorf("%s head %d: canondocs exit %d %q, reference exit %d %q",
					filepath.Base(f), k, code, out, refCode, refOut.String())
			}
			if k <= len(entries) && code != ExitOK {
				t.Errorf("%s head %d: refused a cut within the journal", filepath.Base(f), k)
			}
			if k == len(entries)+1 && code != ExitRefused {
				t.Errorf("%s head %d: accepted a cut beyond the journal", filepath.Base(f), k)
			}
			cuts++
		}
	}
	if journals == 0 {
		t.Fatal("no vector has a source_journal")
	}
	t.Logf("%d journals, %d cuts compared", journals, cuts)
}
