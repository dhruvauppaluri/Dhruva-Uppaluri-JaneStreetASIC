# Programmable Protocol Emulator

## How it works

This project is a compact processor designed to express digital hardware
protocols as firmware instead of fixed UART, SPI, or I2C peripherals. Its
256-word program memory is serially loadable after fabrication. Sixteen
instructions provide bidirectional pin control, deterministic waits, input
sampling, register operations, shifts, conditional branches, pin-level waits,
and halt. A memory-mapped assist adds a programmable bit tick, NRZI pair
driver, bit stuffing, USB CRC-16, and a small FIFO without introducing
USB-named opcodes. A tiny programmable linear classifier also measures edge
and duty cycle features on two input pins and makes its result available to
firmware.

The same silicon can therefore run different protocol programs. Included
examples generate a UART frame, an SPI mode-0 transaction, an open-drain I2C
START/STOP sequence, USB low-speed packet fragments, and an ENC28J60-class
SPI frame write. 10 Mbit/s Ethernet on the cable is the external PHY; the
ASIC is the programmable SPI master.

## How to test

Assert and release reset first, then hold `ui_in[3]` low. Shift each 16-bit
instruction MSB-first on `ui_in[0]`, pulsing `ui_in[1]` for each bit, then
pulse `ui_in[2]` to commit the word. Addresses advance automatically. After
loading the program and optional classifier or assist configuration, set
`ui_in[3]` high to run. Do not reset after loading classifier or assist
state because reset clears that configuration to its safe zero state.

The eight `uio` pins are the emulated protocol pins. Stretch-goal convention:
USB D+/D− on `uio[0:1]`, Ethernet SPI on `uio[2:5]`, RST/INT on `uio[6:7]`.
`uo_out[4:0]` shows `PC[4:0]` (set `ui_in[7]` while running to view
`PC[7:5]`); `uo_out[5]` indicates halt, `uo_out[6]` indicates an active
timed wait, and `uo_out[7]` reports the protocol classifier result.

## External hardware

I2C needs pull-ups on SDA/SCL. USB low-speed needs a 1.5 kΩ pull-up on D−
and, for a real cable, a 3.3 V-safe front-end. 10 Mbit Ethernet needs an
ENC28J60-class SPI MAC/PHY plus magnetics. See
[docs/dut-integration.md](dut-integration.md).
