// SPDX-License-Identifier: MIT OR Apache-2.0

// Package yamljcs projects one YAML 1.2.2 Core Schema document onto I-JSON
// (RFC 7493) and canonicalizes it under RFC 8785 (JCS).
//
// The projection follows six rules:
//
//  1. The stream holds exactly one document. A stream with no document is
//     empty_stream; more than one is multi_document_stream. An explicit empty
//     document ("---") or an explicit null is JSON null.
//  2. Integers lie in -(2^53-1) .. 2^53-1; any other is integer_outside_ijson.
//  3. Floats are finite; .nan, .inf and -.inf are non_finite_number.
//  4. Every mapping key resolves to a string; any other is non_string_key.
//     Repeated keys are duplicate_key.
//  5. Tags outside the Core Schema are unsupported_tag. Merge keys ("<<") are
//     merge_key_rejected unless merge keys are explicitly allowed.
//  6. Strings and keys contain none of the 66 Unicode noncharacters
//     (noncharacter); depth and size limits give too_deep and too_large.
//
// Any other load failure is invalid_yaml. The projection emits plain JSON
// text, which is then canonicalized by the canonprims canon package, so the
// JCS serialization has a single implementation.
package yamljcs

import (
	"errors"
	"fmt"
	"math"
	"strconv"
	"unicode/utf8"

	"github.com/3leaps/canonprims/canon"
	"github.com/3leaps/yamlprims/yaml"
)

// Code is a refusal code for YAML input.
type Code string

// Refusal codes.
const (
	EmptyStream         Code = "empty_stream"
	MultiDocumentStream Code = "multi_document_stream"
	IntegerOutsideIJSON Code = "integer_outside_ijson"
	NonFiniteNumber     Code = "non_finite_number"
	NonStringKey        Code = "non_string_key"
	UnsupportedTag      Code = "unsupported_tag"
	MergeKeyRejected    Code = "merge_key_rejected"
	Noncharacter        Code = "noncharacter"
	TooDeep             Code = "too_deep"
	TooLarge            Code = "too_large"
	DuplicateKey        Code = "duplicate_key"
	InvalidYAML         Code = "invalid_yaml"
)

// Refusal reports YAML input outside the projection's domain.
type Refusal struct {
	// Code is the normative refusal code.
	Code Code
	// Offset is an informative byte offset into the YAML input, or -1 when
	// the refusal has no source position.
	Offset int
	// Message is a short human-readable description.
	Message string
}

// Error implements error.
func (r *Refusal) Error() string {
	if r.Offset >= 0 {
		return fmt.Sprintf("%s: %s at byte %d", r.Code, r.Message, r.Offset)
	}
	return fmt.Sprintf("%s: %s", r.Code, r.Message)
}

// Options controls loading and canonicalization.
type Options struct {
	// Limits bounds the YAML input (MaxBytes), the projected JSON text and
	// its canonicalization (all four limits).
	Limits canon.Limits
	// AllowMergeKeys applies "<<" merge keys instead of refusing them.
	AllowMergeKeys bool
}

// DefaultLimits returns the canondocs default limits: 16 MiB input, depth 64,
// 65536 members per object, 4 MiB per string.
func DefaultLimits() canon.Limits {
	return canon.Limits{
		MaxBytes:         16 << 20,
		MaxDepth:         64,
		MaxObjectMembers: 65536,
		MaxStringBytes:   4 << 20,
	}
}

// maxYAMLDepth is the largest depth the YAML loader accepts.
const maxYAMLDepth = 255

// LoadOptions returns the yamlprims options used for o: unknown tags
// rejected, merge keys rejected unless allowed, and loader budgets derived
// from the limits. Budgets the loader requires to be at least 1 are raised
// to 1; the projection then enforces the exact limit.
func LoadOptions(o Options) yaml.Options {
	y := yaml.DefaultOptions()
	y.UnknownTags = yaml.UnknownTagsReject
	if o.AllowMergeKeys {
		y.MergeKeys = yaml.MergeKeysApply
	} else {
		y.MergeKeys = yaml.MergeKeysReject
	}
	l := o.Limits
	y.Limits.MaxInputBytes = atLeast1(l.MaxBytes)
	y.Limits.MaxDepth = min(atLeast1(l.MaxDepth), maxYAMLDepth)
	y.Limits.MaxScalarBytes = atLeast1(l.MaxStringBytes)
	// A key's weight is its string bytes plus a fixed per-node charge.
	y.Limits.MaxKeyBytes = satAdd(atLeast1(l.MaxStringBytes), int(yaml.NodeOverhead))
	y.Limits.MaxMappingEntries = atLeast1(l.MaxObjectMembers)
	// Two documents are enough to tell a single-document stream from a
	// multi-document one.
	y.Limits.MaxDocuments = 2
	y.Limits.MaxOwnedBytes = max(y.Limits.MaxOwnedBytes, y.Limits.MaxScalarBytes, y.Limits.MaxKeyBytes)
	return y
}

// ToJSON loads input as a single YAML document and returns it as JSON text
// (not canonical). Failures are *Refusal.
func ToJSON(input []byte, o Options) ([]byte, error) {
	if len(input) > max(o.Limits.MaxBytes, 0) {
		return nil, &Refusal{Code: TooLarge, Offset: max(o.Limits.MaxBytes, 0), Message: "input exceeds max bytes"}
	}
	docs, yerr := yaml.LoadAllBytes(input, LoadOptions(o))
	if yerr != nil {
		return nil, fromYAMLError(yerr)
	}
	switch len(docs) {
	case 0:
		return nil, &Refusal{Code: EmptyStream, Offset: 0, Message: "stream holds no document"}
	case 1:
	default:
		return nil, &Refusal{Code: MultiDocumentStream, Offset: docOffset(docs[1]), Message: "stream holds more than one document"}
	}
	w := walker{limits: o.Limits}
	if err := w.node(docs[0].IntoRoot(), 0); err != nil {
		return nil, err
	}
	return w.out, nil
}

// Canonicalize returns the RFC 8785 canonical bytes of the single YAML
// document in input.
func Canonicalize(input []byte, o Options) ([]byte, error) {
	j, err := ToJSON(input, o)
	if err != nil {
		return nil, err
	}
	out, err := canon.Canonicalize(canon.JCS, j, o.Limits)
	return out, fromCanon(err)
}

// SortCanonicalSet returns the canonical set form of the YAML document in
// input, which must be a sequence: elements sorted by their canonical bytes,
// with no two identical.
func SortCanonicalSet(input []byte, o Options) ([]byte, error) {
	j, err := ToJSON(input, o)
	if err != nil {
		return nil, err
	}
	out, err := canon.SortCanonicalSet(j, o.Limits)
	return out, fromCanon(err)
}

// fromCanon turns a canon refusal on the projected JSON into a *Refusal.
// The canon offset points into the projection, not the YAML input, so it is
// dropped.
func fromCanon(err error) error {
	if err == nil {
		return nil
	}
	var r canon.Refusal
	if errors.As(err, &r) {
		return &Refusal{Code: Code(r.Code), Offset: -1, Message: "refused after projection to JSON"}
	}
	return err
}

func fromYAMLError(e *yaml.Error) *Refusal {
	off := -1
	if loc, ok := e.Location(); ok {
		off = loc.ByteOffset
	}
	r := &Refusal{Offset: off, Message: e.Message}
	switch e.Kind {
	case yaml.ErrorKindLimitExceeded:
		switch e.Detail.Limit {
		case yaml.LimitMaxDepth:
			r.Code = TooDeep
		case yaml.LimitMaxDocuments:
			r.Code = MultiDocumentStream
			r.Message = "stream holds more than one document"
		default:
			r.Code = TooLarge
		}
	case yaml.ErrorKindMultipleDocuments:
		r.Code = MultiDocumentStream
	case yaml.ErrorKindDuplicateKey:
		r.Code = DuplicateKey
	case yaml.ErrorKindInvalidKey:
		// A NaN key: a float key, which is never a string.
		r.Code = NonStringKey
	case yaml.ErrorKindMergeRejected:
		r.Code = MergeKeyRejected
	case yaml.ErrorKindUnknownTag:
		r.Code = UnsupportedTag
	case yaml.ErrorKindIntegerOutOfRange:
		r.Code = IntegerOutsideIJSON
	case yaml.ErrorKindFloatOutOfRange:
		r.Code = NonFiniteNumber
	default:
		r.Code = InvalidYAML
	}
	if r.Message == "" {
		r.Message = string(e.Kind)
	}
	return r
}

func docOffset(d yaml.Document) int {
	if s, ok := d.IntoRoot().Span(); ok {
		return s.Start.ByteOffset
	}
	return -1
}

func nodeOffset(n yaml.Node) int {
	if s, ok := n.Span(); ok {
		return s.Start.ByteOffset
	}
	return -1
}

// maxSafeInteger is 2^53 - 1.
const maxSafeInteger = 1<<53 - 1

// walker writes JSON text for a resolved node tree. Its recursion is bounded
// by the depth limit (and by the loader, which never exceeds 255 levels).
type walker struct {
	limits canon.Limits
	out    []byte
}

// node writes n, which sits under depth collections.
func (w *walker) node(n yaml.Node, depth int) error {
	v := n.Value()
	switch v.Kind() {
	case yaml.ValueKindNull:
		w.out = append(w.out, "null"...)
	case yaml.ValueKindBool:
		b, _ := v.AsBool()
		w.out = strconv.AppendBool(w.out, b)
	case yaml.ValueKindInt:
		i, _ := v.AsInt()
		// Exact integer comparison; no conversion to float first.
		x, ok := i.Int64()
		if !ok || x > maxSafeInteger || x < -maxSafeInteger {
			return &Refusal{Code: IntegerOutsideIJSON, Offset: nodeOffset(n), Message: "integer outside -(2^53-1)..2^53-1"}
		}
		w.out = strconv.AppendInt(w.out, x, 10)
	case yaml.ValueKindFloat:
		f, _ := v.AsFloat()
		if math.IsNaN(f) || math.IsInf(f, 0) {
			return &Refusal{Code: NonFiniteNumber, Offset: nodeOffset(n), Message: "float is not finite"}
		}
		// Shortest round-trip spelling; canonicalization reformats it.
		w.out = strconv.AppendFloat(w.out, f, 'g', -1, 64)
	case yaml.ValueKindString:
		s, _ := v.AsStr()
		return w.str(s, nodeOffset(n))
	case yaml.ValueKindSequence:
		if err := w.enter(n, depth); err != nil {
			return err
		}
		items, _ := v.AsSequence()
		w.out = append(w.out, '[')
		for i, item := range items {
			if i > 0 {
				w.out = append(w.out, ',')
			}
			if err := w.node(item, depth+1); err != nil {
				return err
			}
		}
		w.out = append(w.out, ']')
	case yaml.ValueKindMapping:
		if err := w.enter(n, depth); err != nil {
			return err
		}
		m, _ := v.AsMapping()
		w.out = append(w.out, '{')
		for i := 0; i < m.Len(); i++ {
			k, val := m.At(i)
			if i > 0 {
				w.out = append(w.out, ',')
			}
			kv := k.Value()
			switch kv.Kind() {
			case yaml.ValueKindString:
			case yaml.ValueKindTagged:
				return &Refusal{Code: UnsupportedTag, Offset: nodeOffset(k), Message: "tagged mapping key"}
			default:
				return &Refusal{Code: NonStringKey, Offset: nodeOffset(k), Message: "mapping key is " + kv.KindName() + ", not string"}
			}
			ks, _ := kv.AsStr()
			if err := w.str(ks, nodeOffset(k)); err != nil {
				return err
			}
			w.out = append(w.out, ':')
			if err := w.node(val, depth+1); err != nil {
				return err
			}
		}
		w.out = append(w.out, '}')
	case yaml.ValueKindTagged:
		return &Refusal{Code: UnsupportedTag, Offset: nodeOffset(n), Message: "tag outside the Core Schema"}
	default:
		return &Refusal{Code: InvalidYAML, Offset: nodeOffset(n), Message: "unknown value kind " + v.KindName()}
	}
	return nil
}

// enter checks that a collection at depth+1 fits the depth limit.
func (w *walker) enter(n yaml.Node, depth int) error {
	if depth+1 > w.limits.MaxDepth || depth+1 > maxYAMLDepth {
		return &Refusal{Code: TooDeep, Offset: nodeOffset(n), Message: "nesting exceeds max depth"}
	}
	return nil
}

// str writes s as a JSON string, refusing noncharacters and ill-formed UTF-8.
func (w *walker) str(s string, off int) error {
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		if r == utf8.RuneError && size <= 1 {
			return &Refusal{Code: InvalidYAML, Offset: off, Message: "string is not valid UTF-8"}
		}
		if IsNoncharacter(r) {
			return &Refusal{Code: Noncharacter, Offset: off, Message: fmt.Sprintf("noncharacter U+%04X", r)}
		}
		i += size
	}
	w.out = append(w.out, '"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"' || c == '\\':
			w.out = append(w.out, '\\', c)
		case c < 0x20:
			w.out = append(w.out, '\\', 'u', '0', '0', hex[c>>4], hex[c&0xf])
		default:
			w.out = append(w.out, c)
		}
	}
	w.out = append(w.out, '"')
	return nil
}

const hex = "0123456789abcdef"

// IsNoncharacter reports whether r is one of the 66 Unicode noncharacters
// (U+FDD0..U+FDEF and U+nFFFE, U+nFFFF for planes 0 through 16).
func IsNoncharacter(r rune) bool {
	return (r >= 0xFDD0 && r <= 0xFDEF) || (r >= 0 && r <= utf8.MaxRune && r&0xFFFE == 0xFFFE)
}

func atLeast1(n int) int {
	if n < 1 {
		return 1
	}
	return n
}

func satAdd(a, b int) int {
	if a > math.MaxInt-b {
		return math.MaxInt
	}
	return a + b
}
