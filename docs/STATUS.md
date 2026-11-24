# Status and plan (deadline 2027-01-18)

## Done

| area | state |
|---|---|
| Architecture | 64-bit state records; 4 lanes on a deterministic 2/4-way barrel; registered-read memory contract matching the IHP macro; pin router with open-drain and invert; stopwatch; CRC/LFSR and ones-run assist |
| Executable spec | `tools/setl/model.py`, cycle-accurate |
| Toolchain | assembler (images, `$readmemh`, Verilog ROMs), host driver, learning and impersonation (`learn.py`), JTAG helper |
| Programs | UART TX/RX and auto-baud RX; SPI controller (modes 0–3) and target; I²C controller, target, sniffer and host-served target; JTAG; SWD; PS/2; WS2812; MODBUS RTU TX/RX with on-chip CRC; USB low-speed TX and RX with clock recovery, CAN 2.0A TX (generated) |
| Directed tests | 19 (RTL, 512-word memory) / 15 + 4 skips on the 64-word fallback memory, all with the golden model in lockstep; the IHP SRAM macro models are also simulated |
| Random co-sim | 16 seeds, about 850k clocks, zero mismatches |
| Formal | unbounded proof that the barrel never stalls a lane (whole chip, any program, any host traffic); bounded proofs of the UART / SPI / I²C programs on the lane RTL; reachability checks for each; also in CI |
| Lint | Verilator `-Wall` clean |

## Physical design

Two builds exist. `main` holds the SRAM build, which is the submission:

| branch | memory | config |
|---|---|---|
| `main` (= `setl-sram`) | two IHP 512×32 SRAM macros | `SETL_IHP_SRAM`, macro placement and PDN on the SRAM column grid, and Ken Pettit's Apache-2.0 `ExtendPowerStripes` step (`librelane_plugin_setl_pdn.py`) |
| `setl-rewrite` | 64-word flip-flop fallback (stock flow) | backup only |

Issues found and fixed in CI so far:
* ABC used an I/O pad cell (`sg13cmos5l_IOPadOut16mA`) as a buffer, and global placement
  could not place it (GRT-0010). Fixed with `EXTRA_EXCLUDED_CELLS`.
* The SRAM build's lint step could not see the macro (MODMISSING). Fixed with a `vh`
  blackbox view.
* SRAM build, first full run: placement, routing and **LVS completed clean**, which
  verifies the SRAM power hookup through `ExtendPowerStripes`. Two things failed: Magic
  DRC (230k errors, from the SRAM macro's internals) and 8 setup endpoints at the slow
  corner (1.08 V, 125 °C) at 50 MHz. Fixed as in Pettit's flow: KLayout DRC with the
  CMOS5L deck instead of Magic, post-global-route timing repair with a 0.25 ns margin,
  and a 22 ns clock (45 MHz, which gives exactly 15 ticks per USB low-speed bit).
* SRAM build, second run: LVS clean again and Magic DRC gone. It still failed on 17
  routing DRC errors, 73 KLayout DRC errors and slow-corner setup. Third attempt:
  placement density 45% (the SRAM build is only about 9k cells), a 30 ns clock for a first
  clean sign-off, and DRC left to the Tiny Tapeout precheck as the stock template does.
  The precheck log names each DRC rule, which LibreLane's table did not.

* SRAM build, third run (45416354844): **green**. GDS complete, with routing DRC, LVS
  and setup/hold at every corner clean (30 ns clock, 24.7 % utilisation). The Tiny
  Tapeout precheck passed, and gate-level simulation of the routed netlist with the
  IHP SRAM macros passed 15/15 directed tests. (The other 4 were skipped by a test
  setting that is now fixed, so the next run covers all 19.)
* The only red job is `viewer`, which publishes the 3D preview to GitHub Pages. Pages
  is not enabled on the repository (Settings → Pages → Source: GitHub Actions). It is
  not part of the submission.

**Decision (rule from the plan): the SRAM build is the submission and lives on `main`.**
The 64-word fallback stays on `setl-rewrite` as a backup. Its 8×4 flip-flop build ran for
more than five hours in CI and was stopped once the SRAM build was green.

## Next

1. Tighten the clock again (30 ns now; 48–60 MHz is needed for exact USB low-speed
   rates), now that routing is clean at 45 % density.
3. USB: test the receiver against a USB LS decoder-driven stimulus with jitter and frequency offset.
4. Coverage-directed random program generation, and unbounded (inductive) formal proofs.
5. Bring-up on the demo board: `tools/setl/rp2350.py` (MicroPython transport) is written
   but not yet run on hardware.

## Known limitations

* The FIFOs are 4 deep. Fast protocols need a responsive host, as the MODBUS test shows.
* The shift register, FIFOs and counter are 8 bits wide.
* Host memory writes while lanes run use spare slots only.
* 10BASE-T needs 50 ns events: 40 MHz with 2 lanes, or a serializer.
