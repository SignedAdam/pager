# pager. Run `make` to see everything below.
.DEFAULT_GOAL := help
SHELL := /bin/bash

VERSION    := $(shell grep -m1 '^let VERSION' src/Pager.swift | cut -d'"' -f2)
SRC        := src/Pager.swift
BIN        := bin/pager
DIST       := dist/pager
FRAMEWORKS := -framework Cocoa -framework AVFoundation -framework AVKit
ACCENT     := \033[38;5;190m
DIM        := \033[2m
OFF        := \033[0m

.PHONY: help build install uninstall reinstall release tour demo sounds examples \
        log stats follow browse clean check test watch panels kill shots tarball readme

help: ## show this
	@printf '\n  $(ACCENT)pager$(OFF)  $(DIM)a floating notification panel anything can raise$(OFF)\n\n'
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	 | awk -F':.*?## ' '{printf "  \033[38;5;190m%-11s\033[0m %s\n", $$1, $$2}'
	@printf '\n'

# ------------------------------------------------------------------ building

build: $(BIN) ## compile bin/pager

$(BIN): $(SRC)
	@mkdir -p $(dir $@)
	@swiftc -O -o $(BIN) $(SRC) $(FRAMEWORKS)
	@printf '  $(ACCENT)built$(OFF)  $(BIN)  $(DIM)%s$(OFF)\n' "$$(du -h $(BIN) | cut -f1)"

install: ## build, link onto PATH, link the skill, start the tour
	@./install.sh

reinstall: clean install ## from scratch

uninstall: ## remove the links, keep ~/.pager
	@./install.sh --uninstall

release: ## rebuild the universal binary in dist/ for people without swiftc
	@./install.sh --release

clean: ## remove the built binary
	@rm -rf bin
	@printf '  $(DIM)removed bin/$(OFF)\n'

# ------------------------------------------------------------------- running

tour: $(BIN) ## the guided tour, fifteen panels
	@$(BIN) --tour

demo: $(BIN) ## raise one panel showing most of what it can do
	@$(BIN) --title "Deploy failed on production" \
		--app "coolify" --icon "exclamationmark.triangle" --source "deploy" \
		--accent "#ff5f57" --sound alarm --seconds 25 \
		--body "3 of 12 containers unhealthy. Rolled back to \`8f21ac3\`, *automatically*." \
		--chip "production" --chip "2m14s ago" \
		--sparkline "9,9,8,9,12,20,31,44" \
		--action "Logs:open https://example.com" \
		--action "Rollback:" --action-fill "#ff5f57" --action-text "#ffffff"

sounds: $(BIN) ## play the ten bundled sounds in turn
	@$(BIN) --sounds

examples: $(BIN) ## print copy-pasteable recipes
	@$(BIN) --examples

# ------------------------------------------------------------------ watching

browse: $(BIN) ## open the log as a window
	@$(BIN) log --window

follow: $(BIN) ## tail the log as it happens
	@$(BIN) log --follow

panels: ## list panels on screen right now
	@pgrep -fl "bin/pager --" | sed 's/^/  /' || printf '  $(DIM)none$(OFF)\n'

kill: ## dismiss every panel on screen
	@pkill -f "bin/pager --" 2>/dev/null; rm -f ~/.pager/slot-*
	@printf '  $(DIM)cleared$(OFF)\n'

log: $(BIN) ## the recent log, columned and coloured
	@$(BIN) log

stats: $(BIN) ## what calls pager, and how the panels end
	@$(BIN) log --stats

# ------------------------------------------------------------------- checking

check: ## syntax check every script and the Swift source
	@bash -n install.sh && printf '  install.sh  ok\n'
	@bash -n tour/tour.sh && printf '  tour.sh     ok\n'
	@for f in examples/*.sh; do bash -n $$f && printf '  %-11s ok\n' "$$(basename $$f)"; done
	@swiftc -typecheck $(SRC) $(FRAMEWORKS) && printf '  Pager.swift ok\n'

readme: ## check the README against the actual program
	@python3 tools/validate-readme.py

test: check readme ## drive the whole tour with a stub, no windows opened
	@tmp=$$(mktemp -d); \
	printf '#!/bin/bash\necho "$$@" >> $$STUBLOG\necho "---" >> $$STUBLOG\necho "$$STUBANSWER"\n' > $$tmp/stub; \
	chmod +x $$tmp/stub; \
	mkdir -p $$tmp/home/.claude/skills $$tmp/home/.config/opencode $$tmp/home/.codex; \
	printf '# existing\n' > $$tmp/home/.codex/AGENTS.md; \
	: > $$tmp/log; \
	STUBLOG=$$tmp/log STUBANSWER="Next" PAGER_CMD=$$tmp/stub HOME=$$tmp/home \
	  bash tour/tour.sh >/dev/null 2>&1; \
	n=$$(grep -c '^---$$' $$tmp/log); \
	total=$$(grep -m1 '^TOTAL=' tour/tour.sh | cut -d= -f2); \
	steps=$$(grep -c -- "--chip [0-9]* of $$total" $$tmp/log); \
	STUBLOG=$$tmp/log STUBANSWER="Install for all 3" PAGER_CMD=$$tmp/stub HOME=$$tmp/home \
	  bash tour/tour.sh >/dev/null 2>&1; \
	STUBLOG=$$tmp/log STUBANSWER="Install for all 3" PAGER_CMD=$$tmp/stub HOME=$$tmp/home \
	  bash tour/tour.sh >/dev/null 2>&1; \
	blocks=$$(grep -c 'pager:start' $$tmp/home/.codex/AGENTS.md); \
	link=$$([ -L $$tmp/home/.claude/skills/pager ] && echo yes || echo no); \
	printf '\n  panels raised   %s\n  steps           %s of %s\n  skill linked    %s\n  codex blocks    %s (must be 1 after two installs)\n\n' \
	  "$$n" "$$steps" "$$total" "$$link" "$$blocks"; \
	rm -rf $$tmp; \
	[ "$$steps" = "$$total" ] && [ "$$blocks" = 1 ] && [ "$$link" = yes ]

tarball: ## build a self-contained archive people can install without git
	@./install.sh --release >/dev/null
	@rm -rf /tmp/pager-pkg && mkdir -p /tmp/pager-pkg/pager
	@cp -R dist bin src sounds assets tour skills examples install.sh LICENSE README.md /tmp/pager-pkg/pager/ 2>/dev/null || true
	@cp dist/pager /tmp/pager-pkg/pager/bin/pager
	@tar -czf pager-$(VERSION)-macos.tar.gz -C /tmp/pager-pkg pager
	@rm -rf /tmp/pager-pkg
	@printf '  $(ACCENT)packaged$(OFF)  pager-$(VERSION)-macos.tar.gz  $(DIM)%s$(OFF)\n' "$$(du -h pager-$(VERSION)-macos.tar.gz | cut -f1)"

shots: $(BIN) ## regenerate the screenshots in docs/
	@swiftc -O -o /tmp/backdrop tools/backdrop.swift -framework Cocoa
	@python3 tools/shoot.py

watch: ## rebuild whenever the source changes
	@command -v fswatch >/dev/null || { echo "brew install fswatch"; exit 1; }
	@printf '  $(DIM)watching $(SRC)$(OFF)\n'
	@fswatch -o $(SRC) | while read -r _; do $(MAKE) --no-print-directory build; done
