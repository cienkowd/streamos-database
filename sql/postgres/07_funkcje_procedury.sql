-- StreamOS - etap 2, pkt 1: funkcja i procedury
-- uruchamiac jako streamos_admin (Alt+X), po skryptach etapu 1
-- CREATE OR REPLACE -> skrypt mozna uruchamiac wielokrotnie
-- (00_reset.sql usuwa je razem ze schematem, bo naleza do schematu streamos)

SET search_path TO streamos;


-- ===== 1. funkcja pozostaly_budzet =====
-- budzet kampanii minus suma kosztow jej emisji
-- nieistniejaca kampania -> NULL (zapytanie nie zwraca wiersza)
-- STABLE: tylko czyta dane, w obrebie jednego zapytania wynik sie nie zmienia
-- SET search_path: nazwy tabel w ciele szukane w streamos niezaleznie od ustawien wywolujacego
-- sum() korzysta z indeksu idx_emisja_kampania_czas (kampania_id = pierwsza kolumna)

CREATE OR REPLACE FUNCTION pozostaly_budzet(p_kampania_id INT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
SET search_path = streamos
AS $$
    SELECT k.budzet - COALESCE((SELECT sum(e.koszt)
                                FROM emisja_reklamy e
                                WHERE e.kampania_id = p_kampania_id), 0)
    FROM kampania k
    WHERE k.kampania_id = p_kampania_id;
$$;


-- ===== 2. procedura dodaj_konto =====
-- tworzy konto i od razu profil dorosly, zwraca id konta w parametrze OUT
-- oba INSERT-y w jednej transakcji: blad przy profilu wycofuje tez konto
-- duplikat emaila, zly region, pusta nazwa -> bledy z ograniczen tabel (UNIQUE, FK, NOT NULL)

CREATE OR REPLACE PROCEDURE dodaj_konto(
    p_email         VARCHAR,
    p_region_id     INT,
    p_nazwa_profilu VARCHAR,
    OUT p_konto_id  INT
)
LANGUAGE plpgsql
SET search_path = streamos
AS $$
BEGIN
    INSERT INTO konto (email, region_id)
    VALUES (lower(trim(p_email)), p_region_id)
    RETURNING konto_id INTO p_konto_id;

    INSERT INTO profil (konto_id, nazwa, czy_dzieciecy, kategoria_wiekowa_id)
    VALUES (p_konto_id, p_nazwa_profilu, false, NULL);
END;
$$;


-- ===== 3. procedura aktywuj_urzadzenie =====
-- przypisuje telewizor do konta, tylko jesli nie jest jeszcze aktywowany
-- warunek "konto_id IS NULL" w samym UPDATE (a nie osobny SELECT przed nim):
-- dwie rownoczesne aktywacje nie nadpisza sie nawzajem
-- FOUND = czy ostatnie polecenie zmienilo jakis wiersz
-- nieistniejace konto -> blad klucza obcego

CREATE OR REPLACE PROCEDURE aktywuj_urzadzenie(p_numer_seryjny VARCHAR, p_konto_id INT)
LANGUAGE plpgsql
SET search_path = streamos
AS $$
BEGIN
    UPDATE urzadzenie
    SET konto_id = p_konto_id
    WHERE numer_seryjny = p_numer_seryjny
      AND konto_id IS NULL;

    IF NOT FOUND THEN
        IF EXISTS (SELECT 1 FROM urzadzenie WHERE numer_seryjny = p_numer_seryjny) THEN
            RAISE EXCEPTION 'Urzadzenie % jest juz aktywowane', p_numer_seryjny;
        ELSE
            RAISE EXCEPTION 'Nie ma urzadzenia o numerze %', p_numer_seryjny;
        END IF;
    END IF;
END;
$$;


-- ===== 4. uprawnienia =====
-- PostgreSQL domyslnie daje EXECUTE na funkcje i procedury roli PUBLIC (kazdemu).
-- odbieramy: wywolywac moze tylko wlasciciel (streamos_admin)

REVOKE EXECUTE ON ALL ROUTINES IN SCHEMA streamos FROM PUBLIC;


-- ===== 5. kontrola =====
SELECT routine_name AS nazwa, routine_type AS typ, data_type AS zwraca
FROM information_schema.routines
WHERE routine_schema = 'streamos'
ORDER BY routine_name;
