-- StreamOS - etap 2, pkt 10, czesc 2: testy wyzwalaczy w SQL Server
-- czesc A = testy z 09b (wyzwalacz emisji), czesc B = testy 1-11 z 10b (wyzwalacz sesji, CHECK)
-- numery testow takie same jak w PostgreSQL
--
-- JAK URUCHAMIAC: bloki z DECLARE - zaznacz caly blok do GO i Ctrl+Enter, reszta - Ctrl+Enter.
-- tabele tymczasowe #test_id / #test_sesje zyja do konca polaczenia (odpowiednik TEMP VIEW),
-- wiec wszystko w jednym edytorze DBeavera.
-- SYSDATETIMEOFFSET() = now() w PostgreSQL

USE streamos;
GO


-- =====================================================================
-- CZESC A: wyzwalacz emisji (09b)
-- =====================================================================

-- ===== przygotowanie =====

-- konto z profilem doroslym (zaznacz blok, Ctrl+Enter)
DECLARE @id INT;
EXEC streamos.dodaj_konto 'trigger@streamos.test', 1, 'Dorosly', @id OUTPUT;
GO

-- profil dzieciecy 7+ i dwa telewizory
INSERT INTO streamos.profil (konto_id, nazwa, czy_dzieciecy, kategoria_wiekowa_id)
SELECT konto_id, 'Dziecko', 1, (SELECT kategoria_wiekowa_id FROM streamos.kategoria_wiekowa WHERE minimalny_wiek = 7)
FROM streamos.konto WHERE email = 'trigger@streamos.test';

INSERT INTO streamos.urzadzenie (numer_seryjny, partner_id, konto_id)
SELECT v.sn, 1, k.konto_id
FROM streamos.konto k
CROSS JOIN (VALUES ('TEST-SN-E01'), ('TEST-SN-E02')) AS v(sn)
WHERE k.email = 'trigger@streamos.test';
GO

-- trzy sesje na E01: dziecko/0+, dorosly/18+, dorosly/0+ (bajka)
-- (przechodza przez wyzwalacz sesji - wszystkie sa poprawne)
INSERT INTO streamos.sesja_ogladania (profil_id, urzadzenie_id, tresc_id, czas_start)
SELECT p.profil_id, u.urzadzenie_id,
       (SELECT MIN(t.tresc_id) FROM streamos.tresc t
        JOIN streamos.kategoria_wiekowa kw ON kw.kategoria_wiekowa_id = t.kategoria_wiekowa_id
        WHERE kw.minimalny_wiek = w.wiek),
       SYSDATETIMEOFFSET()
FROM streamos.profil p
JOIN streamos.konto k ON k.konto_id = p.konto_id
JOIN (VALUES ('Dziecko', 0), ('Dorosly', 18), ('Dorosly', 0)) AS w(profil, wiek) ON w.profil = p.nazwa
CROSS JOIN streamos.urzadzenie u
WHERE k.email = 'trigger@streamos.test' AND u.numer_seryjny = 'TEST-SN-E01';
GO

-- trzy kampanie: spozywcza (budzet na 4 emisje, limit 3), alkohol, przyszla (za 10 dni)
-- (zaznacz blok, Ctrl+Enter)
DECLARE @r streamos.lista_id, @g streamos.lista_id, @id INT;
DECLARE @dzis DATE = CAST(GETDATE() AS DATE);
DECLARE @za10 DATE = DATEADD(DAY, 10, @dzis), @za30 DATE = DATEADD(DAY, 30, @dzis);
INSERT INTO @r VALUES (1); INSERT INTO @g VALUES (1);
EXEC streamos.dodaj_kampanie 1, 'TEST trg spozywcza', 0.20, 0.05, @dzis, @za30, 3, @r, @g, @id OUTPUT;
EXEC streamos.dodaj_kampanie 2, 'TEST trg alkohol',   100,  0.05, @dzis, @za30, 3, @r, @g, @id OUTPUT;
EXEC streamos.dodaj_kampanie 1, 'TEST trg przyszla',  100,  0.05, @za10, @za30, 3, @r, @g, @id OUTPUT;
GO

-- kontrola branz
SELECT k.nazwa, r.nazwa AS reklamodawca, kb.nazwa AS branza, kb.dozwolona_dla_dzieci
FROM streamos.kampania k
JOIN streamos.reklamodawca r        ON r.reklamodawca_id = k.reklamodawca_id
JOIN streamos.kategoria_branzowa kb ON kb.kategoria_branzowa_id = r.kategoria_branzowa_id
WHERE k.nazwa LIKE 'TEST trg%';
-- oczekiwane: spozywcza i przyszla -> 1, alkohol -> 0
GO

-- tabela tymczasowa z id danych testowych (odpowiednik TEMP VIEW test_id)
DROP TABLE IF EXISTS #test_id;
SELECT (SELECT kampania_id FROM streamos.kampania WHERE nazwa = 'TEST trg spozywcza') AS k_spoz,
       (SELECT kampania_id FROM streamos.kampania WHERE nazwa = 'TEST trg alkohol')   AS k_alko,
       (SELECT kampania_id FROM streamos.kampania WHERE nazwa = 'TEST trg przyszla')  AS k_przysz,
       (SELECT urzadzenie_id FROM streamos.urzadzenie WHERE numer_seryjny = 'TEST-SN-E01') AS tv,
       (SELECT urzadzenie_id FROM streamos.urzadzenie WHERE numer_seryjny = 'TEST-SN-E02') AS tv2,
       (SELECT s.sesja_id FROM streamos.sesja_ogladania s
        JOIN streamos.profil p ON p.profil_id = s.profil_id
        JOIN streamos.urzadzenie u ON u.urzadzenie_id = s.urzadzenie_id
        WHERE u.numer_seryjny = 'TEST-SN-E01' AND p.czy_dzieciecy = 1) AS s_dziecko,
       (SELECT s.sesja_id FROM streamos.sesja_ogladania s
        JOIN streamos.profil p ON p.profil_id = s.profil_id
        JOIN streamos.urzadzenie u ON u.urzadzenie_id = s.urzadzenie_id
        JOIN streamos.tresc t ON t.tresc_id = s.tresc_id
        JOIN streamos.kategoria_wiekowa kw ON kw.kategoria_wiekowa_id = t.kategoria_wiekowa_id
        WHERE u.numer_seryjny = 'TEST-SN-E01' AND p.czy_dzieciecy = 0 AND kw.minimalny_wiek = 18) AS s_dorosly,
       (SELECT s.sesja_id FROM streamos.sesja_ogladania s
        JOIN streamos.profil p ON p.profil_id = s.profil_id
        JOIN streamos.urzadzenie u ON u.urzadzenie_id = s.urzadzenie_id
        JOIN streamos.tresc t ON t.tresc_id = s.tresc_id
        JOIN streamos.kategoria_wiekowa kw ON kw.kategoria_wiekowa_id = t.kategoria_wiekowa_id
        WHERE u.numer_seryjny = 'TEST-SN-E01' AND p.czy_dzieciecy = 0 AND kw.minimalny_wiek = 0) AS s_bajka
INTO #test_id;
GO

SELECT * FROM #test_id;
-- oczekiwane: wszystkie kolumny wypelnione
GO


-- ===== 1. koszt ze stawki kampanii =====

-- test 1: INSERT bez kolumny koszt -> wyzwalacz ja uzupelnia
INSERT INTO streamos.emisja_reklamy (kampania_id, urzadzenie_id, czas_emisji)
SELECT k_spoz, tv, SYSDATETIMEOFFSET() FROM #test_id;
GO

-- test 2: falszywy koszt 999 -> nadpisany stawka
INSERT INTO streamos.emisja_reklamy (kampania_id, urzadzenie_id, czas_emisji, koszt)
SELECT k_spoz, tv, SYSDATETIMEOFFSET(), 999 FROM #test_id;
GO

SELECT e.emisja_id, e.czas_emisji, e.koszt
FROM streamos.emisja_reklamy e JOIN #test_id t ON e.kampania_id = t.k_spoz
ORDER BY e.emisja_id;
-- oczekiwane: 2 wiersze, oba 0.0500
GO


-- ===== 2. limit dzienny =====

-- test 3: dwie emisje w JEDNYM poleceniu, gdy sa juz 2 -> blad, nie zostaje zadna z dwoch
INSERT INTO streamos.emisja_reklamy (kampania_id, urzadzenie_id, czas_emisji)
SELECT k_spoz, tv, SYSDATETIMEOFFSET() FROM #test_id CROSS JOIN (VALUES (1), (2)) AS v(n);
-- oczekiwany blad 50107: telewizor ... osiagnal limit 3 emisji kampanii ...
GO

SELECT COUNT(*) AS emisje_dzis FROM streamos.emisja_reklamy e JOIN #test_id t ON e.kampania_id = t.k_spoz;
-- oczekiwane: 2
GO

-- test 4: trzecia osobno -> przechodzi
INSERT INTO streamos.emisja_reklamy (kampania_id, urzadzenie_id, czas_emisji)
SELECT k_spoz, tv, SYSDATETIMEOFFSET() FROM #test_id;
GO

-- test 5: czwarta tego samego dnia -> blad
INSERT INTO streamos.emisja_reklamy (kampania_id, urzadzenie_id, czas_emisji)
SELECT k_spoz, tv, SYSDATETIMEOFFSET() FROM #test_id;
-- oczekiwany blad 50107
GO


-- ===== 3. budzet =====

-- test 6: jutro, budzet wystarcza na jeszcze jedna -> przechodzi
INSERT INTO streamos.emisja_reklamy (kampania_id, urzadzenie_id, czas_emisji)
SELECT k_spoz, tv, DATEADD(DAY, 1, SYSDATETIMEOFFSET()) FROM #test_id;
GO

SELECT k_spoz, streamos.pozostaly_budzet(k_spoz) AS pozostalo FROM #test_id;
-- oczekiwane: 0.0000
GO

-- test 7: kolejna jutro -> brak budzetu
INSERT INTO streamos.emisja_reklamy (kampania_id, urzadzenie_id, czas_emisji)
SELECT k_spoz, tv, DATEADD(DAY, 1, SYSDATETIMEOFFSET()) FROM #test_id;
-- oczekiwany blad 50108: brak budzetu w kampanii ... (zostalo 0.0000, potrzeba 0.0500)
GO


-- ===== 4. kampania aktywna w dniu emisji =====

-- test 8: kampania zaczyna sie za 10 dni
INSERT INTO streamos.emisja_reklamy (kampania_id, urzadzenie_id, czas_emisji)
SELECT k_przysz, tv, SYSDATETIMEOFFSET() FROM #test_id;
-- oczekiwany blad 50103: dzien ... jest poza okresem kampanii ...
GO

-- test 9: po dacie konca kampanii
INSERT INTO streamos.emisja_reklamy (kampania_id, urzadzenie_id, czas_emisji)
SELECT k_alko, tv, DATEADD(DAY, 31, SYSDATETIMEOFFSET()) FROM #test_id;
-- oczekiwany blad 50103
GO


-- ===== 5. branze niedozwolone dla dzieci =====

-- test 10: alkohol w sesji profilu dzieciecego
INSERT INTO streamos.emisja_reklamy (kampania_id, urzadzenie_id, sesja_id, czas_emisji)
SELECT k_alko, tv, s_dziecko, SYSDATETIMEOFFSET() FROM #test_id;
-- oczekiwany blad 50105: ... na profilu dzieciecym ...
GO

-- test 11: alkohol na profilu doroslym przy tresci 0+
INSERT INTO streamos.emisja_reklamy (kampania_id, urzadzenie_id, sesja_id, czas_emisji)
SELECT k_alko, tv, s_bajka, SYSDATETIMEOFFSET() FROM #test_id;
-- oczekiwany blad 50106: ... przy tresciach dla dzieci (sesja ..., tresc 0+)
GO

-- test 12: dorosly, tresc 18+ -> przechodzi
INSERT INTO streamos.emisja_reklamy (kampania_id, urzadzenie_id, sesja_id, czas_emisji)
SELECT k_alko, tv, s_dorosly, SYSDATETIMEOFFSET() FROM #test_id;
GO

-- test 13: ekran glowny -> przechodzi
INSERT INTO streamos.emisja_reklamy (kampania_id, urzadzenie_id, sesja_id, czas_emisji)
SELECT k_alko, tv, NULL, SYSDATETIMEOFFSET() FROM #test_id;
GO

-- test 14: zapisaly sie dokladnie emisje z testow 12 i 13
SELECT e.emisja_id, e.sesja_id, e.koszt
FROM streamos.emisja_reklamy e JOIN #test_id t ON e.kampania_id = t.k_alko
ORDER BY e.emisja_id;
-- oczekiwane: 2 wiersze - sesja doroslego i NULL
GO


-- ===== 6. emisja na telewizorze sesji =====

-- test 15: sesja na E01, emisja na E02
INSERT INTO streamos.emisja_reklamy (kampania_id, urzadzenie_id, sesja_id, czas_emisji)
SELECT k_alko, tv2, s_dorosly, SYSDATETIMEOFFSET() FROM #test_id;
-- oczekiwany blad 50104: sesja ... trwa na telewizorze ..., a emisja wskazuje telewizor ...
GO


-- ===== 7. status kampanii =====

-- test 16: kampania zakonczona recznie
UPDATE streamos.kampania SET status = 'zakonczona' WHERE nazwa = 'TEST trg alkohol';
GO

INSERT INTO streamos.emisja_reklamy (kampania_id, urzadzenie_id, czas_emisji)
SELECT k_alko, tv, SYSDATETIMEOFFSET() FROM #test_id;
-- oczekiwany blad 50102: kampania ... ma status zakonczona
GO


-- ===== sprzatanie czesci A =====
DELETE FROM streamos.emisja_reklamy   WHERE kampania_id IN (SELECT kampania_id FROM streamos.kampania WHERE nazwa LIKE 'TEST trg%');
DELETE FROM streamos.sesja_ogladania  WHERE urzadzenie_id IN (SELECT urzadzenie_id FROM streamos.urzadzenie WHERE numer_seryjny LIKE 'TEST-SN-E%');
DELETE FROM streamos.kampania_region  WHERE kampania_id IN (SELECT kampania_id FROM streamos.kampania WHERE nazwa LIKE 'TEST trg%');
DELETE FROM streamos.kampania_gatunek WHERE kampania_id IN (SELECT kampania_id FROM streamos.kampania WHERE nazwa LIKE 'TEST trg%');
DELETE FROM streamos.kampania         WHERE nazwa LIKE 'TEST trg%';
DELETE FROM streamos.urzadzenie       WHERE numer_seryjny LIKE 'TEST-SN-E%';
DELETE FROM streamos.profil           WHERE konto_id IN (SELECT konto_id FROM streamos.konto WHERE email = 'trigger@streamos.test');
DELETE FROM streamos.konto            WHERE email = 'trigger@streamos.test';
DROP TABLE IF EXISTS #test_id;
GO


-- =====================================================================
-- CZESC B: wyzwalacz sesji i CHECK (10b, testy 1-11)
-- =====================================================================

-- ===== przygotowanie =====

-- konta A i B (zaznacz blok, Ctrl+Enter)
DECLARE @id INT;
EXEC streamos.dodaj_konto 'sesja.a@streamos.test', 1, 'Dorosly A', @id OUTPUT;
EXEC streamos.dodaj_konto 'sesja.b@streamos.test', 1, 'Dorosly B', @id OUTPUT;
GO

INSERT INTO streamos.profil (konto_id, nazwa, czy_dzieciecy, kategoria_wiekowa_id)
SELECT konto_id, 'Dziecko A', 1, (SELECT kategoria_wiekowa_id FROM streamos.kategoria_wiekowa WHERE minimalny_wiek = 7)
FROM streamos.konto WHERE email = 'sesja.a@streamos.test';

INSERT INTO streamos.urzadzenie (numer_seryjny, partner_id, konto_id) VALUES
 ('TEST-SN-S0A', 1, (SELECT konto_id FROM streamos.konto WHERE email = 'sesja.a@streamos.test')),
 ('TEST-SN-S0B', 1, (SELECT konto_id FROM streamos.konto WHERE email = 'sesja.b@streamos.test')),
 ('TEST-SN-S0N', 1, NULL);
GO

DROP TABLE IF EXISTS #test_sesje;
SELECT (SELECT profil_id FROM streamos.profil WHERE nazwa = 'Dorosly A') AS p_dorosly,
       (SELECT profil_id FROM streamos.profil WHERE nazwa = 'Dziecko A')  AS p_dziecko,
       (SELECT urzadzenie_id FROM streamos.urzadzenie WHERE numer_seryjny = 'TEST-SN-S0A') AS tv_a,
       (SELECT urzadzenie_id FROM streamos.urzadzenie WHERE numer_seryjny = 'TEST-SN-S0B') AS tv_b,
       (SELECT urzadzenie_id FROM streamos.urzadzenie WHERE numer_seryjny = 'TEST-SN-S0N') AS tv_n,
       (SELECT MIN(t.tresc_id) FROM streamos.tresc t JOIN streamos.kategoria_wiekowa kw ON kw.kategoria_wiekowa_id = t.kategoria_wiekowa_id WHERE kw.minimalny_wiek = 7)  AS t_7,
       (SELECT MIN(t.tresc_id) FROM streamos.tresc t JOIN streamos.kategoria_wiekowa kw ON kw.kategoria_wiekowa_id = t.kategoria_wiekowa_id WHERE kw.minimalny_wiek = 12) AS t_12,
       (SELECT MIN(t.tresc_id) FROM streamos.tresc t JOIN streamos.kategoria_wiekowa kw ON kw.kategoria_wiekowa_id = t.kategoria_wiekowa_id WHERE kw.minimalny_wiek = 18) AS t_18
INTO #test_sesje;
GO

SELECT * FROM #test_sesje;
GO


-- ===== wyzwalacz sesji =====

-- test 1: dorosly, telewizor swojego konta, 18+ -> przechodzi
INSERT INTO streamos.sesja_ogladania (profil_id, urzadzenie_id, tresc_id, czas_start)
SELECT p_dorosly, tv_a, t_18, SYSDATETIMEOFFSET() FROM #test_sesje;
GO

-- test 2: dziecko 7+, tresc 7+ -> przechodzi
INSERT INTO streamos.sesja_ogladania (profil_id, urzadzenie_id, tresc_id, czas_start)
SELECT p_dziecko, tv_a, t_7, SYSDATETIMEOFFSET() FROM #test_sesje;
GO

-- test 3: dziecko 7+, tresc 12+
INSERT INTO streamos.sesja_ogladania (profil_id, urzadzenie_id, tresc_id, czas_start)
SELECT p_dziecko, tv_a, t_12, SYSDATETIMEOFFSET() FROM #test_sesje;
-- oczekiwany blad 50202: profil dzieciecy ... ma limit 7+, a tresc ... jest 12+
GO

-- test 4: profil z konta A na telewizorze konta B
INSERT INTO streamos.sesja_ogladania (profil_id, urzadzenie_id, tresc_id, czas_start)
SELECT p_dorosly, tv_b, t_18, SYSDATETIMEOFFSET() FROM #test_sesje;
-- oczekiwany blad 50201: ... nie naleza do tego samego konta
GO

-- test 5: telewizor nieaktywowany
INSERT INTO streamos.sesja_ogladania (profil_id, urzadzenie_id, tresc_id, czas_start)
SELECT p_dorosly, tv_n, t_18, SYSDATETIMEOFFSET() FROM #test_sesje;
-- oczekiwany blad 50201: ... (konto NULL) nie naleza do tego samego konta
GO

-- test 6: zmiana tresci w sesji dziecka na 18+ (wyzwalacz dziala tez przy UPDATE)
UPDATE streamos.sesja_ogladania
SET tresc_id = (SELECT t_18 FROM #test_sesje)
WHERE profil_id = (SELECT p_dziecko FROM #test_sesje);
-- oczekiwany blad 50202
GO

-- test 7: zakonczenie sesji -> UPDATE(...) falszywe, wyzwalacz konczy sie od razu, przechodzi
UPDATE streamos.sesja_ogladania
SET czas_koniec = DATEADD(HOUR, 1, SYSDATETIMEOFFSET())
WHERE profil_id = (SELECT p_dziecko FROM #test_sesje);
GO

SELECT s.sesja_id, p.nazwa AS profil, s.tresc_id, s.czas_start, s.czas_koniec
FROM streamos.sesja_ogladania s
JOIN streamos.profil p ON p.profil_id = s.profil_id
WHERE s.urzadzenie_id = (SELECT tv_a FROM #test_sesje)
ORDER BY s.sesja_id;
-- oczekiwane: 2 sesje, sesja dziecka z tresc 7+ i ustawionym czas_koniec
GO


-- ===== CHECK (przeniesione w 12b) =====

-- test 8: sesja konczy sie przed startem
INSERT INTO streamos.sesja_ogladania (profil_id, urzadzenie_id, tresc_id, czas_start, czas_koniec)
SELECT p_dorosly, tv_a, t_18, SYSDATETIMEOFFSET(), DATEADD(HOUR, -1, SYSDATETIMEOFFSET()) FROM #test_sesje;
-- oczekiwany blad 547: ... conflicted with the CHECK constraint "sesja_czas_check"
GO

-- test 9: profil dzieciecy bez limitu
INSERT INTO streamos.profil (konto_id, nazwa, czy_dzieciecy, kategoria_wiekowa_id)
SELECT konto_id, 'TEST dziecko bez limitu', 1, NULL FROM streamos.konto WHERE email = 'sesja.a@streamos.test';
-- oczekiwany blad 547: ... "profil_dzieciecy_check"
GO

-- test 10: profil dorosly z limitem
INSERT INTO streamos.profil (konto_id, nazwa, czy_dzieciecy, kategoria_wiekowa_id)
SELECT konto_id, 'TEST dorosly z limitem', 0, 1 FROM streamos.konto WHERE email = 'sesja.a@streamos.test';
-- oczekiwany blad 547: ... "profil_dzieciecy_check"
GO

-- test 11: kampania zwyklym INSERT-em, koniec przed startem
INSERT INTO streamos.kampania (reklamodawca_id, nazwa, budzet, stawka, data_od, data_do, status)
VALUES (1, 'TEST zle daty', 1000, 0.05, DATEADD(DAY, 30, CAST(GETDATE() AS DATE)), CAST(GETDATE() AS DATE), 'aktywna');
-- oczekiwany blad 547: ... "kampania_daty_check"
GO


-- ===== sprzatanie czesci B =====
DELETE FROM streamos.sesja_ogladania WHERE urzadzenie_id IN (SELECT urzadzenie_id FROM streamos.urzadzenie WHERE numer_seryjny LIKE 'TEST-SN-S0%');
DELETE FROM streamos.urzadzenie      WHERE numer_seryjny LIKE 'TEST-SN-S0%';
DELETE FROM streamos.profil          WHERE konto_id IN (SELECT konto_id FROM streamos.konto WHERE email LIKE 'sesja.%@streamos.test');
DELETE FROM streamos.konto           WHERE email LIKE 'sesja.%@streamos.test';
DROP TABLE IF EXISTS #test_sesje;
GO
