SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

# amberlinux-flatpak: the suite's flatpak repo, served from flatpak.amberlinux.org.
#
# Same shape as amberlinux-apt (build locally, prove it with a real client, then
# deploy) and the same gates: preflight, lint, staging before upload. It is not a
# copy of it: reprepro's per-package model has targets an ostree repo has no use
# for, and MoSCoW.md records which were deliberately left out and why.
# See docs/DEPLOY.md.

OUT      ?= build/repo
REPO     ?= $(OUT)
BUCKET   ?= amberlinux-flatpak-objects
HOST     ?= 127.0.0.1
PORT     ?= 8001
BRANCH   ?= main
REMOTE   ?= origin
ROOT_COMMIT_MSG ?= Initial amberlinux-flatpak
# HOUSE_ROOT is the folder holding house-rules, which mise sets on a development machine;
# `make lint` runs its check-example-hosts where it is there. house-rules is private, so a clone
# outside the house and the public runner go without it, saying so.
HOUSE_SCRIPTS = $(HOUSE_ROOT)/house-rules/scripts

# Where the archive is published: the Url of the .flatpakrepo and of every app's .flatpakref.
URL      ?= https://flatpak.amberlinux.org/
# Where an app's install file sends flatpak for the runtime it runs on: the archive carries the
# suite's apps, Flathub carries the GNOME and freedesktop runtimes.
RUNTIME_REPO ?= https://dl.flathub.org/repo/flathub.flatpakrepo
# check-client's flatpak installation, kept between runs so the Flathub runtimes are fetched
# once rather than on every stage. Empty: a throwaway installation, every runtime fetched.
VERIFY_CACHE ?= $(HOME)/.cache/amberlinux-flatpak/verify

# Every sibling repo that produces a flatpak. Each answers `make flatpak-repo-path`
# with the path to an ostree repo it has built, so this archive never hardcodes
# another repo's output layout: the same contract amberlinux-apt uses for debs.
# Each is found through its root's variable, which mise sets: odin-sdk-extension, yggr and
# elektron in the Amber tree (AMBER_ROOT), acue in ACUE_MEDIA_ROOT and discover3d-monitor in
# DISCOVER3D_STUDIO_ROOT.
SUITE ?= $(AMBER_ROOT)/odin-sdk-extension $(AMBER_ROOT)/yggr $(ACUE_MEDIA_ROOT)/acue $(AMBER_ROOT)/elektron \
	$(DISCOVER3D_STUDIO_ROOT)/discover3d-monitor
# The apt archive, whose signing key lint checks this one's differs from. It is private: a clone
# outside the house and the public runner go without it, and lint says so.
APT ?= $(if $(AMBER_ROOT),$(AMBER_ROOT)/amberlinux-apt)

# The flatpak archive's own signing key (Amber Linux Flatpak Signing Key
# <flatpak@amberlinux.org>), deliberately NOT the apt archive's key and not
# anyone's commit-signing key. The two archives have different lifecycles:
# this one empties into Flathub (docs/UPSTREAM.md) while apt is permanent, so
# neither key's compromise or retirement may touch the other. This line is the
# authority; lint checks every document against it, and fails if it ever
# equals the apt key again.
GPG_KEY ?= 060DD386E634C5C445DF3A7F2BE23FC60996C427

.PHONY: help setup init-packages init-modules init-workstation preflight hooks build add-suite import sign stage check-repo check-fresh check-no-agent-files \
	check-client check-live check check-buildpaths delete-debug-refs test ci serve list deploy clean \
	push force-push lint diags

# The system packages, one list for a desk and for CI: ostree and flatpak, which build and prove
# the archive, gnupg, which signs it, and shellcheck and shfmt, which lint and fmt run. `make
# init-packages` installs it; a package missing on the runner is added here, and the workflow names
# none.
DEPS := ostree flatpak gnupg shellcheck shfmt
APT_FLAGS ?=

init-packages: ## install the system packages (sudo apt)
	sudo apt-get install $(APT_FLAGS) --no-install-recommends $(DEPS)

# No language packages: the tooling is shell. `ci` depends on it all the same, as in every
# repository.
init-modules: ## install the language packages from the lock: none here

# A desk that publishes needs the archive key, which preflight proves can sign.
init-workstation: preflight hooks ## set up a desk: preflight (the archive key signs), then hooks

help: ## this list
	@awk 'BEGIN {FS = ":.*## "} \
	    /^##@ / {printf "\n%s\n", substr($$0, 5)} \
	    /^[a-z][a-z0-9-]*:.*## / {printf "  %-22s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# Tools present AND the archive key can actually sign. A missing or locked key
# otherwise yields a silently unsigned tree that fails on the user's machine.
preflight: ## tools present and the archive key can sign unattended
	@GPG_KEY=$(GPG_KEY) tools/preflight.sh

hooks: ## point core.hooksPath at .githooks
	git config core.hooksPath .githooks
	@echo "hooks: shellcheck runs on staged shell files before every commit"

# archive-z2 is the mode for a repo served over plain HTTP: every object is a
# separate, individually compressed file, which is what lets a static host work.
build: preflight ## create the ostree repo under build/repo if absent
	@mkdir -p $(REPO)
	@test -f $(REPO)/config || ostree --repo=$(REPO) init --mode=archive-z2
	@echo "repo at $(REPO)"

# Pull each sibling's built extension/app into this repo. A sibling whose repo holds a .Debug
# ref is refused before anything is pulled (tools/check-no-debug.sh).
add-suite: build ## pull every sibling's built flatpak into the repo
	@for r in $(SUITE); do \
		src=$$($(MAKE) --no-print-directory -s -C $$r flatpak-repo-path) || { echo "$$r: no flatpak-repo-path target"; exit 1; }; \
		test -d "$$src" || { echo "$$r: $$src is not a repo"; exit 1; }; \
		tools/check-no-debug.sh "$$src" "$$r"; \
		echo "== pulling from $$r ($$src)"; \
		ostree --repo=$(REPO) pull-local "$$src"; \
	done

# Two ways in. `add-suite` pulls from a sibling that built an ostree repo, which
# needs that repo's SDK installed locally. `import` takes a .flatpak bundle
# (a CI artifact, typically), which needs nothing but flatpak, and is how a
# machine that does not carry several GB of SDK still publishes.
#
#   make import BUNDLE=~/Downloads/odin-sdk-extension-x86_64.flatpak
#
# The bundle is imported into a temporary repo first, so a .Debug ref in it is refused
# before it reaches the archive (tools/check-no-debug.sh).
import: build ## import a bundle: make import BUNDLE=<file.flatpak>
	@test -n "$(BUNDLE)" || { echo "usage: make import BUNDLE=<file.flatpak>"; exit 2; }
	@test -f "$(BUNDLE)" || { echo "no such bundle: $(BUNDLE)"; exit 2; }
	@incoming=$$(mktemp -d); trap 'rm -rf "$$incoming"' EXIT; \
	ostree --repo="$$incoming" init --mode=archive-z2; \
	flatpak build-import-bundle "$$incoming" "$(BUNDLE)"; \
	tools/check-no-debug.sh "$$incoming" "$(BUNDLE)"; \
	ostree --repo=$(REPO) pull-local "$$incoming"
	@echo "imported $(BUNDLE); refs now:"
	@ostree --repo=$(REPO) refs

# No ref may name the machine that built it, and no ref may be a .Debug ref. Checked before
# sign because a signature on a leaking tree is a promise made to the wrong bytes; the apt
# archive runs the same gate over its .debs. sign and stage depend on this, so a .Debug ref
# already in the repo is refused there too; `make delete-debug-refs` removes it.
check-buildpaths: build ## no ref names the machine that built it, and none is a .Debug ref
	@tools/check-no-debug.sh $(REPO)
	@OUT=$(OUT) tools/check-buildpaths.sh

# Delete every .Debug ref from the repo, then prune the objects only those refs reached. The
# summary still names them until the next `make stage`, which re-signs and regenerates it.
delete-debug-refs: ## delete every .Debug ref from build/repo and prune what only they held
	@test -f $(REPO)/config || { echo "$@: no ostree repo at $(REPO)"; exit 2; }
	@refs=$$(ostree --repo=$(REPO) refs | grep -E '\.Debug(/|$$)' || true); \
	if [ -z "$$refs" ]; then echo "$@: no .Debug refs in $(REPO)"; exit 0; fi; \
	for r in $$refs; do \
		echo "deleting $$r"; \
		ostree --repo=$(REPO) refs --delete "$$r"; \
	done; \
	ostree --repo=$(REPO) prune --refs-only

sign: build check-buildpaths ## sign every commit and the summary; write the keyring, .flatpakrepo and app install files
	# Sign every commit, then the summary. These are separate signatures and the
	# difference is not cosmetic: `build-update-repo --gpg-sign` signs only the
	# summary, so a client can `remote-ls` a repo whose commits are unsigned and
	# then fail at install with "GPG verification enabled, but no signatures
	# found". Commits arriving via build-import-bundle carry no signature of
	# their own, so they are signed here.
	# Drop each commit's .commitmeta before signing: gpg-sign appends rather
	# than replaces, so every stage run otherwise adds another signature to
	# every commit, growing without bound and re-uploaded each deploy. It has
	# to be rm: `gpg-sign --delete` matches signatures by key ID and reports
	# "Signatures deleted: 0" against this key in every ID format. Signatures
	# live only in .commitmeta, which is already the mutable object r2-sync
	# always re-uploads, so removing it is the state "unsigned commit", and
	# signing from there leaves exactly one signature however often this runs.
	@for r in $$(ostree --repo=$(REPO) refs); do \
		c=$$(ostree --repo=$(REPO) rev-parse "$$r"); \
		rm -f "$(REPO)/objects/$${c:0:2}/$${c:2}.commitmeta"; \
		echo "signing commit for $$r"; \
		ostree --repo=$(REPO) gpg-sign "$$r" $(GPG_KEY) >/dev/null; \
	done
	# Discard existing deltas first. build-update-repo reuses any it finds, so a
	# delta generated before the commits were signed survives re-signing, and
	# flatpak prefers the delta over the loose objects, so it pulls the unsigned
	# commit and fails with "no signatures found" while the .commitmeta sitting
	# next to it is correctly signed. Regenerating unconditionally costs a little
	# time and removes a failure that looks nothing like its cause.
	rm -rf $(REPO)/deltas $(REPO)/delta-indexes
	flatpak build-update-repo --generate-static-deltas \
		--gpg-sign=$(GPG_KEY) $(REPO)
	# export-minimal, as the apt archive's keyring target does: without it any
	# third-party signature the key picks up later is published to every user.
	gpg --export-options export-minimal --export --armor $(GPG_KEY) > $(OUT)/amberlinux-flatpak.gpg
	# The landing page tells people to add this; generate it beside the keyring
	# so the URL and the key cannot drift apart.
	printf '[Flatpak Repo]\nTitle=Amber Linux\nUrl=%s\nHomepage=https://amberlinux.org/\nGPGKey=%s\n' \
		"$(URL)" "$$(gpg --export-options export-minimal --export $(GPG_KEY) | base64 -w0)" > $(OUT)/amberlinux.flatpakrepo
	cp static/index.html cloudflare/_headers cloudflare/robots.txt $(OUT)/
	# One install file per app, and the landing page's list of them.
	@REPO=$(REPO) OUT=$(OUT) URL="$(URL)" RUNTIME_REPO="$(RUNTIME_REPO)" GPG_KEY=$(GPG_KEY) \
		tools/write-flatpakrefs.sh
	# Must be `.assetsignore`, with the dot: wrangler looks for that exact name
	# in the assets directory, and a file named `assetsignore` is silently just
	# another asset, which is how objects/** ends up uploaded twice.
	cp cloudflare/assetsignore $(OUT)/.assetsignore
	@echo "signed with $(GPG_KEY)"

# The tree's convention: `make check` proves what is here without publishing it.
# Cheaper than `stage`, which re-signs; this checks what is already built.
check: lint check-buildpaths check-repo check-fresh check-client ## prove the built tree without re-signing
	@echo "check: the built tree is signed, coherent, current, clean of build paths, and installs for a real client"

# The tooling on a throwaway archive: fixture runtimes go through `add-suite` and `import`, then
# `check-buildpaths`, `sign`, `check-repo`, `check-fresh` and `check-client` run on that tree, signed
# by a throwaway key in a temporary GNUPGHOME (tools/test-archive.sh). It needs neither the
# archive key nor build/repo, so a fresh checkout and the CI pass it; the real archive is proved
# by `stage`.
test: ## the tooling on a throwaway archive signed by a throwaway key
	@MAKE="$(MAKE)" tools/test-archive.sh

# Everything a push must pass, in a fresh checkout and in the CI alike. `stage`, which signs
# and proves the real archive, is the gate before `deploy`; see docs/DEPLOY.md.
ci: init-modules lint test ## everything a push must pass

# Assemble and prove it before anything is uploaded. `deploy` depends on this
# for the same reason amberlinux-apt's does: an index naming an object nobody
# can fetch is worse than no repo at all.
stage: lint sign check-repo check-fresh check-client ## sign and prove build/repo for deploy
	@echo "stage: $(CURDIR)/$(OUT) is assembled and verified. 'make deploy' uploads it."

# Does the repo describe itself coherently?
check-repo: ## ostree fsck, refs and summary present
	ostree --repo=$(REPO) fsck
	ostree --repo=$(REPO) refs
	@test -s $(OUT)/summary || { echo "no summary: run make sign"; exit 1; }
	@echo "check-repo OK"

# Does a real flatpak client, with no prior knowledge, see what we published?
# Serves the staged tree over HTTP and installs every app through its install
# file and every other ref from the remote, which is the only check that
# exercises summary, refs, objects and runtimes the way a user will.
check-client: ## a real flatpak client installs from the tree over HTTP
	@OUT=$(OUT) HOST=$(HOST) PORT=$(PORT) VERIFY_CACHE="$(VERIFY_CACHE)" tools/check-client.sh

# Is what the archive holds still what its siblings build? Nothing else asks:
# a stale ref is signed, coherent and installable, and yggr builds against it.
# The apt archive's target of the same name makes the same guarantee about
# .debs; see docs/DEPLOY.md.
check-fresh: ## fail if a ref is older than its sibling builds
	@SUITE="$(SUITE)" OUT=$(OUT) tools/check-fresh.sh

# The same check against what is actually published, which is the only thing a
# user ever touches.
check-live: ## check-client against flatpak.amberlinux.org
	@OUT=$(OUT) VERIFY_CACHE="$(VERIFY_CACHE)" tools/check-client.sh $(patsubst %/,%,$(URL))

serve: build ## serve build/repo locally (HOST, PORT)
	python3 -m http.server $(PORT) --bind $(HOST) --directory $(OUT)

list: ## list the refs in the repo
	@ostree --repo=$(REPO) refs

# Upload objects to R2, then publish the worker + static metadata.
deploy: stage ## publish to flatpak.amberlinux.org
	tools/r2-sync.sh
	cd cloudflare && npx wrangler deploy
	$(MAKE) --no-print-directory check-live

clean: ## remove build/repo
	rm -rf $(OUT)

push: ## git push to REMOTE BRANCH (origin main)
	git push "$(REMOTE)" "$(BRANCH)"

# Agent files are never published. Two ways they get in: already tracked, or
# present-and-unignored when `git add -A` below sweeps the whole tree. Both are
# checked here, because a squashed history shows no file being added: a stray
# path simply appears in the root commit as though it always belonged.
check-no-agent-files: ## refuse agent files that are tracked or not ignored
	@bad=$$(git ls-files | grep -E '(^|/)(\.mcp\.json|\.claude/|\.claude-amber/)' || true); \
	if [ -n "$$bad" ]; then \
		echo "agent files are tracked and must not be published:"; \
		printf '  %s\n' $$bad; \
		echo "fix: git rm -r --cached <path>, then add it to .gitignore"; \
		exit 2; \
	fi
	@for p in .mcp.json .claude .claude-amber; do \
		if [ -e "$$p" ] && ! git check-ignore -q "$$p"; then \
			echo "$$p exists and is not gitignored, so 'git add -A' would publish it"; \
			echo "fix: add $$p to .gitignore"; \
			exit 2; \
		fi; \
	done
	@echo "no agent files staged for publication"

# Publishes this repository's source, gated by what every push passes. It leaves build/repo
# alone: re-signing there would make the local summary differ from the published one until the
# next deploy.
force-push: ci check-no-agent-files ## squash history into one signed root commit and force-push
	@test -z "$$(git status --porcelain)" || { \
		echo "Working tree is dirty. Commit, stash, or revert changes first."; \
		exit 2; \
	}
	@set -e; \
	orig_branch="$$(git branch --show-current)"; \
	test -n "$$orig_branch" || { echo "force-push: detached HEAD, check out a branch first"; exit 1; }; \
	tmp_branch="root-squash-$$(date +%s)"; \
	step="starting"; ok=0; \
	trap 'if [ "$$ok" != 1 ]; then echo "force-push FAILED while: $$step. Local history is intact on $$orig_branch; $(REMOTE)/$(BRANCH) was not replaced." >&2; git checkout -f "$$orig_branch" >/dev/null 2>&1 || true; git branch -D "$$tmp_branch" >/dev/null 2>&1 || true; exit 1; fi' EXIT; \
	step="creating the orphan branch"; git checkout --orphan "$$tmp_branch"; \
	step="staging the tree"; git add -A; \
	step="signing the root commit"; git commit -S -m "$(ROOT_COMMIT_MSG)"; \
	step="pushing to $(REMOTE)/$(BRANCH) (refused or unreachable)"; git push --force "$(REMOTE)" "$$tmp_branch:$(BRANCH)"; \
	step="verifying $(REMOTE)/$(BRANCH) equals the new commit"; \
	remote_sha="$$(git ls-remote "$(REMOTE)" "refs/heads/$(BRANCH)" | cut -f1)"; \
	test -n "$$remote_sha" && test "$$remote_sha" = "$$(git rev-parse HEAD)"; \
	ok=1; \
	other_wt="$$(git worktree list --porcelain | awk -v b="branch refs/heads/$(BRANCH)" '/^worktree /{w=substr($$0, 10)} $$0 == b {print w}')"; \
	if [ -n "$$other_wt" ] && [ "$$other_wt" != "$$(git rev-parse --show-toplevel)" ]; then \
		git fetch "$(REMOTE)" "$(BRANCH)" >/dev/null 2>&1 || true; \
		git checkout -q --detach; git branch -D "$$tmp_branch" >/dev/null; \
		echo "Rewrote $$orig_branch as signed root commit on $(REMOTE)/$(BRANCH)."; \
		echo "$(BRANCH) is checked out in $$other_wt; once it is clean: git -C $$other_wt fetch && git -C $$other_wt reset --keep $(REMOTE)/$(BRANCH)"; \
	else \
		git branch -M "$$tmp_branch" "$(BRANCH)"; \
		git branch --set-upstream-to="$(REMOTE)/$(BRANCH)" "$(BRANCH)" >/dev/null 2>&1 || { git fetch "$(REMOTE)" "$(BRANCH)" >/dev/null 2>&1 && git branch --set-upstream-to="$(REMOTE)/$(BRANCH)" "$(BRANCH)" >/dev/null; } || echo "warning: could not set upstream"; \
		echo "Rewrote $$orig_branch as signed root commit on $(REMOTE)/$(BRANCH)."; \
	fi

# The SVG is committed so reading the repo does not require d2; `make lint`
# fails when it drifts from the source.
diags: ## render diags/*.d2 to SVG
	@for f in diags/*.d2; do \
		d2 --theme=105 --dark-theme=300 --pad=40 "$$f" "$${f%.d2}.svg"; \
		chmod 644 "$${f%.d2}.svg"; \
	done

lint: check-no-agent-files ## docs and key consistency, diagram fresh, shellcheck, agent-file guard, house-rules' check-example-hosts
	@if [ -n "$(HOUSE_ROOT)" ] && [ -x "$(HOUSE_SCRIPTS)/check-example-hosts" ]; then "$(HOUSE_SCRIPTS)/check-example-hosts" "$(CURDIR)"; \
	else echo "house-rules not found (HOUSE_ROOT=$(HOUSE_ROOT)): check-example-hosts skipped; house-rules is private"; fi
	@APT="$(APT)" tools/lint.sh
	@if command -v shellcheck >/dev/null; then \
		shellcheck --severity=warning tools/*.sh && echo "shellcheck OK"; \
	else echo "shellcheck not installed, skipping (apt install shellcheck)"; fi

# Shell scripts are laid out by shfmt (sudo apt install shfmt), with tabs: every tracked file
# that is a shell script by its name or its first line. As in house-rules.
# apt's shfmt, the one a CI runner has, before any other on the PATH: versions differ in layout.
SHFMT ?= $(firstword $(wildcard /usr/bin/shfmt) shfmt)
SHFMT_FLAGS = -i 0
SH_SOURCES = git ls-files -z --cached --others --exclude-standard -- . | xargs -0 -r $(SHFMT) -f
.PHONY: fmt check-fmt fmt-sh check-fmt-sh
fmt-sh: ## lay the shell scripts out in place
	@$(SH_SOURCES) | xargs -r -d '\n' $(SHFMT) $(SHFMT_FLAGS) -w

check-fmt-sh: ## fail when a shell script is not as make fmt-sh leaves it
	@if ! command -v $(SHFMT) >/dev/null; then \
		if [ "$$GITHUB_ACTIONS" = true ]; then echo "shfmt is not installed on this runner; it is in DEPS"; exit 1; fi; \
		echo "shfmt not installed, skipping (sudo apt install shfmt)"; exit 0; \
	fi; \
	bad=$$($(SH_SOURCES) | xargs -r -d '\n' $(SHFMT) $(SHFMT_FLAGS) -l 2>&1) || true; \
	if [ -n "$$bad" ]; then echo "not formatted:"; echo "$$bad"; echo "fix: make fmt"; exit 1; fi; \
	echo "shfmt OK"

fmt: fmt-sh ## format the code in place: here, the shell scripts
check-fmt: check-fmt-sh ## fail on code that is not as make fmt leaves it
lint: check-fmt

# The one command after a fresh clone, the same in every repository.
setup: init-packages init-modules init-workstation ## everything a fresh clone needs: packages (sudo apt), preflight, hooks
