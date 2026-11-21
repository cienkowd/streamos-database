-- StreamOS - etap 2, pkt 9: struktura bazy w MS SQL Server 2022 (T-SQL)
-- uruchamiac w DBeaverze na polaczeniu SQL Server, baza streamos, calosc (Alt+X)
--
-- ten skrypt: schemat, tabele, klucze glowne, UNIQUE, DEFAULT, NOT NULL
-- 12b (po zaladowaniu danych): klucze obce, CHECK, indeksy
-- powod podzialu: bez kluczy obcych kolejnosc ladowania tabel nie ma znaczenia,
-- a dodanie ograniczen na koncu sprawdza od razu wszystkie przeniesione dane

USE streamos;

-- CREATE SCHEMA musi byc jedynym poleceniem w swojej paczce (batch), wiec nie da sie go
-- napisac w IF. EXEC uruchamia go jako osobna paczke - dzieki temu nie trzeba GO
IF SCHEMA_ID('streamos') IS NULL
    EXEC('CREATE SCHEMA streamos');


-- ===== reset (ponowne uruchomienie): tabele podrzedne przed nadrzednymi =====
DROP TABLE IF EXISTS streamos.dziennik_zadan;
DROP TABLE IF EXISTS streamos.rozliczenie_dzienne;
DROP TABLE IF EXISTS streamos.emisja_reklamy;
DROP TABLE IF EXISTS streamos.kampania_gatunek;
DROP TABLE IF EXISTS streamos.kampania_region;
DROP TABLE IF EXISTS streamos.kampania;
DROP TABLE IF EXISTS streamos.reklamodawca;
DROP TABLE IF EXISTS streamos.sesja_ogladania;
DROP TABLE IF EXISTS streamos.tresc_gatunek;
DROP TABLE IF EXISTS streamos.tresc;
DROP TABLE IF EXISTS streamos.urzadzenie;
DROP TABLE IF EXISTS streamos.profil;
DROP TABLE IF EXISTS streamos.konto;
DROP TABLE IF EXISTS streamos.partner_oem;
DROP TABLE IF EXISTS streamos.kategoria_branzowa;
DROP TABLE IF EXISTS streamos.kategoria_wiekowa;
DROP TABLE IF EXISTS streamos.gatunek;
DROP TABLE IF EXISTS streamos.region;


-- zamiany typow wzgledem PostgreSQL:
--   SERIAL / BIGSERIAL -> INT / BIGINT IDENTITY(1,1)
--   BOOLEAN            -> BIT (0/1), DEFAULT true -> DEFAULT 1
--   TIMESTAMPTZ        -> DATETIMEOFFSET (czas razem z przesunieciem strefy)
--   now()              -> SYSDATETIMEOFFSET()
--   TEXT               -> VARCHAR(MAX)
-- nazwy ograniczen takie jak w PostgreSQL (np. kampania_budzet_check) - procedura
-- dodaj_kampanie rozpoznaje bledy po nazwie ograniczenia, wiec to sie przyda przy jej przenoszeniu


-- ===== slowniki =====

CREATE TABLE streamos.region (
    region_id INT IDENTITY(1,1) CONSTRAINT region_pkey PRIMARY KEY,
    nazwa     VARCHAR(100) NOT NULL CONSTRAINT region_nazwa_key UNIQUE
);

CREATE TABLE streamos.gatunek (
    gatunek_id INT IDENTITY(1,1) CONSTRAINT gatunek_pkey PRIMARY KEY,
    nazwa      VARCHAR(50) NOT NULL CONSTRAINT gatunek_nazwa_key UNIQUE
);

CREATE TABLE streamos.kategoria_wiekowa (
    kategoria_wiekowa_id INT IDENTITY(1,1) CONSTRAINT kategoria_wiekowa_pkey PRIMARY KEY,
    nazwa                VARCHAR(10) NOT NULL CONSTRAINT kategoria_wiekowa_nazwa_key UNIQUE,
    minimalny_wiek       INT NOT NULL CONSTRAINT kategoria_wiekowa_minimalny_wiek_key UNIQUE
);

CREATE TABLE streamos.kategoria_branzowa (
    kategoria_branzowa_id INT IDENTITY(1,1) CONSTRAINT kategoria_branzowa_pkey PRIMARY KEY,
    nazwa                 VARCHAR(100) NOT NULL CONSTRAINT kategoria_branzowa_nazwa_key UNIQUE,
    dozwolona_dla_dzieci  BIT NOT NULL CONSTRAINT kategoria_branzowa_dozwolona_df DEFAULT 1
);


-- ===== encje =====

CREATE TABLE streamos.partner_oem (
    partner_id     INT IDENTITY(1,1) CONSTRAINT partner_oem_pkey PRIMARY KEY,
    nazwa          VARCHAR(150) NOT NULL CONSTRAINT partner_oem_nazwa_key UNIQUE,
    udzial_procent NUMERIC(5,2) NOT NULL,
    login_bazy     VARCHAR(63) NULL                 -- z etapu 1, pkt 7 (unikalnosc nizej)
);

CREATE TABLE streamos.konto (
    konto_id         INT IDENTITY(1,1) CONSTRAINT konto_pkey PRIMARY KEY,
    email            VARCHAR(254) NOT NULL CONSTRAINT konto_email_key UNIQUE,
    region_id        INT NOT NULL,
    data_rejestracji DATETIMEOFFSET NOT NULL CONSTRAINT konto_data_rejestracji_df DEFAULT SYSDATETIMEOFFSET()
);

CREATE TABLE streamos.profil (
    profil_id            INT IDENTITY(1,1) CONSTRAINT profil_pkey PRIMARY KEY,
    konto_id             INT NOT NULL,
    nazwa                VARCHAR(50) NOT NULL,
    czy_dzieciecy        BIT NOT NULL CONSTRAINT profil_czy_dzieciecy_df DEFAULT 0,
    kategoria_wiekowa_id INT NULL
);

CREATE TABLE streamos.urzadzenie (
    urzadzenie_id INT IDENTITY(1,1) CONSTRAINT urzadzenie_pkey PRIMARY KEY,
    numer_seryjny VARCHAR(32) NOT NULL CONSTRAINT urzadzenie_numer_seryjny_key UNIQUE,
    partner_id    INT NOT NULL,
    konto_id      INT NULL                          -- NULL = telewizor nieaktywowany
);

CREATE TABLE streamos.tresc (
    tresc_id             INT IDENTITY(1,1) CONSTRAINT tresc_pkey PRIMARY KEY,
    tytul                VARCHAR(200) NOT NULL,
    typ                  VARCHAR(20) NOT NULL,
    kategoria_wiekowa_id INT NOT NULL
);

CREATE TABLE streamos.tresc_gatunek (
    tresc_id   INT NOT NULL,
    gatunek_id INT NOT NULL,
    CONSTRAINT tresc_gatunek_pkey PRIMARY KEY (tresc_id, gatunek_id)
);

CREATE TABLE streamos.sesja_ogladania (
    sesja_id      BIGINT IDENTITY(1,1) CONSTRAINT sesja_ogladania_pkey PRIMARY KEY,
    profil_id     INT NOT NULL,
    urzadzenie_id INT NOT NULL,
    tresc_id      INT NOT NULL,
    czas_start    DATETIMEOFFSET NOT NULL,
    czas_koniec   DATETIMEOFFSET NULL
);

CREATE TABLE streamos.reklamodawca (
    reklamodawca_id       INT IDENTITY(1,1) CONSTRAINT reklamodawca_pkey PRIMARY KEY,
    nazwa                 VARCHAR(150) NOT NULL CONSTRAINT reklamodawca_nazwa_key UNIQUE,
    kategoria_branzowa_id INT NOT NULL,
    login_bazy            VARCHAR(63) NULL
);

CREATE TABLE streamos.kampania (
    kampania_id     INT IDENTITY(1,1) CONSTRAINT kampania_pkey PRIMARY KEY,
    reklamodawca_id INT NOT NULL,
    nazwa           VARCHAR(150) NOT NULL,
    budzet          NUMERIC(12,2) NOT NULL,
    stawka          NUMERIC(8,4) NOT NULL,
    data_od         DATE NOT NULL,
    data_do         DATE NOT NULL,
    status          VARCHAR(20) NOT NULL,
    limit_dzienny   INT NOT NULL CONSTRAINT kampania_limit_dzienny_df DEFAULT 3
);

CREATE TABLE streamos.kampania_region (
    kampania_id INT NOT NULL,
    region_id   INT NOT NULL,
    CONSTRAINT kampania_region_pkey PRIMARY KEY (kampania_id, region_id)
);

CREATE TABLE streamos.kampania_gatunek (
    kampania_id INT NOT NULL,
    gatunek_id  INT NOT NULL,
    CONSTRAINT kampania_gatunek_pkey PRIMARY KEY (kampania_id, gatunek_id)
);

CREATE TABLE streamos.emisja_reklamy (
    emisja_id     BIGINT IDENTITY(1,1) CONSTRAINT emisja_reklamy_pkey PRIMARY KEY,
    kampania_id   INT NOT NULL,
    urzadzenie_id INT NOT NULL,
    sesja_id      BIGINT NULL,                      -- NULL = ekran glowny
    czas_emisji   DATETIMEOFFSET NOT NULL,
    koszt         NUMERIC(8,4) NOT NULL
);


-- ===== tabele zadania dobowego (pkt 6) =====

CREATE TABLE streamos.dziennik_zadan (
    wpis_id   BIGINT IDENTITY(1,1) CONSTRAINT dziennik_zadan_pkey PRIMARY KEY,
    zadanie   VARCHAR(50) NOT NULL,
    krok      VARCHAR(50) NOT NULL,
    start     DATETIMEOFFSET NOT NULL,
    koniec    DATETIMEOFFSET NOT NULL,
    status    VARCHAR(4) NOT NULL,
    wiersze   INT NULL,
    komunikat VARCHAR(MAX) NULL
);

CREATE TABLE streamos.rozliczenie_dzienne (
    dzien           DATE NOT NULL,
    partner_id      INT NOT NULL,
    liczba_emisji   INT NOT NULL,
    przychod        NUMERIC(14,4) NOT NULL,
    nalezne         NUMERIC(14,4) NOT NULL,
    data_wyliczenia DATETIMEOFFSET NOT NULL CONSTRAINT rozliczenie_dzienne_data_wyliczenia_df DEFAULT SYSDATETIMEOFFSET(),
    CONSTRAINT rozliczenie_dzienne_pkey PRIMARY KEY (dzien, partner_id)
);


-- ===== unikalnosc login_bazy =====
-- w SQL Serverze ograniczenie UNIQUE dopuszcza tylko JEDEN wiersz z NULL
-- (w PostgreSQL dowolnie wiele). Login ma tylko kilka firm, reszta ma NULL,
-- wiec zwykly UNIQUE odrzucilby dane. Indeks filtrowany (WHERE) pilnuje
-- unikalnosci tylko wsrod wierszy z wpisanym loginem.
CREATE UNIQUE INDEX reklamodawca_login_bazy_key ON streamos.reklamodawca (login_bazy) WHERE login_bazy IS NOT NULL;
CREATE UNIQUE INDEX partner_oem_login_bazy_key  ON streamos.partner_oem  (login_bazy) WHERE login_bazy IS NOT NULL;


-- ===== kontrola =====
SELECT t.name AS tabela,
       (SELECT count(*) FROM sys.columns c WHERE c.object_id = t.object_id) AS kolumny,
       OBJECTPROPERTY(t.object_id, 'TableHasIdentity') AS ma_identity
FROM sys.tables t
WHERE t.schema_id = SCHEMA_ID('streamos')
ORDER BY t.name;
-- oczekiwane: 18 tabel; ma_identity = 1 wszedzie poza tabelami asocjacyjnymi i rozliczenie_dzienne
