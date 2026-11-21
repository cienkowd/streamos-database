-- StreamOS - etap 1, pkt 9: testy perspektyw (i dokonczenie testow uprawnien z pkt 7)
-- uruchamiac jako streamos_admin, POLECENIE PO POLECENIU (Ctrl+Enter), zrzut kazdego wyniku

SET search_path TO streamos;

-- test 1: dwaj reklamodawcy, ta sama perspektywa, rozne dane
SET ROLE reklamodawca_02;
SELECT * FROM v_moje_kampanie;          -- tylko kampanie Reklamodawcy 02
RESET ROLE;

SET ROLE reklamodawca_03;
SELECT * FROM v_moje_kampanie;          -- inne kampanie, Reklamodawcy 03
RESET ROLE;

-- test 2: emisje wg regionow
SET ROLE reklamodawca_03;
SELECT * FROM v_moje_emisje_regiony ORDER BY kampania, liczba_emisji DESC;
RESET ROLE;

-- test 3: dwaj partnerzy, ta sama perspektywa, rozne dane
SET ROLE partner_alfa;
SELECT * FROM v_moje_przychody ORDER BY miesiac;
RESET ROLE;

SET ROLE partner_beta;
SELECT * FROM v_moje_przychody ORDER BY miesiac;
RESET ROLE;

-- test 4: ogladalnosc partnera
SET ROLE partner_alfa;
SELECT * FROM v_moja_ogladalnosc;
RESET ROLE;

-- test 5: reklamodawca probuje zajrzec do perspektywy partnera -> oczekiwany blad
SET ROLE reklamodawca_03;
SELECT * FROM v_moje_przychody;
RESET ROLE;

-- test 6: proba obejscia filtra wlasnym warunkiem -> nadal tylko wlasne dane
SET ROLE reklamodawca_03;
SELECT * FROM v_moje_kampanie WHERE kampania = 'Kampania 2';   -- kampania Reklamodawcy 02, nie 03 -> 0 wierszy
RESET ROLE;
