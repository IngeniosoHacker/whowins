#!/usr/bin/env python3
"""
whowins — Setup completo de base de datos desde cero
=====================================================
Crea la DB, aplica el esquema, inserta seed, carga jugadores
y genera config/teams_wc2026.json — todo en un solo comando.

Uso mínimo (localhost, usuario postgres):
  python3 sql/setup.py

Con servidor remoto y datos reales:
  python3 sql/setup.py \
    --host db.example.com --user postgres --password secret \
    --api-key TU_API_KEY

Solo crear DB y esquema (sin datos):
  python3 sql/setup.py --schema-only

Simular sin escribir nada:
  python3 sql/setup.py --dry-run
"""

import argparse
import importlib.util
import os
import re
import sys
import unittest.mock
from pathlib import Path

# ── Auto-instalar psycopg2 si no está ────────────────────────────────────────
def ensure_psycopg2():
    try:
        import psycopg2
        return psycopg2
    except ImportError:
        print("  [DEP] Instalando psycopg2-binary...")
        import subprocess
        subprocess.run([sys.executable, "-m", "pip", "install",
                        "psycopg2-binary", "-q"], check=True)
        import psycopg2
        return psycopg2

print("Verificando dependencias...")
psycopg2 = ensure_psycopg2()
import psycopg2.extras
from psycopg2.extensions import ISOLATION_LEVEL_AUTOCOMMIT
print("  ✓ psycopg2 listo\n")

BASE_DIR   = Path(__file__).parent.parent.resolve()
SQL_DIR    = BASE_DIR / "sql"
CONFIG_DIR = BASE_DIR / "config"
DATA_DIR   = BASE_DIR / "data"


# =============================================================================
# CONEXIÓN
# =============================================================================

def connect(host, port, user, password, dbname):
    return psycopg2.connect(
        host=host, port=port, user=user,
        password=password, dbname=dbname
    )


def db_exists(host, port, user, password, dbname) -> bool:
    conn = connect(host, port, user, password, "postgres")
    conn.set_isolation_level(ISOLATION_LEVEL_AUTOCOMMIT)
    cur = conn.cursor()
    cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (dbname,))
    exists = cur.fetchone() is not None
    cur.close(); conn.close()
    return exists


# =============================================================================
# EJECUCIÓN DE SQL — statement por statement con autocommit
# Esto evita el problema de "current transaction is aborted" porque
# cada statement vive en su propia transacción implícita.
# =============================================================================

def split_sql(sql: str) -> list[str]:
    """
    Divide un archivo SQL en statements individuales.
    Maneja correctamente:
      - Comentarios -- y /* */
      - Strings con $$ (dollar quoting de PostgreSQL)
      - Strings con comillas simples
      - DO $$ ... $$ blocks
    """
    statements = []
    current    = []
    in_dollar  = False
    dollar_tag = ""
    in_string  = False
    i = 0
    lines = sql.split("\n")
    text  = sql  # trabajamos sobre el texto completo

    # Usamos una máquina de estados simple sobre caracteres
    i = 0
    n = len(text)
    buf = []

    while i < n:
        ch = text[i]

        # ── Dollar quoting: $tag$ ... $tag$ ───────────────────────────────
        if not in_string and not in_dollar and ch == "$":
            # Buscar cierre de tag: $[A-Za-z0-9_]*$
            m = re.match(r'\$([A-Za-z0-9_]*)\$', text[i:])
            if m:
                in_dollar  = True
                dollar_tag = m.group(0)
                buf.append(text[i:i+len(dollar_tag)])
                i += len(dollar_tag)
                continue

        if in_dollar:
            buf.append(ch)
            # Buscar fin del dollar quote
            if text[i:i+len(dollar_tag)] == dollar_tag:
                buf.append(text[i+1:i+len(dollar_tag)])
                i += len(dollar_tag)
                in_dollar = False
            else:
                i += 1
            continue

        # ── String con comilla simple ─────────────────────────────────────
        if not in_string and ch == "'":
            in_string = True
            buf.append(ch)
            i += 1
            continue
        if in_string:
            buf.append(ch)
            if ch == "'" and i+1 < n and text[i+1] == "'":
                buf.append("'")
                i += 2
            elif ch == "'":
                in_string = False
                i += 1
            else:
                i += 1
            continue

        # ── Comentario -- hasta fin de línea ──────────────────────────────
        if ch == "-" and i+1 < n and text[i+1] == "-":
            end = text.find("\n", i)
            if end == -1:
                i = n
            else:
                buf.append(text[i:end+1])
                i = end + 1
            continue

        # ── Comentario /* ... */ ──────────────────────────────────────────
        if ch == "/" and i+1 < n and text[i+1] == "*":
            end = text.find("*/", i+2)
            if end == -1:
                i = n
            else:
                buf.append(text[i:end+2])
                i = end + 2
            continue

        # ── Fin de statement ──────────────────────────────────────────────
        if ch == ";":
            stmt = "".join(buf).strip()
            if stmt:
                statements.append(stmt)
            buf = []
            i += 1
            continue

        buf.append(ch)
        i += 1

    # Último statement sin ; al final
    remaining = "".join(buf).strip()
    if remaining:
        statements.append(remaining)

    # Filtrar statements vacíos o solo comentarios
    def is_empty(s):
        s2 = re.sub(r'--[^\n]*', '', s)
        s2 = re.sub(r'/\*.*?\*/', '', s2, flags=re.DOTALL)
        return not s2.strip()

    return [s for s in statements if not is_empty(s)]


def apply_sql_file(conn, sql_path: Path, label: str) -> tuple[int, list[str]]:
    """
    Ejecuta un archivo SQL statement por statement con autocommit.
    Retorna (n_ok, errores).
    Statements que fallan con "already exists" se ignoran silenciosamente.
    """
    if not sql_path.exists():
        raise FileNotFoundError(f"No encontrado: {sql_path}")

    sql        = sql_path.read_text(encoding="utf-8")
    statements = split_sql(sql)
    n_ok       = 0
    errors     = []

    # Autocommit para DDL — evita el "aborted transaction" en cascada
    old_autocommit = conn.autocommit
    conn.autocommit = True

    for stmt in statements:
        # Ignorar SET/RESET y statements de solo comentario
        stripped = stmt.strip().upper()
        if not stripped or stripped.startswith("SET "):
            continue
        try:
            cur = conn.cursor()
            cur.execute(stmt)
            cur.close()
            n_ok += 1
        except psycopg2.errors.DuplicateObject as e:
            # Ya existe (tipo ENUM, etc.) — normal en re-runs
            cur.close()
            n_ok += 1
        except psycopg2.errors.DuplicateTable as e:
            cur.close()
            n_ok += 1
        except psycopg2.Error as e:
            cur.close()
            code = e.pgcode or ""
            msg  = str(e).split("\n")[0]
            # 42710 = duplicate_object, 42P07 = duplicate_table,
            # 42701 = duplicate_column, 23505 = unique_violation
            if code in ("42710","42P07","42701","23505","42P06","42723"):
                n_ok += 1   # ignorar duplicados — re-run normal
            else:
                errors.append(f"[{code}] {msg}\n  → {stmt[:120]}")
        except Exception as e:
            try: cur.close()
            except: pass
            errors.append(f"{e}\n  → {stmt[:120]}")

    conn.autocommit = old_autocommit
    return n_ok, errors


def step_banner(n, total, text):
    print(f"\n{'─'*60}")
    print(f"  Paso {n}/{total}: {text}")
    print(f"{'─'*60}")


# =============================================================================
# PASO 1 — Crear base de datos
# =============================================================================

def step_create_db(args, dry_run) -> bool:
    step_banner(1, 6, "Crear base de datos")
    if dry_run:
        print(f"  [DRY] CREATE DATABASE {args.dbname}")
        return True
    try:
        if db_exists(args.host, args.port, args.user, args.password, args.dbname):
            print(f"  ✓ '{args.dbname}' ya existe — se omite creación")
        else:
            conn0 = connect(args.host, args.port, args.user, args.password, "postgres")
            conn0.set_isolation_level(ISOLATION_LEVEL_AUTOCOMMIT)
            cur = conn0.cursor()
            cur.execute(f'CREATE DATABASE "{args.dbname}" ENCODING \'UTF8\'')
            cur.close(); conn0.close()
            print(f"  ✓ Base de datos '{args.dbname}' creada")
        return True
    except Exception as e:
        print(f"  [ERROR] {e}")
        print(f"  Asegúrate de que el usuario tenga CREATEDB:")
        print(f"    psql -U postgres -c \"ALTER USER {args.user} CREATEDB;\"")
        return False


# =============================================================================
# PASO 2 — Esquema
# =============================================================================

def step_apply_schema(conn, dry_run) -> bool:
    step_banner(2, 6, "Aplicar esquema (tablas, vistas, funciones, tipos)")
    if dry_run:
        print(f"  [DRY] {SQL_DIR / '01_schema.sql'}")
        return True
    n, errs = apply_sql_file(conn, SQL_DIR / "01_schema.sql",
                              "01_schema.sql")
    if errs:
        print(f"  ⚠  {n} statements OK, {len(errs)} errores:")
        for e in errs:
            print(f"     {e}")
        # Errores no fatales si el esquema ya existía parcialmente
        if all("already exists" in e.lower() or "42" in e for e in errs):
            print("  ℹ  (son duplicados — esquema ya existía, se continúa)")
            return True
        return False
    print(f"  ✓ {n} statements ejecutados")
    return True


# =============================================================================
# PASO 3 — Seed WC2026
# =============================================================================

def step_seed(conn, dry_run) -> bool:
    step_banner(3, 6, "Insertar equipos, grupos y temporada WC2026")
    if dry_run:
        print(f"  [DRY] {SQL_DIR / '02_seed_wc2026.sql'}")
        return True
    n, errs = apply_sql_file(conn, SQL_DIR / "02_seed_wc2026.sql",
                              "02_seed_wc2026.sql")
    # Errores de duplicate en seed son normales en re-runs
    real_errors = [e for e in errs
                   if not any(c in e for c in ("23505","42710","42P07","duplicate"))]
    if real_errors:
        print(f"  ⚠  {len(real_errors)} errores reales:")
        for e in real_errors:
            print(f"     {e}")
        return False

    # Verificar conteos
    try:
        conn.autocommit = True
        cur = conn.cursor()
        cur.execute("SELECT COUNT(*) FROM teams")
        nt = cur.fetchone()[0]
        cur.execute("SELECT COUNT(*) FROM wc2026_groups")
        ng = cur.fetchone()[0]
        cur.close()
        conn.autocommit = False
        print(f"  ✓ {nt} equipos  |  {ng} asignaciones de grupo  ({n} statements)")
    except Exception as e:
        print(f"  [WARN] No se pudo verificar conteos: {e}")
    return True


# =============================================================================
# PASO 4 — Calendario
# =============================================================================

def step_schedule(conn, dry_run) -> bool:
    step_banner(4, 6, "Insertar calendario de partidos WC2026")
    loader_mod = _load_module("loader", SQL_DIR / "03_load_players.py")
    if loader_mod is None:
        print("  [SKIP] No se pudo cargar el loader")
        return True

    if dry_run:
        print(f"  [DRY] {len(loader_mod.WC2026_SCHEDULE)} partidos")
        return True

    try:
        conn.autocommit = True
        cur = conn.cursor()
        cur.execute("""
            SELECT s.season_id FROM seasons s
            JOIN competitions c ON c.competition_id = s.competition_id
            WHERE c.short_name = 'WC2026' AND s.label = '2026'
        """)
        row = cur.fetchone()
        cur.close()
        conn.autocommit = False
        if not row:
            print("  [WARN] Temporada WC2026 no encontrada — omitiendo calendario")
            return True
        season_id = row[0]
        loader_mod.load_schedule(conn, season_id, dry_run=False)
        return True
    except Exception as e:
        print(f"  [ERROR] {e}")
        conn.autocommit = False
        return True   # no fatal


# =============================================================================
# PASO 5 — Jugadores
# =============================================================================

def step_load_players(conn, args, dry_run) -> bool:
    step_banner(5, 6, "Cargar jugadores y estadísticas")
    loader_mod = _load_module("loader", SQL_DIR / "03_load_players.py")
    if loader_mod is None:
        print("  [ERROR] No se pudo cargar 03_load_players.py")
        return False

    # season_id — usar autocommit para la consulta
    try:
        conn.autocommit = True
        cur = conn.cursor()
        season_id = loader_mod.get_season_id(cur, "2026")
        cur.close()
        conn.autocommit = False
    except Exception as e:
        conn.autocommit = False
        print(f"  [ERROR] season_id: {e}")
        return False

    # CSV local
    csv_path = DATA_DIR / "players.csv"
    if csv_path.exists():
        print(f"  → CSV: {csv_path.name}")
        if not dry_run:
            try:
                loader_mod.load_csv_fallback(conn, season_id, dry_run=False)
            except Exception as e:
                print(f"  [WARN] CSV load: {e}")
                conn.rollback()
    else:
        print("  ℹ  data/players.csv no encontrado")

    # API-Football
    if args.api_key:
        print(f"\n  → API-Football (límite: {args.api_limit} req/día)")

        if args.teams:
            teams = [t.upper() for t in args.teams]
        elif args.groups:
            seen, teams = set(), []
            for _, grp, a, b, *_ in loader_mod.WC2026_SCHEDULE:
                if grp.upper() in [g.upper() for g in args.groups]:
                    for t in (a, b):
                        if t not in seen:
                            teams.append(t); seen.add(t)
        elif args.priority:
            teams = [t for t, _ in loader_mod.PRIORITY_ORDER[:args.priority]]
        else:
            max_t = args.api_limit // loader_mod.REQS_PER_TEAM_TOTAL
            teams = [t for t, _ in loader_mod.PRIORITY_ORDER[:max_t]]
            print(f"     Auto: {len(teams)} equipos en {args.api_limit} requests")

        req_est = len(teams) * (1 if args.only_squad
                                else loader_mod.REQS_PER_TEAM_TOTAL)
        print(f"     Equipos: {', '.join(teams)}")
        print(f"     Requests estimadas: ~{req_est}")

        if not dry_run:
            req_used, n_pl = loader_mod.load_teams_api(
                conn, teams, season_id, args.api_key,
                only_squad=args.only_squad, dry_run=False
            )
            print(f"  ✓ {n_pl} jugadores  ({req_used} requests)")
        else:
            print(f"  [DRY] ~{req_est} requests para {len(teams)} equipos")
    else:
        print("\n  ℹ  Sin --api-key: solo se usó el CSV local.")
        print("     Para datos reales: --api-key TU_KEY")

    return True


# =============================================================================
# PASO 6 — Config JSON
# =============================================================================

def step_generate_config(conn, args, dry_run) -> bool:
    step_banner(6, 6, "Generar config/teams_wc2026.json")
    gen_mod = _load_module("gen_config", SQL_DIR / "04_generate_config.py")
    if gen_mod is None:
        print("  [SKIP] No se pudo cargar 04_generate_config.py")
        return True

    out_path = CONFIG_DIR / "teams_wc2026.json"
    if dry_run:
        print(f"  [DRY] → {out_path}")
        return True

    try:
        CONFIG_DIR.mkdir(exist_ok=True)
        conn.rollback()
        conn.autocommit = True

        team_filter  = [t.upper() for t in args.teams]  if args.teams  else None
        group_filter = [g.upper() for g in args.groups] if args.groups else None
        teams = gen_mod.get_wc2026_teams(conn, group_filter, team_filter)
        conn.autocommit = False

        if not teams:
            print("  [WARN] Sin equipos en DB — usando config CSV de ejemplo")
            return True

        import json
        config = {"teams": teams, **gen_mod.R_CONFIG_TEMPLATE}
        config["data_sources"]["players_db"]["dsn"] = (
            f"host={args.host} port={args.port} "
            f"dbname={args.dbname} user={args.user} password={args.password}"
        )
        config["data_sources"]["players_db"]["season_label"] = "2026"

        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(config, f, indent=2, ensure_ascii=False)

        codes = list(teams.keys())
        print(f"  ✓ {out_path}")
        print(f"     {len(teams)} equipos incluidos")
        if len(codes) >= 2:
            print(f"\n  Listo para predecir:")
            print(f"     whowins {codes[0]} {codes[1]} --config config/teams_wc2026.json")
        return True
    except Exception as e:
        conn.autocommit = False
        print(f"  [ERROR] {e}")
        return True   # no fatal


# =============================================================================
# RESET
# =============================================================================

def step_reset(args, dry_run):
    print(f"\n{'═'*60}")
    print(f"  ⚠  RESET: eliminar y recrear '{args.dbname}'")
    print(f"{'═'*60}")
    if not dry_run:
        c = input(f"\n  ¿Seguro? Escribe 'si' para confirmar: ").strip().lower()
        if c not in ("si","sí","yes"):
            print("  Cancelado.")
            sys.exit(0)
        try:
            conn0 = connect(args.host, args.port, args.user, args.password, "postgres")
            conn0.set_isolation_level(ISOLATION_LEVEL_AUTOCOMMIT)
            cur = conn0.cursor()
            cur.execute("""
                SELECT pg_terminate_backend(pid) FROM pg_stat_activity
                WHERE datname=%s AND pid<>pg_backend_pid()
            """, (args.dbname,))
            cur.execute(f'DROP DATABASE IF EXISTS "{args.dbname}"')
            cur.close(); conn0.close()
            print(f"  ✓ '{args.dbname}' eliminada")
        except Exception as e:
            print(f"  [ERROR] {e}"); sys.exit(1)
    else:
        print(f"  [DRY] DROP DATABASE {args.dbname}")


# =============================================================================
# RESUMEN
# =============================================================================

def print_summary(conn, args):
    print(f"\n{'═'*60}")
    print("  ✅  SETUP COMPLETADO")
    print(f"{'═'*60}")
    try:
        conn.autocommit = True
        cur = conn.cursor()
        cur.execute("SELECT COUNT(*) FROM players");       np = cur.fetchone()[0]
        cur.execute("SELECT COUNT(*) FROM player_seasons");ns = cur.fetchone()[0]
        cur.execute("SELECT COUNT(*) FROM teams");         nt = cur.fetchone()[0]
        cur.execute("SELECT COUNT(*) FROM matches");       nm = cur.fetchone()[0]
        cur.execute("""
            SELECT t.team_code, COUNT(tp.player_id)
            FROM team_players tp JOIN teams t ON t.team_id=tp.team_id
            GROUP BY t.team_code ORDER BY 2 DESC LIMIT 6
        """)
        top = cur.fetchall()
        cur.close()
        conn.autocommit = False
        print(f"\n  DB            : {args.dbname} @ {args.host}:{args.port}")
        print(f"  Equipos       : {nt}")
        print(f"  Jugadores     : {np}")
        print(f"  Stats (seasons): {ns}")
        print(f"  Partidos      : {nm}")
        if top:
            print(f"\n  Jugadores por equipo (top 6):")
            for code, n in top:
                print(f"    {code:<6} {'█'*min(n,26)} {n}")
    except Exception:
        pass

    db_url  = (f"postgresql://{args.user}:{args.password}"
               f"@{args.host}:{args.port}/{args.dbname}")
    cfg     = CONFIG_DIR / "teams_wc2026.json"

    print(f"\n  Próximos pasos:")
    print(f"  {'─'*50}")
    if cfg.exists():
        print(f"  Predecir:")
        print(f"    whowins ARG FRA --config config/teams_wc2026.json")
    print(f"\n  Cargar más equipos:")
    print(f"    python3 sql/03_load_players.py \\")
    print(f"      --db {db_url} --api-key TU_KEY --source api")
    print(f"\n  Regenerar config:")
    print(f"    python3 sql/04_generate_config.py --db {db_url}")
    print(f"{'═'*60}\n")


# =============================================================================
# HELPER — cargar módulo sin ejecutar main()
# =============================================================================

def _load_module(name, path):
    try:
        spec = importlib.util.spec_from_file_location(name, path)
        mod  = importlib.util.module_from_spec(spec)
        with unittest.mock.patch("sys.argv", ["setup.py"]):
            spec.loader.exec_module(mod)
        return mod
    except Exception as e:
        print(f"  [WARN] No se pudo importar {path.name}: {e}")
        return None


# =============================================================================
# CLI
# =============================================================================

def main():
    p = argparse.ArgumentParser(
        description="whowins — Setup completo PostgreSQL desde cero",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Ejemplos:
  python3 sql/setup.py
  python3 sql/setup.py --api-key TU_KEY --groups A B
  python3 sql/setup.py --api-key TU_KEY --matches 1 2 3 4
  python3 sql/setup.py --host db.example.com --user admin --password secret --api-key TU_KEY
  python3 sql/setup.py --schema-only
  python3 sql/setup.py --reset
  python3 sql/setup.py --dry-run --api-key FAKE --groups A
"""
    )
    pg = p.add_argument_group("PostgreSQL")
    pg.add_argument("--host",     default=os.getenv("PGHOST","localhost"))
    pg.add_argument("--port",     default=int(os.getenv("PGPORT","5432")), type=int)
    pg.add_argument("--user",     default=os.getenv("PGUSER","postgres"))
    pg.add_argument("--password", default=os.getenv("PGPASSWORD",""))
    pg.add_argument("--dbname",   default=os.getenv("PGDATABASE","whowins"))

    da = p.add_argument_group("Datos")
    da.add_argument("--api-key",    default=None)
    da.add_argument("--api-limit",  default=100, type=int)
    da.add_argument("--only-squad", action="store_true")

    sel = da.add_mutually_exclusive_group()
    sel.add_argument("--teams",    nargs="+", metavar="CODE")
    sel.add_argument("--groups",   nargs="+", metavar="GRP")
    sel.add_argument("--matches",  nargs="+", type=int, metavar="N")
    sel.add_argument("--priority", type=int,  metavar="N")

    ct = p.add_argument_group("Control")
    ct.add_argument("--schema-only",    action="store_true")
    ct.add_argument("--reset",          action="store_true")
    ct.add_argument("--dry-run",        action="store_true")
    ct.add_argument("--skip-schedule",  action="store_true")
    args = p.parse_args()

    print()
    print("╔══════════════════════════════════════════════════════╗")
    print("║       ⚽  whowins — Database Setup  ⚽               ║")
    print("╚══════════════════════════════════════════════════════╝")
    print(f"\n  Host    : {args.host}:{args.port}")
    print(f"  DB      : {args.dbname}")
    print(f"  Usuario : {args.user}")
    print(f"  API key : {'✓' if args.api_key else '✗ (solo CSV)'}")
    print(f"  Dry run : {args.dry_run}\n")

    if args.dry_run:
        print("  [DRY RUN] Nada se ejecuta realmente.\n")

    if args.reset:
        step_reset(args, args.dry_run)

    if not step_create_db(args, args.dry_run):
        sys.exit(1)

    # Conectar a la DB destino
    conn = None
    if not args.dry_run:
        try:
            conn = connect(args.host, args.port, args.user,
                           args.password, args.dbname)
            conn.autocommit = False
            print(f"  ✓ Conectado a '{args.dbname}'")
        except Exception as e:
            print(f"\n[ERROR] Conexión a '{args.dbname}': {e}")
            sys.exit(1)

    if not step_apply_schema(conn, args.dry_run):
        sys.exit(1)

    if not step_seed(conn, args.dry_run):
        sys.exit(1)

    if args.schema_only:
        print("\n  [--schema-only] Listo. Esquema y seed aplicados.")
        if conn: conn.close()
        sys.exit(0)

    if not args.skip_schedule:
        step_schedule(conn, args.dry_run)

    step_load_players(conn, args, args.dry_run)
    step_generate_config(conn, args, args.dry_run)

    if conn:
        print_summary(conn, args)
        conn.close()
    else:
        print("\n  [DRY RUN completado]\n")


if __name__ == "__main__":
    main()
