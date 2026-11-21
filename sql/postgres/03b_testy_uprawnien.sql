-- StreamOS - etap 1, pkt 7: testy uprawnien
-- uruchamiac jako streamos_admin, POLECENIE PO POLECENIU (Ctrl+Enter),
-- zeby kazdy wynik / blad zrobic jako osobny zrzut do sprawozdania.
-- SET ROLE przelacza sesje na innego uzytkownika (admin jest superuserem, wiec moze),
-- RESET ROLE wraca do admina.

-- test 1: kim jestem
SET ROLE reklamodawca_03;
SELECT current_user;

-- test 2: odczyt tabeli -> oczekiwany blad "permission denied for table kampania"
SELECT * FROM streamos.kampania LIMIT 5;

-- test 3: modyfikacja -> oczekiwany blad "permission denied"
UPDATE streamos.kampania SET budzet = 1 WHERE kampania_id = 1;

-- test 4: usuniecie tabeli -> oczekiwany blad "must be owner of table"
DROP TABLE streamos.emisja_reklamy;

RESET ROLE;

-- test 5: to samo dla partnera
SET ROLE partner_alfa;
SELECT * FROM streamos.urzadzenie LIMIT 5;   -- oczekiwany blad
RESET ROLE;

-- test 6: admin dalej widzi wszystko
SELECT current_user, count(*) FROM streamos.kampania;

-- (testy pozytywne, czyli odczyt przez perspektywy z filtrowaniem
--  "kazda firma widzi tylko swoje", sa w pkt 9)
