# UPSTREAM.md — getting onto Flathub

How the Odin SDK extension and Yggr reach the official flatpak repository,
what Flathub demands that this archive does not, and the order the two must
go in. The open work items live in each repo's own `MoSCoW.md`; this file owns
the process and the requirements.

**Why bother:** Flathub hosts, signs, mirrors and delta-compresses at their
expense, puts both refs in every software centre, and frees users from adding
the amberlinux remote. Every Odin application anywhere gets a compiler for one
`sdk-extensions:` line — the reason the extension exists, at full reach.

## What Flathub requires that self-hosting does not

- **Public, pinned, immutable sources.** The buildbot fetches every source
  itself: each `git` source needs a public repository and a `commit:`, each
  archive a `sha256:`. No branch pins, no private repos.
- **Offline builds.** No network during the build. Already true here —
  flatpak-builder enforces it locally too.
- **Runtimes and extensions from Flathub only.** A manifest cannot add a
  third-party remote, which is why the extension must land before Yggr.
- **No prebuilt binaries** without a fight. Reviewers treat a downloaded
  binary as a submission blocker; everything builds from source or gets an
  argument.
- **Valid appstream.** `appstreamcli validate` on the metainfo, and the
  composed catalogue for apps; Flathub runs `flatpak-builder-lint` over the
  manifest and metainfo in review and in CI.
- **ID ownership.** An `io.github.<name>.*` ID is verified against control of
  that GitHub account.

The submission itself: a pull request against the `new-pr` branch of
`github.com/flathub/flathub` containing the manifest (and metainfo, for the
parts not generated). Review is human. On merge, Flathub creates
`flathub/<app-id>`, the buildbot builds and publishes, and updates from then
on are pull requests against that repository. Current mechanics:
[docs.flathub.org](https://docs.flathub.org/docs/for-app-authors/submission).

## The trap that spans every repo: force-push versus pins

The tree's convention is to republish repositories as a single squashed root
commit. **A Flathub manifest pins commits, and a force-push deletes the commit
it pinned** — the buildbot then cannot fetch the source, and every rebuild of
the published app breaks. From the moment any repository is named in a Flathub
manifest — Yggr itself, amber-lib as its collection source, the Odin fork if
one is still in play — that repository's history becomes append-only. Plan the
final squash to land *before* submission, and never force-push a pinned repo
again.

## The extension: org.freedesktop.Sdk.Extension.odin

The freedesktop SDK extension namespace is Flathub-hosted (`llvm22`,
`rust-stable`, `golang` all live there), so the ID needs no change. The
runtime it extends and the llvm22 extension it builds against are both on
Flathub already. The manifest builds offline, the metainfo exists, and the
appstream composes.

The compiler builds from the public `Hyperquader-Coders/Odin` fork at a
pinned commit — fetchable by Flathub's buildbot, so nothing blocks
submission mechanically. Two consequences ride along: the fork is
**append-only from the moment Flathub pins it** (a force-push would orphan
the pinned commit and break every rebuild), and a reviewer will ask why a
language ships from a fork. The answer is the LLVM-target-guard patch, and
the exit is the extension repo's own Must-have chain — rebase it onto
current Odin, carry the guard into `build.bat`, offer it upstream — after
which the Flathub manifest moves to `odin-lang/Odin` at a release tag and
the fork retires. See `../../odin-sdk-extension/MoSCoW.md`.

## Yggr: io.github.hyperquader.Yggr

Gated four deep, each gate already an entry in `../../yggr/MoSCoW.md`:

1. **The extension first.** Yggr's manifest declares
   `org.freedesktop.Sdk.Extension.odin` in `sdk-extensions`; a Flathub build
   can only resolve that from Flathub.
2. **Composed appstream.** `appstream-compose: false` works around a
   gdk-pixbuf defect in the 25.08 SDK; software centres read the composed
   data and Flathub review expects it.
3. **marksman from source, or dropped.** The last prebuilt blob in the
   manifest.
4. **amber-lib pinned by commit.** The manifest tracks `branch: main` because
   amber-lib is still republished as a fresh root; Flathub requires a fixed
   ref, which is the force-push trap above wearing its amber-lib face.

Two review conversations to expect beyond the gates: `--filesystem=host`
(host access is MVP pragmatism for an editor; the portals entry in Yggr's
backlog is the durable answer), and **ID ownership** — the ID names the
`hyperquader` GitHub account while the code lives in the `Hyperquader-Coders`
organisation. Verify what Flathub's checker accepts for that split against
docs.flathub.org before submitting; the alternatives are moving or mirroring
the repository under the account the ID names, or changing the ID before it
is ever published — never after.

## Order of operations

1. The extension's submission is open as
   [flathub/flathub#9793](https://github.com/flathub/flathub/pull/9793),
   built from the pinned public fork; the fork stays append-only while
   anything pins it.
2. Upstream the Odin patch; the Flathub manifest then moves to an
   `odin-lang/Odin` release tag and the fork retires.
3. Clear Yggr's four gates; submit Yggr.
4. This archive then carries only what Flathub does not — nothing, unless a
   component exists that Flathub would not take. `MoSCoW.md` already rules out
   mirroring Flathub; emptying this archive into it is the success case.

Until then, both refs publish here, and nothing about this archive's pipeline
changes.
