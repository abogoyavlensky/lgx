.PHONY: build dev-install dev-run clean

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

clean:
	rm -rf $(dir $(BIN))
