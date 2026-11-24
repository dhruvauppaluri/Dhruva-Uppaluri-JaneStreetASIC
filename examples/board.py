"""Board glue: the chip's host SPI port on the RP2350.  Fill in the GPIO numbers."""
import json

from setl.host import Setl
from setl.rp2350 import PinSpi

GP_SCK, GP_MOSI, GP_CS, GP_MISO = None, None, None, None   # RP2350 GPIOs for ui7, ui6, ui5, uo7
CLK_HZ = 50_000_000                                        # the project clock you configured


def chip():
    if None in (GP_SCK, GP_MOSI, GP_CS, GP_MISO):
        raise RuntimeError("set the GPIO numbers in board.py")
    c = Setl(PinSpi(GP_SCK, GP_MOSI, GP_CS, GP_MISO).xfer)
    if c.read_reg(0x82) != 0x5E:
        raise RuntimeError("SETL not answering (design selected? clock running?)")
    return c


def load(c, name):
    with open(name + ".json") as f:
        return c.load_json(json.load(f))


def ticks(seconds, lanes=2, div=0):
    return int(seconds * CLK_HZ / (lanes * (div + 1)) + 0.5)
