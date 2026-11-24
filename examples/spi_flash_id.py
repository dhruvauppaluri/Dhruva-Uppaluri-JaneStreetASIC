"""Read a SPI flash JEDEC ID: SCK uo2, MOSI uo3, CS_n uo4, MISO ui1 (mode 0, 1 MHz)."""
import board

c = board.chip()
c.run(0)
sym = board.load(c, "spi_ctrl")
c.config_lane(0, start=sym["spi_cpha0"], ta=board.ticks(0.5e-6) - 1, msb=True,
              outmap=["uo2", "uo3", "uo4"], outinit=0b1100)
c.run(1)
c.push(0, [0x9F, 0, 0, 0])                   # one CS frame: command + 3 reply bytes
while c.status(0)["rx"] < 4:
    pass
reply = c.pop(0, 4)
print("JEDEC ID: %02x %02x %02x" % (reply[1], reply[2], reply[3]))
