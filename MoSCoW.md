# MoSCoW: amberlinux-flatpak

Prioritisation by **Must / Should / Could / Won't have** (the lower-case Os just make it
pronounceable). This is the **scope** document, and it holds only what is **still open**: an
item leaves this file the moment it ships. Nothing here records work done; `git log` is for
that.

An empty band means that band is finished, not that it was never populated.

## Must have

- nada

## Should have

- **Every app on Flathub.** The apps are to be hosted by Flathub; this archive is the bridge,
  and an app's install file (`apps/<app id>.flatpakref`) leaves it when the app lands there.
  The process and requirements are in [docs/UPSTREAM.md](docs/UPSTREAM.md). What blocks each:

  | app | blocked by |
  |---|---|
  | Odin SDK extension | the compiler patch landing in `odin-lang/Odin`: the extension builds from our fork, and Flathub builds from upstream |
  | Yggr | the Odin SDK extension on Flathub |
  | Acue | the extension; a public source repository |
  | Elektron | the extension; a public source repository |
  | discover3d-monitor | the extension; a public source repository |

  Every app id is `com.hyperquader.*`, which Flathub verifies once for the domain
  hyperquader.com.

  Yggr, Acue and Elektron are under the Amber Source License and discover3d-monitor under the
  Business Source License; neither is OSI or FSF approved, so Flathub lists those apps as
  proprietary.

## Could have

- **Static deltas between versions.** `flatpak build-update-repo --generate-static-deltas`
  already runs; what is missing is pruning old ones, which otherwise grow without bound.

- **A `remove` target.** Retiring a ref is by hand today (`ostree refs --delete`), and
  nothing prunes the orphaned objects locally or in R2, so a retired ref's objects sit in
  the bucket forever. reprepro's `remove` has no ostree twin here; `ostree prune` plus an
  R2 sweep against the manifest is the shape.

## Won't have (this time)

- **`check-debs`, `add`, `remove`, `build-suite`, `keyring` as separate targets.** The apt
  archive has these because reprepro's model needs them: packages are added and removed
  individually and the index is rebuilt around them. An ostree repo takes whole commits, so
  `import` and `add-suite` cover adding, `keyring` is part of `sign` (regenerated with the
  summary so the two cannot drift), and there is no `.deb` to check.


- **Publishing from CI.** The signing key lives in one machine's `~/.gnupg` and nothing in
  this repository contains it: the same commitment the apt archive makes. Automating the
  publish means putting that key somewhere a runner can reach, which is a larger decision
  than the convenience is worth before v1.

- **Mirroring Flathub.** Flathub serves its own runtimes and does it better. This archive
  carries what the suite builds and nothing else.

- **Unsigned publishing.** The apt archive is signed and so is this. A repo people add to a
  system tool is not the place to save a step.
