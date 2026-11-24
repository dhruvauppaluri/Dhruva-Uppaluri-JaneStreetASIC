"""cocotb harness for SETL.

* All pin writes happen once per cycle on the falling clock edge.
* uio pins are a wired-AND bus: uio_in = (chip drives ? uio_out : 1) & ext,
  so open-drain (I2C) and push-pull external devices are both modelled.
* Optional lockstep co-simulation: every cycle the Python golden model is
  stepped with the same pin inputs and the host strobes observed inside the
  RTL, and all 24 outputs are compared.  (RTL only: needs internal signals.)
"""
import os
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, Lock, RisingEdge

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
from setl import isa, model  # noqa: E402
from setl.host import Setl  # noqa: E402

GATES = os.environ.get("GATES") == "yes"
CLK_NS = 16  # ~60 MHz (16.67 ns); integer ns keeps the simulator happy
HOST_HALF = 8  # host SCK half period in clocks (SCK = clk/16)


class Harness:
    def __init__(self, dut, cosim=None):
        self.dut = dut
        self.ui = 0          # lane-side ui bits [4:0] (and anything else a BFM sets)
        self.host_bits = 0x20  # ui[7]=SCK ui[6]=MOSI ui[5]=CSn (idle high)
        self.ext = 0xFF      # external drive on uio (1 = released/high)
        self.agents = {}     # extra open-drain drivers on the uio bus: name -> byte
        self.cosim = (not GATES) if cosim is None else (cosim and not GATES)
        self.model = model.Chip() if self.cosim else None
        self.mismatches = 0
        self.cycle = 0
        self.host = Setl(self._xfer_sync_unsupported)
        self.uo = 0
        self.uio_out = 0
        self.uio_oe = 0
        self.uio_in = 0xFF
        self.spi_lock = Lock()   # one host SPI transaction at a time

    def _xfer_sync_unsupported(self, data):
        raise RuntimeError("use 'await h.xfer(...)' / Host wrappers in cocotb")

    async def start(self):
        d = self.dut
        cocotb.start_soon(Clock(d.clk, CLK_NS, unit="ns").start())
        d.ena.value = 1
        d.ui_in.value = self.host_bits
        d.uio_in.value = 0xFF
        d.rst_n.value = 0
        await ClockCycles(d.clk, 5)
        await FallingEdge(d.clk)
        d.rst_n.value = 1
        self._task = cocotb.start_soon(self._loop())
        await ClockCycles(d.clk, 2)

    def stop(self):
        self._task.cancel()

    # ------------------------------------------------------------ pin loop
    async def _loop(self):
        d = self.dut
        up = None if GATES else d.user_project
        while True:
            await FallingEdge(d.clk)
            uo_s = str(d.uo_out.value)
            # uo[7] (MISO) may carry X while the host prefetches unwritten SRAM
            assert "x" not in uo_s[1:].lower(), f"X on lane outputs: {uo_s}"
            self.uo = int(uo_s.lower().replace("x", "0").replace("z", "0"), 2)
            self.uio_out = int(str(d.uio_out.value).lower().replace("x", "0"), 2)
            self.uio_oe = int(d.uio_oe.value)
            chip = (self.uio_out | ~self.uio_oe) & 0xFF
            ext = self.ext
            for a in self.agents.values():
                ext &= a
            uio_in = chip & ext
            ui = (self.ui & 0x1F) | (self.host_bits & 0xE0)
            self.uio_in = uio_in
            d.uio_in.value = uio_in
            d.ui_in.value = ui
            if self.cosim:
                self._cosim_step(up, ui, uio_in)
            self.cycle += 1

    def _cosim_step(self, up, ui, uio_in):
        m = self.model
        if self.cycle == 0:
            # the RTL has seen one clock edge since reset release: align the
            # model's free-running slot counter and input synchronisers
            m.slot = int(up.slot.value)
            m.s1 = int(up.s1.value)
            m.s2 = int(up.s2.value)
            m.uo_q = int(up.uo_q.value)
        muo, mout, moe = m.outputs()
        # uo[7] is host MISO (SPI shell, not modelled); compare only driven uio bits
        bad = ((muo ^ self.uo) & 0x7F) or moe != self.uio_oe or ((mout ^ self.uio_out) & moe)
        # internal lane state is compared too: divergence is caught at its source
        names = ("pc", "valid", "pending", "first", "timer", "cnt", "sr", "slot_val", "flag", "sw", "crc", "ones", "crc_hold", "run_bit")
        diff = []
        for i, L in enumerate(m.lanes):
            rl = up.g_lane[i].lane
            for n in names:
                rv = int(getattr(rl, n).value)
                mv = int(getattr(L, n))
                if rv != mv:
                    diff.append(f"lane{i}.{n} rtl={rv} model={mv}")
        if int(up.slot.value) != m.slot:
            diff.append(f"slot rtl={int(up.slot.value)} model={m.slot}")
        if bad or diff:
            self.mismatches += 1
            if self.mismatches <= 5:
                self.dut._log.error(
                    f"cycle {self.cycle}: uo rtl={self.uo:02x} model={muo:02x} "
                    f"uio_out rtl={self.uio_out:02x} model={mout:02x} "
                    f"oe rtl={self.uio_oe:02x} model={moe:02x} {' '.join(diff)}")
        if int(up.reg_we.value):
            m.write_reg(int(up.reg_waddr.value), int(up.reg_wdata.value))
        if int(up.reg_commit.value):
            ca = int(up.reg_caddr.value)
            if ca < 0x40 and (ca & 0xF) == 0xF:
                m.host_pop(ca >> 4)
        if int(up.hmem_gnt.value) and int(up.hmem_we.value):
            m.write_mem_byte(int(up.hmem_baddr.value), int(up.hmem_wbyte.value))
        m.step(ui, uio_in)

    # ------------------------------------------------------------ host SPI
    async def xfer(self, data):
        async with self.spi_lock:
            return await self._xfer(data)

    async def _xfer(self, data):
        d = self.dut
        out = []
        self.host_bits = 0x00  # CS low, SCK low
        await ClockCycles(d.clk, HOST_HALF)
        for byte in data:
            r = 0
            for bit in range(7, -1, -1):
                mosi = (byte >> bit) & 1
                self.host_bits = mosi << 6
                await ClockCycles(d.clk, HOST_HALF)
                r = (r << 1) | ((self.uo >> 7) & 1)
                self.host_bits = 0x80 | (mosi << 6)
                await ClockCycles(d.clk, HOST_HALF)
            self.host_bits = 0x00
            out.append(r)
        await ClockCycles(d.clk, HOST_HALF)
        self.host_bits = 0x20
        await ClockCycles(d.clk, HOST_HALF)
        return bytes(out)

    # ------------------------------------------------------------ helpers
    def set_ui(self, bit, val):
        self.ui = (self.ui & ~(1 << bit)) | ((val & 1) << bit)

    def set_ext(self, bit, val, who=None):
        """Drive (0) or release (1) a uio bit; `who` names a separate open-drain agent."""
        if who is None:
            self.ext = (self.ext & ~(1 << bit)) | ((val & 1) << bit)
        else:
            cur = self.agents.get(who, 0xFF)
            self.agents[who] = (cur & ~(1 << bit)) | ((val & 1) << bit)

    def release(self, who):
        self.agents.pop(who, None)

    def uio_level(self, bit):
        return (self.uio_in >> bit) & 1

    def uo_level(self, bit):
        return (self.uo >> bit) & 1

    async def cycles(self, n):
        await ClockCycles(self.dut.clk, n)

    def check(self):
        assert self.mismatches == 0, f"{self.mismatches} model/RTL mismatches"


class AHost:
    """Async wrapper running the synchronous Setl driver over the cocotb SPI."""

    def __init__(self, h):
        self.h = h

    def __getattr__(self, name):
        fn = getattr(Setl, name)

        async def call(*a, **kw):
            log = []

            def rec(data):
                log.append(bytes(data))
                return bytes(len(data))
            # First pass records the transactions; then we replay them for
            # real.  Read results come from the second pass.
            Setl(rec).__getattribute__(name)(*a, **kw)
            results = [await self.h.xfer(t) for t in log]
            it = iter(results)
            return fn(Setl(lambda data: next(it)), *a, **kw)
        return call
