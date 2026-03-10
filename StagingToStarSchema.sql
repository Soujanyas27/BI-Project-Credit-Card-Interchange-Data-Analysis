/* ============================================================
    USE DEV DATABASE
   - Make sure we are in InterChange_db_Dev
   ============================================================ */
USE InterChange_db_Dev;
GO


/* ============================================================
   1. STAGING: CREATE & LOAD RAW CSV DATA
   - Create Stg_InterchangeRaw
   - BULK INSERT from CSV
   ============================================================ */
CREATE TABLE dbo.Stg_InterchangeRaw
(
    InterChangeID        int             NOT NULL,
    ReportingDate        date            NOT NULL,
    CardNumber           int             NOT NULL,
    AcquirerNetworkGroup nvarchar(50)    NOT NULL,
    Merchant             nvarchar(200)   NOT NULL,
    UsageType            nvarchar(50)    NOT NULL,
    ProductType          nvarchar(20)    NOT NULL,
    SettlementAmount     decimal(18,2)   NOT NULL,
    InterchangeRevenue   decimal(18,6)   NOT NULL,
    TransactionCount     int             NOT NULL
);

TRUNCATE TABLE dbo.Stg_InterchangeRaw;

BULK INSERT dbo.Stg_InterchangeRaw
FROM "C:\Users\Checkout\Downloads\PACIFIC FINAL\Dataset\sampledata.csv"
WITH
(
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n',
    TABLOCK
);

SELECT TOP 100*
FROM dbo.Stg_InterchangeRaw;


/* ============================================================
   2. DATA STANDARDIZATION
   - Clean & standardize text fields in staging
   - UPPER & TRIM extra spaces
   ============================================================ */

-- Standardize text fields in-place in staging table
UPDATE dbo.Stg_InterchangeRaw
SET 
    AcquirerNetworkGroup = UPPER(LTRIM(RTRIM(REPLACE(AcquirerNetworkGroup, '  ', ' ')))),
    Merchant             = UPPER(LTRIM(RTRIM(REPLACE(Merchant, '  ', ' ')))),
    UsageType            = UPPER(LTRIM(RTRIM(REPLACE(UsageType, '  ', ' ')))),
    ProductType          = UPPER(LTRIM(RTRIM(REPLACE(ProductType, '  ', ' '))));



/* ============================================================
   3. DATA QUALITY: CREATE REJECT TABLE
   - Stg_InterchangeRejected to store all bad/invalid rows
   ============================================================ */

CREATE TABLE dbo.Stg_InterchangeRejected
(
    InterChangeID        int             NULL,
    ReportingDate        date            NULL,
    CardNumber           int             NULL,
    AcquirerNetworkGroup nvarchar(50)    NULL,
    Merchant             nvarchar(200)   NULL,
    UsageType            nvarchar(50)    NULL,
    ProductType          nvarchar(20)    NULL,
    SettlementAmount     decimal(18,2)   NULL,
    InterchangeRevenue   decimal(18,6)   NULL,
    TransactionCount     int             NULL,
    RejectionReason      nvarchar(200)   NOT NULL,
    LoggedOn             datetime2       NOT NULL DEFAULT SYSUTCDATETIME()
);



/* ============================================================
   4. DATA QUALITY: DUPLICATE CHECKS
   - First: SELECT to find duplicates
   - Then: Use ROW_NUMBER to log dupes into Rejected
   ============================================================ */

-- Find potential duplicate rows
SELECT
    InterChangeID,
    ReportingDate,
    CardNumber,
    Merchant,
    UsageType,
    ProductType,
    COUNT(*) AS DuplicateCount
FROM dbo.Stg_InterchangeRaw
GROUP BY
    InterChangeID,
    ReportingDate,
    CardNumber,
    Merchant,
    UsageType,
    ProductType
HAVING COUNT(*) > 1;


WITH Dedup AS
(
    SELECT
        s.*,
        ROW_NUMBER() OVER (
            PARTITION BY InterChangeID, ReportingDate, CardNumber, Merchant, UsageType, ProductType
            ORDER BY InterChangeID
        ) AS rn
    FROM dbo.Stg_InterchangeRaw s
)
-- 1) Log duplicates (rn > 1)
INSERT INTO dbo.Stg_InterchangeRejected
(
    InterChangeID, ReportingDate, CardNumber, AcquirerNetworkGroup,
    Merchant, UsageType, ProductType,
    SettlementAmount, InterchangeRevenue, TransactionCount,
    RejectionReason
)
SELECT
    InterChangeID, ReportingDate, CardNumber, AcquirerNetworkGroup,
    Merchant, UsageType, ProductType,
    SettlementAmount, InterchangeRevenue, TransactionCount,
    'Duplicate row for business key'
FROM Dedup
WHERE rn > 1;



/* ============================================================
   5. DATA QUALITY: NULL / MISSING CHECKS
   - Shows rows with NULLs in critical fields
   - Diagnostic SELECT only
   ============================================================ */

-- Null / missing check (if schema allowed NULLs)
SELECT *
FROM dbo.Stg_InterchangeRaw
WHERE InterChangeID IS NULL
   OR ReportingDate IS NULL
   OR CardNumber IS NULL
   OR Merchant IS NULL
   OR SettlementAmount IS NULL
   OR InterchangeRevenue IS NULL
   OR TransactionCount IS NULL;



/* ============================================================
   6. DATA QUALITY: BUSINESS-RULE CHECKS
   - Settlement vs TransactionCount consistency
   - Log those rows into Rejected
   ============================================================ */

-- Business-rule-based null / inconsistency checks
SELECT *
FROM dbo.Stg_InterchangeRaw
WHERE
    (SettlementAmount <> 0 AND TransactionCount = 0) OR
    (SettlementAmount = 0 AND InterchangeRevenue <> 0);



INSERT INTO dbo.Stg_InterchangeRejected
(
    InterChangeID, ReportingDate, CardNumber, AcquirerNetworkGroup,
    Merchant, UsageType, ProductType,
    SettlementAmount, InterchangeRevenue, TransactionCount,
    RejectionReason
)
SELECT
    InterChangeID, ReportingDate, CardNumber, AcquirerNetworkGroup,
    Merchant, UsageType, ProductType,
    SettlementAmount, InterchangeRevenue, TransactionCount,
    'Inconsistent amount vs transaction count'
FROM dbo.Stg_InterchangeRaw
WHERE
    (SettlementAmount <> 0 AND TransactionCount = 0) OR
    (SettlementAmount = 0 AND InterchangeRevenue <> 0);



/* ============================================================
   7. DATA QUALITY: OUTLIER / RATE CHECKS
   - Compute InterchangeRate
   - Identify negatives and very high rates (> 10%)
   - Log them into Rejected
   ============================================================ */

-- Settlement / revenue < 0 or extremely high interchange rate
WITH Rates AS
(
    SELECT
        *,
        CASE
            WHEN SettlementAmount = 0 THEN NULL
            ELSE InterchangeRevenue / SettlementAmount
        END AS InterchangeRate
    FROM dbo.Stg_InterchangeRaw
)
SELECT *
FROM Rates
WHERE SettlementAmount < 0
   OR InterchangeRevenue < 0
   OR InterchangeRate > 0.10;   



INSERT INTO dbo.Stg_InterchangeRejected
(
    InterChangeID, ReportingDate, CardNumber, AcquirerNetworkGroup,
    Merchant, UsageType, ProductType,
    SettlementAmount, InterchangeRevenue, TransactionCount,
    RejectionReason
)
SELECT
    InterChangeID, ReportingDate, CardNumber, AcquirerNetworkGroup,
    Merchant, UsageType, ProductType,
    SettlementAmount, InterchangeRevenue, TransactionCount,
    'Outlier: negative or very high interchange rate'
FROM dbo.Stg_InterchangeRaw r
WHERE
    SettlementAmount < 0
    OR InterchangeRevenue < 0
    OR (
        SettlementAmount > 0
        AND InterchangeRevenue > SettlementAmount * 0.10  
    );



/* ============================================================
   8. BUILD VALIDATED STAGING TABLE
   - Remove duplicates (keep rn = 1)
   - Remove inconsistent & outlier rows
   - Store final clean records into Stg_InterchangeValidated
   ============================================================ */

;WITH Dedup AS
(
    SELECT
        s.*,
        ROW_NUMBER() OVER (
            PARTITION BY InterChangeID, ReportingDate, CardNumber, Merchant, UsageType, ProductType
            ORDER BY InterChangeID
        ) AS rn
    FROM dbo.Stg_InterchangeRaw s
),
ValidBase AS
(
    SELECT *
    FROM Dedup
    WHERE rn = 1

      -- Remove inconsistent rows used earlier in rejects
      AND NOT (
            (SettlementAmount <> 0 AND TransactionCount = 0) OR
            (SettlementAmount = 0 AND InterchangeRevenue <> 0)
          )

      -- Remove negative/outlier cases
      AND SettlementAmount >= 0
      AND InterchangeRevenue >= 0
      AND NOT (
            SettlementAmount > 0
            AND InterchangeRevenue / SettlementAmount > 0.10
          )
)
SELECT
    InterChangeID,
    ReportingDate,
    CardNumber,
    AcquirerNetworkGroup,
    Merchant,
    UsageType,
    ProductType,
    SettlementAmount,
    InterchangeRevenue,
    TransactionCount
INTO dbo.Stg_InterchangeValidated
FROM ValidBase;



/* ============================================================
   9. DIMENSION: DimCardInfo
   - CardNumber + Network = Pk_Card
   - One row per card & network combo
   ============================================================ */

CREATE TABLE dbo.DimCardInfo
(
    Pk_Card              varchar(20)  NOT NULL PRIMARY KEY,   -- e.g. V203991 / S957
    CardNumber           int          NOT NULL,
    AcquirerNetworkGroup nvarchar(50) NOT NULL
);

INSERT INTO dbo.DimCardInfo (Pk_Card, CardNumber, AcquirerNetworkGroup)
SELECT DISTINCT
    CASE 
        WHEN v.AcquirerNetworkGroup = 'Visa' THEN 'V' + CAST(v.CardNumber AS varchar(20))
        WHEN v.AcquirerNetworkGroup = 'STAR' THEN 'S' + CAST(v.CardNumber AS varchar(20))
        ELSE LEFT(v.AcquirerNetworkGroup, 1) + CAST(v.CardNumber AS varchar(20))
    END AS Pk_Card,
    v.CardNumber,
    v.AcquirerNetworkGroup
FROM dbo.Stg_InterchangeValidated v;

SELECT * FROM dbo.DimCardInfo;


/* ============================================================
   10. DIMENSION: Dim_Merchant
       - One row per distinct merchant
       - Pk_Merchant = 'm' + row_number
   ============================================================ */

CREATE TABLE dbo.Dim_Merchant
(
    Pk_Merchant varchar(20)   NOT NULL PRIMARY KEY,   -- m1, m2, m3…
    Merchant    nvarchar(200) NOT NULL
);

;WITH Merchants AS
(
    SELECT Merchant,
           ROW_NUMBER() OVER (ORDER BY Merchant) AS rn
    FROM dbo.Stg_InterchangeValidated
    GROUP BY Merchant
)
INSERT INTO dbo.Dim_Merchant (Pk_Merchant, Merchant)
SELECT 'm' + CAST(rn AS varchar(10)),
       Merchant
FROM Merchants;

SELECT * FROM dbo.Dim_Merchant;


/* ============================================================
   11. DIMENSION: Dim_UsageType
       - Small static lookup for POS usage types
   ============================================================ */

CREATE TABLE dbo.Dim_UsageType
(
    Pk_Usage   varchar(2)   NOT NULL PRIMARY KEY,
    UsageType  nvarchar(50) NOT NULL
);

INSERT INTO dbo.Dim_UsageType (Pk_Usage, UsageType)
VALUES
    ('p1', 'POS - PINLESS'),
    ('p2', 'POS - PIN');

SELECT * FROM dbo.Dim_UsageType;

/* ============================================================
   12. DIMENSION: Dim_ProductType
       - Small static lookup for Debit/Credit
   ============================================================ */

CREATE TABLE dbo.Dim_ProductType
(
    Pk_Product  char(1)      NOT NULL PRIMARY KEY,
    ProductType nvarchar(20) NOT NULL
);

INSERT INTO dbo.Dim_ProductType (Pk_Product, ProductType)
VALUES
    ('d', 'Debit'),
    ('c', 'Credit');


SELECT * FROM dbo.Dim_ProductType;

/* ============================================================
   13. DIMENSION: Dim_Date
       - Date dimension with continuous dates between min/max
       - Includes Year, Month, Quarter, DayOfWeek, etc.
   ============================================================ */

CREATE TABLE dbo.Dim_Date
(
    [Date]          date        NOT NULL PRIMARY KEY,
    [Year]          int         NOT NULL,
    [MonthNumber]   int         NOT NULL,
    [MonthName]     varchar(20) NOT NULL,
    [MonthShort]    varchar(3)  NOT NULL,
    [YearMonth]     char(7)     NOT NULL,   -- YYYY-MM
    [Quarter]       char(2)     NOT NULL,   -- Q1, Q2, ...
    [YearQuarter]   varchar(10) NOT NULL,   -- e.g. 2025-Q3
    [Day]           tinyint     NOT NULL,
    [DayOfWeekNum]  tinyint     NOT NULL,   -- 1=Mon..7=Sun
    [DayOfWeekName] varchar(10) NOT NULL,
    [IsWeekend]     bit         NOT NULL
);
GO

DECLARE @StartDate date, @EndDate date;
SELECT @StartDate = MIN(ReportingDate),
       @EndDate   = MAX(ReportingDate)
FROM dbo.Stg_InterchangeValidated;

;WITH Dates AS
(
    SELECT @StartDate AS [Date]
    UNION ALL
    SELECT DATEADD(DAY, 1, [Date])
    FROM Dates
    WHERE [Date] < @EndDate
)
INSERT INTO dbo.Dim_Date
(
    [Date], [Year], [MonthNumber], [MonthName],
    [MonthShort], [YearMonth], [Quarter], [YearQuarter],
    [Day], [DayOfWeekNum], [DayOfWeekName], [IsWeekend]
)
SELECT
    d.[Date],
    YEAR(d.[Date])                                   AS [Year],
    MONTH(d.[Date])                                  AS [MonthNumber],
    DATENAME(MONTH, d.[Date])                        AS [MonthName],
    LEFT(DATENAME(MONTH, d.[Date]), 3)               AS [MonthShort],
    CONVERT(char(7), d.[Date], 126)                  AS [YearMonth],   -- YYYY-MM
    'Q' + CAST(DATEPART(QUARTER, d.[Date]) AS char(1))          AS [Quarter],
    CAST(YEAR(d.[Date]) AS varchar(4)) + '-Q' 
      + CAST(DATEPART(QUARTER, d.[Date]) AS char(1)) AS [YearQuarter],
    DAY(d.[Date])                                    AS [Day],
    DATEPART(WEEKDAY, d.[Date])                      AS [DayOfWeekNum],
    DATENAME(WEEKDAY, d.[Date])                      AS [DayOfWeekName],
    CASE WHEN DATEPART(WEEKDAY, d.[Date]) IN (1,7) THEN 1 ELSE 0 END AS [IsWeekend]
FROM Dates d
OPTION (MAXRECURSION 0);

SELECT * FROM dbo.Dim_Date;

/* ============================================================
   14. FACT TABLE: Fact_InterchangeTransactions
       - One row per transaction
       - Foreign keys to all dimensions
   ============================================================ */

CREATE TABLE dbo.Fact_InterchangeTransactions
(
    FactInterchangeID   bigint IDENTITY(1,1) PRIMARY KEY,

    InterChangeID       int             NOT NULL,
    ReportingDate       date            NOT NULL,          -- FK -> Dim_Date[Date]

    Fk_Card             varchar(20)     NOT NULL,          -- DimCardInfo.Pk_Card
    Fk_Merchant         varchar(20)     NOT NULL,          -- Dim_Merchant.Pk_Merchant
    Fk_Usage            varchar(2)      NOT NULL,          -- Dim_UsageType.Pk_Usage
    Fk_Product          char(1)         NOT NULL,          -- Dim_ProductType.Pk_Product

    SettlementAmount    decimal(18,2)   NOT NULL,
    InterchangeRevenue  decimal(18,6)   NOT NULL,
    TransactionCount    int             NOT NULL
);



INSERT INTO dbo.Fact_InterchangeTransactions
(
    InterChangeID,
    ReportingDate,
    Fk_Card,
    Fk_Merchant,
    Fk_Usage,
    Fk_Product,
    SettlementAmount,
    InterchangeRevenue,
    TransactionCount
)
SELECT
    v.InterChangeID,
    v.ReportingDate,
    dc.Pk_Card,
    dm.Pk_Merchant,
    CASE 
        WHEN v.UsageType = 'POS - PINLESS' THEN 'p1'
        WHEN v.UsageType = 'POS - PIN'     THEN 'p2'
        ELSE 'p1'  -- default, should not occur after validation
    END AS Fk_Usage,
    CASE 
        WHEN v.ProductType = 'Debit'  THEN 'd'
        WHEN v.ProductType = 'Credit' THEN 'c'
        ELSE 'd'  -- default, should not occur after validation
    END AS Fk_Product,
    COALESCE(v.SettlementAmount,   0) AS SettlementAmount,
    COALESCE(v.InterchangeRevenue, 0) AS InterchangeRevenue,
    COALESCE(v.TransactionCount,   0) AS TransactionCount
FROM dbo.Stg_InterchangeValidated v
JOIN dbo.DimCardInfo          dc
    ON dc.CardNumber           = v.CardNumber
   AND dc.AcquirerNetworkGroup = v.AcquirerNetworkGroup
JOIN dbo.Dim_Merchant         dm
    ON dm.Merchant             = v.Merchant;

SELECT * FROM dbo.Fact_InterchangeTransactions;

/* ============================================================
   15. ADD FOREIGN KEYS
       - Build full star schema integrity
   ============================================================ */

ALTER TABLE dbo.Fact_InterchangeTransactions
ADD CONSTRAINT FK_Fact_Date
    FOREIGN KEY (ReportingDate)
    REFERENCES dbo.Dim_Date ([Date]);
GO

ALTER TABLE dbo.Fact_InterchangeTransactions
ADD CONSTRAINT FK_Fact_Card
    FOREIGN KEY (Fk_Card)
    REFERENCES dbo.DimCardInfo (Pk_Card);
GO

ALTER TABLE dbo.Fact_InterchangeTransactions
ADD CONSTRAINT FK_Fact_Merchant
    FOREIGN KEY (Fk_Merchant)
    REFERENCES dbo.Dim_Merchant (Pk_Merchant);
GO

ALTER TABLE dbo.Fact_InterchangeTransactions
ADD CONSTRAINT FK_Fact_Usage
    FOREIGN KEY (Fk_Usage)
    REFERENCES dbo.Dim_UsageType (Pk_Usage);
GO

ALTER TABLE dbo.Fact_InterchangeTransactions
ADD CONSTRAINT FK_Fact_Product
    FOREIGN KEY (Fk_Product)
    REFERENCES dbo.Dim_ProductType (Pk_Product);
GO



/* ============================================================
   16. SANITY CHECKS & SAMPLE JOINED VIEW
       - Row counts: raw vs validated vs rejected vs fact
       - Sample TOP(20) joined rows across all dimensions
   ============================================================ */

-- Raw vs Validated vs Rejected
SELECT COUNT(*) AS RawRows       FROM dbo.Stg_InterchangeRaw;
SELECT COUNT(*) AS ValidRows     FROM dbo.Stg_InterchangeValidated;
SELECT COUNT(*) AS RejectedRows  FROM dbo.Stg_InterchangeRejected;

SELECT COUNT(*) AS FactRows      FROM dbo.Fact_InterchangeTransactions;


SELECT TOP (20)
    f.ReportingDate,
    f.SettlementAmount,
    f.InterchangeRevenue,
    f.TransactionCount,
    dc.CardNumber,
    dc.AcquirerNetworkGroup,
    dm.Merchant,
    du.UsageType,
    dp.ProductType
FROM dbo.Fact_InterchangeTransactions f
JOIN dbo.DimCardInfo       dc ON f.Fk_Card     = dc.Pk_Card
JOIN dbo.Dim_Merchant      dm ON f.Fk_Merchant = dm.Pk_Merchant
JOIN dbo.Dim_UsageType     du ON f.Fk_Usage    = du.Pk_Usage
JOIN dbo.Dim_ProductType   dp ON f.Fk_Product  = dp.Pk_Product;