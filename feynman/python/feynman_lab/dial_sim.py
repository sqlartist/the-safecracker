"""Standalone simulator for the dial locks — mirrors 03_dial.sql.

Same seed data, same candidate order, same geometry-based bolt test, same
time model, same probing algorithm. Returns rows shaped like the SQL tables.
"""
from __future__ import annotations

import copy
import random

from . import geom

DICTIONARY = [  # Seq, Source, A, B, C, Priority
    (1, "Factory default 25-0-25", 25, 0, 25, 1),
    (2, "Factory default 50-25-50", 50, 25, 50, 2),
    (3, "Secretary's crib: pi", 31, 41, 59, 10),
    (4, "pi, reversed", 59, 41, 31, 11),
    (5, "pi, digits backwards", 95, 14, 13, 12),
    (6, "Psychology: e = 2.71828", 27, 18, 28, 20),
    (7, "Simple run", 10, 20, 30, 30),
    (8, "Simple run", 20, 40, 60, 31),
    (9, "Simple run", 60, 40, 20, 32),
    (10, "Simple run", 30, 20, 10, 33),
    (11, "Date: 6 Aug 1945", 8, 6, 45, 40),
    (12, "Date variant", 86, 19, 45, 41),
]

CABINETS = [
    dict(CabinetId=1, Owner="Richard Feynman", Location="Los Alamos, Theoretical Division", N1=69, N2=32, N3=21, State="Locked", W1=70, W2=12, W3=3,
         Story="His own cabinet, taken apart to see how it worked; 69-32-21 is the example in the book."),
    dict(CabinetId=2, Owner="Robert Christy", Location="Los Alamos, T Division", N1=72, N2=35, N3=60, State="Open", W1=60, W2=35, W3=72,
         Story="Left open during a physics chat. Feynman leans on it and wobbles the dial."),
    dict(CabinetId=3, Owner="Frederic de Hoffmann", Location="Declassification Section, cabinet 1", N1=27, N2=18, N3=28, State="Locked", W1=3, W2=66, W3=91,
         Story="Nine cabinets holding the secrets of the bomb. After pi failed, the psychology method: e."),
    dict(CabinetId=4, Owner="Frederic de Hoffmann", Location="Declassification Section, cabinet 2", N1=27, N2=18, N3=28, State="Locked", W1=44, W2=9, W3=50,
         Story="Same combination. Note left: borrowed document LA4312."),
    dict(CabinetId=5, Owner="Frederic de Hoffmann", Location="Declassification, next room", N1=27, N2=18, N3=28, State="Locked", W1=81, W2=77, W3=12,
         Story="Same combination again."),
    dict(CabinetId=6, Owner="Donald Kerst", Location="Los Alamos", N1=0, N2=5, N3=35, State="Locked", W1=50, W2=50, W3=50,
         Story="Opened cold with an audience: dates swept in fives, 162 tries at most."),
    dict(CabinetId=7, Owner="The Captain", Location="Los Alamos, upstairs office", N1=50, N2=25, N3=50, State="Locked", W1=13, W2=88, W3=2,
         Story="The heavy steel safe hauled upstairs on jacks. Never changed from the factory setting."),
    dict(CabinetId=8, Owner="Plant manager", Location="Oak Ridge", N1=65, N2=10, N3=45, State="Locked", W1=22, W2=71, W3=6,
         Story="Last two numbers taken a month earlier and half remembered: 40-15? 15-40? It was 10-45."),
    dict(CabinetId=9, Owner="The Colonel", Location="Oak Ridge, two-door safe", N1=82, N2=57, N3=14, State="Open", W1=14, W2=57, W3=82,
         Story="Big brass doors, same little Mosler bolt. Numbers taken while the colonel read the report."),
    dict(CabinetId=10, Owner="Computing department", Location="Los Alamos", N1=41, N2=19, N3=63, State="Locked", W1=0, W2=0, W3=0,
         Story="The Staley demonstration: the first two numbers happened to be right."),
    dict(CabinetId=11, Owner="Unknown cabinet", Location="Los Alamos", N1=87, N2=43, N3=71, State="Locked", W1=5, W2=5, W3=5,
         Story="No clues at all. The full 8000."),
]
for c in CABINETS:
    c.setdefault("Tolerance", 2)
    c.setdefault("OpenNumber", 10)

NOTEBOOK = [  # NoteId, CabinetId, B, C, Confidence
    (1, 8, 40, 15, "vague"),
    (2, 8, 15, 40, "vague"),
    (3, 8, 10, 45, "vague"),
]

STRATEGIES = ("Factory", "Notebook", "Psychological", "Feynman8000", "Feynman", "Naive")


class DialLab:
    """In-memory stand-in for the dial.* schema."""

    def __init__(self):
        self.cabinets = {c["CabinetId"]: copy.deepcopy(c) for c in CABINETS}
        self.notebook = list(NOTEBOOK)
        self._packs: dict[int, dict] = {}
        self._bolt = geom.bolt()
        self.runs: list[dict] = []

    # ------------------------------------------------------------ physics
    def bolt(self, cabinet_id):
        return self._bolt

    def wheel_pack(self, cabinet_id):
        """{(wheel_no, dial_pos): (geometry, clear)} — usp_BuildWheelPack."""
        if cabinet_id not in self._packs:
            c = self.cabinets[cabinet_id]
            gates = {1: c["N3"], 2: c["N2"], 3: c["N1"]}
            pack = {}
            for w, g in gates.items():
                for pos in range(100):
                    shape = geom.wheel_shape(geom.wheel_cx(w), 0.0, g, pos, c["Tolerance"])
                    pack[(w, pos)] = (shape, not shape.intersects(self._bolt))
            self._packs[cabinet_id] = pack
        return self._packs[cabinet_id]

    def bolt_drops(self, cabinet_id, a, b, c):
        p = self.wheel_pack(cabinet_id)
        return p[(3, a)][1] and p[(2, b)][1] and p[(1, c)][1]

    # ------------------------------------------------------------ candidates
    def candidates(self, cabinet_id, strategy, max_attempts=10000):
        rows = []  # (stage, k, a, b, c, source)
        if strategy in ("Factory", "Psychological", "Feynman"):
            rows += [(1, pr * 1000 + s, a, b, c, src) for s, src, a, b, c, pr in DICTIONARY if src.startswith("Factory")]
        if strategy in ("Notebook", "Feynman"):
            for nid, cab, b, c, conf in self.notebook:
                if cab == cabinet_id:
                    tag = f"Notebook {b}-{c}" + (" (vague)" if conf == "vague" else "")
                    rows += [(2, nid * 100 + a, a, b, c, tag) for a in range(0, 100, 5)]
        if strategy in ("Psychological", "Feynman"):
            rows += [(3, pr * 1000 + s, a, b, c, src) for s, src, a, b, c, pr in DICTIONARY if not src.startswith("Factory")]
        if strategy == "Psychological":
            rows += [(4, (10 - m) * 10000 + d * 100 + y, m, d, y, "Date sweep m-d-y")
                     for m in (0, 5, 10) for d in range(5, 31, 5) for y in range(5, 46, 5)]
        if strategy in ("Feynman8000", "Feynman"):
            rows += [(5, s, (s // 400) * 5, ((s // 20) % 20) * 5, (s % 20) * 5, "Feynman 8000 grid") for s in range(8000)]
        if strategy == "Naive":
            rows += [(6, s, s // 10000, (s // 100) % 100, s % 100, "Naive: every number") for s in range(max_attempts)]
        rows.sort(key=lambda r: (r[0], r[1]))
        return [dict(Seq=i + 1, A=r[2], B=r[3], C=r[4], Source=r[5]) for i, r in enumerate(rows[:max_attempts])]

    # ------------------------------------------------------------ crack
    def crack(self, cabinet_id, strategy="Feynman", max_attempts=10000):
        if strategy not in STRATEGIES:
            raise ValueError(f"strategy must be one of {STRATEGIES}")
        cab = self.cabinets[cabinet_id]
        cands = self.candidates(cabinet_id, strategy, max_attempts)
        attempts, sim, pa, pb = [], 0.0, None, None
        for cd in cands:
            a, b, c = cd["A"], cd["B"], cd["C"]
            drop = self.bolt_drops(cabinet_id, a, b, c)
            step = 20.0 if a != pa else (12.0 if b != pb else 3.2)
            sim += step
            attempts.append(dict(cd, BoltDropped=drop, StepSeconds=step, SimSeconds=round(sim, 1),
                                 Coverage=geom.coverage(a, b, c, cab["Tolerance"])))
            if drop:
                cab.update(State="Open", W1=c, W2=b, W3=a)
                break
            pa, pb = a, b
        hit = attempts[-1] if attempts and attempts[-1]["BoltDropped"] else None
        run = dict(RunId=len(self.runs) + 1, CabinetId=cabinet_id, Owner=cab["Owner"], Strategy=strategy,
                   Candidates=len(cands), Attempts=len(attempts), SimSeconds=round(sim, 1),
                   Opened=hit is not None,
                   Found=(hit["A"], hit["B"], hit["C"]) if hit else None)
        self.runs.append(run)
        return run, attempts

    # ------------------------------------------------------------ last two numbers
    def take_last_two(self, cabinet_id):
        cab = self.cabinets[cabinet_id]
        if cab["State"] != "Open":
            raise RuntimeError("The drawer is shut. Feynman needs it left open, dial on ten.")
        w1, w2, w3, opn = cab["W1"], cab["W2"], cab["W3"], cab["OpenNumber"]
        probes, step_no = [], 0

        cur1, dist1, last_good = w1, ((w1 - opn) % 100 + 100) % 100, None
        for k in range(41):
            p = (opn + 5 * k) % 100
            if 5 * k >= dist1:
                cur1 = p
            drop = self.bolt_drops(cabinet_id, w3, w2, cur1)
            step_no += 1
            probes.append(dict(StepNo=step_no, Phase="LastNumber", DialPos=p, W1=cur1, W2=w2, W3=w3, BoltDropped=drop,
                               Note="back to ten: bolt drops" if drop else "back to ten: bolt stays up — slot disturbed"))
            if not drop:
                break
            last_good = p
        if last_good is None:
            raise RuntimeError("Wheels were not aligned.")
        est_c = last_good

        cur1, cur2, dist2, last_good = est_c, w2, ((est_c - w2) % 100 + 100) % 100, None
        for k in range(41):
            p = ((est_c - 5 * k) % 100 + 100) % 100
            if 5 * k >= dist2:
                cur2 = p
            drop = self.bolt_drops(cabinet_id, w3, cur2, cur1)
            step_no += 1
            probes.append(dict(StepNo=step_no, Phase="SecondNumber", DialPos=p, W1=cur1, W2=cur2, W3=w3, BoltDropped=drop,
                               Note="bolt drops" if drop else "bolt stays up — second wheel disturbed"))
            if not drop:
                break
            last_good = p
        est_b = last_good

        self.notebook.append((len(self.notebook) + 1, cabinet_id, est_b, est_c, "taken"))
        cab.update(W1=est_c, W2=est_b)
        run = dict(RunId=len(self.runs) + 1, CabinetId=cabinet_id, Owner=cab["Owner"], Strategy="TakeLastTwo",
                   Attempts=step_no, Found=(None, est_b, est_c))
        self.runs.append(run)
        return run, probes

    def lock_cabinet(self, cabinet_id, seed=None):
        rnd = random.Random(seed)
        self.cabinets[cabinet_id].update(State="Locked", W1=rnd.randrange(100), W2=rnd.randrange(100), W3=rnd.randrange(100))

    def owner_opens(self, cabinet_id):
        c = self.cabinets[cabinet_id]
        c.update(State="Open", W1=c["N3"], W2=c["N2"], W3=c["N1"])
