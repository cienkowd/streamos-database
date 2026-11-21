-- StreamOS - etap 1, pkt 7
-- uzytkownicy i uprawnienia
-- uruchamiac jako streamos_admin (wlasciciel bazy), po skryptach 01 i 02

-- reset (gdyby trzeba bylo uruchomic ponownie):
-- DROP OWNED BY reklamodawca_02, reklamodawca_03, partner_alfa, partner_beta, rola_reklamodawca, rola_partner;
-- DROP ROLE IF EXISTS reklamodawca_02, reklamodawca_03, partner_alfa, partner_beta, rola_reklamodawca, rola_partner;
-- ALTER TABLE streamos.reklamodawca DROP COLUMN IF EXISTS login_bazy;
-- ALTER TABLE streamos.partner_oem  DROP COLUMN IF EXISTS login_bazy;

SET search_path TO streamos;


-- ===== 1. role grupowe (bez logowania) =====
-- uprawnienia nadaje sie roli, a konkretni uzytkownicy ja dziedzicza,
-- dzieki temu nowego reklamodawce dodaje sie jednym poleceniem

CREATE ROLE rola_reklamodawca NOLOGIN;
CREATE ROLE rola_partner      NOLOGIN;


-- ===== 2. uzytkownicy (z logowaniem) =====
-- po dwa konta na role, zeby dalo sie sprawdzic, ze kazda firma widzi tylko swoje dane

CREATE ROLE reklamodawca_02 LOGIN PASSWORD 'Reklama02!' IN ROLE rola_reklamodawca;
CREATE ROLE reklamodawca_03 LOGIN PASSWORD 'Reklama03!' IN ROLE rola_reklamodawca;
CREATE ROLE partner_alfa    LOGIN PASSWORD 'PartnerA1!' IN ROLE rola_partner;
CREATE ROLE partner_beta    LOGIN PASSWORD 'PartnerB1!' IN ROLE rola_partner;


-- ===== 3. przypisanie loginu do firmy =====
-- nowa kolumna: baza rozpozna firme po current_user (wykorzystane w perspektywach, pkt 9)

ALTER TABLE reklamodawca ADD COLUMN login_bazy VARCHAR(63) UNIQUE;
ALTER TABLE partner_oem  ADD COLUMN login_bazy VARCHAR(63) UNIQUE;

UPDATE reklamodawca SET login_bazy = 'reklamodawca_02' WHERE reklamodawca_id = 2;
UPDATE reklamodawca SET login_bazy = 'reklamodawca_03' WHERE reklamodawca_id = 3;
UPDATE partner_oem  SET login_bazy = 'partner_alfa'    WHERE partner_id = 1;
UPDATE partner_oem  SET login_bazy = 'partner_beta'    WHERE partner_id = 2;


-- ===== 4. uprawnienia =====
-- domyslnie nowe role nie maja zadnego dostepu do tabel w schemacie streamos.
-- dajemy tylko prawo "wejscia" do schematu (USAGE), bez SELECT na tabelach.
-- dostep do danych dostana wylacznie przez perspektywy (pkt 9).

GRANT CONNECT ON DATABASE streamos TO rola_reklamodawca, rola_partner;
GRANT USAGE   ON SCHEMA streamos   TO rola_reklamodawca, rola_partner;

-- dla pewnosci: zadnych praw do tabel dla wszystkich (PUBLIC)
REVOKE ALL ON ALL TABLES IN SCHEMA streamos FROM PUBLIC;


-- ===== 5. kontrola: kto ma jakie role =====
SELECT r.rolname AS uzytkownik, r.rolcanlogin AS moze_sie_logowac, g.rolname AS rola_grupowa
FROM pg_roles r
LEFT JOIN pg_auth_members m ON m.member = r.oid
LEFT JOIN pg_roles g ON g.oid = m.roleid
WHERE r.rolname LIKE 'reklamodawca%' OR r.rolname LIKE 'partner%' OR r.rolname LIKE 'rola%'
ORDER BY 1;
