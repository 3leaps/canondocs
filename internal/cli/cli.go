// SPDX-License-Identifier: MIT OR Apache-2.0

// Package cli implements the canondocs command line.
//
// Data goes to stdout; diagnostics go to stderr. Exit codes:
//
//	0  success (or --check found canonical input; a closed stdout pipe is success)
//	1  input refused, or --check found it not canonical
//	2  usage error
//	4  input could not be read
//	5  output could not be written
package cli

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/3leaps/canonprims/canon"

	"github.com/3leaps/canondocs/internal/yamljcs"
)

// Version is the canondocs version; release builds set it with -ldflags.
var Version = "0.1.0"

// Exit codes.
const (
	ExitOK      = 0
	ExitRefused = 1
	ExitUsage   = 2
	ExitInput   = 4
	ExitOutput  = 5
)

// YAMLProjection names the YAML to I-JSON projection rules implemented here.
const YAMLProjection = "yaml/jcs-rfc8785-v0"

const name = "canondocs"

func sprintf(format string, a ...any) string { return fmt.Sprintf(format, a...) }

// Env is the process environment a command runs in.
type Env struct {
	Stdin  io.Reader
	Stdout io.Writer
	Stderr io.Writer
}

// Main runs canondocs with args (without the program name) and returns the
// exit code.
func Main(args []string, env Env) int {
	if len(args) == 0 {
		fmt.Fprint(env.Stderr, topUsage)
		return ExitUsage
	}
	cmd, rest := args[0], args[1:]
	var code int
	var err error
	switch cmd {
	case "jcs":
		code, err = runJCS(rest, env)
	case "info":
		code, err = runInfo(rest, env)
	case "version":
		code, err = runVersion(rest, env)
	case "doctor":
		code, err = runDoctor(rest, env)
	case "-h", "--help", "help":
		return output(env, []byte(topUsage))
	case "-V", "--version":
		return output(env, []byte(name+" "+Version+"\n"))
	default:
		err = usagef("unknown command %q", cmd)
	}
	if err != nil {
		var u *usageError
		if errors.As(err, &u) {
			fmt.Fprintf(env.Stderr, "%s: %s\n%s: run '%s --help' for usage\n", name, u.msg, name, name)
			return ExitUsage
		}
		fmt.Fprintf(env.Stderr, "%s: %v\n", name, err)
		return ExitRefused
	}
	return code
}

const topUsage = `canondocs: RFC 8785 (JCS) canonical JSON from JSON, YAML and NDJSON input

Usage:
  canondocs jcs [options] [file|-]   canonicalize, check, digest or vector
  canondocs info [scheme]            describe a scheme as canonical JSON
  canondocs version [--json]         print the version
  canondocs doctor                   run a built-in self-check

Run 'canondocs jcs --help' for jcs options.
`

const jcsUsage = `Usage: canondocs jcs [options] [file|-]

Reads file (or stdin when file is "-" or absent) and writes its RFC 8785
canonical bytes, with no trailing newline.

Options:
  --from auto|json|yaml|ndjson  input format (default auto: .yaml/.yml is YAML,
                                .ndjson/.jsonl is NDJSON, anything else and
                                stdin is JSON)
  --check                       write nothing; exit 0 only if the JSON input is
                                already canonical
  --digest                      write sha256:<hex> of the canonical bytes, then LF
  --vector                      write a canonical JSON vector record, then LF
  --ndjson-array                read LF-terminated NDJSON lines as one array
  --head N                      with NDJSON input, use exactly the first N lines
  --sort-set                    treat the array as a set: sort elements by their
                                canonical bytes, refuse duplicates
  --allow-merge-keys            apply YAML "<<" merge keys instead of refusing them
  --max-bytes N                 largest input in bytes (default 16777216)
  --max-depth N                 deepest array/object nesting (default 64)
  --max-object-members N        most members in one object (default 65536)
  --max-string-bytes N          largest decoded string in bytes (default 4194304)
`

var jcsFlags = []flagSpec{
	{"from", true},
	{"check", false},
	{"digest", false},
	{"vector", false},
	{"ndjson-array", false},
	{"head", true},
	{"sort-set", false},
	{"allow-merge-keys", false},
	{"max-bytes", true},
	{"max-depth", true},
	{"max-object-members", true},
	{"max-string-bytes", true},
}

// Format is an input format.
type Format string

// Input formats.
const (
	FormatJSON   Format = "json"
	FormatYAML   Format = "yaml"
	FormatNDJSON Format = "ndjson"
)

// jcsConfig is a validated jcs invocation.
type jcsConfig struct {
	file           string // "" or "-" is stdin
	format         Format
	check          bool
	digest         bool
	vector         bool
	sortSet        bool
	allowMergeKeys bool
	head           int // 0: all lines
	limits         canon.Limits
}

func parseJCS(args []string) (*jcsConfig, bool, error) {
	p, err := parseArgs(args, jcsFlags)
	if err != nil {
		return nil, false, err
	}
	if p.help {
		return nil, true, nil
	}
	if len(p.pos) > 1 {
		return nil, false, usagef("jcs takes at most one input file")
	}
	c := &jcsConfig{
		check:          p.bools["check"],
		digest:         p.bools["digest"],
		vector:         p.bools["vector"],
		sortSet:        p.bools["sort-set"],
		allowMergeKeys: p.bools["allow-merge-keys"],
		limits:         yamljcs.DefaultLimits(),
	}
	if len(p.pos) == 1 {
		c.file = p.pos[0]
	}
	for flag, dst := range map[string]*int{
		"max-bytes":          &c.limits.MaxBytes,
		"max-depth":          &c.limits.MaxDepth,
		"max-object-members": &c.limits.MaxObjectMembers,
		"max-string-bytes":   &c.limits.MaxStringBytes,
	} {
		if s, ok := p.values[flag]; ok {
			if *dst, err = decimal(flag, s); err != nil {
				return nil, false, err
			}
		}
	}
	headSet := false
	if s, ok := p.values["head"]; ok {
		if c.head, err = decimal("head", s); err != nil {
			return nil, false, err
		}
		if c.head < 1 {
			return nil, false, usagef("--head must be at least 1")
		}
		headSet = true
	}

	ndjsonArray := p.bools["ndjson-array"]
	from := "auto"
	if s, ok := p.values["from"]; ok {
		from = s
	}
	switch from {
	case "auto":
		c.format = detect(c.file)
		if ndjsonArray {
			if c.format == FormatYAML {
				return nil, false, usagef("--ndjson-array conflicts with YAML input %q", c.file)
			}
			c.format = FormatNDJSON
		}
	case "json", "yaml":
		c.format = Format(from)
		if ndjsonArray {
			return nil, false, usagef("--ndjson-array conflicts with --from %s", from)
		}
	case "ndjson":
		c.format = FormatNDJSON
	default:
		return nil, false, usagef("--from must be auto, json, yaml or ndjson, got %q", from)
	}

	if headSet && c.format != FormatNDJSON {
		return nil, false, usagef("--head needs NDJSON input (--ndjson-array or --from ndjson)")
	}
	if c.allowMergeKeys && c.format != FormatYAML {
		return nil, false, usagef("--allow-merge-keys needs YAML input")
	}
	if c.check && c.format != FormatJSON {
		return nil, false, usagef("--check needs JSON input; %s input is never already canonical", c.format)
	}
	n := 0
	for _, b := range []bool{c.check, c.digest, c.vector} {
		if b {
			n++
		}
	}
	if n > 1 {
		return nil, false, usagef("--check, --digest and --vector are mutually exclusive")
	}
	return c, false, nil
}

// detect picks the format for --from auto from the file name.
func detect(file string) Format {
	if file == "" || file == "-" {
		return FormatJSON
	}
	switch strings.ToLower(filepath.Ext(file)) {
	case ".yaml", ".yml":
		return FormatYAML
	case ".ndjson", ".jsonl":
		return FormatNDJSON
	}
	return FormatJSON
}

func runJCS(args []string, env Env) (int, error) {
	c, help, err := parseJCS(args)
	if err != nil {
		return 0, err
	}
	if help {
		return output(env, []byte(jcsUsage)), nil
	}
	lines := 0
	if c.format == FormatNDJSON {
		lines = c.head
	}
	input, err := readInput(c.file, c.limits.MaxBytes, lines, env.Stdin)
	if err != nil {
		label := c.file
		if label == "" {
			label = "-"
		}
		fmt.Fprintf(env.Stderr, "%s: cannot read %s: %v\n", name, label, err)
		return ExitInput, nil
	}
	if c.check {
		if c.sortSet {
			err = canon.CheckCanonicalSet(input, c.limits)
		} else {
			err = canon.Check(canon.JCS, input, c.limits)
		}
		if err != nil {
			return refused(env, err), nil
		}
		return ExitOK, nil
	}
	canonical, err := canonicalOutput(c, input)
	if err != nil {
		return refused(env, err), nil
	}
	switch {
	case c.vector:
		// The input was bounded when it was read; the assembled output may
		// be longer than it, so only the size limit is lifted here.
		l := c.limits
		l.MaxBytes = math.MaxInt
		v, err := canon.VectorOfCanonical(canonical, l)
		if err != nil {
			return refused(env, err), nil
		}
		return output(env, append(v.JSON(), '\n')), nil
	case c.digest:
		return output(env, []byte(digest(canonical)+"\n")), nil
	default:
		return output(env, canonical), nil
	}
}

// canonicalOutput returns the canonical bytes for the input format and mode.
func canonicalOutput(c *jcsConfig, input []byte) ([]byte, error) {
	switch c.format {
	case FormatYAML:
		o := yamljcs.Options{Limits: c.limits, AllowMergeKeys: c.allowMergeKeys}
		if c.sortSet {
			return yamljcs.SortCanonicalSet(input, o)
		}
		return yamljcs.Canonicalize(input, o)
	case FormatNDJSON:
		if !c.sortSet {
			return canon.CanonicalizeNDJSON(input, c.head, c.limits)
		}
		elements, err := canon.NDJSONElements(input, c.head, c.limits)
		if err != nil {
			return nil, err
		}
		// Each element was bounded as a line of the input.
		l := c.limits
		l.MaxBytes = math.MaxInt
		return canon.AssembleCanonicalSet(elements, l)
	default:
		if c.sortSet {
			return canon.SortCanonicalSet(input, c.limits)
		}
		return canon.Canonicalize(canon.JCS, input, c.limits)
	}
}

func digest(b []byte) string {
	sum := sha256.Sum256(b)
	return "sha256:" + hex.EncodeToString(sum[:])
}

// readInput reads at most maxBytes+1 bytes, so oversized input is refused as
// too_large without being read in full. When lines > 0 it stops after the
// lines-th LF, so an NDJSON prefix is answered without waiting for the rest
// of the stream.
func readInput(file string, maxBytes, lines int, stdin io.Reader) ([]byte, error) {
	limit := int64(maxBytes)
	if limit < math.MaxInt64 {
		limit++
	}
	var r io.Reader
	if file == "" || file == "-" {
		r = stdin
	} else {
		f, err := os.Open(file)
		if err != nil {
			return nil, err
		}
		defer f.Close()
		r = f
	}
	r = io.LimitReader(r, limit)
	if lines <= 0 {
		return io.ReadAll(r)
	}
	br := bufio.NewReader(r)
	var buf []byte
	for i := 0; i < lines; i++ {
		line, err := br.ReadBytes('\n')
		buf = append(buf, line...)
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
	}
	return buf, nil
}

// refused reports a refusal on stderr and returns exit code 1.
func refused(env Env, err error) int {
	var cr canon.Refusal
	var yr *yamljcs.Refusal
	switch {
	case errors.As(err, &yr):
		fmt.Fprintf(env.Stderr, "%s: yaml: %s: %s\n", name, yr.Code, yrMessage(yr))
	case errors.As(err, &cr):
		fmt.Fprintf(env.Stderr, "%s: %s: %s at byte %d\n", name, canon.JCS, cr.Code, cr.Offset)
	default:
		fmt.Fprintf(env.Stderr, "%s: %v\n", name, err)
	}
	return ExitRefused
}

func yrMessage(r *yamljcs.Refusal) string {
	if r.Offset >= 0 {
		return fmt.Sprintf("%s (at byte %d)", r.Message, r.Offset)
	}
	return r.Message
}

// output writes b to stdout and returns the exit code. A closed pipe is the
// reader's choice and counts as success.
func output(env Env, b []byte) int {
	_, err := env.Stdout.Write(b)
	if err == nil {
		return ExitOK
	}
	if errors.Is(err, syscall.EPIPE) {
		return ExitOK
	}
	fmt.Fprintf(env.Stderr, "%s: cannot write output: %v\n", name, err)
	return ExitOutput
}

func runInfo(args []string, env Env) (int, error) {
	p, err := parseArgs(args, nil)
	if err != nil {
		return 0, err
	}
	if p.help {
		return output(env, []byte("Usage: canondocs info [scheme]\n\nDescribes a scheme (default jcs/rfc8785) as one canonical JSON object.\n")), nil
	}
	if len(p.pos) > 1 {
		return 0, usagef("info takes at most one scheme")
	}
	scheme := string(canon.JCS)
	if len(p.pos) == 1 {
		scheme = p.pos[0]
	}
	doc, err := schemeInfo(canon.Scheme(scheme))
	if err != nil {
		return 0, usagef("unknown scheme %q", scheme)
	}
	return output(env, append(doc, '\n')), nil
}

// schemeInfo returns the canonical JSON description of scheme s.
func schemeInfo(s canon.Scheme) ([]byte, error) {
	i, err := canon.Info(s)
	if err != nil {
		return nil, err
	}
	return canonicalJSON(map[string]any{
		"scheme":          i.Name,
		"spec":            i.Spec,
		"corpus":          i.Corpus,
		"corpus_digest":   i.CorpusDigest,
		"inputs":          []string{string(FormatJSON), string(FormatNDJSON), string(FormatYAML)},
		"yaml_projection": YAMLProjection,
	})
}

// canonicalJSON marshals v and canonicalizes the result.
func canonicalJSON(v any) ([]byte, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	return canon.Canonicalize(canon.JCS, b, canon.DefaultLimits())
}

func runVersion(args []string, env Env) (int, error) {
	p, err := parseArgs(args, []flagSpec{{"json", false}})
	if err != nil {
		return 0, err
	}
	if p.help {
		return output(env, []byte("Usage: canondocs version [--json]\n")), nil
	}
	if len(p.pos) > 0 {
		return 0, usagef("version takes no arguments")
	}
	if !p.bools["json"] {
		return output(env, []byte(name+" "+Version+"\n")), nil
	}
	info, err := schemeInfo(canon.JCS)
	if err != nil {
		return 0, err
	}
	doc, err := canonicalJSON(map[string]any{
		"name":    name,
		"version": Version,
		"schemes": []json.RawMessage{info},
	})
	if err != nil {
		return 0, err
	}
	return output(env, append(doc, '\n')), nil
}

// Built-in self-check samples; both must canonicalize to doctorExpect.
const (
	doctorJSON   = `{"b":[1.0,2e0,-0,"é\t"],"a":{"z":null,"y":true}}`
	doctorYAML   = "b: [1.0, 2, -0.0, \"\\u00e9\\t\"]\na: {z: ~, y: true}\n"
	doctorExpect = "{\"a\":{\"y\":true,\"z\":null},\"b\":[1,2,0,\"é\\t\"]}"
)

func runDoctor(args []string, env Env) (int, error) {
	p, err := parseArgs(args, nil)
	if err != nil {
		return 0, err
	}
	if p.help {
		return output(env, []byte("Usage: canondocs doctor\n\nCanonicalizes built-in JSON and YAML samples and compares the result.\n")), nil
	}
	if len(p.pos) > 0 {
		return 0, usagef("doctor takes no arguments")
	}
	j, err := canon.Canonicalize(canon.JCS, []byte(doctorJSON), yamljcs.DefaultLimits())
	if err != nil || string(j) != doctorExpect {
		fmt.Fprintf(env.Stderr, "%s: doctor: json self-check failed\n", name)
		return ExitRefused, nil
	}
	y, err := yamljcs.Canonicalize([]byte(doctorYAML), yamljcs.Options{Limits: yamljcs.DefaultLimits()})
	if err != nil || string(y) != doctorExpect {
		fmt.Fprintf(env.Stderr, "%s: doctor: yaml self-check failed\n", name)
		return ExitRefused, nil
	}
	return output(env, []byte("json: ok\nyaml: ok\n"+name+" "+Version+": ok\n")), nil
}
