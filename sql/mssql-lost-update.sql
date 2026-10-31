-- w02 lost update 비교 (SQL Server 2022, REPEATABLE READ)
-- 사용법: 터미널 2개에서 각각 접속, 아래 [S1]/[S2] 표시대로 단계 순서대로 실행
-- 접속: docker exec -it mssql22 /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C
-- sqlcmd는 문장 입력 후 GO를 쳐야 실행된다

-- ===== 초기화 (S1에서 1회) =====
IF DB_ID('txlab') IS NULL CREATE DATABASE txlab;
GO
USE txlab;
DROP TABLE IF EXISTS keyword_stats;
CREATE TABLE keyword_stats (keyword VARCHAR(50) PRIMARY KEY, count INT NOT NULL);
INSERT INTO keyword_stats VALUES ('search', 99);
GO

-- ===== 세션 준비 ([S1], [S2] 각각) =====
USE txlab;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT @@SPID;
GO
-- SPID: S1 = 73, S2 = 74

-- ===== 실험 G-1: 앱 계산값 UPDATE =====
-- 1 [S1]
BEGIN TRAN; SELECT count FROM keyword_stats WHERE keyword='search';
GO
-- 2 [S2]
BEGIN TRAN; SELECT count FROM keyword_stats WHERE keyword='search';
GO
-- 3 [S1] 대기 발생 (S2의 S 락 때문에 X로 변환 대기)
UPDATE keyword_stats SET count = 100 WHERE keyword='search';
GO
-- 4 [S2] 락 관찰: KEY 행에서 S1 = S GRANT + X CONVERT, S2 = S GRANT
SELECT request_session_id, resource_type, resource_description, request_mode, request_status
FROM sys.dm_tran_locks
WHERE resource_database_id = DB_ID('txlab')
ORDER BY request_session_id;
GO
-- 5 [S2] 데드락 발생, 희생자 한쪽이 Msg 1205 (이번 실행에서는 S1이 희생)
UPDATE keyword_stats SET count = 100 WHERE keyword='search';
GO
-- 6 [살아남은 세션]
COMMIT;
GO
-- 확인: 기대 100 (희생 세션은 에러를 받았으므로 재시도하면 101)
SELECT * FROM keyword_stats;
GO
