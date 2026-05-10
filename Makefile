.PHONY: build dev-install dev-run test clean

LG ?= lg
BIN := bin/lgx

build:
	@mkdir -p $(dir $(BIN))
	$(LG) -b $(BIN) lgx.lg
	@echo "built $(BIN)"

dev-install:
	$(LG) lgx.lg install

dev-run:
	$(LG) lgx.lg run examples/hello/main.lg

test:
	bash tests/run.sh

clean:
	rm -rf $(dir $(BIN))
