"""SETL record format: the single source of truth for field positions.

Every SRAM word is one 64-bit *state record*.  A lane holds one record at a
time.  On the first tick in a state it performs the record's entry action;
on every tick it evaluates WAIT and, when WAIT holds, moves to T1 if BR holds
else T0.  See docs/ARCHITECTURE.md for the full semantics.
"""

# (name, msb, lsb)
FIELDS = [
    ("t1",     63, 55),  # next state when BR is true
    ("t0",     54, 46),  # next state when BR is false
    ("w_inv",  45, 45),
    ("w_sel",  44, 41),  # WAIT condition
    ("b_inv",  40, 40),
    ("b_sel",  39, 36),  # BR condition
    ("isel",   35, 31),  # input select (pin conditions + shift-in bit)
    ("omask",  30, 27),  # which output slots the entry action sets
    ("oval",   26, 23),  # values for those slots
    ("sout_en", 22, 22),  # slot SOUT_SLOT <= shift-register out bit
    ("sout",   21, 20),
    ("sh",     19, 19),  # shift the shift register (in-bit = in_vec[isel])
    ("fifo",   18, 17),  # 0 none, 1 pop TX->SR, 2 push SR->RX, 3 SR<=IMM[7:0]
    ("cnt",    16, 15),  # 0 none, 1 dec, 2 load IMM[7:0], 3 inc
    ("tmr",    14, 13),  # 0 none, 1 load TA, 2 load TB, 3 load IMM
    ("flag",   12, 11),  # 0 none, 1 set flag, 2 clear flag, 3 raise host event
    ("xop",    10,  9),  # 0 none, 1 stopwatch clear, 2 TA<=SW, 3 TB<=SW*1.5
    ("imm",     8,  0),
]
FIELD = {n: (m, l) for n, m, l in FIELDS}

FIFO_NONE, FIFO_POP, FIFO_PUSH, FIFO_LDI = range(4)
CNT_NONE, CNT_DEC, CNT_LDI, CNT_INC = range(4)
TMR_NONE, TMR_TA, TMR_TB, TMR_IMM = range(4)
FLAG_NONE, FLAG_SET, FLAG_CLR, FLAG_EVENT = range(4)
XOP_NONE, XOP_SWCLR, XOP_TASW, XOP_TBSW = range(4)

# Condition selectors (4 bits) -- an inversion bit sits beside each.
COND = {
    "always": 0,
    "timer": 1,     # timer == 0 (after this tick's action)
    "cnt0": 2,      # counter == 0
    "txready": 3,   # TX FIFO holds a byte
    "rxfull": 4,    # RX FIFO is full
    "pin": 5,       # in_vec[isel] is high
    "rise": 6,      # rising edge of in_vec[isel] since the previous tick in this state
    "fall": 7,
    "edge": 8,
    "edge_or_timer": 9,
    "match": 10,    # ((SR ^ MATCH) & MASK) == 0
    "bit": 11,      # shift register out-end bit
    "hflag": 12,    # host flag for this lane
    "crcok": 13,    # CRC register == residue (after this tick's update)
    "ones": 14,     # ones-run counter reached the run length (bit stuffing)
    "never": 15,    # reserved, reads as 0
}

# Input vector (32 entries) used by ISEL
PINS = {}
for i in range(8):
    PINS[f"ui{i}"] = i
    PINS[f"uio{i}"] = 8 + i
for i in range(7):
    PINS[f"uo{i}"] = 16 + i
for i in range(4):
    PINS[f"flag{i}"] = 24 + i
PINS["zero"] = 30
PINS["one"] = 31

NWORDS = 512
NLANES = 4


def pack(**kw) -> int:
    w = 0
    for name, val in kw.items():
        msb, lsb = FIELD[name]
        width = msb - lsb + 1
        if not 0 <= val < (1 << width):
            raise ValueError(f"field {name}={val} does not fit {width} bits")
        w |= val << lsb
    return w


def unpack(w: int) -> dict:
    return {n: (w >> l) & ((1 << (m - l + 1)) - 1) for n, m, l in FIELDS}


# Host register map ---------------------------------------------------------
LANE_STRIDE = 0x10
R_CTRL, R_START_LO, R_START_HI, R_DIV = 0, 1, 2, 3
# CTRL: [0] MSB-first shift, [1] CRC enable, [2] CRC/run bit = input bit (else out bit),
#       [3] CRC shifts left (MSB-first polynomial), [6:4] run length (0 = off),
#       [7] run counts identical bits of either polarity (CAN) instead of 1s (USB)
CTRL_MSB, CTRL_CRC, CTRL_CRC_IN, CTRL_CRC_LEFT, CTRL_RUN_ANY = 0x01, 0x02, 0x04, 0x08, 0x80
R_TA_LO, R_TA_HI, R_TB_LO, R_TB_HI = 4, 5, 6, 7
R_OMAP0 = 8          # 8..11
R_OUTINIT = 0xC   # writing it to a stopped lane also sets the slots immediately
R_MATCH, R_MASK, R_FIFO = 0xD, 0xE, 0xF

G_CTRL = 0x80        # [0] 4-lane mode
G_RUN = 0x81         # [3:0] run bits, 0->1 restarts a lane at START
G_ID = 0x82
G_VERSION = 0x83
G_EVENTS = 0x84      # [3:0] events, [7:4] flags
G_HFLAG = 0x85
G_HOSTERR = 0x86     # sticky, write 1s to clear: [0] host memory request lost
                     # (lanes kept the memory busy), [1] host read data late,
                     # [2] (live) a host memory request is still waiting
G_STATUS = 0x88      # +lane: [2:0] tx level, [5:3] rx level (both saturate at 7), [6] event,
                     # [7] overflow; write 1s to clear 6/7.  Full levels: G_LEVEL
G_PC = 0x8C          # +lane: pc[7:0]
G_SR = 0x90          # +lane
G_CNT = 0x94         # +lane
G_PCHI = 0x98        # [3:0] pc[8] per lane
G_LEVEL = 0xC0       # +2*lane: [4:0] TX level, [6] event, [7] overflow; +1: [4:0] RX level
FIFO_DEPTH = 16
G_CRC = 0xA0         # +8*lane: POLY lo/hi, INIT lo/hi, RES lo/hi, CRC lo/hi (CRC is read/write)

# `ld` with IMM[8] set is a special form (the SR load from IMM[7:0] is replaced):
LD_CRC_LO, LD_CRC_HI, LD_CRC_CLR, LD_ONES_CLR = 0x100, 0x101, 0x102, 0x103
# inverted CRC bytes for protocols that send the complement (USB, HDLC/PPP); they
# also freeze the CRC register until the next `crc clr`, so sending it is harmless
LD_CRC_NLO, LD_CRC_NHI = 0x104, 0x105

CHIP_ID = 0x5E
CHIP_VERSION = 0x01

# OMAP byte: [4:0] pin (0-6 uo0-6, 8-15 uio0-7, else unmapped), [5] open-drain, [6] invert,
# [7] tri-state (uio pins only): the slot drives the data, the lane's next slot
# (k+1 mod 4, uninverted) is the output enable -- e.g. SPI MISO released while CS is high
OMAP_NONE = 0x1F
OMAP_OD = 0x20
OMAP_INV = 0x40
OMAP_OE = 0x80


def omap_pin(name: str) -> int:
    if name.startswith("uio"):
        return 8 + int(name[3:])
    if name.startswith("uo"):
        n = int(name[2:])
        if n > 6:
            raise ValueError("uo7 is the host MISO pin")
        return n
    raise ValueError(f"not an output pin: {name}")
