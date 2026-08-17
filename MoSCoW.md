# MoSCoW

The MoSCoW method is a prioritization technique used in management, business analysis, project management, and software development to reach a common understanding with stakeholders on the importance they place on the delivery of each requirement; it is also known as MoSCoW prioritization or MoSCoW analysis.

The term MoSCoW itself is an acronym derived from the first letter of each of four prioritization categories (Must have, Should have, Could have, and Won't have), with the interstitial Os added to make the word pronounceable. While the Os are usually in lower-case to indicate that they do not stand for anything, the all-capitals MOSCOW is also used.

## Must have

- nada

## Should have

- nada

## Could have

- **Static deltas between versions.** `flatpak build-update-repo --generate-static-deltas`
  already runs; what is missing is pruning old ones, which otherwise grow without bound.

- **A `remove` target.** Retiring a ref is by-hand today — `ostree refs --delete`, and
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
  this repository contains it — the same commitment the apt archive makes. Automating the
  publish means putting that key somewhere a runner can reach, which is a larger decision
  than the convenience is worth before v1.

- **Mirroring Flathub.** Flathub serves its own runtimes and does it better. This archive
  carries what the suite builds and nothing else.

- **Unsigned publishing.** The apt archive is signed and so is this. A repo people add to a
  system tool is not the place to save a step.
