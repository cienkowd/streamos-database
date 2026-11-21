-- StreamOS - etap 2, pkt 4: pozostale reguly spojnosci i agregacja dla administratora
-- uruchamiac jako streamos_admin (Alt+X), po 07, 08 i 09
--   1. ograniczenia CHECK  - reguly dotyczace jednego wiersza
--   2. wyzwalacz na sesja_ogladania - reguly siegajace do innych tabel
--   3. funkcja rozliczenie_partnerow - zapytanie 1 z etapu 1 jako funkcja z parametrem

SET search_path TO streamos;


-- ===== 1. ograniczenia CHECK =====
-- regula widzi tylko kolumny tego samego wiersza -> wystarczy CHECK, wyzwalacz bylby zbedny.
-- ADD CONSTRAINT sprawdza tez wszystkie istniejace wiersze: jesli ktorys lamie regule,
-- polecenie sie nie wykona (dane z 02_dane.sql je spelniaja).
-- DROP ... IF EXISTS - zeby skrypt mozna bylo uruchomic ponownie

-- kampania: koniec nie wczesniej niz poczatek
-- (dodaj_kampanie juz to sprawdza, ale zwykly INSERT do tabeli omijal procedure)
ALTER TABLE kampania DROP CONSTRAINT IF EXISTS kampania_daty_check;
ALTER TABLE kampania ADD CONSTRAINT kampania_daty_check
    CHECK (data_od <= data_do);

-- sesja: koniec nie wczesniej niz start
-- trwajaca sesja ma czas_koniec NULL - CHECK z wynikiem NULL jest traktowany jak spelniony,
-- wiec nie trzeba dopisywac "czas_koniec IS NULL OR ..."
ALTER TABLE sesja_ogladania DROP CONSTRAINT IF EXISTS sesja_czas_check;
ALTER TABLE sesja_ogladania ADD CONSTRAINT sesja_czas_check
    CHECK (czas_koniec >= czas_start);

-- profil: dzieciecy <=> ma limit wiekowy (dorosly nie ma limitu, dzieciecy musi go miec)
ALTER TABLE profil DROP CONSTRAINT IF EXISTS profil_dzieciecy_check;
ALTER TABLE profil ADD CONSTRAINT profil_dzieciecy_check
    CHECK (czy_dzieciecy = (kategoria_wiekowa_id IS NOT NULL));


-- ===== 2. wyzwalacz na sesja_ogladania =====
-- reguly:
--   a) profil i telewizor naleza do tego samego konta
--      (telewizor nieaktywowany ma konto NULL, wiec tez nie przejdzie)
--   b) profil dzieciecy oglada tylko tresci do swojego limitu wiekowego
-- porownanie po minimalny_wiek, a nie po id kategorii - id nie musi rosnac razem z wiekiem

CREATE OR REPLACE FUNCTION sesja_przed_zapisem()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = streamos
AS $$
DECLARE
    v_konto_profilu INT;
    v_konto_tv      INT;
    v_dzieciecy     BOOLEAN;
    v_limit_wiek    INT;
    v_wiek_tresci   INT;
BEGIN
    SELECT p.konto_id, p.czy_dzieciecy, kw.minimalny_wiek
    INTO v_konto_profilu, v_dzieciecy, v_limit_wiek
    FROM profil p
    LEFT JOIN kategoria_wiekowa kw ON kw.kategoria_wiekowa_id = p.kategoria_wiekowa_id  -- dorosly: brak limitu
    WHERE p.profil_id = NEW.profil_id;

    SELECT konto_id INTO v_konto_tv
    FROM urzadzenie
    WHERE urzadzenie_id = NEW.urzadzenie_id;

    -- IS DISTINCT FROM zamiast <>: traktuje NULL jak zwykla wartosc,
    -- wiec telewizor bez konta (NULL) tez jest "innym kontem"
    IF v_konto_tv IS DISTINCT FROM v_konto_profilu THEN
        RAISE EXCEPTION 'sesja: profil % (konto %) i telewizor % (konto %) nie naleza do tego samego konta',
            NEW.profil_id, v_konto_profilu, NEW.urzadzenie_id, v_konto_tv;
    END IF;

    IF v_dzieciecy THEN
        SELECT kw.minimalny_wiek INTO v_wiek_tresci
        FROM tresc t
        JOIN kategoria_wiekowa kw ON kw.kategoria_wiekowa_id = t.kategoria_wiekowa_id
        WHERE t.tresc_id = NEW.tresc_id;

        IF v_wiek_tresci > v_limit_wiek THEN
            RAISE EXCEPTION 'sesja: profil dzieciecy % ma limit %+, a tresc % jest %+',
                NEW.profil_id, v_limit_wiek, NEW.tresc_id, v_wiek_tresci;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

-- INSERT oraz UPDATE, ale tylko gdy zmienia sie profil, telewizor albo tresc.
-- zakonczenie sesji (UPDATE czas_koniec) nie uruchamia wyzwalacza - nie ma czego sprawdzac
CREATE OR REPLACE TRIGGER trg_sesja_przed_zapisem
BEFORE INSERT OR UPDATE OF profil_id, urzadzenie_id, tresc_id ON sesja_ogladania
FOR EACH ROW
EXECUTE FUNCTION sesja_przed_zapisem();


-- ===== 3. funkcja rozliczenie_partnerow =====
-- zapytanie 1 z etapu 1 jako funkcja z parametrem: rozliczenie za dowolny miesiac.
-- RETURNS TABLE = funkcja zwraca zbior wierszy, uzywa sie jej w FROM jak tabeli
-- parametr pominiety -> poprzedni miesiac (wartosc domyslna liczona przy kazdym wywolaniu)
-- LEFT JOIN od partner_oem: partner bez emisji w danym miesiacu tez jest na liscie, z zerami
-- warunek na czas emisji w ON, nie w WHERE - w WHERE odrzucilby partnerow bez emisji

CREATE OR REPLACE FUNCTION rozliczenie_partnerow(
    p_miesiac DATE DEFAULT (date_trunc('month', now()) - interval '1 month')::date
)
RETURNS TABLE (
    partner            VARCHAR,
    liczba_emisji      BIGINT,
    przychod_z_reklam  NUMERIC,
    udzial_proc        NUMERIC,
    nalezne_partnerowi NUMERIC
)
LANGUAGE sql
STABLE
SET search_path = streamos
AS $$
    SELECT p.nazwa,
           count(e.emisja_id),
           COALESCE(round(sum(e.koszt), 2), 0),
           p.udzial_procent,
           COALESCE(round(sum(e.koszt) * p.udzial_procent / 100, 2), 0)
    FROM partner_oem p
    LEFT JOIN urzadzenie u     ON u.partner_id = p.partner_id
    LEFT JOIN emisja_reklamy e ON e.urzadzenie_id = u.urzadzenie_id
                              AND e.czas_emisji >= date_trunc('month', p_miesiac)
                              AND e.czas_emisji <  date_trunc('month', p_miesiac) + interval '1 month'
    GROUP BY p.partner_id, p.nazwa, p.udzial_procent
    ORDER BY 3 DESC, p.nazwa;
$$;

REVOKE EXECUTE ON FUNCTION rozliczenie_partnerow FROM PUBLIC;


-- ===== kontrola =====
SELECT conrelid::regclass AS tabela, conname AS ograniczenie, pg_get_constraintdef(oid) AS definicja
FROM pg_constraint
WHERE conname IN ('kampania_daty_check', 'sesja_czas_check', 'profil_dzieciecy_check');

SELECT tgname AS wyzwalacz, tgrelid::regclass AS tabela
FROM pg_trigger
WHERE NOT tgisinternal AND tgrelid::regclass::text IN ('sesja_ogladania', 'emisja_reklamy');
