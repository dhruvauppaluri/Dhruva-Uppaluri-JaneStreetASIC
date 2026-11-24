"""Independent protocol models (they know nothing about SETL programs)."""
from cocotb.triggers import ClockCycles, RisingEdge


async def uart_recv(clk, get_bit, bit_cycles, n, timeout=200000):
    out = []
    waited = 0
    for _ in range(n):
        while get_bit() == 1:
            await RisingEdge(clk)
            waited += 1
            assert waited < timeout, "UART receive timeout"
        await ClockCycles(clk, bit_cycles // 2)
        assert get_bit() == 0, "UART start bit glitch"
        v = 0
        for i in range(8):
            await ClockCycles(clk, bit_cycles)
            v |= get_bit() << i
        await ClockCycles(clk, bit_cycles)
        assert get_bit() == 1, "UART framing error (stop bit low)"
        out.append(v)
    return out


async def uart_send(clk, set_bit, bit_cycles, data, stop_bits=1):
    for b in data:
        set_bit(0)
        await ClockCycles(clk, bit_cycles)
        for i in range(8):
            set_bit((b >> i) & 1)
            await ClockCycles(clk, bit_cycles)
        set_bit(1)
        await ClockCycles(clk, bit_cycles * stop_bits)


class SpiTarget:
    """SPI target for any mode.  Records MOSI bytes, answers from `responses`."""

    def __init__(self, h, sck, mosi, cs, miso_ui, cpol, cpha, responses):
        self.h, self.sck, self.mosi, self.cs, self.miso = h, sck, mosi, cs, miso_ui
        self.cpol, self.cpha = cpol, cpha
        self.responses = list(responses)
        self.received = []
        self.frames = 0

    def _next(self):
        return self.responses.pop(0) if self.responses else 0xFF

    async def run(self):
        h = self.h
        clk = h.dut.clk
        prev_sck, prev_cs = self.cpol, 1
        rx = nrx = 0
        cur = 0
        oidx = 0
        while True:
            await RisingEdge(clk)
            uo = int(h.dut.uo_out.value)
            sck = (uo >> self.sck) & 1
            cs = (uo >> self.cs) & 1
            mosi = (uo >> self.mosi) & 1
            if prev_cs == 1 and cs == 0:
                self.frames += 1
                rx = nrx = 0
                if self.cpha == 0:
                    cur, oidx = self._next(), 0
                    h.set_ui(self.miso, cur >> 7)
                else:
                    oidx = -1
            elif cs == 0 and sck != prev_sck:
                leading = sck != self.cpol
                sample = leading if self.cpha == 0 else not leading
                if sample:
                    rx = ((rx << 1) | mosi) & 0xFF
                    nrx += 1
                    if nrx == 8:
                        self.received.append(rx)
                        rx = nrx = 0
                else:
                    if self.cpha == 0:
                        oidx += 1
                        if oidx == 8:
                            cur, oidx = self._next(), 0
                    else:
                        if oidx in (-1, 7):
                            cur, oidx = self._next(), 0
                        else:
                            oidx += 1
                    h.set_ui(self.miso, (cur >> (7 - oidx)) & 1)
            prev_sck, prev_cs = sck, cs


class I2cTarget:
    """Byte-addressed EEPROM-style I2C target (write: [ptr, data...]; read from ptr)."""

    def __init__(self, h, scl, sda, addr=0x50, size=256, stretch=0):
        self.h, self.scl, self.sda, self.addr = h, scl, sda, addr
        self.mem = bytearray(size)
        self.stretch = stretch
        self.log = []

    async def run(self):
        h = self.h
        clk = h.dut.clk
        st = "idle"
        prev_scl = prev_sda = 1
        sh = bitn = 0
        first = reading = have_ptr = host_ack = False
        ptr = 0
        cur = 0
        stretch_left = 0
        while True:
            await RisingEdge(clk)
            v = int(h.dut.uio_in.value)
            scl, sda = (v >> self.scl) & 1, (v >> self.sda) & 1
            if stretch_left:
                stretch_left -= 1
                if stretch_left == 0:
                    h.set_ext(self.scl, 1)
            if prev_scl and scl and prev_sda != sda:
                if sda == 0:
                    st, sh, bitn, first, have_ptr = "rx", 0, 0, True, False
                    self.log.append("S")
                else:
                    st = "idle"
                    self.log.append("P")
                h.set_ext(self.sda, 1)
            elif not prev_scl and scl:
                if st == "rx":
                    sh = ((sh << 1) | sda) & 0xFF
                    bitn += 1
                elif st == "txack":
                    host_ack = sda == 0
            elif prev_scl and not scl:
                if st == "rx" and bitn == 8:
                    ack = True
                    if first:
                        first = False
                        if (sh >> 1) != self.addr:
                            ack = False
                        reading = bool(sh & 1)
                        self.log.append(("A", sh))
                    elif not have_ptr:
                        ptr, have_ptr = sh, True
                        self.log.append(("W", sh))
                    else:
                        self.mem[ptr % len(self.mem)] = sh
                        ptr += 1
                        self.log.append(("W", sh))
                    if ack:
                        h.set_ext(self.sda, 0)
                        st = "ack"
                    else:
                        st = "idle"
                elif st == "ack":
                    if self.stretch:
                        h.set_ext(self.scl, 0)
                        stretch_left = self.stretch
                    if reading:
                        cur = self.mem[ptr % len(self.mem)]
                        ptr += 1
                        self.log.append(("R", cur))
                        st, bitn = "tx", 0
                        h.set_ext(self.sda, cur >> 7)
                    else:
                        h.set_ext(self.sda, 1)
                        st, sh, bitn = "rx", 0, 0
                elif st == "tx":
                    bitn += 1
                    if bitn < 8:
                        h.set_ext(self.sda, (cur >> (7 - bitn)) & 1)
                    else:
                        h.set_ext(self.sda, 1)
                        st = "txack"
                elif st == "txack":
                    if host_ack:
                        cur = self.mem[ptr % len(self.mem)]
                        ptr += 1
                        self.log.append(("R", cur))
                        st, bitn = "tx", 0
                        h.set_ext(self.sda, cur >> 7)
                    else:
                        st = "idle"
            prev_scl, prev_sda = scl, sda
