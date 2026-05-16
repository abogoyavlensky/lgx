.PHONY: build dev-install dev-run test clean

LG ?= lg
BIN := bin/lgx

# Extract version from lgx.lg
VERSION := $(strip $(shell awk -F '"' '/def[[:space:]]+version[[:space:]]+"/ { print $$2; exit }' lgx.lg))
TAG := v$(VERSION)

# Styling for output
YELLOW := "\e[1;33m"
NC := "\e[0m"
INFO := @sh -c '\
    printf $(YELLOW); \
    echo "=> $$1"; \
    printf $(NC)' VALUE

# Ignore output of make `echo` command
.SILENT:

.PHONY: help  # Show list of targets with descriptions
help:
	@$(INFO) "Commands:"
	@grep '^.PHONY: .* #' Makefile | sed 's/\.PHONY: \(.*\) # \(.*\)/\1 > \2/' | column -tx -s ">"

.PHONY: build  # Build binary
build:
	@$(INFO) "Building $(BIN)..."
	@mkdir -p $(dir $(BIN))
	$(LG) -b $(BIN) lgx.lg
	@echo "built $(BIN)"

.PHONY: dev-install  # Install development dependencies
dev-install:
	@$(INFO) "Installing development dependencies..."
	$(LG) lgx.lg install

.PHONY: dev-run  # Run development script
dev-run:
	@$(INFO) "Running development script..."
	$(LG) lgx.lg run examples/hello/main.lg

.PHONY: test  # Run tests
test:
	@$(INFO) "Running tests..."
	bash tests/run.sh

.PHONY: fmt  # Format code
fmt:
	@$(INFO) "Formatting code..."
	cljfmt fix

.PHONY: fmt-check  # Check code formatting
fmt-check:
	@$(INFO) "Checking code formatting..."
	cljfmt check

.PHONY: clean  # Clean build artifacts
clean:
	@$(INFO) "Cleaning build artifacts..."
	rm -rf $(dir $(BIN))

.PHONY: release  # Add tag and push to build and publish release version in CI
release:
	@$(INFO) "Publishing release version $(TAG)..."
	@test -n "$(VERSION)" || { echo "Could not read version from lgx.lg"; exit 1; }
	git tag "$(TAG)"
	git push origin "$(TAG)"
