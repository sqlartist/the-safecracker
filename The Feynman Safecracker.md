Declassified · Los Alamos · 1943–46

# The Feynman Safecracker

A SQL Server 2025 reconstruction of how a physicist beat a million combinations — and the lock that came after

Richard Feynman cracked the safes holding the secrets of the atomic bomb. Not with a drill or a stethoscope, but with arithmetic: he noticed the locks were *sloppy*, and that slop leaked information. This is that process, rebuilt inside a database — every wheel, bolt and pin modelled as geometry, every attempt logged, so you can watch the maths do the work.

## The thing he actually spotted

The filing cabinets at Los Alamos used Mosler combination locks: three numbers, 0–99, turned left-right-left. Nominally a million combinations. But Feynman took his own lock apart and measured the slop. A number would still open the safe if you were **off by two in either direction**. So you never had to try every number — only every fifth one: 0, 5, 10, 15… Twenty values per wheel.

| Try every single number | 100 × 100 × 100 = 1,000,000 |
| --- | --- |
| Only multiples of five (±2 slop) | 20 × 20 × 20 = 8,000 |
| Worst case, at his practised rhythm | ≈ 8 hours |
| With the last two numbers already known | 20 tries · minutes |

That last row is the real trick, and it's where it stops being honest arithmetic and starts being mischief.

## Taking the last two numbers off

When someone leaves a drawer open with the dial resting on ten, the bolt is still sitting down in the slot — which means the three wheels are still lined up. Feynman would lean on an open filing cabinet mid-conversation and *wobble the dial*. Step away from ten in fives; each time, back to ten. The moment the bolt won't drop back, the slot has been disturbed — and the step *before* that was the last number. Do it again the other way for the second number. He wrote them on a scrap of paper hidden inside his own lock.

![Animation: the dial, the three-wheel pack, and the backend probe log reading the last two numbers off Christy's open cabinet](dial_christy.gif)

Christy's cabinet, left open. The database wobbles the dial (`dial.usp_TakeLastTwo`), logging every step to `dial.Probe`. When the bolt "STAYS" up at 65, the last number is fixed at 60; the second comes out 35 — "Christy — 35, 60," exactly as in the book. After that, opening it cold means trying only twenty first numbers.

> You could be off by two in either direction. With twenty such numbers on a wheel of 100, that was 8000 possibilities instead of the 1,000,000 you would get if you had to try every single number. Richard Feynman — “Safecracker Meets Safecracker”, Surely You're Joking, Mr. Feynman! (1985)

## Three tricks people blur together

The maths

### Tolerance

The mechanism's ±2 slop collapses a million to 8,000. Honest, and his own discovery.

The cheat

### The open drawer

Read the last two numbers off any cabinet left open, then "open it cold" in minutes — twenty first numbers while reading a magazine so it didn't look too easy.

The shortcuts

### Psychology & factory

De Hoffmann's bomb-secret cabinets opened on **27-18-28** — the digits of *e*. Kerst's on **0-5-35**, a daughter's birthday. And half the safes were never changed from the factory **25-0-25** or **50-25-50**.

## Modelling it as geometry

In the database nothing is faked with arithmetic. Each wheel, at each of its 100 positions, is a real `geometry` disc with a gate notch cut into its rim. The bolt is a small bar above each wheel. The entire physics of the lock reduces to one spatial question, asked once and stored:

```
-- does the bolt clear this wheel at this dial position?
UPDATE wg SET Clear = CASE WHEN wg.Geom.STIntersects(b.Geom) = 1
                           THEN 0 ELSE 1 END
FROM dial.WheelGeom wg JOIN dial.Bolt b ON b.CabinetId = wg.CabinetId;
```

Once every position knows whether its gate sits under the bolt, cracking the safe is a pure relational search: find the first candidate combination whose three wheels are *all* clear. The slop falls out of the geometry automatically — a gate cut wide enough leaves exactly five clear dial positions, which *is* the ±2.

### Feynman space

Every attempt is logged to `dial.Attempt` with a running clock, and each try also carves out a 5×5 patch of the search space it has ruled out — twenty first-number bands, each a 100×100 grid of the second and third numbers. You can watch the 8,000 shrink.

![Animation: cracking a cabinet with no clues — the dial turning, the wheel pack, and the Feynman-space grid filling in as attempts are logged](dial_unknown.gif)

A cabinet with no clues at all: the full 8,000 (`dial.usp_Crack … @Strategy='Feynman8000'`). Left, the mechanism; right, "Feynman space" filling in blue as `dial.Attempt` logs each try. The bolt drops the instant all three gates line up.

![Bar chart comparing how long each safe took, from the Captain's factory setting at forty seconds to brute force at eighteen hours](scoreboard.png)

Every episode, timed at his own rhythm. The Captain's factory-set safe: forty seconds. Brute force without the tolerance trick: off the chart. The methods, not the muscle, are the whole story.

## The lock that came after — keys and picking

Feynman learned to pick ordinary pin-tumbler locks from a man named Leo Lavatelli, and his description of it is the same insight as the dial: a real lock isn't made perfectly, so *one pin holds more of the load than the others*. Lift that one to the right height, the plug gives a hair, the pin catches on the edge — and the load moves to the next pin. Push too far and the springs drop everything back: *tic-tic-tic*. Sisyphus.

So the second half of the lab is a see-through practice lock, the kind sold as a transparent teaching kit, built entirely from geometry. A key's cuts are a profile; each pin rides it; the plug turns only if every gap lands on the shear line.

![Animation: a near-miss key inserted into the transparent lock; four pins reach the shear line but the fifth is cut too deep and blocks](pin_key_nextdoor.gif)

The right key lifts every pin so the gap between key pin and driver sits exactly on the red shear line. Next door's key is cut one step too deep on pin 4 — its driver crosses the line and the plug won't turn. The database decides this with `STIntersects` against the shear-line, chamber by chamber.

![Animation: single-pin picking the transparent lock — the pick lifting each binding pin to the shear line, with an overset that drops everything and restarts](pin_pick.gif)

Single-pin picking (`pin.usp_Pick`): tension on, find the binding pin, lift until it sets with a click, move to the next. Overshoot at the shear line and it oversets — tension off, every pin drops, start again. Exactly Feynman's "Sisyphus."

And because the pick records how high each pin had to go, the database can read the bitting straight back off a successful pick and **cut a working key** — the pin-tumbler version of taking the last two numbers off.

## What's in the package

Four T-SQL scripts build the whole thing on a SQL Server 2025 instance; a Python front end draws it, either from the live database (geometry crosses the wire as WKT and is drawn exactly as the database computed it) or from a built-in simulator that reproduces every episode, so the visuals run with no server at all.

**sql/**01_schema · 02_geometry · 03_dial · 04_pin_tumbler · 05_demo\
**python/**dial_viz.py · pin_viz.py · feynman_lab/ (geometry mirror, simulators, SQL driver)\
**out/**pre-rendered animations + the scoreboard

Run `05_demo.sql` in SSMS with the *Spatial results* tab on to see the wheel pack, Feynman space and the see-through lock; or `python dial_viz.py --source sql --live` to watch `dial.usp_Crack` write rows in real time.

---

Source: “Safecracker Meets Safecracker,” from Surely You're Joking, Mr. Feynman! (1985). The combinations shown — de Hoffmann's 27-18-28, Kerst's 0-5-35, the factory 25-0-25 / 50-25-50, Christy's 35-60 — are the ones Feynman records. First-number values and a few cabinets are invented to fill out the set; the mechanics are his.