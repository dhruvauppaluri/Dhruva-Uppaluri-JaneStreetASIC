"""Constrained-random lockstep co-simulation (RTL only).

Each seed builds random programs for all four lanes, a random configuration
(barrel width, dividers, bit order, pin maps incl. open-drain and inversion,
match/mask), drives random pin activity and random host traffic (FIFO pushes
and pops, host flags, program rewrites while running, lane stop/restart), and
compares the RTL against the Python golden model on every output and every
internal lane register, every cycle.

SETL_SEEDS=N (default 12), SETL_CYCLES=N (default 6000), SETL_SEED0=first seed.
"""
import os
import random

import cocotb
from cocotb.triggers import ClockCycles

from harness import Harness, AHost, GATES
from setl import isa

SEEDS = int(os.environ.get("SETL_SEEDS", "16"))
CYCLES = int(os.environ.get("SETL_CYCLES", "40000"))
SEED0 = int(os.environ.get("SETL_SEED0", "1"))
REGION = 24  # states per lane


def rand_record(rng, base):
    w_sel = rng.choices(range(16), weights=[8, 10, 3, 3, 1, 4, 3, 3, 3, 4, 1, 1, 1, 1, 1, 0.2])[0]
    b_sel = rng.randrange(16)
    return isa.pack(
        t1=base + rng.randrange(REGION), t0=base + rng.randrange(REGION),
        w_inv=int(w_sel != 0 and rng.random() < 0.15), w_sel=w_sel,
        b_inv=rng.randrange(2), b_sel=b_sel,
        isel=rng.choice([0, 1, 2, 3, 4, 0, 1, 2, 8, 9, 10, 11, 16, 17, 18, 24, 25, 26, 27, 30, 31]),
        omask=rng.randrange(16), oval=rng.randrange(16),
        sout_en=rng.randrange(2), sout=rng.randrange(4), sh=rng.randrange(2),
        fifo=rng.randrange(4), cnt=rng.randrange(4), tmr=rng.randrange(4),
        flag=rng.randrange(4), xop=rng.choice([0, 0, 0, 1, 2, 3]),
        imm=rng.choice([0, 1, 2, 3, 5, 8, 0x100, 0x101, 0x102, 0x103, 0x104, 0x105, rng.randrange(512)]) if rng.random() < 0.9 else rng.randrange(16),
    )


def rand_omap(rng):
    if rng.random() < 0.2:
        return isa.OMAP_NONE
    pin = rng.choice(list(range(7)) + list(range(8, 16)))
    return pin | (isa.OMAP_OD if rng.random() < 0.3 else 0) | (isa.OMAP_INV if rng.random() < 0.2 else 0)


async def run_seed(dut, seed):
    rng = random.Random(seed)
    h = Harness(dut, cosim=True)
    await h.start()
    host = AHost(h)

    image = {}
    for lane in range(4):
        base = lane * 32
        for a in range(REGION):
            image[base + a] = rand_record(rng, base)
    # backdoor load (the SPI load path is covered by the directed tests)
    with open("backdoor.hex", "w") as fh:
        for a in range(isa.NWORDS):
            fh.write(f"{image.get(a, 0):016x}\n")
            h.model.mem[a] = image.get(a, 0)
    dut.user_project.mem.bd_load.value = 1
    await ClockCycles(dut.clk, 1)
    dut.user_project.mem.bd_load.value = 0
    await host.set_mode4(rng.random() < 0.5)
    for lane in range(4):
        cfg = [rng.randrange(256), (lane * 32 + rng.randrange(REGION)) & 0xFF, 0,
               rng.choice([0, 0, 0, 1, 2]),
               rng.randrange(12), 0, rng.randrange(12), 0,
               *[rand_omap(rng) for _ in range(4)],
               rng.randrange(16), rng.randrange(256), rng.randrange(256)]
        await host.write_regs(lane * 16, cfg)
        await host.write_regs(isa.G_CRC + 8 * lane, [rng.randrange(256) for _ in range(8)])
        await host.push(lane, [rng.randrange(256) for _ in range(rng.randrange(5))])
    await host.write_reg(isa.G_HFLAG, rng.randrange(16))

    async def pins():
        while True:
            await ClockCycles(dut.clk, rng.choice([1, 2, 3, 5, 8, 13]))
            h.ui = rng.randrange(32)
            h.ext = rng.randrange(256) | rng.randrange(256)  # bias towards released

    task = cocotb.start_soon(pins())
    await host.run(0xF)
    end = h.cycle + CYCLES
    while h.cycle < end:
        op = rng.choices(range(8), weights=[3, 2, 1, 2, 4, 1, 1, 4])[0]
        lane = rng.randrange(4)
        if op == 0:
            await host.push(lane, [rng.randrange(256) for _ in range(rng.randrange(1, 3))])
        elif op == 1:
            await host.pop(lane, rng.randrange(1, 3))
        elif op == 2:
            await host.write_reg(isa.G_HFLAG, rng.randrange(16))
        elif op == 3:
            a = lane * 32 + rng.randrange(REGION)
            await host.load_image({a: rand_record(rng, lane * 32)})
        elif op == 4:
            await host.write_reg(isa.G_RUN, rng.randrange(16))
        elif op == 5:
            await host.write_reg(isa.G_STATUS + lane, 0xC0)
        elif op == 6:
            await host.read_regs(isa.G_STATUS, 4)
            if rng.random() < 0.3:     # host rewrites a CRC register while lanes run
                await host.write_reg(isa.G_CRC + 8 * lane + rng.randrange(8), rng.randrange(256))
        else:
            await ClockCycles(dut.clk, rng.randrange(100, 1500))
    task.cancel()
    h.stop()
    cov = " ".join(f"{k}={v}" for k, v in sorted(h.model.cov.items()))
    dut._log.info(f"seed {seed}: {h.cycle} cycles, {h.mismatches} mismatches; coverage {cov}")
    h.check()


if not GATES:
    @cocotb.test()
    async def test_random_cosim(dut):
        for s in range(SEED0, SEED0 + SEEDS):
            await run_seed(dut, s)
