if not exists (select 1 from sys.objects  where name = 'usp_rename_db' and type = 'P')
exec ('create procedure dbo.usp_rename_db  as SELECT 1')
go
alter procedure dbo.usp_rename_db  
@sourceDBName		as sysname,
@destinationDBName	as sysname,
@execute			as int,
@help				as int
as
/*************************************************************************************************************************************************
Author		:	██╗  ██╗██╗███╗   ██╗    ███████╗██╗  ██╗ █████╗ ██╗  ██╗
				██║ ██╔╝██║████╗  ██║    ██╔════╝██║  ██║██╔══██╗██║  ██║
				█████╔╝ ██║██╔██╗ ██║    ███████╗███████║███████║███████║
				██╔═██╗ ██║██║╚██╗██║    ╚════██║██╔══██║██╔══██║██╔══██║
				██║  ██╗██║██║ ╚████║    ███████║██║  ██║██║  ██║██║  ██║
				╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝    ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝ (@TheRockStarDBA)

				Sr. DBA 

Date		:	- Original Version created on 11/18/2015
				

Comments	:	- Tested on SQL Server 2005 through SQL Server 2016
				- This script will be helpful when renaming a source (EXISTING) database to a DBA standard naming convention

				- This script 
						- will put current (sourceDB) database in single user
						- rename it to the destinationDB name
						- rename the logical and physical file names in system tables
						- offline the database 
						- rename the PHYSICAL database files - MDF and LDF

Limitations	:	NONE .. There is limited error catching .... but this script works flawless !!	
                                                                  

Usage		:	- You can use this script free by keeping this header as is and give due credit to the author of this script which is ME :-)
				- Use it as per your risk --> Neither Me or my employer is responsible for any 
						- DATA LOSS !!
						- Financial LOSS !!
						- Emotional LOSS !!
						- ANY LOSS THAT YOU CAN THINK !!
				- When not running as Stored procedure - LOOK FOR "CHANGE HERE" !! and replac with correct database names !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
				
**************************************************************************************************************************************************/



set nocount on

--- prequisite done .. main code begins ....
--declare @sourceDBName sysname
--declare @destinationDBName sysname
--declare @execute int -- 0 = print the statements ONLY
--					 -- 1 = execute the code 
--declare @help int -- 1 = shows code usage

declare @sqltext1 nvarchar(max) = N''

declare @ndf_count int 
declare @max_ndf_count int

declare @ldf_count int
declare @max_ldf_count int

declare @minFileID int

/******* CHANGE HERE START ****************************************************
set @sourceDBName = 'MACK'								-- The source database that you want to rename
set @destinationDBName = 'KIN'						-- the destination db that you want as per DBA Standards !!
set @execute = 1
set @help = 0
******* CHANGE HERE END ******************************************************/

if @help = 1 
begin
RAISERROR ('--!! SCRIPT Usage :', 0, 1) WITH NOWAIT
RAISERROR ('--!! ** This will actually run the script and rename your source database with destination database name **', 0, 1) WITH NOWAIT
RAISERROR ('--!! ** To NOT execute the script and ONLY print the statements, run with @execute = 0 **', 0, 1) WITH NOWAIT
PRINT CHAR(10)
RAISERROR ('EXEC dbo.usp_rename_db	@sourceDBName = ''your source database name'' ', 0, 1) WITH NOWAIT
RAISERROR ('						,@destinationDBName = ''your destination database name'' ', 0, 1) WITH NOWAIT
RAISERROR ('						,@execute = 1 ', 0, 1) WITH NOWAIT
GOTO DEADZONE
end

if exists (select 1 from master.sys.databases where name = ''+@destinationDBName+'' and is_read_only <> 1 and state_desc = 'ONLINE' and user_access_desc= 'MULTI_USER') or	-- destination database exists
	 not exists (select 1 from master.sys.databases where name  = ''+@sourceDBName+'' and is_read_only <> 1 and state_desc = 'ONLINE' and user_access_desc= 'MULTI_USER') or	-- source database does not exist
	 (@sourceDBName = @destinationDBName)	or																							-- source and destination cannot be same .. it will create HAVOC !!
	 (@sourceDBName = '') or (@destinationDBName = '')	-- source or destination cannot be ''
	 and IS_SRVROLEMEMBER ('sysadmin') = 1  -- the user has to be an "SA" or member of "sysadmin" 
	 and @sourceDBName not in (select name from master.sys.databases where database_id > 4)  -- you cannot rename system databases
	 and @destinationDBName not in (select name from master.sys.databases where database_id > 4)  -- you cannot rename system databases

begin
print char(10)
RAISERROR ('!! ************************ Possible reasons for ERROR ************************************************* !!', 0, 1) WITH NOWAIT
RAISERROR ('!! The DESTINATION database exists or is set to '''' OR....................   -- you cannot run the script !!', 0, 1) WITH NOWAIT
RAISERROR ('!! The SOURCE database is set to '''' or it does not exist or is READ_ONLY.   -- you cannot run the script !!', 0, 1) WITH NOWAIT
RAISERROR ('!! The SOURCE & DESTINATION DB cannot be same.............................. -- you cannot run the script !!', 0, 1) WITH NOWAIT
RAISERROR ('!! The Current login is NOT SA............................................. -- you cannot run the script !!', 0, 1) WITH NOWAIT
RAISERROR ('!! You cannot rename system databases ..................................... -- you cannot run the script !!', 0, 1) WITH NOWAIT
RAISERROR ('!! ************************ ERROR END ****************************************************************** !!', 0, 1) WITH NOWAIT
GOTO DEADZONE
end
else
begin

---- PRE REQUISITES ... Enable xp_cmdshell
if (select 1 from master.sys.configurations where name = 'show advanced options' and value_in_use = 1) = 0

begin
exec sp_configure 'show advanced options', 1;
RECONFIGURE WITH OVERRIDE;
end 
else
begin
print 'show advanced options is set to 1 already ...'
end
if (select 1 from master.sys.configurations where name = 'xp_cmdshell' and value_in_use = 1) = 0

begin
exec sp_configure 'xp_cmdshell', 1;
RECONFIGURE WITH OVERRIDE;
end 
else
begin
print 'xp_cmdshell sp_configure option is set to 1 already ...'
end;

IF OBJECT_ID('tempdb..#temp_sys_master_files') IS NOT NULL DROP TABLE #temp_sys_master_files;

select file_id, type_desc, name, physical_name 
into #temp_sys_master_files
from master.sys.master_files where 1=0 -- just create a skeleton 

select @sqltext1 = N''
select @sqltext1 += N'select file_id, type_desc, name, physical_name 
from '+@sourceDBName+'.sys.database_files;'

insert into  #temp_sys_master_files
EXEC sys.sp_executesql @sqltext1;

select @sqltext1=N''

select @ndf_count = count(1) from #temp_sys_master_files
where file_id > 2 and type_desc = 'ROWS'

select @ldf_count = count(1) from #temp_sys_master_files
where file_id > 2 and type_desc = 'LOG'

select @max_ndf_count = @ndf_count+1
select @max_ldf_count = @ldf_count+1

print '/************************ script starts here ******************************************************************************************************' + char(10)

print '-- step 1: PUT DATABASE IN SINGLE USER MODE AND RENAME THE DATABASE ' + CHAR(10)
SELECT		@sqltext1 += N'alter database '+QUOTENAME(@sourceDBName)+ ' set single_user with rollback immediate;'	+ char(10)			-- single user mode
				+ N' waitfor delay ''00:00:03''' + char(10)
				+ N' alter database '+QUOTENAME(@sourceDBName)+ ' modify NAME = '+QUOTENAME(@destinationDBName) + ';'+char(10)   -- rename the database to new name

print @sqltext1
if @execute = 1 
begin
EXEC sys.sp_executesql @sqltext1;
end
select @sqltext1 = N''
print '-- step 2: NOW MODIFY THE LOGICAL AND PHYSICAL DATABASE NAMES FOR BOTH DATA AND LOG FILES ' + CHAR(10)
select @sqltext1 += char(10) + N'ALTER DATABASE ' + QUOTENAME(@destinationDBName) + ' MODIFY FILE ( NAME = N' + QUOTENAME(name,'''') +', NEWNAME= N'+
	 CASE 
		  WHEN type_desc = 'ROWS' AND [file_id] = 1 THEN QUOTENAME(@destinationDBName,'''')
		  WHEN type_desc = 'LOG' THEN QUOTENAME(@destinationDBName+'_log','''') 
 END +');'
	 + char(10) 
	 + N'ALTER DATABASE ' + QUOTENAME(@destinationDBName) + ' MODIFY FILE ( NAME = N' +
	 CASE 
		  WHEN type_desc = 'ROWS' AND [file_id] = 1 THEN QUOTENAME(@destinationDBName,'''')
		  WHEN type_desc = 'LOG'  THEN QUOTENAME(@destinationDBName+'_log','''') 

	 END 
	 +', FILENAME = N''' + SUBSTRING([physical_name], 1,LEN([physical_name]) - CHARINDEX('\',REVERSE([physical_name])) + 1 ) +
     CASE 
		  WHEN type_desc = 'ROWS' AND [file_id] = 1 THEN @destinationDBName+'.mdf'' );'
		  WHEN type_desc = 'LOG'  THEN @destinationDBName+'_log.ldf'' );' 
END 
	 FROM #temp_sys_master_files
	 where [file_id] < 3 -- get me only mdf and first ldf ... rest will be taken care seperately


	 
	 print @sqltext1

if @execute = 1 
begin
EXEC sys.sp_executesql @sqltext1;
end


select @sqltext1 = N''

	--- multiple ndf files are taken care below ....
	select @minFileID = max(file_id) from #temp_sys_master_files where file_id > 2 and type_desc = 'ROWS'

	while (@ndf_count > 0) and (@ndf_count < @max_ndf_count)
	begin
	select    @sqltext1 = char(10)+N'ALTER DATABASE '+ QUOTENAME(@destinationDBName) + ' MODIFY FILE ( NAME = N' + QUOTENAME(name,'''') +', NEWNAME= N'''+@destinationDBName+'' 
							+ cast(@ndf_count as varchar(max)) +''');' 
							+ char(10) + N'ALTER DATABASE ' + QUOTENAME(@destinationDBName) + ' MODIFY FILE ( NAME = N'''+@destinationDBName+'' 
							+ cast(@ndf_count as varchar(max)) +'''' 

						  +', FILENAME = N''' + SUBSTRING([physical_name], 1,LEN([physical_name]) - CHARINDEX('\',REVERSE([physical_name])) + 1 ) + @destinationDBName+cast(@ndf_count as varchar(max))+'.ndf'' );'
						FROM #temp_sys_master_files  where file_id > 2 and type_desc = 'ROWS' and file_id = @minFileID

	select @minFileID = max(file_id) from #temp_sys_master_files where file_id > 2 and type_desc = 'ROWS' and file_id < @minFileID	
	set @ndf_count = @ndf_count - 1

	print @sqltext1
	if @execute = 1 
begin
EXEC sys.sp_executesql @sqltext1;
end
	end

	--- multiple log files are taken care below ......

select @minFileID = 0  -- zero out
select @sqltext1 = N'' -- zero out
select @minFileID = max(file_id) from #temp_sys_master_files where file_id > 2 and type_desc = 'LOG'

while (@ldf_count > 0) and (@ldf_count  < @max_ldf_count)
begin
select    @sqltext1 = char(10)+N'ALTER DATABASE '+ QUOTENAME(@destinationDBName) + ' MODIFY FILE ( NAME = N' + QUOTENAME(name,'''') +', NEWNAME= N'''+@destinationDBName+'_log_' 
						+ cast(@ldf_count as varchar(max)) +''');' 
						+ char(10) + N'ALTER DATABASE ' + QUOTENAME(@destinationDBName) + ' MODIFY FILE ( NAME = N'''+@destinationDBName+'_log_' 
						+ cast(@ldf_count as varchar(max)) +'''' 

					  +', FILENAME = N''' + SUBSTRING([physical_name], 1,LEN([physical_name]) - CHARINDEX('\',REVERSE([physical_name])) + 1 ) + @destinationDBName+'_log_'+cast(@ldf_count as varchar(max))+'.ldf'' );'
					FROM #temp_sys_master_files  where file_id > 2 and type_desc = 'LOG' and file_id = @minFileID

select @minFileID = max(file_id) from #temp_sys_master_files where file_id > 2 and type_desc = 'LOG' and file_id < @minFileID	
set @ldf_count = @ldf_count -1
print @sqltext1
if @execute = 1 
begin
EXEC sys.sp_executesql @sqltext1;
end
end 
print '-- step 3: TAKE THE DATABASE OFFLINE TO PHYSICALLY RENAME THE DATABASE FILES ON THE DISK .. ' + CHAR(10)
select @sqltext1 = char(10)+N' alter database '+QUOTENAME(@destinationDBName)+ ' set OFFLINE with rollback immediate;'

print @sqltext1 

if @execute = 1 
begin
EXEC sys.sp_executesql @sqltext1;
end

select @sqltext1 = N''
print '-- step 4: PHYSICALL RENAME THE DATABASE FILES ON DISK USING xp_cmdshell and RENAME .. ' + CHAR(10)
select @sqltext1 += char(10) +N'exec xp_cmdshell ''RENAME "' +physical_name+'" '+  
  CASE 
		  WHEN type_desc = 'ROWS' AND [file_id] = 1 THEN  '"'+@destinationDBName+'.mdf"'';' 
		  WHEN type_desc = 'LOG' THEN '"'+@destinationDBName+'_log.ldf"'';' 
     END 
FROM #temp_sys_master_files
where [file_id] < 3 -- get me only mdf and first ldf ... rest will be taken care seperately


print @sqltext1 

if @execute = 1 
begin
EXEC sys.sp_executesql @sqltext1;
end

select @ndf_count = count(1) from #temp_sys_master_files
where file_id > 2 and type_desc = 'ROWS'

select @ldf_count = count(1) from #temp_sys_master_files
where file_id > 2 and type_desc = 'LOG'

select @max_ndf_count = @ndf_count+1
select @max_ldf_count = @ldf_count+1

select @minFileID = 0  -- zero out
select @sqltext1 = N'' -- zero out
--- multiple ndf files are taken care below ....
select @minFileID = max(file_id) from #temp_sys_master_files where file_id > 2 and type_desc = 'ROWS'

while (@ndf_count > 0) and (@ndf_count < @max_ndf_count)
begin

select    @sqltext1 = char(10)+N'exec xp_cmdshell ''RENAME "' +physical_name+'" "'+@destinationDBName+cast(@ndf_count as varchar(max))+'.ndf"'';'
						
					FROM #temp_sys_master_files  where file_id > 2 and type_desc = 'ROWS' and file_id = @minFileID

select @minFileID = max(file_id) from #temp_sys_master_files where file_id > 2 and type_desc = 'ROWS' and file_id < @minFileID	
set @ndf_count = @ndf_count - 1

print @sqltext1
if @execute = 1 
begin
EXEC sys.sp_executesql @sqltext1;
end
end

--- multiple log files are taken care below ......
select @minFileID = 0  -- zero out
select @sqltext1 = N'' -- zero out
select @minFileID = max(file_id) from #temp_sys_master_files where file_id > 2 and type_desc = 'LOG'

while (@ldf_count > 0) and (@ldf_count  < @max_ldf_count)
begin
select    @sqltext1 = char(10)+N'exec xp_cmdshell ''RENAME "' +physical_name+'" "'+ @destinationDBName+'_log_'+cast(@ldf_count as varchar(max))+'.ldf'';'
					FROM #temp_sys_master_files  where file_id > 2 and type_desc = 'LOG' and file_id = @minFileID

select @minFileID = max(file_id) from #temp_sys_master_files where file_id > 2 and type_desc = 'LOG' and file_id < @minFileID	
set @ldf_count = @ldf_count -1
print @sqltext1
if @execute = 1 
begin
EXEC sys.sp_executesql @sqltext1;
end
end


select @sqltext1 = N''
print '-- step 5: ONLINE THE DATABASE AND SET IT TO MULTI USER .. ' + CHAR(10)
select @sqltext1 = char(10)+N' alter database '+QUOTENAME(@destinationDBName)+ ' set ONLINE, MULTI_USER with rollback immediate;'

print @sqltext1 

if @execute = 1 
begin
EXEC sys.sp_executesql @sqltext1;
end

END 

DEADZONE:
--- main code ends ....