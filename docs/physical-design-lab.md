# Physical design and tapeout lab

This lab is intentionally written as a sequence of experiments rather than an
automated tapeout recipe. Run every stage yourself, inspect its reports, and
record what changed before moving on. The repository's RTL and firmware tests
are the handoff into this process; a passing RTL regression is not physical
sign-off.

Useful upstream references:

- [Tiny Tapeout local hardening guide](https://tinytapeout.com/guides/local-hardening/)
- [LibreLane newcomers' tutorial](https://librelane.readthedocs.io/en/latest/getting_started/newcomers/)
- [LibreLane timing-closure guide](https://librelane.readthedocs.io/en/latest/usage/timing_closure/)
- [Tiny Tapeout submission guide](https://tinytapeout.com/guides/advanced-workshop/submit-your-design/)

Always prefer the versions pinned by the current Tiny Tapeout IHP action over
version numbers copied from an old tutorial.

## 0. Freeze the RTL handoff

Run:

```sh
make all
cd test
make -B
```

Before physical work, require all of the following:

- every self-checking simulation prints `PASS`;
- Verilator reports no unwaived RTL warnings;
- Yosys finishes with no check errors, inferred latches, or undriven nets;
- UART, SPI, and I2C firmware waveforms match their protocol timing;
- the Tiny Tapeout wrapper test passes through the real serial loading path.

Write down the Git commit hash. Do not compare physical runs made from
different RTL without noting the change.

## 1. Learn what the flow produces

Trace this transformation before changing any knobs:

```text
SystemVerilog RTL
  -> synthesized standard-cell netlist
  -> floorplan and power grid
  -> placed cells
  -> clock tree
  -> routed interconnect
  -> extracted parasitics
  -> post-route timing and physical verification
  -> GDSII
```

For each arrow, locate the corresponding run directory, log, report, and
design view. LibreLane's `final` directory normally contains GDS, LEF, DEF,
netlists, SDC, SDF, SPEF, timing libraries, and `metrics.json`/`metrics.csv`.

## 2. Install the reproducible IHP environment

Use Linux, Docker, and the current Tiny Tapeout local-hardening guide. For the
IHP flow, the local guide uses the `ihp-sg13g2` PDK environment and requires
the `--ihp` option to `tt_tool.py`. This repository's hosted action selects the
Tiny Tapeout CMOS5L flow with `tt-gds-action@ihp-cmos5l` and
`pdk: ihp-sg13cmos5l`; these names refer to different integration layers and
should not be substituted for one another.

Record:

- OS and Docker versions;
- LibreLane version;
- PDK identifier and revision;
- Tiny Tapeout tools commit;
- project commit.

That record makes every layout result reproducible.

## 3. Make a baseline hardening run

Follow the upstream setup, then from the Tiny Tapeout factory-test workspace
generate the user configuration and run the IHP hardening command described by
the guide. Do not tune `src/config.json` before this baseline succeeds.

After the run:

1. Run `tt_tool.py --print-warnings` with the IHP option.
2. Save `metrics.json` and the run log.
3. Open the placed and routed databases in OpenROAD.
4. Open the final GDS and DRC markers in KLayout.
5. Locate the synthesized netlist and compare its cell count with Yosys.

## 4. Read the floorplan

In the GUI, identify:

- core boundary and die boundary;
- standard-cell rows;
- input/output pins;
- power rails and straps;
- clock source;
- dense or empty regions;
- any cells outside rows or unexpected blockages.

For this project, pay particular attention to the 32-by-16 instruction memory.
It is currently synthesized from RTL registers rather than instantiated as an
SRAM macro, so it may occupy a substantial fraction of the standard-cell area.

Exit criterion: the design fits its allocated 6x4 tiles without illegal
geometry, obviously disconnected regions, or unreasonably high utilization.

## 5. Inspect placement and congestion

Record these metrics:

| Metric | Baseline | Next run | Why it matters |
| --- | ---: | ---: | --- |
| Core utilization | | | Placement and routing headroom |
| Standard-cell area | | | Logic cost |
| Worst congestion overflow | | | Routability |
| Total wire length | | | Delay and dynamic power proxy |
| Buffer count | | | Timing fixes and clock load |

If placement or routing fails, change one variable at a time. Start with
placement density/utilization and tile size. Do not hide congestion merely by
enabling a permissive option; understand where the hot spot comes from.

## 6. Inspect the clock tree

Find the CTS reports and record:

- clock insertion delay;
- worst clock skew;
- number and type of inserted clock buffers;
- minimum and maximum clock path depth;
- whether every sequential element is reached by the clock tree.

The project declares a 20 ns clock period (50 MHz). Verify that the physical
flow sees `clk` as the clock and that no generated or unconstrained clock is
silently present.

## 7. Close timing

Check both setup and hold at the final post-route stage, not only before
placement. Read the worst path report from startpoint to endpoint and identify
whether its delay is dominated by cells, routing, fanout, or clock skew.

Record:

| Check | Requirement |
| --- | --- |
| Worst setup slack | Nonnegative in every required corner |
| Worst hold slack | Nonnegative in every required corner |
| Unconstrained endpoints | Zero |
| Clock definition | 20 ns on `clk` |
| Timing exceptions | Only deliberate, reviewed exceptions |

If timing fails, first understand the path. Possible experiments include a
lower placement density, logic restructuring, reduced fanout, or a relaxed
clock target. Never declare closure from a pre-route report.

## 8. Complete physical sign-off

Require clean results for:

- DRC: geometry follows foundry manufacturing rules;
- LVS: extracted layout connectivity matches the intended netlist;
- antenna checks: long fabrication-time metal paths are safe;
- post-route STA: setup and hold pass with extracted parasitics;
- Tiny Tapeout precheck: wrapper, dimensions, ports, and integration rules;
- gate-level simulation: the post-synthesis/post-route representation still
  executes the serial loader and protocol program correctly.

Review the actual reports even if the top-level command exits successfully.
Zero unexplained violations is the sign-off standard.

## 9. Inspect the final layout

In KLayout, visually follow at least one path through each of these structures:

- reset and run control;
- serial loader shift register into instruction memory;
- program counter and instruction decode;
- GPIO output and output-enable paths;
- classifier datapath;
- clock tree and power distribution.

Visual inspection does not replace DRC/LVS, but it teaches how the RTL became
physical geometry and often reveals surprising placement or routing choices.

## 10. Submit only a frozen, reproducible result

Before submission, make a release checklist containing:

- frozen Git commit;
- passing RTL, gate-level, lint, and synthesis logs;
- final GDS artifact;
- clean DRC, LVS, antenna, STA, and precheck results;
- `metrics.json` and timing reports;
- screenshots of floorplan, placement, CTS, routing, and final GDS;
- exact tool and PDK versions;
- a pin-level bring-up test plan for manufactured silicon.

Then follow the current Tiny Tapeout submission guide yourself. A green action
is evidence, not a substitute for reading the reports and understanding every
waiver or configuration choice.

## Suggested lab notebook

For every run, add one row:

| Run | Commit | Single change | Area | Utilization | Setup WNS | Hold WNS | DRC | LVS | Result |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- | --- |
| baseline | | none | | | | | | | |

Changing one variable per run turns physical design from knob-twiddling into
an experiment you can explain in an interview or design review.
