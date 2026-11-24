# Bring-up examples

Each script runs on the demo board's RP2350 (MicroPython) or on a PC with an SPI
bridge. Each one uses the same `setl.host.Setl` driver as the test benches.

1. Build the images on a PC: `make -C programs`.
2. Copy `tools/setl/` (the package), `programs/build/*.json` and an example to the
   board.
3. Fill in the four GPIO numbers in `board.py`. These are the RP2350 pins wired to the
   project's ui[7] (SCK), ui[6] (MOSI), ui[5] (CS_n) and uo[7] (MISO); take them from the
   demo board documentation.
4. Select the design and clock it (any frequency at least 16× the bit-banged SCK).

| script | what it does |
|---|---|
| `uart_hello.py` | UART TX on uo0 at 115200 baud: prints "hello from SETL" |
| `i2c_scan.py` | I²C controller on uio0 (SCL) / uio1 (SDA): lists responding addresses |
| `spi_flash_id.py` | SPI controller mode 0 on uo2-4 / ui1: reads a flash JEDEC ID (0x9F) |

The design loses its program whenever it is deselected, so each script loads its
program first.

These scripts have not been run on hardware yet (no silicon exists). They use only
driver calls that the simulation tests exercise.
