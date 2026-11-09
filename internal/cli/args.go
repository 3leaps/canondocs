// SPDX-License-Identifier: MIT OR Apache-2.0

package cli

import (
	"math"
	"strconv"
	"strings"
)

// usageError is a command-line error; it exits 2.
type usageError struct{ msg string }

func (e *usageError) Error() string { return e.msg }

func usagef(format string, a ...any) error {
	if len(a) == 0 {
		return &usageError{msg: format}
	}
	return &usageError{msg: sprintf(format, a...)}
}

// flagSpec describes one long option.
type flagSpec struct {
	name     string
	hasValue bool
}

// parsed is the result of parsing one subcommand's arguments.
type parsed struct {
	bools  map[string]bool
	values map[string]string
	pos    []string
	help   bool
}

// parseArgs parses GNU-style long options (--name, --name=value,
// --name value) mixed with positional arguments. "--" ends options; a lone
// "-" is positional. A repeated option is a usage error.
func parseArgs(args []string, specs []flagSpec) (*parsed, error) {
	p := &parsed{bools: map[string]bool{}, values: map[string]string{}}
	seen := map[string]bool{}
	byName := map[string]flagSpec{}
	for _, s := range specs {
		byName[s.name] = s
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			p.pos = append(p.pos, args[i+1:]...)
			break
		}
		if a == "-h" || a == "--help" {
			p.help = true
			continue
		}
		if !strings.HasPrefix(a, "-") || a == "-" {
			p.pos = append(p.pos, a)
			continue
		}
		if !strings.HasPrefix(a, "--") {
			return nil, usagef("unknown option %q", a)
		}
		name, value, hasEq := strings.Cut(a[2:], "=")
		spec, ok := byName[name]
		if !ok {
			return nil, usagef("unknown option --%s", name)
		}
		if seen[name] {
			return nil, usagef("option --%s given more than once", name)
		}
		seen[name] = true
		if !spec.hasValue {
			if hasEq {
				return nil, usagef("option --%s takes no value", name)
			}
			p.bools[name] = true
			continue
		}
		if !hasEq {
			if i+1 >= len(args) {
				return nil, usagef("option --%s needs a value", name)
			}
			i++
			value = args[i]
		}
		p.values[name] = value
	}
	return p, nil
}

// decimal parses a count written as ASCII decimal digits only: no sign,
// space, underscore or other characters.
func decimal(name, s string) (int, error) {
	if s == "" {
		return 0, usagef("--%s: expected decimal digits", name)
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0, usagef("--%s: expected decimal digits, got %q", name, s)
		}
	}
	n, err := strconv.ParseUint(s, 10, 64)
	if err != nil || n > math.MaxInt {
		return 0, usagef("--%s: value %s is too large", name, s)
	}
	return int(n), nil
}
