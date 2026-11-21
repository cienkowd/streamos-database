-- StreamOS - etap 1, pkt 9
-- perspektywy dla reklamodawcow i partnerow OEM
-- uruchamiac jako streamos_admin, po skrypcie 03_uzytkownicy.sql
--
-- zasada: kazda perspektywa filtruje wiersze po zalogowanym uzytkowniku
-- (kolumna login_bazy = current_user), wiec ta sama perspektywa pokazuje
-- kazdej firmie tylko jej wlasne dane. Firmy nie maja dostepu do tabel,
-- tylko do tych perspektyw.
-- security_barrier = PostgreSQL najpierw stosuje filtr perspektywy,
-- zeby nie dalo sie go obejsc wlasnymi warunkami w zapytaniu.

SET search_path TO streamos;


-- ===== REKLAMODAWCA =====

-- 1. podsumowanie moich kampanii
CREATE VIEW v_moje_kampanie WITH (security_barrier) AS
SELECT k.nazwa                                          AS kampania,
       k.data_od                                        AS od,
       k.data_do                                        AS do,
       k.status,
       k.budzet,
       count(e.emisja_id)                               AS liczba_emisji,
       coalesce(round(sum(e.koszt), 2), 0)              AS wydano,
       coalesce(round(100 * sum(e.koszt) / k.budzet, 1), 0) AS proc_budzetu
FROM kampania k
JOIN reklamodawca r        ON r.reklamodawca_id = k.reklamodawca_id
LEFT JOIN emisja_reklamy e ON e.kampania_id = k.kampania_id
WHERE r.login_bazy = current_user
GROUP BY k.kampania_id, k.nazwa, k.data_od, k.data_do, k.status, k.budzet;

-- 2. moje emisje w podziale na regiony (region konta, do ktorego nalezy telewizor)
CREATE VIEW v_moje_emisje_regiony WITH (security_barrier) AS
SELECT k.nazwa               AS kampania,
       rg.nazwa              AS region,
       count(*)              AS liczba_emisji,
       round(sum(e.koszt), 2) AS koszt
FROM emisja_reklamy e
JOIN kampania k     ON k.kampania_id = e.kampania_id
JOIN reklamodawca r ON r.reklamodawca_id = k.reklamodawca_id
JOIN urzadzenie u   ON u.urzadzenie_id = e.urzadzenie_id
JOIN konto ko       ON ko.konto_id = u.konto_id
JOIN region rg      ON rg.region_id = ko.region_id
WHERE r.login_bazy = current_user
GROUP BY k.nazwa, rg.nazwa;


-- ===== PARTNER OEM =====

-- 3. miesieczny przychod z reklam na moich telewizorach i nalezny mi udzial
CREATE VIEW v_moje_przychody WITH (security_barrier) AS
SELECT date_trunc('month', e.czas_emisji)::date           AS miesiac,
       count(DISTINCT e.urzadzenie_id)                     AS telewizory_z_reklamami,
       count(*)                                            AS liczba_emisji,
       round(sum(e.koszt), 2)                              AS przychod_z_reklam,
       round(sum(e.koszt) * p.udzial_procent / 100, 2)     AS nalezne_mi
FROM emisja_reklamy e
JOIN urzadzenie u  ON u.urzadzenie_id = e.urzadzenie_id
JOIN partner_oem p ON p.partner_id = u.partner_id
WHERE p.login_bazy = current_user
GROUP BY date_trunc('month', e.czas_emisji), p.udzial_procent;

-- 4. ogladalnosc na moich telewizorach wedlug typu tresci
CREATE VIEW v_moja_ogladalnosc WITH (security_barrier) AS
SELECT t.typ                                                AS typ_tresci,
       count(*)                                             AS liczba_sesji,
       count(DISTINCT s.urzadzenie_id)                      AS telewizory,
       round(sum(extract(epoch FROM s.czas_koniec - s.czas_start)) / 3600) AS godziny_ogladania
FROM sesja_ogladania s
JOIN urzadzenie u  ON u.urzadzenie_id = s.urzadzenie_id
JOIN partner_oem p ON p.partner_id = u.partner_id
JOIN tresc t       ON t.tresc_id = s.tresc_id
WHERE p.login_bazy = current_user
GROUP BY t.typ;


-- ===== uprawnienia: kazda rola widzi tylko swoje perspektywy =====
GRANT SELECT ON v_moje_kampanie, v_moje_emisje_regiony TO rola_reklamodawca;
GRANT SELECT ON v_moje_przychody, v_moja_ogladalnosc   TO rola_partner;
