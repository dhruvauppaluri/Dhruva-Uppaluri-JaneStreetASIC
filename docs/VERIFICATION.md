# Verification

There are three independent views of correctness. They meet at one artifact: the
64-bit state record.

## 1. Golden model in lockstep (every RTL test)

`tools/setl/model.py` is a cycle-accurate Python model of the core: the barrel, lanes,
FIFOs, pin router and synchronisers. The cocotb harness (`test/harness.py`) runs it in
**lockstep with the RTL**. On every clock it:

* replays into the model the host strobes the RTL actually produced (register writes, FIFO
  pops, granted memory writes). This means the SPI shell is exercised for real, not modelled;
* steps the model with the same pin inputs;
* compares all 15 lane-driven outputs, the output enables, and every internal lane register
  (`pc`, `valid`, `pending`, `first`, `timer`, `cnt`, `sr`, `slot_val`, `flag`) plus the slot
  counter.

Any divergence is reported at the cycle where it starts, not when it reaches a pin.

## 2. Independent protocol models (directed tests, `test/test.py`)

The test benches in `test/bfm.py` know nothing about SETL. They implement the
protocols from their specifications:

| test | checks |
|------|--------|
| `test_id_regs_mem` | ID/version, register readback, program memory write/readback, byte-granular writes |
| `test_uart_tx` | 7 bytes including 0x00/0xFF, TX FIFO refilled while sending |
| `test_uart_rx_and_loopback_lane` | 3 lanes at once in 4-lane mode: RX from the test bench, TX, and a second RX lane listening to the TX lane through the on-chip output readback |
| `test_spi_modes` | SPI controller, **all four modes**, full duplex, multi-byte frame with CS held |
| `test_i2c_eeprom` | I²C controller write, pointer set, 3-byte read with ACK/NACK, **clock stretching**, NACK on a wrong address raising a host event, and the rest of the transaction discarded |

These tests run on RTL with both memory builds (`make`, `make SETL_MEM=small`), and are
designed to run on the gate-level netlist (`GATES=yes`), where the lockstep model is
switched off automatically. Every directed program fits in 64 words, so the fallback
netlist runs the same suite.

## 3. Constrained-random co-simulation (`test/test_random.py`)

Each seed generates random 64-bit records for all four lanes (24 states each, all
condition and action encodings including the reserved ones). It also randomises the
configuration: barrel width, dividers, bit order, pin maps with open-drain and
inversion, match and mask. Random pin activity is driven on `ui[4:0]` and the `uio` bus.
While the lanes run, random host traffic arrives: FIFO pushes and pops, host flags,
**program rewrites while lanes are running**, lane stop/restart, and status clears.
The lockstep comparator (section 1) is the oracle.

The current default is 16 seeds, about 840k clock cycles, about 270k lane ticks and about
22k state entries. All seeds show zero mismatches. Coverage counters (`model.cov`) are
printed per seed.

Known gap: coverage still varies a lot between seeds, because random graphs often settle
into states that wait for conditions that never occur. A coverage-directed generator is
on the to-do list.

## Running

```
cd test
make                                  # directed tests (RTL, 512-word memory, lockstep model)
make SETL_MEM=small                   # same tests, 64-word fallback memory
make COCOTB_TEST_MODULES=test_random  # random co-simulation (SETL_SEEDS, SETL_CYCLES, SETL_SEED0)
make GATES=yes                        # gate level (after the GDS action has produced a netlist)
```

## Not yet done (see the plan)

* Formal equivalence between a source FSM and its compiled record image (SBY/EQY).
* Gate-level simulation with the SRAM build. The Tiny Tapeout GL action will provide it once
  the SRAM hardening is in place.
* FPGA bring-up.

## AI use

This design, its model, toolchain, tests and documentation were written with the help of an
AI assistant (Claude). The human author reviewed and directed the work.
