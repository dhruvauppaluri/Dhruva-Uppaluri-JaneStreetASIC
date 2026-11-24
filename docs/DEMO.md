# Demo: learn an I²C device, then answer for it

This is the evidence behind the "learn, then impersonate" claim: the commands to
reproduce it, and a trace from one run. It runs in RTL simulation, with the golden
model compared every clock. It has **not** yet run on FPGA or silicon. The RP2350
transport (`tools/setl/rp2350.py`) is written but not yet run on hardware.

## Reproduce

```bash
cd test
make COCOTB_TEST_MODULES=test COCOTB_TEST_FILTER=test_learn_and_impersonate
```

To repeat a run exactly, add `COCOTB_RANDOM_SEED=<seed>`. The test logs its seed. Each
run draws new phases, delays and jitter.

## What the test does

| step | who | what |
|---|---|---|
| 1 | test bench | An MCU model (`bfm.I2cController`) talks to a sensor model (`bfm.I2cTarget`, address 0x50) |
| 2 | SETL lane 0 | `programs/i2c_sniff.setl` captures the bus passively as (value, tag) pairs into the 16-deep RX FIFO |
| 3 | host | drains the FIFO with random service delays; `setl.learn.learn()` builds a register-device model |
| 4 | test bench | records a **held-out session** against the real sensor. The learner never sees it |
| 5 | host | unplugs the sensor and loads `programs/i2c_target_host.setl` (match 0x50) |
| 6 | SETL lane 0 + host | `learn.Impersonator` serves the model. The lane stretches SCL while the host (with random delays) computes each byte |
| 7 | test bench | the MCU repeats its training traffic and must get identical answers |
| 8 | test bench | a **second controller** with different timing and jitter runs the held-out session and must get the real sensor's answers, including a NACK for the absent address 0x51 |

The test runs three cases:

| I²C half period | bus rate at 33.33 MHz (sign-off) | host service delay | controller jitter |
|---|---|---|---|
| 166 clocks | 100 kHz | up to 6000 clocks (180 µs) | up to 40 clocks per phase |
| 300 clocks | 55 kHz (100 kHz at 60 MHz) | none | none |
| 42 clocks | ~400 kHz | up to 1500 clocks (45 µs) | up to 10 clocks per phase |

Each case also starts the bus at a random phase relative to the lane barrel.

## Trace (one run, seed 79420375602073894659226120035866130453453273409)

Capture, as (value, tag) with `S`=0x53, `P`=0x50, `A`=0x41, `N`=0x4E (the same in all
three cases):

```
S (A0,A) (00,A)  S (A1,A) (12,A) (34,A) (56,A) (78,N) P      ptr=0, read 4
S (A0,A) (0F,A)  S (A1,A) (33,N) P                           ptr=0x0F, read 1
S (A0,A) (10,A) (5A,A) (5B,A) P                              write 0x10,0x11
S (A0,A) (10,A)  S (A1,A) (5A,A) (5B,N) P                    ptr=0x10, read 2
```

Learned: address 0x50; registers {00:12, 01:34, 02:56, 03:78, 0F:33, 10:5A, 11:5B};
none volatile; 7 transactions. Peak RX FIFO level: 6/16, 2/16 and 8/16.

| session | real sensor | SETL impersonating |
|---|---|---|
| training: read 0..3, read 0x0F, read 0x10..0x11 | `[12 34 56 78] [33] [5A 5B]` | `[12 34 56 78] [33] [5A 5B]` |
| held-out: read 0x02 | `[56]` | `[56]` |
| held-out: read 3 from 0x01 | `[34 56 78]` | `[34 56 78]` |
| held-out: address 0x51 | NACK | NACK |
| held-out: write 0x11=C3, read 0x10..0x11 | `[5A C3]` | `[5A C3]` |
| held-out: read 3 from 0x0F | `[33 5A C3]` | `[33 5A C3]` |

SCL was stretched by the target for 54 429, 11 244 and 32 891 clocks in total while the
host computed replies.

## A bug this found

Before this sweep, the demo ran at a single fixed timing and passed. With random phase
and jitter, the capture lost read data. The sniffer polls SCL and SDA on alternate ticks.
When SCL fell just after it was sampled high, the target's next data bit could appear to
change SDA "while SCL was high", which reads as a STOP. The sniffer and both I²C target
programs now sample SCL once more after any SDA change, so START/STOP is only reported
when SCL is still high. This was a two-record change per loop, not a hardware change.

## Limits of this evidence

* The sensor is a register-pointer device. `learn.py` learns that class only, and
  registers it never saw read back as 0xFF.
* The controllers are test-bench models, not a real MCU, and the bus is simulated.
* Next step: the same flow on an FPGA build (`SETL_SIM_FULLMEM`) against a real I²C
  sensor, driven from the RP2350.
