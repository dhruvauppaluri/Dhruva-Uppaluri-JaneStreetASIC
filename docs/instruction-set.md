# Protocol processor instruction set

The processor uses 16-bit instructions. Bits `[15:12]` hold the opcode and
bits `[11:0]` hold its operand. It has four 8-bit registers (`R0` through
`R3`), eight bidirectional protocol pins, a 12-bit wait counter, and a
32-instruction program memory.

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
