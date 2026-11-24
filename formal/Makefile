# Formal proofs of the example programs running on the setl_lane RTL.
#   make            bounded proofs + reachability checks for every program
#   make uart_tx    one program
# Requires yosys, SymbiYosys (sby) and yosys-abc.  Counterexamples: python3 cex.py <task_dir> [signals]
PROGS = uart_tx spi i2c
SRC_uart_tx = uart_tx
SRC_spi     = spi_ctrl
SRC_i2c     = i2c_ctrl
ASM = PYTHONPATH=../tools python3 -m setl.asm

all: $(PROGS) barrel

build/%/rom.vh: ../programs/*.setl ../tools/setl/*.py
	mkdir -p build/$*
	$(ASM) ../programs/$(SRC_$*).setl --vrom build/$*/rom.vh --vsyms build/$*/sym.vh

$(PROGS): %: build/%/rom.vh
	sby -f $@.sby bmc
	sby -f $@.sby reach

# unbounded proof that the barrel never stalls a lane (any program, any host traffic)
barrel:
	sby -f barrel.sby prove
	sby -f barrel.sby reach

clean:
	rm -rf build *_bmc *_reach *_prove

.PHONY: all clean barrel $(PROGS)
