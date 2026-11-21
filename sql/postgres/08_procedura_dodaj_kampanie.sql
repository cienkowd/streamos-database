-- StreamOS - etap 2, pkt 2: procedura dodaj_kampanie (kampania + regiony + gatunki w jednej transakcji)
-- uruchamiac jako streamos_admin, calosc (Alt+X), po 07
-- walidacja parametrow, a bledy ograniczen (FK, CHECK, NOT NULL) zamieniane na czytelne komunikaty;
-- blad w dowolnym INSERT wycofuje cala kampanie razem z przypisanymi regionami i gatunkami

CREATE OR REPLACE PROCEDURE streamos.dodaj_kampanie(IN p_reklamodawca_id integer, IN p_nazwa character varying, IN p_budzet numeric, IN p_stawka numeric, IN p_data_od date, IN p_data_do date, IN p_limit_dzienny integer, IN p_regiony integer[], IN p_gatunki integer[], OUT p_kampania_id integer)
 LANGUAGE plpgsql
 SET search_path TO 'streamos'
AS $procedure$
DECLARE
    v_constraint TEXT;
BEGIN
    IF p_data_od IS NULL OR p_data_do IS NULL THEN
        RAISE EXCEPTION 'dodaj_kampanie: obie daty sa wymagane';
    END IF;

    IF p_data_od > p_data_do THEN
        RAISE EXCEPTION 'dodaj_kampanie: data_od (%) jest pozniejsza niz data_do (%)', p_data_od, p_data_do;
    END IF;

    IF p_data_od < current_date THEN
        RAISE EXCEPTION 'dodaj_kampanie: kampania nie moze zaczynac sie w przeszlosci (%)', p_data_od;
    END IF;

    IF p_limit_dzienny IS NULL OR p_limit_dzienny < 1 THEN
        RAISE EXCEPTION 'dodaj_kampanie: limit dzienny musi byc co najmniej 1';
    END IF;

    IF COALESCE(cardinality(p_regiony), 0) = 0 OR array_position(p_regiony, NULL) IS NOT NULL THEN
        RAISE EXCEPTION 'dodaj_kampanie: lista regionow nie moze byc pusta ani zawierac NULL';
    END IF;

    IF COALESCE(cardinality(p_gatunki), 0) = 0 OR array_position(p_gatunki, NULL) IS NOT NULL THEN
        RAISE EXCEPTION 'dodaj_kampanie: lista gatunkow nie moze byc pusta ani zawierac NULL';
    END IF;

    BEGIN
        INSERT INTO kampania (reklamodawca_id, nazwa, budzet, stawka, data_od, data_do, status, limit_dzienny)
        VALUES (p_reklamodawca_id, p_nazwa, p_budzet, p_stawka, p_data_od, p_data_do, 'aktywna', p_limit_dzienny)
        RETURNING kampania_id INTO p_kampania_id;

        INSERT INTO kampania_region (kampania_id, region_id)
        SELECT DISTINCT p_kampania_id, r FROM unnest(p_regiony) AS r;

        INSERT INTO kampania_gatunek (kampania_id, gatunek_id)
        SELECT DISTINCT p_kampania_id, g FROM unnest(p_gatunki) AS g;

    EXCEPTION
        WHEN foreign_key_violation OR check_violation OR not_null_violation THEN
            GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
            RAISE EXCEPTION 'dodaj_kampanie: %',
                CASE v_constraint
                    WHEN 'kampania_reklamodawca_id_fkey'    THEN format('nie istnieje reklamodawca o id %s', p_reklamodawca_id)
                    WHEN 'kampania_region_region_id_fkey'   THEN 'na liscie regionow jest nieistniejacy region'
                    WHEN 'kampania_gatunek_gatunek_id_fkey' THEN 'na liscie gatunkow jest nieistniejacy gatunek'
                    WHEN 'kampania_budzet_check'            THEN 'budzet musi byc wiekszy od 0'
                    WHEN 'kampania_stawka_check'            THEN 'stawka musi byc wieksza od 0'
                    ELSE SQLERRM
                END
                USING ERRCODE = SQLSTATE;
    END;

    RAISE NOTICE 'Dodano kampanie %', p_kampania_id;
END;
$procedure$

;
