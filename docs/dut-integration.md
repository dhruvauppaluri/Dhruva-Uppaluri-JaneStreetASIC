# DUT integration for USB LS and 10 Mbit Ethernet

This note is the board-level hookup for the programmable protocol emulator on
Tiny Tapeout **6×4**, IHP **130 nm CMOS5L**, 50 MHz clock. The ASIC stays a
reprogrammable processor: UART, SPI, I2C, USB LS fragments, and Ethernet SPI
are firmware plus general assists, not fixed protocol IP.

Recommended run-mode pin map (the eight `uio` pins remain ordinary GPIO; the
labels are a convention for stretch-goal firmware):

| Pin | Stretch use | Notes |
| --- | --- | --- |
| `uio[0]` | USB D+ | Single-ended sample/drive |
| `uio[1]` | USB D− | LS idle J is D− high, D+ low |
| `uio[2]` | Ethernet SPI SCK | To ENC28J60-class SCK |
| `uio[3]` | Ethernet SPI MOSI | |
| `uio[4]` | Ethernet SPI MISO | Input from the controller |
| `uio[5]` | Ethernet SPI CS | Active low |
| `uio[6]` | Ethernet RST | Active low, held high in the min-frame demo |
| `uio[7]` | Ethernet INT | Input; unused by the canned demo |

Host loader pins (`ui_in[0:5]`) stay on the Tiny Tapeout input bus. Load
firmware with `ui_in[3]` low, then set `ui_in[3]` high to run. Do not reset
after loading classifier or assist configuration; reset clears those blocks
but not instruction SRAM.

## USB low-speed (1.5 Mbit/s)

Low-speed **device** identification is a **1.5 kΩ pull-up on D−** to 3.3 V
(USB 2.0). Full-speed uses the pull-up on D+ instead; this project claims
low-speed only.

Typical discrete front-end:

- 1.5 kΩ from D− (`uio[1]`) to 3.3 V
- Optional ~33 Ω series on D+ and D−
- Common ground with the device under test
- Optional 3.3 V USB FS/LS transceiver if the DUT is not 3.3 V tolerant

The assist programs a 33-cycle bit tick at 50 MHz (660 ns, about 1% fast vs
666.7 ns). Firmware in `firmware/usb_ls_sync_pid.asm` and
`firmware/usb_ls_data0_crc.asm` emits SYNC + PID and a DATA0 byte with
hardware CRC-16 and bit stuffing. This is a recognizable LS packet fragment
for a scope or a cooperative test MCU, not a full enumeration stack.

## 10 Mbit Ethernet (SPI MAC/PHY)

The ASIC does **not** implement RMII, MII, or 10BASE-T magnetics. 10 Mbps on
the wire comes from an external SPI Ethernet controller (ENC28J60 class)
with its own PHY and magnetics. The emulator is a **programmable SPI
master** that bit-bangs SCK/MOSI/CS on `uio[2:5]`.

Suggested BOM:

- ENC28J60 (or equivalent SPI 10BASE-T MAC+PHY)
- 3.3 V supply and the vendor crystal
- Magjack / magnetics per the ENC28J60 datasheet
- 10 kΩ pull-up on CS if the ASIC tristates during reset

`firmware/enc28j60_min_frame.asm` writes WBM (`0x7A`) and a broadcast
destination MAC. A real ARP/UDP frame still needs buffer-pointer and MACON
setup in a longer program; 256 words is enough to grow that firmware without
changing silicon.

## Load / run sequence

1. Assert `rst_n` low, then release it with `ui_in[3]` low.
2. Shift each 16-bit instruction MSB-first; pulse commit after 16 bits.
   Load 256 words, or load the live program and leave the rest as `HALT`.
3. Optionally restart the loader address (`ui_in[5]`) and program classifier
   weights (`ui_in[4]`) or assist registers (`ui_in[7]`).
4. Drive protocol pins to idle (USB J, SPI CS high) via firmware `OUT`/`DIR`.
5. Set `ui_in[3]` high. `uo_out[4:0]` shows `PC[4:0]`; set `ui_in[7]` to
   view `PC[7:5]` on `uo_out[2:0]`.

## Competition tier

This is **Tier 2**: SRAM-backed 256×16 IMEM, PIO-style assists, USB LS on
D+/D−, and 10 M Ethernet via SPI-attached PHY. See the README stretch-goal
section for what is and is not claimed.
