#!/usr/bin/env bash
# Guard the one fact this archive cannot get wrong: which key signs it.
#
# The authority is the Makefile's GPG_KEY: a dedicated flatpak key, separate
# from the apt archive's key because the two archives have different
# lifecycles, and separate from commit keys because signing packages and
# signing commits must never share a compromise. This archive was once built
# with a personal commit-signing key because that fingerprint was to hand and
# nobody checked it against a source; every document is checked against the
# Makefile here, and sharing the apt key is checked against too.
set -eu -o pipefail

APT=${APT:-../amberlinux-apt}
bad() { echo "lint: $*" >&2; status=1; }
status=0

# The key this archive signs with.
mine=$(sed -n 's/^GPG_KEY[[:space:]]*?*=[[:space:]]*//p' Makefile | tr -d '[:space:]')
[ -n "$mine" ] || { echo "lint: Makefile has no GPG_KEY" >&2; exit 1; }

# The keys must differ: sharing the apt key entangles two archives with
# different lifecycles in one compromise. Absent sibling, say so.
if [ -f "$APT/conf/distributions" ]; then
	theirs=$(sed -n 's/^SignWith:[[:space:]]*//p' "$APT/conf/distributions" | tr -d '[:space:]')
	if [ -z "$theirs" ]; then
		bad "$APT/conf/distributions has no SignWith line"
	elif [ "$mine" = "$theirs" ]; then
		bad "GPG_KEY equals the apt archive key — the archives sign with separate keys"
	fi
else
	echo "lint: $APT not present — cannot check GPG_KEY differs from the apt key" >&2
fi

# Every fingerprint printed in a doc must be the one that signs, or a reader
# verifies against a key that signed nothing.
found=0
while IFS= read -r f; do
	while read -r printed; do
		found=$((found + 1))
		[ "$printed" = "$mine" ] || bad "$f states fingerprint $printed, GPG_KEY is $mine"
	done < <(grep -ohE '\b[0-9A-F]{40}\b|\b[0-9A-F]{16}\b' "$f" || true)
done < <(git ls-files '*.md')
[ "$found" -gt 0 ] || bad "no document states the archive fingerprint; users have nothing to check"

# The SVG is committed so reading the repo needs no d2; that only helps if it
# still matches. Regenerate with `make diags`.
for src in diags/*.d2; do
	[ -e "$src" ] || continue
	svg=${src%.d2}.svg
	[ -f "$svg" ] || { bad "$src has no committed $svg (run 'make diags')"; continue; }
	if command -v d2 >/dev/null; then
		tmp=$(mktemp -d)
		d2 --theme=105 --dark-theme=300 --pad=40 "$src" "$tmp/out.svg" >/dev/null 2>&1
		cmp -s "$tmp/out.svg" "$svg" || bad "$svg is stale (run 'make diags')"
		rm -rf "$tmp"
	fi
done

# Publishing must never leave the machine that holds the key.
git ls-files | grep -qE '^\.github/workflows/.*deploy' && \
	bad "a workflow appears to deploy; the signing key is not in CI and must not be"

[ "$status" -eq 0 ] && echo "lint: signing key $mine is its own, differs from the apt key, and matches every document"
exit "$status"
