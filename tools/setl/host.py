"""Host-side driver for SETL.

`Setl` turns high-level operations into SPI transactions.  The transport is
anything with `xfer(bytes) -> bytes` (one CS-framed transaction).  The same
code drives the cocotb testbench and real hardware (e.g. an RP2350 running
MicroPython/CPython with an SPI bridge).
"""
from . import isa

WREG, RREG, WMEM, RMEM = 0x00, 0x40, 0x80, 0xC0


class HostError(RuntimeError):
    """A program-memory access did not complete (see G_HOSTERR)."""
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
    def host_errors(self, clear=True):
        e = self.read_reg(isa.G_HOSTERR)
        if e & 3 and clear:
            self.write_reg(isa.G_HOSTERR, e & 3)
        return e

    def load_image(self, image, check=True):
        """Write {word_addr: 64-bit record} using one transaction per contiguous run.

        Lanes have priority on the record memory (that is what keeps their timing
        exact), so a write can only land in a clock where no lane fetches.  If the
        running lanes left no such clock, the chip flags it and this raises instead
        of returning as if the program had been loaded.  Stop the lanes (run(0))
        to load safely."""
        if check:
            self.host_errors()
        addrs = sorted(image)
        i = 0
        while i < len(addrs):
            j = i
            while j + 1 < len(addrs) and addrs[j + 1] == addrs[j] + 1:
                j += 1
            data = b"".join(image[a].to_bytes(8, "big") for a in addrs[i:j + 1])
            self.write_mem(addrs[i] * 8, data)
            i = j + 1
        if check:
            e = self.host_errors()
            if e:
                raise HostError(f"program memory write lost (HOSTERR={e:#x}): the running "
                                "lanes kept the memory busy; stop them with run(0) and reload")

    def load_json(self, obj, base=0):
        """Load an assembler JSON image (dict already parsed); returns the symbols.
        `base` relocates nothing: assemble with `.org` to place programs."""
        image = {int(a): int(w, 16) for a, w in obj["image"].items()}
        self.load_image(image)
        return obj["symbols"]

    def read_word(self, word_addr):
        return int.from_bytes(self.read_mem(word_addr * 8, 8), "big")

    # ---- lane configuration -------------------------------------------------
    def config_lane(self, lane, start, ta=0, tb=0, div=0, msb=False, outmap=(),
                    outinit=0xF, match=0, mask=0, ctrl=0):
        """outmap: up to 4 entries, each a pin name ('uo3', 'uio1') or a tuple
        (pin, 'od'|'pp'|'oe', invert) or None.  'oe' (uio pins only) is tri-state:
        the next slot (k+1) is the output enable."""
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
            if mode not in ("pp", "od", "oe"):
                raise ValueError(f"output mode must be 'pp', 'od' or 'oe', not {mode!r}")
            v = isa.omap_pin(pin)
            if mode == "od":
                v |= isa.OMAP_OD
            if mode == "oe":
                if not 8 <= v <= 15:
                    raise ValueError("tri-state ('oe') needs a uio pin: uo pins are always driven")
                v |= isa.OMAP_OE
            if inv:
                v |= isa.OMAP_INV
            om.append(v)
        base = lane * isa.LANE_STRIDE
        # idle levels first, so a pin never shows anything else once it is mapped
        self.write_reg(base + isa.R_OUTINIT, outinit)
        self.write_regs(base, [
            (ctrl & 0xFE) | (1 if msb else 0), start & 0xFF, start >> 8, div,
            ta & 0xFF, ta >> 8, tb & 0xFF, tb >> 8,
            *om, outinit, match, mask,
        ])

    def config_crc(self, lane, poly, init=0, residue=0, crc=None):
        """CRC/LFSR unit of a lane; enable it with ctrl=CTRL_CRC (| CTRL_CRC_IN | CTRL_CRC_LEFT)."""
        regs = [poly & 0xFF, poly >> 8, init & 0xFF, init >> 8, residue & 0xFF, residue >> 8]
        if crc is not None:
            regs += [crc & 0xFF, crc >> 8]
        self.write_regs(isa.G_CRC + 8 * lane, regs)

    def read_crc(self, lane):
        return int.from_bytes(self.read_regs(isa.G_CRC + 8 * lane + 6, 2), "little")

    def set_mode4(self, on):
        self.write_reg(isa.G_CTRL, 1 if on else 0)

    def run(self, mask):
        self.write_reg(isa.G_RUN, mask)

    def push(self, lane, data):
        self.write_regs(lane * isa.LANE_STRIDE + isa.R_FIFO, list(data), noinc=True)

    def status(self, lane):
        a, b = self.read_regs(isa.G_LEVEL + 2 * lane, 2)
        return {"tx": a & 31, "rx": b & 31, "event": (a >> 6) & 1, "ovf": a >> 7}

    def pop(self, lane, n):
        return self.read_regs(lane * isa.LANE_STRIDE + isa.R_FIFO, n, noinc=True)

    def clear_event(self, lane):
        self.write_reg(isa.G_STATUS + lane, 0xC0)


def ticks(clk_hz, lanes_mode4, div, seconds):
    """Lane ticks for a duration (float) at a clock / barrel configuration."""
    n = 4 if lanes_mode4 else 2
    return seconds * clk_hz / (n * (div + 1))
