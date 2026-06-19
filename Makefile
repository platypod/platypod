SHELL := bash
.DEFAULT_GOAL := help

REPO   ?= platypod/platypod
REMOTE ?= git@github.com:$(REPO).git
BRANCH ?= main

# Space-separated list of every child path registered as a submodule.
paths   = $(shell git config -f .gitmodules --get-regexp '\.path$$' 2>/dev/null | awk '{print $$2}')

.PHONY: help init add pull update track track-all sync status publish

help: ## Show this help
	@echo "platypod umbrella — submodule management"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-9s\033[0m %s\n",$$1,$$2}'
	@echo
	@echo "Typical first run:   make init && make add && make sync && make publish"
	@echo "After cloning:       git clone --recurse-submodules $(REMOTE)  (or: make pull)"

init: ## Initialise an empty umbrella repo here (idempotent)
	@if [ -d .git ]; then echo "Already a git repo."; else \
		git init -b main >/dev/null && echo "Initialised umbrella repo on 'main'."; fi

add: ## Register any ./*/ git checkout not yet tracked as a submodule (run after adding a new project)
	@bak=$$(mktemp -d); \
	for d in */ ; do \
		d=$${d%/}; \
		git -C "$$d" rev-parse --git-dir >/dev/null 2>&1 || continue; \
		if echo " $(paths) " | grep -q " $$d "; then echo "  have  $$d"; continue; fi; \
		url=$$(git -C "$$d" remote get-url origin 2>/dev/null) || { echo "  skip  $$d (no origin remote)"; continue; }; \
		branch=$$(git -C "$$d" rev-parse --abbrev-ref HEAD 2>/dev/null); \
		echo "  add   $$d ($$branch) <- $$url"; \
		mv "$$d" "$$bak/$$d"; \
		if git submodule add -b "$$branch" "$$url" "$$d" >/dev/null 2>&1; then \
			rm -rf "$$bak/$$d"; \
		else \
			echo "  FAIL  $$d (restoring, left untracked)"; rm -rf "$$d"; mv "$$bak/$$d" "$$d"; \
		fi; \
	done; \
	rmdir "$$bak" 2>/dev/null || true

pull: ## Init & check out all submodules at their pinned commits; silently skip repos you can't access
	@git submodule init >/dev/null 2>&1 || true; \
	for p in $(paths); do \
		if git submodule update --init -- "$$p" >/dev/null 2>&1; then echo "  ok    $$p"; \
		else echo "  skip  $$p (no access / offline)"; fi; \
	done

update: ## Bump each submodule to the latest commit on its tracked branch; skip inaccessible ones
	@for p in $(paths); do \
		if git submodule update --remote --init -- "$$p" >/dev/null 2>&1; then echo "  ok    $$p"; \
		else echo "  skip  $$p (no access / offline)"; fi; \
	done; \
	echo "Pointers updated — review 'make status', then 'make sync'."

track: ## Point one submodule at a branch + re-pin to its tip. Usage: make track NAME=stack [BRANCH=main]
	@test -n "$(NAME)" || { echo "Usage: make track NAME=<submodule> [BRANCH=<branch>]"; exit 1; }
	@git -C "$(NAME)" fetch origin "$(BRANCH)" >/dev/null 2>&1 || { echo "  skip  $(NAME) (no '$(BRANCH)' on remote / no access)"; exit 0; }
	@git -C "$(NAME)" checkout -q "$(BRANCH)" && git -C "$(NAME)" merge -q --ff-only "origin/$(BRANCH)" 2>/dev/null || true
	@git config -f .gitmodules submodule.$(NAME).branch "$(BRANCH)"
	@git add .gitmodules "$(NAME)"
	@echo "  $(NAME) tracks $(BRANCH) @ $$(git -C "$(NAME)" rev-parse --short HEAD) (staged — run 'make sync')"

track-all: ## Point every submodule at one branch. Usage: make track-all [BRANCH=main]
	@for p in $(paths); do $(MAKE) --no-print-directory track NAME=$$p BRANCH=$(BRANCH); done

sync: ## Commit umbrella files + any submodule pointer changes
	@git add .gitmodules .gitignore Makefile README.md CLAUDE.md .claude $(paths) 2>/dev/null || true; \
	if git diff --cached --quiet; then echo "Nothing to sync."; \
	else git commit -m "Update umbrella (files + submodule pointers)"; fi

status: ## Show each submodule's checked-out commit and branch
	@git submodule status 2>/dev/null || echo "No submodules yet — run 'make init add'."

publish: ## Create the public GitHub repo $(REPO) and push (one-time)
	@if git remote get-url origin >/dev/null 2>&1; then \
		git push -u origin main; \
	else \
		gh repo create $(REPO) --public --source=. --remote=origin --push; fi
