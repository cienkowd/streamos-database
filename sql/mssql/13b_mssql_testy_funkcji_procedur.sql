-- StreamOS - etap 2, pkt 10, czesc 1: testy funkcji i procedur w SQL Server
-- odpowiedniki testow z 07b, 08b i 10b (funkcja rozliczenie_partnerow) - te same numery
-- testow, zeby wyniki dalo sie zestawic obok siebie
--
-- JAK URUCHAMIAC: kazdy test to paczka zakonczona GO.
-- zmienne T-SQL (DECLARE @...) istnieja tylko w obrebie jednej paczki, wiec test z DECLARE
-- trzeba uruchomic w calosci: ZAZNACZ caly blok testu i Ctrl+Enter.
-- (DBeaver dzieli skrypt na polecenia po srednikach - bez zaznaczenia DECLARE wykonalby
--  sie osobno, a nastepne polecenie nie widzialoby zmiennej)
-- Auto-Commit wlaczony (poza testem transakcji, patrz opis)

USE streamos;
GO


-- ===================== pozostaly_budzet (07b, testy 1-3) =====================

-- test 1: funkcja zgadza sie z recznym wyliczeniem - porownac z wynikiem w PostgreSQL
SELECT k.kampania_id, k.budzet,
       COALESCE(SUM(e.koszt), 0)            AS wydano,
       k.budzet - COALESCE(SUM(e.koszt), 0) AS recznie,
       streamos.pozostaly_budzet(k.kampania_id) AS funkcja
FROM streamos.kampania k
LEFT JOIN streamos.emisja_reklamy e ON e.kampania_id = k.kampania_id
WHERE k.kampania_id IN (1, 2, 50)
GROUP BY k.kampania_id, k.budzet
ORDER BY k.kampania_id;
-- funkcje skalarna w T-SQL wywoluje sie ZAWSZE z nazwa schematu (streamos.pozostaly_budzet)
GO

-- test 3: nieistniejaca kampania -> NULL
SELECT streamos.pozostaly_budzet(-1) AS pozostalo;
GO

-- test 4: 5 aktywnych kampanii z najmniejszym zapasem budzetu - porownac z PostgreSQL
-- TOP 5 = odpowiednik LIMIT 5
SELECT TOP 5 kampania_id, nazwa, budzet, streamos.pozostaly_budzet(kampania_id) AS pozostalo
FROM streamos.kampania
WHERE status = 'aktywna'
ORDER BY pozostalo;
GO


-- ===================== rozliczenie_partnerow (10b, testy 12-15) =====================

-- test 12: poprzedni miesiac (NULL zamiast pominietego parametru) - porownac z PostgreSQL
SELECT * FROM streamos.rozliczenie_partnerow(NULL) ORDER BY przychod_z_reklam DESC, partner;
GO

-- test 13: wybrany miesiac
SELECT * FROM streamos.rozliczenie_partnerow('2026-09-01') ORDER BY przychod_z_reklam DESC, partner;
GO

-- test 14: miesiac bez emisji -> wszyscy partnerzy z zerami
SELECT * FROM streamos.rozliczenie_partnerow('2030-01-01') ORDER BY partner;
GO

-- test 15: funkcja jak tabela
SELECT SUM(nalezne_partnerowi) AS do_wyplaty_razem FROM streamos.rozliczenie_partnerow(NULL);
GO


-- ===================== dodaj_konto (07b, testy 5-9) =====================

-- test 5: poprawne dodanie -> zwraca id nowego konta (zaznacz blok, Ctrl+Enter)
DECLARE @id INT;
EXEC streamos.dodaj_konto
     @p_email = '  Jan.Testowy@STREAMOS.test ', @p_region_id = 1,
     @p_nazwa_profilu = 'Jan', @p_konto_id = @id OUTPUT;
SELECT @id AS nowe_konto_id;
GO

-- test 6: powstalo konto i profil dorosly
SELECT k.konto_id, k.email, k.region_id, p.profil_id, p.nazwa, p.czy_dzieciecy, p.kategoria_wiekowa_id
FROM streamos.konto k
JOIN streamos.profil p ON p.konto_id = k.konto_id
WHERE k.email = 'jan.testowy@streamos.test';
-- oczekiwane: 1 wiersz, email bez spacji i malymi literami, czy_dzieciecy = 0
GO

-- test 7: ten sam email innymi literami -> blad (zaznacz blok, Ctrl+Enter)
DECLARE @id INT;
EXEC streamos.dodaj_konto 'JAN.TESTOWY@streamos.test', 1, 'Jan 2', @id OUTPUT;
-- oczekiwany blad 2627: Violation of UNIQUE KEY constraint 'konto_email_key'
GO

-- test 8: blad przy profilu -> konto tez nie powstaje (atomowosc, zaznacz blok, Ctrl+Enter)
DECLARE @id INT;
EXEC streamos.dodaj_konto 'bez.profilu@streamos.test', 1, NULL, @id OUTPUT;
-- oczekiwany blad 515: Cannot insert the value NULL into column 'nazwa', table 'streamos.streamos.profil'
GO

SELECT COUNT(*) AS konta FROM streamos.konto WHERE email = 'bez.profilu@streamos.test';
-- oczekiwane: 0 - INSERT konta zostal wycofany razem z nieudanym profilem
GO

-- test 9: nieistniejacy region -> blad klucza obcego (zaznacz blok, Ctrl+Enter)
DECLARE @id INT;
EXEC streamos.dodaj_konto 'zly.region@streamos.test', 999999, 'Ala', @id OUTPUT;
-- oczekiwany blad 547: ... conflicted with the FOREIGN KEY constraint "konto_region_id_fkey"
GO


-- ===================== aktywuj_urzadzenie (07b, testy 10-13) =====================

INSERT INTO streamos.urzadzenie (numer_seryjny, partner_id)
VALUES ('TEST-SN-0001', 1), ('TEST-SN-0002', 1);
GO

-- test 10: aktywacja
EXEC streamos.aktywuj_urzadzenie 'TEST-SN-0001', 1;
GO

SELECT numer_seryjny, konto_id FROM streamos.urzadzenie WHERE numer_seryjny LIKE 'TEST-SN-%' ORDER BY numer_seryjny;
-- oczekiwane: 0001 -> konto 1, 0002 -> NULL
GO

-- test 11: ponowna aktywacja -> blad
EXEC streamos.aktywuj_urzadzenie 'TEST-SN-0001', 2;
-- oczekiwany blad 50001: Urzadzenie TEST-SN-0001 jest juz aktywowane
GO

-- test 12: nieistniejacy numer seryjny -> blad
EXEC streamos.aktywuj_urzadzenie 'NIE-MA-TAKIEGO', 1;
-- oczekiwany blad 50001: Nie ma urzadzenia o numerze NIE-MA-TAKIEGO
GO

-- test 13: nieistniejace konto -> blad klucza obcego, telewizor zostaje nieaktywny
EXEC streamos.aktywuj_urzadzenie 'TEST-SN-0002', 999999;
-- oczekiwany blad 547: ... "urzadzenie_konto_id_fkey"
GO

SELECT numer_seryjny, konto_id FROM streamos.urzadzenie WHERE numer_seryjny = 'TEST-SN-0002';
-- oczekiwane: konto_id = NULL
GO


-- ===================== dodaj_kampanie (08b) =====================

-- stan wyjsciowy; IDENT_CURRENT = ostatnia wartosc IDENTITY (odpowiednik last_value sekwencji)
SELECT (SELECT COUNT(*) FROM streamos.kampania)         AS kampanie,
       (SELECT COUNT(*) FROM streamos.kampania_region)  AS kampania_region,
       (SELECT COUNT(*) FROM streamos.kampania_gatunek) AS kampania_gatunek,
       IDENT_CURRENT('streamos.kampania')               AS identity_kampania;
GO

-- test 1: kampania z 3 regionami i 2 gatunkami (gatunek 2 dwa razy) - zaznacz blok, Ctrl+Enter
-- listy: zmienna typu lista_id wypelniona INSERT-em (odpowiednik ARRAY[1, 7, 12])
DECLARE @regiony streamos.lista_id, @gatunki streamos.lista_id, @id INT;
DECLARE @od DATE = DATEADD(DAY, 1, CAST(GETDATE() AS DATE)),
        @do DATE = DATEADD(DAY, 60, CAST(GETDATE() AS DATE));
INSERT INTO @regiony VALUES (1), (7), (12);
INSERT INTO @gatunki VALUES (2), (2), (9);
EXEC streamos.dodaj_kampanie
     @p_reklamodawca_id = 2, @p_nazwa = 'TEST Zimowa promocja',
     @p_budzet = 5000.00, @p_stawka = 0.0450,
     @p_data_od = @od, @p_data_do = @do, @p_limit_dzienny = 3,
     @p_regiony = @regiony, @p_gatunki = @gatunki, @p_kampania_id = @id OUTPUT;
SELECT @id AS nowa_kampania_id;
-- oczekiwane: id kampanii, w Output: Dodano kampanie ...
-- (parametry EXEC nie moga byc wyrazeniami, np. DATEADD(...) - stad zmienne @od i @do)
GO

-- test 2: zapis we wszystkich trzech tabelach
-- STRING_AGG(...) WITHIN GROUP (ORDER BY ...) = odpowiednik string_agg(... ORDER BY ...)
SELECT k.kampania_id, k.nazwa, k.status, k.limit_dzienny,
       (SELECT STRING_AGG(r.nazwa, ', ') WITHIN GROUP (ORDER BY r.nazwa)
        FROM streamos.kampania_region kr JOIN streamos.region r ON r.region_id = kr.region_id
        WHERE kr.kampania_id = k.kampania_id) AS regiony,
       (SELECT STRING_AGG(g.nazwa, ', ') WITHIN GROUP (ORDER BY g.nazwa)
        FROM streamos.kampania_gatunek kg JOIN streamos.gatunek g ON g.gatunek_id = kg.gatunek_id
        WHERE kg.kampania_id = k.kampania_id) AS gatunki
FROM streamos.kampania k
WHERE k.nazwa = 'TEST Zimowa promocja';
-- oczekiwane: aktywna, limit 3, regiony: Dolnoslaskie, Mazowieckie, Slaskie; gatunki: Dramat, Sport
GO

-- test 3: nowa kampania dziala z funkcja
SELECT kampania_id, budzet, streamos.pozostaly_budzet(kampania_id) AS pozostalo
FROM streamos.kampania WHERE nazwa = 'TEST Zimowa promocja';
-- oczekiwane: 5000.0000
GO

-- test 4: daty w zlej kolejnosci (zaznacz blok, Ctrl+Enter)
DECLARE @r streamos.lista_id, @g streamos.lista_id, @id INT;
DECLARE @od DATE = DATEADD(DAY, 30, CAST(GETDATE() AS DATE)), @do DATE = DATEADD(DAY, 1, CAST(GETDATE() AS DATE));
INSERT INTO @r VALUES (1); INSERT INTO @g VALUES (1);
EXEC streamos.dodaj_kampanie 2, 'TEST zle daty', 1000, 0.05, @od, @do, 3, @r, @g, @id OUTPUT;
-- oczekiwany blad 50002: data_od (...) jest pozniejsza niz data_do (...)
GO

-- test 5: start w przeszlosci (zaznacz blok, Ctrl+Enter)
DECLARE @r streamos.lista_id, @g streamos.lista_id, @id INT;
DECLARE @od DATE = DATEADD(DAY, -1, CAST(GETDATE() AS DATE)), @do DATE = DATEADD(DAY, 30, CAST(GETDATE() AS DATE));
INSERT INTO @r VALUES (1); INSERT INTO @g VALUES (1);
EXEC streamos.dodaj_kampanie 2, 'TEST przeszlosc', 1000, 0.05, @od, @do, 3, @r, @g, @id OUTPUT;
-- oczekiwany blad 50003: kampania nie moze zaczynac sie w przeszlosci
GO

-- test 6: limit dzienny 0 (zaznacz blok, Ctrl+Enter)
DECLARE @r streamos.lista_id, @g streamos.lista_id, @id INT;
DECLARE @od DATE = DATEADD(DAY, 1, CAST(GETDATE() AS DATE)), @do DATE = DATEADD(DAY, 30, CAST(GETDATE() AS DATE));
INSERT INTO @r VALUES (1); INSERT INTO @g VALUES (1);
EXEC streamos.dodaj_kampanie 2, 'TEST zerowy limit', 1000, 0.05, @od, @do, 0, @r, @g, @id OUTPUT;
-- oczekiwany blad 50004: limit dzienny musi byc co najmniej 1
GO

-- test 7: pusta lista regionow (zaznacz blok, Ctrl+Enter)
DECLARE @r streamos.lista_id, @g streamos.lista_id, @id INT;
DECLARE @od DATE = DATEADD(DAY, 1, CAST(GETDATE() AS DATE)), @do DATE = DATEADD(DAY, 30, CAST(GETDATE() AS DATE));
INSERT INTO @g VALUES (1);
EXEC streamos.dodaj_kampanie 2, 'TEST bez regionow', 1000, 0.05, @od, @do, 3, @r, @g, @id OUTPUT;
-- oczekiwany blad 50005: lista regionow nie moze byc pusta ani zawierac NULL
GO

-- test 8: NULL na liscie gatunkow (zaznacz blok, Ctrl+Enter)
DECLARE @r streamos.lista_id, @g streamos.lista_id, @id INT;
DECLARE @od DATE = DATEADD(DAY, 1, CAST(GETDATE() AS DATE)), @do DATE = DATEADD(DAY, 30, CAST(GETDATE() AS DATE));
INSERT INTO @r VALUES (1); INSERT INTO @g VALUES (1), (NULL);
EXEC streamos.dodaj_kampanie 2, 'TEST NULL w gatunkach', 1000, 0.05, @od, @do, 3, @r, @g, @id OUTPUT;
-- oczekiwany blad 50006: lista gatunkow nie moze byc pusta ani zawierac NULL
GO

-- test 9: nieistniejacy reklamodawca (zaznacz blok, Ctrl+Enter)
DECLARE @r streamos.lista_id, @g streamos.lista_id, @id INT;
DECLARE @od DATE = DATEADD(DAY, 1, CAST(GETDATE() AS DATE)), @do DATE = DATEADD(DAY, 30, CAST(GETDATE() AS DATE));
INSERT INTO @r VALUES (1); INSERT INTO @g VALUES (1);
EXEC streamos.dodaj_kampanie 999, 'TEST zly reklamodawca', 1000, 0.05, @od, @do, 3, @r, @g, @id OUTPUT;
-- oczekiwany blad 50010: dodaj_kampanie: nie istnieje reklamodawca o id 999
GO

-- test 10: budzet 0 (zaznacz blok, Ctrl+Enter)
DECLARE @r streamos.lista_id, @g streamos.lista_id, @id INT;
DECLARE @od DATE = DATEADD(DAY, 1, CAST(GETDATE() AS DATE)), @do DATE = DATEADD(DAY, 30, CAST(GETDATE() AS DATE));
INSERT INTO @r VALUES (1); INSERT INTO @g VALUES (1);
EXEC streamos.dodaj_kampanie 2, 'TEST zerowy budzet', 0, 0.05, @od, @do, 3, @r, @g, @id OUTPUT;
-- oczekiwany blad 50010: dodaj_kampanie: budzet musi byc wiekszy od 0
GO

-- test 11: TRANSAKCJA - kampania i 2 regiony zapisuja sie, dopiero gatunek 999 nie istnieje
-- (zaznacz blok, Ctrl+Enter)
DECLARE @r streamos.lista_id, @g streamos.lista_id, @id INT;
DECLARE @od DATE = DATEADD(DAY, 1, CAST(GETDATE() AS DATE)), @do DATE = DATEADD(DAY, 30, CAST(GETDATE() AS DATE));
INSERT INTO @r VALUES (3), (4); INSERT INTO @g VALUES (1), (999);
EXEC streamos.dodaj_kampanie 2, 'TEST wycofanie', 1000, 0.05, @od, @do, 3, @r, @g, @id OUTPUT;
-- oczekiwany blad 50010: dodaj_kampanie: na liscie gatunkow jest nieistniejacy gatunek
GO

-- test 12: dowod wycofania
SELECT (SELECT COUNT(*) FROM streamos.kampania WHERE nazwa = 'TEST wycofanie') AS kampania_testowa,
       (SELECT COUNT(*) FROM streamos.kampania)         AS kampanie,
       (SELECT COUNT(*) FROM streamos.kampania_region)  AS kampania_region,
       (SELECT COUNT(*) FROM streamos.kampania_gatunek) AS kampania_gatunek,
       IDENT_CURRENT('streamos.kampania')               AS identity_kampania;
-- oczekiwane: jak w PostgreSQL - kampania_testowa = 0, liczby = stan wyjsciowy + kampania z testu 1,
-- identity_kampania = stan wyjsciowy + 4 (test 1 oraz 9, 10, 11).
-- IDENTITY, tak jak sekwencja, nie cofa sie przy ROLLBACK
GO

-- test 13: procedura w transakcji wywolujacego - poprawne wywolanie, potem ROLLBACK z zewnatrz.
-- w T-SQL nie trzeba przelaczac DBeavera: BEGIN TRAN otwiera transakcje jawnie.
-- (zaznacz blok, Ctrl+Enter)
DECLARE @r streamos.lista_id, @g streamos.lista_id, @id INT;
DECLARE @od DATE = DATEADD(DAY, 1, CAST(GETDATE() AS DATE)), @do DATE = DATEADD(DAY, 30, CAST(GETDATE() AS DATE));
INSERT INTO @r VALUES (5); INSERT INTO @g VALUES (5);
BEGIN TRANSACTION;
EXEC streamos.dodaj_kampanie 2, 'TEST rollback z zewnatrz', 1000, 0.05, @od, @do, 3, @r, @g, @id OUTPUT;
SELECT COUNT(*) AS widoczna_w_transakcji FROM streamos.kampania WHERE nazwa = 'TEST rollback z zewnatrz';
ROLLBACK;
SELECT COUNT(*) AS po_rollback FROM streamos.kampania WHERE nazwa = 'TEST rollback z zewnatrz';
-- oczekiwane: 1, potem 0. COMMIT w procedurze nie zatwierdzil niczego na stale:
-- w SQL Serverze zagniezdzony COMMIT tylko zmniejsza @@TRANCOUNT, zatwierdza dopiero zewnetrzny
GO


-- ===================== sprzatanie =====================
DELETE FROM streamos.kampania_region  WHERE kampania_id IN (SELECT kampania_id FROM streamos.kampania WHERE nazwa LIKE 'TEST%');
DELETE FROM streamos.kampania_gatunek WHERE kampania_id IN (SELECT kampania_id FROM streamos.kampania WHERE nazwa LIKE 'TEST%');
DELETE FROM streamos.kampania         WHERE nazwa LIKE 'TEST%';
DELETE FROM streamos.urzadzenie       WHERE numer_seryjny LIKE 'TEST-SN-%';
DELETE FROM streamos.profil           WHERE konto_id IN (SELECT konto_id FROM streamos.konto WHERE email LIKE '%@streamos.test');
DELETE FROM streamos.konto            WHERE email LIKE '%@streamos.test';
GO
