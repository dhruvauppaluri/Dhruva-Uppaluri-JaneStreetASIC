"""SETL protocol tests.  Each test loads a program through the host SPI port,
then checks the pins against an independent protocol model (bfm.py).  On RTL
runs the golden model also runs in lockstep and every output is compared
every cycle.  These tests also run on the gate-level netlist (GATES=yes).
"""
import os

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from harness import Harness, AHost
import bfm
from setl import isa
from setl.asm import assemble

PROG = os.path.join(os.path.dirname(__file__), "..", "programs")


def prog(name):
    with open(os.path.join(PROG, name)) as f:
        return assemble(f.read())


async def feed(host, lane, data):
    """Push bytes, never overfilling the 4-deep TX FIFO."""
    for b in data:
        while (await host.status(lane))["tx"] == isa.FIFO_DEPTH:
            pass
        await host.push(lane, [b])


async def setup(dut):
    h = Harness(dut)
    await h.start()
    return h, AHost(h)


@cocotb.test()
async def test_id_regs_mem(dut):
    h, host = await setup(dut)
    assert await host.read_reg(isa.G_ID) == isa.CHIP_ID
    assert await host.read_reg(isa.G_VERSION) == isa.CHIP_VERSION
    await host.write_regs(0x14, [0x34, 0x12, 0x78, 0x56])
    assert list(await host.read_regs(0x14, 4)) == [0x34, 0x12, 0x78, 0x56]
    image = {0: 0x0123456789ABCDEF, 1: 0xFEDCBA9876543210, 63: 0x5A5A5A5AA5A5A5A5}
    await host.load_image(image)
    for a, w in image.items():
        got = await host.read_word(a)
        assert got == w, f"word {a}: {got:016x} != {w:016x}"
    # byte-granular write leaves the neighbours alone
    await host.write_mem(8 + 3, [0x00])
    assert await host.read_word(1) == 0xFEDCBA0076543210
    h.check()


@cocotb.test()
async def test_uart_tx(dut):
    h, host = await setup(dut)
    img, sym, _ = prog("uart_tx.setl")
    await host.load_image(img)
    ta = 19                     # 20 ticks/bit, 2-lane barrel -> 40 clocks/bit
    await host.config_lane(0, start=sym["uart_tx"], ta=ta, outmap=["uo0"])
    msg = b"SETL\x00\xff\x55"
    await host.push(0, msg[:4])
    rx = cocotb.start_soon(bfm.uart_recv(dut.clk, lambda: h.uo_level(0), 2 * (ta + 1), len(msg)))
    await host.run(0b0001)
    await feed(host, 0, msg[4:])  # refill while transmitting
    got = await rx
    assert bytes(got) == msg, got
    h.check()


@cocotb.test()
async def test_uart_rx_and_loopback_lane(dut):
    """Lane 0 receives on ui0 from the testbench; lane 1 transmits on uo1 and
    lane 2 (4-lane barrel) receives lane 1's output through the internal uo
    readback -- three concurrent protocol engines."""
    h, host = await setup(dut)
    rx_img, rx_sym, _ = prog("uart_rx.setl")
    tx_img, tx_sym, _ = assemble(".org 8\n" + open(os.path.join(PROG, "uart_tx.setl")).read())
    lb_img, lb_sym, _ = assemble(".org 16\n" + open(os.path.join(PROG, "uart_rx.setl")).read()
                                 .replace(".pin rx ui0", ".pin rx uo1"))
    await host.load_image({**rx_img, **tx_img, **lb_img})
    await host.set_mode4(True)
    bit = 24                    # ticks/bit; 4-lane barrel -> 96 clocks/bit
    tb_ = round(1.5 * bit) - 2
    await host.config_lane(0, start=rx_sym["uart_rx"], ta=bit - 1, tb=tb_)
    await host.config_lane(1, start=tx_sym["uart_tx"], ta=bit - 1, outmap=["uo1"])
    await host.config_lane(2, start=lb_sym["uart_rx"], ta=bit - 1, tb=tb_)
    h.set_ui(0, 1)
    await host.run(0b0111)
    await host.push(1, b"\xa5\x3c")
    await bfm.uart_send(dut.clk, lambda v: h.set_ui(0, v), 4 * bit, b"\x81\x7e")
    await ClockCycles(dut.clk, 4 * bit * 4)
    st0 = await host.status(0)
    assert st0["rx"] == 2 and st0["event"] == 0, st0
    assert list(await host.pop(0, 2)) == [0x81, 0x7E]
    st2 = await host.status(2)
    assert st2["rx"] == 2, st2
    assert list(await host.pop(2, 2)) == [0xA5, 0x3C]
    assert (await host.status(0))["rx"] == 0
    h.check()


@cocotb.test()
async def test_spi_modes(dut):
    h, host = await setup(dut)
    img, sym, _ = prog("spi_ctrl.setl")
    await host.load_image(img)
    for mode in range(4):
        cpol, cpha = mode >> 1, mode & 1
        start = sym["spi_cpha1" if cpha else "spi_cpha0"]
        tgt = bfm.SpiTarget(h, sck=2, mosi=3, cs=4, miso_ui=1, cpol=cpol, cpha=cpha,
                            responses=[0xC3 ^ mode, 0x5A, 0x81])
        await host.run(0)
        await host.config_lane(0, start=start, ta=3, msb=True,
                               outmap=[("uo2", "pp", bool(cpol)), "uo3", "uo4"],
                               outinit=0b1100)
        task = cocotb.start_soon(tgt.run())
        await host.push(0, [0x9E, 0x01 + mode, 0xF0])
        await host.run(1)
        await ClockCycles(dut.clk, 2 * 4 * 2 * 8 * 3 + 200)
        assert tgt.received == [0x9E, 0x01 + mode, 0xF0], (mode, tgt.received)
        assert tgt.frames == 1, f"mode {mode}: CS toggled mid-transfer"
        assert list(await host.pop(0, 3)) == [0xC3 ^ mode, 0x5A, 0x81], mode
        assert h.uo_level(4) == 1
        task.kill()
    h.check()


@cocotb.test()
async def test_i2c_eeprom(dut):
    h, host = await setup(dut)
    img, sym, _ = prog("i2c_ctrl.setl")
    await host.load_image(img)
    tgt = bfm.I2cTarget(h, scl=0, sda=1, addr=0x50, stretch=30)
    cocotb.start_soon(tgt.run())
    # quarter period 8 ticks: 2-lane barrel -> SCL period 64 clocks (~1 MHz in sim;
    # 100/400 kHz are just bigger TA/TB values)
    await host.config_lane(0, start=sym["i2c"], ta=15, tb=7, msb=True,
                           outmap=[("uio0", "od"), ("uio1", "od")], match=0x01, mask=0x01)
    await host.run(1)
    await host.push(0, [0x50 << 1, 0x10, 0xDE, 0xAD])
    await ClockCycles(dut.clk, 3000)
    dut._log.info(f"i2c log: {tgt.log}")
    assert bytes(tgt.mem[0x10:0x12]) == b"\xde\xad", tgt.log
    # set pointer, then read 3 bytes
    await host.push(0, [0x50 << 1, 0x10])
    await ClockCycles(dut.clk, 2500)
    tgt.mem[0x12] = 0x42
    await host.push(0, [(0x50 << 1) | 1, 0, 0, 0])
    await ClockCycles(dut.clk, 4000)
    assert list(await host.pop(0, 3)) == [0xDE, 0xAD, 0x42], tgt.log
    assert (await host.status(0))["event"] == 0
    # wrong address -> NACK -> host event
    await host.push(0, [0x33 << 1, 0x00])
    await ClockCycles(dut.clk, 2000)
    assert (await host.status(0))["event"] == 1
    assert tgt.log.count("S") == tgt.log.count("P") == 4, tgt.log
    h.check()


@cocotb.test()
async def test_uart_autobaud(dut):
    """The lane learns two different baud rates from a calibration character."""
    h, host = await setup(dut)
    img, sym, _ = prog("uart_rx_autobaud.setl")
    await host.load_image(img)
    h.set_ui(0, 1)
    for bit_ticks, data in ((40, b"\x3c\xa5"), (26, b"\x81")):
        await host.run(0)
        await host.config_lane(0, start=sym["uart_autobaud"])   # TA = TB = 0: nothing preset
        await host.run(1)
        bc = 2 * bit_ticks                                       # 2-lane barrel
        await bfm.uart_send(dut.clk, lambda v: h.set_ui(0, v), bc, b"U")
        await ClockCycles(dut.clk, 3 * bc)                       # idle gap after calibration
        await bfm.uart_send(dut.clk, lambda v: h.set_ui(0, v), bc, data)
        await ClockCycles(dut.clk, 2 * bc)
        ta = int.from_bytes(await host.read_regs(isa.R_TA_LO, 2), "little")
        assert abs(ta - (bit_ticks - 1)) <= 1, f"learned TA={ta} for {bit_ticks} ticks/bit"
        st = await host.status(0)
        assert st["rx"] == len(data) and st["event"] == 0, st
        assert bytes(await host.pop(0, len(data))) == data
    h.check()


async def spi_controller(h, sck, mosi, cs, miso_uo, data, half, miso_uio=None):
    """Testbench SPI controller (mode 0, MSB first) bit-banging ui pins.
    MISO is read from uo[miso_uo], or from the uio bus when miso_uio is given."""
    clk = h.dut.clk
    got = []
    h.set_ui(cs, 0)
    await ClockCycles(clk, 2 * half)
    for b in data:
        r = 0
        for i in range(7, -1, -1):
            h.set_ui(mosi, (b >> i) & 1)
            await ClockCycles(clk, half)
            r = (r << 1) | (h.uio_level(miso_uio) if miso_uio is not None else h.uo_level(miso_uo))
            h.set_ui(sck, 1)
            await ClockCycles(clk, half)
            h.set_ui(sck, 0)
        got.append(r)
    await ClockCycles(clk, half)
    h.set_ui(cs, 1)
    await ClockCycles(clk, 4 * half)
    return got


@cocotb.test()
async def test_spi_target(dut):
    h, host = await setup(dut)
    img, sym, _ = prog("spi_target.setl")
    await host.load_image(img)
    h.set_ui(4, 1)
    await host.config_lane(0, start=sym["spi_target"], msb=True, outmap=["uo5"])
    await host.push(0, [0x5A, 0xC3, 0x0F])
    await host.run(1)
    await ClockCycles(dut.clk, 20)
    got = await spi_controller(h, sck=2, mosi=3, cs=4, miso_uo=5,
                               data=[0x9E, 0x21, 0xF0], half=12)
    assert got == [0x5A, 0xC3, 0x0F], [hex(x) for x in got]
    assert list(await host.pop(0, 3)) == [0x9E, 0x21, 0xF0]
    h.check()


@cocotb.test()
async def test_spi_target_shared_bus(dut):
    """The SPI target on a shared MISO line: tri-state OMAP mode, MISO released
    whenever CS is high, and another device answering on the same wire."""
    h, host = await setup(dut)
    img, sym, _ = prog("spi_target.setl")
    await host.load_image(img)
    h.set_ui(4, 1)
    MISO = 2
    await host.config_lane(0, start=sym["spi_target"], msb=True, outmap=[("uio2", "oe")],
                           outinit=0b0001)
    await host.push(0, [0x5A, 0xC3])
    await host.run(1)
    bad = []
    watching = True

    async def watch():                    # OE must follow CS (after sync + a few ticks)
        hist = []
        while watching:
            await RisingEdge(dut.clk)
            cs = (h.ui >> 4) & 1
            hist = (hist + [cs])[-12:]
            oe = (h.uio_oe >> MISO) & 1
            if len(hist) == 12 and all(hist) and oe:
                bad.append(("driven while CS high", h.cycle))
            if len(hist) == 12 and not any(hist) and not oe:
                bad.append(("released while CS low", h.cycle))
    w = cocotb.start_soon(watch())
    await ClockCycles(dut.clk, 40)
    got = await spi_controller(h, sck=2, mosi=3, cs=4, miso_uo=None, miso_uio=MISO,
                               data=[0x9E, 0x21], half=12)
    assert got == [0x5A, 0xC3], [hex(x) for x in got]
    # another target owns the bus now (its own CS): it pulls MISO low, no contention
    h.agents["other"] = 0xFF & ~(1 << MISO)
    await ClockCycles(dut.clk, 50)
    assert h.uio_level(MISO) == 0 and not (h.uio_oe >> MISO) & 1
    h.release("other")
    await ClockCycles(dut.clk, 50)
    assert h.uio_level(MISO) == 1          # released and pulled up
    watching = False
    await w
    assert not bad, bad[:3]
    assert list(await host.pop(0, 2)) == [0x9E, 0x21]
    h.check()


@cocotb.test()
async def test_i2c_target(dut):
    """SETL as an I2C target at address 0x42: writes, repeated-START read, wrong address."""
    h, host = await setup(dut)
    img, sym, _ = prog("i2c_target.setl")
    await host.load_image(img)
    await host.config_lane(0, start=sym["i2c_target"], msb=True,
                           outmap=[("uio1", "od")], match=0x42 << 1, mask=0xFE)
    await host.push(0, [0x11, 0x22])
    await host.run(1)
    c = bfm.I2cController(h, scl=0, sda=1, half=30)
    await ClockCycles(dut.clk, 50)
    # write two bytes
    await c.start()
    assert await c.write(0x42 << 1), "address not ACKed"
    assert await c.write(0x10)
    assert await c.write(0xAB)
    await c.stop()
    assert list(await host.pop(0, 2)) == [0x10, 0xAB]
    # pointer write, repeated START, read two bytes (ACK then NACK)
    await c.start()
    assert await c.write(0x42 << 1)
    assert await c.write(0x20)
    await c.restart()
    assert await c.write((0x42 << 1) | 1)
    got = [await c.read(True), await c.read(False)]
    await c.stop()
    assert got == [0x11, 0x22], [hex(x) for x in got]
    assert list(await host.pop(0, 1)) == [0x20]
    # another device's address is ignored (NACK)
    await c.start()
    assert not await c.write(0x43 << 1), "wrong address was ACKed"
    await c.stop()
    assert (await host.status(0))["rx"] == 0
    h.check()


# The SRAM build's gate-level netlist has the full 512-word memory, so only the
# 64-word fallback (RTL with SETL_MEM=small) skips the big programs.
SMALL_MEM = os.environ.get("SETL_MEM") == "small"


@cocotb.test(skip=SMALL_MEM)
async def test_i2c_controller_and_target_on_one_chip(dut):
    """Lane 0 is an I2C controller, lane 1 an I2C target, on the same open-drain
    pins: the chip talks to itself through its own pads (needs the 512-word memory)."""
    h, host = await setup(dut)
    c_img, c_sym, _ = prog("i2c_ctrl.setl")
    with open(os.path.join(PROG, "i2c_target.setl")) as f:
        t_img, t_sym, _ = assemble(".org 48\n" + f.read())
    await host.load_image({**c_img, **t_img})
    await host.config_lane(0, start=c_sym["i2c"], ta=15, tb=7, msb=True,
                           outmap=[("uio0", "od"), ("uio1", "od")], match=0x01, mask=0x01)
    await host.config_lane(1, start=t_sym["i2c_target"], msb=True,
                           outmap=[("uio1", "od")], match=0x42 << 1, mask=0xFE)
    await host.push(1, [0x99, 0x77])          # what the target will answer
    await host.run(0b11)
    await host.push(0, [0x42 << 1, 0x10, 0x55])
    await ClockCycles(dut.clk, 3000)
    assert list(await host.pop(1, 2)) == [0x10, 0x55]
    await host.push(0, [(0x42 << 1) | 1, 0, 0])
    await ClockCycles(dut.clk, 3500)
    assert list(await host.pop(0, 2)) == [0x99, 0x77]
    assert (await host.status(0))["event"] == 0     # no NACK seen by the controller
    h.check()


@cocotb.test()
async def test_ws2812(dut):
    h, host = await setup(dut)
    img, sym, _ = prog("ws2812.setl")
    await host.load_image(img)
    A, B = 12, 13   # ticks: 0.4 us and 0.43 us at 30 MHz ticks
    await host.config_lane(0, start=sym["ws2812"], ta=A - 1, tb=B - 1, msb=True,
                           outmap=["uo0"], outinit=0)
    data = [0x00, 0xFF, 0xA5]
    await host.push(0, data)
    dec = cocotb.start_soon(bfm.ws2812_decode(h, 0, 24, threshold=2 * (A + B // 2)))
    await host.run(1)
    bits, widths = await dec
    got = [int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, 24, 8)]
    assert got == data, (got, widths)
    # high times: "0" = A ticks, "1" = A+B ticks (2 clocks per tick)
    assert set(widths) == {2 * A, 2 * (A + B)}, sorted(set(widths))
    h.check()


@cocotb.test()
async def test_ps2_rx(dut):
    h, host = await setup(dut)
    img, sym, _ = prog("ps2_rx.setl")
    await host.load_image(img)
    h.set_ui(2, 1)
    h.set_ui(3, 1)
    await host.config_lane(0, start=sym["ps2_rx"])
    await host.run(1)
    await ClockCycles(dut.clk, 20)
    for b in (0x1C, 0xF0, 0x1C):        # 'A' make, break prefix, 'A'
        await bfm.ps2_send(h, 2, 3, b, half=60)
    assert list(await host.pop(0, 3)) == [0x1C, 0xF0, 0x1C]
    h.check()


@cocotb.test()
async def test_jtag_idcode(dut):
    from setl import jtag
    h, host = await setup(dut)
    img, sym, _ = prog("jtag.setl")
    await host.load_image(img)
    await host.config_lane(0, start=sym["jtag"], ta=3, msb=True,
                           outmap=["uo2", "uo3", "uo4"], outinit=0)
    tap = bfm.JtagTap(h, tck=2, tms=3, tdi=4, tdo_ui=1, idcode=0x4BA00477)
    cocotb.start_soon(tap.run())
    await host.run(1)
    seq, first = jtag.read_idcode_sequence()
    txb = jtag.pack(seq)
    rx = []
    for i in range(0, len(txb), 4):          # stream through the 4-deep FIFOs
        await host.push(0, txb[i:i + 4])
        await ClockCycles(dut.clk, 4 * 2 * 16 * 4 + 100)
        st = await host.status(0)
        rx += list(await host.pop(0, st["rx"]))
    bits = jtag.unpack(rx, len(seq))
    idcode = sum(b << i for i, b in enumerate(bits[first:first + 32]))
    assert tap.clocks == len(seq), (tap.clocks, len(seq))
    assert idcode == 0x4BA00477, hex(idcode)
    assert tap.state == "RTI"
    h.check()


async def mcu_session(c):
    """What a microcontroller typically does with an I2C sensor/EEPROM at 0x50."""
    A = 0x50
    out = []

    async def set_ptr(p):
        await c.start()
        assert await c.write(A << 1)
        assert await c.write(p)

    async def read(n):
        await c.restart()
        assert await c.write((A << 1) | 1)
        r = [await c.read(i < n - 1) for i in range(n)]
        await c.stop()
        return r

    await set_ptr(0x00)
    out.append(await read(4))           # measurement registers
    await set_ptr(0x0F)
    out.append(await read(1))           # WHO_AM_I
    await c.start()                     # configure: two bytes at 0x10
    assert await c.write(A << 1)
    for b in (0x10, 0x5A, 0x5B):
        assert await c.write(b)
    await c.stop()
    await set_ptr(0x10)
    out.append(await read(2))           # read the configuration back
    return out


async def heldout_session(c):
    """A different access pattern from `mcu_session`, used only for checking the
    learned device: single and crossing reads, a one-byte write, and a
    transaction to an address nobody answers."""
    A = 0x50
    out = []

    async def rd(p, n):
        await c.start()
        assert await c.write(A << 1)
        assert await c.write(p)
        await c.restart()
        assert await c.write((A << 1) | 1)
        out.append([await c.read(i < n - 1) for i in range(n)])
        await c.stop()

    await rd(0x02, 1)
    await rd(0x01, 3)
    await c.start()
    out.append(await c.write(0x51 << 1))    # absent device: must be NACKed
    await c.stop()
    await c.start()
    assert await c.write(A << 1)
    for b in (0x11, 0xC3):
        assert await c.write(b)
    await c.stop()
    await rd(0x10, 2)
    await rd(0x0F, 3)
    return out


# (I2C half period in clocks, max host service delay in clocks, controller jitter)
#   166 clocks = 100 kHz at the 33.33 MHz sign-off clock; 42 = ~400 kHz
LEARN_CASES = [(166, 6000, 40), (300, 0, 0), (42, 1500, 10)]


@cocotb.test()
async def test_learn_and_impersonate(dut):
    """Sniff an MCU talking to a sensor, learn the sensor on the host, unplug it,
    and let SETL impersonate it.  Swept over bus rate (100 kHz and 400 kHz at the
    sign-off clock), random phase between the bus and the barrel, random
    host-service delays in the capture and serve loops, and a jittered controller.
    The impersonation is checked on the training session *and* on a held-out
    session against answers recorded from the real sensor."""
    import random
    from setl import learn
    seed = cocotb.RANDOM_SEED
    rng = random.Random(seed)
    h, host = await setup(dut)
    for half, hdelay, jit in LEARN_CASES:
        await host.run(0)
        for who in ("mcu", "mcu2"):
            h.release(who)
        dut._log.info(f"learn case: half={half} host delay<={hdelay} jitter<={jit} seed={seed}")
        mcu = bfm.I2cController(h, scl=0, sda=1, half=half, who="mcu", jitter=jit, rng=rng)

        async def service_delay():
            if hdelay:
                await ClockCycles(dut.clk, rng.randint(1, hdelay))

        # ---- phase A: real sensor on the bus, SETL listens ----
        sensor = bfm.I2cTarget(h, scl=0, sda=1, addr=0x50, who="sensor")
        sensor.mem[0:4] = bytes([0x12, 0x34, 0x56, 0x78])
        sensor.mem[0x0F] = 0x33
        sensor_task = cocotb.start_soon(sensor.run())
        img, sym, _ = prog("i2c_sniff.setl")
        await host.load_image(img)
        await host.config_lane(0, start=sym["i2c_sniff"], msb=True)
        await host.run(1)
        capture = []
        sniffing = True
        peak = 0

        async def drain():
            nonlocal peak
            while sniffing:
                await service_delay()
                n = (await host.status(0))["rx"]
                peak = max(peak, n)
                if n:
                    capture.extend(await host.pop(0, n))
        drainer = cocotb.start_soon(drain())
        await ClockCycles(dut.clk, rng.randint(0, 31))      # bus phase vs. the barrel
        real = await mcu_session(mcu)
        await ClockCycles(dut.clk, 2000)
        sniffing = False
        await drainer
        n = (await host.status(0))["rx"]
        capture.extend(await host.pop(0, n))
        assert (await host.status(0))["ovf"] == 0, f"capture overflowed (peak RX level {peak})"
        dut._log.info(f"capture: {learn.pairs(capture)}")
        dev, report = learn.learn(capture)
        dut._log.info(f"learned: {report}; peak RX level {peak}/{isa.FIFO_DEPTH}")
        assert report["address"] == 0x50
        assert {k: report["registers"][k] for k in (0, 1, 2, 3, 0x0F, 0x10, 0x11)} == \
            {0: 0x12, 1: 0x34, 2: 0x56, 3: 0x78, 0x0F: 0x33, 0x10: 0x5A, 0x11: 0x5B}

        # held-out answers, recorded from the real sensor (not shown to the learner)
        await host.run(0)
        snapshot = bytes(sensor.mem)
        golden = await heldout_session(mcu)
        sensor.mem[:] = snapshot                             # undo the held-out write

        # ---- phase B: sensor unplugged, SETL reprogrammed to impersonate it ----
        sensor_task.cancel()
        h.release("sensor")
        img, sym, _ = prog("i2c_target_host.setl")
        await host.load_image(img)
        await host.config_lane(0, start=sym["i2c_target_host"], msb=True,
                               outmap=[("uio1", "od"), ("uio0", "od")], match=0x50 << 1, mask=0xFE)
        await host.run(1)
        serving = True

        def server_for(imp):
            pending = []

            async def serve():
                while serving:
                    await service_delay()
                    n = (await host.status(0))["rx"]
                    if n:
                        pending.extend(await host.pop(0, n))
                        k = len(pending) & ~1
                        replies = imp.handle(pending[:k])
                        del pending[:k]
                        if replies:
                            await host.push(0, replies)
            return serve()
        server = cocotb.start_soon(server_for(learn.Impersonator(dev)))
        await ClockCycles(dut.clk, rng.randint(0, 31))
        fake = await mcu_session(mcu)
        assert fake == real, (fake, real)
        # an independent controller (other timing, other jitter) runs the held-out session
        other = bfm.I2cController(h, scl=0, sda=1, half=half + rng.randint(0, half // 2),
                                  who="mcu2", jitter=2 * jit + 3, rng=random.Random(seed ^ 0x5A5A))
        fake2 = await heldout_session(other)
        serving = False
        await server
        assert fake2 == golden, (fake2, golden)
        assert mcu.stretched + other.stretched > 0, "the target never needed to stretch"
        dut._log.info(f"impersonation ok: training {fake}, held-out {fake2}; "
                      f"SCL stretched {mcu.stretched + other.stretched} clocks")
    h.check()


@cocotb.test()
async def test_modbus_crc(dut):
    """MODBUS RTU: lane 0 appends CRC-16 on chip, lane 1 receives it through the
    on-chip readback and checks the CRC, lane 2 receives a corrupted frame from
    the testbench and flags the CRC error."""
    h, host = await setup(dut)
    with open(os.path.join(PROG, "modbus_tx.setl")) as f:
        tx_img, tx_sym, _ = assemble(f.read())
    with open(os.path.join(PROG, "modbus_rx.setl")) as f:
        rx_src = f.read()
    rx1_img, rx1_sym, _ = assemble(".org 16\n" + rx_src.replace(".pin rx ui0", ".pin rx uo0"))
    rx2_img, rx2_sym, _ = assemble(".org 32\n" + rx_src)
    await host.load_image({**tx_img, **rx1_img, **rx2_img})
    await host.set_mode4(True)
    bit = 64                                   # ticks/bit, 4-lane barrel -> 256 clocks (~234 kbaud)
    tbv = round(1.5 * bit) - 2
    rx_ctrl = isa.CTRL_CRC | isa.CTRL_CRC_IN
    await host.config_lane(0, start=tx_sym["modbus_tx"], ta=bit - 1, outmap=["uo0"], ctrl=isa.CTRL_CRC)
    await host.config_lane(1, start=rx1_sym["modbus_rx"], ta=bit - 1, tb=tbv, ctrl=rx_ctrl)
    await host.config_lane(2, start=rx2_sym["modbus_rx"], ta=bit - 1, tb=tbv, ctrl=rx_ctrl)
    for lane in range(3):
        await host.config_crc(lane, poly=0xA001, init=0xFFFF, residue=0)
    h.set_ui(0, 1)
    frame = [0x01, 0x03, 0x00, 0x00, 0x00, 0x0A]
    # a frame ends when the TX FIFO runs dry, so preload it and top it up at once
    await host.push(0, frame[:4])
    got = {1: [], 2: []}
    draining = True

    async def drain():                         # the host empties both RX FIFOs continuously
        while draining:
            for lane in (1, 2):
                n = (await host.status(lane))["rx"]
                if n:
                    got[lane] += list(await host.pop(lane, n))
    rx = cocotb.start_soon(bfm.uart_recv(dut.clk, lambda: h.uo_level(0), 4 * bit, 8))
    drainer = cocotb.start_soon(drain())
    await host.run(0b0111)
    await feed(host, 0, frame[4:])
    wire = await rx
    assert wire == frame + [0xC5, 0xCD], [hex(x) for x in wire]
    await ClockCycles(dut.clk, 4 * bit * 40)   # inter-frame silence: lane 1 closes the frame
    assert got[1] == frame + [0xC5, 0xCD], [hex(x) for x in got[1]]
    assert (await host.status(1))["event"] == 0, "good frame flagged"
    # a corrupted frame into lane 2
    bad = frame + [0xC5, 0xCE]
    await bfm.uart_send(dut.clk, lambda v: h.set_ui(0, v), 4 * bit, bytes(bad))
    await ClockCycles(dut.clk, 4 * bit * 40)
    draining = False
    await drainer
    assert got[2] == bad, [hex(x) for x in got[2]]
    assert (await host.status(2))["event"] == 1, "bad CRC not flagged"
    h.check()


async def feed_batch(host, lane, data):
    """Keep a TX FIFO topped up, several bytes per SPI transaction."""
    data = list(data)
    while data:
        room = isa.FIFO_DEPTH - (await host.status(lane))["tx"]
        if room:
            await host.push(lane, data[:room])
            del data[:room]


@cocotb.test(skip=SMALL_MEM)
async def test_usb_ls_tx(dut):
    """USB low-speed packets generated entirely on chip: SYNC, NRZI, bit stuffing,
    CRC-16 (sent complemented) and EOP.  The program is generated (181 records:
    it needs the SRAM).  DIV=1 here so the simulated host keeps up; with DIV=0 at
    60 MHz the bit time is exactly 1.5 Mb/s."""
    h, host = await setup(dut)
    with open(os.path.join(PROG, "usb_ls_tx.setl")) as f:
        img, sym, _ = assemble(f.read())
    await host.load_image(img)
    await host.config_lane(0, start=sym["usb_ls_tx"], ta=13, tb=14, div=1,
                           outmap=["uo0", "uo1"], outinit=0b0010,     # J: D+ low, D- high
                           ctrl=isa.CTRL_CRC | (6 << 4))
    await host.config_crc(0, poly=0xA001, init=0xFFFF)
    await host.run(1)
    period = 20 * 2 * 2                           # 20 ticks/bit, 2-lane barrel, DIV=1
    PID = lambda p: p | ((~p & 0xF) << 4)
    # SETUP data packet (DATA0) with a GET_DESCRIPTOR request: has stuffing-prone 0xFF bytes too
    data = [0x80, 0x06, 0x00, 0x01, 0xFF, 0xFF, 0x40, 0x00]
    cases = [
        (PID(0x3), data, False),                  # DATA0 + 8 bytes
        (PID(0x2), [], True),                     # ACK handshake: no data, no CRC
        (PID(0xB), [], False),                    # DATA1, empty data field: CRC only
    ]
    for pid, payload, handshake in cases:
        await host.write_reg(isa.G_HFLAG, 1 if handshake else 0)
        cap = cocotb.start_soon(bfm.usb_ls_capture(h, dp=0, dm=1, period=period))
        await feed_batch(host, 0, [pid] + payload)
        pkt, problems = await cap
        assert not problems, problems
        expect = [pid] + payload
        if not handshake:
            crc = bfm.usb_crc16(payload)
            expect += [crc & 0xFF, crc >> 8]
        assert pkt == expect, ([hex(x) for x in pkt], [hex(x) for x in expect])
        await ClockCycles(dut.clk, 4 * period)
    h.check()


@cocotb.test(skip=SMALL_MEM)
async def test_usb_ls_loopback(dut):
    """Lane 0 transmits USB low-speed packets; lane 1 receives them through the
    on-chip readback with clock recovery, NRZI decoding, un-stuffing and a CRC
    check -- a USB LS PHY + framing in two programs (268 records, needs the SRAM)."""
    h, host = await setup(dut)
    with open(os.path.join(PROG, "usb_ls_tx.setl")) as f:
        tx_img, tx_sym, _ = assemble(f.read())
    with open(os.path.join(PROG, "usb_ls_rx.setl")) as f:
        rx_img, rx_sym, _ = assemble(".org 256\n" + f.read())
    await host.load_image({**tx_img, **rx_img})
    usb = 6 << 4
    await host.config_lane(0, start=tx_sym["usb_ls_tx"], ta=13, tb=14, div=1,
                           outmap=["uo0", "uo1"], outinit=0b0010, ctrl=isa.CTRL_CRC | usb)
    await host.config_lane(1, start=rx_sym["usb_ls_rx"], ta=15, tb=8, div=1,
                           ctrl=isa.CTRL_CRC | isa.CTRL_CRC_IN | usb)
    await host.config_crc(0, poly=0xA001, init=0xFFFF)
    await host.config_crc(1, poly=0xA001, init=0xFFFF, residue=0xB001)
    await host.run(0b11)
    got = []
    draining = True

    async def drain():
        while draining:
            n = (await host.status(1))["rx"]
            if n:
                got.extend(await host.pop(1, n))
    drainer = cocotb.start_soon(drain())
    PID = lambda p: p | ((~p & 0xF) << 4)
    data = [0x80, 0x06, 0x00, 0x01, 0xFF, 0xFF, 0x40, 0x00]
    for pid, payload, hs in ((PID(0x3), data, False), (PID(0x2), [], True), (PID(0xB), [0x5A], False)):
        await host.write_reg(isa.G_HFLAG, 1 if hs else 0)
        got.clear()
        await feed_batch(host, 0, [pid] + payload)
        await ClockCycles(dut.clk, 80 * (8 * (len(payload) + 4) + 12))
        expect = [0x80, pid] + payload
        if not hs:
            crc = bfm.usb_crc16(payload)
            expect += [crc & 0xFF, crc >> 8]
        for _ in range(20):           # let the drainer finish its last pop
            if len(got) >= len(expect):
                break
            await ClockCycles(dut.clk, 500)
        if got != expect:
            dut._log.error(f"usb rx got {[hex(x) for x in got]} expected {[hex(x) for x in expect]}")
        assert got == expect
        assert (await host.status(1))["event"] == 0, "receiver reported a CRC error"
    draining = False
    await drainer
    h.check()


@cocotb.test(skip=SMALL_MEM)
async def test_can_tx(dut):
    """CAN 2.0A data frames: stuffing after five identical bits, CRC-15, ACK slot,
    all generated on chip (89 records, needs the SRAM).  An independent real-time
    receiver checks the bit grid, de-stuffs, checks the CRC and drives the ACK."""
    from setl import can
    h, host = await setup(dut)
    with open(os.path.join(PROG, "can_tx.setl")) as f:
        img, sym, _ = assemble(f.read())
    await host.load_image(img)
    BIT = 60                                    # ticks per bit: 500 kbit/s at 60 MHz
    await host.config_lane(0, start=sym["can_tx"], ta=BIT - 5, tb=BIT - 4, msb=True,
                           outmap=["uo0"], outinit=0xF,
                           ctrl=isa.CTRL_CRC | isa.CTRL_CRC_LEFT | isa.CTRL_RUN_ANY | (5 << 4))
    await host.config_crc(0, poly=0x4599 << 1, init=0)
    h.set_ui(0, 1)
    await host.run(1)
    period = 2 * BIT
    # 0x0F0 and 0x00 / 0xFF data force long runs, so stuffing happens in the ID and the data
    for ident, data, ack in ((0x0F0, [0x00, 0xFF], True), (0x7FF, [], True), (0x123, [0x55], False)):
        await host.clear_event(0)
        rx = cocotb.start_soon(bfm.can_receive(h, tx_uo=0, rx_ui=0, period=period, ack=ack))
        await feed_batch(host, 0, can.frame(ident, data))
        fields, problems = await rx
        assert not problems, problems
        assert fields["sof"] == 0 and fields["id"] == ident and fields["dlc"] == len(data)
        assert fields["data"] == data, fields
        assert fields["crc"] == can.crc15(fields["body"]), (hex(fields["crc"]), hex(can.crc15(fields["body"])))
        await ClockCycles(dut.clk, 6 * period)
        assert (await host.status(0))["event"] == (0 if ack else 1), "ACK reporting wrong"
    h.check()


@cocotb.test()
async def test_swd_read_dpidr(dut):
    """SWD: line reset, JTAG-to-SWD switch, line reset, DPIDR read with ACK and parity,
    against an independent SWD target model on an open-drain SWDIO."""
    from setl import swd
    h, host = await setup(dut)
    img, sym, _ = prog("swd.setl")
    await host.load_image(img)
    await host.config_lane(0, start=sym["swd"], ta=3, msb=True,
                           outmap=["uo2", ("uio1", "od")], outinit=0b0010)
    tgt = bfm.SwdTarget(h, swclk_uo=2, swdio_uio=1, dpidr=0x2BA01477)
    cocotb.start_soon(tgt.run())
    await host.run(1)
    cyc = swd.line_reset() + swd.drive(swd.JTAG_TO_SWD) + swd.line_reset() + swd.drive([0, 0])
    rd, ack_at = swd.read_sequence(0, 0)
    ack_at += len(cyc)
    cyc += rd + swd.drive([0, 0])
    txb = swd.pack(cyc)
    rx = []
    for i in range(0, len(txb), 4):
        await host.push(0, txb[i:i + 4])
        await ClockCycles(dut.clk, 4 * 4 * 16 * 2 + 150)
        n = (await host.status(0))["rx"]
        rx += list(await host.pop(0, n))
    bits = swd.unpack(rx, len(cyc))
    ack, data, parity = swd.parse_read(bits, ack_at)
    assert not tgt.errors, tgt.errors
    assert ack == 0b001, f"ACK {ack:03b}"
    assert data == 0x2BA01477, hex(data)
    assert parity == bin(data).count("1") & 1
    h.check()


@cocotb.test()
async def test_manchester(dut):
    """The tutorial's protocol (docs/TUTORIAL.md): Manchester line coding, checked
    by a decoder that also requires every edge on the half-bit grid."""
    h, host = await setup(dut)
    img, sym, _ = prog("manchester_tx.setl")
    await host.load_image(img)
    TA = 7                                        # half bit = 8 ticks = 16 clocks
    await host.config_lane(0, start=sym["manchester_tx"], ta=TA, tb=TA - 3, msb=True,
                           outmap=["uo0"], outinit=0)
    data = [0xA5, 0x00, 0xFF]
    await host.push(0, data)
    half = 2 * (TA + 1)
    trace = []
    await host.run(1)
    for _ in range(half * 2 * 8 * len(data) + 400):
        await RisingEdge(dut.clk)
        trace.append((int(dut.uo_out.value) >> 0) & 1)
    # the first bit starts at the first sample where the line leaves idle-low or,
    # for a leading 1 (low first half), half a bit before the first rise
    first_rise = trace.index(1)
    start = first_rise - half if data[0] & 0x80 else first_rise
    bits = []
    for k in range(8 * len(data)):
        a = trace[start + 2 * k * half + half // 2]
        b = trace[start + 2 * k * half + half + half // 2]
        assert a != b, f"bit {k}: no mid-bit transition"
        bits.append(1 if (a, b) == (0, 1) else 0)
        for j in range(1, 2 * half):            # no edges except on the half-bit grid
            i = start + 2 * k * half + j
            if j != half and j != 2 * half:
                assert trace[i] == trace[i - 1] or j % half == 0, f"bit {k}: edge off grid"
    got = [int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8)]
    assert got == data, [hex(x) for x in got]
    h.check()


@cocotb.test()
async def test_host_write_while_lanes_busy(dut):
    """Review reproduction: both lanes change state on every tick, so no clock is
    free for the host.  A program write must not be lost silently: the chip
    flags it and the driver raises.  With the lanes stopped the same write lands."""
    from setl.host import HostError
    h, host = await setup(dut)
    busy, sym, _ = assemble("""
        .lane busy0
        a0: goto b0
        b0: goto a0
        .org 8
        .lane busy1
        a1: goto b1
        b1: goto a1
    """)
    await host.load_image(busy)
    abcd = {40: int.from_bytes(b"ABCDABCD", "big")}
    wxyz = {40: int.from_bytes(b"WXYZWXYZ", "big")}
    await host.load_image(abcd)
    await host.config_lane(0, start=sym["busy0"])
    await host.config_lane(1, start=sym["busy1"])
    await host.run(0b11)
    await ClockCycles(dut.clk, 50)
    raised = False
    try:
        await host.load_image(wxyz)
    except HostError:
        raised = True
    assert raised, "a lost program write was not reported"
    await host.run(0)
    await ClockCycles(dut.clk, 10)
    await host.load_image(wxyz)                   # lanes stopped: must land, no error
    assert await host.read_word(40) == wxyz[40]
    assert await host.read_reg(isa.G_HOSTERR) == 0
    h.check()


@cocotb.test()
async def test_host_single_byte_while_lanes_busy(dut):
    """A one-byte write that never gets a free clock is reported too (live pending bit)."""
    from setl.host import HostError
    h, host = await setup(dut)
    busy, sym, _ = assemble("a0: goto b0\nb0: goto a0\n.org 8\na1: goto b1\nb1: goto a1\n")
    await host.load_image(busy)
    await host.config_lane(0, start=sym["a0"])
    await host.config_lane(1, start=sym["a1"])
    await host.run(0b11)
    await ClockCycles(dut.clk, 50)
    await host.write_mem(40 * 8, [0x55])
    e = await host.read_reg(isa.G_HOSTERR)
    assert e & 4, f"pending single-byte write not visible (HOSTERR={e:#x})"
    await host.run(0)
    await ClockCycles(dut.clk, 10)
    assert (await host.read_reg(isa.G_HOSTERR)) & 4 == 0, "write did not complete once lanes stopped"
    assert (await host.read_mem(40 * 8, 1))[0] == 0x55
    h.check()
