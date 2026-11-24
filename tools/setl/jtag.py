"""Host side of programs/jtag.setl: turn (TMS, TDI) cycles into TX bytes and
RX bytes back into TDO bits.  TAP navigation is ordinary host software."""


def pack(cycles):
    """cycles: list of (tms, tdi); length must be a multiple of 4."""
    if len(cycles) % 4:
        raise ValueError("pad the sequence to a multiple of 4 cycles in a stable TAP state")
    out = []
    for i in range(0, len(cycles), 4):
        b = 0
        for tms, tdi in cycles[i:i + 4]:
            b = (b << 2) | (tms << 1) | tdi
        out.append(b)
    return out


def unpack(rx, n):
    """TDO bit for each of the first n cycles."""
    bits = []
    for b in rx:
        for k in (6, 4, 2, 0):
            bits.append((b >> k) & 1)
    return bits[:n]


def read_idcode_sequence():
    """Test-Logic-Reset -> Run-Test/Idle -> Shift-DR, 32 bits out, back to RTI.
    Returns (cycles, index of the first IDCODE bit)."""
    seq = [(1, 0)] * 5 + [(0, 0)]          # TLR (IDCODE selected), RTI
    seq += [(1, 0), (0, 0), (0, 0)]        # Select-DR, Capture-DR, Shift-DR
    first = len(seq)
    seq += [(0, 0)] * 31 + [(1, 0)]        # 32 shifts, last one exits to Exit1-DR
    seq += [(1, 0), (0, 0)]                # Update-DR, RTI
    while len(seq) % 4:
        seq.append((0, 0))                 # idle in RTI
    return seq, first
