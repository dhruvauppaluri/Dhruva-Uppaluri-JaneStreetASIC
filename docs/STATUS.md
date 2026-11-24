# Status and plan (deadline 2027-01-18)

## Done

| area | state |
|---|---|
| Architecture | 64-bit state records; 4 lanes on a deterministic 2/4-way barrel; registered-read memory contract matching the IHP macro; pin router with open-drain and invert; stopwatch; CRC/LFSR and ones-run assist |
| Executable spec | `tools/setl/model.py`, cycle-accurate |
| Toolchain | assembler (images, `$readmemh`, Verilog ROMs), host driver, learning and impersonation (`learn.py`), JTAG helper |
| Programs | UART TX/RX and auto-baud RX; SPI controller (modes 0–3) and target; I²C controller, target, sniffer and host-served target; JTAG; PS/2; WS2812; MODBUS RTU TX/RX with on-chip CRC; USB low-speed TX and RX with clock recovery (generated) |
| Directed tests | 17 (RTL, 512-word memory) / 13 + 3 skips on the 64-word fallback memory, all with the golden model in lockstep; the IHP SRAM macro models are also simulated |
| Random co-sim | 16 seeds, about 850k clocks, zero mismatches |
| Formal | bounded proofs of the UART / SPI / I²C programs on the lane RTL plus reachability checks; also in CI |
| Lint | Verilator `-Wall` clean |

## Physical design

Two builds are hardened by the Tiny Tapeout GitHub action:

| branch | memory | config |
|---|---|---|
| `setl-rewrite` | 64-word flip-flop fallback (stock flow) | `src/config.json`, 50 MHz |
| `setl-sram` | two IHP 512×32 SRAM macros | adds `SETL_IHP_SRAM`, macro placement and PDN on the SRAM column grid, and Ken Pettit's Apache-2.0 `ExtendPowerStripes` step (`librelane_plugin_setl_pdn.py`) |

Issues found and fixed in CI so far:
* ABC used an I/O pad cell (`sg13cmos5l_IOPadOut16mA`) as a buffer, and global placement
  could not place it (GRT-0010). Fixed with `EXTRA_EXCLUDED_CELLS`.
* The SRAM build's lint step could not see the macro (MODMISSING). Fixed with a `vh`
  blackbox view.

Check the GitHub Actions page for the current GDS / precheck / gate-level results of
each branch.

Decision rule from the plan: submit `setl-sram` if it is green. Otherwise submit the
fallback, and spend its spare area on more memory words.

## Next

1. Get both GDS builds green; record area, timing (slack at 50 MHz) and precheck.
2. Run gate-level simulation of the directed tests (the GL job in the GDS workflow).
3. USB: test the receiver against a USB LS decoder-driven stimulus with jitter and frequency offset.
4. Coverage-directed random program generation, and unbounded (inductive) formal proofs.
5. Bring-up on the demo board: `tools/setl/rp2350.py` (MicroPython transport) is written
   but not yet run on hardware.

## Known limitations

* The FIFOs are 4 deep. Fast protocols need a responsive host, as the MODBUS test shows.
* The shift register, FIFOs and counter are 8 bits wide.
* Host memory writes while lanes run use spare slots only.
* 10BASE-T needs 50 ns events: 40 MHz with 2 lanes, or a serializer.
