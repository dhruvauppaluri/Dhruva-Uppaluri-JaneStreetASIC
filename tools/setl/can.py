"""Host side of programs/can_tx.setl."""


def header(ident, dlc, rtr=0):
    """3 header bytes: 5 zero pad bits, SOF, ID[10:0], RTR, IDE=0, r0=0, DLC[3:0]."""
    bits = [0] * 5 + [0] + [(ident >> i) & 1 for i in range(10, -1, -1)] + [rtr, 0, 0]
    bits += [(dlc >> i) & 1 for i in range(3, -1, -1)]
    return [int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, 24, 8)]


def crc15(bits):
    crc = 0
    for b in bits:
        fb = ((crc >> 14) & 1) ^ b
        crc = (crc << 1) & 0x7FFF
        if fb:
            crc ^= 0x4599
    return crc


def frame(ident, data, rtr=0):
    """TX bytes for one data frame."""
    return header(ident, len(data), rtr) + list(data)
