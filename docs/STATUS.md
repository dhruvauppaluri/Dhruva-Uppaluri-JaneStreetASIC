# Status and plan (deadline 2027-01-18)

## Done

| area | state |
|---|---|
| Architecture | 64-bit state records; 4 lanes on a deterministic 2/4-way barrel; registered-read memory contract matching the IHP macro; pin router with open-drain and invert; stopwatch; CRC/LFSR and ones-run assist |
| Executable spec | `tools/setl/model.py`, cycle-accurate |
| Toolchain | assembler (images, `$readmemh`, Verilog ROMs), host driver, learning and impersonation (`learn.py`), JTAG helper |
| Programs | UART TX/RX and auto-baud RX; SPI controller (modes 0–3) and target; I²C controller, target, sniffer and host-served target; JTAG; SWD; PS/2; WS2812; MODBUS RTU TX/RX with on-chip CRC; USB low-speed TX and RX with clock recovery, CAN 2.0A TX (generated) |
| Directed tests | 23 (RTL, 512-word memory) / 18 + 5 skips on the 64-word fallback memory, all with the golden model in lockstep; the IHP SRAM macro models are also simulated |
| Random co-sim | 16 seeds, about 850k clocks, zero mismatches |
| Formal | unbounded proof that the barrel never stalls a lane (whole chip, any program, any host traffic); bounded proofs of the UART / SPI / I²C programs on the lane RTL; reachability checks for each; also in CI |
| Lint | Verilator `-Wall` clean |

## Review fixes (after the first green build)

| issue raised | fix | evidence |
|---|---|---|
| a program write into a running chip could be lost silently | lost writes and late reads set HOSTERR (0x86); `load_image()` raises `HostError` | `test_host_write_while_lanes_busy`, `test_host_single_byte_while_lanes_busy` |
| the I²C capture depended on phase and on a fast host | FIFOs 4 → 16 deep, with full level registers (0xC0+2L); an SCL/SDA sampling race fixed in the I²C programs | `test_learn_and_impersonate` sweep |
| impersonation was only checked on its training traffic | held-out session from a second, independently timed controller, against answers recorded from the real sensor | [DEMO.md](DEMO.md) |
| the SPI target could not share MISO | tri-state OMAP mode (bit 7: the next slot is the enable) | `test_spi_target_shared_bus` |
| the USB rate claim | the build now signs off at 48 MHz, where 16-tick bits are exactly 1.5 Mb/s (`test_usb_ls_48mhz`) | [WRITEUP.md](WRITEUP.md) |

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
* SRAM build, fourth run (45427245051), with every test enabled at gate level: GDS,
  precheck and **gate-level simulation 19/19 pass** on the routed netlist with the IHP SRAM
  macros, including USB low-speed TX/RX, CAN, and I²C controller and target on one chip.
* The only red job is `viewer`, which publishes the 3D preview to GitHub Pages. Pages
  is not enabled on the repository (Settings → Pages → Source: GitHub Actions). It is
  not part of the submission.

* Review-fix run (45506165051): the 16-deep FIFOs added about 1,000 flip-flops, and
  global routing reported congestion. Setup then failed at 30 endpoints at the slow
  corner, even at 30 ns. Fixed by merging the timing work from `setl-fast` (registered
  output readback, fetch on every state exit, a fast branch-condition network checked
  against the original by formal assertions). That work closed 48 MHz on the smaller
  design.

* 48 MHz with every feature: the first attempt also failed on output-pad paths (flop →
  pin router → `uio_oe`, −1.49 ns), and on routing shorts at density 45 %. Fixes: every
  lane output is registered before its pad, and placement density is 38 %. Run 45529281508:
  GDS, LVS, precheck, timing at every corner (slow +1.21 ns) and **gate-level simulation
  22/22**. One later 30 ns run left 9 shorts on a net crowded against an SRAM pin edge,
  so the macro halos are now 4 µm horizontal and 3 µm vertical.
* **Submission build, run 45542613961** (48 MHz, wider halos, `test_usb_ls_48mhz`): GDS,
  LVS, precheck, no setup or hold violations at any corner (slow +1.02 ns, typical
  +8.36 ns), **gate-level simulation 23/23**. The same design at 30 ns (branch
  `setl-regpins`, 33 MHz) is fully green too, with +11.0 ns of slow-corner slack: the fallback.

**Decision: the 48 MHz SRAM build is the submission and lives on `main`.**
The 64-word fallback stays on `setl-rewrite` as a backup. Its 8×4 flip-flop build ran for
more than five hours in CI and was stopped once the SRAM build was green.

## Next

1. 60 MHz: not planned. 48 MHz already gives exact USB low-speed timing.
2. USB: test the receiver against a USB LS decoder-driven stimulus with jitter and frequency offset.
3. Coverage-directed random program generation, and unbounded (inductive) formal proofs.
4. Bring-up: FPGA + RP2350 first (`docs/BRINGUP.md`, `examples/selftest.py`,
   `examples/learn_demo.py`), then the demo board once silicon exists.

## Known limitations

* The FIFOs are 16 deep (8 captured I²C bytes between host services).
* The shift register, FIFOs and counter are 8 bits wide.
* Host memory writes while lanes run use free clocks only. A write that finds none is
  reported (HOSTERR, `HostError`), never lost silently.
* 48 MHz sign-off has +1.02 ns of slow-corner setup margin; silicon must confirm it.
* 10BASE-T needs 50 ns events: 40 MHz with 2 lanes, or a serializer.
