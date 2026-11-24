# Status and plan (deadline 2027-01-18)

## Done (week 0–1)

* **Architecture frozen v1**: 64-bit state records, 4 lanes on a 2/4-way deterministic barrel,
  a registered-read memory contract that matches the IHP macro, and pin routing with
  open-drain and invert.
* **Executable spec**: `tools/setl/model.py`, a cycle-accurate golden model.
* **Toolchain**: assembler (`tools/setl/asm.py`) and host driver (`tools/setl/host.py`, transport-agnostic).
* **RTL**: `src/` (lane, FIFO, SPI host shell, memory wrapper with three build options),
  lint-clean under Verilator `-Wall`.
* **Programs**: UART TX, UART RX (with framing-error event), SPI controller in all four
  modes, an I²C controller (write, read, ACK/NACK, clock stretching, NACK abort), an
  **SPI target**, and a **UART receiver that learns its baud rate on chip** (stopwatch → TA/TB).
* **Verification**: 7 directed tests against independent protocol models, all passing with
  the golden model in lockstep on RTL with both memory builds. Constrained-random
  co-simulation: 16 seeds, about 840k cycles, zero mismatches.
* **Area (Yosys + CMOS5L typ liberty)**:
  * SRAM build: 8.7k cells, 0.145 mm² of cells, plus 2 × 0.080 mm² SRAM. About 25% of the die.
  * Fallback build (64-word flop memory): 21.7k cells, 0.47 mm². About 38% of the die.

## Next: the physical gate (top priority, needs GitHub Actions)

This container cannot run LibreLane, so hardening happens in the Tiny Tapeout GitHub
action.

1. Push to a GitHub repo. The `gds` workflow hardens the **fallback build** (stock flow,
   `src/config.json`, 50 MHz). Goal: green GDS, precheck and GL test. Record the slack.
2. SRAM build: define `SETL_IHP_SRAM`, add the two macros to `MACROS` /
   `PDN_MACRO_CONNECTIONS`, and bring in the CMOS5L Metal4 power fix. Ken Pettit's
   Apache-2.0 `ExtendPowerStripes` LibreLane plugin (`kdp1965/ihp-um-janestreet-prism`)
   is the known-working recipe: placement on the 11.24 µm SRAM power-column grid, and
   `FP_PDN_VPITCH` 44.96. Use the LEF/LIB/CDL from `libs.ref/sg13cmos5l_sram/`, not trimmed
   copies.
3. Cut line from the plan: if step 2 isn't green by about 2026-12-08, ship the fallback
   build and spend the spare area on a larger flop/latch memory (128 words).

## Then (in plan order)

| weeks | item |
|-------|------|
| 2–3 | **FSM compiler**: Verilog FSM → `yosys fsm_extract` → records; SBY/EQY equivalence proof between the image and the source FSM |
| 3–4 | more programs: SPI target, I²C target (address match via `match`), JTAG, SWD, PS/2, WS2812 |
| 4–6 | **learning-as-a-feature**: auto-baud (measure 0x55 into TA; mostly a program, plus a small "timer capture" action), a capture/logic-analyser program, host-side Mealy inference (RPNI), and an I²C impersonation demo |
| 6–7 | stretch assists using the spare area: programmable CRC/LFSR, NRZI and bit-stuffing, Manchester encoding, a full-rate serializer for 10BASE-T; USB-LS. 8 lanes if timing allows |
| 8 | write-up, AI-use disclosure, demo video. Submit with a 3-day buffer |

## Known limitations of v1

* Host memory writes while lanes run use spare slots. A lane that changes state on every tick
  can delay host access (the SPI shell expects access within half an SCK period).
* SR, FIFOs and the counter are 8 bits wide. 9-bit or longer frames need extra states.
* 10BASE-T needs 50 ns events. Run the chip at 40 MHz with 2 lanes, or wait for the planned
  serializer assist.
