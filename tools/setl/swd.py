"""Host side of programs/swd.setl: SWD packets as (dir, data) clock cycles."""


def pack(cycles):
    """cycles: list of (dir, data); padded with released idle cycles to a multiple of 4."""
    cycles = list(cycles)
    while len(cycles) % 4:
        cycles.append((0, 0))
    out = []
    for i in range(0, len(cycles), 4):
        b = 0
        for d, v in cycles[i:i + 4]:
            b = (b << 2) | (d << 1) | v
        out.append(b)
    return out


def unpack(rx, n):
    bits = []
    for b in rx:
        for k in (6, 4, 2, 0):
            bits.append((b >> k) & 1)
    return bits[:n]


def drive(bits):
    return [(1, b) for b in bits]


def release(n):
    return [(0, 0)] * n


def line_reset():
    return drive([1] * 56)


JTAG_TO_SWD = [(0xE79E >> i) & 1 for i in range(16)]      # LSB first


def request(apndp, rnw, addr):
    a2, a3 = (addr >> 2) & 1, (addr >> 3) & 1
    par = (apndp + rnw + a2 + a3) & 1
    return [1, apndp, rnw, a2, a3, par, 0, 1]             # start .. park


def read_sequence(apndp, addr):
    """Cycles for one read: request, turnaround, ACK(3), data(32), parity, turnaround.
    Returns (cycles, index of the ACK's first bit)."""
    cyc = drive(request(apndp, 1, addr)) + release(1)
    ack_at = len(cyc)
    cyc += release(3 + 32 + 1 + 1)
    return cyc, ack_at


def parse_read(bits, ack_at):
    ack = bits[ack_at] | bits[ack_at + 1] << 1 | bits[ack_at + 2] << 2
    data = sum(bits[ack_at + 3 + i] << i for i in range(32))
    parity = bits[ack_at + 35]
    return ack, data, parity
