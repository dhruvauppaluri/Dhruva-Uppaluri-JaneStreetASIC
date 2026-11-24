"""Scan the I2C bus (SCL uio0, SDA uio1, pull-ups required) at 100 kHz."""
import board

c = board.chip()
c.run(0)
sym = board.load(c, "i2c_ctrl")
q = board.ticks(1 / 400_000)                 # quarter period of 100 kHz
c.config_lane(0, start=sym["i2c"], ta=2 * q - 1, tb=q - 1, msb=True,
              outmap=[("uio0", "od"), ("uio1", "od")], match=0x01, mask=0x01)
c.run(1)
found = []
for addr in range(0x08, 0x78):
    c.clear_event(0)
    c.push(0, [addr << 1])                   # address only: ACK or NACK, then STOP
    while c.status(0)["tx"] or c.read_reg(0x8C) != 0:   # until back in i_idle (pc 0)
        pass
    if not c.status(0)["event"]:
        found.append(addr)
print("I2C devices:", [hex(a) for a in found])
