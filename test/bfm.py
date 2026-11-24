"""Independent protocol models (they know nothing about SETL programs)."""
from cocotb.triggers import ClockCycles, RisingEdge


async def uart_recv(clk, get_bit, bit_cycles, n, timeout=200000):
    out = []
    waited = 0
    for _ in range(n):
        while get_bit() == 1:
            await RisingEdge(clk)
            waited += 1
            assert waited < timeout, f"UART receive timeout after {[hex(x) for x in out]}"
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

    def __init__(self, h, scl, sda, addr=0x50, size=256, stretch=0, who=None):
        self.h, self.scl, self.sda, self.addr = h, scl, sda, addr
        self.who = who
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
                    h.set_ext(self.scl, who=self.who, val= 1)
            if prev_scl and scl and prev_sda != sda:
                if sda == 0:
                    st, sh, bitn, first, have_ptr = "rx", 0, 0, True, False
                    self.log.append("S")
                else:
                    st = "idle"
                    self.log.append("P")
                h.set_ext(self.sda, who=self.who, val= 1)
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
                        h.set_ext(self.sda, who=self.who, val= 0)
                        st = "ack"
                    else:
                        st = "idle"
                elif st == "ack":
                    if self.stretch:
                        h.set_ext(self.scl, who=self.who, val= 0)
                        stretch_left = self.stretch
                    if reading:
                        cur = self.mem[ptr % len(self.mem)]
                        ptr += 1
                        self.log.append(("R", cur))
                        st, bitn = "tx", 0
                        h.set_ext(self.sda, who=self.who, val= cur >> 7)
                    else:
                        h.set_ext(self.sda, who=self.who, val= 1)
                        st, sh, bitn = "rx", 0, 0
                elif st == "tx":
                    bitn += 1
                    if bitn < 8:
                        h.set_ext(self.sda, who=self.who, val= (cur >> (7 - bitn)) & 1)
                    else:
                        h.set_ext(self.sda, who=self.who, val= 1)
                        st = "txack"
                elif st == "txack":
                    if host_ack:
                        cur = self.mem[ptr % len(self.mem)]
                        ptr += 1
                        self.log.append(("R", cur))
                        st, bitn = "tx", 0
                        h.set_ext(self.sda, who=self.who, val= cur >> 7)
                    else:
                        st = "idle"
            prev_scl, prev_sda = scl, sda


class I2cController:
    """Bit-banged open-drain I2C controller driving the uio bus (ext bits)."""

    def __init__(self, h, scl, sda, half, who=None, jitter=0, rng=None):
        self.h, self.scl, self.sda, self.half = h, scl, sda, half
        self.who = who
        self.jitter, self.rng = jitter, rng   # each phase lasts half + U(0, jitter) clocks
        self.stretched = 0      # clocks a target held SCL low

    async def _w(self):
        extra = self.rng.randint(0, self.jitter) if self.jitter else 0
        await ClockCycles(self.h.dut.clk, self.half + extra)

    async def start(self):
        h = self.h
        h.set_ext(self.sda, who=self.who, val=1)
        h.set_ext(self.scl, who=self.who, val=1)
        await self._w()
        h.set_ext(self.sda, who=self.who, val=0)
        await self._w()
        h.set_ext(self.scl, who=self.who, val=0)
        await self._w()

    async def restart(self):
        h = self.h
        h.set_ext(self.sda, who=self.who, val=1)
        await self._w()
        await self.start()

    async def stop(self):
        h = self.h
        h.set_ext(self.sda, who=self.who, val=0)
        await self._w()
        h.set_ext(self.scl, who=self.who, val=1)
        await self._w()
        h.set_ext(self.sda, who=self.who, val=1)
        await self._w()

    async def _clock(self):
        """One SCL pulse; returns SDA sampled while SCL is high."""
        h = self.h
        h.set_ext(self.scl, who=self.who, val=1)
        await ClockCycles(h.dut.clk, 4)
        while not h.uio_level(self.scl):      # honour clock stretching
            await ClockCycles(h.dut.clk, 1)
            self.stretched += 1
        await self._w()
        v = h.uio_level(self.sda)
        h.set_ext(self.scl, who=self.who, val=0)
        await self._w()
        return v

    async def write(self, b):
        for i in range(7, -1, -1):
            self.h.set_ext(self.sda, who=self.who, val=(b >> i) & 1)
            await self._w()
            await self._clock()
        self.h.set_ext(self.sda, who=self.who, val=1)
        await self._w()
        return (await self._clock()) == 0   # True = ACK

    async def read(self, ack):
        self.h.set_ext(self.sda, who=self.who, val=1)
        v = 0
        for _ in range(8):
            await self._w()
            v = (v << 1) | await self._clock()
        self.h.set_ext(self.sda, who=self.who, val=0 if ack else 1)
        await self._w()
        await self._clock()
        self.h.set_ext(self.sda, who=self.who, val=1)
        return v


class JtagTap:
    """IEEE 1149.1 TAP with a 4-bit IR (IDCODE=0001, BYPASS=1111) and a
    32-bit IDCODE register.  Samples TMS/TDI on rising TCK, updates TDO on falling."""
    NEXT = {  # state: (next if TMS=0, next if TMS=1)
        "TLR": ("RTI", "TLR"), "RTI": ("RTI", "SELDR"),
        "SELDR": ("CAPDR", "SELIR"), "CAPDR": ("SHDR", "EX1DR"), "SHDR": ("SHDR", "EX1DR"),
        "EX1DR": ("PADR", "UPDR"), "PADR": ("PADR", "EX2DR"), "EX2DR": ("SHDR", "UPDR"),
        "UPDR": ("RTI", "SELDR"), "SELIR": ("CAPIR", "TLR"), "CAPIR": ("SHIR", "EX1IR"),
        "SHIR": ("SHIR", "EX1IR"), "EX1IR": ("PAIR", "UPIR"), "PAIR": ("PAIR", "EX2IR"),
        "EX2IR": ("SHIR", "UPIR"), "UPIR": ("RTI", "SELDR"),
    }

    def __init__(self, h, tck, tms, tdi, tdo_ui, idcode):
        self.h, self.tck, self.tms, self.tdi, self.tdo = h, tck, tms, tdi, tdo_ui
        self.idcode = idcode
        self.state = "TLR"
        self.ir = 0b0001
        self.sh = 0
        self.shlen = 32
        self.clocks = 0

    async def run(self):
        h = self.h
        prev = 0
        out = 0
        while True:
            await RisingEdge(h.dut.clk)
            uo = int(h.dut.uo_out.value)
            tck = (uo >> self.tck) & 1
            if tck and not prev:                       # rising: sample
                self.clocks += 1
                tms, tdi = (uo >> self.tms) & 1, (uo >> self.tdi) & 1
                s = self.state
                if s == "SHDR" or s == "SHIR":
                    self.sh = (self.sh >> 1) | (tdi << (self.shlen - 1))
                nxt = self.NEXT[s][tms]
                if nxt == "TLR":
                    self.ir = 0b0001
                if nxt == "CAPDR":
                    if self.ir == 0b0001:
                        self.sh, self.shlen = self.idcode, 32
                    else:
                        self.sh, self.shlen = 0, 1
                if nxt == "CAPIR":
                    self.sh, self.shlen = 0b0001, 4
                if s == "UPIR":
                    pass
                if nxt == "UPIR":
                    self.ir = self.sh & 0xF
                self.state = nxt
            elif prev and not tck:                     # falling: drive TDO
                out = self.sh & 1 if self.state in ("SHDR", "SHIR") else 0
                h.set_ui(self.tdo, out)
            prev = tck


async def ps2_send(h, clk_bit, dat_bit, byte, half):
    """PS/2 device frame: start, 8 data LSB first, odd parity, stop."""
    clk = h.dut.clk
    bits = [0] + [(byte >> i) & 1 for i in range(8)]
    bits.append(1 - (bin(byte).count("1") & 1))
    bits.append(1)
    for b in bits:
        h.set_ui(dat_bit, b)
        await ClockCycles(clk, half)
        h.set_ui(clk_bit, 0)          # host samples on the falling edge
        await ClockCycles(clk, half)
        h.set_ui(clk_bit, 1)
    h.set_ui(dat_bit, 1)
    await ClockCycles(clk, 4 * half)


async def ws2812_decode(h, pin, nbits, threshold, timeout=400000):
    """Decode WS2812 bits from high-pulse widths (in clocks)."""
    clk = h.dut.clk
    bits, widths = [], []
    prev = h.uo_level(pin)
    hi = 0
    n = 0
    while len(bits) < nbits:
        await RisingEdge(clk)
        n += 1
        assert n < timeout, "WS2812 decode timeout"
        v = (int(h.dut.uo_out.value) >> pin) & 1
        if v:
            hi += 1
        if prev and not v:
            widths.append(hi)
            bits.append(1 if hi > threshold else 0)
            hi = 0
        prev = v
    return bits, widths


def usb_crc16(data):
    c = 0xFFFF
    for b in data:
        c ^= b
        for _ in range(8):
            c = (c >> 1) ^ (0xA001 if c & 1 else 0)
    return c ^ 0xFFFF            # USB sends the complement


async def usb_ls_capture(h, dp, dm, period, timeout=500000):
    """Record one low-speed packet (J idle -> SOP ... EOP -> J) and decode it.
    Returns (packet bytes after SYNC, list of problems)."""
    clk = h.dut.clk
    trace = []
    n = 0
    state = "idle"
    while True:
        await RisingEdge(clk)
        n += 1
        assert n < timeout, "USB capture timeout"
        uo = int(h.dut.uo_out.value)
        v = ((uo >> dp) & 1, (uo >> dm) & 1)
        if state == "idle":
            if v == (1, 0):                     # J -> K: start of packet
                state = "pkt"
                trace = [v]
        else:
            trace.append(v)
            if state == "pkt" and v == (0, 0):
                state = "eop"
                se0 = len(trace) - 1
            elif state == "eop" and v == (0, 1):
                j_at = len(trace) - 1
                for _ in range(period):          # J must hold for one bit
                    await RisingEdge(clk)
                    uo = int(h.dut.uo_out.value)
                    trace.append(((uo >> dp) & 1, (uo >> dm) & 1))
                break
    problems = []
    # every transition before EOP falls on a bit boundary
    for i in range(1, se0 + 1):
        if trace[i] != trace[i - 1] and i % period:
            problems.append(f"transition at {i} clocks is off the bit grid ({period})")
    if se0 % period:
        problems.append(f"SE0 starts off the bit grid at {se0}")
    if abs((j_at - se0) - 2 * period) > 2:
        problems.append(f"SE0 lasted {j_at - se0} clocks, expected {2 * period}")
    if any(trace[j] != (0, 1) for j in range(j_at, j_at + period)):
        problems.append("J after SE0 did not hold for one bit")
    # NRZI decode and un-stuff
    nbits = se0 // period
    prev = (0, 1)                                # J before SOP
    bits, ones = [], 0
    for k in range(nbits):
        s = trace[k * period + period // 2]
        b = 1 if s == prev else 0
        prev = s
        if ones == 6:
            if b != 0:
                problems.append(f"missing stuff bit at bit {k}")
            ones = 0
            continue
        ones = ones + 1 if b else 0
        bits.append(b)
    if len(bits) % 8:
        problems.append(f"{len(bits)} data bits is not whole bytes")
    by = [sum(bits[i + j] << j for j in range(8)) for i in range(0, len(bits) - 7, 8)]
    if not by or by[0] != 0x80:
        problems.append(f"bad SYNC {by[:1]}")
    return by[1:], problems


async def can_receive(h, tx_uo, rx_ui, period, ack=True, timeout=400000):
    """Real-time CAN 2.0A receiver on the wired-AND bus RX = TX & (not our ACK).
    Returns (fields dict, problems).  Drives the ACK slot dominant if `ack`."""
    clk = h.dut.clk
    n = 0
    while True:                                  # wait for SOF (recessive -> dominant)
        await RisingEdge(clk)
        n += 1
        assert n < timeout, "CAN SOF timeout"
        tx = (int(h.dut.uo_out.value) >> tx_uo) & 1
        h.set_ui(rx_ui, tx)
        if not tx:
            break
    problems = []
    bits, raw = [], []
    run_val, run_len = 0, 0
    t = 0                                        # clocks since SOF edge
    prev = 0
    destuff = True
    ack_index = None
    acking = False
    fields = None
    while True:
        await RisingEdge(clk)
        t += 1
        tx = (int(h.dut.uo_out.value) >> tx_uo) & 1
        if tx != prev and t % period and destuff:
            problems.append(f"transition off the bit grid at {t}")
        prev = tx
        h.set_ui(rx_ui, tx & (0 if acking else 1))
        k, phase = divmod(t, period)
        if phase == period // 2:                 # sample point
            b = tx
            if destuff and run_len == 5:
                if b == run_val:
                    problems.append(f"missing stuff bit at raw bit {len(raw)}")
                run_val, run_len = b, 1
                raw.append(b)
                continue
            raw.append(b)
            if b == run_val:
                run_len += 1
            else:
                run_val, run_len = b, 1
            bits.append(b)
            if len(bits) == 19:                  # header done: frame length known
                dlc = int("".join(map(str, bits[15:19])), 2)
                crc_end = 19 + 8 * dlc + 15
            if len(bits) >= 19 and len(bits) == crc_end:
                destuff = False                  # CRC delimiter onwards is not stuffed
                ack_index = k + 2                # delimiter, then the ACK slot
            if ack_index is not None and fields is None and len(bits) == crc_end:
                body = bits[:19 + 8 * dlc]
                fields = {
                    "sof": bits[0], "id": int("".join(map(str, bits[1:12])), 2),
                    "rtr": bits[12], "ide": bits[13], "r0": bits[14], "dlc": dlc,
                    "data": [int("".join(map(str, bits[19 + 8 * i:27 + 8 * i])), 2) for i in range(dlc)],
                    "crc": int("".join(map(str, bits[19 + 8 * dlc:crc_end])), 2),
                    "body": body,
                }
        if ack_index is not None:
            acking = ack and k == ack_index
            if k == ack_index + 9:               # ACK delimiter + EOF seen
                break
    return fields, problems


class SwdTarget:
    """Minimal SWD debug port: line reset, request (with parity / stop / park
    checks), turnaround, ACK=OK, then for DP reads 32 data bits + parity.
    Samples SWDIO on rising SWCLK, changes its own drive right after it."""

    def __init__(self, h, swclk_uo, swdio_uio, dpidr):
        self.h, self.clk_bit, self.dio = h, swclk_uo, swdio_uio
        self.dpidr = dpidr
        self.ones = 0
        self.log = []
        self.errors = []

    def _drive(self, v):
        self.h.set_ext(self.dio, v, who="swd_target")

    async def run(self):
        h = self.h
        prev = 0
        mode = "jtag"            # jtag -> (0xE79E) -> wait_reset -> reset -> (2 zeros) idle -> req
        last16 = 0
        zeros = 0
        wait_turn = False
        req = []
        out = []                 # bits to drive on the following rising edges
        turn = 0
        while True:
            await RisingEdge(h.dut.clk)
            swclk = (int(h.dut.uo_out.value) >> self.clk_bit) & 1
            if swclk and not prev:                       # rising edge
                bit = (int(h.dut.uio_in.value) >> self.dio) & 1
                if wait_turn:                            # turnaround cycle: nobody drives
                    wait_turn = False
                    if out:
                        self._drive(out.pop(0))
                    prev = swclk
                    continue
                if out:                                  # we are driving
                    self._drive(out.pop(0))
                    if not out:
                        turn = 1                         # turnaround back to the host
                    prev = swclk
                    continue
                if turn:
                    self._drive(1)
                    turn = 0
                    prev = swclk
                    continue
                self.ones = self.ones + 1 if bit else 0
                zeros = 0 if bit else zeros + 1
                last16 = ((last16 >> 1) | (bit << 15)) & 0xFFFF     # LSB-first sequence
                if mode == "jtag":
                    if last16 == 0xE79E:
                        mode = "wait_reset"
                        self.log.append("switched to SWD")
                elif self.ones >= 50:
                    mode = "reset"
                elif mode == "reset":
                    if zeros >= 2:
                        mode = "idle"
                elif mode == "idle":
                    if bit:
                        mode, req = "req", [1]
                elif mode == "req":
                    req.append(bit)
                    if len(req) == 8:
                        start, apndp, rnw, a2, a3, par, stop, park = req
                        if par != (apndp + rnw + a2 + a3) & 1 or stop or not park:
                            self.errors.append(f"bad request {req}")
                            mode = "idle"
                        else:
                            self.log.append(("req", apndp, rnw, a2 | a3 << 1))
                            data = self.dpidr if (not apndp and rnw and not (a2 or a3)) else 0
                            ack = [1, 0, 0]                    # OK, LSB first
                            bits = [(data >> i) & 1 for i in range(32)]
                            bits.append(sum(bits) & 1)
                            # the turnaround cycle ends with the next rising edge; ACK is
                            # driven right after it, so the host sees it one cycle later
                            out = ack + (bits if rnw else [])
                            wait_turn = True
                            self._drive(1)
                            mode = "idle"
            prev = swclk
