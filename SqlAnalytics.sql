﻿/* =========================================================================
   1.  What are the current and previous month/year
       based on the latest ReportingDate in the fact table?
   ======================================================================== */

-- Get the latest ReportingDate from the fact table
WITH MaxDate AS
(
    SELECT MAX(ReportingDate) AS MaxDt
    FROM dbo.Fact_InterchangeTransactions
),
-- Determine the current Year & Month from that max date
CurrMonth AS
(
    SELECT
        d.[Year]        AS CurrYear,
        d.[MonthNumber] AS CurrMonth
    FROM MaxDate m
    JOIN dbo.Dim_Date d
        ON d.[Date] = m.MaxDt
),
-- Derive the previous Year & Month (handle Jan -> previous year, Dec)
PrevMonth AS
(
    SELECT
        CASE 
            WHEN CurrMonth = 1 THEN CurrYear - 1
            ELSE CurrYear
        END AS PrevYear,
        CASE 
            WHEN CurrMonth = 1 THEN 12
            ELSE CurrMonth - 1
        END AS PrevMonth
    FROM CurrMonth
)
SELECT * 
FROM CurrMonth 
CROSS JOIN PrevMonth;
GO


/* =========================================================================
   2. Which top 10 merchants have the highest interchange volume?
   ======================================================================== */

SELECT TOP (10)
    dm.Merchant,
    SUM(f.SettlementAmount)      AS InterchangeVolume,    -- total volume = sum of SettlementAmount
    SUM(f.InterchangeRevenue)    AS InterchangeRevenue    
FROM dbo.Fact_InterchangeTransactions f
JOIN dbo.Dim_Merchant dm
    ON f.Fk_Merchant = dm.Pk_Merchant
GROUP BY dm.Merchant
ORDER BY InterchangeVolume DESC;                          -- highest volume first
GO


/* =========================================================================
   3. Can we see the interchange rate per merchant?
       Interchange Rate = Total InterchangeRevenue / Total SettlementAmount
   ======================================================================== */

SELECT
    dm.Merchant,
    SUM(f.SettlementAmount)   AS InterchangeVolume,
    SUM(f.InterchangeRevenue) AS InterchangeRevenue,
    CASE 
        WHEN SUM(f.SettlementAmount) = 0 
            THEN 0                                   
        ELSE SUM(f.InterchangeRevenue) * 1.0 
             / SUM(f.SettlementAmount)
    END AS InterchangeRate
FROM dbo.Fact_InterchangeTransactions f
JOIN dbo.Dim_Merchant dm
    ON f.Fk_Merchant = dm.Pk_Merchant
GROUP BY dm.Merchant
ORDER BY InterchangeRate DESC;                         -- merchants with the highest rate on top
GO


/* =========================================================================
   4. What percent of the total does the TOP interchange volume merchant 
       represent?
   ======================================================================== */

WITH MerchantVolume AS
(
    -- Compute total volume per merchant
    SELECT
        dm.Merchant,
        SUM(f.SettlementAmount) AS InterchangeVolume
    FROM dbo.Fact_InterchangeTransactions f
    JOIN dbo.Dim_Merchant dm
        ON f.Fk_Merchant = dm.Pk_Merchant
    GROUP BY dm.Merchant
),
TotalVolume AS
(
    -- Total volume across all merchants
    SELECT SUM(InterchangeVolume) AS TotalVol
    FROM MerchantVolume
),
Ranked AS
(
    -- Rank merchants by volume and compute % of total per merchant
    SELECT
        mv.Merchant,
        mv.InterchangeVolume,
        mv.InterchangeVolume * 1.0 / tv.TotalVol AS PctOfTotal,
        RANK() OVER (ORDER BY mv.InterchangeVolume DESC) AS VolRank
    FROM MerchantVolume mv
    CROSS JOIN TotalVolume tv
)
-- Take only the top-ranked merchant (highest volume)
SELECT
    Merchant,
    InterchangeVolume,
    PctOfTotal
FROM Ranked
WHERE VolRank = 1;
GO


/* =========================================================================
   5. Can you rank the merchants in order of greatest to least 
       interchange volume?
   ======================================================================== */

WITH MerchantVolume AS
(
    -- Aggregate volume per merchant
    SELECT
        dm.Merchant,
        SUM(f.SettlementAmount) AS InterchangeVolume
    FROM dbo.Fact_InterchangeTransactions f
    JOIN dbo.Dim_Merchant dm
        ON f.Fk_Merchant = dm.Pk_Merchant
    GROUP BY dm.Merchant
)
SELECT
    Merchant,
    InterchangeVolume,
    DENSE_RANK() OVER (ORDER BY InterchangeVolume DESC) AS VolumeRank
FROM MerchantVolume
ORDER BY VolumeRank;                                 
GO


/* =========================================================================
   6. Create a derived table of merchant performance by Year/Month:
       - InterchangeVolume
       - InterchangeRevenue
       - TotalMonthVolume
       - % of Month Total
       - Rank within that month
   ======================================================================== */

WITH MonthlyBase AS
(
    -- Merchant metrics per Year/Month
    SELECT
        d.[Year],
        d.[MonthNumber],
        d.[MonthName],
        dm.Pk_Merchant,
        dm.Merchant,
        SUM(f.SettlementAmount)   AS InterchangeVolume,
        SUM(f.InterchangeRevenue) AS InterchangeRevenue
    FROM dbo.Fact_InterchangeTransactions f
    JOIN dbo.Dim_Date d
        ON f.ReportingDate = d.[Date]
    JOIN dbo.Dim_Merchant dm
        ON f.Fk_Merchant = dm.Pk_Merchant
    GROUP BY
        d.[Year],
        d.[MonthNumber],
        d.[MonthName],
        dm.Pk_Merchant,
        dm.Merchant
),
MonthlyTotals AS
(
    -- Total volume per Year/Month, across all merchants
    SELECT
        [Year],
        [MonthNumber],
        SUM(InterchangeVolume) AS TotalMonthVolume
    FROM MonthlyBase
    GROUP BY [Year], [MonthNumber]
),
WithShareAndRank AS
(
    -- Attach total volume + % of total + rank within each month
    SELECT
        mb.[Year],
        mb.[MonthNumber],
        mb.[MonthName],
        mb.Pk_Merchant,
        mb.Merchant,
        mb.InterchangeVolume,
        mb.InterchangeRevenue,
        mt.TotalMonthVolume,
        CASE 
            WHEN mt.TotalMonthVolume = 0 THEN 0
            ELSE mb.InterchangeVolume * 1.0 / mt.TotalMonthVolume
        END AS PctOfMonthTotal,
        DENSE_RANK() OVER (
            PARTITION BY mb.[Year], mb.[MonthNumber]
            ORDER BY mb.InterchangeVolume DESC
        ) AS VolumeRank
    FROM MonthlyBase mb
    JOIN MonthlyTotals mt
        ON mt.[Year]        = mb.[Year]
       AND mt.[MonthNumber] = mb.[MonthNumber]
)
SELECT *
FROM WithShareAndRank;
GO


/* =========================================================================
   7. Create a physical derived table 
       dbo.Derived_MerchantMonthlyRank 
       with the same logic as above.
   ======================================================================== */

;WITH MonthlyBase AS
(
    -- Merchant metrics per Year/Month
    SELECT
        d.[Year],
        d.[MonthNumber],
        d.[MonthName],
        dm.Pk_Merchant,
        dm.Merchant,
        SUM(f.SettlementAmount)   AS InterchangeVolume,
        SUM(f.InterchangeRevenue) AS InterchangeRevenue
    FROM dbo.Fact_InterchangeTransactions f
    JOIN dbo.Dim_Date d
        ON f.ReportingDate = d.[Date]
    JOIN dbo.Dim_Merchant dm
        ON f.Fk_Merchant = dm.Pk_Merchant
    GROUP BY
        d.[Year],
        d.[MonthNumber],
        d.[MonthName],
        dm.Pk_Merchant,
        dm.Merchant
),
MonthlyTotals AS
(
    -- Total volume per Year/Month
    SELECT
        [Year],
        [MonthNumber],
        SUM(InterchangeVolume) AS TotalMonthVolume
    FROM MonthlyBase
    GROUP BY [Year], [MonthNumber]
),
WithShareAndRank AS
(
    -- Attach total monthly volume, share, and rank
    SELECT
        mb.[Year],
        mb.[MonthNumber],
        mb.[MonthName],
        mb.Pk_Merchant,
        mb.Merchant,
        mb.InterchangeVolume,
        mb.InterchangeRevenue,
        mt.TotalMonthVolume,
        CASE 
            WHEN mt.TotalMonthVolume = 0 THEN 0
            ELSE mb.InterchangeVolume * 1.0 / mt.TotalMonthVolume
        END AS PctOfMonthTotal,
        DENSE_RANK() OVER (
            PARTITION BY mb.[Year], mb.[MonthNumber]
            ORDER BY mb.InterchangeVolume DESC
        ) AS VolumeRank
    FROM MonthlyBase mb
    JOIN MonthlyTotals mt
        ON mt.[Year]        = mb.[Year]
       AND mt.[MonthNumber] = mb.[MonthNumber]
)
-- Save into a physical table
SELECT
    [Year],
    [MonthNumber],
    [MonthName],
    Pk_Merchant,
    Merchant,
    InterchangeVolume,
    InterchangeRevenue,
    TotalMonthVolume,
    PctOfMonthTotal,
    VolumeRank
INTO dbo.Derived_MerchantMonthlyRank
FROM WithShareAndRank;
GO



/* =========================================================================
   8. Can we see the current rank, interchange revenue, and percentage of 
       total vs the previous month’s rank, revenue and % of total,
       for each merchant?

       Uses Derived_MerchantMonthlyRank + Max Date from fact.
   ======================================================================== */

WITH MaxDate AS
(
    -- Latest ReportingDate in the fact table
    SELECT MAX(ReportingDate) AS MaxDt
    FROM dbo.Fact_InterchangeTransactions
),
CurrMonth AS
(
    -- Current Year & Month from Dim_Date
    SELECT
        d.[Year]        AS CurrYear,
        d.[MonthNumber] AS CurrMonth
    FROM MaxDate m
    JOIN dbo.Dim_Date d
        ON d.[Date] = m.MaxDt
),
PrevMonth AS
(
    -- Previous Year & Month 
    SELECT
        CASE 
            WHEN CurrMonth = 1 THEN CurrYear - 1
            ELSE CurrYear
        END AS PrevYear,
        CASE 
            WHEN CurrMonth = 1 THEN 12
            ELSE CurrMonth - 1
        END AS PrevMonth
    FROM CurrMonth
),
CurrPrevData AS
(
   
    SELECT
        dmr.Pk_Merchant,
        dmr.Merchant,
        dmr.[Year],
        dmr.[MonthNumber],
        dmr.InterchangeVolume,
        dmr.InterchangeRevenue,
        dmr.PctOfMonthTotal,
        dmr.VolumeRank
    FROM dbo.Derived_MerchantMonthlyRank dmr
)
SELECT
    cm.Merchant,

    -- Current month metrics
    cm.InterchangeRevenue  AS CurrMonthRevenue,
    cm.PctOfMonthTotal     AS CurrMonthPctOfTotal,
    cm.VolumeRank          AS CurrMonthRank,

    -- Previous month metrics (same merchant, previous month/year)
    pm.InterchangeRevenue  AS PrevMonthRevenue,
    pm.PctOfMonthTotal     AS PrevMonthPctOfTotal,
    pm.VolumeRank          AS PrevMonthRank
FROM CurrMonth c
CROSS JOIN PrevMonth p
LEFT JOIN CurrPrevData cm
    ON cm.[Year]        = c.CurrYear
   AND cm.[MonthNumber] = c.CurrMonth
LEFT JOIN CurrPrevData pm
    ON pm.Pk_Merchant   = cm.Pk_Merchant
   AND pm.[Year]        = p.PrevYear
   AND pm.[MonthNumber] = p.PrevMonth
ORDER BY cm.InterchangeRevenue DESC;     -- highest current revenue merchants on top
GO


/* =========================================================================
   9. Monthly summary by Year/Month & Merchant:
       - InterchangeVolume
       - InterchangeRevenue
   ======================================================================== */

SELECT
    d.[Year],
    d.[MonthNumber],
    d.[MonthName],
    dm.Merchant,
    SUM(f.SettlementAmount)   AS InterchangeVolume,
    SUM(f.InterchangeRevenue) AS InterchangeRevenue
FROM dbo.Fact_InterchangeTransactions f
JOIN dbo.Dim_Date d
    ON f.ReportingDate = d.[Date]
JOIN dbo.Dim_Merchant dm
    ON f.Fk_Merchant = dm.Pk_Merchant
GROUP BY
    d.[Year],
    d.[MonthNumber],
    d.[MonthName],
    dm.Merchant
ORDER BY
    d.[Year],
    d.[MonthNumber],
    InterchangeVolume DESC;       -- merchants ordered by volume inside each month
GO


