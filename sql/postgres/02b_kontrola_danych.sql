-- StreamOS - kontrola danych po wykonaniu 02_dane.sql
-- uruchamiac jako streamos_admin, zapytanie po zapytaniu (Ctrl+Enter)

SET search_path TO streamos;

-- 1. czy dane nie zostaly wgrane dwa razy
--    oczekiwane: 60 kampanii, 1 000 000 sesji, ok. 1,64 mln emisji
SELECT 'kampania' AS tabela, count(*) AS liczba_wierszy FROM kampania
UNION ALL SELECT 'sesja_ogladania', count(*) FROM sesja_ogladania
UNION ALL SELECT 'emisja_reklamy', count(*) FROM emisja_reklamy;

-- 2. duplikaty nazw kampanii -> oczekiwany pusty wynik
SELECT nazwa, count(*) FROM kampania GROUP BY nazwa HAVING count(*) > 1;

-- 3. ktorzy reklamodawcy maja emisje (wybor uzytkownikow testowych do pkt 7 i 9)
--    jesli Reklamodawca 01 ma 0 emisji, jego perspektywy bylyby puste,
--    dlatego uzytkownicy testowi to reklamodawca_02 i reklamodawca_03
SELECT r.reklamodawca_id,
       r.nazwa,
       count(DISTINCT k.kampania_id) AS liczba_kampanii,
       count(e.emisja_id)            AS liczba_emisji
FROM reklamodawca r
LEFT JOIN kampania k       ON k.reklamodawca_id = r.reklamodawca_id
LEFT JOIN emisja_reklamy e ON e.kampania_id = k.kampania_id
WHERE r.reklamodawca_id <= 5
GROUP BY r.reklamodawca_id, r.nazwa
ORDER BY r.reklamodawca_id;
