"""Talk to the real thing: SQL Server 2025, database FeynmanSafecracker.

Connection string comes from the FEYNMAN_SQL environment variable, e.g.
  Driver={ODBC Driver 18 for SQL Server};Server=localhost;Database=FeynmanSafecracker;
  Trusted_Connection=yes;TrustServerCertificate=yes;

Geometry crosses the wire as WKT (STAsText) and is parsed with shapely,
so the drawing code receives exactly what the database computed.
"""
from __future__ import annotations

import os
import threading

from shapely import wkt

try:
    import pyodbc
except ImportError:  # pragma: no cover
    pyodbc = None


def _conn(autocommit=True):
    if pyodbc is None:
        raise RuntimeError("pip install pyodbc  (and an ODBC Driver 18 for SQL Server)")
    cs = os.environ.get("FEYNMAN_SQL")
    if not cs:
        raise RuntimeError("Set FEYNMAN_SQL to an ODBC connection string for the FeynmanSafecracker database.")
    return pyodbc.connect(cs, autocommit=autocommit)


def _rows(cur):
    cols = [c[0] for c in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]


def _exec_out(cn, sql, *params):
    """Run a batch whose LAST result set is SELECT @out; skip any earlier ones."""
    cur = cn.cursor()
    cur.execute(sql, *params)
    last = None
    while True:
        if cur.description:
            last = cur.fetchall()
        if not cur.nextset():
            break
    return last[0][0] if last else None


class SqlDialLab:
    def __init__(self):
        self.cn = _conn()
        self._packs = {}

    @property
    def cabinets(self):
        cur = self.cn.cursor()
        cur.execute("SELECT * FROM dial.Cabinet ORDER BY CabinetId")
        return {r["CabinetId"]: r for r in _rows(cur)}

    def bolt(self, cabinet_id):
        cur = self.cn.cursor()
        cur.execute("SELECT Geom.STAsText() FROM dial.Bolt WHERE CabinetId = ?", cabinet_id)
        return wkt.loads(cur.fetchone()[0])

    def wheel_pack(self, cabinet_id):
        if cabinet_id not in self._packs:
            cur = self.cn.cursor()
            cur.execute("SELECT WheelNo, DialPos, Geom.STAsText() AS G, Clear FROM dial.WheelGeom "
                        "WHERE CabinetId = ?", cabinet_id)
            self._packs[cabinet_id] = {(r.WheelNo, r.DialPos): (wkt.loads(r.G), bool(r.Clear)) for r in cur.fetchall()}
        return self._packs[cabinet_id]

    def bolt_drops(self, cabinet_id, a, b, c):
        p = self.wheel_pack(cabinet_id)
        return p[(3, a)][1] and p[(2, b)][1] and p[(1, c)][1]

    def _run(self, run_id):
        cur = self.cn.cursor()
        cur.execute("SELECT r.*, c.Owner FROM dial.Run r JOIN dial.Cabinet c ON c.CabinetId = r.CabinetId "
                    "WHERE r.RunId = ?", run_id)
        r = _rows(cur)[0]
        r["Found"] = (r["FoundA"], r["FoundB"], r["FoundC"]) if r["FoundC"] is not None else None
        return r

    def attempts(self, run_id, after_seq=0):
        cur = self.cn.cursor()
        cur.execute("SELECT Seq, A, B, C, Source, BoltDropped, StepSeconds, SimSeconds, "
                    "Coverage.STAsText() AS Cov FROM dial.Attempt WHERE RunId = ? AND Seq > ? ORDER BY Seq",
                    run_id, after_seq)
        out = []
        for r in _rows(cur):
            r["Coverage"] = wkt.loads(r.pop("Cov")) if r["Cov"] else None
            r["BoltDropped"] = bool(r["BoltDropped"])
            r["SimSeconds"] = float(r["SimSeconds"])
            out.append(r)
        return out

    def crack(self, cabinet_id, strategy="Feynman", max_attempts=10000, delay_ms=0):
        run_id = _exec_out(self.cn, "SET NOCOUNT ON; DECLARE @r int; "
                           "EXEC dial.usp_Crack @CabinetId=?, @Strategy=?, @MaxAttempts=?, @DelayMs=?, @RunId=@r OUTPUT; "
                           "SELECT @r;", cabinet_id, strategy, max_attempts, delay_ms)
        return self._run(run_id), self.attempts(run_id)

    def crack_in_background(self, cabinet_id, strategy, max_attempts=10000, delay_ms=50):
        """Start usp_Crack on its own connection; returns the thread. Poll attempts() to watch."""
        def work():
            cn = _conn()
            _exec_out(cn, "SET NOCOUNT ON; DECLARE @r int; "
                      "EXEC dial.usp_Crack @CabinetId=?, @Strategy=?, @MaxAttempts=?, @DelayMs=?, @RunId=@r OUTPUT; "
                      "SELECT @r;", cabinet_id, strategy, max_attempts, delay_ms)
            cn.close()
        t = threading.Thread(target=work, daemon=True)
        t.start()
        return t

    def latest_run(self, cabinet_id):
        cur = self.cn.cursor()
        cur.execute("SELECT MAX(RunId) FROM dial.Run WHERE CabinetId = ? AND Strategy <> 'TakeLastTwo'", cabinet_id)
        return cur.fetchone()[0]

    def take_last_two(self, cabinet_id):
        run_id = _exec_out(self.cn, "SET NOCOUNT ON; DECLARE @r int; "
                           "EXEC dial.usp_TakeLastTwo @CabinetId=?, @RunId=@r OUTPUT; SELECT @r;", cabinet_id)
        cur = self.cn.cursor()
        cur.execute("SELECT StepNo, Phase, DialPos, W1, W2, W3, BoltDropped, Note FROM dial.Probe "
                    "WHERE RunId = ? ORDER BY StepNo", run_id)
        probes = _rows(cur)
        for p in probes:
            p["BoltDropped"] = bool(p["BoltDropped"])
        return self._run(run_id), probes

    def lock_cabinet(self, cabinet_id, seed=None):
        self.cn.cursor().execute("EXEC dial.usp_LockCabinet ?", cabinet_id)

    def owner_opens(self, cabinet_id):
        self.cn.cursor().execute("EXEC dial.usp_OwnerOpens ?", cabinet_id)


class SqlPinLab:
    def __init__(self, lock_id=1):
        self.cn = _conn()
        self.lock_id = lock_id
        cur = self.cn.cursor()
        cur.execute("SELECT * FROM pin.Lock WHERE LockId = ?", lock_id)
        self.lock = _rows(cur)[0]
        cur.execute("SELECT Part, Geom.STAsText() AS G FROM pin.Static WHERE LockId = ?", lock_id)
        self.static = {r.Part: wkt.loads(r.G) for r in cur.fetchall()}
        cur.execute("SELECT * FROM pin.Chamber WHERE LockId = ? ORDER BY PinNo", lock_id)
        self.chambers = _rows(cur)

    @property
    def keys(self):
        cur = self.cn.cursor()
        cur.execute("SELECT * FROM pin.Keys ORDER BY KeyId")
        return _rows(cur)

    def frames(self, run_id):
        cur = self.cn.cursor()
        cur.execute("SELECT FrameNo, Caption, Tension, PlugRotation FROM pin.Frame WHERE RunId = ? ORDER BY FrameNo", run_id)
        frames = {r["FrameNo"]: dict(r, Tension=bool(r["Tension"]), Parts=[]) for r in _rows(cur)}
        cur.execute("SELECT FrameNo, Part, PinNo, State, Geom.STAsText() AS G FROM pin.FramePart "
                    "WHERE RunId = ? ORDER BY FrameNo, PartNo", run_id)
        for r in cur.fetchall():
            frames[r.FrameNo]["Parts"].append(dict(Part=r.Part, PinNo=r.PinNo, State=r.State, Geom=wkt.loads(r.G)))
        return [frames[k] for k in sorted(frames)]

    def _run(self, run_id):
        cur = self.cn.cursor()
        cur.execute("SELECT * FROM pin.Run WHERE RunId = ?", run_id)
        r = _rows(cur)[0]
        r["Opened"] = bool(r["Opened"])
        return r

    def use_key(self, key_id):
        run_id = _exec_out(self.cn, "SET NOCOUNT ON; DECLARE @r int; EXEC pin.usp_UseKey ?, ?, @r OUTPUT; SELECT @r;",
                           self.lock_id, key_id)
        return self._run(run_id), self.frames(run_id)

    def pick(self, seed=1945, overset_chance=0.2, max_resets=6):
        run_id = _exec_out(self.cn, "SET NOCOUNT ON; DECLARE @r int; "
                           "EXEC pin.usp_Pick @LockId=?, @Seed=?, @OversetChance=?, @MaxResets=?, @RunId=@r OUTPUT; "
                           "SELECT @r;", self.lock_id, seed, overset_chance, max_resets)
        self.last_pick_run = run_id
        return self._run(run_id), self.frames(run_id)

    def decode_key(self, run_id=None):
        run_id = run_id or self.last_pick_run
        key_id = _exec_out(self.cn, "SET NOCOUNT ON; DECLARE @k int; EXEC pin.usp_DecodeKey ?, @k OUTPUT; SELECT @k;", run_id)
        cur = self.cn.cursor()
        cur.execute("SELECT Bitting FROM pin.Keys WHERE KeyId = ?", key_id)
        return key_id, cur.fetchone()[0]
