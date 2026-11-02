# The Feynman Safecracker Lab

A database that cracks safes the way Richard Feynman did at Los Alamos — the
combination dials first, then a see-through pin-tumbler lock — with the whole
mechanism modelled in **SQL Server 2025 geometry** and a **Python** front end
that lets you watch it happen.

Built in the same spirit as the other "X in SQL Server" projects: the point
isn't that you *should* do this in T-SQL, it's that you *can*, and that doing
it forces you to understand both the safe and the database better.

---

## What Feynman actually did

From the chapter *"Safecracker Meets Safecracker"* in *Surely You're Joking,
Mr. Feynman!* (1985). Three separate tricks, which people usually blur together:

**1. The tolerance trick (the maths).** The Mosler combination dials ran 0–99,
three numbers — a nominal million combinations. But the mechanism was slack:
a number would open "off by two in either direction." So you only had to try
every *fifth* number — 0, 5, 10, … — which is 20 values per wheel, and
20 × 20 × 20 = **8,000**, not 1,000,000. At a practised rhythm he could try the
400 back-number combinations in under half an hour, so a cold safe was a
maximum of eight hours, four on average.

**2. Taking the last two numbers off (the cheat).** When a drawer is left open
with the dial still on ten, the bolt is sitting down in the slot — the wheels
are aligned. Wobble the dial away from ten in small steps and the moment the
bolt *won't* drop back, the step before was the last number. Do it again the
other way for the second number. He'd lean on people's open filing cabinets
mid-conversation and read the numbers off, then write them on a scrap of paper
hidden *inside his own lock*. After that, opening "cold" meant trying only the
**20 possible first numbers** — a few minutes, dressed up to look like an hour.

**3. The psychology / factory settings (the shortcuts).** The safecracker books
suggested owners pick dates and constants. De Hoffmann's cabinets holding the
bomb secrets opened on **27-18-28** — the digits of *e*, 2.71828. Kerst's opened
on **0-5-35**, his daughter's birthday, found by sweeping dates in fives (≤ 162
tries). And the Los Alamos locksmith's real secret: half the safes were never
changed from the factory settings **25-0-25** or **50-25-50**. The Captain's
specially-hoisted steel safe was one of them.

The same idea runs through all three and through the pin-tumbler lock he learned
from Leo Lavatelli: **a real mechanism has slop, and slop leaks information.**

---

## How the database models it

Everything physical is a `geometry` value, and the physics is answered by
spatial predicates rather than by arithmetic:

| Question | How the DB answers it |
|---|---|
| Does the bolt drop at (A,B,C)? | `Bolt.STIntersects(wheel) = 0` for all three wheels |
| How much slop does a wheel have? | count of dial positions where the gate clears the bolt (5 = ±2) |
| Is a pin set? | nothing straddles the shear-line `LINESTRING` in that chamber |
| How deep is a key cut? | vertical `LINESTRING` ∩ key outline = the height the pin rides to |
| What has one try ruled out? | a 5×5 `POLYGON` patch of "Feynman space" |

### `dial` schema — the Mosler filing cabinets
- `dial.Cabinet` — the eleven safes from the book, with their true combinations.
- `dial.WheelGeom` — 3 wheels × 100 positions as geometry, each tagged `Clear`
  (does the gate sit under the bolt here?). The geometry answers the physics
  **once**; after that the crack is a pure relational search.
- `dial.usp_Crack` — runs a strategy (`Factory`, `Notebook`, `Psychological`,
  `Feynman8000`, `Feynman`, `Naive`), logs every attempt to `dial.Attempt` with
  a running clock, and finds the opening combination with a set-based "oracle"
  query. Pass `@DelayMs > 0` to make it crack row-by-row with `WAITFOR` so you
  can watch it live.
- `dial.usp_TakeLastTwo` — the open-drawer trick, logged wobble-by-wobble to
  `dial.Probe`, writing the two numbers into `dial.Notebook`.
- `dial.fn_SearchSpace` — "Feynman space" as geometry: 20 first-number bands,
  what's been covered, what's left, where it opened.

### `pin` schema — the transparent practice lock
- `pin.Lock` / `pin.Chamber` — a five-pin lock, secret bitting `3-5-2-7-4`, with
  a per-pin `BindOffset` (the manufacturing imperfection that makes one pin bind
  first).
- `pin.usp_UseKey` — slide a key in frame by frame; each pin rides the key's
  profile; turn only if every gap lands on the shear line.
- `pin.usp_Pick` — single-pin picking: tension on, find the binding pin, lift in
  quarter steps until it sets with a click, risk an overset that drops
  everything (`tic-tic-tic`), repeat. Every frame is stored in `pin.Frame` /
  `pin.FramePart` as geometry.
- `pin.usp_DecodeKey` — read the bitting back off a successful pick and cut a key.

---

## Running it

### The SQL (needs a SQL Server 2025 instance, compat level 160+)
```
sqlcmd -S localhost -i sql/01_schema.sql
sqlcmd -S localhost -i sql/02_geometry.sql
sqlcmd -S localhost -i sql/03_dial.sql
sqlcmd -S localhost -i sql/04_pin_tumbler.sql
-- then work through sql/05_demo.sql in SSMS with the Spatial results tab on
```
`05_demo.sql` walks every episode. Turn on **Results → Spatial results** to see
the wheel pack, Feynman space, and the see-through lock; watch the **Messages**
tab while cracking.

### The Python visualisers (no SQL Server needed — it has a built-in simulator)
```
pip install -r python/requirements.txt
cd python

# the dial episodes (simulator by default)
python dial_viz.py --episode christy        # taking the last two numbers off
python dial_viz.py --episode kerst          # the date sweep, cold
python dial_viz.py --episode unknown        # the full 8,000
python dial_viz.py --episode all --gif out  # render every episode to GIFs
python dial_viz.py --scoreboard score.png   # how long each safe took

# the see-through lock
python pin_viz.py --mode key --key 1        # the right key opens it
python pin_viz.py --mode key --key 2        # next door's key jams on pin 4
python pin_viz.py --mode pick               # single-pin picking
python pin_viz.py --mode decode             # pick it, then cut the key
```

### Driving the visualisers from the real database
```
export FEYNMAN_SQL="Driver={ODBC Driver 18 for SQL Server};Server=localhost;Database=FeynmanSafecracker;Trusted_Connection=yes;TrustServerCertificate=yes;"
python dial_viz.py --source sql --episode dehoffmann
python dial_viz.py --source sql --live --cabinet 10 --strategy Feynman8000
```
`--live` starts `dial.usp_Crack` with a delay on a second connection and draws
each `dial.Attempt` row as the stored procedure writes it — the backend running
in real time. Geometry crosses the wire as WKT (`STAsText`) and is drawn exactly
as the database computed it, so the Python is showing you the database's own
work, not a re-implementation.

> **Note on verification.** Every
> algorithm is mirrored and validated in `python/feynman_lab/` — the simulator
> reproduces each episode's real outcome (de Hoffmann 27-18-28, Kerst 0-5-35,
> the Captain's factory setting, Christy's 35-60, the full 8,000). Run the four
> SQL scripts on your own instance to light up the spatial views.

---

## Files
```
sql/01_schema.sql        tables for both schemas
sql/02_geometry.sql      geometry builder functions (the physics)
sql/03_dial.sql          dial model, strategies, usp_Crack, usp_TakeLastTwo, seed data
sql/04_pin_tumbler.sql   the see-through lock: usp_UseKey, usp_Pick, usp_DecodeKey
sql/05_demo.sql          a guided tour, episode by episode
python/dial_viz.py       the dial animations + scoreboard + live mode
python/pin_viz.py        the transparent-lock animations
python/feynman_lab/      geometry mirror, simulators, SQL source, drawing helpers
out/                     pre-rendered GIFs and the scoreboard
```
