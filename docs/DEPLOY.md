# DEPLOY.md — publishing the flatpak archive

Publishing happens **on the machine that holds the signing key**, and nowhere
else. The archive is signed with its own dedicated key,
`060DD386E634C5C445DF3A7F2BE23FC60996C427` (`flatpak@amberlinux.org`) — not
the apt archive's key, and not anyone's commit-signing key. Its private half
lives in that machine's `~/.gnupg`; nothing in this repository contains it and
no CI job has it. That is the same commitment the apt archive makes, for the
same reason, and it is why neither archive publishes from GitHub Actions.

## Publishing both archives

The apt archive is the entry point, because more depends on it:

```sh
cd ../amberlinux-apt
make deploy-all        # apt first, then this archive
```

`deploy-all` is `deploy` followed by `deploy-flatpak`, which is
`$(MAKE) -C ../amberlinux-flatpak deploy`. They are separate targets rather than
one, so the two archives fail independently — a flatpak problem must not leave
apt half-published.

To publish only this one: `make deploy` here.

## Getting content in

Two paths, and which you use depends on whether the machine carries the SDKs.

**From a sibling that built an ostree repo.** Each sibling answers
`make flatpak-repo` with a path, the way the apt archive asks for
`make deb-path`:

```sh
cd ../odin-sdk-extension && make repo   # needs that repo's SDK — several GB
cd ../amberlinux-flatpak && make add-suite
```

**From a bundle.** A `.flatpak` file — a CI artifact, usually — needs nothing but
flatpak, so a machine without the SDKs can still publish:

```sh
gh run download -R Hyperquader-Coders/odin-sdk-extension -n odin-sdk-extension
make import BUNDLE=odin-sdk-extension-x86_64.flatpak
```

Both end in the same place: an ostree repo in `out/`, ready to sign.

## What `deploy` actually does

`deploy` depends on `stage`, and `stage` is the gate
([diags/archive-flow.svg](../diags/archive-flow.svg) draws the whole path):

1. **`check-buildpaths`** — checks out every ref and scans its ELF files for
   paths naming this machine. A signature on a leaking tree is a promise made
   to the wrong bytes, so this runs before `sign`, which depends on it.
2. **`sign`** — signs every **commit**, then regenerates deltas, then the
   summary. All three matter and the order does too; see below.
3. **`verify`** — `ostree fsck`, and the summary exists.
4. **`verify-fresh`** — every ref the archive holds is still the commit its
   sibling currently builds, compared against `make flatpak-repo`. Signed,
   coherent and installable are all true of a ref pulled hours ago; this is the
   only check that looks at whether it is *current*. The apt archive's target of
   the same name makes the same guarantee about `.deb`s.
5. **`verify-client`** — serves `out/` over HTTP and adds it as a remote with a
   real flatpak client. The only check that exercises summary, refs and objects
   the way a user will.
6. **`tools/r2-sync.sh`** — uploads `objects/**` and `deltas/**` to R2, in
   parallel, skipping what is already there.
7. **`wrangler deploy`** — publishes the worker and the static metadata.

A sibling that is not checked out, or has not built, is skipped by step 4 with a
note rather than counted as fresh — the suite is developed one repo at a time,
and a machine publishing from a bundle has no sibling repo to compare against.
`appstream/` and `appstream2/` are excluded: they are regenerated here by
`build-update-repo`, not pulled, so they always differ from whatever the sibling
holds.

An index naming an object nobody can fetch is worse than no archive at all,
which is why `deploy` cannot run without `stage`.

## The four traps, all of them paid for

**Signing the summary is not signing the commits.** `build-update-repo
--gpg-sign` signs only the summary. A client can then `remote-ls` the repo
happily — that reads the summary — and fail at install with `GPG verification
enabled, but no signatures found`. `make sign` signs each commit explicitly
first.

**Deltas are regenerated, never reused.** `build-update-repo` keeps any deltas it
finds, so a delta built before the commits were signed survives re-signing, and
flatpak prefers the delta over the loose objects. The symptom is the same
"no signatures found" while the `.commitmeta` beside it is correctly signed.
`make sign` deletes `deltas/` and `delta-indexes/` first.

**Two object kinds are mutable.** `.filez`, `.dirtree` and `.dirmeta` are named
by their own checksum and can never change. `.commitmeta` is named after its
commit and changes when a signature is added; `deltas/**` is named after a commit
pair and changes when regenerated. Treating those as immutable — skipping the
re-upload, or serving them with a year-long cache — produces `Invalid checksum
for static delta`. `r2-sync.sh` always re-uploads both, and the worker serves
them `no-cache`.

**`gpg-sign` appends, and its `--delete` matches nothing.** Signing an
already-signed commit adds a second signature to its `.commitmeta`, so a naive
sign step grows every commit by one signature per run, re-uploaded on every
deploy. `ostree gpg-sign --delete` reports `Signatures deleted: 0` against this
key in every ID format, so it is not the way out. `make sign` removes each
commit's `.commitmeta` — the only place signatures live, and already the
mutable object the sync re-uploads — and signs from the unsigned state, leaving
exactly one signature however often it runs.

## Verifying a publish

The only check that means anything is a client that has never seen the archive:

```sh
export FLATPAK_USER_DIR=$(mktemp -d)
flatpak remote-add --user amberlinux https://flatpak.amberlinux.org/amberlinux.flatpakrepo
flatpak install --user amberlinux org.freedesktop.Sdk.Extension.odin
```

No `--no-gpg-verify`. If that install succeeds, signing, the summary, the objects
in R2 and the worker's routing are all correct at once. `remote-ls` alone proves
much less — it only reads the summary.

`make verify-http` asserts the zone behaviours around that install too: the
summary is `no-cache` and byte-identical to `out/`, missing paths 404, objects
arrive uncompressed and `immutable`, HSTS is present, and plain http 301s to
https — so a Cloudflare setting change fails this check instead of users'
installs.

## If the key is lost

There is no spare key, deliberately: the private half lives in the publishing
machine's `~/.gnupg` and nowhere else, so there is no second copy to steal.
The price of that is that losing the machine means rotation, not restoration —
steps 2 to 4 below, plus revoking the lost key with the certificate GnuPG
wrote at creation (`openpgp-revocs.d/<fingerprint>.rev`, one copy on the
machine, one held offline). The offline copy is the whole disaster plan: it
is the only thing that can mark the old key dead once the machine that held
it is gone.

## If the key is compromised

This archive's key is its own — the apt archive is untouched and stays up
while this one rotates:

1. Revoke: GnuPG wrote the revocation certificate at key creation —
   `~/.gnupg/openpgp-revocs.d/060DD386E634C5C445DF3A7F2BE23FC60996C427.rev`
   on the publishing machine, with a copy held offline. Import it, then
   export the revoked key over the published keyring so existing clients
   learn of it.
2. Generate the replacement under the same identity
   (`flatpak@amberlinux.org`) and change the Makefile's `GPG_KEY` — `make
   lint` then fails until every documented fingerprint follows.
3. Re-sign and redeploy. ostree commits carry their signatures in
   `.commitmeta`, so `make sign` re-signs every ref without rebuilding it.
4. Clients re-add the remote; the `.flatpakrepo` file embeds the key, so the
   published URL hands them the new one.
