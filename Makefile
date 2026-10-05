# Maccy builds with the Command Line Tools only: `xcode-select --install`.
# Common tasks: make install, make test, make self-test.

SWIFT ?= swift
APP_DIR ?= build/Maccy.app
INSTALL_DIR ?= /Applications

# The Command Line Tools ship the Swift Testing macro plugin outside the default search path.
TESTING_PLUGINS := $(shell xcode-select -p)/usr/lib/swift/host/plugins/testing
TEST_FLAGS := $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS),)

.PHONY: build app install test perf self-test snapshots run clean signing-identity

build: ## Debug build
	$(SWIFT) build

app: ## Release build, bundled and signed, in build/Maccy.app
	APP_DIR=$(APP_DIR) scripts/bundle.sh

install: app ## Build, then replace the app in /Applications and start it
	-osascript -e 'tell application id "com.pgilad.Maccy" to quit' >/dev/null 2>&1
	rm -rf "$(INSTALL_DIR)/Maccy.app"
	cp -R "$(APP_DIR)" "$(INSTALL_DIR)/Maccy.app"
	open "$(INSTALL_DIR)/Maccy.app"

test: ## Unit tests (MaccyCore)
	$(SWIFT) test $(TEST_FLAGS)

perf: ## Search timings on 100,000 generated items
	MACCY_PERF=1 $(SWIFT) test -c release $(TEST_FLAGS) --filter PerformanceTests

self-test: build ## Capture, store, search and write-back on a private pasteboard
	.build/debug/Maccy --self-test

snapshots: build ## Render the panel to PNG files in build/snapshots
	.build/debug/Maccy --render-snapshots build/snapshots

run: build ## Run the debug build with a throwaway data folder
	MACCY_DATA_DIR=$$(mktemp -d) .build/debug/Maccy

signing-identity: ## Create the "Maccy Local Signing" certificate (once per Mac)
	scripts/create-signing-identity.sh

clean:
	rm -rf .build build
