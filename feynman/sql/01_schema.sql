/* =====================================================================
   Feynman Safecracker Lab  —  SQL Server 2025
   01_schema.sql : database, schemas, tables

   Two halves:
     dial.*  Feynman's Mosler filing-cabinet combination locks (Los Alamos, 1943-46)
     pin.*   A transparent pin-tumbler practice lock (the Leo Lavatelli lesson)

   Requires compatibility level 160+ (GENERATE_SERIES). 2025 defaults to 170.
   Safe to re-run: drops and recreates everything.
   ===================================================================== */
IF DB_ID(N'FeynmanSafecracker') IS NULL
    CREATE DATABASE FeynmanSafecracker;
GO
USE FeynmanSafecracker;
GO
IF SCHEMA_ID(N'dial') IS NULL EXEC (N'CREATE SCHEMA dial');
GO
IF SCHEMA_ID(N'pin') IS NULL EXEC (N'CREATE SCHEMA pin');
GO

/* ---------- clean slate (child tables first) ---------- */
DROP TABLE IF EXISTS dial.Probe, dial.Attempt, dial.Candidate, dial.Run,
                     dial.Notebook, dial.WheelGeom, dial.Bolt, dial.Dictionary, dial.Cabinet;
DROP TABLE IF EXISTS pin.PickLog, pin.FramePart, pin.Frame, pin.Run,
                     pin.Keys, pin.Static, pin.Chamber, pin.Lock;
GO

/* =====================================================================
   DIAL LOCKS
   Wheel numbering follows the mechanism, front to back:
     wheel 1 = front (next to the dial)  -> set LAST  by N3
     wheel 2 = middle                    -> set       by N2
     wheel 3 = rear                      -> set FIRST by N1
   ===================================================================== */
CREATE TABLE dial.Cabinet
(
    CabinetId   int IDENTITY(1,1) PRIMARY KEY,
    Owner       nvarchar(60)  NOT NULL,
    Location    nvarchar(80)  NOT NULL,
    N1          tinyint NOT NULL CHECK (N1 < 100),     -- the true combination
    N2          tinyint NOT NULL CHECK (N2 < 100),
    N3          tinyint NOT NULL CHECK (N3 < 100),
    Tolerance   tinyint NOT NULL DEFAULT (2),          -- Feynman: "off by two either way"
    OpenNumber  tinyint NOT NULL DEFAULT (10),         -- turn right to 10 to draw the bolt
    State       varchar(6) NOT NULL DEFAULT ('Locked') CHECK (State IN ('Locked','Open')),
    W1          tinyint NOT NULL DEFAULT (0),          -- where each wheel is sitting right now
    W2          tinyint NOT NULL DEFAULT (0),
    W3          tinyint NOT NULL DEFAULT (0),
    Story       nvarchar(400) NULL
);

/* Every wheel at every one of its 100 positions, as geometry, plus the
   pre-computed answer to "does the bolt hit metal on this wheel here?" */
CREATE TABLE dial.WheelGeom
(
    CabinetId   int     NOT NULL REFERENCES dial.Cabinet(CabinetId),
    WheelNo     tinyint NOT NULL CHECK (WheelNo BETWEEN 1 AND 3),
    DialPos     tinyint NOT NULL CHECK (DialPos < 100),
    Geom        geometry NOT NULL,
    Clear       bit     NOT NULL,          -- 1 = bolt clears this wheel (gate under the fence)
    CONSTRAINT PK_WheelGeom PRIMARY KEY (CabinetId, WheelNo, DialPos)
);

CREATE TABLE dial.Bolt
(
    CabinetId   int PRIMARY KEY REFERENCES dial.Cabinet(CabinetId),
    Geom        geometry NOT NULL          -- the fence: one small bar above each wheel
);

/* The safecracker books' "psychology": factory settings, constants, dates */
CREATE TABLE dial.Dictionary
(
    Seq         int IDENTITY(1,1) PRIMARY KEY,
    Source      varchar(40) NOT NULL,
    A           tinyint NOT NULL,
    B           tinyint NOT NULL,
    C           tinyint NOT NULL,
    Priority    int NOT NULL
);

/* Feynman's scrap of paper, kept inside the lock of his own cabinet */
CREATE TABLE dial.Notebook
(
    NoteId      int IDENTITY(1,1) PRIMARY KEY,
    CabinetId   int NOT NULL REFERENCES dial.Cabinet(CabinetId),
    B           tinyint NOT NULL,          -- second number
    C           tinyint NOT NULL,          -- last number
    Confidence  varchar(10) NOT NULL DEFAULT ('taken'),   -- 'taken' or 'vague'
    TakenAt     datetime2(0) NOT NULL DEFAULT (SYSUTCDATETIME())
);

CREATE TABLE dial.Run
(
    RunId       int IDENTITY(1,1) PRIMARY KEY,
    CabinetId   int NOT NULL REFERENCES dial.Cabinet(CabinetId),
    Strategy    varchar(20) NOT NULL,
    StartedAt   datetime2(3) NOT NULL DEFAULT (SYSUTCDATETIME()),
    FinishedAt  datetime2(3) NULL,
    Candidates  int NULL,
    Attempts    int NULL,
    SimSeconds  decimal(12,1) NULL,        -- how long Feynman would have spent at the dial
    Opened      bit NULL,
    FoundA      tinyint NULL,
    FoundB      tinyint NULL,
    FoundC      tinyint NULL
);

CREATE TABLE dial.Candidate
(
    RunId       int NOT NULL,
    Seq         int NOT NULL,
    A           tinyint NOT NULL,
    B           tinyint NOT NULL,
    C           tinyint NOT NULL,
    Source      varchar(40) NOT NULL,
    CONSTRAINT PK_Candidate PRIMARY KEY (RunId, Seq)
);

CREATE TABLE dial.Attempt
(
    RunId       int NOT NULL,
    Seq         int NOT NULL,
    A           tinyint NOT NULL,
    B           tinyint NOT NULL,
    C           tinyint NOT NULL,
    Source      varchar(40) NOT NULL,
    BoltDropped bit NOT NULL,
    StepSeconds decimal(6,1) NOT NULL,
    SimSeconds  decimal(12,1) NOT NULL,    -- running total
    Coverage    geometry NULL,             -- the patch of "Feynman space" this try rules out
    AttemptedAt datetime2(3) NOT NULL DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_Attempt PRIMARY KEY (RunId, Seq)
);

/* Each wobble of the dial while "taking the last two numbers off" */
CREATE TABLE dial.Probe
(
    RunId       int NOT NULL,
    StepNo      int NOT NULL,
    Phase       varchar(12) NOT NULL,      -- 'LastNumber' | 'SecondNumber'
    DialPos     tinyint NOT NULL,
    W1          tinyint NOT NULL,
    W2          tinyint NOT NULL,
    W3          tinyint NOT NULL,
    BoltDropped bit NOT NULL,
    Note        nvarchar(120) NULL,
    CONSTRAINT PK_Probe PRIMARY KEY (RunId, StepNo)
);
GO

/* =====================================================================
   PIN TUMBLER LOCK  (side cut-away, units are arbitrary "lock units")
     y = FloorY      keyway floor; key pins rest here with no key
     y = BladeTopY   top of an uncut key blade
     y = ShearY      the shear line between plug and shell
   KeyPinLen = ShearY - BladeTopY + depth * DepthStep, so the right cut
   lifts the key/driver gap exactly onto the shear line.
   ===================================================================== */
CREATE TABLE pin.Lock
(
    LockId      int IDENTITY(1,1) PRIMARY KEY,
    Name        nvarchar(60) NOT NULL,
    PinCount    tinyint NOT NULL,
    PinSpacing  float NOT NULL DEFAULT (5.0),
    FloorY      float NOT NULL DEFAULT (1.0),
    BladeTopY   float NOT NULL DEFAULT (6.0),
    ShearY      float NOT NULL DEFAULT (10.0),
    ChamberTopY float NOT NULL DEFAULT (24.0),
    DepthStep   float NOT NULL DEFAULT (0.5),
    Tolerance   float NOT NULL DEFAULT (0.15),
    DriverLen   float NOT NULL DEFAULT (6.0),      -- long enough to straddle the shear line at rest
    PinWidth    float NOT NULL DEFAULT (1.6)
);

CREATE TABLE pin.Chamber
(
    LockId      int NOT NULL REFERENCES pin.Lock(LockId),
    PinNo       tinyint NOT NULL,          -- 1 = front (nearest the keyway opening)
    X           float NOT NULL,
    KeyPinLen   float NOT NULL,
    BindOffset  float NOT NULL,            -- manufacturing misalignment: bigger binds first
    CONSTRAINT PK_Chamber PRIMARY KEY (LockId, PinNo)
);

CREATE TABLE pin.Keys
(
    KeyId       int IDENTITY(1,1) PRIMARY KEY,
    LockId      int NULL REFERENCES pin.Lock(LockId),
    Name        nvarchar(60) NOT NULL,
    Bitting     varchar(12) NOT NULL       -- one digit 0-9 per pin, front to back
);

CREATE TABLE pin.Static
(
    LockId      int NOT NULL REFERENCES pin.Lock(LockId),
    Part        varchar(20) NOT NULL,      -- Shell | Plug | ShearLine
    Geom        geometry NOT NULL,
    CONSTRAINT PK_Static PRIMARY KEY (LockId, Part)
);

CREATE TABLE pin.Run
(
    RunId       int IDENTITY(1,1) PRIMARY KEY,
    LockId      int NOT NULL REFERENCES pin.Lock(LockId),
    Mode        varchar(10) NOT NULL,      -- 'Key' | 'Pick'
    KeyId       int NULL,
    StartedAt   datetime2(3) NOT NULL DEFAULT (SYSUTCDATETIME()),
    Opened      bit NULL,
    Frames      int NULL,
    Resets      int NULL,
    Notes       nvarchar(200) NULL
);

CREATE TABLE pin.Frame
(
    RunId        int NOT NULL,
    FrameNo      int NOT NULL,
    Caption      nvarchar(120) NOT NULL,
    Tension      bit NOT NULL,
    PlugRotation float NOT NULL,           -- degrees; 90 = open
    CONSTRAINT PK_Frame PRIMARY KEY (RunId, FrameNo)
);

CREATE TABLE pin.FramePart
(
    RunId       int NOT NULL,
    FrameNo     int NOT NULL,
    PartNo      int NOT NULL,
    Part        varchar(10) NOT NULL,      -- KeyPin | Driver | Spring | Key | Pick
    PinNo       tinyint NULL,
    State       varchar(10) NULL,          -- Rest | Riding | Springy | Binding | Set | Overset | AtShear | Blocked
    Geom        geometry NOT NULL,
    CONSTRAINT PK_FramePart PRIMARY KEY (RunId, FrameNo, PartNo)
);

/* How high each pin had to be lifted when it set — enough to cut a key */
CREATE TABLE pin.PickLog
(
    RunId       int NOT NULL,
    PinNo       tinyint NOT NULL,
    SetOrder    int NOT NULL,
    LiftAtSet   float NOT NULL,
    CONSTRAINT PK_PickLog PRIMARY KEY (RunId, PinNo)
);
GO
