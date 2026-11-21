-- StreamOS - etap 1, pkt 6
-- wypelnienie bazy danymi (dane syntetyczne generowane w SQL)
-- uruchamiac calosc (Alt+X) po skrypcie 01_schematy_tabele.sql
-- czas wykonania: ok. 1-3 min (sesje i emisje to ponad 2,5 mln wierszy)

SET search_path TO streamos;
SELECT setseed(0.42);   -- stale ziarno losowania = przy kazdym uruchomieniu te same dane


-- ===== slowniki (wpisane recznie) =====

INSERT INTO region (nazwa) VALUES
 ('Dolnoslaskie'), ('Kujawsko-Pomorskie'), ('Lubelskie'), ('Lubuskie'),
 ('Lodzkie'), ('Malopolskie'), ('Mazowieckie'), ('Opolskie'),
 ('Podkarpackie'), ('Podlaskie'), ('Pomorskie'), ('Slaskie'),
 ('Swietokrzyskie'), ('Warminsko-Mazurskie'), ('Wielkopolskie'), ('Zachodniopomorskie');

INSERT INTO gatunek (nazwa) VALUES
 ('Komedia'), ('Dramat'), ('Akcja'), ('Thriller'), ('Horror'), ('Dokument'),
 ('Animacja'), ('Familijny'), ('Sport'), ('Wiadomosci'), ('Kryminal'), ('Sci-Fi');

INSERT INTO kategoria_wiekowa (nazwa, minimalny_wiek) VALUES
 ('0+', 0), ('7+', 7), ('12+', 12), ('16+', 16), ('18+', 18);

INSERT INTO kategoria_branzowa (nazwa, dozwolona_dla_dzieci) VALUES
 ('Spozywcza', true), ('Napoje alkoholowe', false), ('Motoryzacja', true),
 ('Elektronika', true), ('Hazard', false), ('Finanse', true),
 ('Zabawki', true), ('Uroda', true);


-- ===== partnerzy i reklamodawcy (fikcyjne firmy) =====

INSERT INTO partner_oem (nazwa, udzial_procent) VALUES
 ('Producent Alfa', 30.00), ('Producent Beta', 25.00), ('Producent Gamma', 35.00),
 ('Producent Delta', 20.00), ('Producent Epsilon', 28.50), ('Producent Zeta', 32.00);

INSERT INTO reklamodawca (nazwa, kategoria_branzowa_id)
SELECT 'Reklamodawca ' || lpad(i::text, 2, '0'),
       (i - 1) % 8 + 1                       -- kategorie branzowe po kolei
FROM generate_series(1, 20) AS i;


-- ===== konta, profile, urzadzenia =====

-- 5000 kont zarejestrowanych w ciagu ostatnich 2 lat
INSERT INTO konto (email, region_id, data_rejestracji)
SELECT 'uzytkownik' || i || '@example.com',
       1 + floor(random() * 16)::int,
       now() - random() * interval '730 days'
FROM generate_series(1, 5000) AS i;

-- 1-4 profile na konto; profil 1 zawsze dorosly,
-- profile 3 i 4 dzieciece z limitem 7+ albo 12+
INSERT INTO profil (konto_id, nazwa, czy_dzieciecy, kategoria_wiekowa_id)
SELECT k.konto_id,
       'Profil ' || p,
       p >= 3,
       CASE WHEN p >= 3 THEN 2 + (k.konto_id % 2) END   -- 2 = 7+, 3 = 12+
FROM konto k
CROSS JOIN generate_series(1, 4) AS p
WHERE p <= 1 + k.konto_id % 4;

-- 8000 telewizorow; ok. 10% jeszcze nieaktywowanych (bez konta)
INSERT INTO urzadzenie (numer_seryjny, partner_id, konto_id)
SELECT 'SN' || lpad(i::text, 8, '0'),
       1 + floor(random() * 6)::int,
       CASE WHEN random() < 0.9 THEN 1 + floor(random() * 5000)::int END
FROM generate_series(1, 8000) AS i;


-- ===== tresci =====

-- 2000 tresci; najwiecej odcinkow, mniej filmow i programow
INSERT INTO tresc (tytul, typ, kategoria_wiekowa_id)
SELECT CASE WHEN r < 0.3 THEN 'Film ' WHEN r < 0.8 THEN 'Serial - odcinek ' ELSE 'Program ' END || i,
       CASE WHEN r < 0.3 THEN 'film'  WHEN r < 0.8 THEN 'odcinek'           ELSE 'program'  END,
       1 + floor(random() * 5)::int
FROM (SELECT i, random() AS r FROM generate_series(1, 2000) AS i) t;

-- kazda tresc ma 1-3 gatunki (pierwszy zawsze, kolejne losowo)
INSERT INTO tresc_gatunek (tresc_id, gatunek_id)
SELECT tresc_id, (tresc_id % 12) + 1 FROM tresc
UNION
SELECT tresc_id, 1 + floor(random() * 12)::int FROM tresc WHERE random() < 0.6
UNION
SELECT tresc_id, 1 + floor(random() * 12)::int FROM tresc WHERE random() < 0.3;


-- ===== kampanie =====

-- 60 kampanii w ostatnim roku, trwajacych 30-120 dni
INSERT INTO kampania (reklamodawca_id, nazwa, budzet, stawka, data_od, data_do, status, limit_dzienny)
SELECT (i - 1) % 20 + 1,
       'Kampania ' || i,
       round((5000 + random() * 95000)::numeric, 2),
       round((0.01 + random() * 0.09)::numeric, 4),
       od,
       od + (30 + floor(random() * 91))::int,
       'aktywna',                                  -- poprawiane nizej
       1 + floor(random() * 5)::int
FROM (SELECT i, (current_date - 365 + floor(random() * 330)::int) AS od
      FROM generate_series(1, 60) AS i) t;

UPDATE kampania SET status = 'zakonczona' WHERE data_do < current_date;

-- targetowanie: 1-4 regiony i 1-3 gatunki na kampanie
INSERT INTO kampania_region (kampania_id, region_id)
SELECT kampania_id, (kampania_id % 16) + 1 FROM kampania
UNION
SELECT k.kampania_id, r.region_id FROM kampania k CROSS JOIN region r WHERE random() < 0.15;

INSERT INTO kampania_gatunek (kampania_id, gatunek_id)
SELECT kampania_id, (kampania_id % 12) + 1 FROM kampania
UNION
SELECT k.kampania_id, g.gatunek_id FROM kampania k CROSS JOIN gatunek g WHERE random() < 0.1;


-- ===== sesje ogladania (1 000 000) =====
-- losujemy aktywowany telewizor, a potem profil z TEGO SAMEGO konta,
-- zeby dane byly spojne (profil i urzadzenie naleza do jednego konta)

CREATE TEMP TABLE tmp_urz AS
SELECT row_number() OVER (ORDER BY urzadzenie_id) AS nr, urzadzenie_id, u.konto_id, p.profile
FROM urzadzenie u
JOIN (SELECT konto_id, array_agg(profil_id) AS profile FROM profil GROUP BY konto_id) p
  ON p.konto_id = u.konto_id;

INSERT INTO sesja_ogladania (profil_id, urzadzenie_id, tresc_id, czas_start, czas_koniec)
SELECT u.profile[1 + floor(random() * array_length(u.profile, 1))::int],
       u.urzadzenie_id,
       r.tresc_id,
       r.start,
       CASE WHEN random() < 0.005 THEN NULL               -- nieliczne sesje jeszcze trwaja
            ELSE r.start + (5 + random() * 145) * interval '1 minute' END
FROM (SELECT 1 + floor(random() * (SELECT count(*) FROM tmp_urz))::int AS nr,
             1 + floor(random() * 2000)::int AS tresc_id,
             now() - random() * interval '180 days' AS start
      FROM generate_series(1, 1000000)) r
JOIN tmp_urz u ON u.nr = r.nr;

-- profile dzieciece ogladaja tylko tresci 0+ i 7+
UPDATE sesja_ogladania s
SET tresc_id = d.tresci[1 + (s.sesja_id % array_length(d.tresci, 1))::int]
FROM profil p,
     (SELECT array_agg(tresc_id) AS tresci FROM tresc WHERE kategoria_wiekowa_id <= 2) d
WHERE p.profil_id = s.profil_id AND p.czy_dzieciecy;


-- ===== emisje reklam (ok. 1,6 mln) =====
-- kampania losowana sposrod kampanii aktywnych w dniu emisji,
-- koszt = stawka kampanii w chwili emisji

CREATE TEMP TABLE tmp_dzien AS
SELECT d::date AS dzien, array_agg(k.kampania_id) AS kampanie
FROM generate_series(current_date - 365, current_date, interval '1 day') AS d
JOIN kampania k ON d::date BETWEEN k.data_od AND k.data_do
GROUP BY d::date;

-- a) emisje w trakcie ogladania (1 200 000)
INSERT INTO emisja_reklamy (kampania_id, urzadzenie_id, sesja_id, czas_emisji, koszt)
SELECT k.kampania_id, e.urzadzenie_id, e.sesja_id, e.czas, k.stawka
FROM (SELECT s.sesja_id, s.urzadzenie_id,
             s.czas_start + random() * (coalesce(s.czas_koniec, s.czas_start + interval '30 minutes') - s.czas_start) AS czas
      FROM (SELECT 1 + floor(random() * 1000000)::bigint AS sesja_id FROM generate_series(1, 1200000)) los
      JOIN sesja_ogladania s ON s.sesja_id = los.sesja_id) e
JOIN tmp_dzien d ON d.dzien = e.czas::date
JOIN kampania k ON k.kampania_id = d.kampanie[1 + floor(random() * array_length(d.kampanie, 1))::int];

-- b) emisje na ekranie glownym, bez sesji (400 000)
INSERT INTO emisja_reklamy (kampania_id, urzadzenie_id, sesja_id, czas_emisji, koszt)
SELECT k.kampania_id, u.urzadzenie_id, NULL, r.czas, k.stawka
FROM (SELECT 1 + floor(random() * (SELECT count(*) FROM tmp_urz))::int AS nr,
             now() - random() * interval '180 days' AS czas
      FROM generate_series(1, 400000)) r
JOIN tmp_urz u ON u.nr = r.nr
JOIN tmp_dzien d ON d.dzien = r.czas::date
JOIN kampania k ON k.kampania_id = d.kampanie[1 + floor(random() * array_length(d.kampanie, 1))::int];

-- regula z case study: reklamy branz niedozwolonych nie pojawiaja sie na profilach dzieciecych
DELETE FROM emisja_reklamy e
USING sesja_ogladania s, profil p, kampania k, reklamodawca r, kategoria_branzowa b
WHERE e.sesja_id = s.sesja_id AND s.profil_id = p.profil_id AND p.czy_dzieciecy
  AND e.kampania_id = k.kampania_id AND k.reklamodawca_id = r.reklamodawca_id
  AND r.kategoria_branzowa_id = b.kategoria_branzowa_id AND NOT b.dozwolona_dla_dzieci;

DROP TABLE tmp_urz, tmp_dzien;

ANALYZE;   -- aktualne statystyki dla planisty zapytan (wazne przy testach indeksow)


-- ===== podsumowanie (zrzut do sprawozdania) =====
SELECT 'region' AS tabela, count(*) AS liczba_wierszy FROM region
UNION ALL SELECT 'gatunek', count(*) FROM gatunek
UNION ALL SELECT 'kategoria_wiekowa', count(*) FROM kategoria_wiekowa
UNION ALL SELECT 'kategoria_branzowa', count(*) FROM kategoria_branzowa
UNION ALL SELECT 'partner_oem', count(*) FROM partner_oem
UNION ALL SELECT 'konto', count(*) FROM konto
UNION ALL SELECT 'profil', count(*) FROM profil
UNION ALL SELECT 'urzadzenie', count(*) FROM urzadzenie
UNION ALL SELECT 'tresc', count(*) FROM tresc
UNION ALL SELECT 'tresc_gatunek', count(*) FROM tresc_gatunek
UNION ALL SELECT 'reklamodawca', count(*) FROM reklamodawca
UNION ALL SELECT 'kampania', count(*) FROM kampania
UNION ALL SELECT 'kampania_region', count(*) FROM kampania_region
UNION ALL SELECT 'kampania_gatunek', count(*) FROM kampania_gatunek
UNION ALL SELECT 'sesja_ogladania', count(*) FROM sesja_ogladania
UNION ALL SELECT 'emisja_reklamy', count(*) FROM emisja_reklamy;
