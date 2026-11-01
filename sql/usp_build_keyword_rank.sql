-- T-SQL Stored Procedure: 날짜별 검색어 순위 집계 (SQL Server 2022)
-- 접속: docker exec -it mssql22 /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -d lab
-- 아래 DDL은 SP가 쓰는 컬럼 기준으로 작성했다. 실제 lab DB의 정의와 다르면 INFORMATION_SCHEMA.COLUMNS 결과에 맞춰 고친다.

-- ===== 테이블과 샘플 데이터 =====
DROP TABLE IF EXISTS dbo.keyword_rank;
DROP TABLE IF EXISTS dbo.search_log;
CREATE TABLE dbo.search_log (
    id          INT IDENTITY PRIMARY KEY,
    keyword     NVARCHAR(50) NOT NULL,
    searched_at DATETIME2    NOT NULL
);
CREATE TABLE dbo.keyword_rank (
    rank_date DATE         NOT NULL,
    rank_no   INT          NOT NULL,
    keyword   NVARCHAR(50) NOT NULL,
    cnt       INT          NOT NULL
    -- 동시 실행 시 중복 순위를 막으려면: , CONSTRAINT PK_keyword_rank PRIMARY KEY (rank_date, rank_no)
);
INSERT INTO dbo.search_log (keyword, searched_at) VALUES
    (N'search',  '2026-10-27 09:00'), (N'search',  '2026-10-27 10:00'), (N'search', '2026-10-27 11:00'),
    (N'news',    '2026-10-27 09:30'), (N'news',    '2026-10-27 12:00'),
    (N'weather', '2026-10-27 13:00'), (N'weather', '2026-10-27 14:00'),   -- news와 동점(2건)
    (N'stock',   '2026-10-27 15:00'),
    (N'search',  '2026-10-28 09:00');                                     -- 다른 날짜, 집계 제외 확인용
GO

-- ===== SP =====
CREATE OR ALTER PROCEDURE usp_build_keyword_rank
    @target_date DATE,
    @top_n INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRAN;

        DELETE FROM dbo.keyword_rank
        WHERE rank_date = @target_date;

        -- 동점 처리: ROW_NUMBER와 TOP이 같은 정렬 기준(count 내림차순, keyword)을 쓰도록 맞춤
        INSERT INTO dbo.keyword_rank (rank_date, rank_no, keyword, cnt)
        SELECT TOP (@top_n)
               @target_date,
               ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, keyword) AS rank_no,
               keyword,
               COUNT(*) AS cnt
        FROM dbo.search_log
        WHERE searched_at >= @target_date
          AND searched_at <  DATEADD(DAY, 1, @target_date)
        GROUP BY keyword
        ORDER BY rank_no;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH
END
GO

-- ===== 검증 1: 정상 실행 =====
-- 기대: 1 search 3 / 2 news 2 / 3 weather 2 (동점은 keyword 순), 10/28 데이터 제외
EXEC usp_build_keyword_rank @target_date = '2026-10-27', @top_n = 3;
SELECT * FROM dbo.keyword_rank ORDER BY rank_date, rank_no;
GO

-- ===== 검증 2: 같은 날짜 재실행 =====
-- 기대: 중복 없이 같은 3행 (DELETE 후 INSERT)
EXEC usp_build_keyword_rank @target_date = '2026-10-27', @top_n = 3;
SELECT * FROM dbo.keyword_rank ORDER BY rank_date, rank_no;
GO

-- ===== 검증 3: INSERT 단계 에러 시 롤백 =====
-- 기대: TOP에 음수를 넣어 INSERT에서 에러, CATCH에서 ROLLBACK 후 THROW. 앞선 DELETE도 취소되어 3행 유지
EXEC usp_build_keyword_rank @target_date = '2026-10-27', @top_n = -1;
GO
SELECT * FROM dbo.keyword_rank ORDER BY rank_date, rank_no;
GO

-- 동시 실행 (실험 안 함, 추론): 기본 READ COMMITTED에서 같은 날짜로 두 세션이 동시에 실행하면
-- 둘 다 지울 행이 없는 상태로 DELETE를 지나 각자 INSERT해 순위가 중복될 수 있다.
-- 대응: keyword_rank에 PRIMARY KEY (rank_date, rank_no)를 두거나(두 번째 실행이 중복 키 에러), sp_getapplock으로 직렬화.
