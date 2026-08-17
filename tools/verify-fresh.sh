#!/usr/bin/env bash
# Every ref the archive publishes must be the commit its sibling currently
# builds. verify-client.sh proves the tree is signed and installable; it passes
# just as happily on a ref pulled hours ago, and yggr builds against this
# archive, so a stale ref is a silently stale toolchain.
#
# The apt archive compares the SHA256 in its Packages index against each repo's
# `make deb-path`. The ostree equivalent is this: compare the commit checksum of
# every ref against the repo each sibling answers `make flatpak-repo` with.
#
# A sibling that is not checked out, or has not built, is skipped with a note
# rather than treated as fresh — the suite is developed one repo at a time.
set -eu -o pipefail

OUT=${OUT:-out}
SUITE=${SUITE:?verify-fresh: SUITE not set}

test -f "$OUT/config" || {
	echo "verify-fresh: no ostree repo at $OUT — run make build first" >&2
	exit 2
}

stale=0 checked=0 skipped=0 missing=0
for repo in $SUITE; do
	[ -d "$repo" ] || { echo "  skip     $repo (not checked out)"; skipped=$((skipped + 1)); continue; }
	# --no-print-directory: under a parent make invoked with -C, MAKEFLAGS
	# carries --print-directory into this sub-make, and the Entering/Leaving
	# banners land in the captured path — which then "is not a repo", and the
	# freshness gate silently skips every sibling.
	src=$(make --no-print-directory -C "$repo" -s flatpak-repo 2>/dev/null) || {
		echo "  skip     $repo (nothing built — run 'make repo' there)"
		skipped=$((skipped + 1)); continue; }
	[ -d "$src" ] || {
		echo "  skip     $repo ($src is not a repo)"
		skipped=$((skipped + 1)); continue; }
	refs=$(ostree --repo="$src" refs) || {
		echo "  skip     $repo ($src has no readable refs)"
		skipped=$((skipped + 1)); continue; }

	for ref in $refs; do
		# appstream/ and appstream2/ are regenerated here by
		# `flatpak build-update-repo`, not pulled from the sibling, so they are
		# expected to differ and comparing them would report a permanent lie.
		case "$ref" in appstream/* | appstream2/*) continue ;; esac

		want=$(ostree --repo="$src" rev-parse "$ref")
		have=$(ostree --repo="$OUT" rev-parse "$ref" 2>/dev/null || true)
		checked=$((checked + 1))
		if [ -z "$have" ]; then
			# Absent is visible to users the moment they try to install it;
			# stale is the failure nothing else catches.
			echo "  absent   $ref is not in the archive"
			missing=$((missing + 1))
		elif [ "$have" != "$want" ]; then
			echo "  STALE    $ref: archive has ${have:0:12}…, $repo builds ${want:0:12}…"
			stale=$((stale + 1))
		else
			echo "  ok       $ref"
		fi
	done
done

if [ "$stale" -ne 0 ]; then
	echo "verify-fresh: $stale ref(s) older than their repo — 'make add-suite', then stage again" >&2
	exit 1
fi
echo "verify-fresh: $((checked - missing)) ref(s) match their repo's current build ($missing absent, $skipped skipped)"
