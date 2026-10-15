#!/usr/bin/env bash
# Prove the tree works for a real flatpak client, with signature verification on,
# without touching the machine's own flatpak installation.
#
#   verify-client.sh                  serves build/repo/ over HTTP and tests that
#   verify-client.sh https://…        tests a published URL instead
#
# Two things this does that a weaker check does not, both learned the hard way:
#
#   - It never passes --no-gpg-verify. A check that disables verification proves
#     the archive is readable and says nothing about whether it is signed, which
#     is the half that actually protects a user.
#   - It installs, rather than listing. `flatpak remote-ls` reads only the
#     summary, so it succeeds against a repo whose commits are unsigned or whose
#     static deltas are stale, both of which then fail at install time.
#   - It installs each app through its install file (tools/write-flatpakrefs.sh) on a client
#     that has no Flathub, so an app whose runtime a fresh machine cannot find fails here.
set -eu -o pipefail

OUT=${OUT:-build/repo}
PORT=${PORT:-8011}
HOST=${HOST:-127.0.0.1}
BASE=${1:-}

srv=
tmp=$(mktemp -d)
cleanup() {
	[ -n "$srv" ] && kill "$srv" 2>/dev/null || true
	rm -rf "$tmp"
}
trap cleanup EXIT

if [ -z "$BASE" ]; then
	test -s "$OUT/summary" || {
		echo "verify-client: no $OUT/summary: run make sign" >&2
		exit 2
	}
	python3 -m http.server "$PORT" --bind "$HOST" --directory "$OUT" >/dev/null 2>&1 &
	srv=$!
	sleep 1
	BASE="http://$HOST:$PORT"
	keyring="$OUT/amberlinux-flatpak.gpg"
else
	keyring=$tmp/keyring.gpg
	curl -fsS "$BASE/amberlinux-flatpak.gpg" -o "$keyring" || {
		echo "verify-client: $BASE serves no keyring" >&2
		exit 1
	}

	# The zone behaviours the archive depends on, asserted here so a
	# Cloudflare setting change fails this check instead of users' installs.
	hdrs=$tmp/headers
	curl -fsSD "$hdrs" -o "$tmp/summary" "$BASE/summary" || {
		echo "verify-client: $BASE serves no summary" >&2
		exit 1
	}
	grep -qi '^cache-control:.*no-cache' "$hdrs" || {
		echo "verify-client: summary is not no-cache: a cached summary against fresh objects breaks installs" >&2
		exit 1
	}
	grep -qi '^strict-transport-security:' "$hdrs" || {
		echo "verify-client: no HSTS on $BASE" >&2
		exit 1
	}
	# A wrangler version swap propagates over a few seconds; retry before
	# calling drift, so the post-deploy check does not race its own deploy.
	if [ -s "$OUT/summary" ]; then
		tries=0
		until cmp -s "$tmp/summary" "$OUT/summary"; do
			tries=$((tries + 1))
			[ "$tries" -le 6 ] || {
				echo "verify-client: published summary differs byte-wise from $OUT/summary: deploy, or the local tree is stale" >&2
				exit 1
			}
			sleep 5
			curl -fsS -o "$tmp/summary" "$BASE/summary"
		done
	fi
	code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/objects/00/no-such-object.filez")
	[ "$code" = 404 ] || {
		echo "verify-client: missing object answers $code, not 404" >&2
		exit 1
	}
	obj=$(cd "$OUT" 2>/dev/null && find objects -name '*.filez' -type f -print -quit || true)
	if [ -n "$obj" ]; then
		curl -fsSI --compressed "$BASE/$obj" >"$hdrs"
		grep -qi '^content-encoding:' "$hdrs" && {
			echo "verify-client: object served with Content-Encoding, so clients decompress twice" >&2
			exit 1
		}
		grep -qi '^cache-control:.*immutable' "$hdrs" || {
			echo "verify-client: object is not cached immutable" >&2
			exit 1
		}
	fi
	case "$BASE" in https://*)
		plain="http://${BASE#https://}"
		code=$(curl -s -o /dev/null -w '%{http_code}' "$plain/summary")
		loc=$(curl -s -o /dev/null -w '%{redirect_url}' "$plain/summary")
		{ [ "$code" = 301 ] && [ "${loc#https://}" != "$loc" ]; } || {
			echo "verify-client: plain http answers $code -> '$loc', not a 301 to https" >&2
			exit 1
		}
		;;
	esac
	echo "verify-client: CDN behaviour holds (no-cache summary, HSTS, 404s, immutable uncompressed objects, http 301s)"
fi

# The client sees nothing of this machine's flatpak: its own user installation, an empty
# system installation and no extra installations. A runtime the system happens to have
# installed would otherwise satisfy an app that a fresh machine cannot run.
#
# The user installation is VERIFY_CACHE when set, so the runtimes an app takes from Flathub are
# fetched once; everything from this archive is removed from it first, so each run installs
# the archive's refs afresh. Empty VERIFY_CACHE: a throwaway installation.
export FLATPAK_SYSTEM_DIR="$tmp/system" FLATPAK_CONFIG_DIR="$tmp/config"
export FLATPAK_USER_DIR="${VERIFY_CACHE:-$tmp/flatpak}"
mkdir -p "$FLATPAK_SYSTEM_DIR" "$FLATPAK_CONFIG_DIR" "$FLATPAK_USER_DIR"
for ref in $(flatpak list --user --columns=ref,origin 2>/dev/null | awk '$2 == "amberlinux" { print $1 }'); do
	flatpak uninstall --user --noninteractive "$ref" >/dev/null
done
flatpak remote-delete --user --force amberlinux >/dev/null 2>&1 || true

# The refs the archive advertises, read by a separate throwaway installation so listing
# them proves nothing about the one that installs.
list=$tmp/list
mkdir -p "$list"
FLATPAK_USER_DIR=$list flatpak remote-add --user --gpg-import="$keyring" verify "$BASE/" >/dev/null 2>&1 || {
	echo "verify-client: a fresh client cannot add $BASE" >&2
	exit 1
}
# Against a publish, wait until the listing is the local tree's: just after a deploy an edge can
# still serve the previous index for a few seconds, so its refs differ while the summary
# already matches. remote-ls leaves out appstream and .Locale refs, and so does the comparison.
want=
[ -n "$srv" ] || [ ! -s "$OUT/summary" ] ||
	want=$(ostree --repo="$OUT" refs | grep -Ev '^appstream2?/|\.Locale/' | sort)
tries=0
while :; do
	refs=$(FLATPAK_USER_DIR=$list flatpak remote-ls --user --columns=ref verify 2>/dev/null | grep . | sort || true)
	if [ -n "$refs" ] && { [ -z "$want" ] || [ "$refs" = "$want" ]; }; then
		break
	fi
	tries=$((tries + 1))
	[ "$tries" -le 6 ] || {
		if [ -z "$refs" ]; then
			echo "verify-client: $BASE advertises no refs" >&2
		else
			echo "verify-client: $BASE advertises other refs than $OUT: deploy, or the local tree is stale" >&2
		fi
		exit 1
	}
	sleep 5
done

# One retry after a pause: assets and R2 objects swap at slightly different
# moments after a deploy, and the gate must not race that window.
retry() {
	"$@" >/dev/null 2>&1 || {
		sleep 20
		"$@" >/dev/null 2>&1
	}
}
served_as_ref() {
	curl -fsSI "$1" | grep -qi '^content-type: *application/vnd\.flatpak\.ref'
}

# Every app through its install file, as a user installs it: the file adds the remote,
# verification on, and fetches the app's runtime from its RuntimeRepo. The file must embed
# the key the archive signs with. Served locally, the file names the published URL; it is
# pointed at the local server and is otherwise the file a user gets.
key=$(gpg --dearmor <"$keyring" | base64 -w0)
for ref in $(grep '^app/' <<<"$refs" || true); do
	IFS=/ read -r _ id _ _ <<<"$ref"
	file=$tmp/$id.flatpakref
	curl -fsS "$BASE/apps/$id.flatpakref" -o "$file" || {
		echo "verify-client: $ref has no install file at $BASE/apps/$id.flatpakref" >&2
		exit 1
	}
	grep -qxF "GPGKey=$key" "$file" || {
		echo "verify-client: apps/$id.flatpakref does not embed the archive's key" >&2
		exit 1
	}
	grep -q '^RuntimeRepo=.' "$file" || {
		echo "verify-client: apps/$id.flatpakref names no RuntimeRepo" >&2
		exit 1
	}
	if [ -n "$srv" ]; then
		sed -i "s|^Url=.*|Url=$BASE/|" "$file"
	else
		grep -qxF "Url=$BASE/" "$file" || {
			echo "verify-client: apps/$id.flatpakref does not name $BASE/" >&2
			exit 1
		}
		# The type is what makes a browser hand the file to the software centre.
		retry served_as_ref "$BASE/apps/$id.flatpakref" || {
			echo "verify-client: apps/$id.flatpakref is not served as application/vnd.flatpak.ref" >&2
			exit 1
		}
	fi
	retry flatpak install --user --noninteractive --from "$file" || {
		echo "verify-client: $ref will not install from apps/$id.flatpakref" >&2
		exit 1
	}
	echo "verify-client: $ref installs from its install file, GPG-verified, runtime included"
done

# Every other ref (SDK extensions, locales) from the remote the install files added, or
# from one added with the keyring when the archive holds no app.
flatpak remote-list --user --columns=name | grep -qx amberlinux ||
	flatpak remote-add --user --gpg-import="$keyring" amberlinux "$BASE/" >/dev/null 2>&1 || {
	echo "verify-client: a fresh client cannot add $BASE" >&2
	exit 1
}
installed=$(flatpak list --user --columns=ref,origin | awk '$2 == "amberlinux" { print $1 }')
for ref in $refs; do
	case "$ref" in app/*) continue ;; esac
	grep -qxF "${ref#*/}" <<<"$installed" && {
		echo "verify-client: $ref installed alongside its app"
		continue
	}
	retry flatpak install --user --noninteractive amberlinux "$ref" || {
		echo "verify-client: $ref is advertised but will not install from $BASE" >&2
		exit 1
	}
	echo "verify-client: $ref installs, GPG-verified"
done

echo "verify-client: $BASE OK"
