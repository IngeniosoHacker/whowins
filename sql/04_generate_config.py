#!/usr/bin/env python3
"""
whowins — Generador de config/teams.json desde PostgreSQL
==========================================================
Reemplaza el JSON estático por uno generado dinámicamente
consultando los 48 equipos del Mundial 2026 en la DB.

Uso:
  python3 sql/04_generate_config.py --db postgresql://user:pass@host/db
  python3 sql/04_generate_config.py --db postgresql://user:pass@host/db --group A
  python3 sql/04_generate_config.py --db postgresql://user:pass@host/db --teams ARG BRA FRA
"""

import argparse
import json
import sys
from pathlib import Path

try:
    import psycopg2
    import psycopg2.extras
except ImportError:
    print("[ERROR] pip install psycopg2-binary")
    sys.exit(1)

# Actualizar config de R para usar PostgreSQL
R_CONFIG_TEMPLATE = {
    "data_sources": {
        "players_csv":  None,
        "matches_csv":  None,
        "players_db": {
            "dsn":          "host=localhost dbname=whowins user=postgres",
            "player_view":  "v_player_details",
            "match_view":   "v_match_history",
            "team_fn":      "fn_team_players",
            "season_label": "2026"
        }
    },
    "model_settings": {
        "anova_significance":      0.05,
        "regression_cv_folds":     5,
        "min_matches_history":     5,
        "home_advantage_weight":   1.0,
        "seasons_weight_decay":    0.8,
        "use_match_player_stats":  True
    }
}


def get_wc2026_teams(conn, group_filter=None, team_filter=None) -> dict:
    cur = conn.cursor(cursor_factory=psycopg2.extras.DictCursor)

    # Obtener la temporada WC2026 más reciente
    cur.execute("""
        SELECT MAX(s.season_id)
        FROM seasons s
        JOIN competitions c
            ON c.competition_id = s.competition_id
        WHERE c.short_name = 'WC2026'
          AND s.label = '2026'
    """)

    season_id = cur.fetchone()[0]

    if not season_id:
        raise RuntimeError(
            "No se encontró ninguna temporada WC2026 con label=2026"
        )

    where = ""
    params = [season_id]

    if group_filter:
        where += " AND g.wc_group = ANY(%s)"
        params.append(group_filter)

    if team_filter:
        where += " AND t.team_code = ANY(%s)"
        params.append(team_filter)

    cur.execute(f"""
        SELECT
            t.team_code,
            t.full_name,
            t.short_name,
            t.altitude_home_m,
            t.stadium,
            g.wc_group,
            g.seed,
            COALESCE(
                array_agg(
                    DISTINCT p.player_code
                    ORDER BY p.player_code
                ) FILTER (
                    WHERE p.player_code IS NOT NULL
                ),
                ARRAY[]::varchar[]
            ) AS player_codes
        FROM teams t
        JOIN wc2026_groups g
            ON g.team_code = t.team_code
        LEFT JOIN team_players tp
            ON tp.team_id = t.team_id
           AND tp.season_id = %s
           AND tp.status = 'active'
        LEFT JOIN players p
            ON p.player_id = tp.player_id
        WHERE 1=1
            {where}
        GROUP BY
            t.team_code,
            t.full_name,
            t.short_name,
            t.altitude_home_m,
            t.stadium,
            g.wc_group,
            g.seed
        ORDER BY
            g.wc_group,
            g.seed
    """, params)

    teams = {}

    for row in cur.fetchall():
        code = row["team_code"]

        teams[code] = {
            "full_name": row["full_name"],
            "short_name": row["short_name"],
            "stadium": row["stadium"] or f"Estadio {row['full_name']}",
            "altitude_home_m": row["altitude_home_m"],
            "wc_group": row["wc_group"],
            "seed": row["seed"],
            "players": list(row["player_codes"])
        }

    cur.close()
    return teams


'''
def get_wc2026_teams(conn, group_filter=None, team_filter=None) -> dict:
    cur = conn.cursor(cursor_factory=psycopg2.extras.DictCursor)

    where = ""
    params = []
    if group_filter:
        where = "AND g.wc_group = ANY(%s)"
        params.append(group_filter)
    if team_filter:
        where += " AND t.team_code = ANY(%s)"
        params.append(team_filter)

    cur.execute(f"""
        SELECT
            t.team_code,
            t.full_name,
            t.short_name,
            t.altitude_home_m,
            t.stadium,
            g.wc_group,
            g.seed,
            COALESCE(
                array_agg(p.player_code ORDER BY tp.jersey_number NULLS LAST)
                FILTER (WHERE p.player_code IS NOT NULL),
                ARRAY[]::varchar[]
            ) AS player_codes
        FROM teams t
        JOIN wc2026_groups g     ON g.team_code = t.team_code
        LEFT JOIN team_players tp ON tp.team_id  = t.team_id
            AND tp.season_id = (
                SELECT s.season_id FROM seasons s
                JOIN competitions c ON c.competition_id = s.competition_id
                WHERE c.short_name = 'WC2026' AND s.label = '2026'
            )
            AND tp.status = 'active'
        LEFT JOIN players p      ON p.player_id  = tp.player_id
        WHERE 1=1 {where}
        GROUP BY t.team_code, t.full_name, t.short_name,
                 t.altitude_home_m, t.stadium, g.wc_group, g.seed
        ORDER BY g.wc_group, g.seed
    """, params if params else None)

    teams = {}
    for row in cur.fetchall():
        code = row["team_code"]
        teams[code] = {
            "full_name":       row["full_name"],
            "short_name":      row["short_name"],
            "stadium":         row["stadium"] or f"Estadio {row['full_name']}",
            "altitude_home_m": row["altitude_home_m"],
            "wc_group":        row["wc_group"],
            "seed":            row["seed"],
            "players":         list(row["player_codes"])
        }

    cur.close()
    return teams

'''

def main():
    parser = argparse.ArgumentParser(
        description="Genera config/teams.json desde PostgreSQL (WC2026)"
    )
    parser.add_argument("--db",
                        default="postgresql://postgres:postgres@localhost/whowins")
    parser.add_argument("--group", nargs="+",
                        help="Filtrar por grupo(s) del Mundial (ej: A B C)")
    parser.add_argument("--teams", nargs="+",
                        help="Filtrar por código(s) de equipo (ej: ARG BRA FRA)")
    parser.add_argument("--output", default=None,
                        help="Ruta de salida (default: config/teams_wc2026.json)")
    args = parser.parse_args()

    try:
        conn = psycopg2.connect(args.db)
    except Exception as e:
        print(f"[ERROR] Conexión: {e}")
        sys.exit(1)

    print("Consultando equipos WC2026 desde PostgreSQL...")
    teams = get_wc2026_teams(
        conn,
        group_filter=args.group,
        team_filter=args.teams
    )
    conn.close()

    if not teams:
        print("[WARN] Ningún equipo encontrado. ¿Ejecutaste 02_seed_wc2026.sql?")
        sys.exit(1)

    # Construir config completo
    config = {
        "teams":         teams,
        **R_CONFIG_TEMPLATE
    }

    out_path = args.output or str(
        Path(__file__).parent.parent / "config" / "teams_wc2026.json"
    )
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)

    print(f"\n✓ Config generado: {out_path}")
    print(f"  Equipos incluidos: {len(teams)}")
    print(f"\n  Grupos:")

    by_group = {}
    for code, info in teams.items():
        g = info["wc_group"]
        by_group.setdefault(g, []).append(f"{code}({len(info['players'])} jug.)")
    for g in sorted(by_group):
        print(f"    Grupo {g}: {', '.join(by_group[g])}")

    print(f"\n  Uso en whowins:")
    codes = list(teams.keys())
    if len(codes) >= 2:
        print(f"    whowins {codes[0]} {codes[1]} --config {out_path}")


if __name__ == "__main__":
    main()
