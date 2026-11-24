## How it works

SETL is a reprogrammable protocol emulator. Instead of a CPU, four **lanes** each step
through a *state graph* held in on-chip memory. One 64-bit word is one state. It says
what to do on entry (drive or release pins, shift a bit in or out, push or pop a byte,
load a timer or counter) and what to wait for (timer, pin level or edge, FIFO state,
counter zero, a shift-register match, CRC check). It also gives the two possible next
states. A UART transmitter is 4 words, an SPI controller 6 words, and an I²C controller
with clock stretching about 40 words. Example programs: UART (including auto-baud), SPI
controller and target, I²C controller, target and sniffer, JTAG, SWD, PS/2, WS2812,
Manchester, MODBUS RTU with on-chip CRC, CAN 2.0A TX, and USB low-speed TX/RX with
clock recovery (the larger ones need the SRAM build).

Each lane also has a programmable CRC/LFSR (any polynomial up to 16 bits), a
bit-stuffing run counter and a stopwatch, so line coding, CRCs and baud-rate learning
happen on chip.

The lanes share the memory as a 2-way or 4-way barrel. Each lane gets its own clock slot,
so every lane can change state on every one of its ticks, with no stalls. Timing is
exact and independent of what the other lanes do. Outputs go through a per-lane pin
map with push-pull, open-drain and invert options.

Full details: `docs/ARCHITECTURE.md`. The assembler is `tools/setl/asm.py` and the example
programs are in `programs/`.

## How to test

Connect an SPI host (the RP2350 on the demo board) to ui7 (SCK), ui6 (MOSI), ui5 (CS_n)
and uo7 (MISO). SPI mode 0, SCK at most clk/16.

1. Read register 0x82 and check that it returns 0x5E.
2. Assemble a program: `python -m setl.asm programs/uart_tx.setl -o uart.json`.
3. Using `tools/setl/host.py`: `load_image`, `config_lane(0, start, ta=clk/(2*baud)-1, outmap=['uo0'])`,
   `run(1)`, then `push(0, b"hello")`. uo0 now outputs UART at the chosen baud rate.

## External hardware

Pull-up resistors on the uio pins used for I²C (open-drain) and any target devices.
No other hardware is required.
