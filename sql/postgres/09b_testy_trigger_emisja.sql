-- StreamOS - etap 2, pkt 3: testy wyzwalacza trg_emisja_przed_dodaniem
-- uruchamiac jako streamos_admin, POLECENIE PO POLECENIU (Ctrl+Enter), zrzut kazdego wyniku
-- DBeaver w trybie Auto-Commit; wszystko w jednym edytorze (widok tymczasowy test_id
-- istnieje tylko w biezacym polaczeniu)
-- dane testowe usuwane na koncu (sprzatanie)

SET search_path TO streamos;


-- ===================== przygotowanie danych testowych =====================

-- konto z profilem doroslym (procedura z pkt 1) + profil dzieciecy 7+
CALL dodaj_konto('trigger@streamos.test', 1, 'Dorosly', NULL);

INSERT INTO profil (konto_id, nazwa, czy_dzieciecy, kategoria_wiekowa_id)
SELECT konto_id, 'Dziecko', true, 2 FROM konto WHERE email = 'trigger@streamos.test';

-- dwa telewizory przypisane do konta
INSERT INTO urzadzenie (numer_seryjny, partner_id, konto_id)
SELECT sn, 1, konto_id
FROM konto, unnest(ARRAY['TEST-SN-E01', 'TEST-SN-E02']) AS sn
WHERE email = 'trigger@streamos.test';

-- trzy sesje na telewizorze E01:
--   dziecko   - profil dzieciecy, tresc 0+
--   dorosly   - profil dorosly,   tresc 18+
--   bajka     - profil dorosly,   tresc 0+ (dorosly oglada tresc dla dzieci)
INSERT INTO sesja_ogladania (profil_id, urzadzenie_id, tresc_id, czas_start)
SELECT p.profil_id, u.urzadzenie_id,
       (SELECT min(t.tresc_id) FROM tresc t
        JOIN kategoria_wiekowa kw ON kw.kategoria_wiekowa_id = t.kategoria_wiekowa_id
        WHERE kw.minimalny_wiek = w.wiek),
       now()
FROM profil p
JOIN konto k ON k.konto_id = p.konto_id
JOIN (VALUES ('Dziecko', 0), ('Dorosly', 18), ('Dorosly', 0)) AS w(profil, wiek) ON w.profil = p.nazwa
CROSS JOIN urzadzenie u
WHERE k.email = 'trigger@streamos.test' AND u.numer_seryjny = 'TEST-SN-E01';

-- trzy kampanie (procedura z pkt 2):
--   spozywcza: reklamodawca 1 (branza Spozywcza), budzet na 4 emisje po 0.05, limit 3 dziennie
--   alkohol:   reklamodawca 2 (branza Napoje alkoholowe, niedozwolona dla dzieci)
--   przyszla:  zaczyna sie za 10 dni
CALL dodaj_kampanie(1, 'TEST trg spozywcza', 0.20, 0.05, current_date, current_date + 30, 3, ARRAY[1], ARRAY[1], NULL);
CALL dodaj_kampanie(2, 'TEST trg alkohol',    100, 0.05, current_date, current_date + 30, 3, ARRAY[1], ARRAY[1], NULL);
CALL dodaj_kampanie(1, 'TEST trg przyszla',   100, 0.05, current_date + 10, current_date + 30, 3, ARRAY[1], ARRAY[1], NULL);

-- kontrola: branze reklamodawcow testowych kampanii
SELECT k.nazwa, r.nazwa AS reklamodawca, kb.nazwa AS branza, kb.dozwolona_dla_dzieci
FROM kampania k
JOIN reklamodawca r        ON r.reklamodawca_id = k.reklamodawca_id
JOIN kategoria_branzowa kb ON kb.kategoria_branzowa_id = r.kategoria_branzowa_id
WHERE k.nazwa LIKE 'TEST trg%';
-- oczekiwane: spozywcza i przyszla -> true, alkohol -> false

-- widok tymczasowy z id danych testowych, zeby nie wpisywac ich recznie w testach
CREATE TEMP VIEW test_id AS
SELECT (SELECT kampania_id FROM kampania WHERE nazwa = 'TEST trg spozywcza') AS k_spoz,
       (SELECT kampania_id FROM kampania WHERE nazwa = 'TEST trg alkohol')   AS k_alko,
       (SELECT kampania_id FROM kampania WHERE nazwa = 'TEST trg przyszla')  AS k_przysz,
       (SELECT urzadzenie_id FROM urzadzenie WHERE numer_seryjny = 'TEST-SN-E01') AS tv,
       (SELECT urzadzenie_id FROM urzadzenie WHERE numer_seryjny = 'TEST-SN-E02') AS tv2,
       (SELECT s.sesja_id FROM sesja_ogladania s
        JOIN profil p ON p.profil_id = s.profil_id
        JOIN urzadzenie u ON u.urzadzenie_id = s.urzadzenie_id
        WHERE u.numer_seryjny = 'TEST-SN-E01' AND p.czy_dzieciecy)     AS s_dziecko,
       (SELECT s.sesja_id FROM sesja_ogladania s
        JOIN profil p ON p.profil_id = s.profil_id
        JOIN urzadzenie u ON u.urzadzenie_id = s.urzadzenie_id
        JOIN tresc t ON t.tresc_id = s.tresc_id
        JOIN kategoria_wiekowa kw ON kw.kategoria_wiekowa_id = t.kategoria_wiekowa_id
        WHERE u.numer_seryjny = 'TEST-SN-E01' AND NOT p.czy_dzieciecy AND kw.minimalny_wiek = 18) AS s_dorosly,
       (SELECT s.sesja_id FROM sesja_ogladania s
        JOIN profil p ON p.profil_id = s.profil_id
        JOIN urzadzenie u ON u.urzadzenie_id = s.urzadzenie_id
        JOIN tresc t ON t.tresc_id = s.tresc_id
        JOIN kategoria_wiekowa kw ON kw.kategoria_wiekowa_id = t.kategoria_wiekowa_id
        WHERE u.numer_seryjny = 'TEST-SN-E01' AND NOT p.czy_dzieciecy AND kw.minimalny_wiek = 0)  AS s_bajka;

SELECT * FROM test_id;
-- oczekiwane: wszystkie kolumny wypelnione


-- ===================== 1. koszt ze stawki kampanii =====================

-- test 1: INSERT bez kolumny koszt -> wyzwalacz ja uzupelnia
-- (NOT NULL jest sprawdzany PO wyzwalaczu BEFORE, wiec brak kosztu nie jest bledem)
INSERT INTO emisja_reklamy (kampania_id, urzadzenie_id, czas_emisji)
SELECT k_spoz, tv, now() FROM test_id;

-- test 2: INSERT z falszywym kosztem 999 -> nadpisany stawka
INSERT INTO emisja_reklamy (kampania_id, urzadzenie_id, czas_emisji, koszt)
SELECT k_spoz, tv, now(), 999 FROM test_id;

SELECT e.emisja_id, e.czas_emisji, e.koszt
FROM emisja_reklamy e, test_id t
WHERE e.kampania_id = t.k_spoz
ORDER BY e.emisja_id;
-- oczekiwane: 2 wiersze, oba z kosztem 0.0500


-- ===================== 2. limit dzienny (3 emisje na telewizor) =====================

-- test 3: dwie emisje w JEDNYM poleceniu, gdy sa juz 2 -> trzecia przejdzie, czwarta nie.
-- blad przerywa cale polecenie, wiec nie zostaje zadna z dwoch
INSERT INTO emisja_reklamy (kampania_id, urzadzenie_id, czas_emisji)
SELECT k_spoz, tv, now() FROM test_id, generate_series(1, 2);
-- oczekiwany blad: telewizor ... osiagnal limit 3 emisji kampanii ...

SELECT count(*) AS emisje_dzis
FROM emisja_reklamy e, test_id t
WHERE e.kampania_id = t.k_spoz;
-- oczekiwane: 2 (nie 3)

-- test 4: trzecia emisja osobno -> przechodzi
INSERT INTO emisja_reklamy (kampania_id, urzadzenie_id, czas_emisji)
SELECT k_spoz, tv, now() FROM test_id;

-- test 5: czwarta tego samego dnia -> blad
INSERT INTO emisja_reklamy (kampania_id, urzadzenie_id, czas_emisji)
SELECT k_spoz, tv, now() FROM test_id;
-- oczekiwany blad: telewizor ... osiagnal limit 3 emisji kampanii ...


-- ===================== 3. budzet (0.20 = 4 emisje po 0.05) =====================

-- test 6: jutro limit jest od nowa, budzet wystarcza na jeszcze jedna emisje -> przechodzi
INSERT INTO emisja_reklamy (kampania_id, urzadzenie_id, czas_emisji)
SELECT k_spoz, tv, now() + interval '1 day' FROM test_id;

SELECT k_spoz, pozostaly_budzet(k_spoz) AS pozostalo FROM test_id;
-- oczekiwane: pozostalo = 0.0000

-- test 7: kolejna jutro -> limit jeszcze nie osiagniety (1 z 3), ale budzet sie skonczyl
INSERT INTO emisja_reklamy (kampania_id, urzadzenie_id, czas_emisji)
SELECT k_spoz, tv, now() + interval '1 day' FROM test_id;
-- oczekiwany blad: brak budzetu w kampanii ... (zostalo 0.0000, stawka 0.0500)


-- ===================== 4. kampania aktywna w dniu emisji =====================

-- test 8: kampania, ktora zaczyna sie za 10 dni
INSERT INTO emisja_reklamy (kampania_id, urzadzenie_id, czas_emisji)
SELECT k_przysz, tv, now() FROM test_id;
-- oczekiwany blad: dzien ... jest poza okresem kampanii ...

-- test 9: emisja po dacie konca kampanii
INSERT INTO emisja_reklamy (kampania_id, urzadzenie_id, czas_emisji)
SELECT k_alko, tv, now() + interval '31 days' FROM test_id;
-- oczekiwany blad: dzien ... jest poza okresem kampanii ...


-- ===================== 5. branze niedozwolone dla dzieci =====================

-- test 10: reklama alkoholu w sesji profilu dzieciecego -> blad
INSERT INTO emisja_reklamy (kampania_id, urzadzenie_id, sesja_id, czas_emisji)
SELECT k_alko, tv, s_dziecko, now() FROM test_id;
-- oczekiwany blad: reklam tej branzy nie mozna emitowac na profilu dzieciecym ...

-- test 11: reklama alkoholu na profilu doroslym, ale przy tresci 0+ -> blad
INSERT INTO emisja_reklamy (kampania_id, urzadzenie_id, sesja_id, czas_emisji)
SELECT k_alko, tv, s_bajka, now() FROM test_id;
-- oczekiwany blad: reklam tej branzy nie mozna emitowac przy tresciach dla dzieci (sesja ..., tresc 0+)

-- test 12: ta sama reklama w sesji profilu doroslego przy tresci 18+ -> przechodzi
INSERT INTO emisja_reklamy (kampania_id, urzadzenie_id, sesja_id, czas_emisji)
SELECT k_alko, tv, s_dorosly, now() FROM test_id;

-- test 13: ta sama reklama na ekranie glownym (sesja_id NULL) -> przechodzi
INSERT INTO emisja_reklamy (kampania_id, urzadzenie_id, sesja_id, czas_emisji)
SELECT k_alko, tv, NULL, now() FROM test_id;

-- test 14: zapisaly sie dokladnie emisje z testow 12 i 13
SELECT e.emisja_id, e.sesja_id, e.koszt
FROM emisja_reklamy e, test_id t
WHERE e.kampania_id = t.k_alko
ORDER BY e.emisja_id;
-- oczekiwane: 2 wiersze - jeden z sesja_id doroslego, jeden z NULL


-- ===================== 6. emisja na telewizorze sesji =====================

-- test 15: sesja trwa na E01, a emisja wskazuje E02 -> blad
INSERT INTO emisja_reklamy (kampania_id, urzadzenie_id, sesja_id, czas_emisji)
SELECT k_alko, tv2, s_dorosly, now() FROM test_id;
-- oczekiwany blad: sesja ... trwa na telewizorze ..., a emisja wskazuje telewizor ...


-- ===================== 7. status kampanii =====================

-- test 16: kampania zakonczona recznie -> kolejne emisje odrzucone
UPDATE kampania SET status = 'zakonczona' WHERE nazwa = 'TEST trg alkohol';

INSERT INTO emisja_reklamy (kampania_id, urzadzenie_id, czas_emisji)
SELECT k_alko, tv, now() FROM test_id;
-- oczekiwany blad: kampania ... ma status zakonczona


-- ===================== sprzatanie =====================
DELETE FROM emisja_reklamy   WHERE kampania_id IN (SELECT kampania_id FROM kampania WHERE nazwa LIKE 'TEST trg%');
DELETE FROM sesja_ogladania  WHERE urzadzenie_id IN (SELECT urzadzenie_id FROM urzadzenie WHERE numer_seryjny LIKE 'TEST-SN-E%');
DELETE FROM kampania_region  WHERE kampania_id IN (SELECT kampania_id FROM kampania WHERE nazwa LIKE 'TEST trg%');
DELETE FROM kampania_gatunek WHERE kampania_id IN (SELECT kampania_id FROM kampania WHERE nazwa LIKE 'TEST trg%');
DELETE FROM kampania         WHERE nazwa LIKE 'TEST trg%';
DELETE FROM urzadzenie       WHERE numer_seryjny LIKE 'TEST-SN-E%';
DELETE FROM profil           WHERE konto_id IN (SELECT konto_id FROM konto WHERE email = 'trigger@streamos.test');
DELETE FROM konto            WHERE email = 'trigger@streamos.test';
DROP VIEW test_id;
