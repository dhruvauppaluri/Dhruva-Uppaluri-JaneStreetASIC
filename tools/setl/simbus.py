"""A host transport backed by the golden model, for dry-running board scripts on a PC.

    from setl.simbus import ModelBus
    from setl.host import Setl
    bus = ModelBus(clk_hz=33_333_333)
    chip = Setl(bus.xfer)
    chip.read_reg(0x82)            # 0x5E
    bus.sleep_us(100)              # let the model run for 100 us

It decodes the host SPI command set (WREG/RREG/WMEM/RMEM) into model register
and memory accesses, and advances the model by the time each SPI byte takes
(8 SCK periods of `sck_div` clocks).  The pins outside the chip are a pull-up on
every uio line plus whatever `ui` and `ext` (open-drain pull-downs on uio) hold.

This is a convenience model of the host port, not the RTL: the RTL and its SPI
shell are what the cocotb tests check.  Use it to debug bring-up scripts before
they meet hardware.
"""
from . import isa, model


class ModelBus:
    def __init__(self, clk_hz=33_333_333, sck_div=16, chip=None):
        self.chip = chip or model.Chip()
        self.clk_hz = clk_hz
        self.byte_clocks = 8 * sck_div
        self.ui = 0
        self.ext = 0xFF          # external open-drain drivers on uio (0 = pulled low)
        self.shadow = {}         # register values as written (for readback)
        self.cycles = 0

    # ---- time ----------------------------------------------------------------
    def step(self, n=1):
        c = self.chip
        for _ in range(n):
            _, out, oe = c.outputs()
            uio = ((out | (~oe & 0xFF)) & self.ext) & 0xFF
            c.step(self.ui & 0x1F, uio)
            self.cycles += 1

    def sleep_us(self, us):
        self.step(max(1, int(us * self.clk_hz / 1e6)))

    def sleep_ms(self, ms):
        self.sleep_us(ms * 1000)

    def uio_level(self, bit):
        _, out, oe = self.chip.outputs()
        return (((out | (~oe & 0xFF)) & self.ext) >> bit) & 1

    def uo_level(self, bit):
        return (self.chip.outputs()[0] >> bit) & 1

    # ---- host port ---------------------------------------------------------------
    def _read(self, a):
        c = self.chip
        if a < 0x40:
            lane, r = a >> 4, a & 0xF
            if r == isa.R_FIFO:
                v = c.host_pop(lane)
                return v
            return self.shadow.get(a, 0)
        if a == isa.G_ID:
            return isa.CHIP_ID
        if a == isa.G_VERSION:
            return isa.CHIP_VERSION
        if a == isa.G_HOSTERR:
            return 0                       # the model never loses a host access
        if isa.G_STATUS <= a < isa.G_STATUS + 4:
            L = c.lanes[a - isa.G_STATUS]
            return (min(L.tx.level, 7) | (min(L.rx.level, 7) << 3)
                    | (L.event << 6) | (L.ovf << 7))
        if isa.G_LEVEL <= a < isa.G_LEVEL + 8:
            L = c.lanes[(a - isa.G_LEVEL) >> 1]
            if (a - isa.G_LEVEL) & 1:
                return L.rx.level
            return L.tx.level | (L.event << 6) | (L.ovf << 7)
        if a == isa.G_EVENTS:
            return (sum(L.event << L.idx for L in c.lanes)
                    | sum(L.flag << (4 + L.idx) for L in c.lanes))
        if isa.G_CRC <= a < isa.G_CRC + 32:
            L = c.lanes[(a - isa.G_CRC) >> 3]
            r = (a - isa.G_CRC) & 7
            v = [L.poly, L.crc_init, L.crc_res, L.crc][r >> 1]
            return (v >> (8 * (r & 1))) & 0xFF
        return self.shadow.get(a, 0)

    def xfer(self, data):
        data = bytes(data)
        out = bytearray(len(data))
        cmd = data[0] & 0xC0
        noinc = data[0] & 0x20
        self.step(self.byte_clocks)
        if cmd in (0x00, 0x40):
            if len(data) < 2:
                return bytes(out)
            a = data[1]
            self.step(self.byte_clocks)
            for i in range(2, len(data)):
                if cmd == 0x00:
                    self.chip.write_reg(a, data[i])
                    self.shadow[a] = data[i]
                else:
                    out[i] = self._read(a) & 0xFF
                self.step(self.byte_clocks)
                if not noinc:
                    a = (a + 1) & 0xFF
        else:
            if len(data) < 3:
                return bytes(out)
            ba = ((data[1] & 0xF) << 8) | data[2]
            self.step(self.byte_clocks)
            for i in range(3, len(data)):
                if cmd == 0x80:
                    self.chip.write_mem_byte(ba, data[i])
                else:
                    w = self.chip.mem[(ba >> 3) % isa.NWORDS]
                    out[i] = (w >> (8 * (7 - (ba & 7)))) & 0xFF
                self.step(self.byte_clocks)
                ba = (ba + 1) & 0xFFF
        return bytes(out)
