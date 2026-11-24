"""Host-side driver for SETL.

`Setl` turns high-level operations into SPI transactions.  The transport is
anything with `xfer(bytes) -> bytes` (one CS-framed transaction).  The same
code drives the cocotb testbench and real hardware (e.g. an RP2350 running
MicroPython/CPython with an SPI bridge).
"""
from . import isa

WREG, RREG, WMEM, RMEM = 0x00, 0x40, 0x80, 0xC0
NOINC = 0x20


class Setl:
    def __init__(self, xfer):
        self.xfer = xfer

    # ---- raw access -------------------------------------------------------
    def write_regs(self, addr, data, noinc=False):
        self.xfer(bytes([WREG | (NOINC if noinc else 0), addr]) + bytes(data))

    def read_regs(self, addr, n, noinc=False):
        r = self.xfer(bytes([RREG | (NOINC if noinc else 0), addr]) + bytes(n))
        return r[2:]

    def write_reg(self, addr, val):
        self.write_regs(addr, [val])

    def read_reg(self, addr):
        return self.read_regs(addr, 1)[0]

    def write_mem(self, byte_addr, data):
        self.xfer(bytes([WMEM, (byte_addr >> 8) & 0xF, byte_addr & 0xFF]) + bytes(data))

    def read_mem(self, byte_addr, n):
        r = self.xfer(bytes([RMEM, (byte_addr >> 8) & 0xF, byte_addr & 0xFF]) + bytes(n))
        return r[3:]

    # ---- program loading ---------------------------------------------------
    def load_image(self, image):
        """Write {word_addr: 64-bit record} using one transaction per contiguous run."""
        addrs = sorted(image)
        i = 0
        while i < len(addrs):
            j = i
            while j + 1 < len(addrs) and addrs[j + 1] == addrs[j] + 1:
                j += 1
            data = b"".join(image[a].to_bytes(8, "big") for a in addrs[i:j + 1])
            self.write_mem(addrs[i] * 8, data)
            i = j + 1

    def read_word(self, word_addr):
        return int.from_bytes(self.read_mem(word_addr * 8, 8), "big")

    # ---- lane configuration -------------------------------------------------
    def config_lane(self, lane, start, ta=0, tb=0, div=0, msb=False, outmap=(),
                    outinit=0xF, match=0, mask=0):
        """outmap: up to 4 entries, each a pin name ('uo3', 'uio1') or a tuple
        (pin, 'od'|'pp', invert) or None."""
        om = []
        for k in range(4):
            e = outmap[k] if k < len(outmap) else None
            if e is None:
                om.append(isa.OMAP_NONE)
                continue
            if isinstance(e, str):
                e = (e, "pp", False)
            e = list(e)
            pin = e[0]
            mode = e[1] if len(e) > 1 else "pp"
            inv = bool(e[2]) if len(e) > 2 else False
            if mode not in ("pp", "od"):
                raise ValueError(f"output mode must be 'pp' or 'od', not {mode!r}")
            v = isa.omap_pin(pin)
            if mode == "od":
                v |= isa.OMAP_OD
            if inv:
                v |= isa.OMAP_INV
            om.append(v)
        base = lane * isa.LANE_STRIDE
        # idle levels first, so a pin never shows anything else once it is mapped
        self.write_reg(base + isa.R_OUTINIT, outinit)
        self.write_regs(base, [
            1 if msb else 0, start & 0xFF, start >> 8, div,
            ta & 0xFF, ta >> 8, tb & 0xFF, tb >> 8,
            *om, outinit, match, mask,
        ])

    def set_mode4(self, on):
        self.write_reg(isa.G_CTRL, 1 if on else 0)

    def run(self, mask):
        self.write_reg(isa.G_RUN, mask)

    def push(self, lane, data):
        self.write_regs(lane * isa.LANE_STRIDE + isa.R_FIFO, list(data), noinc=True)

    def status(self, lane):
        s = self.read_reg(isa.G_STATUS + lane)
        return {"tx": s & 7, "rx": (s >> 3) & 7, "event": (s >> 6) & 1, "ovf": s >> 7}

    def pop(self, lane, n):
        return self.read_regs(lane * isa.LANE_STRIDE + isa.R_FIFO, n, noinc=True)

    def clear_event(self, lane):
        self.write_reg(isa.G_STATUS + lane, 0xC0)


def ticks(clk_hz, lanes_mode4, div, seconds):
    """Lane ticks for a duration (float) at a clock / barrel configuration."""
    n = 4 if lanes_mode4 else 2
    return seconds * clk_hz / (n * (div + 1))
