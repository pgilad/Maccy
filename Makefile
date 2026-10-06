# Maccy builds with the Command Line Tools only: `xcode-select --install`.
# Common tasks: make install, make test, make self-test, make lint.

SWIFT ?= swift
APP_DIR ?= build/Maccy.app
INSTALL_DIR ?= /Applications
# Extra flags for swift build and swift test. CI uses -Xswiftc -warnings-as-errors.
SWIFT_FLAGS ?=

# The Command Line Tools ship the Swift Testing macro plugin outside the default search path.
TESTING_PLUGINS := $(shell xcode-select -p)/usr/lib/swift/host/plugins/testing
TEST_FLAGS := $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS),)
# SwiftLint needs SourceKit. Without Xcode, it must look in the Command Line Tools.
LINT_ENV := $(if $(findstring CommandLineTools,$(shell xcode-select -p)),TOOLCHAIN_DIR=$(shell xcode-select -p),)

.PHONY: build app install test perf lint self-test snapshots run clean signing-identity

build: ## Debug build
	$(SWIFT) build $(SWIFT_FLAGS)

app: ## Release build, bundled and signed, in build/Maccy.app
	APP_DIR=$(APP_DIR) SWIFT_FLAGS="$(SWIFT_FLAGS)" scripts/bundle.sh

install: app ## Build, then replace the app in /Applications and start it
	-osascript -e 'tell application id "com.pgilad.Maccy" to quit' >/dev/null 2>&1
	rm -rf "$(INSTALL_DIR)/Maccy.app"
	cp -R "$(APP_DIR)" "$(INSTALL_DIR)/Maccy.app"
	open "$(INSTALL_DIR)/Maccy.app"

test: ## Unit tests (MaccyCore)
	$(SWIFT) test $(SWIFT_FLAGS) $(TEST_FLAGS)

perf: ## Search timings on 100,000 generated items
	MACCY_PERF=1 $(SWIFT) test -c release $(SWIFT_FLAGS) $(TEST_FLAGS) --filter PerformanceTests

lint: ## SwiftLint, warnings fail (brew install swiftlint)
	$(LINT_ENV) swiftlint lint --strict --quiet

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
