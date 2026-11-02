#!/usr/bin/env python3
"""The transparent practice lock — watch a key work, or watch it get picked.

  python pin_viz.py --mode key --key 1            # the right key opens it
  python pin_viz.py --mode key --key 2 --gif k2.gif   # next door's key jams
  python pin_viz.py --mode pick --seed 7 --gif pick.gif
  python pin_viz.py --mode decode --gif decode.gif    # pick it, then cut the key
  python pin_viz.py --source sql --mode pick

Like a cutaway acrylic practice lock: shell, plug, keyway, five chambers,
key pins (blue), driver pins (steel), springs, the shear line in red. Every
shape is the geometry the database returns.
"""
from __future__ import annotations

import argparse
import sys
import textwrap

import matplotlib

if "--show" not in sys.argv:
    matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation, PillowWriter

from feynman_lab import draw
from feynman_lab.draw import (ACRYLIC, BLUE, BRASS, CRITICAL, GOOD, INK, INK_2,
                              MAGENTA, NICKEL, STEEL, SURFACE)

STATE_COLOR = {
    "Rest": (BLUE, "key pin"), "Riding": (BLUE, "riding the key"),
    "Binding": (MAGENTA, "binding"), "Springy": ("#9fb0bd", "springy"),
    "Set": (GOOD, "set"), "AtShear": (GOOD, "on the shear line"),
    "Overset": (CRITICAL, "overset"), "Blocked": (CRITICAL, "blocking"),
    None: (BLUE, ""),
}


def make_lab(source):
    if source == "sql":
        from feynman_lab.sqlsource import SqlPinLab
        return SqlPinLab()
    from feynman_lab.pin_sim import PinLab
    return PinLab()


class PinFigure:
    def __init__(self, lab, title):
        self.lab = lab
        self.static = lab.static
        self.fig = plt.figure(figsize=(14, 8), facecolor=SURFACE)
        self.fig.suptitle(title, x=0.5, y=0.96, fontsize=15, fontweight="bold", color=INK)
        gs = self.fig.add_gridspec(2, 1, height_ratios=[5, 1], hspace=0.08,
                                   left=0.04, right=0.84, top=0.9, bottom=0.04)
        self.ax = self.fig.add_subplot(gs[0, 0])
        self.ax_cap = self.fig.add_subplot(gs[1, 0])
        self.ax_side = self.fig.add_axes([0.85, 0.08, 0.14, 0.82])

    def _plug_transform(self, rotation):
        """Rotate the plug + its contents about the keyway mouth as it opens."""
        from matplotlib.transforms import Affine2D
        return Affine2D().rotate_deg_around(0, self.lab.lock["ShearY"] / 2, rotation) + self.ax.transData

    def redraw(self, frame):
        ax = self.ax
        ax.clear(); draw.clean(ax)
        L = self.lab.lock
        length = (L["PinCount"] + 1) * L["PinSpacing"]
        ax.set_xlim(-16, length + 4)
        ax.set_ylim(-5, L["ChamberTopY"] + 4)
        rot = frame.get("PlugRotation", 0) or 0
        tr = self._plug_transform(rot)

        # shell (fixed), plug (rotates), shear line
        draw.plot_geom(ax, self.static["Shell"], facecolor="#e7e4df", edgecolor=INK_2, lw=1.1, zorder=1)
        draw.plot_geom(ax, self.static["Plug"], facecolor=ACRYLIC, edgecolor=INK_2, lw=1.1,
                       alpha=0.55, zorder=2, transform=tr)
        sx, sy = self.static["ShearLine"].xy
        ax.plot(sx, sy, color=CRITICAL, lw=1.6, ls=(0, (6, 3)), zorder=6)
        ax.text(length + 1.5, L["ShearY"], "shear\nline", color=CRITICAL, fontsize=8, va="center")

        # the plug and whatever rides inside it turn together; drivers and
        # springs belong to the shell and stay put
        for part in frame["Parts"]:
            g, kind, state = part["Geom"], part["Part"], part["State"]
            col, _ = STATE_COLOR.get(state, (BLUE, ""))
            if kind == "KeyPin":
                draw.plot_geom(ax, g, facecolor=col, edgecolor=INK, lw=0.7, zorder=5, transform=tr)
            elif kind == "Driver":
                drv_set = state in ("Set", "AtShear")
                draw.plot_geom(ax, g, facecolor=NICKEL if not drv_set else "#a9d6bd",
                               edgecolor=INK, lw=0.7, zorder=5)
            elif kind == "Spring":
                gx, gy = g.xy
                ax.plot(gx, gy, color=STEEL, lw=1.0, zorder=4)
            elif kind == "Key":
                draw.plot_geom(ax, g, facecolor=BRASS, edgecolor=INK, lw=0.9, alpha=0.92, zorder=7, transform=tr)
            elif kind == "Pick":
                gx, gy = g.xy
                ax.plot(gx, gy, color=INK, lw=2.2, solid_capstyle="round", zorder=8)
                ax.plot(gx[-1], gy[-1], "o", color=INK, ms=4, zorder=8)

        # pin numbers along the bottom
        for c in self.lab.chambers:
            ax.text(c["X"], -3.4, f"pin {c['PinNo']}", ha="center", fontsize=8, color=INK_2)
        if frame.get("Tension"):
            ax.annotate("tension →", xy=(length, L["ShearY"] / 2), xytext=(length - 3, -3.4),
                        fontsize=9, color=MAGENTA)

        self._caption(frame)
        self._legend(frame)

    def _caption(self, frame):
        ax = self.ax_cap
        ax.clear(); draw.clean(ax)
        ax.set_xlim(0, 1); ax.set_ylim(0, 1)
        txt = frame.get("Caption", "")
        ax.text(0.01, 0.75, "\n".join(textwrap.wrap(txt, 110)), fontsize=11, color=INK, va="top")
        ax.text(0.01, 0.12, f"frame {frame['FrameNo']}", fontsize=8, color=INK_2)

    def _legend(self, frame):
        ax = self.ax_side
        ax.clear(); draw.clean(ax)
        ax.set_xlim(0, 1); ax.set_ylim(0, 1)
        ax.set_title("legend", fontsize=10, color=INK_2)
        items = [(BLUE, "key pin"), (NICKEL, "driver pin"), (STEEL, "spring"),
                 (BRASS, "key"), (INK, "pick"), (CRITICAL, "shear line"),
                 (MAGENTA, "binding pin"), (GOOD, "set / open"), (CRITICAL, "overset / blocked")]
        y = 0.92
        for col, lab in items:
            ax.add_patch(plt.Rectangle((0.04, y - 0.018), 0.12, 0.036, fc=col, ec=INK, lw=0.5))
            ax.text(0.2, y, lab, fontsize=9, color=INK, va="center")
            y -= 0.078
        # per-pin state readout
        pins = {p["PinNo"]: p["State"] for p in frame["Parts"] if p["Part"] == "KeyPin"}
        y -= 0.03
        ax.text(0.04, y, "pins:", fontsize=9, color=INK_2); y -= 0.06
        for pn in sorted(k for k in pins if k is not None):
            _, word = STATE_COLOR.get(pins[pn], (INK, ""))
            col = STATE_COLOR.get(pins[pn], (INK, ""))[0]
            ax.text(0.06, y, f"{pn}: {word}", fontsize=8.5, color=col, va="center")
            y -= 0.055


def run(lab, mode, key, seed, overset, gif, show, fps):
    if mode == "key":
        info, frames = lab.use_key(key)
        name = info.get("KeyName", f"key {key}")
        title = f"The practice lock — {name}"
    elif mode == "pick":
        info, frames = lab.pick(seed=seed, overset_chance=overset)
        title = "The practice lock — single-pin picking"
    elif mode == "decode":
        _, pre = lab.pick(seed=seed, overset_chance=overset)
        key_id, bitting = lab.decode_key()
        info, post = lab.use_key(key_id)
        frames = pre + post
        title = f"Pick it, read the pins, cut the key ({bitting})"
    else:
        sys.exit("mode must be key, pick or decode")

    figo = PinFigure(lab, title)

    def update(fi):
        figo.redraw(frames[fi])
        return []

    if gif:
        anim = FuncAnimation(figo.fig, update, frames=len(frames), interval=1000 / fps, blit=False)
        anim.save(gif, writer=PillowWriter(fps=fps))
        plt.close(figo.fig)
        print(f"  {mode:7s} {len(frames):4d} frames  ->  {gif}  (opened={info.get('Opened')})")
    elif show:
        figo._anim = FuncAnimation(figo.fig, update, frames=len(frames), interval=1000 / fps, blit=False, repeat=False)
        plt.show()
    else:
        figo.redraw(frames[-1])
        png = f"pin_{mode}.png"
        figo.fig.savefig(png, dpi=110, facecolor=SURFACE)
        plt.close(figo.fig)
        print(f"  {mode} final -> {png}  (opened={info.get('Opened')})")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", choices=["sim", "sql"], default="sim")
    ap.add_argument("--mode", choices=["key", "pick", "decode"], default="pick")
    ap.add_argument("--key", type=int, default=1, help="1 right key, 2 next door's, 3 blank")
    ap.add_argument("--seed", type=int, default=1945)
    ap.add_argument("--overset", type=float, default=0.22, help="chance of overshooting at the shear line")
    ap.add_argument("--gif")
    ap.add_argument("--show", action="store_true")
    ap.add_argument("--fps", type=int, default=10)
    args = ap.parse_args()
    run(make_lab(args.source), args.mode, args.key, args.seed, args.overset, args.gif, args.show, args.fps)


if __name__ == "__main__":
    main()
