"""Learn a real I2C device, then impersonate it (MicroPython on the RP2350).

Wiring: the device's SCL to uio0 and SDA to uio1 (with 4.7 kOhm pull-ups to 3.3 V
if the breakout has none), and the RP2350 GPIOs wired to uio0/uio1 used as the
"MCU" (an independent SoftI2C controller).  Fill in board.py and GP_SCL/GP_SDA.

    import learn_demo; learn_demo.main()

Flow, printed as JSON lines for the report:
  1. scan the bus; pick the device (ADDR, or the only one found)
  2. SETL lane 0 sniffs while the MCU (core 1) runs the training session twice;
     core 0 drains the capture.  The host learns a register model.
  3. the MCU runs a held-out session against the real device: the golden answers
  4. you unplug the device and press Enter
  5. SETL becomes a host-served target at ADDR; the MCU reruns both sessions;
     core 0 serves the learned model while the target stretches SCL
  6. answers are compared, skipping registers seen to change (volatile)

Both sessions are lists of (pointer, count) reads plus optional writes; edit
TRAIN/HELDOUT for your device.  The defaults suit 24Cxx EEPROMs, a DS3231 RTC
(0x68) and a BME280 (0x76/0x77, chip ID 0x60 at 0xD0).
"""
import json
import time

import _thread
from machine import Pin, SoftI2C

import board
from setl import learn

GP_SCL, GP_SDA = None, None        # RP2350 GPIOs wired to uio0 / uio1
ADDR = None                        # 7-bit address; None = the only device found
FREQ = 100_000

SESSIONS = {
    # addr: (training [(ptr, n)], held-out [(ptr, n)])
    0x50: ([(0x00, 8), (0x10, 4)], [(0x02, 3), (0x11, 2)]),        # 24Cxx EEPROM
    0x57: ([(0x00, 8), (0x10, 4)], [(0x02, 3), (0x11, 2)]),        # EEPROM on DS3231 boards
    0x68: ([(0x00, 7), (0x0E, 2)], [(0x04, 3), (0x0F, 1)]),        # DS3231 RTC
    0x76: ([(0xD0, 1), (0x88, 8)], [(0x8A, 4), (0xD0, 1)]),        # BME280 ID + calibration
    0x77: ([(0xD0, 1), (0x88, 8)], [(0x8A, 4), (0xD0, 1)]),
}


def out(**kw):
    print(json.dumps(kw))


def mcu():
    if None in (GP_SCL, GP_SDA):
        raise RuntimeError("set GP_SCL / GP_SDA in learn_demo.py")
    # long timeout: the impersonating target stretches SCL while the host works
    return SoftI2C(scl=Pin(GP_SCL), sda=Pin(GP_SDA), freq=FREQ, timeout=500_000)


def session(i2c, addr, reads):
    res = []
    for ptr, n in reads:
        try:
            res.append(list(i2c.readfrom_mem(addr, ptr, n)))
        except OSError as e:
            res.append("error %s" % e)
    return res


def in_background(fn):
    """Run fn on core 1; returns a dict that gets 'result' (or 'error') and 'done'."""
    box = {"done": False}

    def wrap():
        try:
            box["result"] = fn()
        except Exception as e:
            box["error"] = repr(e)
        box["done"] = True
    _thread.start_new_thread(wrap, ())
    return box


def main():
    c = board.chip()
    i2c = mcu()
    found = i2c.scan()
    out(step="scan", found=[hex(a) for a in found])
    addr = ADDR if ADDR is not None else (found[0] if len(found) == 1 else None)
    if addr is None or addr not in SESSIONS:
        raise RuntimeError("set ADDR (and SESSIONS) for one of %s" % [hex(a) for a in found])
    train, held = SESSIONS[addr]

    # ---- 2. sniff while the MCU runs the training session twice ----------------
    sym = board.load(c, "i2c_sniff")
    c.run(0)
    c.config_lane(0, start=sym["i2c_sniff"], msb=True)
    c.run(1)
    box = in_background(lambda: [session(i2c, addr, train), session(i2c, addr, train)])
    capture, peak = [], 0
    while not box["done"]:
        n = c.status(0)["rx"]
        peak = max(peak, n)
        if n:
            capture.extend(c.pop(0, n))
    time.sleep_ms(5)
    n = c.status(0)["rx"]
    capture.extend(c.pop(0, n))
    ovf = c.status(0)["ovf"]
    real = box.get("result")
    out(step="capture", bytes=len(capture), peak_rx_level=peak, overflow=ovf,
        pairs=learn.pairs(capture), real_training=real, error=box.get("error"))
    dev, report = learn.learn(capture, addr=addr)
    vol = set(report["volatile"])
    out(step="learned", address=hex(report["address"]),
        registers={hex(k): v for k, v in report["registers"].items()},
        volatile=[hex(v) for v in sorted(vol)], transactions=report["transactions"])

    # ---- 3. held-out answers from the real device --------------------------------
    c.run(0)
    golden = session(i2c, addr, held)
    out(step="heldout_real", answers=golden)

    # ---- 4/5. impersonate -----------------------------------------------------------
    input("Unplug the device, then press Enter... ")
    sym = board.load(c, "i2c_target_host")
    c.config_lane(0, start=sym["i2c_target_host"], msb=True,
                  outmap=[("uio1", "od"), ("uio0", "od")], match=addr << 1, mask=0xFE)
    c.run(1)
    imp = learn.Impersonator(dev)
    box = in_background(lambda: [session(i2c, addr, train), session(i2c, addr, held)])
    pending = []
    t0 = time.ticks_ms()
    while not box["done"]:
        n = c.status(0)["rx"]
        if n:
            pending.extend(c.pop(0, n))
            k = len(pending) & ~1
            replies = imp.handle(pending[:k])
            del pending[:k]
            if replies:
                c.push(0, replies)
    c.run(0)
    fake_train, fake_held = box.get("result") or (None, None)
    out(step="impersonate", fake_training=fake_train, fake_heldout=fake_held,
        error=box.get("error"), ms=time.ticks_diff(time.ticks_ms(), t0))

    # ---- 6. compare, register by register -------------------------------------------
    def compare(reads, want, got):
        rows = []
        for (ptr, n), w, g in zip(reads, want or [], got or []):
            for j in range(n):
                reg = (ptr + j) & 0xFF
                a = w[j] if isinstance(w, list) else None
                b = g[j] if isinstance(g, list) else None
                rows.append({"reg": hex(reg), "real": a, "setl": b,
                             "volatile": reg in vol, "match": a == b})
        return rows
    rows = compare(train, real[0] if real else None, fake_train) + compare(held, golden, fake_held)
    checked = [r for r in rows if not r["volatile"]]
    ok = bool(checked) and all(r["match"] for r in checked)
    out(step="result", passed=ok, compared=len(checked),
        mismatches=[r for r in checked if not r["match"]],
        skipped_volatile=len(rows) - len(checked))
    return ok
