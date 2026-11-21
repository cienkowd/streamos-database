-- StreamOS - etap 2, pkt 6: automatyzacja (pg_cron)
-- uruchamiac jako streamos_admin (Alt+X), po 07-10
-- wymaga obrazu z pg_cron i shared_preload_libraries=pg_cron (docker-compose)
--
-- zadanie dobowe, 3 kroki, kazdy w osobnej transakcji:
--   1. zamkniecie kampanii po terminie
--   2. zamkniecie kampanii, ktorym budzet nie wystarcza na kolejna emisje
--   3. dzienne rozliczenie partnerow OEM, z nadrabianiem zaleglych dni
-- kazdy krok zapisuje w dzienniku, co zrobil albo jaki wystapil blad

SET search_path TO streamos;


-- ===== 1. tabele =====

-- jeden wiersz na krok kazdego uruchomienia
CREATE TABLE IF NOT EXISTS dziennik_zadan (
    wpis_id   BIGSERIAL PRIMARY KEY,
    zadanie   VARCHAR(50) NOT NULL,
    krok      VARCHAR(50) NOT NULL,
    start     TIMESTAMPTZ NOT NULL,
    koniec    TIMESTAMPTZ NOT NULL,
    status    VARCHAR(4)  NOT NULL CHECK (status IN ('OK', 'BLAD')),
    wiersze   INT,                 -- ile wierszy krok zmienil/zapisal (NULL przy bledzie)
    komunikat TEXT                 -- tresc bledu (NULL gdy OK)
);

-- wynik rozliczenia: jeden wiersz na partnera na dzien, takze dni bez emisji (zera)
-- klucz (dzien, partner_id): ponowne liczenie tego samego dnia nadpisuje wiersz, nie dubluje go
CREATE TABLE IF NOT EXISTS rozliczenie_dzienne (
    dzien           DATE          NOT NULL,
    partner_id      INT           NOT NULL REFERENCES partner_oem(partner_id),
    liczba_emisji   INT           NOT NULL,
    przychod        NUMERIC(14,4) NOT NULL,
    nalezne         NUMERIC(14,4) NOT NULL,
    data_wyliczenia TIMESTAMPTZ   NOT NULL DEFAULT now(),
    PRIMARY KEY (dzien, partner_id)
);


-- ===== 2. procedura zadanie_dobowe =====
-- procedura, a nie funkcja, bo robi COMMIT po kazdym kroku: blad w jednym kroku
-- nie cofa poprzednich, a wpis w dzienniku zostaje zapisany nawet po bledzie.
--
-- dwa ograniczenia PL/pgSQL, ktore wymusily ten ksztalt:
--   - procedura z klauzula SET (np. SET search_path) nie moze robic COMMIT,
--     dlatego schemat i strefa czasowa sa ustawiane w ciele przez set_config
--   - w bloku z EXCEPTION nie wolno robic COMMIT, dlatego blok tylko lapie blad
--     do zmiennych, a wpis do dziennika i COMMIT sa juz za blokiem

CREATE OR REPLACE PROCEDURE zadanie_dobowe()
LANGUAGE plpgsql
AS $$
DECLARE
    v_start     TIMESTAMPTZ;
    v_status    VARCHAR(4);
    v_wiersze   INT;
    v_komunikat TEXT;
    v_bledy     INT := 0;
    v_od        DATE;
    v_do        DATE;
BEGIN
    -- false = na cala sesje, nie tylko do konca transakcji (inaczej COMMIT by to cofnal).
    -- strefa czasowa ustawiona jawnie: pg_cron laczy sie z ustawieniami serwera (w Dockerze UTC),
    -- a DBeaver z ustawieniami komputera - bez tego "dzien" i current_date znaczylyby co innego
    PERFORM set_config('search_path', 'streamos', false);
    PERFORM set_config('TimeZone', 'Europe/Warsaw', false);


    -- ===== krok 1: kampanie po terminie =====
    -- clock_timestamp() = rzeczywisty czas; now() przez cala transakcje zwraca ten sam moment
    v_start := clock_timestamp();
    BEGIN
        UPDATE kampania
        SET status = 'zakonczona'
        WHERE status = 'aktywna' AND data_do < current_date;

        GET DIAGNOSTICS v_wiersze = ROW_COUNT;
        v_status := 'OK';  v_komunikat := NULL;
    EXCEPTION WHEN OTHERS THEN
        v_status := 'BLAD';  v_wiersze := NULL;  v_komunikat := SQLERRM;
    END;

    INSERT INTO dziennik_zadan (zadanie, krok, start, koniec, status, wiersze, komunikat)
    VALUES ('zadanie_dobowe', 'kampanie po terminie', v_start, clock_timestamp(), v_status, v_wiersze, v_komunikat);
    IF v_status = 'BLAD' THEN v_bledy := v_bledy + 1; END IF;
    COMMIT;


    -- ===== krok 2: kampanie bez budzetu na kolejna emisje =====
    -- "pozostalo < stawka", a nie "pozostalo = 0": przy reszcie 0.03 i stawce 0.05
    -- kampania i tak nie wyemituje juz zadnej reklamy (wyzwalacz by ja odrzucil)
    v_start := clock_timestamp();
    BEGIN
        UPDATE kampania k
        SET status = 'zakonczona'
        WHERE k.status = 'aktywna' AND pozostaly_budzet(k.kampania_id) < k.stawka;

        GET DIAGNOSTICS v_wiersze = ROW_COUNT;
        v_status := 'OK';  v_komunikat := NULL;
    EXCEPTION WHEN OTHERS THEN
        v_status := 'BLAD';  v_wiersze := NULL;  v_komunikat := SQLERRM;
    END;

    INSERT INTO dziennik_zadan (zadanie, krok, start, koniec, status, wiersze, komunikat)
    VALUES ('zadanie_dobowe', 'kampanie bez budzetu', v_start, clock_timestamp(), v_status, v_wiersze, v_komunikat);
    IF v_status = 'BLAD' THEN v_bledy := v_bledy + 1; END IF;
    COMMIT;


    -- ===== krok 3: dzienne rozliczenie partnerow =====
    -- zakres: od dnia po ostatnim rozliczonym do wczoraj. Jesli komputer byl wylaczony
    -- kilka dni, kolejne uruchomienie nadrobi wszystkie brakujace dni.
    -- pierwsze uruchomienie (pusta tabela): od pierwszego dnia z emisjami
    -- (min(czas_emisji) bierze wartosc z indeksu idx_emisja_czas, bez czytania tabeli)
    v_start := clock_timestamp();
    BEGIN
        v_od := COALESCE((SELECT max(dzien) + 1 FROM rozliczenie_dzienne),
                         (SELECT min(czas_emisji)::date FROM emisja_reklamy));
        v_do := current_date - 1;

        -- dni   = kazdy dzien z zakresu (generate_series; pusty, gdy v_od > v_do)
        -- emisje = suma emisji na dzien i partnera, liczona raz dla calego zakresu
        -- dni x partnerzy LEFT JOIN emisje -> wiersz z zerami, gdy partner nie mial emisji
        WITH dni AS (
            SELECT d::date AS dzien
            FROM generate_series(v_od, v_do, interval '1 day') AS d
        ),
        emisje AS (
            SELECT e.czas_emisji::date AS dzien, u.partner_id,
                   count(*) AS liczba, sum(e.koszt) AS suma
            FROM emisja_reklamy e
            JOIN urzadzenie u ON u.urzadzenie_id = e.urzadzenie_id
            WHERE e.czas_emisji >= v_od
              AND e.czas_emisji <  v_do + 1
            GROUP BY e.czas_emisji::date, u.partner_id
        )
        INSERT INTO rozliczenie_dzienne (dzien, partner_id, liczba_emisji, przychod, nalezne)
        SELECT d.dzien, p.partner_id,
               COALESCE(em.liczba, 0),
               COALESCE(em.suma, 0),
               COALESCE(em.suma, 0) * p.udzial_procent / 100
        FROM dni d
        CROSS JOIN partner_oem p
        LEFT JOIN emisje em ON em.dzien = d.dzien AND em.partner_id = p.partner_id
        -- ON CONFLICT: gdy wiersz (dzien, partner_id) juz istnieje, aktualizujemy go
        -- EXCLUDED = wiersz, ktory probowalismy wstawic
        ON CONFLICT (dzien, partner_id) DO UPDATE
        SET liczba_emisji   = EXCLUDED.liczba_emisji,
            przychod        = EXCLUDED.przychod,
            nalezne         = EXCLUDED.nalezne,
            data_wyliczenia = now();

        GET DIAGNOSTICS v_wiersze = ROW_COUNT;
        v_status := 'OK';
        v_komunikat := CASE WHEN v_od > v_do THEN 'wszystkie dni juz rozliczone'
                            ELSE format('dni %s - %s', v_od, v_do) END;
    EXCEPTION WHEN OTHERS THEN
        v_status := 'BLAD';  v_wiersze := NULL;  v_komunikat := SQLERRM;
    END;

    INSERT INTO dziennik_zadan (zadanie, krok, start, koniec, status, wiersze, komunikat)
    VALUES ('zadanie_dobowe', 'rozliczenie partnerow', v_start, clock_timestamp(), v_status, v_wiersze, v_komunikat);
    IF v_status = 'BLAD' THEN v_bledy := v_bledy + 1; END IF;
    COMMIT;


    -- na koniec blad, jesli ktorys krok sie nie udal: wtedy tez pg_cron oznaczy
    -- uruchomienie jako nieudane (cron.job_run_details), a szczegoly sa w dzienniku.
    -- wczesniejsze kroki sa juz zatwierdzone, wiec ten blad niczego nie cofa
    IF v_bledy > 0 THEN
        RAISE EXCEPTION 'zadanie_dobowe: % krok(i) z bledem, szczegoly w dziennik_zadan', v_bledy;
    END IF;
END;
$$;

REVOKE EXECUTE ON PROCEDURE zadanie_dobowe FROM PUBLIC;


-- ===== 3. harmonogram =====
-- pg_cron trzyma swoje tabele w schemacie cron; rozszerzenie tworzy sie raz,
-- w bazie wskazanej przez cron.database_name (streamos)
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- codziennie o 00:15 (czas wg cron.timezone = Europe/Warsaw)
-- format: minuta godzina dzien_miesiaca miesiac dzien_tygodnia
-- cron.schedule z nazwa: ponowne wywolanie z ta sama nazwa nadpisuje zadanie, nie dubluje go
SELECT cron.schedule('zadanie_dobowe', '15 0 * * *', 'CALL streamos.zadanie_dobowe()');

-- kontrola
SELECT jobid, jobname, schedule, command, database, username, active
FROM cron.job;
