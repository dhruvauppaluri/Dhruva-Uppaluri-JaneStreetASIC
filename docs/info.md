# Programmable Protocol Emulator

## How it works

This project is a compact processor designed to express digital hardware
protocols as firmware instead of fixed UART, SPI, or I2C peripherals. Its
32-word program memory is serially loadable after fabrication. Sixteen
instructions provide bidirectional pin control, deterministic waits, input
sampling, register operations, shifts, conditional branches, pin-level waits,
and halt. A tiny programmable linear classifier also measures edge and duty
cycle features on two input pins and makes its result available to firmware.

The same silicon can therefore run different protocol programs. Included
examples generate a UART frame, an SPI mode-0 transaction, and an open-drain
I2C START/STOP sequence.

## How to test

Assert and release reset first, then hold `ui_in[3]` low. Shift each 16-bit
instruction MSB-first on `ui_in[0]`, pulsing `ui_in[1]` for each bit, then
pulse `ui_in[2]` to commit the word. Addresses advance automatically. After
loading the program and optional classifier configuration, set `ui_in[3]` high
to run. Do not reset after loading classifier weights because reset clears
that configuration to its safe zero state.

The eight `uio` pins are the emulated protocol pins. `uo_out[4:0]` shows the
program counter; `uo_out[5]` indicates halt, `uo_out[6]` indicates an active
timed wait, and `uo_out[7]` reports the protocol classifier result.

## External hardware

No external hardware is required beyond suitable pull-up resistors when using
open-drain protocols such as I2C.
