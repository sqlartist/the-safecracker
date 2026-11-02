/* =====================================================================
   Feynman Safecracker Lab  —  02_geometry.sql
   Geometry builders. Everything physical is a shape, and the physics
   is answered by spatial predicates:

     "Does the bolt drop?"      Bolt.STIntersects(wheel) = 0 for all wheels
     "Is the pin set?"          nothing straddles the shear line
     "How high does the key     STIntersection of a vertical line through
      lift this pin?"           the chamber with the key outline

   Layout of the dial-lock drawing plane (SSMS Spatial results tab):
     wheel 3 (rear)  centred at x =  0
     wheel 2         centred at x = 25
     wheel 1 (front) centred at x = 50      wheel radius 10
     dial face       centred at x = 80
   A wheel set to dial position d with its gate cut at number g has the
   gate at angle 90 + 3.6*(d - g) degrees (90 = 12 o'clock, under the bolt).
   ===================================================================== */
USE FeynmanSafecracker;
GO

/* fixed-point text for WKT (no scientific notation) */
CREATE OR ALTER FUNCTION dbo.fmt (@v float)
RETURNS varchar(32)
WITH SCHEMABINDING
AS
BEGIN
    RETURN LTRIM(STR(@v, 24, 6));
END;
GO

CREATE OR ALTER FUNCTION dbo.fn_Rect (@x1 float, @y1 float, @x2 float, @y2 float)
RETURNS geometry
AS
BEGIN
    RETURN geometry::STGeomFromText(CONCAT(
        'POLYGON((',
        dbo.fmt(@x1),' ',dbo.fmt(@y1),', ',
        dbo.fmt(@x2),' ',dbo.fmt(@y1),', ',
        dbo.fmt(@x2),' ',dbo.fmt(@y2),', ',
        dbo.fmt(@x1),' ',dbo.fmt(@y2),', ',
        dbo.fmt(@x1),' ',dbo.fmt(@y1),'))'), 0);
END;
GO

CREATE OR ALTER FUNCTION dbo.fn_HLine (@x1 float, @x2 float, @y float)
RETURNS geometry
AS
BEGIN
    RETURN geometry::STGeomFromText(CONCAT('LINESTRING(',
        dbo.fmt(@x1),' ',dbo.fmt(@y),', ',dbo.fmt(@x2),' ',dbo.fmt(@y),')'), 0);
END;
GO

/* a pie slice: centre, radius, centre angle and half-width in degrees */
CREATE OR ALTER FUNCTION dbo.fn_Wedge (@cx float, @cy float, @r float, @centreDeg float, @halfDeg float)
RETURNS geometry
AS
BEGIN
    DECLARE @pts varchar(max);

    SELECT @pts = STRING_AGG(CAST(CONCAT(
                dbo.fmt(@cx + @r * COS(RADIANS(@centreDeg - @halfDeg + 2.0 * @halfDeg * s.value / 24.0))), ' ',
                dbo.fmt(@cy + @r * SIN(RADIANS(@centreDeg - @halfDeg + 2.0 * @halfDeg * s.value / 24.0))))
            AS varchar(max)), ', ') WITHIN GROUP (ORDER BY s.value)
    FROM GENERATE_SERIES(0, 24) AS s;

    RETURN geometry::STGeomFromText(CONCAT('POLYGON((',
        dbo.fmt(@cx),' ',dbo.fmt(@cy),', ', @pts, ', ',
        dbo.fmt(@cx),' ',dbo.fmt(@cy),'))'), 0);
END;
GO

/* =====================================================================
   DIAL LOCK SHAPES
   ===================================================================== */
CREATE OR ALTER FUNCTION dial.fn_WheelCx (@WheelNo int)
RETURNS float
WITH SCHEMABINDING
AS
BEGIN
    RETURN (3 - @WheelNo) * 25.0;      -- rear wheel on the left, front wheel on the right
END;
GO

/* One combination wheel: a disc with a hub hole, a drive-pin hole (so you
   can see it rotate) and the gate notch cut into its rim.
   Gate half-width = (tol + 0.5) * 3.6 deg + 3 deg clearance, which with the
   0.6-wide bolt lets exactly +/- tol numbers through. */
CREATE OR ALTER FUNCTION dial.fn_WheelShape (@cx float, @cy float, @Gate int, @SetTo int, @Tol int)
RETURNS geometry
AS
BEGIN
    DECLARE @R      float = 10.0;
    DECLARE @theta  float = 90.0 + 3.6 * (@SetTo - @Gate);
    DECLARE @half   float = (@Tol + 0.5) * 3.6 + 3.0;
    DECLARE @centre geometry = geometry::Point(@cx, @cy, 0);

    DECLARE @notch geometry =
        dbo.fn_Wedge(@cx, @cy, @R * 1.3, @theta, @half)
           .STDifference(@centre.STBuffer(@R * 0.8));

    DECLARE @pinHole geometry =
        geometry::Point(@cx + 6.0 * COS(RADIANS(@theta + 180.0)),
                        @cy + 6.0 * SIN(RADIANS(@theta + 180.0)), 0).STBuffer(0.9);

    RETURN @centre.STBuffer(@R)
                  .STDifference(@centre.STBuffer(1.5))
                  .STDifference(@pinHole)
                  .STDifference(@notch);
END;
GO

/* Feynman's own example combination, 69-32-21, lives in "Feynman space":
   20 panels, one per first-number band (0,5,..95), each a 100 x 100 square
   of (second, third). One try with tolerance 2 rules out a 5 x 5 patch. */
CREATE OR ALTER FUNCTION dial.fn_PanelOrigin (@A int)
RETURNS TABLE
AS
RETURN
    SELECT  p.Panel,
            (p.Panel % 5) * 110.0  AS X0,
            -(p.Panel / 5) * 110.0 AS Y0
    FROM (SELECT CAST(ROUND(@A / 5.0, 0) AS int) % 20 AS Panel) AS p;
GO

CREATE OR ALTER FUNCTION dial.fn_Coverage (@A int, @B int, @C int, @Tol int)
RETURNS geometry
AS
BEGIN
    DECLARE @x0 float, @y0 float, @h float = @Tol + 0.5;
    SELECT @x0 = X0, @y0 = Y0 FROM dial.fn_PanelOrigin(@A);

    RETURN dbo.fn_Rect(@x0 + @B - @h, @y0 + @C - @h, @x0 + @B + @h, @y0 + @C + @h)
              .STIntersection(dbo.fn_Rect(@x0, @y0, @x0 + 100, @y0 + 100));
END;
GO

CREATE OR ALTER FUNCTION dial.fn_Universe ()
RETURNS geometry
AS
BEGIN
    DECLARE @g geometry;
    SELECT @g = geometry::UnionAggregate(
                  dbo.fn_Rect((p.value % 5) * 110.0, -(p.value / 5) * 110.0,
                              (p.value % 5) * 110.0 + 100, -(p.value / 5) * 110.0 + 100))
    FROM GENERATE_SERIES(0, 19) AS p;
    RETURN @g;
END;
GO

/* The dial itself, for the SSMS spatial viewer: rim, 100 ticks rotated so
   that @Pos sits under the index mark, a knob, and the index pointer. */
CREATE OR ALTER FUNCTION dial.fn_DialFace (@cx float, @cy float, @Pos int)
RETURNS geometry
AS
BEGIN
    DECLARE @ticks varchar(max);
    SELECT @ticks = STRING_AGG(CAST(CONCAT('(',
        dbo.fmt(@cx + 11.4 * COS(RADIANS(90.0 + 3.6 * (n.value - @Pos)))), ' ',
        dbo.fmt(@cy + 11.4 * SIN(RADIANS(90.0 + 3.6 * (n.value - @Pos)))), ', ',
        dbo.fmt(@cx + (11.4 - IIF(n.value % 10 = 0, 2.2, IIF(n.value % 5 = 0, 1.4, 0.7))) * COS(RADIANS(90.0 + 3.6 * (n.value - @Pos)))), ' ',
        dbo.fmt(@cy + (11.4 - IIF(n.value % 10 = 0, 2.2, IIF(n.value % 5 = 0, 1.4, 0.7))) * SIN(RADIANS(90.0 + 3.6 * (n.value - @Pos)))), ')')
        AS varchar(max)), ', ') WITHIN GROUP (ORDER BY n.value)
    FROM GENERATE_SERIES(0, 99) AS n;

    DECLARE @centre geometry = geometry::Point(@cx, @cy, 0);
    DECLARE @rim    geometry = @centre.STBuffer(12.0).STDifference(@centre.STBuffer(11.4));
    DECLARE @index  geometry = geometry::STGeomFromText(CONCAT('POLYGON((',
        dbo.fmt(@cx - 0.8),' ',dbo.fmt(@cy + 13.2),', ',
        dbo.fmt(@cx + 0.8),' ',dbo.fmt(@cy + 13.2),', ',
        dbo.fmt(@cx),' ',dbo.fmt(@cy + 12.1),', ',
        dbo.fmt(@cx - 0.8),' ',dbo.fmt(@cy + 13.2),'))'), 0);

    RETURN @rim
        .STUnion(geometry::STGeomFromText(CONCAT('MULTILINESTRING(', @ticks, ')'), 0))
        .STUnion(@centre.STBuffer(4.0))
        .STUnion(@index);
END;
GO

/* =====================================================================
   PIN TUMBLER SHAPES
   ===================================================================== */
CREATE OR ALTER FUNCTION pin.fn_Spring (@x float, @y1 float, @y2 float, @w float)
RETURNS geometry
AS
BEGIN
    DECLARE @wkt varchar(max) = CONCAT('LINESTRING(', dbo.fmt(@x), ' ', dbo.fmt(@y1));
    DECLARE @i int = 1, @n int = 11;
    WHILE @i < @n
    BEGIN
        SET @wkt += CONCAT(', ',
            dbo.fmt(@x + IIF(@i % 2 = 1, -@w / 2, @w / 2)), ' ',
            dbo.fmt(@y1 + (@y2 - @y1) * @i / @n));
        SET @i += 1;
    END;
    SET @wkt += CONCAT(', ', dbo.fmt(@x), ' ', dbo.fmt(@y2), ')');
    RETURN geometry::STGeomFromText(@wkt, 0);
END;
GO

/* A key: bow plus blade, with a V-cut over each chamber.
   @Offset slides the whole key along x (0 = fully inserted). */
CREATE OR ALTER FUNCTION pin.fn_KeyGeom (@LockId int, @Bitting varchar(12), @Offset float)
RETURNS geometry
AS
BEGIN
    DECLARE @n int, @sp float, @floor float, @top float, @step float;
    SELECT @n = PinCount, @sp = PinSpacing, @floor = FloorY, @top = BladeTopY, @step = DepthStep
    FROM pin.Lock WHERE LockId = @LockId;

    DECLARE @wkt varchar(max) = CONCAT('POLYGON((',
        dbo.fmt(@Offset - 1), ' ', dbo.fmt(@floor), ', ',
        dbo.fmt(@Offset - 1), ' ', dbo.fmt(@top));

    DECLARE @i int = 1, @d int, @cx float, @dy float, @run float;
    WHILE @i <= @n
    BEGIN
        SET @d = CAST(SUBSTRING(@Bitting, @i, 1) AS int);
        IF @d > 0
        BEGIN
            SET @cx  = @Offset + @i * @sp;
            SET @dy  = @top - @d * @step;
            SET @run = @d * @step * 0.5;           -- ~63 degree flanks
            SET @wkt += CONCAT(', ',
                dbo.fmt(@cx - 0.2 - @run), ' ', dbo.fmt(@top), ', ',
                dbo.fmt(@cx - 0.2),        ' ', dbo.fmt(@dy),  ', ',
                dbo.fmt(@cx + 0.2),        ' ', dbo.fmt(@dy),  ', ',
                dbo.fmt(@cx + 0.2 + @run), ' ', dbo.fmt(@top));
        END;
        SET @i += 1;
    END;

    DECLARE @tip float = @Offset + (@n + 1) * @sp;
    SET @wkt += CONCAT(', ',
        dbo.fmt(@tip - 1.5), ' ', dbo.fmt(@top), ', ',
        dbo.fmt(@tip),       ' ', dbo.fmt(@top - 2.0), ', ',
        dbo.fmt(@tip),       ' ', dbo.fmt(@floor), ', ',
        dbo.fmt(@Offset - 1),' ', dbo.fmt(@floor), '))');

    RETURN geometry::STGeomFromText(@wkt, 0).MakeValid()
             .STUnion(dbo.fn_Rect(@Offset - 9, @floor - 2, @Offset - 1, @top + 3));
END;
GO

/* Height of the key's top edge directly under chamber x — the spatial way:
   drop a vertical line through the chamber and intersect it with the key. */
CREATE OR ALTER FUNCTION pin.fn_SurfaceY (@Key geometry, @x float, @Floor float)
RETURNS float
AS
BEGIN
    IF @Key IS NULL RETURN @Floor;

    DECLARE @hit geometry = @Key.STIntersection(geometry::STGeomFromText(CONCAT(
        'LINESTRING(', dbo.fmt(@x), ' -10, ', dbo.fmt(@x), ' 40)'), 0));
    IF @hit IS NULL OR @hit.STIsEmpty() = 1 RETURN @Floor;

    DECLARE @best float = @Floor, @i int = 1, @g geometry;
    WHILE @i <= @hit.STNumGeometries()
    BEGIN
        SET @g = @hit.STGeometryN(@i);
        IF @g.STGeometryType() = 'Point'
            SET @best = IIF(@g.STY > @best, @g.STY, @best);
        ELSE
        BEGIN
            SET @best = IIF(@g.STStartPoint().STY > @best, @g.STStartPoint().STY, @best);
            SET @best = IIF(@g.STEndPoint().STY   > @best, @g.STEndPoint().STY,   @best);
        END;
        SET @i += 1;
    END;
    RETURN @best;
END;
GO

/* What is straddling the shear line in this chamber?
     'Driver' -> driver pin crosses it: plug can't turn (binding / not lifted enough)
     'KeyPin' -> key pin crosses it: overset (lifted too far)
     'Clear'  -> the gap between the pins sits on the line: set
   Each pin is shrunk by the tolerance first, so "nearly on the line" counts. */
CREATE OR ALTER FUNCTION pin.fn_Straddler
    (@x float, @KpBottom float, @Kpl float, @DrvBottom float, @DrvLen float,
     @Width float, @ShearY float, @Tol float)
RETURNS varchar(10)
AS
BEGIN
    DECLARE @line geometry = dbo.fn_HLine(@x - 5, @x + 5, @ShearY);

    IF dbo.fn_Rect(@x - @Width / 2, @DrvBottom, @x + @Width / 2, @DrvBottom + @DrvLen)
          .STBuffer(-@Tol).STIntersects(@line) = 1
        RETURN 'Driver';

    IF dbo.fn_Rect(@x - @Width / 2, @KpBottom, @x + @Width / 2, @KpBottom + @Kpl)
          .STBuffer(-@Tol).STIntersects(@line) = 1
        RETURN 'KeyPin';

    RETURN 'Clear';
END;
GO

/* A hook pick coming in along the keyway, tip under chamber x at height y */
CREATE OR ALTER FUNCTION pin.fn_PickGeom (@x float, @TipY float, @Floor float)
RETURNS geometry
AS
BEGIN
    RETURN geometry::STGeomFromText(CONCAT('LINESTRING(',
        dbo.fmt(-14.0),     ' ', dbo.fmt(@Floor + 0.6), ', ',
        dbo.fmt(@x - 1.4),  ' ', dbo.fmt(@Floor + 0.6), ', ',
        dbo.fmt(@x),        ' ', dbo.fmt(@TipY), ')'), 0);
END;
GO
