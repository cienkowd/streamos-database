-- StreamOS - etap 2, pkt 10, czesc 3: uzytkownicy, role i perspektywy w MS SQL Server
-- odpowiedniki: 03_uzytkownicy.sql i 05_perspektywy.sql
-- uruchamiac jako sa, baza streamos, calosc (Alt+X)
-- kolumny login_bazy z wartosciami przyszly z danymi w pkt 9, wiec ich nie dodajemy
--
-- roznice wobec PostgreSQL:
--   - dwa poziomy zamiast jednego: LOGIN (serwer - logowanie haslem) i USER (baza - uprawnienia).
--     W PostgreSQL rola z LOGIN byla jednym i drugim naraz.
--   - role grupowe sa w bazie (CREATE ROLE + ALTER ROLE ... ADD MEMBER)
--   - nowy uzytkownik bazy nie ma zadnych praw do tabel - nie trzeba REVOKE ... FROM PUBLIC
--   - CURRENT_USER zwraca nazwe uzytkownika BAZY. Uzytkownicy maja takie same nazwy
--     jak loginy z PostgreSQL, wiec warunek login_bazy = CURRENT_USER dziala bez zmian

USE streamos;
GO


-- ===== 0. reset: uzytkownicy bazy, role, loginy serwera =====
-- (najpierw uzytkownicy - usuniecie uzytkownika usuwa tez jego czlonkostwo w roli)
DROP USER IF EXISTS reklamodawca_02;
DROP USER IF EXISTS reklamodawca_03;
DROP USER IF EXISTS partner_alfa;
DROP USER IF EXISTS partner_beta;
DROP ROLE IF EXISTS rola_reklamodawca;
DROP ROLE IF EXISTS rola_partner;
IF SUSER_ID('reklamodawca_02') IS NOT NULL DROP LOGIN reklamodawca_02;
IF SUSER_ID('reklamodawca_03') IS NOT NULL DROP LOGIN reklamodawca_03;
IF SUSER_ID('partner_alfa')    IS NOT NULL DROP LOGIN partner_alfa;
IF SUSER_ID('partner_beta')    IS NOT NULL DROP LOGIN partner_beta;
GO


-- ===== 1. loginy serwera (logowanie) =====
-- DEFAULT_DATABASE: po zalogowaniu od razu baza streamos zamiast master
-- hasla jak w PostgreSQL; spelniaja wymagania zlozonosci SQL Servera (8+ znakow, 3 rodzaje)
CREATE LOGIN reklamodawca_02 WITH PASSWORD = 'Reklama02!', DEFAULT_DATABASE = streamos;
CREATE LOGIN reklamodawca_03 WITH PASSWORD = 'Reklama03!', DEFAULT_DATABASE = streamos;
CREATE LOGIN partner_alfa    WITH PASSWORD = 'PartnerA1!', DEFAULT_DATABASE = streamos;
CREATE LOGIN partner_beta    WITH PASSWORD = 'PartnerB1!', DEFAULT_DATABASE = streamos;
GO


-- ===== 2. uzytkownicy bazy (powiazani z loginami) =====
-- utworzenie uzytkownika daje prawo polaczenia z baza (CONNECT) - odpowiednik GRANT CONNECT
CREATE USER reklamodawca_02 FOR LOGIN reklamodawca_02;
CREATE USER reklamodawca_03 FOR LOGIN reklamodawca_03;
CREATE USER partner_alfa    FOR LOGIN partner_alfa;
CREATE USER partner_beta    FOR LOGIN partner_beta;
GO


-- ===== 3. role grupowe =====
CREATE ROLE rola_reklamodawca;
CREATE ROLE rola_partner;

ALTER ROLE rola_reklamodawca ADD MEMBER reklamodawca_02;
ALTER ROLE rola_reklamodawca ADD MEMBER reklamodawca_03;
ALTER ROLE rola_partner      ADD MEMBER partner_alfa;
ALTER ROLE rola_partner      ADD MEMBER partner_beta;
GO


-- ===== 4. perspektywy =====
-- brak odpowiednika WITH (security_barrier). W SQL Serverze zwykly uzytkownik nie moze
-- tworzyc wlasnych funkcji, ktorymi w PostgreSQL daloby sie podejrzec odfiltrowane wiersze,
-- wiec ten wektor nie wystepuje. Pelnym odpowiednikiem filtrowania wierszy byloby
-- Row-Level Security (CREATE SECURITY POLICY) - tu zostajemy przy warunku w perspektywie.
--
-- dlaczego uzytkownik z prawem tylko do perspektywy moze czytac tabele w jej srodku:
-- "lancuch wlascicieli" (ownership chaining) - perspektywa i tabele maja tego samego
-- wlasciciela (dbo), wiec SQL Server nie sprawdza praw do tabel, tylko do perspektywy.
-- (w PostgreSQL dzialalo podobnie: perspektywa czyta tabele z prawami swojego wlasciciela)
--
-- [od], [do] - nawiasy kwadratowe = nazwa w cudzyslowie (jak "od" w PG), na wypadek kolizji ze slowami kluczowymi
-- w perspektywie nie wolno ORDER BY - sortuje zapytanie, ktore z niej czyta


-- ===== REKLAMODAWCA =====

-- 1. podsumowanie moich kampanii
CREATE OR ALTER VIEW streamos.v_moje_kampanie AS
SELECT k.nazwa                                                   AS kampania,
       k.data_od                                                 AS [od],
       k.data_do                                                 AS [do],
       k.status,
       k.budzet,
       COUNT(e.emisja_id)                                        AS liczba_emisji,
       COALESCE(ROUND(SUM(e.koszt), 2), 0)                       AS wydano,
       COALESCE(ROUND(100 * SUM(e.koszt) / k.budzet, 1), 0)      AS proc_budzetu
FROM streamos.kampania k
JOIN streamos.reklamodawca r        ON r.reklamodawca_id = k.reklamodawca_id
LEFT JOIN streamos.emisja_reklamy e ON e.kampania_id = k.kampania_id
WHERE r.login_bazy = CURRENT_USER
GROUP BY k.kampania_id, k.nazwa, k.data_od, k.data_do, k.status, k.budzet;
GO

-- 2. moje emisje w podziale na regiony
CREATE OR ALTER VIEW streamos.v_moje_emisje_regiony AS
SELECT k.nazwa                AS kampania,
       rg.nazwa               AS region,
       COUNT(*)               AS liczba_emisji,
       ROUND(SUM(e.koszt), 2) AS koszt
FROM streamos.emisja_reklamy e
JOIN streamos.kampania k     ON k.kampania_id = e.kampania_id
JOIN streamos.reklamodawca r ON r.reklamodawca_id = k.reklamodawca_id
JOIN streamos.urzadzenie u   ON u.urzadzenie_id = e.urzadzenie_id
JOIN streamos.konto ko       ON ko.konto_id = u.konto_id
JOIN streamos.region rg      ON rg.region_id = ko.region_id
WHERE r.login_bazy = CURRENT_USER
GROUP BY k.nazwa, rg.nazwa;
GO


-- ===== PARTNER OEM =====

-- 3. miesieczny przychod z reklam na moich telewizorach
-- date_trunc('month', ...) -> DATEFROMPARTS(rok, miesiac, 1) z dnia emisji w czasie polskim
-- (CROSS APPLY liczy ten dzien raz na wiersz, zeby nie powtarzac wyrazenia w SELECT i GROUP BY)
CREATE OR ALTER VIEW streamos.v_moje_przychody AS
SELECT DATEFROMPARTS(YEAR(d.dzien), MONTH(d.dzien), 1)          AS miesiac,
       COUNT(DISTINCT e.urzadzenie_id)                          AS telewizory_z_reklamami,
       COUNT(*)                                                 AS liczba_emisji,
       ROUND(SUM(e.koszt), 2)                                   AS przychod_z_reklam,
       ROUND(SUM(e.koszt) * p.udzial_procent / 100, 2)          AS nalezne_mi
FROM streamos.emisja_reklamy e
JOIN streamos.urzadzenie u  ON u.urzadzenie_id = e.urzadzenie_id
JOIN streamos.partner_oem p ON p.partner_id = u.partner_id
CROSS APPLY (SELECT CAST(e.czas_emisji AT TIME ZONE 'Central European Standard Time' AS DATE) AS dzien) d
WHERE p.login_bazy = CURRENT_USER
GROUP BY DATEFROMPARTS(YEAR(d.dzien), MONTH(d.dzien), 1), p.udzial_procent;
GO

-- 4. ogladalnosc na moich telewizorach wedlug typu tresci
-- extract(epoch FROM koniec - start) -> DATEDIFF(SECOND, start, koniec)
-- CAST na BIGINT: suma sekund z kilkuset tysiecy sesji moze przekroczyc zakres INT
-- trwajaca sesja (czas_koniec NULL) daje NULL i SUM ja pomija - tak samo jak w PostgreSQL
CREATE OR ALTER VIEW streamos.v_moja_ogladalnosc AS
SELECT t.typ                                                                        AS typ_tresci,
       COUNT(*)                                                                     AS liczba_sesji,
       COUNT(DISTINCT s.urzadzenie_id)                                              AS telewizory,
       ROUND(SUM(CAST(DATEDIFF(SECOND, s.czas_start, s.czas_koniec) AS BIGINT)) / 3600.0, 0) AS godziny_ogladania
FROM streamos.sesja_ogladania s
JOIN streamos.urzadzenie u  ON u.urzadzenie_id = s.urzadzenie_id
JOIN streamos.partner_oem p ON p.partner_id = u.partner_id
JOIN streamos.tresc t       ON t.tresc_id = s.tresc_id
WHERE p.login_bazy = CURRENT_USER
GROUP BY t.typ;
GO


-- ===== 5. uprawnienia: kazda rola widzi tylko swoje perspektywy =====
GRANT SELECT ON streamos.v_moje_kampanie       TO rola_reklamodawca;
GRANT SELECT ON streamos.v_moje_emisje_regiony TO rola_reklamodawca;
GRANT SELECT ON streamos.v_moje_przychody      TO rola_partner;
GRANT SELECT ON streamos.v_moja_ogladalnosc    TO rola_partner;
GO


-- ===== 6. kontrola =====

-- kto ma jakie role (odpowiednik zapytania o pg_auth_members)
SELECT u.name AS uzytkownik, l.name AS login, r.name AS rola_grupowa
FROM sys.database_principals u
LEFT JOIN sys.server_principals l       ON l.sid = u.sid
LEFT JOIN sys.database_role_members m   ON m.member_principal_id = u.principal_id
LEFT JOIN sys.database_principals r     ON r.principal_id = m.role_principal_id
WHERE u.name LIKE 'reklamodawca%' OR u.name LIKE 'partner%'
ORDER BY u.name;

-- jakie prawa maja role
SELECT pr.name AS rola, pe.permission_name AS prawo, OBJECT_NAME(pe.major_id) AS obiekt
FROM sys.database_permissions pe
JOIN sys.database_principals pr ON pr.principal_id = pe.grantee_principal_id
WHERE pr.name IN ('rola_reklamodawca', 'rola_partner')
ORDER BY pr.name, obiekt;

-- loginy przypisane do firm (przeniesione z danymi)
SELECT 'reklamodawca' AS typ, reklamodawca_id AS id, nazwa, login_bazy FROM streamos.reklamodawca WHERE login_bazy IS NOT NULL
UNION ALL
SELECT 'partner', partner_id, nazwa, login_bazy FROM streamos.partner_oem WHERE login_bazy IS NOT NULL;
