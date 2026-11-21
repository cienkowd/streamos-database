"""Buduje obie bazy StreamOS od zera i uruchamia wszystkie skrypty w kolejności.

    python run.py            # całość: PostgreSQL -> migracja -> SQL Server
    python run.py postgres   # tylko PostgreSQL (00-11)
    python run.py mssql      # migracja + SQL Server (12-16); wymaga gotowego PostgreSQL
    python run.py down       # zatrzymuje kontenery i usuwa wolumeny

Skrypty główne muszą przejść bez żadnego błędu. Skrypty testowe (pliki z "b" w nazwie)
celowo wywołują błędy (np. odmowa dostępu, odrzucona emisja), więc są uruchamiane w całości,
a liczba błędów w każdym z nich jest porównywana z tests/expected_errors.json.
Wymaga Dockera z Compose v2; bez zależności Pythona spoza biblioteki standardowej.
"""
from __future__ import annotations
import json
import re
import subprocess
import sys
import time
from decimal import Decimal, InvalidOperation
from pathlib import Path

ROOT = Path(__file__).resolve().parent
LOGS = ROOT / "logs"
TRANSFER = ROOT / ".transfer"
EXPECTED = ROOT / "tests" / "expected_errors.json"

# (plik, test?) — kolejność jak przy ręcznym uruchamianiu
PG_STEPS = [
    ("00_reset.sql", False), ("01_schematy_tabele.sql", False), ("02_dane.sql", False),
    ("02b_kontrola_danych.sql", True), ("03_uzytkownicy.sql", False), ("03b_testy_uprawnien.sql", True),
    ("04_zapytania.sql", False), ("05_perspektywy.sql", False), ("05b_testy_perspektyw.sql", True),
    ("06_indeksy.sql", False), ("07_funkcje_procedury.sql", False), ("08_procedura_dodaj_kampanie.sql", False),
    ("09_trigger_emisja.sql", False), ("09b_testy_trigger_emisja.sql", True),
    ("10_reguly_sesje_rozliczenie.sql", False), ("10b_testy_reguly_sesje_rozliczenie.sql", True),
    ("11_automatyzacja.sql", False), ("11b_testy_automatyzacji.sql", True),
]
MS_STEPS = [
    ("13_mssql_funkcje_procedury.sql", False), ("13b_mssql_testy_funkcji_procedur.sql", True),
    ("14_mssql_triggery.sql", False), ("14b_mssql_testy_triggerow.sql", True),
    ("15_mssql_perspektywy_role.sql", False), ("15b_mssql_testy_uprawnien_perspektyw.sql", True),
    ("16_mssql_automatyzacja.sql", False), ("16b_mssql_testy_automatyzacji.sql", True),
]

PSQL = 'psql -X -U "$POSTGRES_USER" -d streamos'
SQLCMD = '/opt/mssql-tools18/bin/sqlcmd -C -I -f 65001 -S localhost -U sa -P "$MSSQL_SA_PASSWORD"'
PG_ERROR = re.compile(r"^psql:.*\bERROR:", re.M)
MS_ERROR = re.compile(r"^Msg \d+, Level (1[1-9]|2\d)", re.M)
# klient zawiesił się albo stracił połączenie: reszta pliku się nie wykonała, więc test jest niewiarygodny
FATAL = re.compile(r"^SqlState \w+, |server closed the connection|connection to server .* failed", re.M)

results: list[tuple[str, str, str]] = []  # (krok, status, szczegóły)


def compose(*args: str, **kw) -> subprocess.CompletedProcess:
    return subprocess.run(["docker", "compose", *args], cwd=ROOT, **kw)


def in_container(service: str, command: str, stdin: bytes | None = None) -> subprocess.CompletedProcess:
    return compose("exec", "-T", service, "sh", "-c", command, input=stdin, capture_output=True)


def log(name: str, out: bytes) -> str:
    LOGS.mkdir(exist_ok=True)
    text = out.decode("utf-8", errors="replace")
    (LOGS / f"{name}.log").write_text(text, encoding="utf-8")
    return text


def run_step(service: str, folder: str, file: str, is_test: bool, expected: dict) -> bool:
    if service == "postgres":
        cmd = f"{PSQL} {'' if is_test else '-v ON_ERROR_STOP=1'} -f /sql/{folder}/{file} 2>&1"
    else:
        cmd = f"{SQLCMD} -d streamos {'' if is_test else '-b'} -i /sql/{folder}/{file} 2>&1"
    t0 = time.time()
    p = in_container(service, cmd)
    text = log(Path(file).stem, p.stdout + p.stderr)
    errors = len((PG_ERROR if service == "postgres" else MS_ERROR).findall(text))
    secs = f"{time.time() - t0:.0f}s"
    if not is_test:
        ok = p.returncode == 0 and errors == 0
        results.append((file, "OK" if ok else "BŁĄD", f"{secs}, zob. logs/{Path(file).stem}.log" if not ok else secs))
        return ok
    if FATAL.search(text):
        results.append((file, "PRZERWANY", f"{secs}, klient przerwał wykonywanie, zob. logs/{Path(file).stem}.log"))
        return False
    want = expected.get(file)
    ok = want is None or errors == want
    detail = f"{secs}, błędy oczekiwane przez test: {errors}" + ("" if want is None or ok else f" (powinno być {want})")
    results.append((file, "OK" if ok else "INNE BŁĘDY", detail))
    return ok


def up() -> None:
    # katalog na CSV musi powstać przed `compose up`: inaczej na Linuksie Docker tworzy go
    # sam jako root (źródło bind mounta) i skrypt nie może do niego pisać
    TRANSFER.mkdir(exist_ok=True)
    if compose("up", "-d", "--build", "--wait").returncode != 0:
        sys.exit("docker compose up nie powiódł się")


def postgres(expected: dict) -> bool:
    ok = True
    for file, is_test in PG_STEPS:
        ok &= run_step("postgres", "postgres", file, is_test, expected)
        if not ok and not is_test:
            return False
    return ok


def mssql_query(sql: str, db: str = "streamos") -> str:
    p = in_container("mssql", f"{SQLCMD} -d {db} -b -h -1 -W -s '|' -Q \"SET NOCOUNT ON; {sql}\" 2>&1")
    if p.returncode != 0:
        raise RuntimeError(p.stdout.decode(errors="replace"))
    return p.stdout.decode("utf-8", errors="replace")


def migrate() -> bool:
    """PostgreSQL -> SQL Server: tabele z 12, dane przez CSV (COPY -> BULK INSERT), potem 12b."""
    t0 = time.time()
    mssql_query("IF DB_ID('streamos') IS NOT NULL BEGIN ALTER DATABASE streamos SET SINGLE_USER WITH ROLLBACK IMMEDIATE;"
                " DROP DATABASE streamos; END; CREATE DATABASE streamos;", db="master")
    if not run_step("mssql", "mssql", "12_mssql_tabele.sql", False, {}):
        return False

    columns: dict[str, list[tuple[str, str]]] = {}
    for line in mssql_query("SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS "
                            "WHERE TABLE_SCHEMA = 'streamos' ORDER BY TABLE_NAME, ORDINAL_POSITION").splitlines():
        if line.count("|") == 2:
            t, c, dtype = (x.strip() for x in line.split("|"))
            columns.setdefault(t, []).append((c, dtype))

    TRANSFER.mkdir(exist_ok=True)
    for f in TRANSFER.glob("*"):
        f.unlink()
    load = []
    rows_total = 0
    for table, cols in columns.items():
        exprs = []
        for c, dtype in cols:
            if dtype == "bit":
                exprs.append(f'("{c}")::int')
            elif dtype == "datetimeoffset":  # zapis w UTC, tak jak przy migracji w DBeaverze
                exprs.append(f"""to_char("{c}" AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US') || '+00:00'""")
            else:
                exprs.append(f'"{c}"')
        copy = f'COPY (SELECT {", ".join(exprs)} FROM streamos."{table}") TO STDOUT WITH (FORMAT csv);'
        p = in_container("postgres", f"{PSQL} -q -v ON_ERROR_STOP=1 -f -", stdin=copy.encode())
        if p.returncode != 0:
            results.append((f"migracja: {table}", "BŁĄD", p.stdout.decode(errors="replace")[:300]))
            return False
        (TRANSFER / f"{table}.csv").write_bytes(p.stdout)  # binarnie: bez zamiany \n na \r\n
        n = p.stdout.count(b"\n")
        rows_total += n
        if n:
            load.append(f"BULK INSERT streamos.[{table}] FROM '/transfer/{table}.csv' WITH (FORMAT = 'CSV', "
                        f"FIELDQUOTE = '\"', ROWTERMINATOR = '0x0a', KEEPIDENTITY, KEEPNULLS, TABLOCK);")
    # bez CODEPAGE: SQL Server na Linuksie go nie obsługuje; dane StreamOS są w całości ASCII
    (TRANSFER / "load.sql").write_text("SET NOCOUNT ON;\n" + "\n".join(load) + "\n", encoding="utf-8")
    p = in_container("mssql", f"{SQLCMD} -d streamos -b -i /transfer/load.sql 2>&1")
    log("12a_migracja_bulk_insert", p.stdout)
    if p.returncode != 0:
        results.append(("migracja danych", "BŁĄD", "zob. logs/12a_migracja_bulk_insert.log"))
        return False
    results.append(("migracja danych", "OK", f"{time.time() - t0:.0f}s, {len(columns)} tabel, {rows_total} wierszy"))
    return run_step("mssql", "mssql", "12b_mssql_ograniczenia.sql", False, {})


def _rows(text: str) -> list[tuple]:
    out = []
    for line in text.splitlines():
        if "|" not in line and not re.fullmatch(r"\s*-?[\d.]+\s*", line):
            continue
        vals = []
        for v in line.split("|"):
            v = v.strip()
            if v == "NULL":  # sqlcmd pisze NULL, psql -A pusty napis
                v = ""
            try:
                vals.append(Decimal(v).normalize())
            except InvalidOperation:
                vals.append(v)
        out.append(tuple(vals))
    return out


def compare() -> bool:
    """12c: te same zapytania w obu bazach, wyniki muszą być identyczne wiersz po wierszu."""
    sql = (ROOT / "sql" / "mssql" / "12c_porownanie_danych.sql").read_bytes()
    pg = in_container("postgres", f"{PSQL} -q -A -t -F '|' -v ON_ERROR_STOP=1 -f -", stdin=sql)
    ms = in_container("mssql", f"{SQLCMD} -d streamos -b -h -1 -W -s '|' -i /sql/mssql/12c_porownanie_danych.sql 2>&1")
    pg_rows = _rows(pg.stdout.decode("utf-8", errors="replace"))
    ms_rows = _rows("\n".join(l for l in ms.stdout.decode("utf-8", errors="replace").splitlines()
                              if "rows affected" not in l))
    log("12c_porownanie_postgres", pg.stdout)
    log("12c_porownanie_mssql", ms.stdout)
    # UNION ALL bez ORDER BY: każdy silnik zwraca wiersze w innej kolejności, więc porównujemy zbiory wierszy
    ok = pg.returncode == 0 and ms.returncode == 0 and len(pg_rows) > 0 and sorted(pg_rows, key=str) == sorted(ms_rows, key=str)
    results.append(("12c_porownanie_danych.sql", "OK" if ok else "RÓŻNICE",
                    f"{len(pg_rows)} wierszy wyników identycznych w obu bazach" if ok else "zob. logs/12c_porownanie_*.log"))
    return ok


def mssql(expected: dict) -> bool:
    if not (migrate() and compare()):
        return False
    ok = True
    for file, is_test in MS_STEPS:
        ok &= run_step("mssql", "mssql", file, is_test, expected)
        if not ok and not is_test:
            return False
    return ok


def main() -> None:
    target = sys.argv[1] if len(sys.argv) > 1 else "all"
    if target == "down":
        compose("down", "-v")
        return
    expected = json.loads(EXPECTED.read_text(encoding="utf-8")) if EXPECTED.exists() else {}
    up()
    ok = True
    if target in ("all", "postgres"):
        ok = postgres(expected)
    if ok and target in ("all", "mssql"):
        ok = mssql(expected)
    width = max(len(r[0]) for r in results) if results else 0
    print()
    for step, status, detail in results:
        print(f"  {step:<{width}}  {status:<10}  {detail}")
    print("\nWYNIK:", "wszystko przeszło" if ok else "są błędy (szczegóły w logs/)")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
