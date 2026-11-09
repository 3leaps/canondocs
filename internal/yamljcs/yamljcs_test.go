// SPDX-License-Identifier: MIT OR Apache-2.0

package yamljcs

import (
	"errors"
	"math"
	"testing"
	"unicode/utf8"

	"github.com/3leaps/canonprims/canon"
	"github.com/3leaps/yamlprims/yaml"
)

func TestNoncharacterSet(t *testing.T) {
	n := 0
	for r := rune(0); r <= utf8.MaxRune; r++ {
		if IsNoncharacter(r) {
			n++
			low := r & 0xFFFF
			if !(r >= 0xFDD0 && r <= 0xFDEF) && low != 0xFFFE && low != 0xFFFF {
				t.Fatalf("U+%04X is not a noncharacter", r)
			}
		}
	}
	if n != 66 {
		t.Fatalf("%d noncharacters, want 66", n)
	}
	for _, r := range []rune{-1, utf8.MaxRune + 1, 0x11FFFE, 0xFDCF, 0xFDF0, 0xFFFD} {
		if IsNoncharacter(r) {
			t.Fatalf("U+%04X reported as noncharacter", r)
		}
	}
}

// Every noncharacter is refused in a value and in a key.
func TestNoncharactersRefused(t *testing.T) {
	o := Options{Limits: DefaultLimits()}
	for r := rune(0); r <= utf8.MaxRune; r++ {
		if !IsNoncharacter(r) {
			continue
		}
		esc := []byte(`"\U` + hex8(r) + `"`)
		for _, doc := range [][]byte{esc, append(append([]byte{}, esc...), ": a"...)} {
			_, err := Canonicalize(doc, o)
			var rr *Refusal
			if !errors.As(err, &rr) || rr.Code != Noncharacter {
				t.Fatalf("%s: %v", doc, err)
			}
		}
	}
}

func hex8(r rune) string {
	const digits = "0123456789ABCDEF"
	b := make([]byte, 8)
	for i := 7; i >= 0; i-- {
		b[i] = digits[r&0xF]
		r >>= 4
	}
	return string(b)
}

func walk(t *testing.T, n yaml.Node) ([]byte, error) {
	t.Helper()
	w := walker{limits: DefaultLimits()}
	err := w.node(n, 0)
	return w.out, err
}

func code(err error) Code {
	var r *Refusal
	if errors.As(err, &r) {
		return r.Code
	}
	return ""
}

// The loader rejects unknown tags itself; the walker refuses any Tagged node
// that reaches it, as a value or as a key.
func TestWalkerRefusesTagged(t *testing.T) {
	tagged := yaml.NewSyntheticNode(yaml.TaggedValue(yaml.NewTagged(
		yaml.NewTag("!foo", "!", "foo"), yaml.NewSyntheticNode(yaml.StringValue("x")))))
	if _, err := walk(t, tagged); code(err) != UnsupportedTag {
		t.Fatalf("value: %v", err)
	}
	m := yaml.NewMapping()
	if ie := m.InsertNew(tagged, yaml.NewSyntheticNode(yaml.NullValue())); ie != nil {
		t.Fatal(ie)
	}
	if _, err := walk(t, yaml.NewSyntheticNode(yaml.MappingValue(m))); code(err) != UnsupportedTag {
		t.Fatalf("key: %v", err)
	}
}

func TestWalkerIntegers(t *testing.T) {
	for _, tc := range []struct {
		i  yaml.Integer
		ok bool
	}{
		{yaml.IntegerFromInt64(1<<53 - 1), true},
		{yaml.IntegerFromInt64(-(1<<53 - 1)), true},
		{yaml.IntegerFromInt64(0), true},
		{yaml.IntegerFromInt64(1 << 53), false},
		{yaml.IntegerFromInt64(-(1 << 53)), false},
		{yaml.IntegerFromInt64(math.MinInt64), false},
		{yaml.IntegerFromInt64(math.MaxInt64), false},
		{yaml.IntegerFromUint64(math.MaxUint64), false},
		{yaml.IntegerFromUint128(1, 0), false},
		{yaml.IntegerFromInt128(-1, 0), false},
	} {
		out, err := walk(t, yaml.NewSyntheticNode(yaml.IntValue(tc.i)))
		if tc.ok != (err == nil) {
			t.Fatalf("%s: %q %v", tc.i, out, err)
		}
		if !tc.ok && code(err) != IntegerOutsideIJSON {
			t.Fatalf("%s: %v", tc.i, err)
		}
		if tc.ok && string(out) != tc.i.String() {
			t.Fatalf("%s: %q", tc.i, out)
		}
	}
}

func TestWalkerFloats(t *testing.T) {
	// Expected values are the ECMAScript Number::toString spellings.
	for _, tc := range []struct {
		f    float64
		want string
	}{
		{0.1, "0.1"},
		{1e-7, "1e-7"},
		{2.5e-5, "0.000025"},
		{5e-324, "5e-324"},
		{math.MaxFloat64, "1.7976931348623157e+308"},
		{-math.MaxFloat64, "-1.7976931348623157e+308"},
		{1e21, "1e+21"},
		{1e20, "100000000000000000000"},
		{123456, "123456"},
		{1.0, "1"},
		{math.Copysign(0, -1), "0"},
		{0.30000000000000004, "0.30000000000000004"},
	} {
		out, err := walk(t, yaml.NewSyntheticNode(yaml.FloatValue(tc.f)))
		if err != nil {
			t.Fatal(err)
		}
		got, err := canon.Canonicalize(canon.JCS, out, canon.DefaultLimits())
		if err != nil || string(got) != tc.want {
			t.Fatalf("%v: emitted %q, canonical %q %v, want %q", tc.f, out, got, err, tc.want)
		}
	}
	for _, f := range []float64{math.NaN(), math.Inf(1), math.Inf(-1)} {
		if _, err := walk(t, yaml.NewSyntheticNode(yaml.FloatValue(f))); code(err) != NonFiniteNumber {
			t.Fatalf("%v: %v", f, err)
		}
	}
}

func TestWalkerStringEscapes(t *testing.T) {
	out, err := walk(t, yaml.NewSyntheticNode(yaml.StringValue("a\"\\\x00\x1f\x7f é")))
	if err != nil {
		t.Fatal(err)
	}
	if string(out) != "\"a\\\"\\\\\\u0000\\u001f\x7f é\"" {
		t.Fatalf("%q", out)
	}
	if _, err := walk(t, yaml.NewSyntheticNode(yaml.StringValue("\xff"))); code(err) != InvalidYAML {
		t.Fatalf("invalid utf-8: %v", err)
	}
}

// Loader options are valid for every limit, including 0 and huge values.
func TestLoadOptionsValid(t *testing.T) {
	for _, v := range []int{0, 1, 64, 255, 256, 1 << 20, math.MaxInt} {
		o := Options{Limits: canon.Limits{MaxBytes: v, MaxDepth: v, MaxObjectMembers: v, MaxStringBytes: v}}
		y := LoadOptions(o)
		if err := y.Validate(); err != nil {
			t.Fatalf("%d: %v", v, err)
		}
		if y.UnknownTags != yaml.UnknownTagsReject || y.MergeKeys != yaml.MergeKeysReject {
			t.Fatalf("%d: policy %v %v", v, y.UnknownTags, y.MergeKeys)
		}
	}
	if LoadOptions(Options{Limits: DefaultLimits(), AllowMergeKeys: true}).MergeKeys != yaml.MergeKeysApply {
		t.Fatal("merge keys not applied")
	}
}

func TestProjectionOverMaxBytesIsTooLarge(t *testing.T) {
	// "[a]" (3 bytes) projects to ["a"] (5 bytes): the max-bytes limit
	// applies to the projected JSON as well as to the YAML input.
	o := Options{Limits: DefaultLimits()}
	o.Limits.MaxBytes = 4
	if _, err := Canonicalize([]byte("[a]"), o); code(err) != TooLarge {
		t.Fatalf("%v", err)
	}
	o.Limits.MaxBytes = 5
	if out, err := Canonicalize([]byte("[a]"), o); err != nil || string(out) != `["a"]` {
		t.Fatalf("%q %v", out, err)
	}
}
