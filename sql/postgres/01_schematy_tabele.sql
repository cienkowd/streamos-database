-- StreamOS - etap 1, pkt 5
-- tworzenie schematu i tabel (PostgreSQL 18)

-- reset (kasuje wszystko!):
-- DROP SCHEMA IF EXISTS streamos CASCADE;

CREATE SCHEMA streamos;
SET search_path TO streamos;


-- ===== slowniki =====

CREATE TABLE region (
    region_id SERIAL PRIMARY KEY,
    nazwa     VARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE gatunek (
    gatunek_id SERIAL PRIMARY KEY,
    nazwa      VARCHAR(50) NOT NULL UNIQUE
);

CREATE TABLE kategoria_wiekowa (
    kategoria_wiekowa_id SERIAL PRIMARY KEY,
    nazwa                VARCHAR(10) NOT NULL UNIQUE,  -- np. 7+, 12+, 18+
    minimalny_wiek       INT NOT NULL UNIQUE
);

CREATE TABLE kategoria_branzowa (
    kategoria_branzowa_id SERIAL PRIMARY KEY,
    nazwa                 VARCHAR(100) NOT NULL UNIQUE,
    dozwolona_dla_dzieci  BOOLEAN NOT NULL DEFAULT true
);


-- ===== encje =====

CREATE TABLE partner_oem (
    partner_id     SERIAL PRIMARY KEY,
    nazwa          VARCHAR(150) NOT NULL UNIQUE,
    udzial_procent NUMERIC(5,2) NOT NULL CHECK (udzial_procent BETWEEN 0 AND 100)
);

CREATE TABLE konto (
    konto_id         SERIAL PRIMARY KEY,
    email            VARCHAR(254) NOT NULL UNIQUE,
    region_id        INT NOT NULL REFERENCES region(region_id),
    data_rejestracji TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE profil (
    profil_id            SERIAL PRIMARY KEY,
    konto_id             INT NOT NULL REFERENCES konto(konto_id),
    nazwa                VARCHAR(50) NOT NULL,
    czy_dzieciecy        BOOLEAN NOT NULL DEFAULT false,
    kategoria_wiekowa_id INT REFERENCES kategoria_wiekowa(kategoria_wiekowa_id)  -- limit dla dzieci
);

-- konto_id NULL = telewizor jeszcze nieaktywowany
CREATE TABLE urzadzenie (
    urzadzenie_id SERIAL PRIMARY KEY,
    numer_seryjny VARCHAR(32) NOT NULL UNIQUE,
    partner_id    INT NOT NULL REFERENCES partner_oem(partner_id),
    konto_id      INT REFERENCES konto(konto_id)
);

CREATE TABLE tresc (
    tresc_id             SERIAL PRIMARY KEY,
    tytul                VARCHAR(200) NOT NULL,
    typ                  VARCHAR(20) NOT NULL CHECK (typ IN ('film', 'odcinek', 'program')),
    kategoria_wiekowa_id INT NOT NULL REFERENCES kategoria_wiekowa(kategoria_wiekowa_id)
);

-- tresc moze miec kilka gatunkow (n:m)
CREATE TABLE tresc_gatunek (
    tresc_id   INT REFERENCES tresc(tresc_id),
    gatunek_id INT REFERENCES gatunek(gatunek_id),
    PRIMARY KEY (tresc_id, gatunek_id)
);

-- duza tabela zdarzen
CREATE TABLE sesja_ogladania (
    sesja_id      BIGSERIAL PRIMARY KEY,
    profil_id     INT NOT NULL REFERENCES profil(profil_id),
    urzadzenie_id INT NOT NULL REFERENCES urzadzenie(urzadzenie_id),
    tresc_id      INT NOT NULL REFERENCES tresc(tresc_id),
    czas_start    TIMESTAMPTZ NOT NULL,
    czas_koniec   TIMESTAMPTZ
);

CREATE TABLE reklamodawca (
    reklamodawca_id       SERIAL PRIMARY KEY,
    nazwa                 VARCHAR(150) NOT NULL UNIQUE,
    kategoria_branzowa_id INT NOT NULL REFERENCES kategoria_branzowa(kategoria_branzowa_id)
);

CREATE TABLE kampania (
    kampania_id     SERIAL PRIMARY KEY,
    reklamodawca_id INT NOT NULL REFERENCES reklamodawca(reklamodawca_id),
    nazwa           VARCHAR(150) NOT NULL,
    budzet          NUMERIC(12,2) NOT NULL CHECK (budzet > 0),
    stawka          NUMERIC(8,4) NOT NULL CHECK (stawka > 0),
    data_od         DATE NOT NULL,
    data_do         DATE NOT NULL,
    status          VARCHAR(20) NOT NULL CHECK (status IN ('aktywna', 'zakonczona')),
    limit_dzienny   INT NOT NULL DEFAULT 3
);

-- kampania skierowana do kilku regionow (n:m)
CREATE TABLE kampania_region (
    kampania_id INT REFERENCES kampania(kampania_id),
    region_id   INT REFERENCES region(region_id),
    PRIMARY KEY (kampania_id, region_id)
);

-- kampania skierowana do kilku gatunkow tresci (n:m)
CREATE TABLE kampania_gatunek (
    kampania_id INT REFERENCES kampania(kampania_id),
    gatunek_id  INT REFERENCES gatunek(gatunek_id),
    PRIMARY KEY (kampania_id, gatunek_id)
);

-- duza tabela zdarzen nr 2, sesja_id NULL = ekran glowny
-- koszt zapisany w momencie emisji
CREATE TABLE emisja_reklamy (
    emisja_id     BIGSERIAL PRIMARY KEY,
    kampania_id   INT NOT NULL REFERENCES kampania(kampania_id),
    urzadzenie_id INT NOT NULL REFERENCES urzadzenie(urzadzenie_id),
    sesja_id      BIGINT REFERENCES sesja_ogladania(sesja_id),
    czas_emisji   TIMESTAMPTZ NOT NULL,
    koszt         NUMERIC(8,4) NOT NULL
);


-- sprawdzenie
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'streamos' ORDER BY table_name;
