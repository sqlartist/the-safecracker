/* =====================================================================
   Feynman Safecracker Lab  —  04_pin_tumbler.sql
   A transparent pin-tumbler practice lock, built from geometry.

   Feynman's own description of picking (he learned it from Leo Lavatelli):
   the lock isn't made perfectly, so one pin holds more of the load than
   the rest. Lift THAT pin to the right height, the plug gives a little,
   the pin stays caught on the edge, and the load moves to another pin.
   Push too far, or let go of the tension, and the springs click
   everything back down — tic-tic-tic. Sisyphus.

   That imperfection is the same idea as the +/- 2 on the dial: the
   mechanism's tolerances leak information, and he exploited both.

   Procedures
     pin.usp_BuildLock   static geometry: shell, plug, shear line
     pin.usp_UseKey      slide a key in, frame by frame; turn if it's right
     pin.usp_Pick        single-pin picking with tension, binding order, oversets
     pin.usp_DecodeKey   read the bitting off a successful pick and cut a key
   ===================================================================== */
USE FeynmanSafecracker;
GO

CREATE OR ALTER PROCEDURE pin.usp_BuildLock @LockId int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @n int, @sp float, @floor float, @top float, @shear float, @ctop float, @w float;
    SELECT @n = PinCount, @sp = PinSpacing, @floor = FloorY, @top = BladeTopY,
           @shear = ShearY, @ctop = ChamberTopY, @w = PinWidth
    FROM pin.Lock WHERE LockId = @LockId;
    IF @n IS NULL THROW 50010, N'No such lock.', 1;

    DECLARE @L float = (@n + 1) * @sp;      -- plug length

    /* chamber holes: one geometry per half */
    DECLARE @plugHoles geometry, @shellHoles geometry;
    SELECT @plugHoles  = geometry::UnionAggregate(dbo.fn_Rect(X - @w / 2 - 0.05, @top + 0.3, X + @w / 2 + 0.05, @shear)),
           @shellHoles = geometry::UnionAggregate(dbo.fn_Rect(X - @w / 2 - 0.05, @shear,     X + @w / 2 + 0.05, @ctop))
    FROM pin.Chamber WHERE LockId = @LockId;

    DECLARE @plug geometry =
        dbo.fn_Rect(0, 0, @L, @shear)
           .STDifference(dbo.fn_Rect(0, @floor - 0.1, @L, @top + 0.3))   -- keyway
           .STDifference(@plugHoles);

    DECLARE @shell geometry =
        dbo.fn_Rect(-1, -3, @L + 1, @ctop + 2)
           .STDifference(dbo.fn_Rect(0, 0, @L, @shear))                  -- the bore the plug turns in
           .STDifference(@shellHoles);

    DELETE pin.Static WHERE LockId = @LockId;
    INSERT pin.Static (LockId, Part, Geom) VALUES
        (@LockId, 'Shell',     @shell),
        (@LockId, 'Plug',      @plug),
        (@LockId, 'ShearLine', dbo.fn_HLine(0, @L, @shear));
END;
GO

/* Writes one animation frame from the caller's #Pins table.
   #Pins(PinNo, X, Kpl, KpBottom, DrvBottom, State) must exist. */
CREATE OR ALTER PROCEDURE pin.usp_WriteFrame
    @RunId    int,
    @FrameNo  int,
    @Caption  nvarchar(120),
    @Tension  bit,
    @Rotation float,
    @Key      geometry = NULL,
    @Pick     geometry = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @w float, @drv float, @ctop float;
    SELECT @w = l.PinWidth, @drv = l.DriverLen, @ctop = l.ChamberTopY
    FROM pin.Run AS r JOIN pin.Lock AS l ON l.LockId = r.LockId
    WHERE r.RunId = @RunId;

    INSERT pin.Frame (RunId, FrameNo, Caption, Tension, PlugRotation)
    VALUES (@RunId, @FrameNo, @Caption, @Tension, @Rotation);

    INSERT pin.FramePart (RunId, FrameNo, PartNo, Part, PinNo, State, Geom)
    SELECT @RunId, @FrameNo, ROW_NUMBER() OVER (ORDER BY v.Ord, p.PinNo), v.Part, p.PinNo, p.State, v.Geom
    FROM #Pins AS p
    CROSS APPLY (VALUES
        (1, 'KeyPin', dbo.fn_Rect(p.X - @w / 2, p.KpBottom,  p.X + @w / 2, p.KpBottom + p.Kpl)),
        (2, 'Driver', dbo.fn_Rect(p.X - @w / 2, p.DrvBottom, p.X + @w / 2, p.DrvBottom + @drv)),
        (3, 'Spring', pin.fn_Spring(p.X, p.DrvBottom + @drv, @ctop, @w * 0.8))
    ) AS v(Ord, Part, Geom);

    DECLARE @next int = (SELECT COUNT(*) * 3 FROM #Pins);
    IF @Key IS NOT NULL
        INSERT pin.FramePart (RunId, FrameNo, PartNo, Part, PinNo, State, Geom)
        VALUES (@RunId, @FrameNo, @next + 1, 'Key', NULL, NULL, @Key);
    IF @Pick IS NOT NULL
        INSERT pin.FramePart (RunId, FrameNo, PartNo, Part, PinNo, State, Geom)
        VALUES (@RunId, @FrameNo, @next + 2, 'Pick', NULL, NULL, @Pick);
END;
GO

/* ---------------------------------------------------------------------
   Use a key. Each pin rides the key's profile (STIntersection of a vertical
   line through the chamber with the key outline). Fully home, every gap
   must sit on the shear line or the plug won't turn.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE pin.usp_UseKey
    @LockId int,
    @KeyId  int,
    @RunId  int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @bitting varchar(12), @keyName nvarchar(60);
    SELECT @bitting = Bitting, @keyName = Name FROM pin.Keys WHERE KeyId = @KeyId;
    IF @bitting IS NULL THROW 50011, N'No such key.', 1;

    DECLARE @n int, @sp float, @floor float, @shear float, @tol float, @drv float, @w float;
    SELECT @n = PinCount, @sp = PinSpacing, @floor = FloorY, @shear = ShearY,
           @tol = Tolerance, @drv = DriverLen, @w = PinWidth
    FROM pin.Lock WHERE LockId = @LockId;
    IF LEN(@bitting) <> @n THROW 50012, N'That key has the wrong number of cuts for this lock.', 1;
    IF NOT EXISTS (SELECT 1 FROM pin.Static WHERE LockId = @LockId) EXEC pin.usp_BuildLock @LockId;

    INSERT pin.Run (LockId, Mode, KeyId, Resets) VALUES (@LockId, 'Key', @KeyId, 0);
    SET @RunId = SCOPE_IDENTITY();

    CREATE TABLE #Pins (PinNo tinyint PRIMARY KEY, X float, Kpl float, KpBottom float, DrvBottom float, State varchar(10));
    INSERT #Pins (PinNo, X, Kpl, KpBottom, DrvBottom, State)
    SELECT PinNo, X, KeyPinLen, @floor, @floor + KeyPinLen, 'Rest' FROM pin.Chamber WHERE LockId = @LockId;

    DECLARE @frame int = 0, @off float = -(@n + 1) * @sp, @key geometry, @cap nvarchar(120);

    /* slide it in, one unit at a time */
    WHILE @off <= 0
    BEGIN
        SET @key = pin.fn_KeyGeom(@LockId, @bitting, @off);
        UPDATE #Pins SET KpBottom = pin.fn_SurfaceY(@key, X, @floor);
        UPDATE #Pins SET DrvBottom = KpBottom + Kpl,
                         State = IIF(KpBottom > @floor + 0.001, 'Riding', 'Rest');
        SET @frame += 1;
        SET @cap = CONCAT(N'Inserting ', @keyName, N' (', @bitting, N')');
        EXEC pin.usp_WriteFrame @RunId, @frame, @cap, 0, 0, @key, NULL;
        SET @off += 1.0;
    END;

    /* fully home: who is straddling the shear line? */
    UPDATE #Pins
       SET State = CASE pin.fn_Straddler(X, KpBottom, Kpl, DrvBottom, @drv, @w, @shear, @tol)
                       WHEN 'Clear' THEN 'AtShear' ELSE 'Blocked' END;

    DECLARE @blocked int = (SELECT COUNT(*) FROM #Pins WHERE State = 'Blocked');
    DECLARE @which varchar(40) = (SELECT STRING_AGG(CAST(PinNo AS varchar(3)), ', ') WITHIN GROUP (ORDER BY PinNo)
                                  FROM #Pins WHERE State = 'Blocked');
    SET @frame += 1;
    SET @cap = IIF(@blocked = 0, N'Every gap on the shear line — turn!',
                   CONCAT(N'Pin ', @which, N' across the shear line — it won''t turn'));
    EXEC pin.usp_WriteFrame @RunId, @frame, @cap, 0, 0, @key, NULL;

    IF @blocked = 0
    BEGIN
        DECLARE @rot float = 4;
        WHILE @rot <= 20
        BEGIN
            SET @frame += 1;
            EXEC pin.usp_WriteFrame @RunId, @frame, N'Plug turning — open', 0, @rot, @key, NULL;
            SET @rot += 4;
        END;
    END;

    UPDATE pin.Run SET Opened = IIF(@blocked = 0, 1, 0), Frames = @frame, Notes = @cap WHERE RunId = @RunId;
    SELECT @RunId AS RunId, @keyName AS KeyName, @bitting AS Bitting, IIF(@blocked = 0, 1, 0) AS Opened, @cap AS Result;
END;
GO

/* ---------------------------------------------------------------------
   Single-pin picking.
   Tension on. The binding pin is the unset pin with the biggest
   manufacturing offset (the one "doing the most holding"). The picker
   scans front to back: non-binding pins feel springy; the binding pin
   feels stiff and is lifted in quarter steps until nothing straddles the
   shear line — click, it sets and the plug turns a hair. At the critical
   moment an unsteady hand may overshoot (@OversetChance): the key pin
   jams across the shear line, so tension comes off and every pin drops.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE pin.usp_Pick
    @LockId        int,
    @Seed          int   = 1945,
    @OversetChance float = 0.2,
    @MaxResets     int   = 6,
    @RunId         int   = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @floor float, @shear float, @tol float, @drv float, @w float;
    SELECT @floor = FloorY, @shear = ShearY, @tol = Tolerance, @drv = DriverLen, @w = PinWidth
    FROM pin.Lock WHERE LockId = @LockId;
    IF @floor IS NULL THROW 50010, N'No such lock.', 1;
    IF NOT EXISTS (SELECT 1 FROM pin.Static WHERE LockId = @LockId) EXEC pin.usp_BuildLock @LockId;

    INSERT pin.Run (LockId, Mode, Resets) VALUES (@LockId, 'Pick', 0);
    SET @RunId = SCOPE_IDENTITY();

    CREATE TABLE #Pins (PinNo tinyint PRIMARY KEY, X float, Kpl float, KpBottom float, DrvBottom float,
                        State varchar(10), IsSet bit, Bind float);
    INSERT #Pins (PinNo, X, Kpl, KpBottom, DrvBottom, State, IsSet, Bind)
    SELECT PinNo, X, KeyPinLen, @floor, @floor + KeyPinLen, 'Rest', 0, BindOffset
    FROM pin.Chamber WHERE LockId = @LockId;

    DECLARE @r float = RAND(@Seed);       -- seed the generator once
    DECLARE @frame int = 0, @rot float = 0, @resets int = 0, @setOrder int = 0,
            @bp int, @sp int, @x float, @kpl float, @lift float, @st varchar(10),
            @cap nvarchar(120), @pick geometry, @overset bit;

    SET @frame += 1;
    EXEC pin.usp_WriteFrame @RunId, @frame, N'Tension wrench in — light turning pressure', 1, 0, NULL, NULL;

    WHILE EXISTS (SELECT 1 FROM #Pins WHERE IsSet = 0) AND @resets <= @MaxResets
    BEGIN
        /* the pin doing most of the holding */
        SELECT TOP (1) @bp = PinNo FROM #Pins WHERE IsSet = 0 ORDER BY Bind DESC;

        /* scan from the front: springy pins first */
        SET @sp = NULL;
        SELECT TOP (1) @sp = PinNo FROM #Pins WHERE IsSet = 0 AND PinNo < @bp ORDER BY PinNo;
        WHILE @sp IS NOT NULL
        BEGIN
            SELECT @x = X FROM #Pins WHERE PinNo = @sp;
            UPDATE #Pins SET KpBottom = @floor + 1.0, DrvBottom = @floor + 1.0 + Kpl, State = 'Springy' WHERE PinNo = @sp;
            SET @frame += 1;
            SET @cap = CONCAT(N'Pin ', @sp, N': springy — not binding, move on');
            SET @pick = pin.fn_PickGeom(@x, @floor + 1.0, @floor);
            EXEC pin.usp_WriteFrame @RunId, @frame, @cap, 1, @rot, NULL, @pick;
            UPDATE #Pins SET KpBottom = @floor, DrvBottom = @floor + Kpl, State = 'Rest' WHERE PinNo = @sp;

            DECLARE @prev int = @sp;
            SET @sp = NULL;
            SELECT TOP (1) @sp = PinNo FROM #Pins WHERE IsSet = 0 AND PinNo > @prev AND PinNo < @bp ORDER BY PinNo;
        END;

        /* lift the binding pin */
        SELECT @x = X, @kpl = Kpl FROM #Pins WHERE PinNo = @bp;
        SELECT @lift = 0, @overset = 0;
        WHILE 1 = 1
        BEGIN
            SET @lift += 0.25;
            /* at the critical moment, an unsteady hand overshoots */
            IF @floor + @lift + @kpl >= @shear - 0.001 AND RAND() < @OversetChance
                SET @lift += 0.5;

            UPDATE #Pins SET KpBottom = @floor + @lift, DrvBottom = @floor + @lift + Kpl, State = 'Binding'
            WHERE PinNo = @bp;
            SET @st = pin.fn_Straddler(@x, @floor + @lift, @kpl, @floor + @lift + @kpl, @drv, @w, @shear, @tol);
            SET @pick = pin.fn_PickGeom(@x, @floor + @lift, @floor);

            IF @st = 'Driver'
            BEGIN
                SET @frame += 1;
                SET @cap = CONCAT(N'Pin ', @bp, N': binding — lifting');
                EXEC pin.usp_WriteFrame @RunId, @frame, @cap, 1, @rot, NULL, @pick;
                CONTINUE;
            END;

            IF @st = 'Clear'
            BEGIN
                SET @setOrder += 1;
                SET @rot += 1.5;
                INSERT pin.PickLog (RunId, PinNo, SetOrder, LiftAtSet) VALUES (@RunId, @bp, @setOrder, @lift);
                UPDATE #Pins SET IsSet = 1, State = 'Set', KpBottom = @floor, DrvBottom = @shear WHERE PinNo = @bp;
                SET @frame += 1;
                SET @cap = CONCAT(N'Click — pin ', @bp, N' set (', @setOrder, N' of ',
                                  (SELECT COUNT(*) FROM #Pins), N'); the plug gives a hair');
                EXEC pin.usp_WriteFrame @RunId, @frame, @cap, 1, @rot, NULL, @pick;
                BREAK;
            END;

            /* @st = 'KeyPin' : overset */
            UPDATE #Pins SET State = 'Overset' WHERE PinNo = @bp;
            SET @frame += 1;
            SET @cap = CONCAT(N'Overset! Pin ', @bp, N'''s key pin jammed across the shear line');
            EXEC pin.usp_WriteFrame @RunId, @frame, @cap, 1, @rot, NULL, @pick;

            UPDATE #Pins SET IsSet = 0, State = 'Rest', KpBottom = @floor, DrvBottom = @floor + Kpl;
            DELETE pin.PickLog WHERE RunId = @RunId;
            SELECT @rot = 0, @setOrder = 0, @resets += 1;
            SET @frame += 1;
            EXEC pin.usp_WriteFrame @RunId, @frame, N'Let go of the tension — tic-tic-tic, every pin drops. Start again.', 0, 0, NULL, NULL;
            SET @frame += 1;
            EXEC pin.usp_WriteFrame @RunId, @frame, N'Tension back on', 1, 0, NULL, NULL;
            BREAK;
        END;
    END;

    DECLARE @opened bit = IIF(EXISTS (SELECT 1 FROM #Pins WHERE IsSet = 0), 0, 1);
    IF @opened = 1
    BEGIN
        WHILE @rot < 20
        BEGIN
            SET @rot = IIF(@rot + 4 > 20, 20, @rot + 4);
            SET @frame += 1;
            EXEC pin.usp_WriteFrame @RunId, @frame, N'All pins set — the plug turns. Open.', 1, @rot, NULL, NULL;
        END;
    END;

    UPDATE pin.Run SET Opened = @opened, Frames = @frame, Resets = @resets,
                       Notes = CONCAT(N'Set order: ', (SELECT STRING_AGG(CAST(PinNo AS varchar(3)), N'-') WITHIN GROUP (ORDER BY SetOrder)
                                                       FROM pin.PickLog WHERE RunId = @RunId))
    WHERE RunId = @RunId;

    SELECT RunId, Opened, Frames, Resets, Notes FROM pin.Run WHERE RunId = @RunId;
END;
GO

/* ---------------------------------------------------------------------
   The pin-tumbler version of "taking the last two numbers off":
   how high each pin had to be lifted to set tells you how deep the
   key's cut must be. Cut the key, file it in pin.Keys.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE pin.usp_DecodeKey
    @RunId int,
    @KeyId int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @lock int, @opened bit, @floor float, @top float, @step float, @n int;
    SELECT @lock = r.LockId, @opened = r.Opened, @floor = l.FloorY, @top = l.BladeTopY,
           @step = l.DepthStep, @n = l.PinCount
    FROM pin.Run AS r JOIN pin.Lock AS l ON l.LockId = r.LockId
    WHERE r.RunId = @RunId AND r.Mode = 'Pick';
    IF @opened IS NULL OR @opened = 0 THROW 50013, N'Need a successful pick run to decode.', 1;

    /* key pin bottom at the moment of setting = where the key's cut must be */
    DECLARE @bitting varchar(12) =
        (SELECT STRING_AGG(CAST(CAST(ROUND((@top - (@floor + LiftAtSet)) / @step, 0) AS int) AS varchar(2)), '')
                WITHIN GROUP (ORDER BY PinNo)
         FROM pin.PickLog WHERE RunId = @RunId);

    INSERT pin.Keys (LockId, Name, Bitting) VALUES (@lock, CONCAT(N'Key decoded from pick run ', @RunId), @bitting);
    SET @KeyId = SCOPE_IDENTITY();
    SELECT @KeyId AS KeyId, @bitting AS Bitting;
END;
GO

/* =====================================================================
   SEED: one five-pin clear practice lock and three keys
   Secret bitting 3-5-2-7-4. Binding order from BindOffset: 2,5,3,1,4.
   ===================================================================== */
SET IDENTITY_INSERT pin.Lock ON;
INSERT pin.Lock (LockId, Name, PinCount) VALUES (1, N'Clear practice lock (5-pin)', 5);
SET IDENTITY_INSERT pin.Lock OFF;

INSERT pin.Chamber (LockId, PinNo, X, KeyPinLen, BindOffset)
SELECT 1, v.PinNo, v.PinNo * l.PinSpacing, l.ShearY - l.BladeTopY + v.Depth * l.DepthStep, v.Bind
FROM (VALUES (1, 3, 0.04), (2, 5, 0.12), (3, 2, 0.07), (4, 7, 0.02), (5, 4, 0.10)) AS v(PinNo, Depth, Bind)
CROSS JOIN pin.Lock AS l
WHERE l.LockId = 1;

INSERT pin.Keys (LockId, Name, Bitting) VALUES
 (1, N'the right key',        '35274'),
 (1, N'next door''s key',     '35284'),
 (NULL, N'an uncut blank',    '00000');

EXEC pin.usp_BuildLock 1;
GO
