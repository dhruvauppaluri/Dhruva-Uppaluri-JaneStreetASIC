"""SETL protocol tests.  Each test loads a program through the host SPI port,
then checks the pins against an independent protocol model (bfm.py).  On RTL
runs the golden model also runs in lockstep and every output is compared
every cycle.  These tests also run on the gate-level netlist (GATES=yes).
"""
import os

import cocotb
from cocotb.triggers import ClockCycles

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
        while (await host.status(lane))["tx"] == 4:
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


async def spi_controller(h, sck, mosi, cs, miso_uo, data, half):
    """Testbench SPI controller (mode 0, MSB first) bit-banging ui pins."""
    clk = h.dut.clk
    got = []
    h.set_ui(cs, 0)
    await ClockCycles(clk, 2 * half)
    for b in data:
        r = 0
        for i in range(7, -1, -1):
            h.set_ui(mosi, (b >> i) & 1)
            await ClockCycles(clk, half)
            r = (r << 1) | h.uo_level(miso_uo)
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


SMALL_MEM = os.environ.get("SETL_MEM") == "small" or os.environ.get("GATES") == "yes"


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


@cocotb.test()
async def test_learn_and_impersonate(dut):
    """Sniff an MCU talking to a sensor, learn the sensor on the host, unplug it,
    and let SETL impersonate it: the MCU sees the same answers."""
    from setl import learn
    h, host = await setup(dut)
    # 100 kHz I2C at a 60 MHz clock (300-clock half period), as on the real board
    mcu = bfm.I2cController(h, scl=0, sda=1, half=300, who="mcu")

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

    async def drain():
        while sniffing:
            n = (await host.status(0))["rx"]
            if n:
                capture.extend(await host.pop(0, n))
    drainer = cocotb.start_soon(drain())
    real = await mcu_session(mcu)
    await ClockCycles(dut.clk, 2000)
    sniffing = False
    await drainer
    n = (await host.status(0))["rx"]
    capture.extend(await host.pop(0, n))
    assert (await host.status(0))["ovf"] == 0, "capture overflowed"
    dev, report = learn.learn(capture)
    dut._log.info(f"learned: {report}")
    assert report["address"] == 0x50
    assert {k: report["registers"][k] for k in (0, 1, 2, 3, 0x0F, 0x10, 0x11)} == \
        {0: 0x12, 1: 0x34, 2: 0x56, 3: 0x78, 0x0F: 0x33, 0x10: 0x5A, 0x11: 0x5B}

    # ---- phase B: sensor unplugged, SETL reprogrammed to impersonate it ----
    sensor_task.cancel()
    h.release("sensor")
    await host.run(0)
    img, sym, _ = prog("i2c_target_host.setl")
    await host.load_image(img)
    await host.config_lane(0, start=sym["i2c_target_host"], msb=True,
                           outmap=[("uio1", "od"), ("uio0", "od")], match=0x50 << 1, mask=0xFE)
    await host.run(1)
    imp = learn.Impersonator(dev)
    serving = True
    pending = []

    async def serve():
        while serving:
            n = (await host.status(0))["rx"]
            if n:
                pending.extend(await host.pop(0, n))
                k = len(pending) & ~1
                replies = imp.handle(pending[:k])
                del pending[:k]
                if replies:
                    await host.push(0, replies)
    server = cocotb.start_soon(serve())
    fake = await mcu_session(mcu)
    serving = False
    await server
    assert fake == real, (fake, real)
    assert mcu.stretched > 0, "the target never needed to stretch"
    dut._log.info(f"impersonation: {fake}; SCL stretched for {mcu.stretched} clocks")
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
