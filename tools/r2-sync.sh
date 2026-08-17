#!/usr/bin/env bash
# Upload out/objects/** and out/deltas/** to the R2 bucket the worker serves
# from. ostree object names are content-addressed — the checksum is the
# filename — so an object never changes once written, and a key that already
# exists remotely can be skipped. What has been uploaded before is tracked in
# .r2-synced (gitignored) rather than by asking R2, which would be one HTTP
# round trip per object across a couple of thousand of them.
#
# Uploads run in parallel because they are latency-bound, not bandwidth-bound:
# a single `wrangler r2 object put` takes about 2.7s almost regardless of the
# object's size, and an ostree repo of a bundled toolchain is ~2000 objects.
# Sequentially that is an hour and a half; at JOBS=8 it is minutes.
#
# wrangler's CLI upload stops at 300 MiB. Nothing an ostree repo produces should
# approach that — objects are individually compressed files — but the check is
# here rather than as an assumption, because the failure it prevents is a
# summary naming an object the worker cannot serve.
set -eu -o pipefail

BUCKET=${BUCKET:-amberlinux-flatpak-objects}
OUT=${OUT:-out}
WRANGLER=${WRANGLER:-wrangler}
JOBS=${JOBS:-8}
WRANGLER_CAP=$((300 * 1024 * 1024))
MANIFEST=.r2-synced

test -d "$OUT/objects" || {
	echo "r2-sync: $OUT/objects missing — run make stage first" >&2
	exit 2
}
command -v "$WRANGLER" >/dev/null || {
	echo "r2-sync: $WRANGLER not on PATH" >&2
	exit 2
}
touch "$MANIFEST"

work=$(mktemp)
done_dir=$(mktemp -d)
trap 'rm -f "$work"; rm -rf "$done_dir"' EXIT

# Build the work list: everything not already recorded as uploaded.
#
# "Content-addressed" is true of .filez, .dirtree and .dirmeta, whose name IS
# their checksum. It is NOT true of two others, and both bit us:
#
#   .commitmeta  named after the commit it annotates; its contents change when
#                a signature is added. Serving a stale one gives "GPG
#                verification enabled, but no signatures found" at install,
#                while remote-ls succeeds because that only reads the summary.
#   deltas/**    named after the commit pair; regenerating a delta rewrites it
#                under the same key. Serving a stale one gives "Invalid checksum
#                for static delta".
#
# Both are therefore always re-uploaded, never skipped.
skipped=0
while IFS= read -r -d '' file; do
	key=${file#"$OUT"/}
	case "$key" in
	*.commitmeta | deltas/*) : ;;
	*)
		if grep -qxF "$key" "$MANIFEST"; then
			skipped=$((skipped + 1))
			continue
		fi
		;;
	esac
	size=$(stat -c%s "$file")
	if [ "$size" -gt "$WRANGLER_CAP" ]; then
		echo "r2-sync: $key is $size bytes, over wrangler's 300 MiB cap." >&2
		echo "  Uploading it needs S3 multipart against the R2 endpoint —" >&2
		echo "  see amberlinux-apt's tools/r2-sync.sh, which already does this." >&2
		exit 3
	fi
	printf '%s\t%s\n' "$key" "$file" >>"$work"
done < <(find "$OUT/objects" "$OUT/deltas" -type f -print0 2>/dev/null)

total=$(wc -l <"$work" | tr -d ' ')
echo "r2-sync: $total to upload, $skipped already present, JOBS=$JOBS"
[ "$total" -eq 0 ] && exit 0

# Each worker writes a marker on success, so a crashed or killed run records
# exactly what actually landed rather than assuming the whole batch did.
export BUCKET WRANGLER done_dir
upload_one() {
	key=${1%%$'\t'*}
	file=${1#*$'\t'}
	if "$WRANGLER" r2 object put "$BUCKET/$key" --file "$file" --remote >/dev/null 2>&1; then
		printf '%s\n' "$key" >"$done_dir/$(printf '%s' "$key" | tr / _)"
	else
		echo "r2-sync: FAILED $key" >&2
		return 1
	fi
}
export -f upload_one

failed=0
xargs -a "$work" -d '\n' -P "$JOBS" -I{} bash -c 'upload_one "$@"' _ {} || failed=1

cat "$done_dir"/* 2>/dev/null >>"$MANIFEST" || true
uploaded=$(find "$done_dir" -type f | wc -l | tr -d ' ')
echo "r2-sync: uploaded $uploaded of $total"

if [ "$failed" -ne 0 ] || [ "$uploaded" -ne "$total" ]; then
	echo "r2-sync: some uploads failed — re-run to retry only what is missing" >&2
	exit 4
fi
