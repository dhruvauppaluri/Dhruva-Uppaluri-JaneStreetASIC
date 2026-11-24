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
| `test_uart_autobaud` | the lane learns 40 and then 26 ticks/bit from a calibration character, receives at each rate, and the learned TA is read back |
| `test_spi_target` | SPI **target** role: a 3-byte full-duplex exchange driven by a test-bench controller |
| `test_i2c_target` | SETL as an I²C **target**: writes, pointer write + repeated START + read with ACK/NACK, wrong address ignored |
| `test_i2c_controller_and_target_on_one_chip` | lane 0 is the controller and lane 1 the target, on the same open-drain pins, so the chip talks to itself through its pads (512-word memory only) |
| `test_ws2812` | LED bit stream decoded by pulse width; exact high times |
| `test_ps2_rx` | PS/2 keyboard frames (start, data, odd parity, stop) clocked by the device |
| `test_jtag_idcode` | JTAG adapter against a full 16-state TAP model: reset, walk to Shift-DR, read a 32-bit IDCODE, return to Run-Test/Idle with the exact TCK count |
| `test_learn_and_impersonate` | **learn, then impersonate**. An MCU model talks to a sensor model at real 100 kHz timing while lane 0 sniffs the bus. The host learns a register-device model from the capture. The sensor is unplugged, the chip is reprogrammed as a host-served target, and the MCU repeats its traffic and gets identical answers. The target stretches SCL while the host prepares each reply. |
| `test_modbus_crc` | MODBUS RTU on three lanes: lane 0 appends CRC-16 on chip (matches the standard `01 03 00 00 00 0A → C5 CD` vector), lane 1 receives over the on-chip readback and checks the CRC, lane 2 flags a corrupted frame |
| `test_usb_ls_tx` | USB low-speed DATA0 (with forced bit stuffing), ACK handshake, and empty DATA1. An independent decoder does NRZI, un-stuffing, SYNC, PID, CRC-16 and EOP, and asserts that **every transition lies exactly on the bit grid** (512-word memory only) |
| `test_usb_ls_loopback` | USB LS TX lane → RX lane through the on-chip readback: clock recovery, NRZI, un-stuffing, CRC check; data packets and a handshake (512-word memory only) |
| `test_can_tx` | CAN 2.0A frames at 500 kbit/s against a real-time receiver that de-stuffs, checks the bit grid and the CRC-15, and drives the ACK slot; stuffing in the ID and data fields; a frame with no ACK raises the host event (512-word memory only) |
| `test_swd_read_dpidr` | SWD against a debug-port model: line reset, JTAG-to-SWD switch, DPIDR read with ACK=OK, data and parity |
| `test_manchester` | the tutorial's protocol: Manchester line coding decoded independently, with every edge on the half-bit grid |
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

The current default is 16 seeds, about 850k clock cycles, about 270k lane ticks and about
22k state entries. All seeds show zero mismatches. Coverage counters (`model.cov`) are
printed per seed.

The stimulus is coverage-directed. The test watches the golden model, and a lane that
has not changed state since the last look (parked on a condition that may never come) is
restarted, sometimes from a different start state. This steadied the per-seed coverage:
the minimum state entries per seed went from tens to hundreds or thousands.

## 4. Formal proofs of the programs on the RTL (`formal/`)

The assembler can emit any program as a Verilog ROM (`--vrom`, `--vsyms`). Each
harness (`formal/fv_*.v`) runs one program on the real `setl_lane` RTL, with the
chip's record-memory timing: fetch in the lane's slot, data one clock later. The
environment is unconstrained, apart from "the host never overfills the TX FIFO" and
"quiet during reset". Any data can be pushed at any time, any target can ACK or NACK,
drive any data, and stretch SCL for any length. A **shadow FIFO** tracks the host's
pushes, so the proofs check the *data* that comes out, not just the waveform shape.

| program | properties proved |
|---------|-------------------|
| `uart_tx` | Every frame is an exact 8N1 frame of the next byte the host pushed, in order. Every bit lasts exactly 2·(TA+1) clocks. The line never glitches and idles high. Every frame consumes exactly one FIFO byte. |
| `spi_ctrl` (mode 0) | SCK only moves while CS is low. MOSI is stable while SCK is high and across the rising edge. Each popped byte goes out MSB-first on exactly 8 rising edges. CS only rises on a byte boundary. The received byte equals the MISO bits at the rising edges. |
| `i2c_ctrl` | Under any target behaviour, including unbounded clock stretching, SDA changes while SCL is high only in the START state (falling) and the STOP state (rising). SCL and SDA never change in the same clock. |

The proofs are **bounded**: every behaviour from reset for 90 / 110 / 300 clocks. That is
several complete UART frames, several SPI bytes, and a full I²C write and read
transaction. Each harness also has a **reachability check** (`-DREACH`, SBY `expect fail`).
It asserts that a milestone never happens within the *same* bound: two complete UART
frames; a received SPI byte and then CS released; an I²C read byte followed by STOP. The
solver must find a trace that reaches it. This shows the proofs are not vacuous. This
check found a real harness bug during development: a mis-sized I²C input vector made
the read path unreachable, and the shallow proof had been passing vacuously.

### Unbounded proof: the barrel never stalls a lane (`formal/barrel.sby`)

This proof runs on the **complete chip** with the host SPI pins and protocol pins left
completely free. That means any register, memory or FIFO traffic, lanes started and
stopped at any time, and the barrel width changed at any time. The record memory is
replaced by arbitrary data (`SETL_FORMAL_ANY_MEM`), so it covers every program at once.
ABC's PDR proves, for all time:

* at most one lane fetches a record in any clock;
* every fetch is answered on the very next clock, to the lane that asked;
* a lane never reaches its slot while it is still waiting for record data.

Together these are the architecture's determinism claim: a lane can change state on
every one of its ticks, whatever the other lanes and the host do. The proof takes about
15 s. A reachability check (lane 3 receiving a record in 4-lane mode, which needs real
SPI configuration traffic) shows it is not vacuous.

The protocol-level proofs above stay bounded. PDR on the full lane datapath with a
protocol monitor did not converge within 30 minutes.

```
cd formal && make                 # about 7 minutes; needs yosys, sby, yosys-abc
python3 cex.py <task_dir> sig...  # print a counterexample (no SMT solver needed)
```

## Running

```
cd test
make                                  # directed tests (RTL, 512-word memory, lockstep model)
make SETL_MEM=small                   # same tests, 64-word fallback memory
make COCOTB_TEST_MODULES=test_random  # random co-simulation (SETL_SEEDS, SETL_CYCLES, SETL_SEED0)
make GATES=yes                        # gate level (after the GDS action has produced a netlist)
```

## Not yet done (see the plan)

* Unbounded versions of the program-level proofs.
* Gate-level simulation with the SRAM build. The Tiny Tapeout GL action will provide it once
  the SRAM hardening is in place.
* FPGA bring-up.

## AI use

This design, its model, toolchain, tests and documentation were written with the help of an
AI assistant (Claude). The human author reviewed and directed the work.
