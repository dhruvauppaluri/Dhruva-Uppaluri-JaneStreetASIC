# DUT integration for USB LS and 10 Mbit Ethernet

This note is the board-level hookup for the programmable protocol emulator on
Tiny Tapeout **6×4**, IHP **130 nm CMOS5L**, 50 MHz clock. The ASIC stays a
reprogrammable processor: UART, SPI, I2C, USB LS, and 10 M Ethernet MAC are
firmware plus one shared serial engine, not fixed protocol IP.

**Map A** (default) puts every stretch I/O on the eight `uio` pins and leaves
the serial loader on `ui_in` untouched:

| Pin | Run-mode function |
| --- | --- |
| `uio[0]` | USB D+ |
| `uio[1]` | USB D− (LS idle J is D− high, D+ low) |
| `uio[2]` | RMII `TXD0` |
| `uio[3]` | RMII `TXD1` |
| `uio[4]` | RMII `TX_EN` |
| `uio[5]` | RMII `RXD0` |
| `uio[6]` | RMII `RXD1` |
| `uio[7]` | RMII `CRS_DV` |
| `clk` | Shared 50 MHz `REF_CLK` to the external PHY |
| PHY `RST#` | Board pull-up / strap; MDIO is omitted |

UART/SPI/I2C demos keep using `uio[7:0]` as generic GPIO when that firmware is
loaded. Stretch USB+Ethernet firmware uses Map A and can run both at once
(2+6=8). There is no leftover GPIO for a third protocol while stretch is live.

Host loader pins (`ui_in[0:5]`) stay on the Tiny Tapeout input bus. Load
firmware with `ui_in[3]` low, then set `ui_in[3]` high to run. Do not reset
after loading classifier or engine configuration; reset clears those blocks
but not instruction SRAM.

The analog USB PHY, 15 kΩ pulldowns, 10BASE-T PMA, magnetics, and RJ45 are
**not** on the die.

## USB low-speed (1.5 Mbit/s)

Low-speed **device** identification is a **1.5 kΩ pull-up on D−** to 3.3 V
(USB 2.0). Full-speed uses the pull-up on D+ instead; this project claims
low-speed only.

Typical discrete front-end:

- 1.5 kΩ from D− (`uio[1]`) to 3.3 V
- Optional ~33 Ω series on D+ and D−
- Common ground with the host
- Optional 3.3 V USB FS/LS transceiver if the host is not 3.3 V tolerant

The serial engine programs a 33-cycle bit tick at 50 MHz (660 ns, about 1%
fast vs 666.7 ns), NRZI, bit stuffing, CRC-16, SYNC hunt, and EOP. Firmware
in `firmware/usb_ls_device_lite.asm` is a device-lite: bus reset, SET_ADDRESS,
and GET_DESCRIPTOR (device) on D+/D−. `usb_ls_sync_pid.asm` and
`usb_ls_data0_crc.asm` remain SIE TX smoke tests, not the USB stretch claim.

A real host must still supply a legal attach (pull-up) and reset (≥10 ms SE0).
The cooperative testbench uses a short SE0 pulse, longer than EOP and shorter
than a full 10 ms reset.

## 10 Mbit Ethernet (on-die MAC, external PHY)

The ASIC implements a **10 Mbps MAC** (preamble/SFD, CRC-32, IFG, RMII-10
framer, 64-byte packet RAM). 10 Mbps exists on the RJ45 because a
**LAN8720-class RMII PHY** plus magnetics do PMA off-chip. Tiny Tapeout `clk`
is already 50 MHz; route that oscillator to the PHY `REF_CLK`.

Suggested BOM:

- LAN8720 / LAN8720A (or equivalent RMII 10/100 PHY)
- 3.3 V supply; strap RMII and 10 M / autoneg per the datasheet
- Magjack / magnetics per the PHY datasheet
- PHY `RST#` pulled up; **no MDIO** on Map A

`firmware/eth_rmii_min_frame.asm` and `firmware/eth_rmii_loopback.asm` load a
60-byte padded frame; the engine appends preamble, SFD, FCS, and IFG and
holds each dibit for ten `clk` cycles. `firmware/enc28j60_min_frame.asm` is a
generic SPI example only — it is not the Ethernet architecture.

## Load / run sequence

1. Assert `rst_n` low, then release it with `ui_in[3]` low.
2. Shift each 16-bit instruction MSB-first; pulse commit after 16 bits.
   Load 256 words, or load the live program and leave the rest as `HALT`.
3. Optionally restart the loader address (`ui_in[5]`) and program classifier
   weights (`ui_in[4]`) or engine registers (`ui_in[7]`).
4. Drive protocol pins to idle (USB J via the D− pull-up) via firmware.
5. Set `ui_in[3]` high. `uo_out[4:0]` shows `PC[4:0]`; set `ui_in[7]` to
   view `PC[7:5]` on `uo_out[2:0]`.

## Competition story

This is the on-die SIE/MAC stretch: SRAM-style 256×16 IMEM (still
flip-flop-inferred in this RTL), a PIO-style CPU, USB LS on D+/D−, and
10 M Ethernet as **our MAC** to an external PHY. See the README for what is
and is not claimed.
