# SETL architecture and instruction set

SETL (*Sparse Event-Transition Lanes*) is a protocol emulator for the Jane Street /
Tiny Tapeout competition. It does not run instructions. Each SRAM word is one **state
record**: what to do when you enter a state, what to wait for, and where to go next. A
protocol is a small state graph. Changing the protocol means loading a different graph.

The executable specification is `tools/setl/model.py`. This document describes it, and
the RTL is checked against it every cycle (see `VERIFICATION.md`).

## Block diagram

```
            host SPI (ui7 SCK, ui6 MOSI, ui5 CS_n, uo7 MISO)
                 │  registers, FIFOs, program memory
                 ▼
   ┌──────────────────────────────┐     one access per clock
   │ record memory 512 x 64       │◄────────────────────────┐
   │ (2 x IHP 512x32 SRAM macro)  │                         │
   └──────────────┬───────────────┘                         │
                  │ registered read data                    │ fetch (on state change only)
   ┌──────────────▼──────────────────────────────────────────┴─────┐
   │ barrel: slot counter gives each lane every 2nd (or 4th) clock │
   │  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐                  │
   │  │ lane 0 │ │ lane 1 │ │ lane 2 │ │ lane 3 │  each: record,   │
   │  └────────┘ └────────┘ └────────┘ └────────┘  timer, counter,  │
   └──────────────────────────────────────────────  SR, FIFOs ──────┘
         │ 4 output slots per lane          ▲ 32-entry input vector
         ▼                                  │ (pins, outputs, lane flags)
   OMAP pin router (push-pull / open-drain / invert) ──► uo[6:0], uio[7:0]
```

## Lanes and timing

* Four lanes share one single-port memory with **registered** read data, which is how the IHP
  macro behaves. A slot counter gives lane *i* the clocks where `slot == i`. In 2-lane mode
  (`G_CTRL[0]=0`) lanes 0 and 1 alternate. In 4-lane mode all four lanes take turns.
* A lane only touches memory when it changes state. Its fetch is issued in its own slot, and the
  data comes back in the next clock, which is always before the lane's next slot. **Every lane
  can change state on every one of its ticks**, so timing is fully deterministic: no stalls,
  no arbitration, and no dependence on what the other lanes are doing.
* A **tick** is one lane step. The tick rate is `clk / (N × (DIV+1))`, where N is 2 or 4.
  At 60 MHz with 2 lanes that is 30 MHz, or 33 ns per tick.
* A transition to the current state does not fetch. It re-enters the state, so the entry
  action runs again.
* The host gets the memory in any clock where the owning lane isn't fetching.

## The state record (64 bits)

| bits  | field     | meaning |
|-------|-----------|---------|
| 63:55 | `T1`      | next state when BR is true |
| 54:46 | `T0`      | next state when BR is false |
| 45    | `W_INV`   | invert WAIT |
| 44:41 | `W_SEL`   | WAIT condition |
| 40    | `B_INV`   | invert BR |
| 39:36 | `B_SEL`   | BR (branch) condition |
| 35:31 | `ISEL`    | input select (pin conditions, shift-in bit) |
| 30:27 | `OMASK`   | output slots written by the entry action |
| 26:23 | `OVAL`    | values for those slots |
| 22    | `SOUT_EN` | slot `SOUT` ← shift-register out bit |
| 21:20 | `SOUT`    | |
| 19    | `SH`      | shift the shift register |
| 18:17 | `FIFO`    | 0 –, 1 pop TX→SR, 2 push SR→RX, 3 SR←IMM[7:0] |
| 16:15 | `CNT`     | 0 –, 1 decrement, 2 load IMM[7:0], 3 increment |
| 14:13 | `TMR`     | 0 –, 1 load TA, 2 load TB, 3 load IMM |
| 12:11 | `FLAG`    | 0 –, 1 set lane flag, 2 clear lane flag, 3 raise host event |
| 10:9  | `XOP`     | timing learning: 0 –, 1 stopwatch ← 0, 2 TA ← SW, 3 TB ← SW + SW/2 |
| 8:0   | `IMM`     | immediate |

### What one tick does

On every tick the lane holds one record:

1. **Entry action**, only on the first tick in the state:
   * SR pipeline: **load** (pop or IMM), then take the **out bit** (SR[7] if MSB-first,
     otherwise SR[0]), then **shift** (the new bit comes from `in[ISEL]`).
     `push` sends the post-shift SR to the RX FIFO. Pushing to a full RX FIFO drops the byte
     and sets the lane's overflow flag.
   * Output slots: `OMASK`/`OVAL` are applied first, then `SOUT` takes the out bit.
   * The counter, timer and flag ops are applied.
   * **Stopwatch** `SW` (16-bit, per lane) counts ticks and saturates at 0xFFFF. `XOP=1` clears it.
     `XOP=2/3` write the lane's own **TA** / **TB** registers from it (`TB` gets 1.5 × SW). A
     program can therefore measure a bit time on the line and adopt it, which is how on-chip
     auto-baud works (`programs/uart_rx_autobaud.setl`). The host can read the learned value back.
2. **Timer:** if this tick did not load it, the timer decrements towards 0.
3. **Conditions** see the values *after* this tick's action. If **WAIT** holds, the lane moves to
   `BR ? T1 : T0`. Otherwise it stays, and later ticks run no action.

So `timer=N … wait timer` makes the state last N+1 ticks. Without a wait, a state takes one tick.

### Conditions (`W_SEL` / `B_SEL`, each with an invert bit)

| # | name | true when |
|---|------|-----------|
| 0 | `always` | always |
| 1 | `timer` | timer == 0 |
| 2 | `cnt0` | counter == 0 |
| 3 | `txready` | TX FIFO not empty |
| 4 | `rxfull` | RX FIFO full |
| 5 | `pin` | `in[ISEL]` high |
| 6/7/8 | `rise`/`fall`/`edge` | `in[ISEL]` changed since the previous tick *in this state* (never on the entry tick) |
| 9 | `edge_or_timer` | edge, or timer == 0 (timeouts) |
| 10 | `match` | `((SR ^ MATCH) & MASK) == 0` |
| 11 | `bit` | SR out-end bit |
| 12 | `hflag` | host flag for this lane |
| 13 | `crcok` | CRC register == residue (after this tick) |
| 14 | `ones` | ones-run counter == run length (bit stuffing) |
| 15 | – | reserved (false) |

### Input vector (`ISEL`)

| index | source |
|-------|--------|
| 0–7 | `ui[0..7]` (2-flop synchronised) |
| 8–15 | `uio[0..7]` (2-flop synchronised) |
| 16–22 | `uo[0..6]`: the chip's own outputs, for lane-to-lane links on chip |
| 24–27 | lane flags 0–3, for lane-to-lane synchronisation |
| 30 / 31 | constant 0 / 1 |

### Outputs

Each lane drives 4 **output slots**. The per-lane `OMAP` registers route each slot to a pin
(`uo0-6` or `uio0-7`). Each mapping can be **open-drain** (0 drives low, 1 releases) and/or
**inverted**. SPI CPOL is just an inverted SCK mapping. If several slots map to the same pin,
their values are OR-ed.

### CRC / LFSR and bit-stuffing assist

Each lane has a programmable 16-bit CRC/LFSR and a ones-run counter. They are
configured by `CTRL` and the per-lane registers at `0xA0 + 8·lane` (POLY, INIT,
RESIDUE, CRC; little-endian 16-bit; CRC can be read and written).

* `CTRL[1]` enables the CRC. On every `shift` it takes one bit: the shifted-out bit, or
  the input bit when `CTRL[2]` is set. `CTRL[3]` selects shift-left (MSB-first
  polynomials); otherwise it shifts right (reflected polynomials, e.g. 0xA001 for
  CRC-16/MODBUS and USB).
* `CTRL[7:4]` sets the ones-run length (0 = off). The counter counts consecutive 1 bits
  on the same bit source. `ones` becomes true when the counter reaches the length (6 for
  USB, 5 for HDLC/CAN).
* `ld` with IMM[8] set is a special form: `crc lo` (SR ← CRC[7:0]), `crc hi`,
  `crc clr` (CRC ← INIT) and `ones clr` (after inserting a stuff bit); `crc nlo` /
  `crc nhi` load the *complemented* CRC byte and freeze the CRC until the next `crc clr`
  (USB, HDLC/PPP).

A reflected CRC shifts its own low byte out to the old high byte, so a transmitter
appends the CRC with `crc lo` twice. A receiver that passes the CRC bytes through the
unit ends with the CRC at the residue: `crcok` (`programs/modbus_tx.setl` /
`modbus_rx.setl`).

## Host interface

The host interface is an SPI target (mode 0, MSB first, SCK ≤ clk/16) on `ui7`/`ui6`/`ui5`/`uo7`.

| byte 0 | then |
|--------|------|
| `0x00` WREG (`|0x20` no auto-increment) | reg address, data… |
| `0x40` RREG | reg address, dummy… (data is returned during the following bytes) |
| `0x80` WMEM | addr[11:8], addr[7:0] (byte address, word = addr>>3, byte 0 = bits 63:56), data… |
| `0xC0` RMEM | addr[11:8], addr[7:0], dummy… |

### Registers

The lane *L* registers are at `L*0x10 + r`:

| r | name | |
|---|------|-|
| 0 | CTRL | [0] MSB-first shift, [1] CRC on, [2] CRC/ones bit = input, [3] CRC shifts left, [7:4] ones run length |
| 1,2 | START | first state (9 bits) |
| 3 | DIV | tick divider (DIV+1) |
| 4,5 / 6,7 | TA / TB | 16-bit timer reload values |
| 8–B | OMAP0–3 | [4:0] pin (0–6 uo, 8–15 uio, other = none), [5] open-drain, [6] invert |
| C | OUTINIT | slot values loaded at start |
| D,E | MATCH, MASK | for the `match` condition |
| F | FIFO | write: push TX. Read: pop RX (popped only when the host clocks the byte) |

Global registers:

| addr | name | |
|------|------|-|
| 0x80 | G_CTRL | [0] 4-lane mode |
| 0x81 | RUN | [3:0]; a 0→1 transition restarts that lane at START (lanes started together start in lock-step) |
| 0x82/83 | ID / VERSION | 0x5E / 0x01 |
| 0x84 | EVENTS | [3:0] events, [7:4] lane flags |
| 0x85 | HFLAG | host flags (`hflag` condition) |
| 0x88+L | STATUS | [2:0] TX level, [5:3] RX level, [6] event, [7] overflow; writing 1s clears [7:6] |
| 0x8C+L / 0x90+L / 0x94+L / 0x98 | PC / SR / CNT / PC[8] | debug |
| 0xA0+8L … +7 | POLY, INIT, RESIDUE, CRC | CRC unit (16-bit little-endian; CRC is read/write) |

## Memory build options (`src/setl_mem.v`)

| define | memory | use |
|--------|--------|-----|
| `SETL_IHP_SRAM` | 2 × `RM_IHPSG13_1P_512x32_c2_bm_bist` (512 words) | target silicon |
| `SETL_SIM_FULLMEM` | 512-word behavioural array | RTL simulation / FPGA |
| *(none)* | 64-word flip-flop array | stock Tiny Tapeout flow fallback |

## Example: UART transmitter (complete program)

```
tx_idle:  wait txready                                goto tx_start
tx_start: pop set 0=0 cnt=8 timer=TA wait timer       goto tx_bit
tx_bit:   out 0 shift dec timer=TA wait timer         if cnt0 goto tx_stop else tx_bit
tx_stop:  set 0=1 timer=TA wait timer                 if txready goto tx_start else tx_idle
```

That is four 64-bit words. The baud rate is the `TA` register, so the same program runs at
any rate.
