# Hardware bring-up plan

This is the plan for the first physical tests: on an FPGA before silicon, then on the
chip. Every step prints JSON lines, so the logs go straight into the test report.
Nothing here has run on hardware yet.

## What you need

| item | why | notes |
|---|---|---|
| RP2350 board (Tiny Tapeout demo board, or a Pico 2 wired to an FPGA) | host: loads programs, runs the tests | MicroPython |
| FPGA board (pre-silicon only) | runs the RTL with `SETL_SIM_FULLMEM` | about 10k LUTs + 4 KB RAM; port pending the board choice |
| an I²C device on a breakout | learn-and-impersonate | 24Cxx EEPROM (cleanest), DS3231 RTC, or BME280; 3.3 V |
| 2 × 4.7 kΩ resistors | I²C pull-ups | only if the breakout has none |
| USB logic analyzer (8 ch, 24 MHz, sigrok/PulseView) | waveforms for the report | strongly recommended |
| jumper wires | | |

## Pins

| SETL pin | use in these tests |
|---|---|
| ui7 / ui6 / ui5 / uo7 | host SPI: SCK / MOSI / CS_n / MISO (to RP2350 GPIOs; fill in `examples/board.py`) |
| uo1 | self-test UART (internal loopback, probe it with the analyzer) |
| uio0 / uio1 | I²C SCL / SDA (device + RP2350 SoftI2C on the same two lines) |

## Steps

**0. Prepare (PC).** `make -C programs`. Copy `tools/setl/`, `programs/build/*.json`
and `examples/*.py` to the board. Set the GPIO numbers and `CLK_HZ` in `board.py`.
Dry-run the scripts first: `PYTHONPATH=tools python3 examples/selftest.py --model`.

**1. Alive.** `import selftest; selftest.main()` runs these checks:

| test | pass criterion |
|---|---|
| `id` | ID 0x5E, version 0x01 |
| `regs` | lane registers read back as written |
| `mem` | all 512 words, two patterns, zero errors, HOSTERR = 0 |
| `fifo` | 16 queued bytes show TX level 16, and drain to 0 |
| `uart` | lane 0 → lane 1 on-chip loopback at 9600, 115200 and 1 M baud, all bytes, no framing errors |

Capture uo1 with the analyzer during the `uart` test. That's the first waveform for
the report.

**2. External protocols.** These need one device each: `uart_hello.py` (USB-serial
adapter on uo0), `i2c_scan.py` (the I²C device), `spi_flash_id.py` (any SPI flash).
Capture each one.

**3. Learn and impersonate.** `import learn_demo; learn_demo.main()`. Probe uio0/uio1
for the whole run, and press Enter after unplugging the device. Pass: every
non-volatile register read in the training and held-out sessions matches the real
device. `peak_rx_level` and `overflow` show how close the capture came to the FIFO
limit.

**4. Stress (optional).** Repeat step 3 at `FREQ = 400_000`, and run `selftest` in a
loop for 10 minutes. Record clock frequency and board temperature.

## What to send back for the report

* the JSON-line logs from each script, copied from the REPL;
* analyzer captures as `.sr` files (not screenshots), named after the step;
* photos of the setup;
* part numbers: RP2350 board, FPGA board, I²C device, clock frequency used.

## Known risks

* **Host link speed.** The bit-banged SPI is slow in MicroPython. Step 3 needs the
  capture drained at least every 8 bus events (about 700 µs at 100 kHz). The log reports
  `peak_rx_level`. If it overflows, use the RP2350's hardware SPI on those pins, or
  lower `FREQ`.
* **Volatile registers.** Clocks and live sensor readings change between reads.
  The training session reads everything twice, and registers that changed are
  reported as volatile and excluded from the comparison.
* **Pull-ups.** I²C does not work without them. A scan that finds nothing usually
  means the pull-ups are missing.
