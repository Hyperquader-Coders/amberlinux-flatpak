#!/usr/bin/env bash
# One install file per app, OUT/apps/<app id>.flatpakref, and the landing page's list of them:
# OUT/index.html's `<!-- apps -->` line becomes one entry per app.
#
#   REPO=build/repo OUT=build/repo URL=https://flatpak.amberlinux.org/ \
#   RUNTIME_REPO=https://dl.flathub.org/repo/flathub.flatpakrepo GPG_KEY=<fpr> \
#   tools/write-flatpakrefs.sh
#
# A user installs an app with `flatpak install --from <url>` or a click in the browser. Flatpak
# adds this archive as the remote `amberlinux`, verifies it against the key the file embeds, and
# takes the app's runtime from RUNTIME_REPO when no configured remote has it. That last step is
# why the file exists: the archive holds the suite's apps but not the GNOME and freedesktop
# runtimes they run on, a machine without Flathub has nowhere to find them, and the flatpak CLI
# honours RuntimeRepo only in a .flatpakref, never in the .flatpakrepo.
#
# An app's file leaves this archive when the app moves to Flathub (docs/UPSTREAM.md).
set -eu -o pipefail

: "${REPO:?}" "${OUT:?}" "${URL:?}" "${RUNTIME_REPO:?}" "${GPG_KEY:?}"

key=$(gpg --export-options export-minimal --export "$GPG_KEY" | base64 -w0)
[ -n "$key" ] || {
	echo "write-flatpakrefs: gpg exports nothing for $GPG_KEY" >&2
	exit 1
}

dir=$OUT/apps
rm -rf "${dir:?}"
mkdir -p "$dir"
list=

for ref in $(ostree --repo="$REPO" refs | grep '^app/' || true); do
	IFS=/ read -r _ id _ branch <<<"$ref"
	file=$dir/$id.flatpakref
	[ ! -e "$file" ] || {
		echo "write-flatpakrefs: $id is in the archive on two branches; an install file names one" >&2
		exit 1
	}
	title=$(ostree --repo="$REPO" cat "$ref" "/files/share/applications/$id.desktop" 2>/dev/null |
		sed -n 's/^Name=//p' | head -n1 || true)
	printf '[Flatpak Ref]\nTitle=%s\nName=%s\nBranch=%s\nUrl=%s\nSuggestRemoteName=amberlinux\nHomepage=https://amberlinux.org/\nIsRuntime=false\nGPGKey=%s\nRuntimeRepo=%s\n' \
		"${title:-$id}" "$id" "$branch" "$URL" "$key" "$RUNTIME_REPO" >"$file"
	echo "install file for $ref: apps/$id.flatpakref"
	list+="<h3><a href=\"${URL}apps/$id.flatpakref\">${title:-$id}</a></h3>
<pre><code>flatpak install --from ${URL}apps/$id.flatpakref</code></pre>
"
done

page=$OUT/index.html
[ ! -f "$page" ] || {
	grep -qx '<!-- apps -->' "$page" || {
		echo "write-flatpakrefs: $page has no <!-- apps --> line" >&2
		exit 1
	}
	printf '%s' "${list:-<p>No apps yet.</p>
}" >"$OUT/.apps.html"
	sed -i -e "/^<!-- apps -->\$/{r $OUT/.apps.html" -e 'd}' "$page"
	rm -f "$OUT/.apps.html"
}
