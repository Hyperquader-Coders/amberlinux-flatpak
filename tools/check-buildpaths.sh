#!/usr/bin/env bash
# Refuse to sign a tree that names the machine it was built on.
#
# The ostree port of amberlinux-apt's tools/check-no-buildpaths.sh: check out
# every ref the archive would publish and scan its ELF files. strip does not
# remove these strings — Odin's Source_Code_Location and a configure prefix
# both land in .rodata — so the only reliable gate is reading the bytes that
# would ship. A flatpak-builder sandbox leaves /run/build/<module> paths, which
# are identical for every builder and carry no machine detail; those pass.
#
# Fail only on paths naming the publishing machine. Upstream binaries carry
# their own vendors' build paths (Alpine's /home/buildozer and the like), which
# are upstream's to fix, not ours — reported, not fatal. HOME is overridable so
# a run on one machine can check paths leaked from another.
set -uo pipefail

OUT=${OUT:-out}
PUBLISHER_HOME=${PUBLISHER_HOME:-$HOME}

test -f "$OUT/config" || {
	echo "check-buildpaths: no ostree repo at $OUT — run make build first" >&2
	exit 2
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0 checked=0

for ref in $(ostree --repo="$OUT" refs); do
	# appstream trees are generated metadata, not built binaries.
	case "$ref" in appstream/* | appstream2/*) continue ;; esac
	checked=$((checked + 1))

	rm -rf "$tmp/x"
	# --disable-cache: a plain checkout populates uncompressed-objects-cache/
	# inside the repo — hundreds of MB of working state that wrangler would
	# then try to publish as static assets.
	ostree --repo="$OUT" checkout --disable-cache --user-mode "$ref" "$tmp/x" || {
		echo "check-buildpaths: cannot check out $ref" >&2
		fail=1
		continue
	}

	hits="" foreign=0
	while IFS= read -r f; do
		[ "$(head -c4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ] || continue
		p=$(strings -a "$f" \
			| grep -aoE '(/home/[A-Za-z0-9_.-]+|/root|/tmp)/[A-Za-z0-9_./+-]*' | sort -u)
		[ -n "$p" ] || continue
		ours=$(grep -F "$PUBLISHER_HOME/" <<<"$p" || true)
		if [ -n "$ours" ]; then
			n=$(grep -c . <<<"$ours")
			hits="$hits${f#"$tmp/x"} :: $(head -1 <<<"$ours")$([ "$n" -gt 1 ] && echo "  (+$((n - 1)) more)")"$'\n'
		fi
		grep -qvF "$PUBLISHER_HOME/" <<<"$p" && foreign=1
	done < <(find "$tmp/x" -type f 2>/dev/null)

	note=""
	[ "$foreign" -eq 1 ] && note="  (carries upstream vendors' own build paths)"
	if [ -n "$hits" ]; then
		echo "LEAK — $ref names this machine:"
		sed 's/^/    /' <<<"${hits%$'\n'}"
		fail=1
	else
		echo "  ok  $ref$note"
	fi
done

[ "$checked" -gt 0 ] || { echo "check-buildpaths: no refs to check — run make add-suite or make import" >&2; exit 2; }
[ "$fail" -eq 0 ] || { echo "check-buildpaths: refusing to sign the above"; exit 1; }
echo "check-buildpaths: no ref names the machine it was built on"
