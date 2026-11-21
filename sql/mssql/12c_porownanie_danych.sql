-- StreamOS - etap 2, pkt 9: porownanie danych po migracji
-- TO SAMO zapytanie uruchamiac w obu bazach: w PostgreSQL i w SQL Serverze (baza streamos)
-- wyniki powinny byc identyczne wiersz po wierszu
--
-- liczba wierszy pokazuje, czy nic nie zginelo; suma id - czy id nie zostaly przenumerowane
-- (gdyby IDENTITY nadal wlasne numery 1, 2, 3... zamiast id z PostgreSQL, liczba wierszy
--  bylaby ta sama, ale suma juz nie - bo w PostgreSQL sa dziury w numeracji)
-- CAST(... AS BIGINT): w SQL Serverze sum() po INT zwraca INT i przy sesjach przekroczylby zakres

SELECT 'region' AS tabela, count(*) AS wiersze, sum(CAST(region_id AS BIGINT)) AS suma_id FROM streamos.region
UNION ALL SELECT 'gatunek',             count(*), sum(CAST(gatunek_id AS BIGINT))            FROM streamos.gatunek
UNION ALL SELECT 'kategoria_wiekowa',   count(*), sum(CAST(kategoria_wiekowa_id AS BIGINT))  FROM streamos.kategoria_wiekowa
UNION ALL SELECT 'kategoria_branzowa',  count(*), sum(CAST(kategoria_branzowa_id AS BIGINT)) FROM streamos.kategoria_branzowa
UNION ALL SELECT 'partner_oem',         count(*), sum(CAST(partner_id AS BIGINT))            FROM streamos.partner_oem
UNION ALL SELECT 'konto',               count(*), sum(CAST(konto_id AS BIGINT))              FROM streamos.konto
UNION ALL SELECT 'profil',              count(*), sum(CAST(profil_id AS BIGINT))             FROM streamos.profil
UNION ALL SELECT 'urzadzenie',          count(*), sum(CAST(urzadzenie_id AS BIGINT))         FROM streamos.urzadzenie
UNION ALL SELECT 'tresc',               count(*), sum(CAST(tresc_id AS BIGINT))              FROM streamos.tresc
UNION ALL SELECT 'tresc_gatunek',       count(*), sum(CAST(tresc_id AS BIGINT) * 100 + gatunek_id) FROM streamos.tresc_gatunek
UNION ALL SELECT 'sesja_ogladania',     count(*), sum(CAST(sesja_id AS BIGINT))              FROM streamos.sesja_ogladania
UNION ALL SELECT 'reklamodawca',        count(*), sum(CAST(reklamodawca_id AS BIGINT))       FROM streamos.reklamodawca
UNION ALL SELECT 'kampania',            count(*), sum(CAST(kampania_id AS BIGINT))           FROM streamos.kampania
UNION ALL SELECT 'kampania_region',     count(*), sum(CAST(kampania_id AS BIGINT) * 100 + region_id)  FROM streamos.kampania_region
UNION ALL SELECT 'kampania_gatunek',    count(*), sum(CAST(kampania_id AS BIGINT) * 100 + gatunek_id) FROM streamos.kampania_gatunek
UNION ALL SELECT 'emisja_reklamy',      count(*), sum(CAST(emisja_id AS BIGINT))             FROM streamos.emisja_reklamy
UNION ALL SELECT 'dziennik_zadan',      count(*), sum(CAST(wpis_id AS BIGINT))               FROM streamos.dziennik_zadan
UNION ALL SELECT 'rozliczenie_dzienne', count(*), sum(CAST(partner_id AS BIGINT))            FROM streamos.rozliczenie_dzienne;

-- kontrola wartosci, nie tylko kluczy: suma kosztow emisji i budzetow
-- (wykrywa np. obciete miejsca po przecinku przy zlym mapowaniu typow)
SELECT sum(koszt) AS suma_kosztow FROM streamos.emisja_reklamy;
SELECT sum(budzet) AS suma_budzetow, sum(stawka) AS suma_stawek FROM streamos.kampania;
