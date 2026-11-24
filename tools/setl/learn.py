"""Learn-then-impersonate, host side.

1. `programs/i2c_sniff.setl` captures a live I2C bus as (value, tag) pairs.
2. `transactions()` turns the pairs into transactions; `learn()` replays them into
   a register-device model (pointer byte, auto-increment, register file).  Every
   register the controller wrote or read is learned; registers whose reads
   disagreed are reported as volatile.
3. `Impersonator` serves that model through `programs/i2c_target_host.setl`, so
   the chip answers the controller exactly as the real device did.

The learning runs on the host (the RP2350 or a PC).  The chip does all the
real-time work: capture, bus timing, clock stretching.
"""

TAG_S, TAG_P, TAG_A, TAG_N = 0x53, 0x50, 0x41, 0x4E   # sniffer
TAG_W, TAG_R = 0x57, 0x52                              # host-served target


def pairs(stream):
    """Group a flat RX byte stream into (value, tag) pairs."""
    if len(stream) % 2:
        raise ValueError("odd-length capture stream")
    return [(stream[i], stream[i + 1]) for i in range(0, len(stream), 2)]


def transactions(stream):
    """Decode a sniffer capture into a list of segments.

    Each segment is (addr7, is_read, [(byte, acked), ...]): one START (or
    repeated START) up to the next START/STOP.  Unknown tags raise."""
    segs = []
    cur = None
    for value, tag in pairs(stream):
        if tag == TAG_S:
            if cur:
                segs.append(cur)
            cur = []
        elif tag == TAG_P:
            if cur:
                segs.append(cur)
            cur = None
        elif tag in (TAG_A, TAG_N):
            if cur is None:
                raise ValueError("byte outside a transaction")
            cur.append((value, tag == TAG_A))
        else:
            raise ValueError(f"unknown capture tag 0x{tag:02x}")
    if cur:
        segs.append(cur)
    out = []
    for seg in segs:
        (a, ack), rest = seg[0], seg[1:]
        if not ack:
            continue                    # nobody answered this address
        out.append((a >> 1, bool(a & 1), rest))
    return out


class RegisterDevice:
    """Pointer-addressed register file (EEPROMs, most sensors)."""

    def __init__(self, addr, regs=None, size=256):
        self.addr = addr
        self.regs = dict(regs or {})
        self.size = size
        self.ptr = 0
        self._first = False

    def write_start(self):
        self._first = True

    def write(self, b):
        if self._first:
            self.ptr, self._first = b % self.size, False
        else:
            self.regs[self.ptr] = b
            self.ptr = (self.ptr + 1) % self.size

    def read(self):
        v = self.regs.get(self.ptr, 0xFF)
        self.ptr = (self.ptr + 1) % self.size
        return v


def learn(stream, addr=None):
    """Infer a RegisterDevice from a capture.  Returns (device, report)."""
    segs = transactions(stream)
    if addr is None:
        addrs = {a for a, _, _ in segs}
        if len(addrs) != 1:
            raise ValueError(f"capture talks to {sorted(addrs)}; pick one with addr=")
        addr = addrs.pop()
    dev = RegisterDevice(addr)
    seen = {}
    volatile = set()
    for a, rd, data in segs:
        if a != addr:
            continue
        if rd:
            for b, _ack in data:
                p = dev.ptr
                if p in seen and seen[p] != b:
                    volatile.add(p)
                seen[p] = b
                dev.regs[p] = b
                dev.ptr = (p + 1) % dev.size
        else:
            dev.write_start()
            for b, _ack in data:
                if not dev._first:
                    seen[dev.ptr] = b      # the controller wrote it: known value
                dev.write(b)
    report = {"address": addr, "registers": dict(sorted(dev.regs.items())),
              "volatile": sorted(volatile), "transactions": len(segs)}
    dev.ptr = 0
    return dev, report


class Impersonator:
    """Feeds `i2c_target_host.setl`: give it RX pairs, it returns bytes to push to TX."""

    def __init__(self, dev):
        self.dev = dev
        self.log = []

    def handle(self, stream):
        replies = []
        for value, tag in pairs(stream):
            if tag == TAG_S:
                self.dev.write_start()
                self.log.append("S")
            elif tag == TAG_W:
                self.dev.write(value)
                self.log.append(("W", value))
            elif tag == TAG_R:
                v = self.dev.read()
                replies.append(v)
                self.log.append(("R", v))
            else:
                raise ValueError(f"unknown target tag 0x{tag:02x}")
        return replies
