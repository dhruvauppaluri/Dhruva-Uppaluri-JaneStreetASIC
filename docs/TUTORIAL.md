# Adding a protocol in 15 minutes

This walks through a protocol SETL was never designed for, **Manchester line coding**
(IEEE 802.3: a 0 is high→low, a 1 is low→high, with a transition in the middle of every
bit). The steps are: write it, run it in the model, test it, and load it. The finished
files are `programs/manchester_tx.setl` and `test_manchester` in `test/test.py`.

## 1. Think in states, not instructions

Each state is one 64-bit record:

```
label:  ENTRY ACTIONS            wait CONDITION      goto NEXT | if COND goto A else B
```

The entry actions run once, when the state is entered. Then the lane waits for the
condition and jumps. A Manchester bit is two halves, so a 1 is "low for half a bit, then
high for half a bit", and the encoder needs:

* two states per bit value: the first half and the second half;
* a way to choose between them: the `bit` condition (the shift register's next
  out-bit);
* the byte bookkeeping: `pop` a byte, count 8 bits with `cnt`, and `shift` after each.

## 2. Write it

```
mc_idle:  set 0=0 wait txready                 goto mc_load
mc_load:  pop cnt=8                            if bit goto mc_1a else mc_0a
mc_1a:    set 0=0 timer=TA wait timer          goto mc_1b       ; first half of a 1
mc_1b:    set 0=1 shift dec timer=TB wait timer goto mc_next
mc_0a:    set 0=1 timer=TA wait timer          goto mc_0b       ; first half of a 0
mc_0b:    set 0=0 shift dec timer=TB wait timer goto mc_next
mc_next:                                       if cnt0 goto mc_more else mc_pad
mc_pad:                                        goto mc_pick
mc_pick:                                       if bit goto mc_1a else mc_0a
mc_more:                                       if txready goto mc_load else mc_end
mc_end:                                        goto mc_idle
```

`set 0=1` drives output slot 0. The host maps slot 0 to a pin (`outmap=["uo0"]`), so the
program never names a pin. `timer=TA wait timer` holds a state for TA+1 ticks.

## 3. The one rule that matters: count every tick

A state without `wait` still takes one tick. If decision states sit between two edges,
they add to that interval. The first version of this encoder had two bugs:

1. The second half included the decision states, so it was longer than the first half.
   The fix is to make **every** path from a second half to the next first half equally
   long (here: 3 decision ticks via `mc_pad`, `mc_more` or `mc_end`) and give the second
   half a shorter timer: **TB = TA − 3**.
2. At the end of a frame the path to `mc_idle` was one tick shorter than the
   continue-path, so the last bit was clipped. `mc_end` pads it.

The test below catches both, because it requires **every edge to lie on the half-bit
grid**. The bigger generated programs (USB, CAN) follow the same rule; their generators
pad every path in the same way.

## 4. Assemble and run it in the model

```
PYTHONPATH=tools python3 -m setl.asm programs/manchester_tx.setl -l
```

The golden model runs programs with no simulator at all. That makes it handy for
working out timing:

```python
from setl import model, isa
from setl.asm import assemble
img, sym, _ = assemble(open("programs/manchester_tx.setl").read())
chip = model.Chip(); chip.load(img)
for addr, val in [(isa.R_CTRL, 1), (isa.R_TA_LO, 7), (isa.R_TB_LO, 4),
                  (isa.R_OMAP0, 0), (isa.R_OUTINIT, 0), (isa.R_FIFO, 0xA5), (isa.G_RUN, 1)]:
    chip.write_reg(addr, val); chip.step()
wave = []
for _ in range(400):
    wave.append(chip.outputs()[0] & 1); chip.step()
print("".join(map(str, wave)))
```

## 5. Test it against an independent decoder

`test_manchester` loads the program over the real SPI host port, decodes the pin with
its own Manchester decoder, and checks the bytes and the edge grid. Because every RTL
test runs the golden model in lockstep, it also checks the RTL against the model on every
clock.

```
cd test && make COCOTB_TEST_MODULES=test COCOTB_TEST_FILTER=test_manchester
```

## 6. Optional: prove it

`python -m setl.asm prog.setl --vrom rom.vh --vsyms sym.vh` turns the program into a
Verilog ROM. `formal/fv_*.v` show how to put a ROM on the real lane RTL and prove
properties with SymbiYosys. Copy `fv_uart_tx.v` and replace the protocol monitor.

## 7. Run it on the board

```
make -C programs                # builds programs/build/manchester_tx.json
```

Then, on the RP2350 (see `examples/`):

```python
sym = board.load(c, "manchester_tx")
c.config_lane(0, start=sym["manchester_tx"], ta=7, tb=4, msb=True, outmap=["uo0"], outinit=0)
c.run(1); c.push(0, [0xA5])
```

That's the whole loop. A protocol that didn't exist when the chip was made becomes
eleven records and a few register writes.
