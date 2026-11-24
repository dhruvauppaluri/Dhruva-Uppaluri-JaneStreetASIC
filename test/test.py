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
