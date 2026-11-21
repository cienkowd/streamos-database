-- StreamOS - etap 1, pkt 8
-- zapytania realizujace funkcjonalnosci systemu
-- uruchamiac kazde zapytanie osobno (Ctrl+Enter) i robic zrzut wyniku

SET search_path TO streamos;


-- =====================================================================
-- ZAPYTANIE 1: rozliczenie partnerow OEM za poprzedni miesiac
-- ile reklam wyswietlono na telewizorach kazdego producenta,
-- jaki byl z nich przychod i ile z tego nalezy sie partnerowi
-- =====================================================================
SELECT p.nazwa                                          AS partner,
       count(*)                                         AS liczba_emisji,
       round(sum(e.koszt), 2)                           AS przychod_z_reklam,
       p.udzial_procent                                 AS udzial_proc,
       round(sum(e.koszt) * p.udzial_procent / 100, 2)  AS nalezne_partnerowi
FROM emisja_reklamy e
JOIN urzadzenie u  ON u.urzadzenie_id = e.urzadzenie_id
JOIN partner_oem p ON p.partner_id = u.partner_id
WHERE e.czas_emisji >= date_trunc('month', now()) - interval '1 month'
  AND e.czas_emisji <  date_trunc('month', now())
GROUP BY p.nazwa, p.udzial_procent
ORDER BY przychod_z_reklam DESC;


-- =====================================================================
-- ZAPYTANIE 2 (z podzapytaniem): najchetniej ogladane tresci na profilach dzieciecych
-- podzapytanie wybiera profile dzieciece, a zapytanie glowne liczy,
-- ile razy ogladano kazda tresc na tych profilach (10 najpopularniejszych)
-- =====================================================================
SELECT t.tytul,
       kw.nazwa         AS kategoria_wiekowa,
       count(*)         AS liczba_sesji
FROM sesja_ogladania s
JOIN tresc t              ON t.tresc_id = s.tresc_id
JOIN kategoria_wiekowa kw ON kw.kategoria_wiekowa_id = t.kategoria_wiekowa_id
WHERE s.profil_id IN (SELECT profil_id
                      FROM profil
                      WHERE czy_dzieciecy = true)
GROUP BY t.tytul, kw.nazwa
ORDER BY liczba_sesji DESC
LIMIT 10;


-- =====================================================================
-- ZAPYTANIE 3: kontrola dziennego limitu emisji (ostatnie 7 dni)
-- regula z case study: ta sama reklama moze pojawic sie na jednym
-- telewizorze tylko kilka razy dziennie. Zapytanie pokazuje przypadki,
-- w ktorych limit zostal przekroczony.
-- (wykorzystane rowniez do testow indeksow w pkt 10)
-- =====================================================================
SELECT k.nazwa              AS kampania,
       e.urzadzenie_id,
       e.czas_emisji::date  AS dzien,
       count(*)             AS liczba_emisji,
       k.limit_dzienny
FROM emisja_reklamy e
JOIN kampania k ON k.kampania_id = e.kampania_id
WHERE e.czas_emisji >= now() - interval '7 days'
GROUP BY k.nazwa, e.urzadzenie_id, e.czas_emisji::date, k.limit_dzienny
HAVING count(*) > k.limit_dzienny
ORDER BY liczba_emisji DESC;
