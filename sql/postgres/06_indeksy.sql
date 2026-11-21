-- StreamOS - etap 1, pkt 10: indeksy i testy wydajnosci
-- uruchamiac jako streamos_admin, POLECENIE PO POLECENIU (Ctrl+Enter)
--
-- jak mierzyc:
--   EXPLAIN (ANALYZE, BUFFERS) naprawde wykonuje zapytanie i pokazuje plan:
--   - Seq Scan          = baza czyta cala tabele
--   - Index Scan /
--     Bitmap Index Scan = baza korzysta z indeksu
--   - Buffers           = ile stron (po 8 kB) trzeba bylo przeczytac
--   - Execution Time    = czas wykonania
--   kazdy EXPLAIN uruchom 2-3 razy i bierz ostatni wynik (pierwszy bywa wolniejszy,
--   bo dane nie sa jeszcze w pamieci). Do sprawozdania: zrzut planu z Execution Time.
--
-- PostgreSQL sam tworzy indeksy tylko dla PRIMARY KEY i UNIQUE.
-- Kluczy obcych NIE indeksuje, wiec np. emisja_reklamy.kampania_id nie ma indeksu.

SET search_path TO streamos;

-- start od zera (gdyby skrypt byl uruchamiany ponownie)
DROP INDEX IF EXISTS idx_emisja_czas;
DROP INDEX IF EXISTS idx_emisja_kampania;
DROP INDEX IF EXISTS idx_emisja_kampania_czas;
ANALYZE emisja_reklamy;


-- =====================================================================
-- TEST A: zapytanie 3 (kontrola dziennego limitu, ostatnie 7 dni)
-- warunek tylko po czasie emisji -> indeks na jednej kolumnie czas_emisji
-- =====================================================================

-- A1. bez indeksu
EXPLAIN (ANALYZE, BUFFERS)
SELECT k.nazwa AS kampania, e.urzadzenie_id, e.czas_emisji::date AS dzien,
       count(*) AS liczba_emisji, k.limit_dzienny
FROM emisja_reklamy e
JOIN kampania k ON k.kampania_id = e.kampania_id
WHERE e.czas_emisji >= now() - interval '7 days'
GROUP BY k.nazwa, e.urzadzenie_id, e.czas_emisji::date, k.limit_dzienny
HAVING count(*) > k.limit_dzienny
ORDER BY liczba_emisji DESC;

-- A2. indeks B-drzewo na czas_emisji
CREATE INDEX idx_emisja_czas ON emisja_reklamy (czas_emisji);
ANALYZE emisja_reklamy;

EXPLAIN (ANALYZE, BUFFERS)
SELECT k.nazwa AS kampania, e.urzadzenie_id, e.czas_emisji::date AS dzien,
       count(*) AS liczba_emisji, k.limit_dzienny
FROM emisja_reklamy e
JOIN kampania k ON k.kampania_id = e.kampania_id
WHERE e.czas_emisji >= now() - interval '7 days'
GROUP BY k.nazwa, e.urzadzenie_id, e.czas_emisji::date, k.limit_dzienny
HAVING count(*) > k.limit_dzienny
ORDER BY liczba_emisji DESC;


-- =====================================================================
-- TEST B: emisje jednej kampanii w ostatnich 7 dniach, dzien po dniu
-- (to, co reklamodawca sprawdza najczesciej, i kontrola budzetu)
-- warunek po DWOCH kolumnach: kampania_id i czas_emisji
-- porownanie: brak / indeks na jednej kolumnie / dwa osobne / jeden zlozony
-- =====================================================================

DROP INDEX IF EXISTS idx_emisja_czas;
ANALYZE emisja_reklamy;

-- B1. bez indeksu
EXPLAIN (ANALYZE, BUFFERS)
SELECT czas_emisji::date AS dzien, count(*) AS liczba_emisji, sum(koszt) AS koszt
FROM emisja_reklamy
WHERE kampania_id = 50
  AND czas_emisji >= now() - interval '7 days'
GROUP BY czas_emisji::date
ORDER BY dzien;

-- B2. indeks tylko na kampania_id (indeks na kluczu obcym)
CREATE INDEX idx_emisja_kampania ON emisja_reklamy (kampania_id);
ANALYZE emisja_reklamy;

EXPLAIN (ANALYZE, BUFFERS)
SELECT czas_emisji::date AS dzien, count(*) AS liczba_emisji, sum(koszt) AS koszt
FROM emisja_reklamy
WHERE kampania_id = 50
  AND czas_emisji >= now() - interval '7 days'
GROUP BY czas_emisji::date
ORDER BY dzien;

-- B3. dwa osobne indeksy: kampania_id oraz czas_emisji
CREATE INDEX idx_emisja_czas ON emisja_reklamy (czas_emisji);
ANALYZE emisja_reklamy;

EXPLAIN (ANALYZE, BUFFERS)
SELECT czas_emisji::date AS dzien, count(*) AS liczba_emisji, sum(koszt) AS koszt
FROM emisja_reklamy
WHERE kampania_id = 50
  AND czas_emisji >= now() - interval '7 days'
GROUP BY czas_emisji::date
ORDER BY dzien;

-- B4. jeden indeks zlozony (kampania_id, czas_emisji), osobne usuwamy
DROP INDEX idx_emisja_kampania;
DROP INDEX idx_emisja_czas;
CREATE INDEX idx_emisja_kampania_czas ON emisja_reklamy (kampania_id, czas_emisji);
ANALYZE emisja_reklamy;

EXPLAIN (ANALYZE, BUFFERS)
SELECT czas_emisji::date AS dzien, count(*) AS liczba_emisji, sum(koszt) AS koszt
FROM emisja_reklamy
WHERE kampania_id = 50
  AND czas_emisji >= now() - interval '7 days'
GROUP BY czas_emisji::date
ORDER BY dzien;


-- =====================================================================
-- TEST C: perspektywa reklamodawcy korzysta z indeksu zlozonego
-- (laczenie kampanii z emisjami po kampania_id = pierwsza kolumna indeksu)
-- =====================================================================
SET ROLE reklamodawca_03;
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM v_moje_kampanie;
RESET ROLE;


-- =====================================================================
-- STAN KONCOWY: zostawiamy dwa indeksy
--   idx_emisja_kampania_czas - raporty kampanii, kontrola budzetu, perspektywa reklamodawcy
--   idx_emisja_czas          - zapytanie 3 (filtr tylko po czasie)
-- osobny indeks na samym kampania_id jest zbedny: zastepuje go indeks zlozony,
-- bo kampania_id jest w nim pierwsza kolumna
-- =====================================================================
CREATE INDEX idx_emisja_czas ON emisja_reklamy (czas_emisji);
ANALYZE emisja_reklamy;

SELECT indexname                                           AS indeks,
       pg_size_pretty(pg_relation_size(indexname::regclass)) AS rozmiar,
       indexdef                                            AS definicja
FROM pg_indexes
WHERE schemaname = 'streamos' AND tablename = 'emisja_reklamy'
ORDER BY indexname;
