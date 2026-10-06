# Protocol processor instruction set

The processor uses 16-bit instructions. Bits `[15:12]` hold the opcode and
bits `[11:0]` hold its operand. It has four 8-bit registers (`R0` through
`R3`), eight bidirectional protocol pins, a 12-bit wait counter, and a
256-instruction program memory (`PROGRAM_WORDS = 256`). The program counter
is eight bits wide. Jump targets must land in `0 .. PROGRAM_WORDS-1`.
`JZ`/`JNZ` encode the address in eight bits, so they also cover the full
256-word space. `JMP` uses the low bits of the 12-bit operand, validated
against the same depth by the assembler.

Instruction memory is an inferrable SRAM-style array with clocked writes and
combinational reads, so fetch remains single-cycle and `WAIT` timing is
unchanged. Serial load semantics are unchanged: sixteen bits MSB-first, then
a commit pulse, while `ui_in[3]` is low.

| Opcode | Assembly | Operation |
| --- | --- | --- |
| `0` | `NOP` | Advance without changing state |
| `1` | `OUT value` / `OUT Rn` | Write an immediate or register to the output latch |
| `2` | `DIR mask` | Set output enables; `1` drives and `0` releases a pin |
| `3` | `WAIT cycles` | Insert the requested number of idle enabled clocks |
| `4` | `IN Rn` | Sample all eight protocol pins into a register |
| `5` | `LDI Rn, value` | Load an 8-bit immediate |
| `6` | `ANDI Rn, value` | Register AND immediate |
| `7` | `XORI Rn, value` | Register XOR immediate |
| `8` | `ADDI Rn, value` | Register addition modulo 256 |
| `9` | `SHL Rn` | Shift register left by one |
| `A` | `SHR Rn` | Shift register right by one |
| `B` | `JMP address` | Unconditional jump |
| `C` | `JZ Rn, address` | Jump when the register is zero |
| `D` | `JNZ Rn, address` | Jump when the register is nonzero |
| `E` | `WAIT_PIN pin, level` | Wait until an input pin has the selected level |
| `F` | `HALT` | Stop until reset |

`WAIT 0` advances without stalling. `WAIT N` inserts `N` idle processor clocks
after the `WAIT` instruction. Therefore, two `OUT` instructions separated by
`WAIT N` occur `N + 2` clocks apart.

## Assist MMIO (reserved OUT / IN encodings)

The same `OUT`/`IN` opcodes decode a reserved operand space that talks to a
general-purpose serial engine (bit tick, 1- or 2-bit shifter, NRZI+stuff or
NRZ, CRC-16 or CRC-32, 64-byte packet RAM, TX and RX, pin overlay). These are
**not** USB- or Ethernet-named opcodes.

| Assembly | Encoding | Meaning |
| --- | --- | --- |
| `AOUT port, imm` | `OUT` with operand `[11:10]=01`, port in `[9:8]` | Write immediate to engine port 0..3 |
| `AOUT port, Rn` | `OUT` with operand `[11:10]=11`, register in `[9:8]`, port in `[7:6]` | Write register to engine port |
| `AIN Rn, port` | `IN` with operand `[11:10]=01`, port in `[1:0]` | Read engine port into a register |

Ports:

| Port | Write | Read |
| --- | --- | --- |
| 0 | Control (TX/RX start, reset, stuff/NRZI/SE0/overlay) | Status (busy, RAM, SE0, RX ready, CRC ok) |
| 1 | Bit-tick period in clocks (USB LS uses 33; RMII-10 uses 10) | CRC high byte (wire value) |
| 2 | Push packet RAM | Pop RX byte (`AIN` advances the read index) |
| 3 | Feed CRC, or MODE if `data[7:6]==11` | CRC low byte (wire value) |

Control bits: `[0]` TX start, `[1]` soft reset, `[2]` stuff, `[3]` NRZI,
`[4]` CRC reset, `[5]` RX start, `[6]` force SE0, `[7]` overlay. MODE
`0xC0|flags`: `[0]` width-2, `[1]` CRC-32, `[2]` RMII, `[3]` append CRC,
`[4]` auto EOP, `[5]` preamble/SFD.

Status bit 3 is SE0: both USB pins are low on `gpio_in`. Firmware can poll
that instead of a dedicated `WAIT_SE0` opcode. The engine keeps ticking while
the CPU is in `WAIT` or `HALT` as long as run-mode `enable` is high.

USB LS firmware programs period 33, width 1, NRZI+stuff, CRC-16. Ethernet
firmware programs period 10, width 2, NRZ, CRC-32, RMII overlay on
`uio[2:7]`. UART/SPI/I2C firmware does not have to use the engine.

## Programming interface

The Tiny Tapeout wrapper loads one word at a time:

1. Hold `ui_in[3]` low to pause execution and enable loading.
2. Present each instruction bit on `ui_in[0]`, most-significant bit first.
3. Pulse `ui_in[1]` for one rising clock per bit.
4. After sixteen bits, pulse `ui_in[2]` for one clock to commit the word.
5. Repeat for sequential addresses starting at zero.
6. Set `ui_in[3]` high to execute from address zero after reset.

The loader address returns to zero on reset. Reset does not erase instruction
memory, allowing a loaded program to be restarted.

`ui_in[7]` while loading selects the serial-engine MMIO as the write target (the
same extra-target pattern as the classifier on `ui_in[4]`). While running,
`ui_in[7]` muxes `PC[7:5]` onto `uo_out[2:0]` (`uo_out[4:3]` stay zero in
that view). By default `uo_out[4:0]` still shows `PC[4:0]`, so programs
shorter than 32 words look unchanged; high PC bits are truncated unless
`ui_in[7]` is set.

## Classifier configuration

Pulse `ui_in[5]` while loading to restart the loader address, then hold
`ui_in[4]` high and commit five configuration words:

| Address | Value |
| --- | --- |
| 0 | Signed INT8 weight for pin-0 transition count |
| 1 | Signed INT8 weight for pin-0 high-cycle count |
| 2 | Signed INT8 weight for pin-1 transition count |
| 3 | Signed INT8 weight for pin-1 high-cycle count |
| 4 | Signed 16-bit bias |

Every 32 running clocks, the classifier evaluates
`bias + sum(feature[i] * weight[i])`. A nonnegative score produces class one;
a negative score produces class zero. The result appears on `uo_out[7]`.
Setting `ui_in[6]` routes the same result into processor input bit 7 so firmware
can sample, mask, and branch on the classification.
