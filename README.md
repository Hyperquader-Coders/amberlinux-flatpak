# amberlinux-flatpak

The suite's flatpak repo, served from **flatpak.amberlinux.org**.

Sibling to [`amberlinux-apt`](https://github.com/Hyperquader-Coders/amberlinux-apt),
built the same way and gated the same way: assemble locally, prove it with a real
client that verifies signatures, then deploy. Where the two differ is where
reprepro and ostree differ, and [MoSCoW.md](MoSCoW.md) says which of the apt
archive's targets were deliberately not ported. The archive never hardcodes another repo's output layout — each sibling
answers `make flatpak-repo` with the ostree repo it built, the way the apt
archive asks for `make deb-path`.

```sh
flatpak remote-add --if-not-exists amberlinux \
    https://flatpak.amberlinux.org/amberlinux.flatpakrepo
```

## What it publishes

| ref | from |
|---|---|
| `runtime/org.freedesktop.Sdk.Extension.odin/x86_64/25.08` | [`odin-sdk-extension`](https://github.com/Hyperquader-Coders/odin-sdk-extension) |
| `app/io.github.hyperquader.Yggr/x86_64/stable` | [`yggr`](https://github.com/Hyperquader-Coders/yggr) |

Yggr's `.Locale` and `.Debug` refs ride alongside the app, split out by
flatpak-builder.

The Odin SDK extension is the reason this exists. A Flatpak build sandbox
reaches nothing on the host, so an application written in Odin has no compiler
unless it builds one inside its own manifest. Publishing the extension means an
app declares `sdk-extensions` and gets a compiler, which is how every other
language works.

## Building and deploying

```sh
make build        # ostree init, archive-z2
make add-suite    # pull each sibling's built ostree repo in (needs their SDKs)
make import BUNDLE=x.flatpak   # or take a bundle — needs only flatpak
make stage        # sign, fsck, freshness, and prove a fresh client can read it
make deploy       # upload objects to R2, then publish the worker
make serve        # serve out/ locally on :8001
```

The two checks inside `stage` answer different questions and neither substitutes
for the other. `verify-client` asks whether a client that has never seen the
archive can add it and install from it with signature verification on.
`verify-fresh` asks whether what it would install is still what the sibling
builds — a ref pulled hours ago passes the first check and fails this one. The
apt archive splits the same way, under the same two names.

Publishing happens on the machine holding the signing key, never in CI. The apt
archive is the entry point for a publishing run:

```sh
cd ../amberlinux-apt && make deploy-all    # apt, then this archive
```

The full runbook, including the four signing traps that are easy to re-discover,
is in [docs/DEPLOY.md](docs/DEPLOY.md). The path off self-hosting — what Flathub
requires and the order the two refs go in — is [docs/UPSTREAM.md](docs/UPSTREAM.md).

`stage` is the gate, and `deploy` depends on it. A summary naming an object
nobody can fetch is worse than no repo at all — the same reasoning as the apt
archive's staging step.

**archive-z2** is the repo mode: every object is a separate, individually
compressed file, which is what makes a static host workable.

## How it is served

Only over TLS: the worker 301s plain HTTP to https and every response carries
HSTS. Signatures prove origin, not freshness — on plain HTTP an on-path
attacker can stall or replay an older validly signed summary, and ostree has
no rollback protection, so transport is the only replay defence a client gets.

Two paths, split at the 25 MiB static-asset cap:

- **Static assets** — `summary`, `summary.sig`, `config`, `refs/**`, the
  keyring and the landing page. Served byte-exact; `html_handling` is `"none"`
  because ostree files have no extensions and must not be rewritten.
- **R2** — `objects/**` and `deltas/**`, via the worker. Most ostree objects are
  small, but a repo carrying a toolchain has a few that are not: the Odin
  extension's `libLLVM` is over 100 MiB before compression.

Objects are content-addressed, so the checksum is the filename and an object
never changes once written. They are served `immutable` with a one-year cache.

`tools/r2-sync.sh` uploads only what it has not uploaded before, tracked in
`.r2-synced`. It refuses anything over wrangler's 300 MiB CLI cap rather than
letting a half-published repo happen; nothing an ostree repo produces should come
close, but the check costs nothing.

## Signing

Signed with the Amber Linux flatpak key,
`060DD386E634C5C445DF3A7F2BE23FC60996C427` (`flatpak@amberlinux.org`).

**This archive signs with its own key, and the authority is the `GPG_KEY`
line in the [Makefile](Makefile).** It is a dedicated identity — deliberately
not the apt archive's key, because the two archives have different lifecycles
(this one empties into Flathub, [docs/UPSTREAM.md](docs/UPSTREAM.md), while
apt is permanent), and deliberately not anyone's commit-signing key, because
compromising or rotating one must never touch the other. `make lint` fails if
any fingerprint printed in these docs disagrees with the Makefile, or if the
key ever equals the apt archive's again — and `stage` and `force-push` both
run `lint`, so a wrong key cannot be published. `make sign` regenerates the
summary, static deltas and the exported keyring together, so they cannot drift
apart.

`sign` also refuses a tree whose binaries name the machine that built them:
`tools/check-buildpaths.sh` checks out every ref and scans its ELF files, the
ostree port of the apt archive's `check-no-buildpaths.sh`. `strip` does not
remove these strings — Odin's `Source_Code_Location` and a configure prefix
both land in `.rodata` — so the gate reads the bytes that would ship. A
flatpak-builder sandbox leaves `/run/build/<module>` paths, identical for every
builder; those pass.

## Licence

**This licence covers the archive tooling only** — the Makefile, `tools/`, the
Cloudflare worker and the docs in this repository. BSD-3-Clause; see
[LICENSE](LICENSE).

**It does not cover what the archive serves.** Each published ref carries the
licence of the repository it was built from: the Odin SDK extension is
BSD-3-Clause, matching the compiler it packages, and anything else added here
brings its own. Read the component's own licence before assuming, exactly as with
the sibling apt archive — permissive tooling around a payload says nothing about
the payload.
