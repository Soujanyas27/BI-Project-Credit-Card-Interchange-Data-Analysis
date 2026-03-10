/* =====================================================================
   Script:  Create_InterChange_Environments.sql
   Purpose: Create the three environments required for the InterChange project:
            - InterChange_db_Dev
            - InterChange_db_Test
            - InterChange_db_Prod
   ===================================================================== */

---------------------------
-- 1. Create DEV database
---------------------------
IF DB_ID('InterChange_db_Dev') IS NULL
BEGIN
    PRINT 'Creating database: InterChange_db_Dev...';
    CREATE DATABASE InterChange_db_Dev;
    PRINT 'InterChange_db_Dev created.';
END
ELSE
BEGIN
    PRINT 'InterChange_db_Dev already exists. Skipping.';
END
GO

---------------------------
-- 2. Create TEST database
---------------------------
IF DB_ID('InterChange_db_Test') IS NULL
BEGIN
    PRINT 'Creating database: InterChange_db_Test...';
    CREATE DATABASE InterChange_db_Test;
    PRINT 'InterChange_db_Test created.';
END
ELSE
BEGIN
    PRINT 'InterChange_db_Test already exists. Skipping.';
END
GO

---------------------------
-- 3. Create PROD database
---------------------------
IF DB_ID('InterChange_db_Prod') IS NULL
BEGIN
    PRINT 'Creating database: InterChange_db_Prod...';
    CREATE DATABASE InterChange_db_Prod;
    PRINT 'InterChange_db_Prod created.';
END
ELSE
BEGIN
    PRINT 'InterChange_db_Prod already exists. Skipping.';
END
GO





PRINT 'All InterChange environments are created / verified successfully.';