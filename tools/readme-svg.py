#!/usr/bin/env python3
"""Record `cshutdown --dry-run` into an animated SVG for the README.

    tools/readme-svg.py assets/readme/hero.svg
    tools/readme-svg.py assets/readme/abort.svg --cols 96 --rows 26 --abort-at 3.6 --start 2.4

Runs the real program in a pty, emulates the escape codes it writes, samples
frames, and writes an SVG where every element is stored once with the time
window it is visible in (CSS visibility animations, no script).
"""

import argparse
import fcntl
import os
import pty
import re
import select
import signal
import struct
import termios
import time
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
PROGRAM = os.path.join(HERE, "..", "cshutdown")
CW, CH = 8, 16  # cell size in SVG units
BG = (5, 3, 10)
BLOCKS = {"█": 1.0, "▓": 0.75, "▒": 0.5, "░": 0.25}
# glitch noise glyphs: drawn as translucent cells, far smaller than text
for _c in "▚▞▙▟▛▜▌▐":
    BLOCKS[_c] = 0.6

ap = argparse.ArgumentParser()
ap.add_argument("out")
ap.add_argument("--cols", type=int, default=104)
ap.add_argument("--rows", type=int, default=30)
ap.add_argument("--fps", type=float, default=7)
ap.add_argument("--abort-at", type=float)
ap.add_argument("--start", type=float, default=0.0, help="drop frames before this time")
ap.add_argument("--hold", type=float, default=1.0, help="seconds to hold the last frame")
ap.add_argument("--label", default="~ cshutdown --dry-run")
a = ap.parse_args()

# ── record ───────────────────────────────────────────────────────────────────
pid, fd = pty.fork()
if pid == 0:
    os.environ["CSHUTDOWN_DEMO"] = "1"  # fake host, user and processes: these files go public
    os.execvp("python3", ["python3", PROGRAM, "--dry-run"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", a.rows, a.cols, 0, 0))
os.kill(pid, signal.SIGWINCH)

W, H = a.cols, a.rows
ch = [[" "] * W for _ in range(H)]
fg = [[(255, 255, 255)] * W for _ in range(H)]
bg = [[BG] * W for _ in range(H)]
state = {"x": 0, "y": 0, "f": (255, 255, 255), "b": BG}
csi = re.compile(r"\x1b\[([?0-9;]*)([A-Za-z])")
frames = {}  # slot -> (ch, fg, bg)
dt = 1.0 / a.fps
t0 = time.monotonic()
sent = False


def feed(s):
    i = 0
    while i < len(s):
        c = s[i]
        if c == "\x1b":
            m = csi.match(s, i)
            if not m:
                return s[i:]
            p, f = m.group(1), m.group(2)
            if f == "H":
                r, col = (p.split(";") + ["1", "1"])[:2]
                state["y"], state["x"] = int(r or 1) - 1, int(col or 1) - 1
            elif f == "m":
                v = p.split(";")
                if v[0] == "38":
                    state["f"] = tuple(map(int, v[2:5]))
                elif v[0] == "48":
                    state["b"] = tuple(map(int, v[2:5]))
            elif f == "l" and p == "?2026":
                state["last"] = ([r[:] for r in ch], [r[:] for r in fg], [r[:] for r in bg])
                slot = round((time.monotonic() - t0) / dt)
                if slot * dt >= a.start and slot not in frames:
                    frames[slot] = ([r[:] for r in ch], [r[:] for r in fg], [r[:] for r in bg])
            i = m.end()
            continue
        x, y = state["x"], state["y"]
        if 0 <= y < H and 0 <= x < W:
            ch[y][x], fg[y][x], bg[y][x] = c, state["f"], state["b"]
        state["x"] += 1
        i += 1
    return ""


buf = ""
while True:
    if a.abort_at is not None and not sent and time.monotonic() - t0 >= a.abort_at:
        os.write(fd, b"x")
        sent = True
    r, _, _ = select.select([fd], [], [], 0.005)
    if r:
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        buf = feed(buf + data.decode("utf-8", "replace"))
os.waitpid(pid, 0)

slots = sorted(frames)
first = slots[0]
# fill gaps so every slot has a frame
seq = []
last = None
for s in range(first, slots[-1] + 1):
    last = frames.get(s, last)
    seq.append(last)
# the final frame the program drew, which can fall between two samples
seq.append(state["last"])
seq.extend([seq[-1]] * int(a.hold / dt))
N = len(seq)


# ── frame → elements ─────────────────────────────────────────────────────────
def q(c):
    """Quantize to 4 bits a channel: shorter colours, and more runs merge."""
    return tuple(min(15, (v + 8) // 17) for v in c)


def hexc(c):
    return "#%x%x%x" % c


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def elements(frame):
    fch, ffg, fbg = frame
    ffg = [[q(c) for c in row] for row in ffg]
    fbg = [[q(c) for c in row] for row in fbg]
    bgq = q(BG)
    out = []
    oy = 24  # room for the title bar
    for y in range(H):
        py = oy + y * CH
        x = 0
        while x < W:  # background runs
            b = fbg[y][x]
            x2 = x
            while x2 < W and fbg[y][x2] == b:
                x2 += 1
            if b != bgq:
                out.append((0, hexc(b), 1, (py, x * CW, "h%dv%dh-%dz" % ((x2 - x) * CW, CH, (x2 - x) * CW))))
            x = x2
        x = 0
        while x < W:
            c, f = fch[y][x], ffg[y][x]
            if c == " ":
                x += 1
                continue
            if c in BLOCKS:
                x2 = x
                while x2 < W and fch[y][x2] == c and ffg[y][x2] == f:
                    x2 += 1
                op = BLOCKS[c]
                out.append((1, hexc(f), op, (py, x * CW, "h%dv%dh-%dz" % ((x2 - x) * CW, CH, (x2 - x) * CW))))
                x = x2
            elif c in "▀▄":
                out.append((1, hexc(f), 1, (py + (0 if c == "▀" else CH // 2), x * CW, "h%dv%dh-%dz" % (CW, CH // 2, CW))))
                x += 1
            elif c in "◢◤":
                if c == "◢":
                    out.append((1, hexc(f), 1, (py + CH, x * CW, "l%d -%dv%dz" % (CW, CH, CH))))
                else:
                    out.append((1, hexc(f), 1, (py, x * CW, "h%dl-%d %dz" % (CW, CW, CH))))
                x += 1
            else:  # a text run: same colour, spaces allowed inside
                x2 = x
                while x2 < W and fch[y][x2] not in BLOCKS and fch[y][x2] not in "▀▄◢◤" and (fch[y][x2] == " " or ffg[y][x2] == f):
                    x2 += 1
                text = "".join(fch[y][x:x2]).rstrip()
                n = len(text)
                tl = ' textLength="%d"' % (n * CW) if n > 1 else ""
                out.append((1, hexc(f), "t", '<text x="%d" y="%d"%s>%s</text>' % (x * CW, py + 12, tl, esc(text))))
                x2 = x + n
                x = x2
    return out


# element -> visible spans [start, end)
spans = defaultdict(list)
for i, frame in enumerate(seq):
    for e in set(elements(frame)):
        sp = spans[e]
        if sp and sp[-1][1] == i:
            sp[-1][1] = i + 1
        else:
            sp.append([i, i + 1])

groups = defaultdict(list)  # (start, length) -> elements
for e, sp in spans.items():
    for s, end in sp:
        groups[(s, end - s)].append(e)

T = N * dt
poster = int(N * 0.42)  # the HUD at full tilt, for reduced-motion viewers
lengths = sorted({ln for _, ln in groups})
css = [
    "text{font:13.3px ui-monospace,'JetBrains Mono',SFMono-Regular,Menlo,Consolas,monospace;white-space:pre}",
    ".f{visibility:hidden;animation:%.3fs step-end infinite}" % T,
]
for ln in lengths:
    css.append("@keyframes v%d{0%%{visibility:visible}%.4f%%{visibility:hidden}}" % (ln, 100.0 * ln / N))
    css.append(".l%d{animation-name:v%d}" % (ln, ln))
css.append("@media (prefers-reduced-motion:reduce){.f{animation:none}.p{visibility:visible}}")

width, height = W * CW, H * CH + 24
def path_data(frags):
    """Subpaths sorted by position, each moved to relative to the last start."""
    out, px, py = [], None, None
    for y, x, tail in sorted(frags):
        out.append(("M%d %d" % (x, y) if px is None else "m%d %d" % (x - px, y - py)) + tail)
        px, py = x, y
    return "".join(out)


body = []
# backgrounds first, then everything drawn on top of them; inside a group,
# every shape of one colour becomes a single path
for layer in (0, 1):
    for (s, ln), els in sorted(groups.items()):
        mine = [e for e in els if e[0] == layer]
        if not mine:
            continue
        paths, texts = defaultdict(list), defaultdict(list)
        for _, fill, op, payload in mine:
            if op == "t":
                texts[fill].append(payload)
            else:
                paths[(fill, op)].append(payload)
        parts = ['<path fill="%s"%s d="%s"/>' % (fill, "" if op == 1 else ' opacity="%g"' % op, path_data(d)) for (fill, op), d in sorted(paths.items())]
        parts.extend('<g fill="%s">%s</g>' % (fill, "".join(sorted(t))) for fill, t in sorted(texts.items()))
        cls = "f l%d%s" % (ln, " p" if s <= poster < s + ln else "")
        body.append('<g class="%s" style="animation-delay:%.3fs">%s</g>' % (cls, s * dt, "".join(parts)))

svg = (
    '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" role="img" aria-label="cshutdown terminal recording">\n'
    "<defs><style>%s</style></defs>\n"
    '<rect width="%d" height="%d" fill="%s"/>\n'
    '<rect width="%d" height="24" fill="#fcee0a"/><path d="M%d 0H%dV24H%dZ" fill="#ff003c"/>\n'
    '<text x="10" y="16" fill="#000000">%s</text><text x="%d" y="16" fill="#000000" text-anchor="end">RELIC//OS 2.0.77</text>\n'
    "%s\n</svg>\n"
) % (width, height, width, height, "".join(css), width, height, hexc(q(BG)), width, width - 140, width, width - 116, esc(a.label), width - 150, "\n".join(body))

os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
with open(a.out, "w") as f:
    f.write(svg)
print("%s: %d frames, %.1fs, %d groups, %d KB" % (a.out, N, T, len(groups), len(svg) // 1024))
