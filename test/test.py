# SPDX-License-Identifier: MIT

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


async def clock_edge(dut):
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")


async def load_word(dut, word):
    for bit_index in range(15, -1, -1):
        dut.ui_in.value = (int(dut.ui_in.value) & ~0x07) | ((word >> bit_index) & 1) | 0x02
        await clock_edge(dut)
        dut.ui_in.value = int(dut.ui_in.value) & ~0x02

    dut.ui_in.value = int(dut.ui_in.value) | 0x04
    await clock_edge(dut)
    dut.ui_in.value = int(dut.ui_in.value) & ~0x04
    await clock_edge(dut)


@cocotb.test()
async def serial_load_and_execute(dut):
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    for _ in range(3):
        await clock_edge(dut)
    dut.rst_n.value = 1

    for word in [0x20FF, 0x10A5, 0x3002, 0x105A, 0xF000]:
        await load_word(dut, word)

    # Restart the loader address, select the classifier target, and load
    # weights for score = 4*pin0_edges - pin0_high_cycles - 8.
    dut.ui_in.value = int(dut.ui_in.value) | 0x20
    await clock_edge(dut)
    dut.ui_in.value = (int(dut.ui_in.value) & ~0x20) | 0x10
    for word in [0x0004, 0x00FF, 0x0000, 0x0000, 0xFFF8]:
        await load_word(dut, word)

    dut.ui_in.value = (int(dut.ui_in.value) & ~0x10) | 0x08

    await clock_edge(dut)
    assert int(dut.uio_oe.value) == 0xFF
    assert int(dut.uo_out.value) & 0x1F == 1

    await clock_edge(dut)
    assert int(dut.uio_out.value) == 0xA5

    await clock_edge(dut)
    assert int(dut.uo_out.value) & 0x40

    await clock_edge(dut)
    assert int(dut.uio_out.value) == 0xA5
    await clock_edge(dut)
    assert not (int(dut.uo_out.value) & 0x40)

    await clock_edge(dut)
    assert int(dut.uio_out.value) == 0x5A
    await clock_edge(dut)
    assert int(dut.uo_out.value) & 0x20

    # Complete the first idle window and its four scoring cycles.
    for _ in range(25 + 4):
        await clock_edge(dut)
    assert not (int(dut.uo_out.value) & 0x80)

    # Align to a new feature window, then toggle pin zero every clock.
    for _ in range(28):
        await clock_edge(dut)
    for _ in range(32):
        dut.uio_in.value = int(dut.uio_in.value) ^ 0x01
        await clock_edge(dut)
    for _ in range(4):
        await clock_edge(dut)
    assert int(dut.uo_out.value) & 0x80
