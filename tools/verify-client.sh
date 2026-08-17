#!/usr/bin/env bash
# Prove the tree works for a real flatpak client, with signature verification on,
# without touching the machine's own flatpak installation.
#
#   verify-client.sh                  serves out/ over HTTP and tests that
#   verify-client.sh https://…        tests a published URL instead
#
# Two things this does that a weaker check does not, both learned the hard way:
#
#   - It never passes --no-gpg-verify. A check that disables verification proves
#     the archive is readable and says nothing about whether it is signed, which
#     is the half that actually protects a user.
#   - It installs, rather than listing. `flatpak remote-ls` reads only the
#     summary, so it succeeds against a repo whose commits are unsigned or whose
#     static deltas are stale — both of which then fail at install time.
set -eu -o pipefail

OUT=${OUT:-out}
PORT=${PORT:-8011}
HOST=${HOST:-127.0.0.1}
BASE=${1:-}

srv=
tmp=$(mktemp -d)
cleanup() { [ -n "$srv" ] && kill "$srv" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT

if [ -z "$BASE" ]; then
	test -s "$OUT/summary" || { echo "verify-client: no $OUT/summary — run make sign" >&2; exit 2; }
	python3 -m http.server "$PORT" --bind "$HOST" --directory "$OUT" >/dev/null 2>&1 &
	srv=$!
	sleep 1
	BASE="http://$HOST:$PORT"
	keyring="$OUT/amberlinux-flatpak.gpg"
else
	keyring=$tmp/keyring.gpg
	curl -fsS "$BASE/amberlinux-flatpak.gpg" -o "$keyring" || {
		echo "verify-client: $BASE serves no keyring" >&2; exit 1; }

	# The zone behaviours the archive depends on, asserted here so a
	# Cloudflare setting change fails this check instead of users' installs.
	hdrs=$tmp/headers
	curl -fsSD "$hdrs" -o "$tmp/summary" "$BASE/summary" || {
		echo "verify-client: $BASE serves no summary" >&2; exit 1; }
	grep -qi '^cache-control:.*no-cache' "$hdrs" || {
		echo "verify-client: summary is not no-cache — a cached summary against fresh objects breaks installs" >&2; exit 1; }
	grep -qi '^strict-transport-security:' "$hdrs" || {
		echo "verify-client: no HSTS on $BASE" >&2; exit 1; }
	# A wrangler version swap propagates over a few seconds; retry before
	# calling drift, so the post-deploy check does not race its own deploy.
	if [ -s "$OUT/summary" ]; then
		tries=0
		until cmp -s "$tmp/summary" "$OUT/summary"; do
			tries=$((tries + 1))
			[ "$tries" -le 6 ] || {
				echo "verify-client: published summary differs byte-wise from $OUT/summary — deploy, or the local tree is stale" >&2
				exit 1
			}
			sleep 5
			curl -fsS -o "$tmp/summary" "$BASE/summary"
		done
	fi
	code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/objects/00/no-such-object.filez")
	[ "$code" = 404 ] || {
		echo "verify-client: missing object answers $code, not 404" >&2; exit 1; }
	obj=$(cd "$OUT" 2>/dev/null && find objects -name '*.filez' -type f | head -1 || true)
	if [ -n "$obj" ]; then
		curl -fsSI --compressed "$BASE/$obj" >"$hdrs"
		grep -qi '^content-encoding:' "$hdrs" && {
			echo "verify-client: object served with Content-Encoding — clients decompress twice" >&2; exit 1; }
		grep -qi '^cache-control:.*immutable' "$hdrs" || {
			echo "verify-client: object is not cached immutable" >&2; exit 1; }
	fi
	case "$BASE" in https://*)
		plain="http://${BASE#https://}"
		code=$(curl -s -o /dev/null -w '%{http_code}' "$plain/summary")
		loc=$(curl -s -o /dev/null -w '%{redirect_url}' "$plain/summary")
		{ [ "$code" = 301 ] && [ "${loc#https://}" != "$loc" ]; } || {
			echo "verify-client: plain http answers $code -> '$loc', not a 301 to https" >&2; exit 1; }
	esac
	echo "verify-client: CDN behaviour holds (no-cache summary, HSTS, 404s, immutable uncompressed objects, http 301s)"
fi

export FLATPAK_USER_DIR="$tmp/flatpak"
mkdir -p "$FLATPAK_USER_DIR"

flatpak remote-add --user --gpg-import="$keyring" verify "$BASE/" >/dev/null 2>&1 || {
	echo "verify-client: a fresh client cannot add $BASE" >&2; exit 1; }

refs=$(flatpak remote-ls --user verify 2>/dev/null | awk '{print $2}' | grep . || true)
[ -n "$refs" ] || { echo "verify-client: $BASE advertises no refs" >&2; exit 1; }

# Install every ref the archive advertises, verification on. This is the
# check. One retry after a pause: assets and R2 objects swap at slightly
# different moments after a deploy, and the gate must not race that window.
for ref in $refs; do
	if ! flatpak install --user --noninteractive verify "$ref" >/dev/null 2>&1; then
		sleep 20
		flatpak install --user --noninteractive verify "$ref" >/dev/null 2>&1 || {
			echo "verify-client: $ref is advertised but will not install from $BASE" >&2
			exit 1; }
	fi
	echo "verify-client: $ref installs, GPG-verified"
done

echo "verify-client: $BASE OK"
