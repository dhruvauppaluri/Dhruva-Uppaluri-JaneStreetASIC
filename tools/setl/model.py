"""Cycle-accurate golden model of the SETL chip core (everything except the
host SPI shell).  The RTL is checked against this model cycle by cycle, so
this file *is* the executable specification.

Usage:
    chip = Chip()
    chip.load(image)                # dict addr -> 64-bit word
    chip.write_reg(addr, val) ...   # same register map as the SPI host
    for _ in range(n):
        uo, uio_out, uio_oe = chip.outputs()
        chip.step(ui_in, uio_in)
"""
from . import isa


class Fifo:
    DEPTH = 4

    def __init__(self):
        self.q = []

    @property
    def level(self):
        return len(self.q)


class Lane:
    def __init__(self, idx):
        self.idx = idx
        # config
        self.msb = 0
        self.start = 0
        self.div = 0
        self.ta = 0
        self.tb = 0
        self.omap = [isa.OMAP_NONE] * 4
        self.outinit = 0xF
        self.match = 0
        self.mask = 0
        # state
        self.rec = 0
        self.pc = 0
        self.valid = False
        self.pending = False
        self.first = False
        self.last = 0
        self.timer = 0
        self.cnt = 0
        self.sr = 0
        self.dcnt = 0
        self.slot_val = 0xF
        self.flag = 0
        self.tx = Fifo()
        self.rx = Fifo()
        self.event = 0
        self.ovf = 0

    def restart(self):
        self.pc = self.start
        self.valid = self.pending = self.first = False
        self.last = 0
        self.timer = self.cnt = self.sr = self.dcnt = 0
        self.slot_val = self.outinit
        self.flag = 0


def cond_value(sel, c):
    return [
        1,
        c["timer0"],
        c["cnt0"],
        c["txready"],
        c["rxfull"],
        c["pin"],
        c["rise"],
        c["fall"],
        c["rise"] | c["fall"],
        c["rise"] | c["fall"] | c["timer0"],
        c["match"],
        c["bit"],
        c["hflag"],
        0, 0, 0,
    ][sel]


class Chip:
    def __init__(self):
        self.mem = [0] * isa.NWORDS
        self.lanes = [Lane(i) for i in range(isa.NLANES)]
        self.mode4 = 0
        self.run = 0
        self.hflag = 0
        self.slot = 0
        self.s1 = 0  # {uio, ui} first sync stage (16 bits)
        self.s2 = 0
        self.rd_valid = False
        self.rd_lane = 0
        self.dout = 0
        self.cycle = 0
        self._writes = []
        self._mem_writes = []
        self._cfg_writes = []
        self._host_pop = None
        self.cov = {}  # coverage counters (informational)

    # ---------------------------------------------------------------- host
    def load(self, image):
        for a, w in image.items():
            self.mem[a] = w

    def write_reg(self, addr, val):
        """Host register write.  Queued and applied at the clock edge that
        ends the current cycle (same as the RTL strobe)."""
        self._writes.append((addr, val & 0xFF))

    def write_mem_byte(self, byte_addr, val):
        """Host memory byte write, applied at the end of the current cycle."""
        self._mem_writes.append((byte_addr, val & 0xFF))

    def _apply_write(self, addr, val):
        if addr < 0x40:
            L = self.lanes[addr >> 4]
            r = addr & 0xF
            if r == isa.R_CTRL:
                L.msb = val & 1
            elif r == isa.R_START_LO:
                L.start = (L.start & 0x100) | val
            elif r == isa.R_START_HI:
                L.start = (L.start & 0xFF) | ((val & 1) << 8)
            elif r == isa.R_DIV:
                L.div = val
            elif r == isa.R_TA_LO:
                L.ta = (L.ta & 0xFF00) | val
            elif r == isa.R_TA_HI:
                L.ta = (L.ta & 0xFF) | (val << 8)
            elif r == isa.R_TB_LO:
                L.tb = (L.tb & 0xFF00) | val
            elif r == isa.R_TB_HI:
                L.tb = (L.tb & 0xFF) | (val << 8)
            elif isa.R_OMAP0 <= r < isa.R_OMAP0 + 4:
                L.omap[r - isa.R_OMAP0] = val & 0x7F
            elif r == isa.R_OUTINIT:
                L.outinit = val & 0xF
            elif r == isa.R_MATCH:
                L.match = val
            elif r == isa.R_MASK:
                L.mask = val
            elif r == isa.R_FIFO:
                self._host_push = (L.idx, val)
        elif addr == isa.G_CTRL:
            self._cfg_writes.append((addr, val))  # slot sequencing uses the old mode this cycle
        elif addr == isa.G_RUN:
            self._host_run = val & 0xF
        elif addr == isa.G_HFLAG:
            self.hflag = val & 0xF
        elif isa.G_STATUS <= addr < isa.G_STATUS + 4:
            L = self.lanes[addr - isa.G_STATUS]
            self._host_clr = (L.idx, val)

    def _apply_cfg(self, addr, val):
        if addr == isa.G_CTRL:
            self.mode4 = val & 1

    # ------------------------------------------------------------- outputs
    def outputs(self):
        uo = 0
        uio_out = 0
        uio_oe = 0
        for L in self.lanes:
            for k in range(4):
                m = L.omap[k]
                pin = m & 0x1F
                od = (m >> 5) & 1
                inv = (m >> 6) & 1
                v = ((L.slot_val >> k) & 1) ^ inv
                if pin <= 6:
                    uo |= v << pin
                elif 8 <= pin <= 15:
                    b = pin - 8
                    if od:
                        uio_oe |= (1 - v) << b
                    else:
                        uio_out |= v << b
                        uio_oe |= 1 << b
        return uo, uio_out, uio_oe

    def in_vec(self):
        uo, _, _ = self.outputs()
        v = self.s2 & 0xFFFF
        v |= (uo & 0x7F) << 16
        for L in self.lanes:
            v |= L.flag << (24 + L.idx)
        v |= 1 << 31
        return v

    # ---------------------------------------------------------------- step
    def step(self, ui_in=0, uio_in=0):
        nl = 4 if self.mode4 else 2
        invec = self.in_vec()
        mem_req = None  # (lane, addr)
        updates = []

        rd_valid, rd_lane, dout = self.rd_valid, self.rd_lane, self.dout

        for L in self.lanes:
            u = {}
            me = (self.slot == L.idx) and L.idx < nl
            runbit = (self.run >> L.idx) & 1
            if rd_valid and rd_lane == L.idx and L.pending:
                u.update(rec=dout, valid=True, pending=False, first=True)
            if me and runbit and not L.valid and not L.pending:
                mem_req = (L.idx, L.pc)
                u.update(pending=True)
            elif me and runbit and L.valid and not L.pending:
                if L.dcnt != 0:
                    u.update(dcnt=L.dcnt - 1)
                else:
                    u.update(dcnt=L.div)
                    req = self._tick(L, invec, u)
                    if req is not None:
                        mem_req = (L.idx, req)
            updates.append(u)

        # host FIFO / status side effects (registered by the host strobe)
        self._host_push = self._host_clr = self._host_run = None
        writes, self._writes = self._writes, []
        for a, v in writes:
            self._apply_write(a, v)  # sets _host_push/_host_clr/_host_run only
        hp, hclr, hrun = self._host_push, self._host_clr, self._host_run
        hpop, self._host_pop = self._host_pop, None

        # commit lane updates
        for L, u in zip(self.lanes, updates):
            pop = u.pop("_pop", False)
            push = u.pop("_push", None)
            ev = u.pop("_event", False)
            ovf = u.pop("_ovf", False)
            for k, v in u.items():
                setattr(L, k, v)
            if pop:
                L.tx.q.pop(0)
            if push is not None:
                L.rx.q.append(push)
            if ev:
                L.event = 1
            if ovf:
                L.ovf = 1
            if hp is not None and hp[0] == L.idx and len(L.tx.q) < Fifo.DEPTH:
                L.tx.q.append(hp[1])
            if hpop is not None and hpop == L.idx and L.rx.q:
                L.rx.q.pop(0)
            if hclr is not None and hclr[0] == L.idx:
                if hclr[1] & 0x40 and not ev:
                    L.event = 0
                if hclr[1] & 0x80 and not ovf:
                    L.ovf = 0

        # memory pipeline
        if mem_req is not None:
            self.rd_valid, self.rd_lane = True, mem_req[0]
            self.dout = self.mem[mem_req[1]]
        else:
            self.rd_valid = False

        if hrun is not None:
            for L in self.lanes:
                if (hrun >> L.idx) & 1 and not (self.run >> L.idx) & 1:
                    L.restart()
            self.run = hrun

        self.slot = (self.slot + 1) & 3 if self.mode4 else (self.slot ^ 1) & 1
        for a, v in self._cfg_writes:
            self._apply_cfg(a, v)
        self._cfg_writes = []
        for ba, v in self._mem_writes:
            sh = (7 - (ba & 7)) * 8
            w = ba >> 3
            self.mem[w] = (self.mem[w] & ~(0xFF << sh)) | (v << sh)
        self._mem_writes = []
        self.s2 = self.s1
        self.s1 = (ui_in & 0xFF) | ((uio_in & 0xFF) << 8)
        self.cycle += 1

    def host_pop(self, lane):
        """Pop the RX FIFO (side effect of a host FIFO read); returns the head."""
        L = self.lanes[lane]
        head = L.rx.q[0] if L.rx.q else 0
        self._host_pop = lane
        return head

    # ---------------------------------------------------------------- lane
    def _tick(self, L, invec, u):
        f = isa.unpack(L.rec)
        act = L.first
        cur = (invec >> f["isel"]) & 1

        # SR pipeline inside one tick: load (pop/ld) -> take out bit -> shift.
        tx_avail = len(L.tx.q) != 0
        pop = act and f["fifo"] == isa.FIFO_POP and tx_avail
        push_req = act and f["fifo"] == isa.FIFO_PUSH
        push_ok = push_req and len(L.rx.q) < Fifo.DEPTH
        if pop:
            sr0 = L.tx.q[0]
        elif act and f["fifo"] == isa.FIFO_LDI:
            sr0 = f["imm"] & 0xFF
        else:
            sr0 = L.sr
        outbit = (sr0 >> 7) & 1 if L.msb else sr0 & 1
        if L.msb:
            shifted = ((sr0 << 1) & 0xFF) | cur
        else:
            shifted = (sr0 >> 1) | (cur << 7)
        sr_n = shifted if (act and f["sh"]) else sr0

        cnt_n = L.cnt
        if act:
            if f["cnt"] == isa.CNT_DEC:
                cnt_n = (L.cnt - 1) & 0xFF
            elif f["cnt"] == isa.CNT_LDI:
                cnt_n = f["imm"] & 0xFF
            elif f["cnt"] == isa.CNT_INC:
                cnt_n = (L.cnt + 1) & 0xFF

        if act and f["tmr"] != isa.TMR_NONE:
            timer_n = {isa.TMR_TA: L.ta, isa.TMR_TB: L.tb, isa.TMR_IMM: f["imm"]}[f["tmr"]]
        else:
            timer_n = L.timer - 1 if L.timer else 0

        slot_n = L.slot_val
        if act:
            slot_n = (slot_n & ~f["omask"] | (f["oval"] & f["omask"])) & 0xF
            if f["sout_en"]:
                k = f["sout"]
                slot_n = (slot_n & ~(1 << k)) | (outbit << k)
        flag_n = L.flag
        if act and f["flag"] == isa.FLAG_SET:
            flag_n = 1
        elif act and f["flag"] == isa.FLAG_CLR:
            flag_n = 0

        c = {
            "timer0": int(timer_n == 0),
            "cnt0": int(cnt_n == 0),
            "txready": int(len(L.tx.q) - int(pop) != 0),
            "rxfull": int(len(L.rx.q) + int(push_ok) == Fifo.DEPTH),
            "pin": cur,
            "rise": int((not L.first) and L.last == 0 and cur == 1),
            "fall": int((not L.first) and L.last == 1 and cur == 0),
            "match": int(((sr_n ^ L.match) & L.mask) == 0),
            "bit": (sr_n >> 7) & 1 if L.msb else sr_n & 1,
            "hflag": (self.hflag >> L.idx) & 1,
        }
        cv = self.cov
        cv["tick"] = cv.get("tick", 0) + 1
        if act:
            cv["entry"] = cv.get("entry", 0) + 1
            for k in ("sh", "sout_en"):
                if f[k]:
                    cv[k] = cv.get(k, 0) + 1
            for k in ("fifo", "cnt", "tmr", "flag"):
                if f[k]:
                    cv[f"{k}{f[k]}"] = cv.get(f"{k}{f[k]}", 0) + 1
        if not L.first and (c["rise"] or c["fall"]):
            cv["edge"] = cv.get("edge", 0) + 1
        wait = cond_value(f["w_sel"], c) ^ f["w_inv"]
        if wait:
            k = f"exit_w{f['w_sel']}"
            cv[k] = cv.get(k, 0) + 1
        br = cond_value(f["b_sel"], c) ^ f["b_inv"]
        nxt = f["t1"] if br else f["t0"]

        u.update(sr=sr_n, cnt=cnt_n, timer=timer_n, slot_val=slot_n, flag=flag_n, last=cur)
        if pop:
            u["_pop"] = True
        if push_req and not push_ok:
            self.cov["rx_overflow"] = self.cov.get("rx_overflow", 0) + 1
        if push_ok:
            u["_push"] = sr_n
        if push_req and not push_ok:
            u["_ovf"] = True
        if act and f["flag"] == isa.FLAG_EVENT:
            u["_event"] = True

        req = None
        if wait:
            if nxt == L.pc:
                u["first"] = True
            else:
                u.update(first=False, valid=False, pending=True, pc=nxt)
                req = nxt
        else:
            u["first"] = False
        return req
