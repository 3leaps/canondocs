#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Refuses tracked (and untracked, not ignored) files that contain absolute
# home-directory paths or non-public identifiers. Patterns are built
# from fragments so this script does not match itself.
set -eu

home='/Us''ers/|/ho''me/[a-z]|~/d''ev/'
ids='CD''OC-|CA''NP-|CR''U-[0-9]|YP''-TASK|GN''T-[0-9]|SY''SP-'
roles='cxo''tech|ent''arch|dev''lead|matter''most'

scan() {
	git ls-files -z --cached --others --exclude-standard |
		xargs -0 grep -n -I "$@" -- 2>/dev/null || true
}

found="$(scan -E "$home|$ids")$(scan -i -E "$roles")"
if [ -n "$found" ]; then
	printf '%s\n' "$found"
	echo "content-check: forbidden content found" >&2
	exit 1
fi
echo "content-check: ok"
