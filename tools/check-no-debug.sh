#!/usr/bin/env bash
# Refuse an ostree repo holding a .Debug ref.
#
#   check-no-debug.sh REPO [SOURCE]
#
# No released package ships debug information. flatpak-builder splits an app's debug
# information into a runtime ref named <app-id>.Debug; one arriving here means that app's
# manifest still produces it, so the ref is refused rather than skipped, and the fix belongs in
# the manifest. add-suite runs this on each sibling's repo before pulling, import on the
# bundle's contents before they reach the archive, and check-buildpaths on the archive itself,
# so sign and stage refuse a .Debug ref already there. `make delete-debug-refs` removes those.
set -eu -o pipefail

repo=${1:?usage: check-no-debug.sh REPO [SOURCE]}
source=${2:-$repo}

test -f "$repo/config" || {
	echo "check-no-debug: no ostree repo at $repo" >&2
	exit 2
}

bad=0
while IFS= read -r ref; do
	case "$ref" in
	*.Debug/* | *.Debug)
		echo "check-no-debug: $source carries the debug ref $ref" >&2
		bad=1
		;;
	esac
done < <(ostree --repo="$repo" refs)

[ "$bad" -eq 0 ] || {
	echo "check-no-debug: no released package ships debug information; fix that app's manifest so it produces no .Debug ref" >&2
	exit 1
}
