SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

# amberlinux-flatpak — the suite's flatpak repo, served from flatpak.amberlinux.org.
#
# Same shape as amberlinux-apt — build locally, prove it with a real client, then
# deploy — and the same gates: preflight, lint, staging before upload. It is not a
# copy of it: reprepro's per-package model has targets an ostree repo has no use
# for, and MoSCoW.md records which were deliberately left out and why.
# See docs/DEPLOY.md.

OUT      ?= out
REPO     ?= $(OUT)
BUCKET   ?= amberlinux-flatpak-objects
HOST     ?= 127.0.0.1
PORT     ?= 8001
BRANCH   ?= main
REMOTE   ?= origin
ROOT_COMMIT_MSG ?= Initial amberlinux-flatpak

# Every sibling repo that produces a flatpak. Each answers `make flatpak-repo`
# with the path to an ostree repo it has built, so this archive never hardcodes
# another repo's output layout — the same contract amberlinux-apt uses for debs.
SUITE ?= ../odin-sdk-extension ../yggr

# The flatpak archive's own signing key (Amber Linux Flatpak Signing Key
# <flatpak@amberlinux.org>) — deliberately NOT the apt archive's key and not
# anyone's commit-signing key. The two archives have different lifecycles:
# this one empties into Flathub (docs/UPSTREAM.md) while apt is permanent, so
# neither key's compromise or retirement may touch the other. This line is the
# authority; lint checks every document against it, and fails if it ever
# equals the apt key again.
GPG_KEY ?= 060DD386E634C5C445DF3A7F2BE23FC60996C427

.PHONY: deps preflight hooks build add-suite import sign stage verify verify-fresh \ check-no-agent-files
	verify-client verify-http check check-buildpaths ci serve list deploy clean \
	push force-push lint diags

deps: preflight

# Tools present AND the archive key can actually sign. A missing or locked key
# otherwise yields a silently unsigned tree that fails on the user's machine.
preflight:
	@GPG_KEY=$(GPG_KEY) tools/preflight.sh

hooks:
	git config core.hooksPath .githooks
	@echo "hooks: shellcheck runs on staged shell files before every commit"

# archive-z2 is the mode for a repo served over plain HTTP: every object is a
# separate, individually compressed file, which is what lets a static host work.
build: deps
	@mkdir -p $(REPO)
	@test -f $(REPO)/config || ostree --repo=$(REPO) init --mode=archive-z2
	@echo "repo at $(REPO)"

# Pull each sibling's built extension/app into this repo.
add-suite: build
	@for r in $(SUITE); do \
		src=$$($(MAKE) --no-print-directory -s -C $$r flatpak-repo) || { echo "$$r: no flatpak-repo target"; exit 1; }; \
		test -d "$$src" || { echo "$$r: $$src is not a repo"; exit 1; }; \
		echo "== pulling from $$r ($$src)"; \
		ostree --repo=$(REPO) pull-local "$$src"; \
	done

# Two ways in. `add-suite` pulls from a sibling that built an ostree repo, which
# needs that repo's SDK installed locally. `import` takes a .flatpak bundle —
# a CI artifact, typically — which needs nothing but flatpak, and is how a
# machine that does not carry several GB of SDK still publishes.
#
#   make import BUNDLE=~/Downloads/odin-sdk-extension-x86_64.flatpak
import: build
	@test -n "$(BUNDLE)" || { echo "usage: make import BUNDLE=<file.flatpak>"; exit 2; }
	@test -f "$(BUNDLE)" || { echo "no such bundle: $(BUNDLE)"; exit 2; }
	flatpak build-import-bundle $(REPO) "$(BUNDLE)"
	@echo "imported $(BUNDLE); refs now:"
	@ostree --repo=$(REPO) refs

# No ref may name the machine that built it. Checked before sign because a
# signature on a leaking tree is a promise made to the wrong bytes; the apt
# archive runs the same gate over its .debs.
check-buildpaths: build
	@OUT=$(OUT) tools/check-buildpaths.sh

sign: build check-buildpaths
	# Sign every commit, then the summary. These are separate signatures and the
	# difference is not cosmetic: `build-update-repo --gpg-sign` signs only the
	# summary, so a client can `remote-ls` a repo whose commits are unsigned and
	# then fail at install with "GPG verification enabled, but no signatures
	# found". Commits arriving via build-import-bundle carry no signature of
	# their own, so they are signed here.
	# Drop each commit's .commitmeta before signing: gpg-sign appends rather
	# than replaces, so every stage run otherwise adds another signature to
	# every commit, growing without bound and re-uploaded each deploy. It has
	# to be rm — `gpg-sign --delete` matches signatures by key ID and reports
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
	# delta generated before the commits were signed survives re-signing — and
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
	printf '[Flatpak Repo]\nTitle=Amber Linux\nUrl=https://flatpak.amberlinux.org/\nHomepage=https://amberlinux.org/\nGPGKey=%s\n' \
		"$$(gpg --export-options export-minimal --export $(GPG_KEY) | base64 -w0)" > $(OUT)/amberlinux.flatpakrepo
	cp static/index.html cloudflare/_headers cloudflare/robots.txt $(OUT)/
	# Must be `.assetsignore`, with the dot: wrangler looks for that exact name
	# in the assets directory, and a file named `assetsignore` is silently just
	# another asset — which is how objects/** ends up uploaded twice.
	cp cloudflare/assetsignore $(OUT)/.assetsignore
	@echo "signed with $(GPG_KEY)"

# The tree's convention: `make check` proves what is here without publishing it.
# Cheaper than `stage`, which re-signs; this checks what is already built.
check: lint check-buildpaths verify verify-fresh verify-client
	@echo "check: the built tree is signed, coherent, current, clean of build paths, and installs for a real client"

# What a runner would do, if the signing key were ever reachable from one. It is
# not, so this is the local equivalent — see docs/DEPLOY.md.
ci: lint verify

# Assemble and prove it before anything is uploaded. `deploy` depends on this
# for the same reason amberlinux-apt's does: an index naming an object nobody
# can fetch is worse than no repo at all.
stage: lint sign verify verify-fresh verify-client
	@echo "stage: $(CURDIR)/$(OUT) is assembled and verified. 'make deploy' uploads it."

# Does the repo describe itself coherently?
verify:
	ostree --repo=$(REPO) fsck
	ostree --repo=$(REPO) refs
	@test -s $(OUT)/summary || { echo "no summary — run make sign"; exit 1; }
	@echo "verify OK"

# Does a real flatpak client, with no prior knowledge, see what we published?
# Serves the staged tree over HTTP and adds it as a remote, which is the only
# check that exercises summary, refs and objects the way a user will.
verify-client:
	@OUT=$(OUT) HOST=$(HOST) PORT=$(PORT) tools/verify-client.sh

# Is what the archive holds still what its siblings build? Nothing else asks:
# a stale ref is signed, coherent and installable, and yggr builds against it.
# The apt archive's target of the same name makes the same guarantee about
# .debs — see docs/DEPLOY.md.
verify-fresh:
	@SUITE="$(SUITE)" OUT=$(OUT) tools/verify-fresh.sh

# The same check against what is actually published, which is the only thing a
# user ever touches.
verify-http:
	@tools/verify-client.sh https://flatpak.amberlinux.org

serve: build
	python3 -m http.server $(PORT) --bind $(HOST) --directory $(OUT)

list:
	@ostree --repo=$(REPO) refs

# Upload objects to R2, then publish the worker + static metadata.
deploy: stage
	tools/r2-sync.sh
	cd cloudflare && npx wrangler deploy
	$(MAKE) --no-print-directory verify-http

clean:
	rm -rf $(OUT)

push:
	git push "$(REMOTE)" "$(BRANCH)"

# Agent files are never published. Two ways they get in: already tracked, or
# present-and-unignored when `git add -A` below sweeps the whole tree. Both are
# checked here, because a squashed history shows no file being added — a stray
# path simply appears in the root commit as though it always belonged.
check-no-agent-files:
	@bad=$$(git ls-files | grep -E '(^|/)(\.mcp\.json|\.claude/|\.claude-amber/)' || true); \
	if [ -n "$$bad" ]; then \
		echo "agent files are tracked and must not be published:"; \
		printf '  %s\n' $$bad; \
		echo "fix: git rm -r --cached <path>, then add it to .gitignore"; \
		exit 2; \
	fi
	@for p in .mcp.json .claude .claude-amber; do \
		if [ -e "$$p" ] && ! git check-ignore -q "$$p"; then \
			echo "$$p exists and is not gitignored — 'git add -A' would publish it"; \
			echo "fix: add $$p to .gitignore"; \
			exit 2; \
		fi; \
	done
	@echo "no agent files staged for publication"

force-push: lint stage check-no-agent-files
	@test -z "$$(git status --porcelain)" || { \
		echo "Working tree is dirty. Commit, stash, or revert changes first."; \
		exit 2; \
	}
	@orig_branch="$$(git branch --show-current)"; \
	tmp_branch="root-squash-$$(date +%s)"; \
	git checkout --orphan "$$tmp_branch"; \
	git add -A; \
	git commit -S -m "$(ROOT_COMMIT_MSG)"; \
	git branch -D "$(BRANCH)" 2>/dev/null || true; \
	git branch -m "$(BRANCH)"; \
	git push --force --set-upstream "$(REMOTE)" "$(BRANCH)"; \
	echo "Rewrote $$orig_branch as signed root commit on $(REMOTE)/$(BRANCH)."
	@echo "Now clear the workflow runs left pointing at the discarded commits —"
	@echo "see the force-push skill."

# The SVG is committed so reading the repo does not require d2; `make lint`
# fails when it drifts from the source.
diags:
	@for f in diags/*.d2; do \
		d2 --theme=105 --dark-theme=300 --pad=40 "$$f" "$${f%.d2}.svg"; \
		chmod 644 "$${f%.d2}.svg"; \
	done

lint:
	@tools/lint.sh
	@if command -v shellcheck >/dev/null; then \
		shellcheck --severity=warning tools/*.sh && echo "shellcheck OK"; \
	else echo "shellcheck not installed — skipping (apt install shellcheck)"; fi
