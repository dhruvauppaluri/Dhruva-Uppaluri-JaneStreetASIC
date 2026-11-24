"""MicroPython transport for driving SETL from the demo board's RP2350.

    from setl.rp2350 import PinSpi
    from setl.host import Setl
    spi = PinSpi(sck=GP_UI7, mosi=GP_UI6, cs=GP_UI5, miso=GP_UO7)
    chip = Setl(spi.xfer)
    assert chip.read_reg(0x82) == 0x5E

The GPIO numbers are those of the RP2350 pins wired to the project's ui[7],
ui[6], ui[5] and uo[7] on the Tiny Tapeout demo board.  Take them from the
board documentation or the board SDK's pin map.  The project clock must run
at least 16x faster than SCK: this bit-banged SPI is far slower than that.

Assemble programs on a PC (`python -m setl.asm prog.setl -o prog.json`); the
board only loads the image: `chip.load_image({int(a): int(w, 16) for a, w in
json["image"].items()})`.  The design loses its program when it is deselected,
so reload after selecting it.
"""
try:
    from machine import Pin
except ImportError:          # allows importing on a PC for documentation/tests
    Pin = None


class PinSpi:
    """SPI mode 0, MSB first, one CS-framed transaction per xfer()."""

    def __init__(self, sck, mosi, cs, miso):
        self.sck = Pin(sck, Pin.OUT, value=0)
        self.mosi = Pin(mosi, Pin.OUT, value=0)
        self.cs = Pin(cs, Pin.OUT, value=1)
        self.miso = Pin(miso, Pin.IN)

    def xfer(self, data):
        sck, mosi, miso = self.sck, self.mosi, self.miso
        out = bytearray(len(data))
        self.cs.value(0)
        for i, byte in enumerate(data):
            r = 0
            for bit in range(7, -1, -1):
                mosi.value((byte >> bit) & 1)
                r = (r << 1) | miso.value()      # MISO is valid before the rising edge
                sck.value(1)
                sck.value(0)
            out[i] = r
        self.cs.value(1)
        return bytes(out)
