-- StreamOS - etap 2, pkt 10, czesc 4: automatyzacja w MS SQL Server (SQL Server Agent)
-- odpowiednik 11_automatyzacja.sql (procedura zadanie_dobowe + pg_cron)
-- uruchamiac jako sa, calosc (Alt+X), po 13-15
-- tabele dziennik_zadan i rozliczenie_dzienne powstaly w 12, a ich dane przyszly z PostgreSQL
--
-- roznice wobec PostgreSQL:
--   - harmonogram jest wbudowany (SQL Server Agent), nie trzeba rozszerzenia jak pg_cron.
--     Zadania Agenta sa zapisane w systemowej bazie msdb, nie w bazie streamos.
--   - w T-SQL kazde polecenie poza jawna transakcja zatwierdza sie samo, wiec "COMMIT po
--     kazdym kroku" dostajemy bez pisania COMMIT; blad w kroku cofa tylko to jedno polecenie
--   - w CATCH wolno zapisywac do tabel i zatwierdzac - nie ma ograniczenia z PL/pgSQL
--     ("w bloku z EXCEPTION nie wolno COMMIT"), wiec wpis o bledzie idzie prosto z CATCH
--   - brak search_path, wiec nie ma tez problemu "SET w procedurze blokuje COMMIT"
--   - strefa czasowa: serwer dziala w Europe/Warsaw (TZ w docker-compose), wiec GETDATE()
--     to czas polski i nie trzeba jej ustawiac w procedurze jak w PostgreSQL

USE streamos;
GO


-- ===== 1. procedura zadanie_dobowe =====

CREATE OR ALTER PROCEDURE streamos.zadanie_dobowe
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @start     DATETIMEOFFSET,
            @status    VARCHAR(4),
            @wiersze   INT,
            @komunikat VARCHAR(MAX),
            @bledy     INT = 0,
            @dzis      DATE = CAST(GETDATE() AS DATE),
            @od        DATE,
            @do        DATE;


    -- ===== krok 1: kampanie po terminie =====
    SET @start = SYSDATETIMEOFFSET();
    BEGIN TRY
        UPDATE streamos.kampania
        SET status = 'zakonczona'
        WHERE status = 'aktywna' AND data_do < @dzis;

        SELECT @wiersze = @@ROWCOUNT, @status = 'OK', @komunikat = NULL;
    END TRY
    BEGIN CATCH
        SELECT @wiersze = NULL, @status = 'BLAD', @komunikat = ERROR_MESSAGE(), @bledy = @bledy + 1;
    END CATCH

    INSERT INTO streamos.dziennik_zadan (zadanie, krok, start, koniec, status, wiersze, komunikat)
    VALUES ('zadanie_dobowe', 'kampanie po terminie', @start, SYSDATETIMEOFFSET(), @status, @wiersze, @komunikat);


    -- ===== krok 2: kampanie bez budzetu na kolejna emisje =====
    SET @start = SYSDATETIMEOFFSET();
    BEGIN TRY
        UPDATE k
        SET status = 'zakonczona'
        FROM streamos.kampania k
        WHERE k.status = 'aktywna' AND streamos.pozostaly_budzet(k.kampania_id) < k.stawka;

        SELECT @wiersze = @@ROWCOUNT, @status = 'OK', @komunikat = NULL;
    END TRY
    BEGIN CATCH
        SELECT @wiersze = NULL, @status = 'BLAD', @komunikat = ERROR_MESSAGE(), @bledy = @bledy + 1;
    END CATCH

    INSERT INTO streamos.dziennik_zadan (zadanie, krok, start, koniec, status, wiersze, komunikat)
    VALUES ('zadanie_dobowe', 'kampanie bez budzetu', @start, SYSDATETIMEOFFSET(), @status, @wiersze, @komunikat);


    -- ===== krok 3: dzienne rozliczenie partnerow, z nadrabianiem =====
    SET @start = SYSDATETIMEOFFSET();
    BEGIN TRY
        SET @od = COALESCE((SELECT DATEADD(DAY, 1, MAX(dzien)) FROM streamos.rozliczenie_dzienne),
                           (SELECT CAST(MIN(czas_emisji) AT TIME ZONE 'Central European Standard Time' AS DATE)
                            FROM streamos.emisja_reklamy));
        SET @do = DATEADD(DAY, -1, @dzis);
        SET @wiersze = 0;

        -- warunek potrzebny: GENERATE_SERIES(0, -1) nie zwraca pustego wyniku jak generate_series
        -- w PostgreSQL, tylko liczy w dol (0, -1), bo przy start > stop domyslny krok to -1
        IF @od <= @do
        BEGIN
            -- MERGE = odpowiednik INSERT ... ON CONFLICT DO UPDATE:
            --   WHEN MATCHED     -> wiersz (dzien, partner) juz jest: aktualizacja
            --   WHEN NOT MATCHED -> nie ma: wstawienie
            -- WITH (HOLDLOCK): bez tego dwa rownoczesne MERGE moglyby oba uznac, ze wiersza
            -- nie ma, i oba probowac go wstawic (znany problem MERGE w SQL Serverze)
            -- GENERATE_SERIES (nowe w SQL Server 2022) daje liczby 0..n, zamieniane na kolejne dni
            MERGE streamos.rozliczenie_dzienne WITH (HOLDLOCK) AS cel
            USING (
                SELECT d.dzien, p.partner_id,
                       COALESCE(em.liczba, 0)                        AS liczba_emisji,
                       COALESCE(em.suma, 0)                          AS przychod,
                       COALESCE(em.suma, 0) * p.udzial_procent / 100 AS nalezne
                FROM (SELECT DATEADD(DAY, s.value, @od) AS dzien
                      FROM GENERATE_SERIES(0, DATEDIFF(DAY, @od, @do)) AS s) d
                CROSS JOIN streamos.partner_oem p
                LEFT JOIN (
                    SELECT CAST(e.czas_emisji AT TIME ZONE 'Central European Standard Time' AS DATE) AS dzien,
                           u.partner_id, COUNT(*) AS liczba, SUM(e.koszt) AS suma
                    FROM streamos.emisja_reklamy e
                    JOIN streamos.urzadzenie u ON u.urzadzenie_id = e.urzadzenie_id
                    WHERE e.czas_emisji >= (CAST(@od AS DATETIME2) AT TIME ZONE 'Central European Standard Time')
                      AND e.czas_emisji <  (CAST(DATEADD(DAY, 1, @do) AS DATETIME2) AT TIME ZONE 'Central European Standard Time')
                    GROUP BY CAST(e.czas_emisji AT TIME ZONE 'Central European Standard Time' AS DATE), u.partner_id
                ) em ON em.dzien = d.dzien AND em.partner_id = p.partner_id
            ) AS zrodlo
            ON cel.dzien = zrodlo.dzien AND cel.partner_id = zrodlo.partner_id
            WHEN MATCHED THEN
                UPDATE SET liczba_emisji   = zrodlo.liczba_emisji,
                           przychod        = zrodlo.przychod,
                           nalezne         = zrodlo.nalezne,
                           data_wyliczenia = SYSDATETIMEOFFSET()
            WHEN NOT MATCHED THEN
                INSERT (dzien, partner_id, liczba_emisji, przychod, nalezne)
                VALUES (zrodlo.dzien, zrodlo.partner_id, zrodlo.liczba_emisji, zrodlo.przychod, zrodlo.nalezne);
            -- MERGE musi konczyc sie srednikiem

            SET @wiersze = @@ROWCOUNT;
        END

        SELECT @status = 'OK',
               @komunikat = CASE WHEN @od > @do THEN 'wszystkie dni juz rozliczone'
                                 ELSE CONCAT('dni ', @od, ' - ', @do) END;
    END TRY
    BEGIN CATCH
        SELECT @wiersze = NULL, @status = 'BLAD', @komunikat = ERROR_MESSAGE(), @bledy = @bledy + 1;
    END CATCH

    INSERT INTO streamos.dziennik_zadan (zadanie, krok, start, koniec, status, wiersze, komunikat)
    VALUES ('zadanie_dobowe', 'rozliczenie partnerow', @start, SYSDATETIMEOFFSET(), @status, @wiersze, @komunikat);


    -- blad na koniec, gdy ktorys krok sie nie udal: Agent oznaczy wtedy uruchomienie jako nieudane
    -- (historia zadania), a szczegoly sa w dzienniku. Kroki i wpisy sa juz zapisane - nic nie znika
    IF @bledy > 0
    BEGIN
        SET @komunikat = CONCAT('zadanie_dobowe: ', @bledy, ' krok(i) z bledem, szczegoly w dziennik_zadan');
        THROW 50301, @komunikat, 1;
    END
END;
GO


-- ===== 2. zadanie SQL Server Agent =====
-- zadanie (job) sklada sie z: definicji zadania, krokow, harmonogramu i serwera docelowego.
-- wszystko tworza procedury systemowe z bazy msdb (odpowiednik jednego cron.schedule)

USE msdb;
GO

-- ponowne uruchomienie skryptu: usuniecie starego zadania (razem z nieuzywanym harmonogramem)
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'streamos_zadanie_dobowe')
    EXEC msdb.dbo.sp_delete_job @job_name = N'streamos_zadanie_dobowe', @delete_unused_schedule = 1;
GO

-- definicja zadania
EXEC msdb.dbo.sp_add_job
     @job_name    = N'streamos_zadanie_dobowe',
     @description = N'StreamOS: zamykanie kampanii i dzienne rozliczenie partnerow (odpowiednik pg_cron)',
     @enabled     = 1;

-- krok: polecenie T-SQL w bazie streamos
-- (Agent pozwala na wiele krokow z decyzja "przy bledzie idz do kroku X";
--  tu jeden krok, bo podzial na etapy jest w procedurze - tak jak w PostgreSQL)
EXEC msdb.dbo.sp_add_jobstep
     @job_name      = N'streamos_zadanie_dobowe',
     @step_name     = N'zadanie_dobowe',
     @subsystem     = N'TSQL',
     @database_name = N'streamos',
     @command       = N'EXEC streamos.zadanie_dobowe;';

-- harmonogram: codziennie o 00:15
--   freq_type = 4         -> codziennie
--   freq_interval = 1     -> co 1 dzien
--   active_start_time     -> godzina w formacie HHMMSS jako liczba: 001500 = 1500
EXEC msdb.dbo.sp_add_schedule
     @schedule_name     = N'streamos_codziennie_0015',
     @freq_type         = 4,
     @freq_interval     = 1,
     @active_start_time = 1500;

EXEC msdb.dbo.sp_attach_schedule
     @job_name      = N'streamos_zadanie_dobowe',
     @schedule_name = N'streamos_codziennie_0015';

-- serwer docelowy: bez tego zadanie istnieje, ale Agent go nigdy nie uruchomi
EXEC msdb.dbo.sp_add_jobserver
     @job_name    = N'streamos_zadanie_dobowe',
     @server_name = N'(local)';
GO


-- ===== 3. kontrola =====
SELECT j.name AS zadanie, j.enabled AS wlaczone, s.name AS harmonogram,
       s.freq_type, s.active_start_time,
       CASE WHEN js.next_run_date > 0   -- 0 = Agent jeszcze nie przeliczyl (agent_datetime(0, 0) rzuca blad konwersji)
            THEN msdb.dbo.agent_datetime(js.next_run_date, js.next_run_time) END AS nastepne_uruchomienie
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobschedules js ON js.job_id = j.job_id
JOIN msdb.dbo.sysschedules s     ON s.schedule_id = js.schedule_id
WHERE j.name = N'streamos_zadanie_dobowe';
-- nastepne_uruchomienie moze byc puste przez pierwsze ok. 20 minut -
-- Agent przelicza je okresowo (albo po pierwszym uruchomieniu)
