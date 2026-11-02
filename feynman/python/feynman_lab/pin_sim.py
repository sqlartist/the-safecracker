"""Standalone simulator for the pin-tumbler lock — mirrors 04_pin_tumbler.sql.

Frames come back in the same shape as pin.Frame + pin.FramePart, so the
visualiser can't tell whether SQL Server or this module produced them.
(Random draws use Python's generator, so a given seed won't reproduce the
exact SQL RAND() sequence — the behaviour is the same, the luck differs.)
"""
from __future__ import annotations

import random

from . import geom

LOCK = dict(LockId=1, Name="Clear practice lock (5-pin)", PinCount=5, PinSpacing=5.0, FloorY=1.0,
            BladeTopY=6.0, ShearY=10.0, ChamberTopY=24.0, DepthStep=0.5, Tolerance=0.15,
            DriverLen=6.0, PinWidth=1.6)
SECRET = [(1, 3, 0.04), (2, 5, 0.12), (3, 2, 0.07), (4, 7, 0.02), (5, 4, 0.10)]  # pin, depth, bind offset
CHAMBERS = [dict(PinNo=p, X=p * LOCK["PinSpacing"],
                 KeyPinLen=LOCK["ShearY"] - LOCK["BladeTopY"] + d * LOCK["DepthStep"], BindOffset=b)
            for p, d, b in SECRET]
KEYS = [dict(KeyId=1, Name="the right key", Bitting="35274"),
        dict(KeyId=2, Name="next door's key", Bitting="35284"),
        dict(KeyId=3, Name="an uncut blank", Bitting="00000")]


class PinLab:
    def __init__(self):
        self.lock = dict(LOCK)
        self.chambers = [dict(c) for c in CHAMBERS]
        self.keys = [dict(k) for k in KEYS]
        self.static = geom.lock_static(self.lock, self.chambers)

    # ------------------------------------------------------------ frame writer
    def _frame(self, frames, pins, caption, tension, rotation, key=None, pick=None):
        L = self.lock
        parts = []
        for p in pins:
            x, w = p["X"], L["PinWidth"]
            parts.append(dict(Part="KeyPin", PinNo=p["PinNo"], State=p["State"],
                              Geom=geom.rect(x - w / 2, p["KpBottom"], x + w / 2, p["KpBottom"] + p["Kpl"])))
            parts.append(dict(Part="Driver", PinNo=p["PinNo"], State=p["State"],
                              Geom=geom.rect(x - w / 2, p["DrvBottom"], x + w / 2, p["DrvBottom"] + L["DriverLen"])))
            parts.append(dict(Part="Spring", PinNo=p["PinNo"], State=p["State"],
                              Geom=geom.spring(x, p["DrvBottom"] + L["DriverLen"], L["ChamberTopY"], w * 0.8)))
        if key is not None:
            parts.append(dict(Part="Key", PinNo=None, State=None, Geom=key))
        if pick is not None:
            parts.append(dict(Part="Pick", PinNo=None, State=None, Geom=pick))
        frames.append(dict(FrameNo=len(frames) + 1, Caption=caption, Tension=tension,
                           PlugRotation=rotation, Parts=parts))

    def _pins(self):
        f = self.lock["FloorY"]
        return [dict(PinNo=c["PinNo"], X=c["X"], Kpl=c["KeyPinLen"], KpBottom=f, DrvBottom=f + c["KeyPinLen"],
                     State="Rest", IsSet=False, Bind=c["BindOffset"]) for c in self.chambers]

    # ------------------------------------------------------------ use a key
    def use_key(self, key_id):
        L = self.lock
        key_row = next(k for k in self.keys if k["KeyId"] == key_id)
        bitting, name = key_row["Bitting"], key_row["Name"]
        pins, frames = self._pins(), []
        off = -(L["PinCount"] + 1) * L["PinSpacing"]
        key = None
        while off <= 0:
            key = geom.key_geom(L, bitting, off)
            for p in pins:
                p["KpBottom"] = geom.surface_y(key, p["X"], L["FloorY"])
                p["DrvBottom"] = p["KpBottom"] + p["Kpl"]
                p["State"] = "Riding" if p["KpBottom"] > L["FloorY"] + 0.001 else "Rest"
            self._frame(frames, pins, f"Inserting {name} ({bitting})", False, 0, key)
            off += 1.0
        blocked = []
        for p in pins:
            s = geom.straddler(p["X"], p["KpBottom"], p["Kpl"], p["DrvBottom"], L["DriverLen"],
                               L["PinWidth"], L["ShearY"], L["Tolerance"])
            p["State"] = "AtShear" if s == "Clear" else "Blocked"
            if s != "Clear":
                blocked.append(p["PinNo"])
        cap = ("Every gap on the shear line — turn!" if not blocked
               else f"Pin {', '.join(map(str, blocked))} across the shear line — it won't turn")
        self._frame(frames, pins, cap, False, 0, key)
        if not blocked:
            for rot in range(4, 23, 3):
                self._frame(frames, pins, "Plug turning — open", False, rot, key)
        run = dict(Mode="Key", KeyName=name, Bitting=bitting, Opened=not blocked, Frames=len(frames), Notes=cap)
        return run, frames

    # ------------------------------------------------------------ pick it
    def pick(self, seed=1945, overset_chance=0.2, max_resets=6):
        L = self.lock
        rnd = random.Random(seed)
        pins, frames, picklog = self._pins(), [], []
        rot, resets = 0.0, 0
        floor, shear = L["FloorY"], L["ShearY"]
        by_no = {p["PinNo"]: p for p in pins}
        self._frame(frames, pins, "Tension wrench in — light turning pressure", True, 0)

        while any(not p["IsSet"] for p in pins) and resets <= max_resets:
            bp = max((p for p in pins if not p["IsSet"]), key=lambda p: p["Bind"])["PinNo"]
            for p in sorted((p for p in pins if not p["IsSet"] and p["PinNo"] < bp), key=lambda p: p["PinNo"]):
                p.update(KpBottom=floor + 1.0, DrvBottom=floor + 1.0 + p["Kpl"], State="Springy")
                self._frame(frames, pins, f"Pin {p['PinNo']}: springy — not binding, move on", True, rot,
                            pick=geom.pick_geom(p["X"], floor + 1.0, floor))
                p.update(KpBottom=floor, DrvBottom=floor + p["Kpl"], State="Rest")

            p = by_no[bp]
            lift = 0.0
            while True:
                lift += 0.25
                if floor + lift + p["Kpl"] >= shear - 0.001 and rnd.random() < overset_chance:
                    lift += 0.5
                p.update(KpBottom=floor + lift, DrvBottom=floor + lift + p["Kpl"], State="Binding")
                st = geom.straddler(p["X"], floor + lift, p["Kpl"], floor + lift + p["Kpl"], L["DriverLen"],
                                    L["PinWidth"], shear, L["Tolerance"])
                pk = geom.pick_geom(p["X"], floor + lift, floor)
                if st == "Driver":
                    self._frame(frames, pins, f"Pin {bp}: binding — lifting", True, rot, pick=pk)
                    continue
                if st == "Clear":
                    picklog.append(dict(PinNo=bp, SetOrder=len(picklog) + 1, LiftAtSet=lift))
                    rot += 1.5
                    p.update(IsSet=True, State="Set", KpBottom=floor, DrvBottom=shear)
                    self._frame(frames, pins, f"Click — pin {bp} set ({len(picklog)} of {len(pins)}); the plug gives a hair",
                                True, rot, pick=pk)
                    break
                p["State"] = "Overset"
                self._frame(frames, pins, f"Overset! Pin {bp}'s key pin jammed across the shear line", True, rot, pick=pk)
                for q in pins:
                    q.update(IsSet=False, State="Rest", KpBottom=floor, DrvBottom=floor + q["Kpl"])
                picklog.clear()
                rot, resets = 0.0, resets + 1
                self._frame(frames, pins, "Let go of the tension — tic-tic-tic, every pin drops. Start again.", False, 0)
                self._frame(frames, pins, "Tension back on", True, 0)
                break

        opened = all(p["IsSet"] for p in pins)
        while opened and rot < 20:
            rot = min(20.0, rot + 4)
            self._frame(frames, pins, "All pins set — the plug turns. Open.", True, rot)
        order = "-".join(str(r["PinNo"]) for r in sorted(picklog, key=lambda r: r["SetOrder"]))
        self.last_picklog = picklog
        run = dict(Mode="Pick", Opened=opened, Frames=len(frames), Resets=resets, Notes=f"Set order: {order}")
        return run, frames

    def decode_key(self, picklog=None):
        L = self.lock
        picklog = picklog or self.last_picklog
        bitting = "".join(str(int(round((L["BladeTopY"] - (L["FloorY"] + r["LiftAtSet"])) / L["DepthStep"])))
                          for r in sorted(picklog, key=lambda r: r["PinNo"]))
        key_id = max(k["KeyId"] for k in self.keys) + 1
        self.keys.append(dict(KeyId=key_id, Name="key decoded from the pick", Bitting=bitting))
        return key_id, bitting
