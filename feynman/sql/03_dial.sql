/* =====================================================================
   Feynman Safecracker Lab  —  03_dial.sql
   The Mosler filing cabinets: building the wheel pack, the strategies,
   the cracking procedure and "taking the last two numbers off".
   ===================================================================== */
USE FeynmanSafecracker;
GO

/* ---------------------------------------------------------------------
   Build the physical model of one cabinet: 3 wheels x 100 positions.
   The geometry answers the physics ONCE, here, and stores it as Clear.
   After that the search is a pure relational problem.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dial.usp_BuildWheelPack
    @CabinetId int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tol int, @n1 int, @n2 int, @n3 int;

    SELECT @tol = Tolerance, @n1 = N1, @n2 = N2, @n3 = N3
    FROM dial.Cabinet WHERE CabinetId = @CabinetId;
    IF @@ROWCOUNT = 0 THROW 50001, N'No such cabinet.', 1;

    DELETE dial.WheelGeom WHERE CabinetId = @CabinetId;
    DELETE dial.Bolt      WHERE CabinetId = @CabinetId;

    INSERT dial.Bolt (CabinetId, Geom)
    SELECT @CabinetId, geometry::UnionAggregate(dbo.fn_Rect(w.cx - 0.3, 8.6, w.cx + 0.3, 9.8))
    FROM (VALUES (0.0), (25.0), (50.0)) AS w(cx);

    INSERT dial.WheelGeom (CabinetId, WheelNo, DialPos, Geom, Clear)
    SELECT  @CabinetId, w.WheelNo, p.value,
            dial.fn_WheelShape(dial.fn_WheelCx(w.WheelNo), 0.0, w.Gate, p.value, @tol),
            0
    FROM (VALUES (1, @n3), (2, @n2), (3, @n1)) AS w(WheelNo, Gate)
    CROSS JOIN GENERATE_SERIES(0, 99) AS p;

    /* the only physics question we ever need to ask */
    UPDATE wg
       SET Clear = CASE WHEN wg.Geom.STIntersects(b.Geom) = 1 THEN 0 ELSE 1 END
    FROM dial.WheelGeom AS wg
    JOIN dial.Bolt      AS b ON b.CabinetId = wg.CabinetId
    WHERE wg.CabinetId = @CabinetId;
END;
GO

/* Does the bolt drop with the wheels at (A,B,C)? (A sets rear wheel 3) */
CREATE OR ALTER FUNCTION dial.fn_BoltDrops (@CabinetId int, @A int, @B int, @C int)
RETURNS TABLE
AS
RETURN
    SELECT CAST(MIN(CAST(Clear AS int)) AS bit) AS BoltDropped
    FROM dial.WheelGeom
    WHERE CabinetId = @CabinetId
      AND (   (WheelNo = 3 AND DialPos = @A)
           OR (WheelNo = 2 AND DialPos = @B)
           OR (WheelNo = 1 AND DialPos = @C));
GO

/* Snapshot of the mechanism for the SSMS Spatial results tab */
CREATE OR ALTER FUNCTION dial.fn_WheelPackAt (@CabinetId int, @A int, @B int, @C int)
RETURNS TABLE
AS
RETURN
    SELECT CONCAT('Wheel ', wg.WheelNo, ' @ ', wg.DialPos, IIF(wg.Clear = 1, ' (gate under bolt)', '')) AS Label,
           wg.Geom
    FROM dial.WheelGeom AS wg
    WHERE wg.CabinetId = @CabinetId
      AND (   (wg.WheelNo = 3 AND wg.DialPos = @A)
           OR (wg.WheelNo = 2 AND wg.DialPos = @B)
           OR (wg.WheelNo = 1 AND wg.DialPos = @C))
    UNION ALL
    SELECT IIF(d.BoltDropped = 1, 'Bolt DOWN - open!', 'Bolt held up'),
           IIF(d.BoltDropped = 1,
               b.Geom.STUnion(dbo.fn_Rect(-1, 7.4, 51, 7.6)),      -- draw it dropped into the gates
               b.Geom.STUnion(dbo.fn_Rect(-1, 10.6, 51, 10.8)))
    FROM dial.Bolt AS b
    CROSS APPLY dial.fn_BoltDrops(@CabinetId, @A, @B, @C) AS d
    WHERE b.CabinetId = @CabinetId
    UNION ALL
    SELECT CONCAT('Dial on ', @C), dial.fn_DialFace(80, 0, @C);
GO

/* ---------------------------------------------------------------------
   Candidate generators. Stage keeps strategies in Feynman's order of
   cheapness when they are combined ('Feynman' = everything he knew).
     1 Factory settings 25-0-25 / 50-25-50   (the locksmith's secret)
     2 Notebook: known 2nd & 3rd, try 20 firsts
     3 Psychology: constants, simple runs, dates
     4 Date sweep: month-day-year in steps of five (the Kerst method)
     5 The 8000 grid: multiples of five on every wheel
     6 Naive: every number, 1,000,000 of them (capped)
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dial.fn_Candidates (@CabinetId int, @Strategy varchar(20), @Max int)
RETURNS TABLE
AS
RETURN
    SELECT 1 AS Stage, CAST(d.Priority * 1000 + d.Seq AS bigint) AS K, d.A, d.B, d.C, d.Source
    FROM dial.Dictionary AS d
    WHERE d.Source LIKE 'Factory%'
      AND @Strategy IN ('Factory', 'Psychological', 'Feynman')

    UNION ALL
    SELECT 2, CAST(n.NoteId * 100 + a.value AS bigint), a.value, n.B, n.C,
           CONCAT('Notebook ', n.B, '-', n.C, IIF(n.Confidence = 'vague', ' (vague)', ''))
    FROM dial.Notebook AS n
    CROSS JOIN GENERATE_SERIES(0, 95, 5) AS a
    WHERE n.CabinetId = @CabinetId
      AND @Strategy IN ('Notebook', 'Feynman')

    UNION ALL
    SELECT 3, CAST(d.Priority * 1000 + d.Seq AS bigint), d.A, d.B, d.C, d.Source
    FROM dial.Dictionary AS d
    WHERE d.Source NOT LIKE 'Factory%'
      AND @Strategy IN ('Psychological', 'Feynman')

    UNION ALL
    SELECT 4, CAST((10 - m.value) * 10000 + dd.value * 100 + y.value AS bigint),
           m.value, dd.value, y.value, 'Date sweep m-d-y'
    FROM GENERATE_SERIES(0, 10, 5) AS m          -- months 1-12 need only 0,5,10
    CROSS JOIN GENERATE_SERIES(5, 30, 5) AS dd   -- days: six numbers
    CROSS JOIN GENERATE_SERIES(5, 45, 5) AS y    -- years 1903-47: nine numbers  => 162
    WHERE @Strategy = 'Psychological'

    UNION ALL
    SELECT 5, CAST(s.value AS bigint),
           (s.value / 400) * 5, ((s.value / 20) % 20) * 5, (s.value % 20) * 5, 'Feynman 8000 grid'
    FROM GENERATE_SERIES(0, 7999) AS s
    WHERE @Strategy IN ('Feynman8000', 'Feynman')

    UNION ALL
    SELECT 6, CAST(s.value AS bigint),
           s.value / 10000, (s.value / 100) % 100, s.value % 100, 'Naive: every number'
    FROM GENERATE_SERIES(0, IIF(@Strategy = 'Naive', @Max - 1, -1)) AS s;
GO

/* ---------------------------------------------------------------------
   Crack a cabinet.
     @DelayMs = 0  -> set-based: find the first candidate whose three wheels
                      are all Clear, then write the attempt log in one go.
     @DelayMs > 0  -> row by row with WAITFOR, so you can watch dial.Attempt
                      fill up (Python --live, or SSMS Messages tab).
   Time model (from the book: 400 back numbers in under half an hour,
   8000 in at most eight hours):
     only the third number changed  3.2 s
     second number changed         12.0 s
     first number changed          20.0 s
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dial.usp_Crack
    @CabinetId   int,
    @Strategy    varchar(20) = 'Feynman',
    @MaxAttempts int = 10000,
    @DelayMs     int = 0,
    @RunId       int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Strategy NOT IN ('Factory','Notebook','Psychological','Feynman8000','Feynman','Naive')
        THROW 50003, N'Strategy must be Factory, Notebook, Psychological, Feynman8000, Feynman or Naive.', 1;
    IF NOT EXISTS (SELECT 1 FROM dial.Cabinet WHERE CabinetId = @CabinetId)
        THROW 50001, N'No such cabinet.', 1;
    IF NOT EXISTS (SELECT 1 FROM dial.WheelGeom WHERE CabinetId = @CabinetId)
        EXEC dial.usp_BuildWheelPack @CabinetId;

    DECLARE @tol int = (SELECT Tolerance FROM dial.Cabinet WHERE CabinetId = @CabinetId);
    DECLARE @owner nvarchar(60) = (SELECT Owner FROM dial.Cabinet WHERE CabinetId = @CabinetId);
    DECLARE @msg nvarchar(400);

    INSERT dial.Run (CabinetId, Strategy) VALUES (@CabinetId, @Strategy);
    SET @RunId = SCOPE_IDENTITY();

    INSERT dial.Candidate (RunId, Seq, A, B, C, Source)
    SELECT TOP (@MaxAttempts)
           @RunId, ROW_NUMBER() OVER (ORDER BY c.Stage, c.K), c.A, c.B, c.C, c.Source
    FROM dial.fn_Candidates(@CabinetId, @Strategy, @MaxAttempts) AS c
    ORDER BY c.Stage, c.K;

    DECLARE @cands int = @@ROWCOUNT;
    SET @msg = CONCAT(N'Run ', @RunId, N': ', @owner, N' — ', @Strategy, N', ', @cands, N' candidates queued.');
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    /* the relational oracle: which is the first candidate that clears all three wheels? */
    DECLARE @HitSeq int;
    SELECT @HitSeq = MIN(c.Seq)
    FROM dial.Candidate AS c
    JOIN dial.WheelGeom AS w3 ON w3.CabinetId = @CabinetId AND w3.WheelNo = 3 AND w3.DialPos = c.A
    JOIN dial.WheelGeom AS w2 ON w2.CabinetId = @CabinetId AND w2.WheelNo = 2 AND w2.DialPos = c.B
    JOIN dial.WheelGeom AS w1 ON w1.CabinetId = @CabinetId AND w1.WheelNo = 1 AND w1.DialPos = c.C
    WHERE c.RunId = @RunId AND w1.Clear = 1 AND w2.Clear = 1 AND w3.Clear = 1;

    DECLARE @LastSeq int = COALESCE(@HitSeq, @cands);

    IF @DelayMs <= 0
    BEGIN
        INSERT dial.Attempt (RunId, Seq, A, B, C, Source, BoltDropped, StepSeconds, SimSeconds, Coverage)
        SELECT x.RunId, x.Seq, x.A, x.B, x.C, x.Source, x.BoltDropped, x.StepSeconds,
               SUM(x.StepSeconds) OVER (ORDER BY x.Seq ROWS UNBOUNDED PRECEDING),
               dial.fn_Coverage(x.A, x.B, x.C, @tol)
        FROM (
            SELECT c.RunId, c.Seq, c.A, c.B, c.C, c.Source,
                   CAST(IIF(c.Seq = @HitSeq, 1, 0) AS bit) AS BoltDropped,
                   CAST(CASE
                          WHEN LAG(c.A) OVER (ORDER BY c.Seq) IS NULL
                            OR LAG(c.A) OVER (ORDER BY c.Seq) <> c.A THEN 20.0
                          WHEN LAG(c.B) OVER (ORDER BY c.Seq) <> c.B THEN 12.0
                          ELSE 3.2 END AS decimal(6,1)) AS StepSeconds
            FROM dial.Candidate AS c
            WHERE c.RunId = @RunId AND c.Seq <= @LastSeq
        ) AS x;
    END
    ELSE
    BEGIN
        DECLARE @seq int = 1, @a int, @b int, @c int, @src varchar(40),
                @pa int = -1, @pb int = -1, @drop bit,
                @step decimal(6,1), @sim decimal(12,1) = 0,
                @wait datetime = DATEADD(MILLISECOND, @DelayMs, CAST(0 AS datetime));

        WHILE @seq <= @LastSeq
        BEGIN
            SELECT @a = A, @b = B, @c = C, @src = Source
            FROM dial.Candidate WHERE RunId = @RunId AND Seq = @seq;

            SELECT @drop = BoltDropped FROM dial.fn_BoltDrops(@CabinetId, @a, @b, @c);

            SET @step = CASE WHEN @a <> @pa THEN 20.0 WHEN @b <> @pb THEN 12.0 ELSE 3.2 END;
            SET @sim += @step;

            INSERT dial.Attempt (RunId, Seq, A, B, C, Source, BoltDropped, StepSeconds, SimSeconds, Coverage)
            VALUES (@RunId, @seq, @a, @b, @c, @src, @drop, @step, @sim, dial.fn_Coverage(@a, @b, @c, @tol));

            IF @seq % 25 = 0 OR @drop = 1
            BEGIN
                SET @msg = CONCAT(N'  try ', @seq, N': ', @a, N'-', @b, N'-', @c, N'  [', @src, N']',
                                  IIF(@drop = 1, N'  CLICK!', N''));
                RAISERROR(@msg, 0, 1) WITH NOWAIT;
            END;

            IF @drop = 1 BREAK;
            SELECT @pa = @a, @pb = @b, @seq += 1;
            WAITFOR DELAY @wait;
        END;
    END;

    /* wrap up */
    DECLARE @attempts int, @simTotal decimal(12,1), @fa int, @fb int, @fc int;
    SELECT @attempts = COUNT(*), @simTotal = MAX(SimSeconds) FROM dial.Attempt WHERE RunId = @RunId;
    SELECT @fa = A, @fb = B, @fc = C FROM dial.Attempt WHERE RunId = @RunId AND BoltDropped = 1;

    UPDATE dial.Run
       SET FinishedAt = SYSUTCDATETIME(), Candidates = @cands, Attempts = @attempts,
           SimSeconds = @simTotal, Opened = IIF(@fa IS NULL, 0, 1),
           FoundA = @fa, FoundB = @fb, FoundC = @fc
    WHERE RunId = @RunId;

    IF @fa IS NOT NULL
        UPDATE dial.Cabinet SET State = 'Open', W1 = @fc, W2 = @fb, W3 = @fa
        WHERE CabinetId = @CabinetId;

    SET @msg = IIF(@fa IS NULL,
        CONCAT(N'No luck after ', @attempts, N' tries.'),
        CONCAT(N'OPEN: ', @fa, N'-', @fb, N'-', @fc, N' after ', @attempts, N' tries, about ',
               CONVERT(varchar(8), DATEADD(SECOND, CAST(@simTotal AS int), CAST(0 AS datetime)), 108),
               N' at the dial.'));
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    SELECT r.RunId, c.Owner, r.Strategy, r.Candidates, r.Attempts,
           CONVERT(varchar(8), DATEADD(SECOND, CAST(r.SimSeconds AS int), CAST(0 AS datetime)), 108) AS TimeAtDial,
           r.Opened, CONCAT(r.FoundA, '-', r.FoundB, '-', r.FoundC) AS Combination
    FROM dial.Run AS r JOIN dial.Cabinet AS c ON c.CabinetId = r.CabinetId
    WHERE r.RunId = @RunId;
END;
GO

/* ---------------------------------------------------------------------
   "Taking the last two numbers off" an OPEN cabinet.
   Drawer open, dial left on ten, bolt down in the slot.
   Phase 1: step the dial away from ten in fives. The front wheel is
            picked up and pushed. The first step where the bolt will NOT
            drop back -> the step before is the last number.
   Phase 2: put the front wheel back on that number, go the other way in
            fives pushing the middle wheel -> second number.
   Abstraction: the drive-pin "fly" and the extra reversal turn are folded
   into "the wheel is picked up once the dial has travelled to it".
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dial.usp_TakeLastTwo
    @CabinetId int,
    @RunId     int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @state varchar(6), @w1 int, @w2 int, @w3 int, @open int, @owner nvarchar(60);

    SELECT @state = State, @w1 = W1, @w2 = W2, @w3 = W3, @open = OpenNumber, @owner = Owner
    FROM dial.Cabinet WHERE CabinetId = @CabinetId;
    IF @state IS NULL THROW 50001, N'No such cabinet.', 1;
    IF @state <> 'Open'
        THROW 50002, N'The drawer is shut. Feynman needs it left open, dial on ten, while he chats about physics.', 1;
    IF NOT EXISTS (SELECT 1 FROM dial.WheelGeom WHERE CabinetId = @CabinetId)
        EXEC dial.usp_BuildWheelPack @CabinetId;

    INSERT dial.Run (CabinetId, Strategy) VALUES (@CabinetId, 'TakeLastTwo');
    SET @RunId = SCOPE_IDENTITY();

    DECLARE @k int, @p int, @drop bit, @lastGood int, @stepNo int = 0;

    /* ---- phase 1: last number (front wheel) ---- */
    DECLARE @cur1 int = @w1, @dist1 int = ((@w1 - @open) % 100 + 100) % 100;
    SELECT @k = 0, @lastGood = NULL;
    WHILE @k <= 40
    BEGIN
        SET @p = (@open + 5 * @k) % 100;
        IF 5 * @k >= @dist1 SET @cur1 = @p;                    -- drive pin has caught the wheel
        SELECT @drop = BoltDropped FROM dial.fn_BoltDrops(@CabinetId, @w3, @w2, @cur1);
        SET @stepNo += 1;
        INSERT dial.Probe (RunId, StepNo, Phase, DialPos, W1, W2, W3, BoltDropped, Note)
        VALUES (@RunId, @stepNo, 'LastNumber', @p, @cur1, @w2, @w3, @drop,
                IIF(@drop = 1, N'back to ten: bolt drops', N'back to ten: bolt stays up — slot disturbed'));
        IF @drop = 0 BREAK;
        SELECT @lastGood = @p, @k += 1;
    END;
    IF @lastGood IS NULL THROW 50004, N'Wheels were not aligned — was the cabinet really open?', 1;
    DECLARE @estC int = @lastGood;

    /* ---- phase 2: second number (middle wheel), turning the other way ---- */
    SET @cur1 = @estC;
    DECLARE @cur2 int = @w2, @dist2 int = ((@estC - @w2) % 100 + 100) % 100;
    SELECT @k = 0, @lastGood = NULL;
    WHILE @k <= 40
    BEGIN
        SET @p = ((@estC - 5 * @k) % 100 + 100) % 100;
        IF 5 * @k >= @dist2 SET @cur2 = @p;
        SELECT @drop = BoltDropped FROM dial.fn_BoltDrops(@CabinetId, @w3, @cur2, @cur1);
        SET @stepNo += 1;
        INSERT dial.Probe (RunId, StepNo, Phase, DialPos, W1, W2, W3, BoltDropped, Note)
        VALUES (@RunId, @stepNo, 'SecondNumber', @p, @cur1, @cur2, @w3, @drop,
                IIF(@drop = 1, N'bolt drops', N'bolt stays up — second wheel disturbed'));
        IF @drop = 0 BREAK;
        SELECT @lastGood = @p, @k += 1;
    END;
    DECLARE @estB int = @lastGood;

    /* write it on the scrap of paper hidden inside his own lock */
    INSERT dial.Notebook (CabinetId, B, C, Confidence) VALUES (@CabinetId, @estB, @estC, 'taken');

    /* leave things as he found them: wheels back in line, drawer still open */
    UPDATE dial.Cabinet SET W1 = @estC, W2 = @estB WHERE CabinetId = @CabinetId;

    UPDATE dial.Run SET FinishedAt = SYSUTCDATETIME(), Attempts = @stepNo, Opened = 0,
                        FoundB = @estB, FoundC = @estC
    WHERE RunId = @RunId;

    DECLARE @msg nvarchar(200) = CONCAT(N'Notebook: ', @owner, N' — ', @estB, N', ', @estC,
                                        N'  (', @stepNo, N' wobbles of the dial)');
    RAISERROR(@msg, 0, 1) WITH NOWAIT;
    SELECT @owner AS Owner, @estB AS SecondNumber, @estC AS LastNumber, @stepNo AS Wobbles;
END;
GO

/* ---------------------------------------------------------------------
   Housekeeping: the owner opens it properly / spins the dial and walks off
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dial.usp_OwnerOpens @CabinetId int
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dial.Cabinet SET State = 'Open', W1 = N3, W2 = N2, W3 = N1 WHERE CabinetId = @CabinetId;
END;
GO

CREATE OR ALTER PROCEDURE dial.usp_LockCabinet @CabinetId int
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dial.Cabinet
       SET State = 'Locked',
           W1 = ABS(CHECKSUM(NEWID())) % 100,
           W2 = ABS(CHECKSUM(NEWID())) % 100,
           W3 = ABS(CHECKSUM(NEWID())) % 100
    WHERE CabinetId = @CabinetId;
END;
GO

/* Feynman space for a run: what's covered, what's left, where it opened */
CREATE OR ALTER FUNCTION dial.fn_SearchSpace (@RunId int)
RETURNS TABLE
AS
RETURN
    WITH U AS (SELECT dial.fn_Universe() AS G),
         C AS (SELECT geometry::UnionAggregate(Coverage) AS G FROM dial.Attempt WHERE RunId = @RunId)
    SELECT 'Universe' AS Layer, U.G AS Geom FROM U
    UNION ALL
    SELECT 'Covered', C.G FROM C WHERE C.G IS NOT NULL
    UNION ALL
    SELECT 'Remaining', IIF(C.G IS NULL, U.G, U.G.STDifference(C.G)) FROM U CROSS JOIN C
    UNION ALL
    SELECT CONCAT('OPEN ', a.A, '-', a.B, '-', a.C), a.Coverage.STBuffer(2)
    FROM dial.Attempt AS a WHERE a.RunId = @RunId AND a.BoltDropped = 1;
GO

/* =====================================================================
   SEED DATA — the cabinets from "Safecracker Meets Safecracker"
   Where the book doesn't give the first number, one is invented.
   ===================================================================== */
DELETE dial.Notebook; DELETE dial.Dictionary;
DBCC CHECKIDENT ('dial.Dictionary', RESEED, 0) WITH NO_INFOMSGS;

INSERT dial.Dictionary (Source, A, B, C, Priority) VALUES
 ('Factory default 25-0-25',     25,  0, 25,  1),
 ('Factory default 50-25-50',    50, 25, 50,  2),
 ('Secretary''s crib: pi',       31, 41, 59, 10),
 ('pi, reversed',                59, 41, 31, 11),
 ('pi, digits backwards',        95, 14, 13, 12),
 ('Psychology: e = 2.71828',     27, 18, 28, 20),
 ('Simple run',                  10, 20, 30, 30),
 ('Simple run',                  20, 40, 60, 31),
 ('Simple run',                  60, 40, 20, 32),
 ('Simple run',                  30, 20, 10, 33),
 ('Date: 6 Aug 1945',             8,  6, 45, 40),
 ('Date variant',                86, 19, 45, 41);

SET IDENTITY_INSERT dial.Cabinet ON;
INSERT dial.Cabinet (CabinetId, Owner, Location, N1, N2, N3, State, W1, W2, W3, Story) VALUES
 (1, N'Richard Feynman',      N'Los Alamos, Theoretical Division', 69, 32, 21, 'Locked', 70, 12, 3,
     N'His own cabinet, taken apart to see how it worked; 69-32-21 is the example in the book.'),
 (2, N'Robert Christy',       N'Los Alamos, T Division',           72, 35, 60, 'Open',   60, 35, 72,
     N'Left open during a physics chat. Feynman leans on it and wobbles the dial: "Christy — 35, 60".'),
 (3, N'Frederic de Hoffmann', N'Declassification Section, cabinet 1', 27, 18, 28, 'Locked', 3, 66, 91,
     N'Nine cabinets holding the secrets of the bomb. After pi failed, the psychology method: e.'),
 (4, N'Frederic de Hoffmann', N'Declassification Section, cabinet 2', 27, 18, 28, 'Locked', 44, 9, 50,
     N'Same combination. Note left: borrowed document LA4312.'),
 (5, N'Frederic de Hoffmann', N'Declassification, next room',      27, 18, 28, 'Locked', 81, 77, 12,
     N'Same combination again. "Same Guy."'),
 (6, N'Donald Kerst',         N'Los Alamos',                       0,  5, 35, 'Locked', 50, 50, 50,
     N'Opened cold with an audience: dates swept in fives, 162 tries at most. 0-5-35 — a daughter''s birthday.'),
 (7, N'The Captain',          N'Los Alamos, upstairs office',      50, 25, 50, 'Locked', 13, 88, 2,
     N'The heavy steel safe hauled upstairs on jacks. Never changed from the factory setting.'),
 (8, N'Plant manager',        N'Oak Ridge',                        65, 10, 45, 'Locked', 22, 71, 6,
     N'Last two numbers taken a month earlier and half remembered: 40-15? 15-40? It was 10-45.'),
 (9, N'The Colonel',          N'Oak Ridge, two-door safe',         82, 57, 14, 'Open',   14, 57, 82,
     N'Big brass doors, same little Mosler bolt. Numbers taken while the colonel read the report.'),
 (10, N'Computing department', N'Los Alamos',                      41, 19, 63, 'Locked', 0, 0, 0,
     N'The Staley demonstration: first two numbers happened to be right. Complete luck.'),
 (11, N'Unknown cabinet',      N'Los Alamos',                      87, 43, 71, 'Locked', 5, 5, 5,
     N'No clues at all. The full 8000.');
SET IDENTITY_INSERT dial.Cabinet OFF;

INSERT dial.Notebook (CabinetId, B, C, Confidence) VALUES
 (8, 40, 15, 'vague'),
 (8, 15, 40, 'vague'),
 (8, 10, 45, 'vague');

DECLARE @id int = 1;
WHILE @id <= 11
BEGIN
    EXEC dial.usp_BuildWheelPack @id;
    SET @id += 1;
END;
GO
