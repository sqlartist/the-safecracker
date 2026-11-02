#!/usr/bin/env python3
"""Animate the dial-lock episodes from "Safecracker Meets Safecracker".

  python dial_viz.py --episode kerst
  python dial_viz.py --episode christy --gif christy.gif
  python dial_viz.py --episode all --gif out/
  python dial_viz.py --source sql --episode dehoffmann
  python dial_viz.py --source sql --live --cabinet 10 --strategy Feynman8000
  python dial_viz.py --scoreboard score.png

Panels: the dial | the wheel pack (geometry from dial.WheelGeom) | "Feynman
space" (20 first-number bands x 100 x 100) | the backend rows | run summary.
"""
from __future__ import annotations

import argparse
import os
import sys

import matplotlib

if "--show" not in sys.argv and "--live" not in sys.argv:
    matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.animation import FuncAnimation, PillowWriter
from matplotlib.patches import Circle

from feynman_lab import draw
from feynman_lab.draw import BLUE, CRITICAL, GOOD, INK, INK_2, SURFACE, YELLOW

EPISODES = {
    "captain":    ("The Captain's safe", [("crack", 7, "Factory")]),
    "christy":    ("Taking the last two numbers off", [("open", 2), ("probe", 2), ("lock", 2), ("crack", 2, "Notebook")]),
    "dehoffmann": ("de Hoffmann's nine cabinets", [("crack", 3, "Psychological"), ("crack", 4, "Psychological"),
                                                    ("crack", 5, "Psychological")]),
    "kerst":      ("Kerst's safe, cold", [("crack", 6, "Psychological")]),
    "oakridge":   ("Oak Ridge, half remembered", [("crack", 8, "Notebook")]),
    "colonel":    ("The colonel's two-door safe", [("open", 9), ("probe", 9), ("lock", 9), ("crack", 9, "Notebook")]),
    "staley":     ("Showing Staley", [("crack", 10, "Feynman8000")]),
    "unknown":    ("No clues: the 8000", [("crack", 11, "Feynman8000")]),
    "naive":      ("Without the tolerance trick", [("crack", 11, "Naive", 20000)]),
}

WHEEL_LABEL = {3: "Wheel 3 (rear)\nset by 1st no.", 2: "Wheel 2\nset by 2nd no.", 1: "Wheel 1 (front)\nset by 3rd no."}


def hms(s):
    s = int(round(s or 0))
    return f"{s // 3600:02d}:{s % 3600 // 60:02d}:{s % 60:02d}"


_UNIV_AREA = None


def _universe_area():
    global _UNIV_AREA
    if _UNIV_AREA is None:
        from feynman_lab import geom
        _UNIV_AREA = geom.universe().area
    return _UNIV_AREA


def make_lab(source):
    if source == "sql":
        from feynman_lab.sqlsource import SqlDialLab
        return SqlDialLab()
    from feynman_lab.dial_sim import DialLab
    return DialLab()


def build_frames(lab, steps, max_frames=130):
    frames = []
    for step in steps:
        kind, cid = step[0], step[1]
        cab = lab.cabinets[cid]
        if kind == "open":
            if cab["State"] != "Open":
                lab.owner_opens(cid)
            continue
        if kind == "lock":
            lab.lock_cabinet(cid, seed=cid)
            cab = lab.cabinets[cid]
            frames += [dict(kind="card", cid=cid, title=f"{cab['Owner']} spins the dial and locks up",
                            caption="Later the drawer is shut. Feynman reads the two numbers off the scrap of paper "
                                    "inside his own lock, then needs only the twenty possible first numbers.",
                            wheels=(cab["W1"], cab["W2"], cab["W3"]), dial=cab["W1"], drop=False)] * 8
            continue
        if kind == "probe":
            run, probes = lab.take_last_two(cid)
            for i, p in enumerate(probes):
                frames.append(dict(kind="probe", cid=cid, run=run, probes=probes, i=i, dial=p["DialPos"],
                                   wheels=(p["W1"], p["W2"], p["W3"]), drop=p["BoltDropped"],
                                   title=f"{cab['Owner']}: drawer open, dial on ten",
                                   caption=("Turn away from ten in fives, each time back to ten. When the bolt "
                                            "won't drop, the step before was the number. ")
                                   + ("Phase 1: last number, front wheel." if p["Phase"] == "LastNumber"
                                      else "Phase 2: the other way, second number, middle wheel.")))
            frames += [dict(frames[-1], kind="note", note=run["Found"])] * 10
            continue
        strategy = step[2]
        max_att = step[3] if len(step) > 3 else 10000
        run, attempts = lab.crack(cid, strategy, max_att)
        n = len(attempts)
        idx = list(range(n)) if n <= max_frames else sorted(set(np.linspace(0, n - 1, max_frames).astype(int)))
        # cumulative coverage, built once (incremental union is O(n), not O(n^2))
        from shapely.ops import unary_union
        uni_area = _universe_area()
        running, snaps = None, {}
        batch, nxt = [], 0
        for i in range(n):
            cov = attempts[i]["Coverage"]
            batch.append(cov) if cov is not None and not cov.is_empty else None
            if nxt < len(idx) and i == idx[nxt]:
                if batch:
                    running = unary_union(([running] if running is not None else []) + batch)
                    batch = []
                snaps[i] = (running, 100.0 * running.area / uni_area if running is not None else 0.0)
                nxt += 1
        for i in idx:
            a = attempts[i]
            cov, pct = snaps[i]
            frames.append(dict(kind="crack", cid=cid, run=run, attempts=attempts, i=i, dial=a["C"],
                               wheels=(a["C"], a["B"], a["A"]), drop=a["BoltDropped"], covered=cov, pct=pct,
                               title=f"{cab['Owner']} — {cab['Location']}", caption=cab.get("Story") or ""))
        frames += [frames[-1]] * (14 if run["Opened"] else 6)
    return frames


class DialFigure:
    """Five-panel figure; redraw(frame) paints one frame."""

    def __init__(self, lab, title):
        self.lab = lab
        self.fig = plt.figure(figsize=(16, 9), facecolor=SURFACE)
        self.fig.suptitle(title, x=0.5, y=0.975, fontsize=15, fontweight="bold", color=INK)
        gs = self.fig.add_gridspec(2, 3, height_ratios=[3, 2], width_ratios=[1.1, 1.4, 1.2],
                                   hspace=0.16, wspace=0.12, left=0.03, right=0.985, top=0.9, bottom=0.04)
        self.ax_dial = self.fig.add_subplot(gs[0, 0])
        self.ax_pack = self.fig.add_subplot(gs[0, 1])
        self.ax_space = self.fig.add_subplot(gs[0, 2])
        self.ax_rows = self.fig.add_subplot(gs[1, :2])
        self.ax_run = self.fig.add_subplot(gs[1, 2])
        self._universe_cache = None

    # -------------------------------------------------- the dial
    def _dial(self, pos, drop):
        ax = self.ax_dial
        ax.clear(); draw.clean(ax)
        ax.set_xlim(-16, 16); ax.set_ylim(-16, 17)
        ax.set_title("The dial", fontsize=11, color=INK_2)
        ax.add_patch(Circle((0, 0), 13.2, fc="#ecebe8", ec=INK_2, lw=1.2, zorder=1))
        ax.add_patch(Circle((0, 0), 4.2, fc="#d8d7d3", ec=INK_2, lw=1, zorder=4))
        for n in range(100):
            a = np.radians(90 + 3.6 * (n - pos))
            r0 = 13.0
            r1 = 13.0 - (2.0 if n % 10 == 0 else (1.3 if n % 5 == 0 else 0.6))
            ax.plot([r1 * np.cos(a), r0 * np.cos(a)], [r1 * np.sin(a), r0 * np.sin(a)],
                    color=INK, lw=1.6 if n % 10 == 0 else 0.7, zorder=2)
            if n % 10 == 0:
                rt = 10.6
                ax.text(rt * np.cos(a), rt * np.sin(a), str(n), ha="center", va="center",
                        fontsize=7.5, color=INK_2, rotation=np.degrees(a) - 90, zorder=3)
        ax.plot([0, 0], [13.4, 15.6], color=CRITICAL, lw=2.4, solid_capstyle="round", zorder=5)
        ax.text(0, 16.4, "index", ha="center", fontsize=8, color=CRITICAL)
        ax.add_patch(Circle((0, 0), 0.5, fc=INK, zorder=5))
        ax.text(0, -15.2, f"reading {pos}", ha="center", fontsize=10, color=GOOD if drop else INK,
                fontweight="bold" if drop else "normal")

    # -------------------------------------------------- the wheel pack
    def _pack(self, cid, wheels, drop):
        ax = self.ax_pack
        ax.clear(); draw.clean(ax)
        ax.set_xlim(-14, 64); ax.set_ylim(-14, 20)
        ax.set_title("The wheel pack  (geometry from dial.WheelGeom)", fontsize=11, color=INK_2)
        pack = self.lab.wheel_pack(cid)
        order = [(3, wheels[2]), (2, wheels[1]), (1, wheels[0])]
        for w, pos in order:
            shape, clear = pack[(w, pos)]
            draw.plot_geom(ax, shape, facecolor="#d7dde3" if not clear else "#cfe8dc",
                           edgecolor=INK_2, lw=0.9, zorder=2)
            cx = draw.STEEL and (3 - w) * 25.0
            ax.text(cx, -12.5, WHEEL_LABEL[w], ha="center", va="center", fontsize=7.6, color=INK_2)
            ax.text(cx, 0, str(pos), ha="center", va="center", fontsize=10, color=INK, fontweight="bold")
        bolt = self.lab.bolt(cid)
        dy = -1.2 if drop else 0.0
        from shapely.affinity import translate
        draw.plot_geom(ax, translate(bolt, yoff=dy), facecolor=GOOD if drop else CRITICAL,
                       edgecolor=INK, lw=0.8, zorder=5)
        ax.plot([-6, 56], [12.2, 12.2], color=INK_2, lw=1.0, zorder=4)
        ax.text(-10, 12.2, "bolt /\nfence", ha="center", va="center", fontsize=7.6, color=INK_2)
        ax.text(25, 17.5, "bolt drops into the gates — OPEN" if drop else "a gate is off — bolt held up",
                ha="center", fontsize=9.5, color=GOOD if drop else CRITICAL, fontweight="bold")

    # -------------------------------------------------- Feynman space
    def _space(self, frame):
        ax = self.ax_space
        ax.clear(); draw.clean(ax)
        ax.set_title("Feynman space  (20 bands of 2nd×3rd)", fontsize=11, color=INK_2)
        ax.set_xlim(-8, 558); ax.set_ylim(-990, 108)
        for p in range(20):
            x0, y0 = (p % 5) * 110.0, -(p // 5) * 110.0
            ax.add_patch(plt.Rectangle((x0, y0), 100, 100, fc="#f0eeea", ec="#d9d7d2", lw=0.6, zorder=1))
            ax.text(x0 + 50, y0 + 104, f"1st={p*5}", ha="center", fontsize=6, color=INK_2)
        if frame["kind"] in ("crack",):
            if frame.get("covered") is not None:
                draw.plot_geom(ax, frame["covered"], facecolor=BLUE, edgecolor="none", alpha=0.5, zorder=2)
            a = frame["attempts"][frame["i"]]
            if a["Coverage"] is not None and not a["Coverage"].is_empty:
                draw.plot_geom(ax, a["Coverage"].buffer(2.5),
                               facecolor=GOOD if frame["drop"] else YELLOW, edgecolor=INK, lw=0.8, zorder=4)
            ax.text(275, -975, f"{frame['i'] + 1} tries ruled out {frame['pct']:.1f}% of the 8000", ha="center",
                    fontsize=9, color=INK_2)
        else:
            ax.text(275, -480, "(search space shown while cracking)", ha="center", fontsize=9, color=INK_2)

    def _universe(self):
        if self._universe_cache is None:
            from feynman_lab import geom
            self._universe_cache = geom.universe()
        return self._universe_cache

    # -------------------------------------------------- backend rows
    def _rows(self, frame):
        ax = self.ax_rows
        ax.clear(); draw.clean(ax)
        ax.set_xlim(0, 1); ax.set_ylim(0, 1)
        k = frame["kind"]
        if k in ("crack",):
            ax.set_title("dial.Attempt  (the backend, row by row)", fontsize=11, color=INK_2, loc="left")
            atts, i = frame["attempts"], frame["i"]
            head = f"{'seq':>5}  {'try':>10}  {'bolt':>5}  {'+sec':>5}  {'clock':>8}   source"
            ax.text(0.01, 0.92, head, family="monospace", fontsize=9, color=INK_2)
            window = atts[max(0, i - 8): i + 1]
            for j, a in enumerate(reversed(window)):
                y = 0.80 - j * 0.085
                hit = a["BoltDropped"]
                line = (f"{a['Seq']:>5}  {a['A']:>2}-{a['B']:>2}-{a['C']:<3}  "
                        f"{'DROP' if hit else '·':>5}  {a['StepSeconds']:>5.1f}  {hms(a['SimSeconds']):>8}   {a['Source'][:34]}")
                ax.text(0.01, y, line, family="monospace", fontsize=9,
                        color=GOOD if hit else INK, fontweight="bold" if hit else "normal")
        elif k == "probe":
            ax.set_title("dial.Probe  (wobbling the dial on an open drawer)", fontsize=11, color=INK_2, loc="left")
            probes, i = frame["probes"], frame["i"]
            ax.text(0.01, 0.92, f"{'step':>4}  {'phase':<12}  {'pos':>3}  {'bolt':>5}   note",
                    family="monospace", fontsize=9, color=INK_2)
            for j, p in enumerate(reversed(probes[max(0, i - 8): i + 1])):
                y = 0.80 - j * 0.085
                drop = p["BoltDropped"]
                ax.text(0.01, y, f"{p['StepNo']:>4}  {p['Phase']:<12}  {p['DialPos']:>3}  "
                        f"{'drop' if drop else 'STAYS':>5}   {p['Note'][:40]}",
                        family="monospace", fontsize=8.5, color=INK if drop else CRITICAL)
        else:
            ax.set_title("", fontsize=11)
            ax.text(0.01, 0.8, frame.get("title", ""), fontsize=12, color=INK, fontweight="bold")
        cap = frame.get("caption", "")
        if cap:
            import textwrap
            ax.text(0.01, -0.02, "\n".join(textwrap.wrap(cap, 92)), fontsize=8.6, color=INK_2, va="top")

    # -------------------------------------------------- run summary
    def _run(self, frame):
        ax = self.ax_run
        ax.clear(); draw.clean(ax)
        ax.set_xlim(0, 1); ax.set_ylim(0, 1)
        ax.set_title("This run", fontsize=11, color=INK_2, loc="left")
        y = 0.86
        lines = []
        if frame["kind"] in ("crack",):
            r = frame["run"]
            lines = [("strategy", r["Strategy"]),
                     ("candidates queued", f"{r['Candidates']:,}"),
                     ("tries so far", f"{frame['i'] + 1:,}"),
                     ("time at the dial", hms(frame["attempts"][frame["i"]]["SimSeconds"]))]
            if frame["drop"]:
                a = frame["attempts"][frame["i"]]
                lines.append(("OPENED", f"{a['A']}-{a['B']}-{a['C']}"))
        elif frame["kind"] in ("probe", "note"):
            _, b, c = frame["run"]["Found"]
            lines = [("reading off", "an open drawer"),
                     ("2nd number", str(b)), ("last number", str(c))]
            if frame["kind"] == "note":
                lines.append(("written in", "the notebook"))
        for label, val in lines:
            hit = label in ("OPENED",)
            ax.text(0.03, y, label, fontsize=10, color=INK_2)
            ax.text(0.97, y, str(val), fontsize=12, color=GOOD if hit else INK, ha="right",
                    fontweight="bold" if hit else "normal")
            y -= 0.14

    def redraw(self, frame):
        self._dial(frame["dial"], frame["drop"])
        self._pack(frame["cid"], frame["wheels"], frame["drop"])
        self._space(frame)
        self._rows(frame)
        self._run(frame)


def render_episode(lab, name, out_gif=None, show=False, fps=14):
    title, steps = EPISODES[name]
    frames = build_frames(lab, steps)
    figo = DialFigure(lab, f"Feynman the safecracker — {title}")

    def update(fi):
        figo.redraw(frames[fi])
        return []

    if out_gif:
        anim = FuncAnimation(figo.fig, update, frames=len(frames), interval=1000 / fps, blit=False)
        anim.save(out_gif, writer=PillowWriter(fps=fps))
        plt.close(figo.fig)
        print(f"  {name:12s} {len(frames):4d} frames  ->  {out_gif}")
    elif show:
        from matplotlib.animation import FuncAnimation as FA
        figo._anim = FA(figo.fig, update, frames=len(frames), interval=1000 / fps, blit=False, repeat=False)
        plt.show()
    else:
        figo.redraw(frames[-1])
        png = f"{name}.png"
        figo.fig.savefig(png, dpi=110, facecolor=SURFACE)
        plt.close(figo.fig)
        print(f"  {name:12s} final frame -> {png}")


def live(lab, cabinet, strategy, delay_ms=50, fps=12):
    """SQL-only: start usp_Crack with @DelayMs and watch dial.Attempt fill."""
    lab.lock_cabinet(cabinet)
    lab.crack_in_background(cabinet, strategy, delay_ms=delay_ms)
    import time
    run_id = None
    for _ in range(100):
        run_id = lab.latest_run(cabinet)
        if run_id:
            break
        time.sleep(0.1)
    figo = DialFigure(lab, f"LIVE — cabinet {cabinet}, {strategy}")
    cab = lab.cabinets[cabinet]

    def poll():
        atts = lab.attempts(run_id)
        if not atts:
            return None
        a = atts[-1]
        return dict(kind="crack", cid=cabinet, run=lab._run(run_id), attempts=atts, i=len(atts) - 1,
                    dial=a["C"], wheels=(a["C"], a["B"], a["A"]), drop=a["BoltDropped"],
                    title=cab["Owner"], caption=cab.get("Story") or "")

    def update(_):
        fr = poll()
        if fr:
            figo.redraw(fr)
        return []

    figo._anim = FuncAnimation(figo.fig, update, interval=1000 / fps, blit=False, cache_frame_data=False)
    plt.show()


def scoreboard(lab, path):
    rows = []
    for name, (title, steps) in EPISODES.items():
        lab = make_lab(getattr(scoreboard, "_source", "sim"))
        run = None
        for step in steps:              # replay the whole episode (probe/lock then crack)
            kind, cid = step[0], step[1]
            if kind == "open" and lab.cabinets[cid]["State"] != "Open":
                lab.owner_opens(cid)
            elif kind == "probe":
                lab.take_last_two(cid)
            elif kind == "lock":
                lab.lock_cabinet(cid, seed=cid)
            elif kind == "crack":
                run, _ = lab.crack(cid, step[2], step[3] if len(step) > 3 else 10000)
        cid = [s for s in steps if s[0] == "crack"][-1][1]
        rows.append((lab.cabinets[cid]["Owner"], run["Strategy"], run["Attempts"], run["SimSeconds"], run["Opened"]))
    rows.sort(key=lambda r: r[3])
    fig, ax = plt.subplots(figsize=(12, 7), facecolor=SURFACE)
    draw.clean(ax)
    ax.set_facecolor(SURFACE)
    names = [f"{o}\n{s}" for o, s, *_ in rows]
    hours = [r[3] / 3600 for r in rows]
    y = np.arange(len(rows))
    bars = ax.barh(y, hours, color=[GOOD if r[4] else CRITICAL for r in rows], height=0.6, zorder=3)
    for yi, (r, h) in enumerate(zip(rows, hours)):
        ax.add_patch(plt.Rectangle((0, yi - 0.3), h, 0.6, fc="none", ec="none"))
        ax.text(h + 0.03, yi, f"{r[2]:,} tries · {hms(r[3])}", va="center", fontsize=9, color=INK_2)
    ax.set_yticks(y); ax.set_yticklabels(names, fontsize=9)
    ax.set_xlabel("estimated hours at the dial", fontsize=10, color=INK_2)
    ax.set_title("How long each safe took — Feynman's methods vs brute force", fontsize=14, fontweight="bold", color=INK)
    ax.set_xlim(0, max(hours) * 1.25 + 0.2)
    ax.tick_params(left=False)
    fig.tight_layout()
    fig.savefig(path, dpi=120, facecolor=SURFACE)
    plt.close(fig)
    print(f"  scoreboard -> {path}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", choices=["sim", "sql"], default="sim")
    ap.add_argument("--episode", default="kerst", help="one of: " + ", ".join(EPISODES) + ", or 'all'")
    ap.add_argument("--gif", help="file (single episode) or directory (--episode all)")
    ap.add_argument("--show", action="store_true", help="open an interactive window")
    ap.add_argument("--scoreboard", help="write the comparison chart to this PNG")
    ap.add_argument("--live", action="store_true", help="SQL only: watch a crack as it runs")
    ap.add_argument("--cabinet", type=int, default=10)
    ap.add_argument("--strategy", default="Feynman8000")
    ap.add_argument("--delay-ms", type=int, default=50)
    ap.add_argument("--fps", type=int, default=14)
    args = ap.parse_args()

    lab = make_lab(args.source)

    if args.scoreboard:
        scoreboard(lab, args.scoreboard)
        return
    if args.live:
        if args.source != "sql":
            sys.exit("--live needs --source sql")
        live(lab, args.cabinet, args.strategy, args.delay_ms, args.fps)
        return
    if args.episode == "all":
        outdir = args.gif or "."
        os.makedirs(outdir, exist_ok=True)
        for name in EPISODES:
            render_episode(make_lab(args.source), name,
                           out_gif=os.path.join(outdir, f"dial_{name}.gif") if args.gif else None, fps=args.fps)
    else:
        render_episode(lab, args.episode, out_gif=args.gif, show=args.show, fps=args.fps)


if __name__ == "__main__":
    main()
