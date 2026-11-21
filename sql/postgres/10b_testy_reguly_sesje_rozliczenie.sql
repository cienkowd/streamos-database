-- StreamOS - etap 2, pkt 4: testy CHECK, wyzwalacza na sesjach i funkcji rozliczenie_partnerow
-- uruchamiac jako streamos_admin, POLECENIE PO POLECENIU (Ctrl+Enter), zrzut kazdego wyniku
-- DBeaver w trybie Auto-Commit; wszystko w jednym edytorze (widok tymczasowy test_sesje)
-- dane testowe usuwane na koncu (sprzatanie)

SET search_path TO streamos;


-- ===================== przygotowanie danych testowych =====================

-- konto A: profil dorosly + dzieciecy 7+;  konto B: profil dorosly
CALL dodaj_konto('sesja.a@streamos.test', 1, 'Dorosly A', NULL);
CALL dodaj_konto('sesja.b@streamos.test', 1, 'Dorosly B', NULL);

INSERT INTO profil (konto_id, nazwa, czy_dzieciecy, kategoria_wiekowa_id)
SELECT konto_id, 'Dziecko A', true,
       (SELECT kategoria_wiekowa_id FROM kategoria_wiekowa WHERE minimalny_wiek = 7)
FROM konto WHERE email = 'sesja.a@streamos.test';

-- telewizory: A (konto A), B (konto B), N (nieaktywowany)
INSERT INTO urzadzenie (numer_seryjny, partner_id, konto_id) VALUES
 ('TEST-SN-S0A', 1, (SELECT konto_id FROM konto WHERE email = 'sesja.a@streamos.test')),
 ('TEST-SN-S0B', 1, (SELECT konto_id FROM konto WHERE email = 'sesja.b@streamos.test')),
 ('TEST-SN-S0N', 1, NULL);

-- widok tymczasowy z id danych testowych i przykladowych tresci 7+, 12+ i 18+
CREATE TEMP VIEW test_sesje AS
SELECT (SELECT profil_id FROM profil WHERE nazwa = 'Dorosly A') AS p_dorosly,
       (SELECT profil_id FROM profil WHERE nazwa = 'Dziecko A')  AS p_dziecko,
       (SELECT urzadzenie_id FROM urzadzenie WHERE numer_seryjny = 'TEST-SN-S0A') AS tv_a,
       (SELECT urzadzenie_id FROM urzadzenie WHERE numer_seryjny = 'TEST-SN-S0B') AS tv_b,
       (SELECT urzadzenie_id FROM urzadzenie WHERE numer_seryjny = 'TEST-SN-S0N') AS tv_n,
       (SELECT min(t.tresc_id) FROM tresc t JOIN kategoria_wiekowa kw USING (kategoria_wiekowa_id) WHERE kw.minimalny_wiek = 7)  AS t_7,
       (SELECT min(t.tresc_id) FROM tresc t JOIN kategoria_wiekowa kw USING (kategoria_wiekowa_id) WHERE kw.minimalny_wiek = 12) AS t_12,
       (SELECT min(t.tresc_id) FROM tresc t JOIN kategoria_wiekowa kw USING (kategoria_wiekowa_id) WHERE kw.minimalny_wiek = 18) AS t_18;

SELECT * FROM test_sesje;
-- oczekiwane: wszystkie kolumny wypelnione


-- ===================== wyzwalacz na sesjach: poprawne sesje =====================

-- test 1: profil dorosly na telewizorze swojego konta, tresc 18+ -> przechodzi
INSERT INTO sesja_ogladania (profil_id, urzadzenie_id, tresc_id, czas_start)
SELECT p_dorosly, tv_a, t_18, now() FROM test_sesje;

-- test 2: profil dzieciecy 7+, tresc 7+ (rowno limitowi) -> przechodzi
INSERT INTO sesja_ogladania (profil_id, urzadzenie_id, tresc_id, czas_start)
SELECT p_dziecko, tv_a, t_7, now() FROM test_sesje;


-- ===================== wyzwalacz na sesjach: odrzucone =====================

-- test 3: profil dzieciecy 7+, tresc 12+
INSERT INTO sesja_ogladania (profil_id, urzadzenie_id, tresc_id, czas_start)
SELECT p_dziecko, tv_a, t_12, now() FROM test_sesje;
-- oczekiwany blad: profil dzieciecy ... ma limit 7+, a tresc ... jest 12+

-- test 4: profil z konta A na telewizorze konta B
INSERT INTO sesja_ogladania (profil_id, urzadzenie_id, tresc_id, czas_start)
SELECT p_dorosly, tv_b, t_18, now() FROM test_sesje;
-- oczekiwany blad: profil ... (konto ...) i telewizor ... (konto ...) nie naleza do tego samego konta

-- test 5: telewizor nieaktywowany
INSERT INTO sesja_ogladania (profil_id, urzadzenie_id, tresc_id, czas_start)
SELECT p_dorosly, tv_n, t_18, now() FROM test_sesje;
-- oczekiwany blad: ... i telewizor ... (konto <NULL>) nie naleza do tego samego konta


-- ===================== wyzwalacz na sesjach: UPDATE =====================

-- test 6: zmiana tresci w sesji dziecka na 18+ -> wyzwalacz dziala tez przy UPDATE
UPDATE sesja_ogladania
SET tresc_id = (SELECT t_18 FROM test_sesje)
WHERE profil_id = (SELECT p_dziecko FROM test_sesje);
-- oczekiwany blad: profil dzieciecy ... ma limit 7+, a tresc ... jest 18+

-- test 7: zakonczenie sesji (UPDATE czas_koniec) -> wyzwalacz sie nie uruchamia, przechodzi
UPDATE sesja_ogladania
SET czas_koniec = now() + interval '1 hour'
WHERE profil_id = (SELECT p_dziecko FROM test_sesje);

SELECT s.sesja_id, p.nazwa AS profil, s.tresc_id, s.czas_start, s.czas_koniec
FROM sesja_ogladania s
JOIN profil p ON p.profil_id = s.profil_id
WHERE s.urzadzenie_id = (SELECT tv_a FROM test_sesje)
ORDER BY s.sesja_id;
-- oczekiwane: 2 sesje (testy 1 i 2), sesja dziecka z tresc 7+ i ustawionym czas_koniec


-- ===================== ograniczenia CHECK =====================

-- test 8: sesja konczy sie przed startem
INSERT INTO sesja_ogladania (profil_id, urzadzenie_id, tresc_id, czas_start, czas_koniec)
SELECT p_dorosly, tv_a, t_18, now(), now() - interval '1 hour' FROM test_sesje;
-- oczekiwany blad: ... violates check constraint "sesja_czas_check"

-- test 9: profil dzieciecy bez limitu wiekowego
INSERT INTO profil (konto_id, nazwa, czy_dzieciecy, kategoria_wiekowa_id)
SELECT konto_id, 'TEST dziecko bez limitu', true, NULL
FROM konto WHERE email = 'sesja.a@streamos.test';
-- oczekiwany blad: ... violates check constraint "profil_dzieciecy_check"

-- test 10: profil dorosly z limitem wiekowym
INSERT INTO profil (konto_id, nazwa, czy_dzieciecy, kategoria_wiekowa_id)
SELECT konto_id, 'TEST dorosly z limitem', false, 1
FROM konto WHERE email = 'sesja.a@streamos.test';
-- oczekiwany blad: ... violates check constraint "profil_dzieciecy_check"

-- test 11: kampania dodana zwyklym INSERT-em (z pominieciem procedury), koniec przed startem
INSERT INTO kampania (reklamodawca_id, nazwa, budzet, stawka, data_od, data_do, status)
VALUES (1, 'TEST zle daty', 1000, 0.05, current_date + 30, current_date, 'aktywna');
-- oczekiwany blad: ... violates check constraint "kampania_daty_check"


-- ===================== funkcja rozliczenie_partnerow =====================

-- test 12: poprzedni miesiac (parametr pominiety) - te same liczby co zapytanie 1 z etapu 1
SELECT * FROM rozliczenie_partnerow();

-- test 13: wybrany miesiac
SELECT * FROM rozliczenie_partnerow('2026-09-01');

-- test 14: miesiac bez emisji -> wszyscy partnerzy z zerami (dzieki LEFT JOIN)
SELECT * FROM rozliczenie_partnerow('2030-01-01');

-- test 15: funkcja jak tabela - laczna kwota do wyplaty wszystkim partnerom
SELECT sum(nalezne_partnerowi) AS do_wyplaty_razem
FROM rozliczenie_partnerow();


-- ===================== sprzatanie =====================
DELETE FROM sesja_ogladania WHERE urzadzenie_id IN (SELECT urzadzenie_id FROM urzadzenie WHERE numer_seryjny LIKE 'TEST-SN-S0%');
DELETE FROM urzadzenie      WHERE numer_seryjny LIKE 'TEST-SN-S0%';
DELETE FROM profil          WHERE konto_id IN (SELECT konto_id FROM konto WHERE email LIKE 'sesja.%@streamos.test');
DELETE FROM konto           WHERE email LIKE 'sesja.%@streamos.test';
DROP VIEW test_sesje;
