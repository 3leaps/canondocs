// SPDX-License-Identifier: MIT OR Apache-2.0

package cli

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/3leaps/canonprims/canon"
)

// run invokes Main with stdin and returns stdout, stderr and the exit code.
func run(t *testing.T, stdin string, args ...string) (string, string, int) {
	t.Helper()
	var out, errb bytes.Buffer
	code := Main(args, Env{Stdin: strings.NewReader(stdin), Stdout: &out, Stderr: &errb})
	return out.String(), errb.String(), code
}

func writeFile(t *testing.T, name, content string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestUsageErrors(t *testing.T) {
	yamlFile := writeFile(t, "doc.YML", "a: 1\n")
	for _, args := range [][]string{
		{},
		{"nope"},
		{"jcs", "--bogus"},
		{"jcs", "-x"},
		{"jcs", "a", "b"},
		{"jcs", "--digest", "--digest"},
		{"jcs", "--digest=yes"},
		{"jcs", "--max-bytes"},
		{"jcs", "--max-bytes", ""},
		{"jcs", "--max-bytes", "+5"},
		{"jcs", "--max-bytes", "-5"},
		{"jcs", "--max-bytes", " 5"},
		{"jcs", "--max-bytes", "5 "},
		{"jcs", "--max-bytes", "1_000"},
		{"jcs", "--max-depth", "0x10"},
		{"jcs", "--max-string-bytes", "99999999999999999999"},
		{"jcs", "--max-object-members", "1e3"},
		{"jcs", "--ndjson-array", "--head", "0"},
		{"jcs", "--head", "1"},
		{"jcs", "--from", "yaml", "--head", "1"},
		{"jcs", "--from", "toml"},
		{"jcs", "--from", "yaml", "--check"},
		{"jcs", "--check", yamlFile},
		{"jcs", "--ndjson-array", "--check"},
		{"jcs", "--from", "ndjson", "--check"},
		{"jcs", "--check", "--digest"},
		{"jcs", "--check", "--vector"},
		{"jcs", "--digest", "--vector"},
		{"jcs", "--allow-merge-keys"},
		{"jcs", "--allow-merge-keys", "--from", "json"},
		{"jcs", "--from", "yaml", "--ndjson-array"},
		{"jcs", "--from", "json", "--ndjson-array"},
		{"jcs", "--ndjson-array", yamlFile},
		{"info", "jcs/unknown"},
		{"info", "a", "b"},
		{"version", "--extended"},
		{"version", "x"},
		{"doctor", "x"},
	} {
		out, errs, code := run(t, "{}", args...)
		if code != ExitUsage || out != "" || errs == "" {
			t.Errorf("%q: exit %d stdout %q stderr %q, want usage error", args, code, out, errs)
		}
	}
}

func TestHelp(t *testing.T) {
	for _, args := range [][]string{{"--help"}, {"jcs", "--help"}, {"info", "-h"}, {"version", "--help"}, {"doctor", "--help"}} {
		out, errs, code := run(t, "", args...)
		if code != ExitOK || !strings.Contains(out, "anondocs") || errs != "" {
			t.Errorf("%q: exit %d stdout %q stderr %q", args, code, out, errs)
		}
	}
}

func TestDetection(t *testing.T) {
	for _, tc := range []struct {
		file string
		want Format
	}{
		{"", FormatJSON}, {"-", FormatJSON}, {"x.json", FormatJSON}, {"x.txt", FormatJSON},
		{"x.yaml", FormatYAML}, {"x.YML", FormatYAML}, {"x.Yaml", FormatYAML},
		{"x.ndjson", FormatNDJSON}, {"x.JSONL", FormatNDJSON}, {"yaml", FormatJSON},
	} {
		if got := detect(tc.file); got != tc.want {
			t.Errorf("detect(%q) = %s, want %s", tc.file, got, tc.want)
		}
	}
}

func TestStdinNeverGuessesYAML(t *testing.T) {
	// Valid YAML, invalid JSON: stdin defaults to JSON and refuses it.
	_, errs, code := run(t, "a: 1\n", "jcs")
	if code != ExitRefused || !strings.HasPrefix(errs, "canondocs: jcs/rfc8785: invalid_json at byte ") {
		t.Fatalf("exit %d stderr %q", code, errs)
	}
}

func TestJSON(t *testing.T) {
	out, errs, code := run(t, `{"b":[1.0,1e21],"a":"é"}`, "jcs")
	if code != ExitOK || out != `{"a":"é","b":[1,1e+21]}` || errs != "" {
		t.Fatalf("exit %d %q %q", code, out, errs)
	}
	// JSON input follows the binary64 integer rule, not the YAML safe-integer
	// rule: 2^53 is a binary64 value and is admitted.
	out, _, code = run(t, `9007199254740992`, "jcs")
	if code != ExitOK || out != "9007199254740992" {
		t.Fatalf("2^53: exit %d %q", code, out)
	}
	_, errs, code = run(t, `9007199254740993`, "jcs")
	if code != ExitRefused || !strings.Contains(errs, "integer_outside_binary64") {
		t.Fatalf("2^53+1: exit %d %q", code, errs)
	}
	_, errs, code = run(t, `{"a":1,"a":2}`, "jcs")
	if code != ExitRefused || !strings.HasPrefix(errs, "canondocs: jcs/rfc8785: duplicate_member at byte ") {
		t.Fatalf("duplicate: exit %d %q", code, errs)
	}
}

func TestCheck(t *testing.T) {
	if _, _, code := run(t, `{"a":1}`, "jcs", "--check"); code != ExitOK {
		t.Fatalf("canonical: exit %d", code)
	}
	out, errs, code := run(t, `{"a": 1}`, "jcs", "--check")
	if code != ExitRefused || out != "" || !strings.Contains(errs, "not_canonical at byte 5") {
		t.Fatalf("not canonical: exit %d %q %q", code, out, errs)
	}
	if _, _, code := run(t, `[1,2,3]`, "jcs", "--check", "--sort-set"); code != ExitOK {
		t.Fatalf("set: exit %d", code)
	}
	if _, errs, code := run(t, `[2,1]`, "jcs", "--check", "--sort-set"); code != ExitRefused || !strings.Contains(errs, "not_canonical") {
		t.Fatalf("unsorted set: exit %d %q", code, errs)
	}
	if _, errs, code := run(t, `[1,1]`, "jcs", "--check", "--sort-set"); code != ExitRefused || !strings.Contains(errs, "duplicate_set_element") {
		t.Fatalf("duplicate set: exit %d %q", code, errs)
	}
}

func TestDigestAndVector(t *testing.T) {
	out, _, code := run(t, `{"b":1,"a":2}`, "jcs", "--digest")
	// sha256 of {"a":2,"b":1}
	want, _ := canon.Digest(canon.JCS, []byte(`{"a":2,"b":1}`), canon.DefaultLimits(), "sha256")
	if code != ExitOK || out != want+"\n" {
		t.Fatalf("digest: exit %d %q want %q", code, out, want)
	}
	out, _, code = run(t, "b: 1\na: 2\n", "jcs", "--from", "yaml", "--vector")
	if code != ExitOK {
		t.Fatalf("vector: exit %d", code)
	}
	var v struct {
		ByteLength int    `json:"byte_length"`
		Canonical  string `json:"canonical"`
		Digest     string `json:"digest"`
		Scheme     string `json:"scheme"`
	}
	if err := json.Unmarshal([]byte(out), &v); err != nil {
		t.Fatal(err)
	}
	if v.Canonical != `{"a":2,"b":1}` || v.ByteLength != 13 || v.Digest != want || v.Scheme != "jcs/rfc8785" {
		t.Fatalf("vector %+v", v)
	}
	if !strings.HasSuffix(out, "}\n") {
		t.Fatalf("vector not LF-terminated: %q", out)
	}
	if err := canon.Check(canon.JCS, []byte(strings.TrimSuffix(out, "\n")), canon.DefaultLimits()); err != nil {
		t.Fatalf("vector record not canonical: %v", err)
	}
}

func TestNDJSON(t *testing.T) {
	journal := "{\"b\":1,\"a\":2}\n[3]\n\"x\"\n"
	f := writeFile(t, "j.jsonl", journal)
	for _, tc := range []struct {
		args []string
		out  string
		code int
	}{
		{[]string{"jcs", f}, `[{"a":2,"b":1},[3],"x"]`, ExitOK},
		{[]string{"jcs", "--head", "2", f}, `[{"a":2,"b":1},[3]]`, ExitOK},
		{[]string{"jcs", "--from", "ndjson", "--head", "1", "-"}, `[{"a":2,"b":1}]`, ExitOK},
		{[]string{"jcs", "--ndjson-array", "--head", "3"}, `[{"a":2,"b":1},[3],"x"]`, ExitOK},
		{[]string{"jcs", "--ndjson-array", "--head", "4"}, ``, ExitRefused},
		{[]string{"jcs", "--ndjson-array", "--sort-set"}, `["x",[3],{"a":2,"b":1}]`, ExitOK},
	} {
		out, errs, code := run(t, journal, tc.args...)
		if code != tc.code || out != tc.out {
			t.Errorf("%q: exit %d %q %q", tc.args, code, out, errs)
		}
	}
	// Framing: CR LF, blank and unterminated lines are refused.
	for _, bad := range []string{"{}\r\n", "{}\n\n", "{}", ""} {
		if _, errs, code := run(t, bad, "jcs", "--ndjson-array"); code != ExitRefused || !strings.Contains(errs, "invalid_json") {
			t.Errorf("%q: exit %d %q", bad, code, errs)
		}
	}
	// A head prefix is read even when later bytes exceed max-bytes.
	if out, _, code := run(t, "1\n"+strings.Repeat("x", 100), "jcs", "--ndjson-array", "--head", "1", "--max-bytes", "10"); code != ExitOK || out != "[1]" {
		t.Errorf("head under max-bytes: exit %d %q", code, out)
	}
}

func TestSortSetYAML(t *testing.T) {
	out, _, code := run(t, "- b\n- {y: 1, x: 2}\n- 10\n- a\n", "jcs", "--from", "yaml", "--sort-set")
	if code != ExitOK || out != `["a","b",10,{"x":2,"y":1}]` {
		t.Fatalf("exit %d %q", code, out)
	}
	_, errs, code := run(t, "a: 1\n", "jcs", "--from", "yaml", "--sort-set")
	if code != ExitRefused || !strings.HasPrefix(errs, "canondocs: yaml: not_an_array: ") {
		t.Fatalf("mapping: exit %d %q", code, errs)
	}
	_, errs, code = run(t, "- 1\n- 1.0\n", "jcs", "--from", "yaml", "--sort-set")
	if code != ExitRefused || !strings.HasPrefix(errs, "canondocs: yaml: duplicate_set_element: ") {
		t.Fatalf("duplicate: exit %d %q", code, errs)
	}
}

func TestLimits(t *testing.T) {
	// Input over max-bytes is too_large for every format.
	if _, errs, code := run(t, `[1,2,3]`, "jcs", "--max-bytes", "6"); code != ExitRefused || !strings.Contains(errs, "too_large") {
		t.Errorf("json: exit %d %q", code, errs)
	}
	if out, _, code := run(t, `[1,2,3]`, "jcs", "--max-bytes", "7"); code != ExitOK || out != "[1,2,3]" {
		t.Errorf("json at limit: exit %d %q", code, out)
	}
	if _, errs, code := run(t, "[1, 2]\n", "jcs", "--from", "yaml", "--max-bytes", "6"); code != ExitRefused || !strings.HasPrefix(errs, "canondocs: yaml: too_large: ") {
		t.Errorf("yaml: exit %d %q", code, errs)
	}
	for _, tc := range []struct {
		input string
		args  []string
		code  string
	}{
		{"[[1]]", []string{"--max-depth", "1"}, "too_deep"},
		{"{a: 1, b: 2}", []string{"--max-object-members", "1"}, "too_large"},
		{"\"abcd\"", []string{"--max-string-bytes", "3"}, "too_large"},
		{"abcd: 1", []string{"--max-string-bytes", "3"}, "too_large"},
		{"[]", []string{"--max-depth", "0"}, "too_deep"},
		{"{a: 1}", []string{"--max-object-members", "0"}, "too_large"},
	} {
		args := append([]string{"jcs", "--from", "yaml"}, tc.args...)
		_, errs, code := run(t, tc.input, args...)
		if code != ExitRefused || !strings.HasPrefix(errs, "canondocs: yaml: "+tc.code+": ") {
			t.Errorf("%q %q: exit %d %q", tc.input, tc.args, code, errs)
		}
	}
	for _, tc := range []struct {
		input, out string
		args       []string
	}{
		{"[[1]]", "[[1]]", []string{"--max-depth", "2"}},
		{"{a: 1}", `{"a":1}`, []string{"--max-object-members", "1"}},
		{"abc: abc", `{"abc":"abc"}`, []string{"--max-string-bytes", "3"}},
		{"1", "1", []string{"--max-depth", "0"}},
	} {
		args := append([]string{"jcs", "--from", "yaml"}, tc.args...)
		out, errs, code := run(t, tc.input, args...)
		if code != ExitOK || out != tc.out {
			t.Errorf("%q %q: exit %d %q %q", tc.input, tc.args, code, out, errs)
		}
	}
	// Depth beyond the YAML loader maximum is refused even when allowed.
	deep := strings.Repeat("[", 256) + strings.Repeat("]", 256)
	if _, errs, code := run(t, deep, "jcs", "--from", "yaml", "--max-depth", "1000"); code != ExitRefused || !strings.Contains(errs, "too_deep") {
		t.Errorf("256 deep: exit %d %q", code, errs)
	}
	ok := strings.Repeat("[", 255) + strings.Repeat("]", 255)
	if out, _, code := run(t, ok, "jcs", "--from", "yaml", "--max-depth", "1000"); code != ExitOK || out != ok {
		t.Errorf("255 deep: exit %d", code)
	}
}

func TestReadsAtMostMaxBytesPlusOne(t *testing.T) {
	r := &countingReader{}
	var out, errb bytes.Buffer
	code := Main([]string{"jcs", "--max-bytes", "10"}, Env{Stdin: r, Stdout: &out, Stderr: &errb})
	if code != ExitRefused || r.n != 11 {
		t.Fatalf("exit %d, read %d bytes", code, r.n)
	}
}

// countingReader is an endless stream of spaces that counts what is read.
type countingReader struct{ n int }

func (c *countingReader) Read(p []byte) (int, error) {
	for i := range p {
		p[i] = ' '
	}
	c.n += len(p)
	return len(p), nil
}

func TestInputError(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "missing.json")
	out, errs, code := run(t, "", "jcs", missing)
	if code != ExitInput || out != "" || !strings.HasPrefix(errs, "canondocs: cannot read ") {
		t.Fatalf("exit %d %q %q", code, out, errs)
	}
	if _, _, code := run(t, "", "jcs", t.TempDir()); code != ExitInput {
		t.Fatalf("directory: exit %d", code)
	}
}

type failWriter struct{ err error }

func (w failWriter) Write([]byte) (int, error) { return 0, w.err }

func TestOutputErrors(t *testing.T) {
	var errb bytes.Buffer
	env := Env{Stdin: strings.NewReader("{}"), Stdout: failWriter{&os.PathError{Op: "write", Path: "|1", Err: syscall.EPIPE}}, Stderr: &errb}
	if code := Main([]string{"jcs"}, env); code != ExitOK || errb.Len() != 0 {
		t.Fatalf("EPIPE: exit %d %q", code, errb.String())
	}
	env.Stdin = strings.NewReader("{}")
	env.Stdout = failWriter{errors.New("disk full")}
	if code := Main([]string{"jcs"}, env); code != ExitOutput || !strings.Contains(errb.String(), "cannot write output") {
		t.Fatalf("other: exit %d %q", code, errb.String())
	}
}

func TestInfoVersionDoctor(t *testing.T) {
	out, _, code := run(t, "", "info")
	if code != ExitOK || !strings.HasSuffix(out, "\n") {
		t.Fatalf("info: exit %d %q", code, out)
	}
	out2, _, _ := run(t, "", "info", "jcs/rfc8785")
	if out2 != out {
		t.Fatalf("info default differs from explicit scheme")
	}
	if err := canon.Check(canon.JCS, []byte(strings.TrimSuffix(out, "\n")), canon.DefaultLimits()); err != nil {
		t.Fatalf("info not canonical: %v", err)
	}
	if !strings.Contains(out, `"scheme":"jcs/rfc8785"`) || !strings.Contains(out, `"corpus_digest":"`+canon.CorpusDigest+`"`) {
		t.Fatalf("info %q", out)
	}

	out, _, code = run(t, "", "version")
	if code != ExitOK || out != "canondocs "+Version+"\n" {
		t.Fatalf("version: %q", out)
	}
	out, _, code = run(t, "", "version", "--json")
	if code != ExitOK || !strings.HasPrefix(out, `{"name":"canondocs","schemes":[{`) || !strings.HasSuffix(out, `"version":"`+Version+"\"}\n") {
		t.Fatalf("version --json: %q", out)
	}
	if err := canon.Check(canon.JCS, []byte(strings.TrimSuffix(out, "\n")), canon.DefaultLimits()); err != nil {
		t.Fatalf("version --json not canonical: %v", err)
	}

	out, errs, code := run(t, "", "doctor")
	if code != ExitOK || !strings.HasSuffix(out, ": ok\n") || errs != "" {
		t.Fatalf("doctor: exit %d %q %q", code, out, errs)
	}
}

func TestVersionMatchesFile(t *testing.T) {
	b, err := os.ReadFile("../../VERSION")
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(b)) != Version {
		t.Fatalf("VERSION %q, Version %q", strings.TrimSpace(string(b)), Version)
	}
}
