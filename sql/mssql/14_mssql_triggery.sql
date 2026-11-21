-- StreamOS - etap 2, pkt 10, czesc 2: wyzwalacze w MS SQL Server
-- odpowiedniki: 09 (trg_emisja_przed_dodaniem), 10 (trg_sesja_przed_zapisem)
-- uruchamiac w DBeaverze na polaczeniu SQL Server, baza streamos, calosc (Alt+X), po 13
--
-- najwieksze roznice wobec PostgreSQL:
--   1. SQL Server nie ma wyzwalaczy BEFORE. Sa tylko AFTER i INSTEAD OF.
--   2. Wyzwalacz uruchamia sie RAZ NA POLECENIE, nie raz na wiersz (brak FOR EACH ROW).
--      Zmienione wiersze sa w pseudotabelach "inserted" (nowe) i "deleted" (stare),
--      ktore moga miec wiele wierszy - kazda regula musi byc sprawdzona zbiorczo (SELECT
--      po inserted), a nie przez NEW.kolumna.
--   3. Blad (THROW) w wyzwalaczu wycofuje cala transakcje, w ktorej padlo polecenie
--      (w wyzwalaczu XACT_ABORT jest domyslnie wlaczony).
--
-- wzorzec sprawdzania regul: SELECT TOP 1 @komunikat = ... WHERE <naruszenie>.
-- jesli zaden wiersz nie lamie reguly, SELECT nie przypisze nic i @komunikat zostaje NULL.
-- jesli lamie - THROW z opisem pierwszego zlego wiersza.

USE streamos;
GO


-- ===== 1. wyzwalacz na emisja_reklamy: INSTEAD OF INSERT =====
-- zamiast BEFORE INSERT. INSTEAD OF przejmuje cale polecenie INSERT: wiersze trafiaja
-- tylko do "inserted", a do tabeli zapisuje je dopiero INSERT na koncu wyzwalacza
-- (ten wewnetrzny INSERT nie uruchamia wyzwalacza ponownie).
-- dzieki temu, jak w BEFORE, mozna zmienic dane przed zapisem (koszt = stawka)
-- albo odrzucic polecenie.
-- INSTEAD OF dziala przed sprawdzeniem ograniczen, wiec INSERT bez kolumny koszt
-- (NOT NULL) nie jest bledem - koszt uzupelnia wyzwalacz.
--
-- dzien emisji liczony w czasie polskim (AT TIME ZONE), tak jak w PostgreSQL ze strefa Europe/Warsaw

CREATE OR ALTER TRIGGER streamos.trg_emisja_przed_dodaniem
ON streamos.emisja_reklamy
INSTEAD OF INSERT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;

    DECLARE @komunikat NVARCHAR(400);

    -- dane kampanii z polecenia, z blokada - odpowiednik FOR UPDATE:
    --   UPDLOCK  = blokada do aktualizacji: dwie rownoczesne emisje tej samej kampanii
    --              nie moga jej trzymac naraz, druga czeka
    --   HOLDLOCK = blokada trzymana do konca transakcji, a nie tylko na czas odczytu
    DECLARE @kamp TABLE (
        kampania_id   INT PRIMARY KEY,
        status        VARCHAR(20),
        data_od       DATE,
        data_do       DATE,
        stawka        NUMERIC(8,4),
        limit_dzienny INT,
        dozwolona     BIT
    );

    INSERT INTO @kamp
    SELECT k.kampania_id, k.status, k.data_od, k.data_do, k.stawka, k.limit_dzienny, kb.dozwolona_dla_dzieci
    FROM streamos.kampania k WITH (UPDLOCK, HOLDLOCK)
    JOIN streamos.reklamodawca r        ON r.reklamodawca_id = k.reklamodawca_id
    JOIN streamos.kategoria_branzowa kb ON kb.kategoria_branzowa_id = r.kategoria_branzowa_id
    WHERE k.kampania_id IN (SELECT kampania_id FROM inserted);

    -- 0. nieistniejaca kampania (bez tego wiersz zniknalby przy JOIN na koncu, bez bledu)
    SELECT TOP 1 @komunikat = CONCAT('emisja: nie istnieje kampania o id ', i.kampania_id)
    FROM inserted i
    WHERE NOT EXISTS (SELECT 1 FROM @kamp k WHERE k.kampania_id = i.kampania_id);
    IF @komunikat IS NOT NULL THROW 50101, @komunikat, 1;

    -- 2. kampania aktywna w dniu emisji
    SELECT TOP 1 @komunikat = CONCAT('emisja: kampania ', k.kampania_id, ' ma status ', k.status)
    FROM inserted i JOIN @kamp k ON k.kampania_id = i.kampania_id
    WHERE k.status <> 'aktywna';
    IF @komunikat IS NOT NULL THROW 50102, @komunikat, 1;

    SELECT TOP 1 @komunikat = CONCAT('emisja: dzien ', CAST(i.czas_emisji AT TIME ZONE 'Central European Standard Time' AS DATE),
                                     ' jest poza okresem kampanii ', k.kampania_id, ' (', k.data_od, ' - ', k.data_do, ')')
    FROM inserted i JOIN @kamp k ON k.kampania_id = i.kampania_id
    WHERE CAST(i.czas_emisji AT TIME ZONE 'Central European Standard Time' AS DATE) NOT BETWEEN k.data_od AND k.data_do;
    IF @komunikat IS NOT NULL THROW 50103, @komunikat, 1;

    -- 3. reguly zwiazane z sesja (tylko emisje z sesja_id; NULL = ekran glowny)
    -- 3a. emisja na tym samym telewizorze co sesja
    SELECT TOP 1 @komunikat = CONCAT('emisja: sesja ', i.sesja_id, ' trwa na telewizorze ', s.urzadzenie_id,
                                     ', a emisja wskazuje telewizor ', i.urzadzenie_id)
    FROM inserted i JOIN streamos.sesja_ogladania s ON s.sesja_id = i.sesja_id
    WHERE s.urzadzenie_id <> i.urzadzenie_id;
    IF @komunikat IS NOT NULL THROW 50104, @komunikat, 1;

    -- 3b. branza niedozwolona: nie na profilu dzieciecym
    SELECT TOP 1 @komunikat = CONCAT('emisja: reklam tej branzy nie mozna emitowac na profilu dzieciecym (sesja ', i.sesja_id, ')')
    FROM inserted i
    JOIN @kamp k                    ON k.kampania_id = i.kampania_id
    JOIN streamos.sesja_ogladania s ON s.sesja_id = i.sesja_id
    JOIN streamos.profil p          ON p.profil_id = s.profil_id
    WHERE k.dozwolona = 0 AND p.czy_dzieciecy = 1;
    IF @komunikat IS NOT NULL THROW 50105, @komunikat, 1;

    -- 3c. branza niedozwolona: nie przy tresciach dla dzieci (0+ i 7+), tez na profilu doroslym
    SELECT TOP 1 @komunikat = CONCAT('emisja: reklam tej branzy nie mozna emitowac przy tresciach dla dzieci (sesja ',
                                     i.sesja_id, ', tresc ', kw.minimalny_wiek, '+)')
    FROM inserted i
    JOIN @kamp k                      ON k.kampania_id = i.kampania_id
    JOIN streamos.sesja_ogladania s   ON s.sesja_id = i.sesja_id
    JOIN streamos.tresc t             ON t.tresc_id = s.tresc_id
    JOIN streamos.kategoria_wiekowa kw ON kw.kategoria_wiekowa_id = t.kategoria_wiekowa_id
    WHERE k.dozwolona = 0 AND kw.minimalny_wiek <= 7;
    IF @komunikat IS NOT NULL THROW 50106, @komunikat, 1;

    -- 4. limit dzienny na telewizor
    -- w PostgreSQL wyzwalacz FOR EACH ROW widzial wiersze wstawione chwile wczesniej w tym
    -- samym poleceniu. Tutaj nowych wierszy jeszcze nie ma w tabeli, wiec liczymy osobno:
    -- juz zapisane (CROSS APPLY) + nowe z tego polecenia (n.ile) - tez dla INSERT wielu wierszy.
    -- CROSS APPLY = podzapytanie wykonywane dla kazdego wiersza z lewej strony (jak LATERAL w PG)
    WITH nowe AS (
        SELECT kampania_id, urzadzenie_id,
               CAST(czas_emisji AT TIME ZONE 'Central European Standard Time' AS DATE) AS dzien,
               COUNT(*) AS ile
        FROM inserted
        GROUP BY kampania_id, urzadzenie_id, CAST(czas_emisji AT TIME ZONE 'Central European Standard Time' AS DATE)
    )
    SELECT TOP 1 @komunikat = CONCAT('emisja: telewizor ', n.urzadzenie_id, ' osiagnal limit ', k.limit_dzienny,
                                     ' emisji kampanii ', n.kampania_id, ' w dniu ', n.dzien)
    FROM nowe n
    JOIN @kamp k ON k.kampania_id = n.kampania_id
    CROSS APPLY (
        -- granice dnia: polnoc czasu polskiego (AT TIME ZONE na DATETIME2 daje DATETIMEOFFSET)
        SELECT COUNT(*) AS juz
        FROM streamos.emisja_reklamy e
        WHERE e.kampania_id   = n.kampania_id
          AND e.urzadzenie_id = n.urzadzenie_id
          AND e.czas_emisji  >= (CAST(n.dzien AS DATETIME2) AT TIME ZONE 'Central European Standard Time')
          AND e.czas_emisji   < (CAST(DATEADD(DAY, 1, n.dzien) AS DATETIME2) AT TIME ZONE 'Central European Standard Time')
    ) x
    WHERE x.juz + n.ile > k.limit_dzienny;
    IF @komunikat IS NOT NULL THROW 50107, @komunikat, 1;

    -- 5. budzet: musi wystarczyc na WSZYSTKIE emisje kampanii z tego polecenia
    SELECT TOP 1 @komunikat = CONCAT('emisja: brak budzetu w kampanii ', n.kampania_id,
                                     ' (zostalo ', b.pozostalo, ', potrzeba ', k.stawka * n.ile, ')')
    FROM (SELECT kampania_id, COUNT(*) AS ile FROM inserted GROUP BY kampania_id) n
    JOIN @kamp k ON k.kampania_id = n.kampania_id
    CROSS APPLY (SELECT streamos.pozostaly_budzet(n.kampania_id) AS pozostalo) b
    WHERE b.pozostalo < k.stawka * n.ile;
    IF @komunikat IS NOT NULL THROW 50108, @komunikat, 1;

    -- 1. zapis z kosztem ze stawki kampanii (koszt podany w INSERT jest pomijany)
    INSERT INTO streamos.emisja_reklamy (kampania_id, urzadzenie_id, sesja_id, czas_emisji, koszt)
    SELECT i.kampania_id, i.urzadzenie_id, i.sesja_id, i.czas_emisji, k.stawka
    FROM inserted i
    JOIN @kamp k ON k.kampania_id = i.kampania_id;
END;
GO


-- ===== 2. wyzwalacz na sesja_ogladania: AFTER INSERT, UPDATE =====
-- tu nie trzeba zmieniac danych, tylko odrzucac zle wiersze, wiec wystarczy AFTER:
-- wiersze sa juz w tabeli, a THROW wycofuje polecenie.
-- AFTER uruchamia sie PO sprawdzeniu ograniczen - nieistniejacy profil czy telewizor
-- odrzuci wczesniej klucz obcy, wiec wyzwalacz nie musi tego obslugiwac.
-- UPDATE(kolumna) = czy kolumna byla w SET polecenia UPDATE (przy INSERT zawsze prawda)
-- - odpowiednik "UPDATE OF profil_id, urzadzenie_id, tresc_id" z PostgreSQL.
-- nazwa inna niz w PG (po_zapisie zamiast przed_zapisem), bo to wyzwalacz AFTER

DROP TRIGGER IF EXISTS streamos.trg_sesja_przed_zapisem;
GO

CREATE OR ALTER TRIGGER streamos.trg_sesja_po_zapisie
ON streamos.sesja_ogladania
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT (UPDATE(profil_id) OR UPDATE(urzadzenie_id) OR UPDATE(tresc_id)) RETURN;

    DECLARE @komunikat NVARCHAR(400);

    -- a) profil i telewizor z tego samego konta (telewizor nieaktywowany ma konto NULL)
    -- CONCAT zamienia NULL na pusty tekst, stad COALESCE, zeby w komunikacie bylo widac NULL
    SELECT TOP 1 @komunikat = CONCAT('sesja: profil ', i.profil_id, ' (konto ', p.konto_id, ') i telewizor ',
                                     i.urzadzenie_id, ' (konto ', COALESCE(CAST(u.konto_id AS VARCHAR(10)), 'NULL'),
                                     ') nie naleza do tego samego konta')
    FROM inserted i
    JOIN streamos.profil p     ON p.profil_id = i.profil_id
    JOIN streamos.urzadzenie u ON u.urzadzenie_id = i.urzadzenie_id
    WHERE u.konto_id IS NULL OR u.konto_id <> p.konto_id;
    IF @komunikat IS NOT NULL THROW 50201, @komunikat, 1;

    -- b) profil dzieciecy tylko tresci do swojego limitu (porownanie po minimalny_wiek)
    SELECT TOP 1 @komunikat = CONCAT('sesja: profil dzieciecy ', i.profil_id, ' ma limit ', kp.minimalny_wiek,
                                     '+, a tresc ', i.tresc_id, ' jest ', kt.minimalny_wiek, '+')
    FROM inserted i
    JOIN streamos.profil p             ON p.profil_id = i.profil_id
    JOIN streamos.kategoria_wiekowa kp ON kp.kategoria_wiekowa_id = p.kategoria_wiekowa_id
    JOIN streamos.tresc t              ON t.tresc_id = i.tresc_id
    JOIN streamos.kategoria_wiekowa kt ON kt.kategoria_wiekowa_id = t.kategoria_wiekowa_id
    WHERE p.czy_dzieciecy = 1 AND kt.minimalny_wiek > kp.minimalny_wiek;
    IF @komunikat IS NOT NULL THROW 50202, @komunikat, 1;
END;
GO


-- ===== kontrola =====
SELECT t.name AS wyzwalacz, OBJECT_NAME(t.parent_id) AS tabela,
       CASE WHEN t.is_instead_of_trigger = 1 THEN 'INSTEAD OF' ELSE 'AFTER' END AS rodzaj,
       STRING_AGG(te.type_desc, ', ') AS zdarzenia
FROM sys.triggers t
JOIN sys.trigger_events te ON te.object_id = t.object_id
WHERE OBJECT_SCHEMA_NAME(t.parent_id) = 'streamos'
GROUP BY t.name, t.parent_id, t.is_instead_of_trigger;
-- oczekiwane: trg_emisja_przed_dodaniem - emisja_reklamy - INSTEAD OF - INSERT
--             trg_sesja_po_zapisie      - sesja_ogladania - AFTER - INSERT, UPDATE
