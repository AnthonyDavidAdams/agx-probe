CC      = clang
CFLAGS  = -fobjc-arc -O2 -Wall -Isrc
FRAME   = -framework Foundation -framework Metal
BIN     = build/state_probe build/isa_probe build/write_probe build/cull_probe build/validate_all

all: $(BIN)

build:
	@mkdir -p build

build/%: src/%.m src/agxcommon.h | build
	$(CC) $(CFLAGS) -o $@ $< $(FRAME)

run: all
	./build/state_probe > results/state-map.txt 2> results/state-log.txt & \
	./build/isa_probe   > results/isa-map.txt   2> results/isa-log.txt & \
	wait

validate: build/write_probe build/cull_probe build/validate_all
	./build/write_probe
	./build/cull_probe

clean:
	rm -rf build
.PHONY: all run validate clean
