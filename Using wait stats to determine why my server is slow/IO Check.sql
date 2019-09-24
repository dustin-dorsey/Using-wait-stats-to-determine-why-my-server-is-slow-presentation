


    DECLARE @SecondsToRun INT = 90
    DECLARE @Seconds INT = @SecondsToRun
    DECLARE @SinceStartup TINYINT = 0 
    DECLARE @StartSampleTime DATETIMEOFFSET
    DECLARE @FinishSampleTime DATETIMEOFFSET
	DECLARE @FinishSampleTimeWaitFor DATETIME
	DECLARE @StringToExecute NVARCHAR(MAX)

SELECT
    @StartSampleTime = SYSDATETIMEOFFSET(),
    @FinishSampleTime = DATEADD(ss, @Seconds, SYSDATETIMEOFFSET()),
	@FinishSampleTimeWaitFor = DATEADD(ss, @Seconds, GETDATE())

    IF OBJECT_ID('tempdb..#MasterFiles') IS NOT NULL
        DROP TABLE #MasterFiles;
    CREATE TABLE #MasterFiles (database_id INT, file_id INT, type_desc NVARCHAR(50), name NVARCHAR(255), physical_name NVARCHAR(255), size BIGINT);
    /* Azure SQL Database doesn't have sys.master_files, so we have to build our own. */
    IF CAST(SERVERPROPERTY('edition') AS VARCHAR(100)) = 'SQL Azure'
        SET @StringToExecute = 'INSERT INTO #MasterFiles (database_id, file_id, type_desc, name, physical_name, size) SELECT DB_ID(), file_id, type_desc, name, physical_name, size FROM sys.database_files;'
    ELSE
        SET @StringToExecute = 'INSERT INTO #MasterFiles (database_id, file_id, type_desc, name, physical_name, size) SELECT database_id, file_id, type_desc, name, physical_name, size FROM sys.master_files;'
    EXEC(@StringToExecute);

    IF OBJECT_ID('tempdb..#FileStats') IS NOT NULL
        DROP TABLE #FileStats;
    CREATE TABLE #FileStats (
        ID INT IDENTITY(1, 1) PRIMARY KEY CLUSTERED,
        Pass TINYINT NOT NULL,
        SampleTime DATETIMEOFFSET NOT NULL,
        DatabaseID INT NOT NULL,
        FileID INT NOT NULL,
        DatabaseName NVARCHAR(256) ,
        FileLogicalName NVARCHAR(256) ,
        TypeDesc NVARCHAR(60) ,
        SizeOnDiskMB BIGINT ,
        io_stall_read_ms BIGINT ,
        num_of_reads BIGINT ,
        bytes_read BIGINT ,
        io_stall_write_ms BIGINT ,
        num_of_writes BIGINT ,
        bytes_written BIGINT,
        PhysicalName NVARCHAR(520) ,
        avg_stall_read_ms INT ,
        avg_stall_write_ms INT
    );
  
    INSERT INTO #FileStats (Pass, SampleTime, DatabaseID, FileID, DatabaseName, FileLogicalName, SizeOnDiskMB, io_stall_read_ms ,
        num_of_reads, [bytes_read] , io_stall_write_ms,num_of_writes, [bytes_written], PhysicalName, TypeDesc)
    SELECT
        1 AS Pass,
        CASE @Seconds WHEN 0 THEN @StartSampleTime ELSE SYSDATETIMEOFFSET() END AS SampleTime,
        mf.[database_id],
        mf.[file_id],
        DB_NAME(vfs.database_id) AS [db_name],
        mf.name + N' [' + mf.type_desc COLLATE SQL_Latin1_General_CP1_CI_AS + N']' AS file_logical_name ,
        CAST(( ( vfs.size_on_disk_bytes / 1024.0 ) / 1024.0 ) AS INT) AS size_on_disk_mb ,
        CASE @Seconds WHEN 0 THEN 0 ELSE vfs.io_stall_read_ms END ,
        CASE @Seconds WHEN 0 THEN 0 ELSE vfs.num_of_reads END ,
        CASE @Seconds WHEN 0 THEN 0 ELSE vfs.[num_of_bytes_read] END ,
        CASE @Seconds WHEN 0 THEN 0 ELSE vfs.io_stall_write_ms END ,
        CASE @Seconds WHEN 0 THEN 0 ELSE vfs.num_of_writes END ,
        CASE @Seconds WHEN 0 THEN 0 ELSE vfs.[num_of_bytes_written] END ,
        mf.physical_name,
        mf.type_desc
    FROM sys.dm_io_virtual_file_stats (NULL, NULL) AS vfs
    INNER JOIN #MasterFiles AS mf ON vfs.file_id = mf.file_id
        AND vfs.database_id = mf.database_id
    WHERE vfs.num_of_reads > 0
        OR vfs.num_of_writes > 0;

    IF SYSDATETIMEOFFSET() < @FinishSampleTime
		BEGIN
		RAISERROR('Waiting to match @Seconds parameter',10,1) WITH NOWAIT;
        WAITFOR TIME @FinishSampleTimeWaitFor;
		END

    INSERT INTO #FileStats (Pass, SampleTime, DatabaseID, FileID, DatabaseName, FileLogicalName, SizeOnDiskMB, io_stall_read_ms ,
        num_of_reads, [bytes_read] , io_stall_write_ms,num_of_writes, [bytes_written], PhysicalName, TypeDesc, avg_stall_read_ms, avg_stall_write_ms)
    SELECT         2 AS Pass,
        SYSDATETIMEOFFSET() AS SampleTime,
        mf.[database_id],
        mf.[file_id],
        DB_NAME(vfs.database_id) AS [db_name],
        mf.name + N' [' + mf.type_desc COLLATE SQL_Latin1_General_CP1_CI_AS + N']' AS file_logical_name ,
        CAST(( ( vfs.size_on_disk_bytes / 1024.0 ) / 1024.0 ) AS INT) AS size_on_disk_mb ,
        vfs.io_stall_read_ms ,
        vfs.num_of_reads ,
        vfs.[num_of_bytes_read],
        vfs.io_stall_write_ms ,
        vfs.num_of_writes ,
        vfs.[num_of_bytes_written],
        mf.physical_name,
        mf.type_desc,
        0,
        0
    FROM sys.dm_io_virtual_file_stats (NULL, NULL) AS vfs
    INNER JOIN #MasterFiles AS mf ON vfs.file_id = mf.file_id
        AND vfs.database_id = mf.database_id
    WHERE vfs.num_of_reads > 0
        OR vfs.num_of_writes > 0;

    UPDATE fNow
    SET avg_stall_read_ms = ((fNow.io_stall_read_ms - fBase.io_stall_read_ms) / (fNow.num_of_reads - fBase.num_of_reads))
    FROM #FileStats fNow
    INNER JOIN #FileStats fBase ON fNow.DatabaseID = fBase.DatabaseID AND fNow.FileID = fBase.FileID AND fNow.SampleTime > fBase.SampleTime AND fNow.num_of_reads > fBase.num_of_reads AND fNow.io_stall_read_ms > fBase.io_stall_read_ms
    WHERE (fNow.num_of_reads - fBase.num_of_reads) > 0

    UPDATE fNow
    SET avg_stall_write_ms = ((fNow.io_stall_write_ms - fBase.io_stall_write_ms) / (fNow.num_of_writes - fBase.num_of_writes))
    FROM #FileStats fNow
    INNER JOIN #FileStats fBase ON fNow.DatabaseID = fBase.DatabaseID AND fNow.FileID = fBase.FileID AND fNow.SampleTime > fBase.SampleTime AND fNow.num_of_writes > fBase.num_of_writes AND fNow.io_stall_write_ms > fBase.io_stall_write_ms
    WHERE (fNow.num_of_writes - fBase.num_of_writes) > 0;
 
            WITH readstats AS (
                SELECT 'PHYSICAL READS' AS Pattern,
                ROW_NUMBER() OVER (ORDER BY wd2.avg_stall_read_ms DESC) AS StallRank,
                wd2.SampleTime AS [Sample Time],
                DATEDIFF(ss,wd1.SampleTime, wd2.SampleTime) AS [Sample (seconds)],
                wd1.DatabaseName ,
                wd1.FileLogicalName AS [File Name],
                UPPER(SUBSTRING(wd1.PhysicalName, 1, 2)) AS [Drive] ,
                wd1.SizeOnDiskMB ,
                ( wd2.num_of_reads - wd1.num_of_reads ) AS [# Reads/Writes],
                CASE WHEN wd2.num_of_reads - wd1.num_of_reads > 0
                  THEN CAST(( wd2.bytes_read - wd1.bytes_read)/1024./1024. AS NUMERIC(21,1))
                  ELSE 0
                END AS [MB Read/Written],
                wd2.avg_stall_read_ms AS [Avg Stall (ms)],
                wd1.PhysicalName AS [file physical name]
            FROM #FileStats wd2
                JOIN #FileStats wd1 ON wd2.SampleTime > wd1.SampleTime
                  AND wd1.DatabaseID = wd2.DatabaseID
                  AND wd1.FileID = wd2.FileID
            ),
            writestats AS (
                SELECT
                'PHYSICAL WRITES' AS Pattern,
                ROW_NUMBER() OVER (ORDER BY wd2.avg_stall_write_ms DESC) AS StallRank,
                wd2.SampleTime AS [Sample Time],
                DATEDIFF(ss,wd1.SampleTime, wd2.SampleTime) AS [Sample (seconds)],
                wd1.DatabaseName ,
                wd1.FileLogicalName AS [File Name],
                UPPER(SUBSTRING(wd1.PhysicalName, 1, 2)) AS [Drive] ,
                wd1.SizeOnDiskMB ,
                ( wd2.num_of_writes - wd1.num_of_writes ) AS [# Reads/Writes],
                CASE WHEN wd2.num_of_writes - wd1.num_of_writes > 0
                  THEN CAST(( wd2.bytes_written - wd1.bytes_written)/1024./1024. AS NUMERIC(21,1))
                  ELSE 0
                END AS [MB Read/Written],
                wd2.avg_stall_write_ms AS [Avg Stall (ms)],
                wd1.PhysicalName AS [file physical name]
            FROM #FileStats wd2
                JOIN #FileStats wd1 ON wd2.SampleTime > wd1.SampleTime
                  AND wd1.DatabaseID = wd2.DatabaseID
                  AND wd1.FileID = wd2.FileID
            )
            SELECT
                Pattern, [Sample Time], [Sample (seconds)], [File Name], [Drive],  [# Reads/Writes],[MB Read/Written],[Avg Stall (ms)], [file physical name]
            FROM readstats
            WHERE StallRank <=5 AND [MB Read/Written] > 0
            UNION ALL
            SELECT Pattern, [Sample Time], [Sample (seconds)], [File Name], [Drive],  [# Reads/Writes],[MB Read/Written],[Avg Stall (ms)], [file physical name]
            FROM writestats
            WHERE StallRank <=5 AND [MB Read/Written] > 0;


 


GO


