"""Shapely mirrors of the T-SQL geometry builders in 02_geometry.sql.

Used by the standalone simulator so the visualisers run without SQL Server,
and kept deliberately line-for-line comparable with the SQL so the two agree.
"""
from __future__ import annotations

import math

from shapely.geometry import LineString, Point, Polygon, box
from shapely.ops import unary_union

R = 10.0  # wheel radius


# ---------------------------------------------------------------- helpers
def rect(x1, y1, x2, y2):
    return box(min(x1, x2), min(y1, y2), max(x1, x2), max(y1, y2))


def hline(x1, x2, y):
    return LineString([(x1, y), (x2, y)])


def wedge(cx, cy, r, centre_deg, half_deg):
    pts = [(cx, cy)]
    for i in range(25):
        a = math.radians(centre_deg - half_deg + 2.0 * half_deg * i / 24.0)
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    pts.append((cx, cy))
    return Polygon(pts)


# ---------------------------------------------------------------- dial lock
def wheel_cx(wheel_no: int) -> float:
    return (3 - wheel_no) * 25.0


def gate_angle(gate: int, set_to: int) -> float:
    return 90.0 + 3.6 * (set_to - gate)


def wheel_shape(cx, cy, gate, set_to, tol):
    theta = gate_angle(gate, set_to)
    half = (tol + 0.5) * 3.6 + 3.0
    centre = Point(cx, cy)
    notch = wedge(cx, cy, R * 1.3, theta, half).difference(centre.buffer(R * 0.8))
    pin_hole = Point(cx + 6.0 * math.cos(math.radians(theta + 180.0)),
                     cy + 6.0 * math.sin(math.radians(theta + 180.0))).buffer(0.9)
    return (centre.buffer(R)
            .difference(centre.buffer(1.5))
            .difference(pin_hole)
            .difference(notch))


def bolt():
    return unary_union([rect(cx - 0.3, 8.6, cx + 0.3, 9.8) for cx in (0.0, 25.0, 50.0)])


def panel_origin(a: int):
    panel = int(math.floor(a / 5.0 + 0.5)) % 20      # SQL ROUND(x,0): half away from zero
    return panel, (panel % 5) * 110.0, -(panel // 5) * 110.0


def coverage(a, b, c, tol):
    _, x0, y0 = panel_origin(a)
    h = tol + 0.5
    return rect(x0 + b - h, y0 + c - h, x0 + b + h, y0 + c + h).intersection(
        rect(x0, y0, x0 + 100, y0 + 100))


def universe():
    return unary_union([rect((p % 5) * 110.0, -(p // 5) * 110.0,
                             (p % 5) * 110.0 + 100, -(p // 5) * 110.0 + 100) for p in range(20)])


# ---------------------------------------------------------------- pin tumbler
def spring(x, y1, y2, w):
    n = 11
    pts = [(x, y1)]
    for i in range(1, n):
        pts.append((x + (-w / 2 if i % 2 == 1 else w / 2), y1 + (y2 - y1) * i / n))
    pts.append((x, y2))
    return LineString(pts)


def key_geom(lock: dict, bitting: str, offset: float):
    n, sp = lock["PinCount"], lock["PinSpacing"]
    floor, top, step = lock["FloorY"], lock["BladeTopY"], lock["DepthStep"]
    pts = [(offset - 1, floor), (offset - 1, top)]
    for i in range(1, n + 1):
        d = int(bitting[i - 1])
        if d > 0:
            cx, dy, run = offset + i * sp, top - d * step, d * step * 0.5
            pts += [(cx - 0.2 - run, top), (cx - 0.2, dy), (cx + 0.2, dy), (cx + 0.2 + run, top)]
    tip = offset + (n + 1) * sp
    pts += [(tip - 1.5, top), (tip, top - 2.0), (tip, floor), (offset - 1, floor)]
    blade = Polygon(pts).buffer(0)
    return blade.union(rect(offset - 9, floor - 2, offset - 1, top + 3))


def surface_y(key, x, floor):
    if key is None:
        return floor
    hit = key.intersection(LineString([(x, -10), (x, 40)]))
    if hit.is_empty:
        return floor
    return max(floor, hit.bounds[3])


def straddler(x, kp_bottom, kpl, drv_bottom, drv_len, width, shear, tol):
    line = hline(x - 5, x + 5, shear)
    if rect(x - width / 2, drv_bottom, x + width / 2, drv_bottom + drv_len).buffer(-tol).intersects(line):
        return "Driver"
    if rect(x - width / 2, kp_bottom, x + width / 2, kp_bottom + kpl).buffer(-tol).intersects(line):
        return "KeyPin"
    return "Clear"


def pick_geom(x, tip_y, floor):
    return LineString([(-14.0, floor + 0.6), (x - 1.4, floor + 0.6), (x, tip_y)])


def lock_static(lock: dict, chambers: list[dict]):
    n, sp = lock["PinCount"], lock["PinSpacing"]
    floor, top, shear = lock["FloorY"], lock["BladeTopY"], lock["ShearY"]
    ctop, w = lock["ChamberTopY"], lock["PinWidth"]
    L = (n + 1) * sp
    plug_holes = unary_union([rect(c["X"] - w / 2 - 0.05, top + 0.3, c["X"] + w / 2 + 0.05, shear) for c in chambers])
    shell_holes = unary_union([rect(c["X"] - w / 2 - 0.05, shear, c["X"] + w / 2 + 0.05, ctop) for c in chambers])
    plug = rect(0, 0, L, shear).difference(rect(0, floor - 0.1, L, top + 0.3)).difference(plug_holes)
    shell = rect(-1, -3, L + 1, ctop + 2).difference(rect(0, 0, L, shear)).difference(shell_holes)
    return {"Shell": shell, "Plug": plug, "ShearLine": hline(0, L, shear)}
