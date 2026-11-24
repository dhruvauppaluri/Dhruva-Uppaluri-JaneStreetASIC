"""SETL assembler.

One state per line:

    label:  ACTION...  [wait COND]  [goto L | if COND goto L1 else L2]

Actions (performed once, on entry to the state):
    set S=V[,S=V]   drive output slot S (0-3) to V (0/1)
    out S           slot S <= shift-register out bit (taken before any shift)
    shift           shift SR one place; the new bit comes from the input pin
    pop | push | ld N     TX FIFO -> SR | SR -> RX FIFO | SR <= N
    dec | inc | cnt=N     counter ops
    timer=TA | timer=TB | timer=N
    flag set | flag clr | event
    crc lo | crc hi | crc clr  SR <= CRC[7:0] | SR <= CRC[15:8] | CRC <= INIT
    ones clr        reset the ones-run counter (after inserting a stuff bit)
    sw clr | ta=sw | tb=sw15   stopwatch: clear | TA <= SW | TB <= SW + SW/2
                    (SW counts lane ticks; use it to measure bit times on chip)
    in PIN          input for pin conditions / shift-in (ui0-7, uio0-7, uo0-6, flag0-3, one, zero)

Conditions: always timer cnt0 txready rxfull pin rise fall edge
            edge_or_timer match bit hflag crcok ones never, prefix "!" to invert.

Without `wait` the state waits for nothing (leaves after one tick).
Without goto/if the state falls through to the next line.

Directives:
    .org N          place the next state at word N
    .pin NAME PIN   symbolic input pin
    .in PIN         default input pin for following states
    .const NAME N   numeric constant
    .lane NAME      cosmetic: starts a new program (label NAME is defined here)

Timer note: timer=N makes the state last N+1 ticks before `wait timer` fires.
Use `delay(D)` = D-1 in your head, or write timer=TA with TA = D-1.
"""
import re
import sys

from . import isa


class AsmError(Exception):
    pass


def _num(tok, consts):
    if tok in consts:
        return consts[tok]
    try:
        return int(tok, 0)
    except ValueError:
        raise AsmError(f"bad number {tok!r}")


def _cond(tok):
    inv = 0
    if tok.startswith("!"):
        inv, tok = 1, tok[1:]
    if tok not in isa.COND:
        raise AsmError(f"unknown condition {tok!r}")
    return isa.COND[tok], inv


def assemble(text, base=0):
    """Returns (image: dict addr->word, symbols: dict label->addr, listing)."""
    consts = {}
    pins = dict(isa.PINS)
    lines = []  # (lineno, addr, labels, tokens, default_in)
    addr = base
    default_in = 0
    pending_labels = []
    symbols = {}

    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.split(";")[0].split("#")[0].strip()
        if not line:
            continue
        try:
            if line.startswith("."):
                parts = line.split()
                d = parts[0]
                if d == ".org":
                    addr = _num(parts[1], consts)
                elif d == ".pin":
                    pins[parts[1]] = pins[parts[2]] if parts[2] in pins else _num(parts[2], consts)
                elif d == ".in":
                    default_in = pins[parts[1]]
                elif d == ".const":
                    consts[parts[1]] = _num(parts[2], consts)
                elif d == ".lane":
                    pending_labels.append(parts[1])
                else:
                    raise AsmError(f"unknown directive {d}")
                continue
            m = re.match(r"^([A-Za-z_][\w]*)\s*:\s*(.*)$", line)
            while m:
                pending_labels.append(m.group(1))
                line = m.group(2).strip()
                m = re.match(r"^([A-Za-z_][\w]*)\s*:\s*(.*)$", line)
            if not line:
                continue
            for lab in pending_labels:
                if lab in symbols:
                    raise AsmError(f"duplicate label {lab}")
                symbols[lab] = addr
            pending_labels = []
            lines.append((n, addr, line.replace(",", " ").split(), default_in))
            addr += 1
        except (AsmError, KeyError, IndexError) as e:
            raise AsmError(f"line {n}: {e}") from None
    for lab in pending_labels:
        symbols[lab] = addr

    image = {}
    listing = []
    used = set()
    for n, a, toks, din in lines:
        try:
            if a in used:
                raise AsmError(f"address {a} used twice")
            if not 0 <= a < isa.NWORDS:
                raise AsmError(f"address {a} out of range")
            used.add(a)
            image[a] = _encode(toks, a, symbols, pins, consts, din)
            listing.append(f"{a:03x}: {image[a]:016x}   {' '.join(toks)}")
        except (AsmError, KeyError, IndexError) as e:
            raise AsmError(f"line {n}: {e}") from None
    return image, symbols, "\n".join(listing)


def _target(tok, symbols, consts):
    if tok in symbols:
        return symbols[tok]
    return _num(tok, consts)


def _encode(toks, addr, symbols, pins, consts, din):
    f = dict(t1=(addr + 1) % isa.NWORDS, t0=(addr + 1) % isa.NWORDS,
             w_sel=0, w_inv=0, b_sel=0, b_inv=0, isel=din, omask=0, oval=0,
             sout_en=0, sout=0, sh=0, fifo=0, cnt=0, tmr=0, flag=0, xop=0, imm=0)
    imm_user = None
    toks = ["goto" if t == "->" else t for t in toks]

    def set_imm(v, what):
        nonlocal imm_user
        if imm_user is not None and f["imm"] != v:
            raise AsmError(f"{what} needs IMM={v} but {imm_user} already uses IMM={f['imm']}")
        if not 0 <= v < 512:
            raise AsmError(f"immediate {v} out of range for {what}")
        f["imm"] = v
        imm_user = what

    i = 0
    while i < len(toks):
        t = toks[i]
        tl = t.lower()
        if tl == "set":
            i += 1
            while i < len(toks) and re.fullmatch(r"[0-3]=[01]", toks[i]):
                s, v = toks[i].split("=")
                s, v = int(s), int(v)
                f["omask"] |= 1 << s
                f["oval"] = (f["oval"] & ~(1 << s)) | (v << s)
                i += 1
            continue
        if re.fullmatch(r"[0-3]=[01]", t):  # bare S=V
            s, v = t.split("=")
            f["omask"] |= 1 << int(s)
            f["oval"] = (f["oval"] & ~(1 << int(s))) | (int(v) << int(s))
        elif tl == "out":
            f["sout_en"], f["sout"] = 1, int(toks[i + 1])
            i += 1
        elif tl == "shift":
            f["sh"] = 1
        elif tl == "pop":
            f["fifo"] = isa.FIFO_POP
        elif tl == "push":
            f["fifo"] = isa.FIFO_PUSH
        elif tl == "ld":
            f["fifo"] = isa.FIFO_LDI
            set_imm(_num(toks[i + 1], consts), "ld")
            i += 1
        elif tl == "crc":
            f["fifo"] = isa.FIFO_LDI
            sp = {"lo": isa.LD_CRC_LO, "hi": isa.LD_CRC_HI, "clr": isa.LD_CRC_CLR}[toks[i + 1]]
            set_imm(sp, "crc " + toks[i + 1])
            i += 1
        elif tl == "ones" and i + 1 < len(toks) and toks[i + 1] == "clr":
            f["fifo"] = isa.FIFO_LDI
            set_imm(isa.LD_ONES_CLR, "ones clr")
            i += 1
        elif tl == "dec":
            f["cnt"] = isa.CNT_DEC
        elif tl == "inc":
            f["cnt"] = isa.CNT_INC
        elif tl.startswith("cnt="):
            f["cnt"] = isa.CNT_LDI
            set_imm(_num(t[4:], consts), "cnt")
        elif tl.startswith("timer="):
            v = t[6:]
            if v.upper() == "TA":
                f["tmr"] = isa.TMR_TA
            elif v.upper() == "TB":
                f["tmr"] = isa.TMR_TB
            else:
                f["tmr"] = isa.TMR_IMM
                set_imm(_num(v, consts), "timer")
        elif tl == "flag":
            f["flag"] = {"set": isa.FLAG_SET, "clr": isa.FLAG_CLR}[toks[i + 1]]
            i += 1
        elif tl == "sw" and i + 1 < len(toks) and toks[i + 1] == "clr":
            f["xop"] = isa.XOP_SWCLR
            i += 1
        elif tl == "ta=sw":
            f["xop"] = isa.XOP_TASW
        elif tl == "tb=sw15":
            f["xop"] = isa.XOP_TBSW
        elif tl == "event":
            f["flag"] = isa.FLAG_EVENT
        elif tl == "in":
            p = toks[i + 1]
            f["isel"] = pins[p] if p in pins else _num(p, consts)
            i += 1
        elif tl == "wait":
            f["w_sel"], f["w_inv"] = _cond(toks[i + 1])
            i += 1
        elif tl == "goto":
            f["t1"] = f["t0"] = _target(toks[i + 1], symbols, consts)
            i += 1
        elif tl == "if":
            # if COND goto L1 [else L2]
            f["b_sel"], f["b_inv"] = _cond(toks[i + 1])
            if toks[i + 2] != "goto":
                raise AsmError("expected 'goto' after if COND")
            f["t1"] = _target(toks[i + 3], symbols, consts)
            i += 3
            if i + 1 < len(toks) and toks[i + 1] == "else":
                f["t0"] = _target(toks[i + 2], symbols, consts)
                i += 2
        else:
            raise AsmError(f"unknown token {t!r}")
        i += 1
    return isa.pack(**f)


def vrom(image, name="setl_rom"):
    """The image as a combinational Verilog function (unused words read as 0)."""
    lines = [f"function [63:0] {name};", "    input [8:0] a;", "    case (a)"]
    for addr in sorted(image):
        lines.append(f"        9'd{addr}: {name} = 64'h{image[addr]:016x};")
    lines += [f"        default: {name} = 64'h0;", "    endcase", "endfunction", ""]
    return "\n".join(lines)


def main(argv=None):
    import argparse
    import json
    ap = argparse.ArgumentParser(description="SETL assembler")
    ap.add_argument("src")
    ap.add_argument("-o", "--out", help="write image as JSON {addr: hex}")
    ap.add_argument("--hex", help="write $readmemh file (512 lines)")
    ap.add_argument("--vrom", help="write the image as a Verilog function (for formal proofs)")
    ap.add_argument("--vrom-name", default="setl_rom")
    ap.add_argument("--vsyms", help="write symbols as Verilog localparams")
    ap.add_argument("-l", "--list", action="store_true")
    a = ap.parse_args(argv)
    try:
        image, syms, lst = assemble(open(a.src).read())
    except AsmError as e:
        print(f"{a.src}: {e}", file=sys.stderr)
        return 1
    if a.list:
        print(lst)
        print("symbols:", syms)
    if a.out:
        json.dump({"image": {str(k): f"{v:016x}" for k, v in image.items()}, "symbols": syms},
                  open(a.out, "w"), indent=1)
    if a.vrom:
        with open(a.vrom, "w") as fh:
            fh.write(vrom(image, a.vrom_name))
    if a.vsyms:
        with open(a.vsyms, "w") as fh:
            for k, v in sorted(syms.items(), key=lambda kv: kv[1]):
                fh.write(f"localparam [8:0] S_{k.upper()} = 9'd{v};\n")
    if a.hex:
        with open(a.hex, "w") as fh:
            for i in range(isa.NWORDS):
                fh.write(f"{image.get(i, 0):016x}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
