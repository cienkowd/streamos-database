-- StreamOS - etap 2, pkt 10, czesc 1: funkcje i procedury w MS SQL Server
-- odpowiedniki: 07 (pozostaly_budzet, dodaj_konto, aktywuj_urzadzenie),
--               08 (dodaj_kampanie), 10 (rozliczenie_partnerow)
-- uruchamiac w DBeaverze na polaczeniu SQL Server, baza streamos, calosc (Alt+X)
--
-- GO = koniec paczki (batch). W T-SQL CREATE FUNCTION / PROCEDURE / TYPE musi byc
-- jedynym poleceniem w paczce, dlatego kazdy obiekt jest oddzielony GO.
-- CREATE OR ALTER = odpowiednik CREATE OR REPLACE (od SQL Server 2016 SP1)
--
-- roznice wobec PostgreSQL, ktore zmienily kod:
--   - brak search_path: wszystkie nazwy z prefiksem schematu streamos.
--   - procedura NIE dziala sama w transakcji: bez BEGIN TRAN kazdy INSERT
--     zatwierdza sie osobno, wiec atomowosc trzeba zapewnic jawnie
--   - brak tablic (INT[]): listy przekazywane jako parametr tabelaryczny (typ lista_id)
--   - nowe funkcje i procedury NIE sa dostepne dla wszystkich (w PostgreSQL EXECUTE
--     mial PUBLIC), wiec REVOKE nie jest potrzebny

USE streamos;
GO


-- ===== 1. funkcja pozostaly_budzet =====
-- RETURNS NUMERIC(14,4), a nie samo NUMERIC: w T-SQL NUMERIC bez precyzji to NUMERIC(18,0),
-- czyli liczba calkowita - funkcja obcinalaby grosze
-- nieistniejaca kampania -> podzapytanie bez wiersza -> NULL, jak w PostgreSQL

CREATE OR ALTER FUNCTION streamos.pozostaly_budzet (@p_kampania_id INT)
RETURNS NUMERIC(14,4)
AS
BEGIN
    RETURN (
        SELECT k.budzet - COALESCE((SELECT SUM(e.koszt)
                                    FROM streamos.emisja_reklamy e
                                    WHERE e.kampania_id = @p_kampania_id), 0)
        FROM streamos.kampania k
        WHERE k.kampania_id = @p_kampania_id
    );
END;
GO


-- ===== 2. funkcja rozliczenie_partnerow =====
-- funkcja tabelaryczna "inline" (RETURNS TABLE AS RETURN jedno zapytanie) -
-- odpowiednik RETURNS TABLE z PostgreSQL; optymalizator wkleja ja do zapytania jak perspektywe
--
-- roznice:
--   - wartosc domyslna parametru w T-SQL musi byc stala (nie da sie wpisac "poprzedni miesiac")
--     i i tak trzeba ja jawnie podac slowem DEFAULT; dlatego NULL = poprzedni miesiac
--   - w funkcji inline nie wolno ORDER BY - sortuje wywolujacy
--   - granice miesiaca: DATE porownany z DATETIMEOFFSET zostalby zamieniony na polnoc UTC,
--     a PostgreSQL liczyl polnoc w strefie sesji (Europe/Warsaw). AT TIME ZONE daje polnoc
--     czasu polskiego, wiec wyniki sa takie same jak w PostgreSQL

CREATE OR ALTER FUNCTION streamos.rozliczenie_partnerow (@p_miesiac DATE)
RETURNS TABLE
AS
RETURN (
    WITH zakres AS (
        SELECT CAST(m.od AS DATETIME2) AT TIME ZONE 'Central European Standard Time'                    AS od,
               CAST(DATEADD(MONTH, 1, m.od) AS DATETIME2) AT TIME ZONE 'Central European Standard Time' AS do_
        FROM (SELECT DATEFROMPARTS(YEAR(d.dzien), MONTH(d.dzien), 1) AS od
              FROM (SELECT COALESCE(@p_miesiac, DATEADD(MONTH, -1, CAST(GETDATE() AS DATE))) AS dzien) d) m
    )
    SELECT p.nazwa                                                     AS partner,
           COUNT(e.emisja_id)                                          AS liczba_emisji,
           COALESCE(ROUND(SUM(e.koszt), 2), 0)                         AS przychod_z_reklam,
           p.udzial_procent                                            AS udzial_proc,
           COALESCE(ROUND(SUM(e.koszt) * p.udzial_procent / 100, 2), 0) AS nalezne_partnerowi
    FROM streamos.partner_oem p
    CROSS JOIN zakres z
    LEFT JOIN streamos.urzadzenie u     ON u.partner_id = p.partner_id
    LEFT JOIN streamos.emisja_reklamy e ON e.urzadzenie_id = u.urzadzenie_id
                                       AND e.czas_emisji >= z.od
                                       AND e.czas_emisji <  z.do_
    GROUP BY p.partner_id, p.nazwa, p.udzial_procent
);
GO


-- ===== 3. procedura dodaj_konto =====
-- OUTPUT = parametr wyjsciowy (odpowiednik OUT)
-- SCOPE_IDENTITY() = ostatnie id z IDENTITY wstawione w tym zakresie (odpowiednik RETURNING)
--
-- transakcja: BEGIN TRAN ... COMMIT jawnie, bo bez tego konto zostaloby zapisane,
-- nawet gdyby INSERT profilu sie nie udal
-- SET XACT_ABORT ON: kazdy blad przerywa i wycofuje cala transakcje (bez tego niektore
--   bledy przerywaja tylko jedno polecenie, a transakcja dziala dalej)
-- TRY/CATCH + THROW: wycofanie i ponowne zgloszenie oryginalnego bledu (jak RAISE w PL/pgSQL)
-- SET NOCOUNT ON: bez komunikatow "1 row affected" po kazdym poleceniu

CREATE OR ALTER PROCEDURE streamos.dodaj_konto
    @p_email         VARCHAR(254),
    @p_region_id     INT,
    @p_nazwa_profilu VARCHAR(50),
    @p_konto_id      INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO streamos.konto (email, region_id)
        VALUES (LOWER(TRIM(@p_email)), @p_region_id);

        SET @p_konto_id = SCOPE_IDENTITY();

        INSERT INTO streamos.profil (konto_id, nazwa, czy_dzieciecy, kategoria_wiekowa_id)
        VALUES (@p_konto_id, @p_nazwa_profilu, 0, NULL);

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH
END;
GO


-- ===== 4. procedura aktywuj_urzadzenie =====
-- @@ROWCOUNT = liczba wierszy zmienionych przez ostatnie polecenie (odpowiednik FOUND);
--   trzeba go odczytac od razu po UPDATE, kazde kolejne polecenie go nadpisuje
-- THROW numer, komunikat, stan: wlasny blad (numery od 50000 sa dla uzytkownika);
--   komunikat musi byc gotowa zmienna albo tekstem - THROW nie przyjmuje wyrazen
-- jedno polecenie UPDATE jest atomowe samo w sobie, wiec BEGIN TRAN nie jest potrzebny;
-- warunek "konto_id IS NULL" w UPDATE chroni przed dwiema rownoczesnymi aktywacjami, jak w PG
-- SET XACT_ABORT ON: bez niego blad klucza obcego (nieistniejace konto) przerywa tylko UPDATE,
--   a procedura idzie dalej: @@ROWCOUNT = 0 -> mylacy drugi blad "jest juz aktywowane".
--   Z XACT_ABORT pierwszy blad konczy procedure, tak jak w PL/pgSQL.

CREATE OR ALTER PROCEDURE streamos.aktywuj_urzadzenie
    @p_numer_seryjny VARCHAR(32),
    @p_konto_id      INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @komunikat NVARCHAR(200);

    UPDATE streamos.urzadzenie
    SET konto_id = @p_konto_id
    WHERE numer_seryjny = @p_numer_seryjny
      AND konto_id IS NULL;

    IF @@ROWCOUNT = 0
    BEGIN
        IF EXISTS (SELECT 1 FROM streamos.urzadzenie WHERE numer_seryjny = @p_numer_seryjny)
            SET @komunikat = CONCAT('Urzadzenie ', @p_numer_seryjny, ' jest juz aktywowane');
        ELSE
            SET @komunikat = CONCAT('Nie ma urzadzenia o numerze ', @p_numer_seryjny);

        THROW 50001, @komunikat, 1;
    END
END;
GO


-- ===== 5. typ lista_id (zamiast INT[]) =====
-- typ tabelaryczny: parametr procedury bedacy mala tabela z jedna kolumna id.
-- NULL dozwolony celowo - zeby procedura mogla go wykryc i zglosic czytelny blad
-- (typu nie da sie zmienic, gdy uzywa go procedura - stad usuniecie procedury przed typem)

DROP PROCEDURE IF EXISTS streamos.dodaj_kampanie;
GO
DROP TYPE IF EXISTS streamos.lista_id;
GO
CREATE TYPE streamos.lista_id AS TABLE (id INT NULL);
GO


-- ===== 6. procedura dodaj_kampanie =====
-- parametry tabelaryczne musza byc READONLY (tylko do odczytu)
--
-- obsluga bledow:
--   - walidacja przed transakcja: wlasne bledy 50001-50006
--   - bledy ograniczen w CATCH: T-SQL nie ma GET STACKED DIAGNOSTICS CONSTRAINT_NAME,
--     nazwa ograniczenia jest tylko w tresci komunikatu, wiec szukamy jej przez LIKE.
--     FK i CHECK maja ten sam numer bledu 547, dlatego nie da sie ich rozroznic po numerze
--   - THROW z wlasnym numerem 50010: w T-SQL wlasny komunikat mozna rzucic tylko z
--     numerem >= 50000, oryginalny numer (547/515) jest zachowany w tresci przy ELSE

CREATE OR ALTER PROCEDURE streamos.dodaj_kampanie
    @p_reklamodawca_id INT,
    @p_nazwa           VARCHAR(150),
    @p_budzet          NUMERIC(12,2),
    @p_stawka          NUMERIC(8,4),
    @p_data_od         DATE,
    @p_data_do         DATE,
    @p_limit_dzienny   INT,
    @p_regiony         streamos.lista_id READONLY,
    @p_gatunki         streamos.lista_id READONLY,
    @p_kampania_id     INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @komunikat NVARCHAR(4000);

    -- ===== walidacja regul spoza schematu =====
    IF @p_data_od IS NULL OR @p_data_do IS NULL
        THROW 50001, 'dodaj_kampanie: obie daty sa wymagane', 1;

    IF @p_data_od > @p_data_do
    BEGIN
        SET @komunikat = CONCAT('dodaj_kampanie: data_od (', @p_data_od, ') jest pozniejsza niz data_do (', @p_data_do, ')');
        THROW 50002, @komunikat, 1;
    END

    IF @p_data_od < CAST(GETDATE() AS DATE)
    BEGIN
        SET @komunikat = CONCAT('dodaj_kampanie: kampania nie moze zaczynac sie w przeszlosci (', @p_data_od, ')');
        THROW 50003, @komunikat, 1;
    END

    IF @p_limit_dzienny IS NULL OR @p_limit_dzienny < 1
        THROW 50004, 'dodaj_kampanie: limit dzienny musi byc co najmniej 1', 1;

    IF NOT EXISTS (SELECT 1 FROM @p_regiony) OR EXISTS (SELECT 1 FROM @p_regiony WHERE id IS NULL)
        THROW 50005, 'dodaj_kampanie: lista regionow nie moze byc pusta ani zawierac NULL', 1;

    IF NOT EXISTS (SELECT 1 FROM @p_gatunki) OR EXISTS (SELECT 1 FROM @p_gatunki WHERE id IS NULL)
        THROW 50006, 'dodaj_kampanie: lista gatunkow nie moze byc pusta ani zawierac NULL', 1;

    -- ===== zapis do trzech tabel w jednej transakcji =====
    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO streamos.kampania (reklamodawca_id, nazwa, budzet, stawka, data_od, data_do, status, limit_dzienny)
        VALUES (@p_reklamodawca_id, @p_nazwa, @p_budzet, @p_stawka, @p_data_od, @p_data_do, 'aktywna', @p_limit_dzienny);

        SET @p_kampania_id = SCOPE_IDENTITY();

        INSERT INTO streamos.kampania_region (kampania_id, region_id)
        SELECT DISTINCT @p_kampania_id, id FROM @p_regiony;

        INSERT INTO streamos.kampania_gatunek (kampania_id, gatunek_id)
        SELECT DISTINCT @p_kampania_id, id FROM @p_gatunki;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;

        SET @komunikat = ERROR_MESSAGE();
        SET @komunikat = CONCAT('dodaj_kampanie: ',
            CASE
                WHEN @komunikat LIKE '%kampania_reklamodawca_id_fkey%'    THEN CONCAT('nie istnieje reklamodawca o id ', @p_reklamodawca_id)
                WHEN @komunikat LIKE '%kampania_region_region_id_fkey%'   THEN 'na liscie regionow jest nieistniejacy region'
                WHEN @komunikat LIKE '%kampania_gatunek_gatunek_id_fkey%' THEN 'na liscie gatunkow jest nieistniejacy gatunek'
                WHEN @komunikat LIKE '%kampania_budzet_check%'            THEN 'budzet musi byc wiekszy od 0'
                WHEN @komunikat LIKE '%kampania_stawka_check%'            THEN 'stawka musi byc wieksza od 0'
                ELSE CONCAT(@komunikat, ' (blad ', ERROR_NUMBER(), ')')
            END);

        THROW 50010, @komunikat, 1;
    END CATCH

    -- PRINT = odpowiednik RAISE NOTICE (w DBeaverze: zakladka Output)
    PRINT CONCAT('Dodano kampanie ', @p_kampania_id);
END;
GO


-- ===== kontrola =====
SELECT name AS obiekt, type_desc AS typ
FROM sys.objects
WHERE schema_id = SCHEMA_ID('streamos') AND type IN ('FN', 'IF', 'P')
ORDER BY name;
-- oczekiwane: aktywuj_urzadzenie, dodaj_kampanie, dodaj_konto (SQL_STORED_PROCEDURE),
-- pozostaly_budzet (SQL_SCALAR_FUNCTION), rozliczenie_partnerow (SQL_INLINE_TABLE_VALUED_FUNCTION)
