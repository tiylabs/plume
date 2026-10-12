# Plume — common tasks. Thin wrappers over Scripts/*; run `make help` for the list.
.DEFAULT_GOAL := help
.PHONY: help lint test test-all dev build editor clean

EDITOR_DIR := Editor
DEV_APP    := build/Plume Dev.app

help: ## Show this help
	@awk 'BEGIN{FS=":.*## "} /^[a-zA-Z_-]+:.*## /{printf "  make %-10s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

$(EDITOR_DIR)/node_modules: $(EDITOR_DIR)/package-lock.json
	cd $(EDITOR_DIR) && npm ci
	@touch $@

lint: $(EDITOR_DIR)/node_modules ## Typecheck the editor (tsc), check doc references, run SwiftLint if installed
	cd $(EDITOR_DIR) && npm run --silent typecheck
	Scripts/check-doc-refs.sh
	@if command -v swiftlint >/dev/null 2>&1; then swiftlint lint --quiet; \
	else echo "swiftlint not installed, skipping (brew install swiftlint)"; fi

test: ## Run the PlumeKit suite (pure Foundation)
	Scripts/test.sh

test-all: $(EDITOR_DIR)/node_modules ## Run every suite: PlumeKit, typecheck, keyboard, WKWebView suites
	Scripts/test-all.sh

dev: $(EDITOR_DIR)/node_modules ## Rebuild the isolated Plume Dev.app without stopping the release app
	swift Scripts/tools/dev-app.swift stop "$(CURDIR)/$(DEV_APP)" "$(CURDIR)/build/Plume.app"
	Scripts/build-app.sh --debug
	open "$(CURDIR)/$(DEV_APP)"

build: $(EDITOR_DIR)/node_modules ## Release build of build/Plume.app (host architecture)
	Scripts/build-app.sh --release

editor: $(EDITOR_DIR)/node_modules ## Rebuild only the web editor bundle
	cd $(EDITOR_DIR) && node build.mjs

clean: ## Remove build outputs while preserving build/Plume-scratch notes
	rm -rf .build $(EDITOR_DIR)/dist
	@if [ -L build ]; then rm build; \
	elif [ -d build ]; then \
		for path in build/* build/.[!.]* build/..?*; do \
			[ "$$path" = "build/Plume-scratch" ] && continue; \
			[ -e "$$path" ] || [ -L "$$path" ] || continue; \
			rm -rf "$$path" || exit $$?; \
		done; \
	fi
