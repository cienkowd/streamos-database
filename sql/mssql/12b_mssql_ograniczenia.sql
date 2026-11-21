-- StreamOS - etap 2, pkt 9: ograniczenia i indeksy w MS SQL Server - PO zaladowaniu danych
-- uruchamiac w DBeaverze na polaczeniu SQL Server, baza streamos, calosc (Alt+X)
--
-- ADD CONSTRAINT domyslnie dziala jak WITH CHECK: sprawdza wszystkie istniejace wiersze.
-- jesli migracja zgubila albo przesunela jakies id, polecenie sie nie wykona
-- i od razu wiadomo, ktora relacja sie nie zgadza.
-- (WITH NOCHECK pominalby sprawdzenie, ale ograniczenie byloby wtedy "niezaufane"
--  - SQL Server nie uzywa go przy optymalizacji zapytan i nie gwarantuje poprawnosci danych)

USE streamos;


-- ===== 1. CHECK =====

-- z etapu 1 (01_schematy_tabele.sql)
ALTER TABLE streamos.partner_oem ADD CONSTRAINT partner_oem_udzial_procent_check CHECK (udzial_procent BETWEEN 0 AND 100);
ALTER TABLE streamos.tresc       ADD CONSTRAINT tresc_typ_check                  CHECK (typ IN ('film', 'odcinek', 'program'));
ALTER TABLE streamos.kampania    ADD CONSTRAINT kampania_budzet_check            CHECK (budzet > 0);
ALTER TABLE streamos.kampania    ADD CONSTRAINT kampania_stawka_check            CHECK (stawka > 0);
ALTER TABLE streamos.kampania    ADD CONSTRAINT kampania_status_check            CHECK (status IN ('aktywna', 'zakonczona'));

-- z pkt 4 (10_reguly_sesje_rozliczenie.sql)
ALTER TABLE streamos.kampania        ADD CONSTRAINT kampania_daty_check CHECK (data_od <= data_do);
ALTER TABLE streamos.sesja_ogladania ADD CONSTRAINT sesja_czas_check    CHECK (czas_koniec >= czas_start);
-- jak w PostgreSQL: CHECK odrzuca tylko wynik FALSE, a NULL (trwajaca sesja) przechodzi

-- w PostgreSQL: CHECK (czy_dzieciecy = (kategoria_wiekowa_id IS NOT NULL))
-- T-SQL nie ma typu logicznego w wyrazeniach: "IS NOT NULL" nie zwraca wartosci,
-- ktora mozna porownac z kolumna BIT, wiec oba przypadki sa rozpisane osobno
ALTER TABLE streamos.profil ADD CONSTRAINT profil_dzieciecy_check
    CHECK ((czy_dzieciecy = 1 AND kategoria_wiekowa_id IS NOT NULL)
        OR (czy_dzieciecy = 0 AND kategoria_wiekowa_id IS NULL));

-- z pkt 6 (11_automatyzacja.sql)
ALTER TABLE streamos.dziennik_zadan ADD CONSTRAINT dziennik_zadan_status_check CHECK (status IN ('OK', 'BLAD'));


-- ===== 2. klucze obce =====
-- nazwy jak nadal PostgreSQL: tabela_kolumna_fkey

ALTER TABLE streamos.konto           ADD CONSTRAINT konto_region_id_fkey                    FOREIGN KEY (region_id)             REFERENCES streamos.region (region_id);
ALTER TABLE streamos.profil          ADD CONSTRAINT profil_konto_id_fkey                    FOREIGN KEY (konto_id)              REFERENCES streamos.konto (konto_id);
ALTER TABLE streamos.profil          ADD CONSTRAINT profil_kategoria_wiekowa_id_fkey        FOREIGN KEY (kategoria_wiekowa_id)  REFERENCES streamos.kategoria_wiekowa (kategoria_wiekowa_id);
ALTER TABLE streamos.urzadzenie      ADD CONSTRAINT urzadzenie_partner_id_fkey              FOREIGN KEY (partner_id)            REFERENCES streamos.partner_oem (partner_id);
ALTER TABLE streamos.urzadzenie      ADD CONSTRAINT urzadzenie_konto_id_fkey                FOREIGN KEY (konto_id)              REFERENCES streamos.konto (konto_id);
ALTER TABLE streamos.tresc           ADD CONSTRAINT tresc_kategoria_wiekowa_id_fkey         FOREIGN KEY (kategoria_wiekowa_id)  REFERENCES streamos.kategoria_wiekowa (kategoria_wiekowa_id);
ALTER TABLE streamos.tresc_gatunek   ADD CONSTRAINT tresc_gatunek_tresc_id_fkey             FOREIGN KEY (tresc_id)              REFERENCES streamos.tresc (tresc_id);
ALTER TABLE streamos.tresc_gatunek   ADD CONSTRAINT tresc_gatunek_gatunek_id_fkey           FOREIGN KEY (gatunek_id)            REFERENCES streamos.gatunek (gatunek_id);
ALTER TABLE streamos.sesja_ogladania ADD CONSTRAINT sesja_ogladania_profil_id_fkey          FOREIGN KEY (profil_id)             REFERENCES streamos.profil (profil_id);
ALTER TABLE streamos.sesja_ogladania ADD CONSTRAINT sesja_ogladania_urzadzenie_id_fkey      FOREIGN KEY (urzadzenie_id)         REFERENCES streamos.urzadzenie (urzadzenie_id);
ALTER TABLE streamos.sesja_ogladania ADD CONSTRAINT sesja_ogladania_tresc_id_fkey           FOREIGN KEY (tresc_id)              REFERENCES streamos.tresc (tresc_id);
ALTER TABLE streamos.reklamodawca    ADD CONSTRAINT reklamodawca_kategoria_branzowa_id_fkey FOREIGN KEY (kategoria_branzowa_id) REFERENCES streamos.kategoria_branzowa (kategoria_branzowa_id);
ALTER TABLE streamos.kampania        ADD CONSTRAINT kampania_reklamodawca_id_fkey           FOREIGN KEY (reklamodawca_id)       REFERENCES streamos.reklamodawca (reklamodawca_id);
ALTER TABLE streamos.kampania_region ADD CONSTRAINT kampania_region_kampania_id_fkey        FOREIGN KEY (kampania_id)           REFERENCES streamos.kampania (kampania_id);
ALTER TABLE streamos.kampania_region ADD CONSTRAINT kampania_region_region_id_fkey          FOREIGN KEY (region_id)             REFERENCES streamos.region (region_id);
ALTER TABLE streamos.kampania_gatunek ADD CONSTRAINT kampania_gatunek_kampania_id_fkey      FOREIGN KEY (kampania_id)           REFERENCES streamos.kampania (kampania_id);
ALTER TABLE streamos.kampania_gatunek ADD CONSTRAINT kampania_gatunek_gatunek_id_fkey       FOREIGN KEY (gatunek_id)            REFERENCES streamos.gatunek (gatunek_id);
ALTER TABLE streamos.emisja_reklamy  ADD CONSTRAINT emisja_reklamy_kampania_id_fkey         FOREIGN KEY (kampania_id)           REFERENCES streamos.kampania (kampania_id);
ALTER TABLE streamos.emisja_reklamy  ADD CONSTRAINT emisja_reklamy_urzadzenie_id_fkey       FOREIGN KEY (urzadzenie_id)         REFERENCES streamos.urzadzenie (urzadzenie_id);
ALTER TABLE streamos.emisja_reklamy  ADD CONSTRAINT emisja_reklamy_sesja_id_fkey            FOREIGN KEY (sesja_id)              REFERENCES streamos.sesja_ogladania (sesja_id);
ALTER TABLE streamos.rozliczenie_dzienne ADD CONSTRAINT rozliczenie_dzienne_partner_id_fkey FOREIGN KEY (partner_id)            REFERENCES streamos.partner_oem (partner_id);


-- ===== 3. indeksy z etapu 1, pkt 10 =====
-- jak w PostgreSQL: SQL Server tez nie indeksuje kluczy obcych sam z siebie
CREATE INDEX idx_emisja_kampania_czas ON streamos.emisja_reklamy (kampania_id, czas_emisji);
CREATE INDEX idx_emisja_czas          ON streamos.emisja_reklamy (czas_emisji);


-- ===== 4. kontrola =====

-- wszystkie ograniczenia zaufane (is_not_trusted = 0), czyli sprawdzone na danych
SELECT OBJECT_NAME(parent_object_id) AS tabela, name AS ograniczenie, 'FK' AS typ, is_not_trusted
FROM sys.foreign_keys WHERE schema_id = SCHEMA_ID('streamos')
UNION ALL
SELECT OBJECT_NAME(parent_object_id), name, 'CHECK', is_not_trusted
FROM sys.check_constraints WHERE schema_id = SCHEMA_ID('streamos')
ORDER BY typ, tabela, ograniczenie;
-- oczekiwane: 21 FK + 9 CHECK, wszystkie is_not_trusted = 0

-- stan licznikow IDENTITY po zaladowaniu: wartosc biezaca powinna byc >= max(id)
-- (SQL Server sam przesuwa licznik, gdy wstawiono jawnie wieksza wartosc)
SELECT OBJECT_NAME(object_id) AS tabela, name AS kolumna, last_value AS biezaca_wartosc
FROM sys.identity_columns
WHERE OBJECT_SCHEMA_NAME(object_id) = 'streamos'
ORDER BY tabela;
