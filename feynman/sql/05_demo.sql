/* =====================================================================
   Feynman Safecracker Lab  —  05_demo.sql
   Run a section at a time in SSMS. Turn on Results > Spatial results tab
   for the geometry queries, and watch the Messages tab while cracking.
   ===================================================================== */
USE FeynmanSafecracker;
GO

/* ---------------------------------------------------------------------
   0. Look at the mechanism.  (Spatial results tab; pick "Label" as label)
   Feynman's own cabinet, set to his example 69-32-21: bolt drops.
   --------------------------------------------------------------------- */
SELECT Label, Geom FROM dial.fn_WheelPackAt(1, 69, 32, 21);
-- off by two on every wheel: still opens
SELECT Label, Geom FROM dial.fn_WheelPackAt(1, 67, 34, 19);
-- off by three on the front wheel: bolt held up
SELECT Label, Geom FROM dial.fn_WheelPackAt(1, 69, 32, 24);

/* How many dial numbers clear each wheel? (5 each = tolerance +/- 2) */
SELECT WheelNo, COUNT(*) AS ClearPositions,
       STRING_AGG(CAST(DialPos AS varchar(3)), ',') WITHIN GROUP (ORDER BY DialPos) AS Positions
FROM dial.WheelGeom WHERE CabinetId = 1 AND Clear = 1
GROUP BY WheelNo;

/* The arithmetic that started it all */
SELECT 100 * 100 * 100                                  AS EveryNumber,
       20 * 20 * 20                                     AS MultiplesOfFive,
       20                                               AS WithLastTwoKnown,
       CONVERT(varchar(8), DATEADD(SECOND, 8000 * 3.6, CAST(0 AS datetime)), 108) AS WorstCase8000;

/* ---------------------------------------------------------------------
   1. The Captain's safe — factory setting. Second try.
   --------------------------------------------------------------------- */
DECLARE @run int;
EXEC dial.usp_Crack @CabinetId = 7, @Strategy = 'Factory', @RunId = @run OUTPUT;
SELECT Seq, A, B, C, Source, BoltDropped FROM dial.Attempt WHERE RunId = @run ORDER BY Seq;
GO

/* ---------------------------------------------------------------------
   2. Christy's cabinet: drawer left open. Take the last two numbers off,
      let him lock it, come back later and open it in <= 20 tries.
   --------------------------------------------------------------------- */
DECLARE @probe int, @run int;
EXEC dial.usp_TakeLastTwo @CabinetId = 2, @RunId = @probe OUTPUT;
SELECT StepNo, Phase, DialPos, W1, W2, W3, BoltDropped, Note FROM dial.Probe WHERE RunId = @probe ORDER BY StepNo;
SELECT * FROM dial.Notebook;            -- the scrap of paper inside Feynman's lock

EXEC dial.usp_LockCabinet 2;            -- Christy spins the dial and goes out of town
EXEC dial.usp_Crack @CabinetId = 2, @Strategy = 'Notebook', @RunId = @run OUTPUT;
GO

/* ---------------------------------------------------------------------
   3. de Hoffmann's nine cabinets: pi from the secretary's sheet fails,
      the psychology method (e) works — on all of them.
   --------------------------------------------------------------------- */
DECLARE @run int;
EXEC dial.usp_Crack @CabinetId = 3, @Strategy = 'Psychological', @RunId = @run OUTPUT;
EXEC dial.usp_Crack @CabinetId = 4, @Strategy = 'Psychological';
EXEC dial.usp_Crack @CabinetId = 5, @Strategy = 'Psychological';
SELECT Seq, A, B, C, Source, BoltDropped FROM dial.Attempt WHERE RunId = @run ORDER BY Seq;
GO

/* ---------------------------------------------------------------------
   4. Kerst's safe, cold, with an audience: the date sweep.
   --------------------------------------------------------------------- */
DECLARE @run int;
EXEC dial.usp_Crack @CabinetId = 6, @Strategy = 'Psychological', @RunId = @run OUTPUT;
SELECT Source, COUNT(*) AS Tries FROM dial.Attempt WHERE RunId = @run GROUP BY Source;
GO

/* ---------------------------------------------------------------------
   5. Oak Ridge: half-remembered numbers (40-15? 15-40? 10-45).
   --------------------------------------------------------------------- */
EXEC dial.usp_Crack @CabinetId = 8, @Strategy = 'Notebook';
GO

/* ---------------------------------------------------------------------
   6. The colonel's two-door safe: numbers taken while he read the report,
      then "forty-five minutes" that took about seven.
   --------------------------------------------------------------------- */
DECLARE @probe int;
EXEC dial.usp_TakeLastTwo 9, @probe OUTPUT;
EXEC dial.usp_LockCabinet 9;
EXEC dial.usp_Crack 9, 'Notebook';
GO

/* ---------------------------------------------------------------------
   7. No clues: the full 8000, and what naive would have cost.
   --------------------------------------------------------------------- */
DECLARE @run int;
EXEC dial.usp_Crack @CabinetId = 11, @Strategy = 'Feynman8000', @RunId = @run OUTPUT;

-- Feynman space: run this and look at the Spatial results tab
SELECT Layer, Geom FROM dial.fn_SearchSpace(@run);

-- how much of the space was searched before it opened?
SELECT CAST(100.0 * c.Geom.STArea() / u.Geom.STArea() AS decimal(5,1)) AS PctSearched
FROM dial.fn_SearchSpace(@run) AS c
CROSS JOIN dial.fn_SearchSpace(@run) AS u
WHERE c.Layer = 'Covered' AND u.Layer = 'Universe';
GO

-- naive, capped at 20,000 tries: still on first numbers 0 and 1 — 2% of a million
EXEC dial.usp_Crack @CabinetId = 11, @Strategy = 'Naive', @MaxAttempts = 20000;
GO

/* ---------------------------------------------------------------------
   8. Scoreboard
   --------------------------------------------------------------------- */
SELECT r.RunId, c.Owner, c.Location, r.Strategy, r.Attempts,
       CONVERT(varchar(8), DATEADD(SECOND, CAST(r.SimSeconds AS int), CAST(0 AS datetime)), 108) AS TimeAtDial,
       r.Opened, CONCAT(r.FoundA, '-', r.FoundB, '-', r.FoundC) AS Found
FROM dial.Run AS r JOIN dial.Cabinet AS c ON c.CabinetId = r.CabinetId
ORDER BY r.RunId;
GO

/* ---------------------------------------------------------------------
   9. Watch it live: run this in one window, and in another either
        python dial_viz.py --source sql --live
      or keep re-running the SELECT below.
   --------------------------------------------------------------------- */
-- EXEC dial.usp_LockCabinet 10;
-- EXEC dial.usp_Crack @CabinetId = 10, @Strategy = 'Feynman8000', @DelayMs = 50;
-- SELECT TOP (20) * FROM dial.Attempt ORDER BY AttemptedAt DESC;

/* =====================================================================
   PIN TUMBLER
   ===================================================================== */

/* the lock, see-through (Spatial results tab) */
SELECT Part, Geom FROM pin.Static WHERE LockId = 1;

/* 10. The right key, next door's key, and a blank */
DECLARE @run int;
EXEC pin.usp_UseKey 1, 1, @run OUTPUT;     -- opens
EXEC pin.usp_UseKey 1, 2;                  -- pin 4 too deep: driver across the line
EXEC pin.usp_UseKey 1, 3;                  -- blank: every key pin pushed too high

-- final frame of the right key, everything in one picture
SELECT fp.Part + ISNULL(' ' + CAST(fp.PinNo AS varchar(3)), '') + ISNULL(' ' + fp.State, '') AS Label, fp.Geom
FROM pin.FramePart AS fp
WHERE fp.RunId = @run AND fp.FrameNo = (SELECT MAX(FrameNo) FROM pin.Frame WHERE RunId = @run)
UNION ALL SELECT Part, Geom FROM pin.Static WHERE LockId = 1;
GO

/* 11. Pick it, then cut a key from what the pins told us */
DECLARE @pick int, @key int, @run int;
EXEC pin.usp_Pick @LockId = 1, @Seed = 1945, @OversetChance = 0.25, @RunId = @pick OUTPUT;
SELECT FrameNo, Caption, Tension, PlugRotation FROM pin.Frame WHERE RunId = @pick ORDER BY FrameNo;
SELECT * FROM pin.PickLog WHERE RunId = @pick ORDER BY SetOrder;

EXEC pin.usp_DecodeKey @pick, @key OUTPUT;
EXEC pin.usp_UseKey 1, @key, @run OUTPUT;   -- the decoded key opens the lock
GO
