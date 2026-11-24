#!/usr/bin/env python3
"""Show a counterexample from an SBY task without an SMT solver.

    python3 cex.py <task_dir> [signal ...]

Replays engine_0/trace.aiw on the prepared design with `yosys sim`, prints the
failing assertion(s) and a per-cycle table of the requested top-level signals.
"""
import os
import re
import subprocess
import sys

task = sys.argv[1]
want = sys.argv[2:]
top = re.search(r"prep -top (\S+)", open(os.path.join(task, "config.sby")).read()).group(1)
vcd = os.path.join(task, "cex.vcd")
eng = os.path.join(task, "engine_0")
wit = os.path.join(eng, "trace_aiw.yw") if os.path.exists(os.path.join(eng, "trace_aiw.yw")) \
    else os.path.join(eng, "trace.aiw")
mapf = os.path.join(task, "model", "design_aiger.aim")
model = os.path.join(task, "model")
if wit.endswith(".aiw"):
    # AIGER witness -> Yosys witness (named signals), then replay on the RTL model
    yw = os.path.join(task, "cex.yw")
    subprocess.run(["yosys-witness", "aiw2yw", wit, os.path.join(model, "design_aiger.ywa"), yw],
                   check=True, capture_output=True)
    wit = yw
script = (f"read_rtlil {model}/design_prep.il; sim -r {wit} -scope {top} -vcd {vcd}")
r = subprocess.run(["yosys", "-q", "-p", script], capture_output=True, text=True)
print((r.stdout + r.stderr).strip())
ids, vals, rows, t, depth = {}, {}, [], None, 0
for line in open(vcd):
    line = line.strip()
    if line.startswith("$scope"):
        depth += 1
    elif line.startswith("$upscope"):
        depth -= 1
    elif line.startswith("$var"):
        p = line.split()
        if depth == 1 and (not want or p[4] in want):
            ids[p[3]] = p[4]
    elif line.startswith("#"):
        if t is not None:
            rows.append((t, dict(vals)))
        t = int(line[1:])
    elif line.startswith("b"):
        v, code = line[1:].split()
        if code in ids:
            vals[ids[code]] = v
    elif line and line[0] in "01xz" and line[1:] in ids:
        vals[ids[line[1:]]] = line[0]
rows.append((t, dict(vals)))
cols = want or sorted({k for _, v in rows for k in v})
print("time " + " ".join(cols))
last = None
for t, v in rows:
    row = " ".join(str(int(v[c], 2)) if c in v and set(v[c]) <= {"0", "1"} else "?" for c in cols)
    if row != last:
        print(f"{t:4d} {row}")
    last = row
