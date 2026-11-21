-- StreamOS - etap 2, pkt 6: testy automatyzacji
-- uruchamiac jako streamos_admin, POLECENIE PO POLECENIU (Ctrl+Enter), zrzut kazdego wyniku
-- DBeaver w trybie Auto-Commit (CALL procedury z COMMIT nie zadziala w otwartej transakcji)

SET search_path TO streamos;


-- ===================== stan przed =====================

-- test 1: ile aktywnych kampanii powinno zostac zamknietych
SELECT count(*) FILTER (WHERE data_do < current_date)                   AS po_terminie,
       count(*) FILTER (WHERE data_do >= current_date
                          AND pozostaly_budzet(kampania_id) < stawka)   AS bez_budzetu,
       count(*)                                                         AS aktywne_razem
FROM kampania
WHERE status = 'aktywna';
-- 02_dane.sql zamyka kampanie po terminie przy ladowaniu, wiec po_terminie
-- bedzie > 0 tylko dla kampanii, ktorych data_do minela od tamtego czasu


-- ===================== 1. pierwsze uruchomienie (reczne) =====================

-- test 2: reczne wywolanie - pierwsze liczy rozliczenie od pierwszego dnia z emisjami
CALL zadanie_dobowe();

-- test 3: dziennik - 3 kroki, wszystkie OK
SELECT wpis_id, krok, status, wiersze, komunikat,
       koniec - start AS czas_trwania
FROM dziennik_zadan
ORDER BY wpis_id DESC
LIMIT 3;
-- oczekiwane: kampanie po terminie / bez budzetu - liczby jak w tescie 1,
-- rozliczenie partnerow - wiersze = liczba dni x 6 partnerow, komunikat z zakresem dni

-- test 4: rozliczenie - ostatnie 3 dni, wszyscy partnerzy
SELECT r.dzien, p.nazwa AS partner, r.liczba_emisji,
       round(r.przychod, 2) AS przychod, round(r.nalezne, 2) AS nalezne
FROM rozliczenie_dzienne r
JOIN partner_oem p ON p.partner_id = r.partner_id
WHERE r.dzien >= current_date - 3
ORDER BY r.dzien, p.nazwa;

-- test 5: zgodnosc z funkcja z pkt 4 - suma dni poprzedniego miesiaca = rozliczenie miesieczne
SELECT p.nazwa AS partner,
       round(sum(r.nalezne), 2)                       AS suma_dzienna,
       (SELECT f.nalezne_partnerowi FROM rozliczenie_partnerow() f
        WHERE f.partner = p.nazwa)                    AS funkcja_miesieczna
FROM rozliczenie_dzienne r
JOIN partner_oem p ON p.partner_id = r.partner_id
WHERE r.dzien >= date_trunc('month', current_date) - interval '1 month'
  AND r.dzien <  date_trunc('month', current_date)
GROUP BY p.nazwa
ORDER BY p.nazwa;
-- oczekiwane: obie kolumny rowne
-- (jesli DBeaver ma inna strefe czasowa niz Europe/Warsaw, emisje z okolic polnocy
--  moga trafic do innego dnia i pojawi sie roznica - wtedy: SET TimeZone = 'Europe/Warsaw')

-- test 6: kampanie sa juz zamkniete
SELECT count(*) FILTER (WHERE data_do < current_date)                   AS po_terminie,
       count(*) FILTER (WHERE pozostaly_budzet(kampania_id) < stawka)   AS bez_budzetu
FROM kampania
WHERE status = 'aktywna';
-- oczekiwane: 0, 0


-- ===================== 2. ponowne uruchomienie i nadrabianie =====================

-- test 7: drugie uruchomienie tego samego dnia - nic do zrobienia
CALL zadanie_dobowe();

SELECT wpis_id, krok, status, wiersze, komunikat
FROM dziennik_zadan
ORDER BY wpis_id DESC
LIMIT 3;
-- oczekiwane: wszystkie kroki 0 wierszy, rozliczenie: "wszystkie dni juz rozliczone"

-- test 8: symulacja 3 dni przerwy (komputer wylaczony) - usuwamy 3 ostatnie dni rozliczenia
DELETE FROM rozliczenie_dzienne WHERE dzien >= current_date - 3;

CALL zadanie_dobowe();

SELECT wpis_id, krok, status, wiersze, komunikat
FROM dziennik_zadan
ORDER BY wpis_id DESC
LIMIT 1;
-- oczekiwane: rozliczenie partnerow, wiersze = 18 (3 dni x 6 partnerow)

SELECT dzien, count(*) AS partnerow
FROM rozliczenie_dzienne
WHERE dzien >= current_date - 5
GROUP BY dzien
ORDER BY dzien;
-- oczekiwane: kazdy dzien do wczoraj, po 6 partnerow, bez dziur


-- ===================== 3. obsluga bledu w jednym kroku =====================

-- test 9: sztucznie psujemy krok 3 - ograniczenie, ktorego nie spelni zaden wiersz rozliczenia.
-- NOT VALID: nie sprawdza istniejacych wierszy, tylko nowe
ALTER TABLE rozliczenie_dzienne
    ADD CONSTRAINT test_awaria CHECK (liczba_emisji < 0) NOT VALID;

DELETE FROM rozliczenie_dzienne WHERE dzien = current_date - 1;   -- zeby krok 3 mial co liczyc

CALL zadanie_dobowe();
-- oczekiwany blad: zadanie_dobowe: 1 krok(i) z bledem, szczegoly w dziennik_zadan

SELECT wpis_id, krok, status, wiersze, komunikat
FROM dziennik_zadan
ORDER BY wpis_id DESC
LIMIT 3;
-- oczekiwane: kroki 1 i 2 OK, krok 3 BLAD z komunikatem o naruszeniu "test_awaria".
-- wpisy sa w dzienniku, mimo ze procedura zakonczyla sie bledem - kazdy byl zatwierdzony osobno

-- test 10: naprawa i ponowne uruchomienie - nadrabia wczorajszy dzien
ALTER TABLE rozliczenie_dzienne DROP CONSTRAINT test_awaria;

CALL zadanie_dobowe();

SELECT wpis_id, krok, status, wiersze, komunikat
FROM dziennik_zadan
ORDER BY wpis_id DESC
LIMIT 1;
-- oczekiwane: rozliczenie partnerow OK, wiersze = 6


-- ===================== 4. uruchomienie przez pg_cron =====================

-- test 11: zadanie w harmonogramie
SELECT jobid, jobname, schedule, command, active FROM cron.job;

-- test 12: tymczasowo co minute, zeby zobaczyc uruchomienie przez pg_cron
SELECT cron.schedule('zadanie_dobowe', '* * * * *', 'CALL streamos.zadanie_dobowe()');

-- odczekaj ok. 1-2 minuty, potem:
SELECT jobid, runid, status, return_message, start_time, end_time
FROM cron.job_run_details
ORDER BY start_time DESC
LIMIT 5;
-- oczekiwane: status succeeded, return_message CALL

SELECT wpis_id, krok, status, wiersze, start
FROM dziennik_zadan
ORDER BY wpis_id DESC
LIMIT 3;
-- oczekiwane: nowe wpisy z czasem zgodnym z start_time z cron.job_run_details

-- test 13: przywrocenie harmonogramu dobowego (00:15)
SELECT cron.schedule('zadanie_dobowe', '15 0 * * *', 'CALL streamos.zadanie_dobowe()');
SELECT jobid, jobname, schedule FROM cron.job;
-- oczekiwane: jedno zadanie, schedule = 15 0 * * *
