"""UART TX at 115200 baud on uo0."""
import board

c = board.chip()
c.run(0)
sym = board.load(c, "uart_tx")
c.config_lane(0, start=sym["uart_tx"], ta=board.ticks(1 / 115200) - 1, outmap=["uo0"])
c.run(1)
for ch in b"hello from SETL\r\n":
    while c.status(0)["tx"] == 4:
        pass
    c.push(0, [ch])
