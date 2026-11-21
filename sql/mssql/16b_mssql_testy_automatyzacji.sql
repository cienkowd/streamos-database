-- StreamOS - etap 2, pkt 10, czesc 4: testy automatyzacji w SQL Server
-- odpowiednik 11b, te same numery testow
-- uruchamiac jako sa, POLECENIE PO POLECENIU (Ctrl+Enter), zrzut kazdego wyniku
--
-- uwaga do porownan z PostgreSQL: dziennik i rozliczenia przyszly z PostgreSQL w pkt 9,
-- wiec pierwsze uruchomienie nadrobi tylko dni od migracji

USE streamos;
GO


-- ===================== stan przed =====================

-- test 1: ile aktywnych kampanii powinno zostac zamknietych
SELECT SUM(CASE WHEN data_do < CAST(GETDATE() AS DATE) THEN 1 ELSE 0 END)              AS po_terminie,
       SUM(CASE WHEN data_do >= CAST(GETDATE() AS DATE)
                 AND streamos.pozostaly_budzet(kampania_id) < stawka THEN 1 ELSE 0 END) AS bez_budzetu,
       COUNT(*)                                                                         AS aktywne_razem
FROM streamos.kampania
WHERE status = 'aktywna';
-- (count(*) FILTER (WHERE ...) z PostgreSQL nie istnieje w T-SQL - stad SUM(CASE ...))
GO

SELECT MAX(dzien) AS ostatni_rozliczony_dzien FROM streamos.rozliczenie_dzienne;
GO


-- ===================== 1. pierwsze uruchomienie (reczne) =====================

-- test 2
EXEC streamos.zadanie_dobowe;
GO

-- test 3: dziennik - 3 kroki, wszystkie OK
SELECT TOP 3 wpis_id, krok, status, wiersze, komunikat,
       DATEDIFF(MILLISECOND, start, koniec) AS czas_ms
FROM streamos.dziennik_zadan
ORDER BY wpis_id DESC;
-- oczekiwane: liczby zamknietych kampanii jak w tescie 1,
-- rozliczenie: dni od dnia po ostatnim rozliczonym do wczoraj, wiersze = dni x 6 partnerow
GO

-- test 4: rozliczenie z ostatnich 3 dni
SELECT r.dzien, p.nazwa AS partner, r.liczba_emisji,
       ROUND(r.przychod, 2) AS przychod, ROUND(r.nalezne, 2) AS nalezne
FROM streamos.rozliczenie_dzienne r
JOIN streamos.partner_oem p ON p.partner_id = r.partner_id
WHERE r.dzien >= DATEADD(DAY, -3, CAST(GETDATE() AS DATE))
ORDER BY r.dzien, p.nazwa;
GO

-- test 5: suma dni poprzedniego miesiaca = funkcja miesieczna
-- rozliczenia dzienne za poprzedni miesiac policzyl jeszcze PostgreSQL (przyszly z migracja),
-- a funkcje liczy SQL Server - zgodnosc potwierdza tez, ze strefa czasowa jest liczona tak samo
SELECT p.nazwa AS partner,
       ROUND(SUM(r.nalezne), 2) AS suma_dzienna,
       (SELECT f.nalezne_partnerowi FROM streamos.rozliczenie_partnerow(NULL) f
        WHERE f.partner = p.nazwa) AS funkcja_miesieczna
FROM streamos.rozliczenie_dzienne r
JOIN streamos.partner_oem p ON p.partner_id = r.partner_id
WHERE r.dzien >= DATEFROMPARTS(YEAR(DATEADD(MONTH, -1, GETDATE())), MONTH(DATEADD(MONTH, -1, GETDATE())), 1)
  AND r.dzien <  DATEFROMPARTS(YEAR(GETDATE()), MONTH(GETDATE()), 1)
GROUP BY p.nazwa
ORDER BY p.nazwa;
-- oczekiwane: kolumny rowne
GO

-- test 6: kampanie zamkniete
SELECT SUM(CASE WHEN data_do < CAST(GETDATE() AS DATE) THEN 1 ELSE 0 END)         AS po_terminie,
       SUM(CASE WHEN streamos.pozostaly_budzet(kampania_id) < stawka THEN 1 ELSE 0 END) AS bez_budzetu
FROM streamos.kampania
WHERE status = 'aktywna';
-- oczekiwane: 0, 0 (albo NULL, NULL, jesli nie zostala zadna aktywna kampania)
GO


-- ===================== 2. ponowne uruchomienie i nadrabianie =====================

-- test 7: drugie uruchomienie - nic do zrobienia
EXEC streamos.zadanie_dobowe;
GO

SELECT TOP 3 wpis_id, krok, status, wiersze, komunikat
FROM streamos.dziennik_zadan ORDER BY wpis_id DESC;
-- oczekiwane: 0 wierszy we wszystkich krokach, rozliczenie: "wszystkie dni juz rozliczone"
GO

-- test 8: symulacja 3 dni przerwy
DELETE FROM streamos.rozliczenie_dzienne WHERE dzien >= DATEADD(DAY, -3, CAST(GETDATE() AS DATE));
GO

EXEC streamos.zadanie_dobowe;
GO

SELECT TOP 1 wpis_id, krok, status, wiersze, komunikat
FROM streamos.dziennik_zadan ORDER BY wpis_id DESC;
-- oczekiwane: wiersze = 18 (3 dni x 6 partnerow)
GO

SELECT dzien, COUNT(*) AS partnerow
FROM streamos.rozliczenie_dzienne
WHERE dzien >= DATEADD(DAY, -5, CAST(GETDATE() AS DATE))
GROUP BY dzien ORDER BY dzien;
-- oczekiwane: kazdy dzien do wczoraj, po 6 partnerow, bez dziur
GO


-- ===================== 3. obsluga bledu w jednym kroku =====================

-- test 9: sztuczna awaria kroku 3
-- WITH NOCHECK = odpowiednik NOT VALID: nie sprawdza istniejacych wierszy, tylko nowe
ALTER TABLE streamos.rozliczenie_dzienne WITH NOCHECK
    ADD CONSTRAINT test_awaria CHECK (liczba_emisji < 0);
GO

DELETE FROM streamos.rozliczenie_dzienne WHERE dzien = DATEADD(DAY, -1, CAST(GETDATE() AS DATE));
GO

EXEC streamos.zadanie_dobowe;
-- oczekiwany blad 50301: zadanie_dobowe: 1 krok(i) z bledem, szczegoly w dziennik_zadan
GO

SELECT TOP 3 wpis_id, krok, status, wiersze, komunikat
FROM streamos.dziennik_zadan ORDER BY wpis_id DESC;
-- oczekiwane: kroki 1 i 2 OK, krok 3 BLAD z komunikatem o "test_awaria"
GO

-- test 10: naprawa i ponowne uruchomienie
ALTER TABLE streamos.rozliczenie_dzienne DROP CONSTRAINT test_awaria;
GO

EXEC streamos.zadanie_dobowe;
GO

SELECT TOP 1 wpis_id, krok, status, wiersze, komunikat
FROM streamos.dziennik_zadan ORDER BY wpis_id DESC;
-- oczekiwane: OK, wiersze = 6
GO


-- ===================== 4. uruchomienie przez SQL Server Agent =====================

-- test 11: zadanie i harmonogram
SELECT j.name AS zadanie, j.enabled AS wlaczone, s.name AS harmonogram, s.active_start_time
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobschedules js ON js.job_id = j.job_id
JOIN msdb.dbo.sysschedules s     ON s.schedule_id = js.schedule_id
WHERE j.name = N'streamos_zadanie_dobowe';
GO

-- test 12: uruchomienie zadania przez Agenta teraz (bez czekania na 00:15)
-- sp_start_job tylko zleca uruchomienie i od razu wraca - zadanie wykonuje sie w tle
EXEC msdb.dbo.sp_start_job @job_name = N'streamos_zadanie_dobowe';
GO

-- odczekaj kilka sekund, potem: historia zadania
-- step_id 0 = wynik calego zadania, 1 = wynik kroku; run_status 1 = sukces, 0 = blad
SELECT h.step_id, h.step_name,
       CASE h.run_status WHEN 1 THEN 'sukces' WHEN 0 THEN 'blad' ELSE CAST(h.run_status AS VARCHAR(10)) END AS wynik,
       msdb.dbo.agent_datetime(h.run_date, h.run_time) AS uruchomione,
       h.message
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE j.name = N'streamos_zadanie_dobowe'
ORDER BY h.instance_id DESC;
-- oczekiwane: krok 1 i zadanie (step 0) - sukces
GO

SELECT TOP 3 wpis_id, krok, status, wiersze, start
FROM streamos.dziennik_zadan ORDER BY wpis_id DESC;
-- oczekiwane: nowe wpisy z czasem zgodnym z kolumna "uruchomione" z historii Agenta
GO

-- test 13 (opcjonalnie): harmonogram co minute, zeby Agent uruchomil zadanie sam
--   freq_subday_type = 4 -> co ile minut, freq_subday_interval = 1 -> co 1 minute
EXEC msdb.dbo.sp_update_schedule @name = N'streamos_codziennie_0015',
     @freq_subday_type = 4, @freq_subday_interval = 1, @active_start_time = 0;
GO

-- odczekaj 1-2 minuty i uruchom ponownie zapytanie o historie z testu 12, potem przywroc 00:15:
--   freq_subday_type = 1 -> raz, o godzinie active_start_time
EXEC msdb.dbo.sp_update_schedule @name = N'streamos_codziennie_0015',
     @freq_subday_type = 1, @freq_subday_interval = 0, @active_start_time = 1500;
GO
