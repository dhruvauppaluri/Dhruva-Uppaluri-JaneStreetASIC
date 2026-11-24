# Build every program into build/<name>.json ({"image": {addr: hex}, "symbols": {...}})
# for loading from a host (PC or the RP2350):  make -C programs
ASM = PYTHONPATH=../tools python3 -m setl.asm
SRC = $(wildcard *.setl)
OUT = $(SRC:%.setl=build/%.json)

all: usb_ls_tx.setl usb_ls_rx.setl can_tx.setl $(OUT)

usb_ls_tx.setl: gen_usb_ls_tx.py
	python3 gen_usb_ls_tx.py
usb_ls_rx.setl: gen_usb_ls_rx.py
	python3 gen_usb_ls_rx.py
can_tx.setl: gen_can_tx.py
	python3 gen_can_tx.py

build/%.json: %.setl ../tools/setl/asm.py ../tools/setl/isa.py
	@mkdir -p build
	$(ASM) $< -o $@

clean:
	rm -rf build

.PHONY: all clean
