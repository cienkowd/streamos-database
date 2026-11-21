-- StreamOS - etap 2, pkt 3: wyzwalacz na emisja_reklamy
-- uruchamiac jako streamos_admin (Alt+X), po 07 i 08
--
-- UWAGA: tworzyc PO zaladowaniu danych (02_dane.sql). Dane historyczne maja emisje
-- zakonczonych kampanii i przekroczenia limitu (zapytanie 3 z etapu 1), wiec przy
-- wlaczonym wyzwalaczu 02_dane.sql by sie nie wykonal. Istniejacych wierszy wyzwalacz
-- nie sprawdza - dziala tylko przy INSERT.

SET search_path TO streamos;


-- ===== funkcja wyzwalacza =====
-- w PostgreSQL wyzwalacz = funkcja zwracajaca typ "trigger" + CREATE TRIGGER, ktory ja podpina.
-- NEW = wiersz, ktory ma zostac wstawiony; BEFORE pozwala go jeszcze zmienic (koszt).
-- RETURN NEW = wstaw wiersz (ze zmianami); RAISE EXCEPTION = odrzuc cale polecenie INSERT.

CREATE OR REPLACE FUNCTION emisja_przed_dodaniem()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = streamos
AS $$
DECLARE
    v_status    VARCHAR;
    v_data_od   DATE;
    v_data_do   DATE;
    v_stawka    NUMERIC;
    v_limit     INT;
    v_dozwolona BOOLEAN;
    v_dzien     TIMESTAMPTZ;
    v_liczba    INT;
    v_pozostalo NUMERIC;
    v_urz_sesji   INT;
    v_dzieciecy   BOOLEAN;
    v_wiek_tresci INT;
BEGIN
    -- dane kampanii i branzy reklamodawcy jednym zapytaniem.
    -- FOR UPDATE OF k blokuje wiersz kampanii do konca transakcji: dwie rownoczesne emisje
    -- tej samej kampanii czekaja na siebie, zamiast obie zobaczyc ten sam stan budzetu
    -- i limitu i obie przejsc (wtedy budzet albo limit zostalby przekroczony)
    SELECT k.status, k.data_od, k.data_do, k.stawka, k.limit_dzienny, kb.dozwolona_dla_dzieci
    INTO v_status, v_data_od, v_data_do, v_stawka, v_limit, v_dozwolona
    FROM kampania k
    JOIN reklamodawca r        ON r.reklamodawca_id = k.reklamodawca_id
    JOIN kategoria_branzowa kb ON kb.kategoria_branzowa_id = r.kategoria_branzowa_id
    WHERE k.kampania_id = NEW.kampania_id
    FOR UPDATE OF k;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'emisja: nie istnieje kampania o id %', NEW.kampania_id;
    END IF;

    -- 1. koszt zawsze ze stawki kampanii, nawet jesli w INSERT podano inny
    NEW.koszt := v_stawka;

    -- 2. kampania aktywna w dniu emisji
    IF v_status <> 'aktywna' THEN
        RAISE EXCEPTION 'emisja: kampania % ma status %', NEW.kampania_id, v_status;
    END IF;

    -- ::date liczy dzien w strefie czasowej sesji (SHOW timezone)
    IF NEW.czas_emisji::date NOT BETWEEN v_data_od AND v_data_do THEN
        RAISE EXCEPTION 'emisja: dzien % jest poza okresem kampanii % (% - %)',
            NEW.czas_emisji::date, NEW.kampania_id, v_data_od, v_data_do;
    END IF;

    -- 3. reguly zwiazane z sesja - tylko reklama w trakcie ogladania
    -- (sesja_id NULL = ekran glowny: nie ma profilu ani tresci, reguly nie dotycza)
    IF NEW.sesja_id IS NOT NULL THEN
        SELECT s.urzadzenie_id, p.czy_dzieciecy, kw.minimalny_wiek
        INTO v_urz_sesji, v_dzieciecy, v_wiek_tresci
        FROM sesja_ogladania s
        JOIN profil p             ON p.profil_id = s.profil_id
        JOIN tresc t              ON t.tresc_id = s.tresc_id
        JOIN kategoria_wiekowa kw ON kw.kategoria_wiekowa_id = t.kategoria_wiekowa_id
        WHERE s.sesja_id = NEW.sesja_id;

        -- 3a. emisja na tym samym telewizorze, na ktorym trwa sesja
        -- nieistniejaca sesja -> zmienne NULL, "NULL <> x" nie jest prawda, wiec warunek
        -- nie zadziala, a blad zglosi pozniej klucz obcy sesja_id
        IF v_urz_sesji <> NEW.urzadzenie_id THEN
            RAISE EXCEPTION 'emisja: sesja % trwa na telewizorze %, a emisja wskazuje telewizor %',
                NEW.sesja_id, v_urz_sesji, NEW.urzadzenie_id;
        END IF;

        IF NOT v_dozwolona THEN
            -- 3b. branze niedozwolone: nie na profilu dzieciecym
            IF v_dzieciecy THEN
                RAISE EXCEPTION 'emisja: reklam tej branzy nie mozna emitowac na profilu dzieciecym (sesja %)', NEW.sesja_id;
            END IF;

            -- 3c. branze niedozwolone: nie przy tresciach dla dzieci, tez na profilu doroslym
            -- tresc dla dzieci = kategoria wiekowa 0+ albo 7+ (tak jak w generatorze danych)
            IF v_wiek_tresci <= 7 THEN
                RAISE EXCEPTION 'emisja: reklam tej branzy nie mozna emitowac przy tresciach dla dzieci (sesja %, tresc %+)',
                    NEW.sesja_id, v_wiek_tresci;
            END IF;
        END IF;
    END IF;

    -- 4. limit dzienny emisji kampanii na jeden telewizor
    -- zakres od polnocy do polnocy zamiast czas_emisji::date = ...,
    -- zeby mogl zadzialac indeks idx_emisja_kampania_czas (kampania_id, czas_emisji)
    v_dzien := date_trunc('day', NEW.czas_emisji);

    SELECT count(*) INTO v_liczba
    FROM emisja_reklamy
    WHERE kampania_id   = NEW.kampania_id
      AND urzadzenie_id = NEW.urzadzenie_id
      AND czas_emisji  >= v_dzien
      AND czas_emisji   < v_dzien + interval '1 day';

    IF v_liczba >= v_limit THEN
        RAISE EXCEPTION 'emisja: telewizor % osiagnal limit % emisji kampanii % w dniu %',
            NEW.urzadzenie_id, v_limit, NEW.kampania_id, v_dzien::date;
    END IF;

    -- 5. budzet: po tej emisji wydatki nie moga przekroczyc budzetu (funkcja z pkt 1)
    v_pozostalo := pozostaly_budzet(NEW.kampania_id);

    IF v_pozostalo < v_stawka THEN
        RAISE EXCEPTION 'emisja: brak budzetu w kampanii % (zostalo %, stawka %)',
            NEW.kampania_id, v_pozostalo, v_stawka;
    END IF;

    RETURN NEW;
END;
$$;


-- ===== wyzwalacz =====
-- BEFORE INSERT: przed zapisem wiersza (mozna zmienic NEW albo odrzucic)
-- FOR EACH ROW:  osobno dla kazdego wstawianego wiersza
-- CREATE OR REPLACE TRIGGER - od PostgreSQL 14, skrypt mozna uruchamiac wielokrotnie

CREATE OR REPLACE TRIGGER trg_emisja_przed_dodaniem
BEFORE INSERT ON emisja_reklamy
FOR EACH ROW
EXECUTE FUNCTION emisja_przed_dodaniem();


-- kontrola
SELECT tgname AS wyzwalacz, tgrelid::regclass AS tabela, tgfoid::regproc AS funkcja
FROM pg_trigger
WHERE NOT tgisinternal AND tgrelid = 'emisja_reklamy'::regclass;
