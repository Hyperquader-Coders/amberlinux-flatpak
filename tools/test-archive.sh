#!/usr/bin/env bash
# make test: the archive's tooling, run on a throwaway archive. It needs no secret and none of
# this checkout's state (build/repo), so a fresh checkout and the CI run it as they run lint.
#
# In one temporary directory, removed on exit:
#   gnupg/    a GNUPGHOME holding a throwaway signing key without a passphrase; GNUPGHOME is
#             exported before the first gpg call, so ~/.gnupg and the archive key are never read
#   sibling/  a stand-in suite repository: a Makefile answering `make flatpak-repo-path` with an
#             ostree repo holding one fixture runtime and one fixture app that runs on it
#   fixture.flatpak  a bundle of a second fixture runtime
#   archive/  the archive every target below is given as OUT
#
# A fixture runtime is one text file and its metadata, exported with
# `flatpak build-export --runtime`, which writes the commit metadata a real flatpak client reads.
# The fixture app runs on the sibling's runtime and carries a desktop file, so `sign` writes its
# install file (tools/write-flatpakrefs.sh) with the app's name as its title. URL is the local
# server and RUNTIME_REPO the archive's own .flatpakrepo, so `verify-client` installs the app
# through that file, and its runtime with it, without leaving this machine.
#
# Then the Makefile's own targets run against that archive: `add-suite` (preflight, ostree
# init, pull-local from the sibling), `import` (the bundle), `check-buildpaths`, `sign`,
# `verify`, `verify-fresh` (against the sibling) and `verify-client` (a real flatpak client
# installs the app through its install file and every other ref from the remote, over local
# HTTP with GPG verification on, in a throwaway installation). The code under test is the
# code `stage` and `deploy` run.
#
# The negative case: a .Debug runtime, in a second sibling and in a second bundle. `add-suite`
# and `import` must refuse each, naming the ref, and leave the archive without it. The ref is
# then forced into the archive with ostree pull-local; `check-buildpaths` and `sign` must refuse
# it, `delete-debug-refs` must remove it, and the archive must sign, verify and install again.
#
# GPG_KEY is given to those targets on the command line, so they sign with the throwaway key.
# `make lint` is not weakened by that: tools/lint.sh reads the GPG_KEY line from the Makefile's
# text, not the variable, so ci's lint still checks every document and the apt key against the
# real archive key. The throwaway key is never compared with a document; nothing here prints it
# anywhere but this run's output.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
make=${MAKE:-make}
arch=$(flatpak --default-arch)
id=org.amberlinux.Fixture

die() {
	echo "test: $*" >&2
	exit 1
}

tmp=$(mktemp -d)
export GNUPGHOME=$tmp/gnupg
cleanup() {
	gpgconf --kill all 2>/dev/null || true
	rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' \
	--quick-gen-key 'amberlinux-flatpak test archive <test@amberlinux.invalid>' ed25519 sign 1d
fpr=$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')
[ -n "$fpr" ] || die "the throwaway key has no fingerprint"
echo "test: throwaway key $fpr in $GNUPGHOME"

# runtime NAME REPO: export a one-file runtime NAME on branch test into the ostree repo REPO.
runtime() {
	local name=$1 repo=$2 dir
	dir=$(mktemp -d "$tmp/rt.XXXXXX")
	mkdir -p "$dir/files" "$dir/usr"
	printf '[Runtime]\nname=%s\nruntime=%s/%s/test\nsdk=%s/%s/test\n' \
		"$name" "$name" "$arch" "$name" "$arch" >"$dir/metadata"
	echo "The one file of the runtime make test publishes." >"$dir/usr/README"
	[ -f "$repo/config" ] || ostree --repo="$repo" init --mode=archive-z2
	flatpak build-export --runtime "$repo" "$dir" test >/dev/null
}

# app NAME RUNTIME REPO: export a one-file app NAME on branch test, running on RUNTIME, into REPO.
app() {
	local name=$1 rt=$2 repo=$3 dir
	dir=$(mktemp -d "$tmp/app.XXXXXX")
	mkdir -p "$dir/files/bin" "$dir/files/share/applications" "$dir/export"
	printf '[Application]\nname=%s\nruntime=%s/%s/test\nsdk=%s/%s/test\ncommand=fixture\n' \
		"$name" "$rt" "$arch" "$rt" "$arch" >"$dir/metadata"
	printf '#!/bin/sh\necho fixture\n' >"$dir/files/bin/fixture"
	chmod +x "$dir/files/bin/fixture"
	printf '[Desktop Entry]\nType=Application\nName=Fixture App\nExec=fixture\n' \
		>"$dir/files/share/applications/$name.desktop"
	flatpak build-export "$repo" "$dir" test >/dev/null
}

# sibling DIR NAME: a suite repository whose `make flatpak-repo-path` names a repo holding NAME.
sibling() {
	mkdir -p "$1"
	runtime "$2" "$1/repo"
	printf 'flatpak-repo-path:\n\t@echo $(CURDIR)/repo\n' >"$1/Makefile"
}

sibling "$tmp/sibling" "$id"
app "$id.App" "$id" "$tmp/sibling/repo"
runtime "$id.Bundled" "$tmp/bundle-repo"
flatpak build-bundle --runtime "$tmp/bundle-repo" "$tmp/fixture.flatpak" "$id.Bundled" test
sibling "$tmp/sibling-debug" "$id.Debug"
runtime "$id.Bundled.Debug" "$tmp/bundle-debug-repo"
flatpak build-bundle --runtime "$tmp/bundle-debug-repo" "$tmp/fixture-debug.flatpak" "$id.Bundled.Debug" test

# A free port, so a running `make serve` or a parallel test does not collide.
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')

archive=$tmp/archive
vars=(OUT="$archive" GPG_KEY="$fpr" SUITE="$tmp/sibling" PORT="$port" VERIFY_CACHE=
	URL="http://127.0.0.1:$port/" RUNTIME_REPO="http://127.0.0.1:$port/amberlinux.flatpakrepo")
run() {
	echo "test: make $*"
	"$make" -C "$root" --no-print-directory "${vars[@]}" "$@"
}

run add-suite
run import BUNDLE="$tmp/fixture.flatpak"
for target in check-buildpaths sign verify verify-fresh verify-client; do
	run "$target"
done

refs=$(ostree --repo="$archive" refs)
for ref in "runtime/$id/$arch/test" "runtime/$id.Bundled/$arch/test" "app/$id.App/$arch/test"; do
	grep -qx "$ref" <<<"$refs" || die "the archive lacks $ref"
done
ref_file=$archive/apps/$id.App.flatpakref
for line in "Title=Fixture App" "Name=$id.App" "Branch=test" "SuggestRemoteName=amberlinux" \
	"RuntimeRepo=http://127.0.0.1:$port/amberlinux.flatpakrepo"; do
	grep -qxF "$line" "$ref_file" || die "$ref_file lacks $line"
done
[ "$(find "$archive/apps" -type f | wc -l)" = 1 ] || die "sign wrote an install file for a runtime"
grep -qF "flatpak install --from http://127.0.0.1:$port/apps/$id.App.flatpakref" "$archive/index.html" ||
	die "the landing page does not list $id.App"

# refuse REF TARGET...: make TARGET must fail, with tools/check-no-debug.sh naming REF.
refuse() {
	local ref=$1 out
	shift
	echo "test: make $* must refuse $ref"
	if out=$("$make" -C "$root" --no-print-directory "${vars[@]}" "$@" 2>&1); then
		echo "$out"
		die "make $* accepted $ref"
	fi
	grep -qF "carries the debug ref $ref" <<<"$out" || {
		echo "$out"
		die "make $* failed without naming $ref"
	}
}

debug=runtime/$id.Debug/$arch/test
refuse "$debug" add-suite SUITE="$tmp/sibling-debug"
refuse "runtime/$id.Bundled.Debug/$arch/test" import BUNDLE="$tmp/fixture-debug.flatpak"
! ostree --repo="$archive" refs | grep -q '\.Debug/' || die "a refused .Debug ref reached the archive"

ostree --repo="$archive" pull-local "$tmp/sibling-debug/repo" >/dev/null
refuse "$debug" check-buildpaths
refuse "$debug" sign
run delete-debug-refs
! ostree --repo="$archive" refs | grep -q '\.Debug/' || die "delete-debug-refs left a .Debug ref"
for target in check-buildpaths sign verify verify-client; do
	run "$target"
done

echo "test: OK, two fixture runtimes and an app added, imported, signed and installed by flatpak over HTTP,"
echo "test: OK, the app through its install file;"
echo "test: OK, .Debug refs refused by add-suite, import, check-buildpaths and sign, and deleted"
