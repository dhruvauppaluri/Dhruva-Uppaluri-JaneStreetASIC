# SETL: Sparse Event-Transition Lanes

A post-fabrication reprogrammable protocol emulator for the Jane Street protocol emulator
ASIC competition (IHP SG13CMOS5L via Tiny Tapeout, 8×4 tiles).

There is no CPU. Protocols are compiled into **state graphs** stored in SRAM. Each 64-bit
word is one state: an entry action, a wait condition, and two successor states. Four
lanes run these graphs concurrently on a deterministic barrel, with one state change
per lane tick and no stalls.

| | |
|-|-|
| Architecture and ISA | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Verification | [docs/VERIFICATION.md](docs/VERIFICATION.md) |
| **Write-up (start here)** | [docs/WRITEUP.md](docs/WRITEUP.md) |
| Status and plan | [docs/STATUS.md](docs/STATUS.md) |
| Assembler / model / host driver | `tools/setl/` |
| Example programs | `programs/`: UART TX/RX and auto-baud RX, SPI controller (modes 0–3) and target, I²C controller and target, JTAG, SWD, PS/2, WS2812, MODBUS RTU, CAN TX, USB low-speed TX/RX |
| Formal proofs | `formal/` (programs proven on the lane RTL) |

**What it can do that a fixed-function chip can't:** learn an unknown device's baud rate
on chip; sniff an I²C bus, learn the device on the host and then **impersonate it**
after it is unplugged; be an I²C controller and target at once; and run any protocol
that fits the state-record model, all after fabrication.

```
cd test && make                       # directed protocol tests + lockstep golden model
make COCOTB_TEST_MODULES=test_random  # constrained-random co-simulation
```

Built from the [Tiny Tapeout IHP Verilog template](https://github.com/TinyTapeout/ttihp-verilog-template)
(template files keep their Apache-2.0 notices). The IHP SRAM simulation models in
`test/ihp_sram/` are copies of the IHP Open PDK models (Apache-2.0, © IHP PDK Authors).
Everything else: MIT, see `LICENSE`.

This branch replaces the earlier single-CPU design (see git history before `setl-rewrite`).
