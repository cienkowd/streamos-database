-- StreamOS - etap 2, pkt 10, czesc 3: testy uprawnien i perspektyw w SQL Server
-- odpowiedniki 03b (testy 1-6) i 05b (testy 1-6), te same numery
-- uruchamiac jako sa, POLECENIE PO POLECENIU (Ctrl+Enter), zrzut kazdego wyniku
--
-- EXECUTE AS USER = '...' przelacza sesje na innego uzytkownika (odpowiednik SET ROLE),
-- REVERT wraca do sa (odpowiednik RESET ROLE).
-- przelaczenie trwa do REVERT, takze po bledzie - REVERT trzeba wykonac zawsze.
-- jesli nie wiadomo, kim sie jest: SELECT CURRENT_USER; (sa widzi siebie jako dbo)

USE streamos;
GO


-- ===================== uprawnienia (03b) =====================

-- test 1: kim jestem
EXECUTE AS USER = 'reklamodawca_03';
SELECT CURRENT_USER AS uzytkownik, SUSER_SNAME() AS login;
-- oczekiwane: reklamodawca_03, reklamodawca_03

-- test 2: odczyt tabeli -> blad
SELECT TOP 5 * FROM streamos.kampania;
-- oczekiwany blad 229: The SELECT permission was denied on the object 'kampania', database 'streamos', schema 'streamos'

-- test 3: modyfikacja -> blad
UPDATE streamos.kampania SET budzet = 1 WHERE kampania_id = 1;
-- oczekiwany blad 229: The UPDATE permission was denied on the object 'kampania' ...

-- test 4: usuniecie tabeli -> blad
DROP TABLE streamos.emisja_reklamy;
-- oczekiwany blad 3701: Cannot drop the table 'streamos.emisja_reklamy', because it does not exist
-- or you do not have permission.
-- (SQL Server celowo nie mowi, czy tabela istnieje - zeby nie zdradzac struktury bazy)

REVERT;

-- test 5: to samo dla partnera
EXECUTE AS USER = 'partner_alfa';
SELECT TOP 5 * FROM streamos.urzadzenie;
-- oczekiwany blad 229
REVERT;

-- test 6: admin dalej widzi wszystko
SELECT CURRENT_USER AS uzytkownik, COUNT(*) AS kampanie FROM streamos.kampania;
-- oczekiwane: dbo, liczba kampanii


-- ===================== perspektywy (05b) =====================
-- wyniki porownac z tymi samymi testami w PostgreSQL

-- test 1: dwaj reklamodawcy, ta sama perspektywa, rozne dane
EXECUTE AS USER = 'reklamodawca_02';
SELECT * FROM streamos.v_moje_kampanie ORDER BY kampania;
REVERT;

EXECUTE AS USER = 'reklamodawca_03';
SELECT * FROM streamos.v_moje_kampanie ORDER BY kampania;
REVERT;

-- test 2: emisje wg regionow
EXECUTE AS USER = 'reklamodawca_03';
SELECT * FROM streamos.v_moje_emisje_regiony ORDER BY kampania, liczba_emisji DESC;
REVERT;

-- test 3: dwaj partnerzy, rozne dane
EXECUTE AS USER = 'partner_alfa';
SELECT * FROM streamos.v_moje_przychody ORDER BY miesiac;
REVERT;

EXECUTE AS USER = 'partner_beta';
SELECT * FROM streamos.v_moje_przychody ORDER BY miesiac;
REVERT;

-- test 4: ogladalnosc partnera
EXECUTE AS USER = 'partner_alfa';
SELECT * FROM streamos.v_moja_ogladalnosc ORDER BY typ_tresci;
REVERT;

-- test 5: reklamodawca probuje zajrzec do perspektywy partnera -> blad
EXECUTE AS USER = 'reklamodawca_03';
SELECT * FROM streamos.v_moje_przychody;
-- oczekiwany blad 229: The SELECT permission was denied on the object 'v_moje_przychody' ...
REVERT;

-- test 6: proba obejscia filtra wlasnym warunkiem -> nadal tylko wlasne dane
EXECUTE AS USER = 'reklamodawca_03';
SELECT * FROM streamos.v_moje_kampanie WHERE kampania = 'Kampania 2';
-- oczekiwane: 0 wierszy (Kampania 2 nalezy do Reklamodawcy 02)
REVERT;


-- ===================== dodatkowo: prawdziwe logowanie =====================
-- EXECUTE AS tylko symuluje uzytkownika. Dla pewnosci, ze loginy dzialaja:
-- w DBeaverze nowe polaczenie SQL Server, uzytkownik reklamodawca_03, haslo Reklama03!,
-- baza streamos (trustServerCertificate = true jak dla sa), i tam:
--   SELECT * FROM streamos.v_moje_kampanie;   -- wynik jak w tescie 1
--   SELECT * FROM streamos.kampania;          -- blad 229
