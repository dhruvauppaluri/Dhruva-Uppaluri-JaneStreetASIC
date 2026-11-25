"""Board self-test: needs no external parts.

On the board (MicroPython on the RP2350, with board.py filled in):
    import selftest; selftest.main()
On a PC, as a dry run against the golden model:
    PYTHONPATH=tools python3 examples/selftest.py --model

Each result is printed as one JSON line ({"test", "pass", ...}), so a log can be
turned straight into the report tables.  Tests:
  id        chip ID and version registers
  regs      lane configuration registers write and read back
  mem       all 512 program words: two patterns written and read back, HOSTERR clear
  fifo      16 bytes queued in a stopped lane's TX FIFO read back as level 16
  uart      lane 0 (UART TX on uo1) -> lane 1 (UART RX reading uo1 on chip) at
            several baud rates, 16-byte bursts, no framing errors
"""
import json
import sys

ID, VERSION, HOSTERR = 0x82, 0x83, 0x86
RUN, LEVEL, STATUS = 0x81, 0xC0, 0x88
BAUDS = (9600, 115200, 1000000)


def _pattern(i, k):
    x = (i * 0x9E3779B97F4A7C15 + k * 0xD1B54A32D192ED03) & 0xFFFFFFFFFFFFFFFF
    return x ^ (x >> 29)


def t_id(c, env):
    i, v = c.read_reg(ID), c.read_reg(VERSION)
    return i == 0x5E, {"id": i, "version": v}


def t_regs(c, env):
    bad = []
    for lane in range(4):
        base = lane * 0x10
        vals = [(lane * 37 + k * 11) & 0xFF for k in range(1, 8)]
        c.write_regs(base + 1, vals)
        got = list(c.read_regs(base + 1, 7))
        if got != vals:
            bad.append({"lane": lane, "wrote": vals, "read": got})
    return not bad, {"mismatches": bad}


def t_mem(c, env):
    c.write_reg(RUN, 0)
    c.host_errors()
    errors = 0
    first = None
    for k in (1, 2):
        for base in range(0, 512, 8):
            blob = b"".join(_pattern(i, k).to_bytes(8, "big") for i in range(base, base + 8))
            c.write_mem(base * 8, blob)
        for base in range(0, 512, 8):
            got = c.read_mem(base * 8, 64)
            for j in range(8):
                want = _pattern(base + j, k)
                have = int.from_bytes(got[8 * j:8 * j + 8], "big")
                if have != want:
                    errors += 1
                    if first is None:
                        first = {"word": base + j, "want": hex(want), "read": hex(have)}
    herr = c.host_errors()
    return errors == 0 and herr == 0, {"word_errors": errors, "first": first, "hosterr": herr}


def _load_selftest(c, prog):
    c.write_reg(RUN, 0)
    return c.load_json(prog)


def t_fifo(c, env, prog):
    sym = _load_selftest(c, prog)
    c.config_lane(0, start=sym["st_tx"], ta=99, outmap=["uo1"], outinit=1)
    c.push(0, bytes(range(16)))
    lvl = c.status(0)["tx"]
    # configuring a lane does not flush its FIFOs: send the bytes out (8 ticks/bit)
    c.config_lane(0, start=sym["st_tx"], ta=7, outmap=["uo1"], outinit=1)
    c.run(0b01)
    env["sleep_us"](int(16 * 10 * 8 * 2 * 1e6 / env["clk_hz"]) + 100)
    left = c.status(0)["tx"]
    c.write_reg(RUN, 0)
    return lvl == 16 and left == 0, {"tx_level": lvl, "left_after_drain": left}


def t_uart(c, env, prog):
    sym = _load_selftest(c, prog)
    tick_hz = env["clk_hz"] / 2          # 2-lane barrel, DIV = 0
    rows = []
    ok_all = True
    for baud in BAUDS:
        bit = int(tick_hz / baud + 0.5)
        if not 8 <= bit <= 65535:
            rows.append({"baud": baud, "skipped": "bit = %d ticks out of range" % bit})
            continue
        n = 4 if baud < 50000 else 16
        data = bytes((0xA5 ^ (i * 29)) & 0xFF for i in range(n))
        c.write_reg(RUN, 0)
        c.config_lane(0, start=sym["st_tx"], ta=bit - 1, outmap=["uo1"], outinit=1)
        c.config_lane(1, start=sym["st_rx"], ta=bit - 1, tb=(3 * bit + 1) // 2 - 2)
        stale = c.status(1)["rx"]
        if stale:
            c.pop(1, stale)
        c.clear_event(1)
        c.run(0b11)
        c.push(0, data)
        env["sleep_us"](int(1e6 * (n + 2) * 10 / baud) + 200)
        st = c.status(1)
        got = bytes(c.pop(1, st["rx"]))
        ok = got == data and st["event"] == 0 and st["ovf"] == 0
        ok_all &= ok
        rows.append({"baud": baud, "ticks_per_bit": bit, "sent": n, "received": len(got),
                     "match": got == data, "framing_error": st["event"], "pass": ok})
    c.write_reg(RUN, 0)
    return ok_all, {"rates": rows}


def run(c, env, prog):
    results = []
    for name, fn in (("id", t_id), ("regs", t_regs), ("mem", t_mem),
                     ("fifo", lambda c, e: t_fifo(c, e, prog)),
                     ("uart", lambda c, e: t_uart(c, e, prog))):
        try:
            ok, info = fn(c, env)
        except Exception as e:        # report and carry on
            ok, info = False, {"exception": repr(e)}
        row = {"test": name, "pass": bool(ok)}
        row.update(info)
        print(json.dumps(row))
        results.append(row)
    n = sum(r["pass"] for r in results)
    print(json.dumps({"summary": "%d/%d passed" % (n, len(results))}))
    return results


def main():
    if sys.implementation.name == "micropython":
        import time
        import board
        c = board.chip()
        env = {"clk_hz": board.CLK_HZ, "sleep_us": time.sleep_us}
        with open("selftest_loopback.json") as f:
            prog = json.load(f)
    else:
        import os
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
        sys.path.insert(0, os.path.join(root, "tools"))
        from setl.asm import assemble
        from setl.host import Setl
        from setl.simbus import ModelBus
        clk = 33_333_333
        bus = ModelBus(clk_hz=clk)
        c = Setl(bus.xfer)
        env = {"clk_hz": clk, "sleep_us": bus.sleep_us}
        with open(os.path.join(root, "programs", "selftest_loopback.setl")) as f:
            img, sym, _ = assemble(f.read())
        prog = {"image": {str(a): "%016x" % w for a, w in img.items()}, "symbols": sym}
    return run(c, env, prog)


if __name__ == "__main__":
    main()
