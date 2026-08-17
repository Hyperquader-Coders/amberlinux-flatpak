#!/usr/bin/env bash
# Refuse to touch the archive unless the tools are present and the archive key
# can actually sign. Without this a missing or locked key yields a silently
# unsigned tree that only fails on the user's machine, at `flatpak install`.
#
# The apt archive has the same gate for the same reason.
set -eu -o pipefail

GPG_KEY=${GPG_KEY:?set GPG_KEY}
status=0
bad() { echo "preflight: $*" >&2; status=1; }

for t in ostree flatpak gpg; do
	command -v "$t" >/dev/null || bad "$t is not installed"
done

# Present is not the same as usable: the key may be public-only on this machine,
# or its private half may be on a smartcard that is not plugged in.
if command -v gpg >/dev/null; then
	gpg --list-secret-keys "$GPG_KEY" >/dev/null 2>&1 || \
		bad "no secret key for $GPG_KEY — this machine cannot sign the archive"

	# Actually sign something. A secret key can exist and still fail to sign:
	# expired, revoked, or a passphrase this session cannot supply.
	if ! echo preflight | gpg --local-user "$GPG_KEY" --sign --output /dev/null 2>/dev/null; then
		bad "$GPG_KEY cannot sign here (expired, revoked, or no passphrase available)"
	fi
fi

[ "$status" -eq 0 ] && echo "preflight: tools present, $GPG_KEY can sign"
exit "$status"
