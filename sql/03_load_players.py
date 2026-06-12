#!/usr/bin/env python3
"""
whowins — Cargador de datos: Jugadores del Mundial 2026
========================================================
Soporta selección interactiva de equipos para optimizar
el uso de las primeras 100 consultas de la API.

Uso:
  # Interactivo: menú para elegir qué equipos cargar primero
  python3 sql/03_load_players.py --db postgresql://user:pass@host/db --source api --api-key KEY

  # Cargar por grupo
  python3 sql/03_load_players.py ... --groups A B C

  # Cargar por partido (ambos equipos del partido)
  python3 sql/03_load_players.py ... --match "MEX RSA"

  # Cargar equipos específicos
  python3 sql/03_load_players.py ... --teams ARG FRA BRA GER

  # Cargar por fecha de primer partido (prioridad automática)
  python3 sql/03_load_players.py ... --priority auto --limit 10

  # Sin base de datos (solo ver cuántas requests usaría)
  python3 sql/03_load_players.py --dry-run --teams ARG FRA
"""

import argparse
import csv
import json
import sys
import time
import warnings
from datetime import date, datetime
from pathlib import Path
from typing import Optional

warnings.filterwarnings("ignore")

# ── Dependencias opcionales ────────────────────────────────────────────────────
try:
    import psycopg2
    import psycopg2.extras
    HAS_PSYCOPG2 = True
except ImportError:
    HAS_PSYCOPG2 = False

try:
    import soccerdata as sd
    HAS_SOCCERDATA = True
except ImportError:
    HAS_SOCCERDATA = False

try:
    import requests
    HAS_REQUESTS = True
except ImportError:
    HAS_REQUESTS = False

# =============================================================================
# CALENDARIO COMPLETO — MUNDIAL 2026
# Orden cronológico exacto de todos los partidos de fase de grupos.
# Cada tupla: (fecha, grupo, equipo_A, equipo_B, sede, ciudad)
# Fuente: ESPN/CBS/NBC Sports — junio 2026
# =============================================================================
WC2026_SCHEDULE = [
    # ── Jornada 1 ──────────────────────────────────────────────────────────────
    ("2026-06-11", "A", "MEX", "RSA",  "Estadio Azteca",        "Ciudad de México"),
    ("2026-06-11", "A", "KOR", "CZE",  "Estadio Akron",         "Zapopan"),
    ("2026-06-12", "B", "CAN", "BIH",  "BMO Field",             "Toronto"),
    ("2026-06-12", "D", "USA", "PAR",  "SoFi Stadium",          "Inglewood"),
    ("2026-06-13", "B", "QAT", "SUI",  "Levi's Stadium",        "Santa Clara"),
    ("2026-06-13", "C", "BRA", "MAR",  "MetLife Stadium",       "East Rutherford"),
    ("2026-06-13", "C", "HAI", "SCO",  "Gillette Stadium",      "Foxborough"),
    ("2026-06-13", "D", "AUS", "TUR",  "BC Place",              "Vancouver"),
    ("2026-06-14", "E", "GER", "CUR",  "NRG Stadium",           "Houston"),
    ("2026-06-14", "E", "NED", "JPN",  "Lincoln Financial",     "Filadelfia"),
    ("2026-06-14", "F", "CIV", "ECU",  "Lincoln Financial",     "Filadelfia"),
    ("2026-06-14", "F", "SWE", "TUN",  "Levi's Stadium",        "Santa Clara"),
    ("2026-06-15", "H", "ESP", "CPV",  "Mercedes-Benz Stadium", "Atlanta"),
    ("2026-06-15", "K", "BEL", "EGY",  "SoFi Stadium",          "Inglewood"),
    ("2026-06-15", "K", "KSA", "URU",  "Hard Rock Stadium",     "Miami"),
    ("2026-06-15", "G", "IRN", "NZL",  "BC Place",              "Vancouver"),
    ("2026-06-16", "I", "FRA", "SEN",  "AT&T Stadium",          "Arlington"),
    ("2026-06-16", "I", "IRQ", "NOR",  "MetLife Stadium",       "East Rutherford"),
    ("2026-06-16", "J", "ARG", "ALG",  "AT&T Stadium",          "Arlington"),
    ("2026-06-16", "J", "AUT", "JOR",  "Levi's Stadium",        "Santa Clara"),
    ("2026-06-17", "K", "POR", "UZB",  "NRG Stadium",           "Houston"),
    ("2026-06-17", "L", "ENG", "GHA",  "Gillette Stadium",      "Foxborough"),
    ("2026-06-17", "L", "PAN", "COL",  "SoFi Stadium",          "Inglewood"),  # ajustado
    ("2026-06-17", "F", "TUN", "JPN",  "Estadio BBVA",          "Monterrey"),
    ("2026-06-17", "H", "URU", "CPV",  "Hard Rock Stadium",     "Miami"),
    ("2026-06-17", "G", "ESP", "KSA",  "Mercedes-Benz Stadium", "Atlanta"),
    ("2026-06-17", "G", "BEL", "IRN",  "SoFi Stadium",          "Inglewood"),
    ("2026-06-17", "G", "NZL", "EGY",  "BC Place",              "Vancouver"),

    # ── Jornada 2 ──────────────────────────────────────────────────────────────
    ("2026-06-18", "A", "CZE", "RSA",  "Mercedes-Benz Stadium", "Atlanta"),
    ("2026-06-18", "A", "MEX", "KOR",  "Estadio Akron",         "Zapopan"),
    ("2026-06-18", "B", "SUI", "BIH",  "SoFi Stadium",          "Inglewood"),
    ("2026-06-18", "B", "CAN", "QAT",  "BC Place",              "Vancouver"),
    ("2026-06-19", "C", "BRA", "HAI",  "NRG Stadium",           "Houston"),   # ajustado
    ("2026-06-19", "D", "USA", "AUS",  "Lumen Field",           "Seattle"),
    ("2026-06-19", "D", "TUR", "PAR",  "Levi's Stadium",        "Santa Clara"),
    ("2026-06-20", "E", "GER", "CIV",  "BMO Field",             "Toronto"),
    ("2026-06-20", "E", "ECU", "CUR",  "Arrowhead Stadium",     "Kansas City"),
    ("2026-06-20", "F", "SWE", "NED",  "Lincoln Financial",     "Filadelfia"),
    ("2026-06-21", "H", "ESP", "KSA",  "Mercedes-Benz Stadium", "Atlanta"),
    ("2026-06-21", "H", "URU", "CPV",  "Hard Rock Stadium",     "Miami"),
    ("2026-06-21", "I", "FRA", "IRQ",  "Levi's Stadium",        "Santa Clara"),
    ("2026-06-21", "I", "NOR", "SEN",  "MetLife Stadium",       "East Rutherford"),
    ("2026-06-22", "J", "ARG", "AUT",  "AT&T Stadium",          "Arlington"),
    ("2026-06-22", "J", "ALG", "JOR",  "Levi's Stadium",        "Santa Clara"),
    ("2026-06-22", "K", "POR", "BEL",  "NRG Stadium",           "Houston"),
    ("2026-06-22", "K", "UZB", "EGY",  "SoFi Stadium",          "Inglewood"),
    ("2026-06-23", "L", "ENG", "PAN",  "Gillette Stadium",      "Foxborough"),
    ("2026-06-23", "L", "COL", "GHA",  "SoFi Stadium",          "Inglewood"),
    ("2026-06-23", "C", "MAR", "SCO",  "Lincoln Financial",     "Filadelfia"),
    ("2026-06-23", "B", "SUI", "CAN",  "BC Place",              "Vancouver"),

    # ── Jornada 3 ──────────────────────────────────────────────────────────────
    ("2026-06-24", "A", "CZE", "MEX",  "Estadio Azteca",        "Ciudad de México"),
    ("2026-06-24", "A", "RSA", "KOR",  "Estadio BBVA",          "Monterrey"),
    ("2026-06-24", "B", "BIH", "QAT",  "Lumen Field",           "Seattle"),
    ("2026-06-24", "B", "SUI", "CAN",  "BC Place",              "Vancouver"),
    ("2026-06-25", "D", "TUR", "USA",  "SoFi Stadium",          "Inglewood"),
    ("2026-06-25", "D", "PAR", "AUS",  "Levi's Stadium",        "Santa Clara"),
    ("2026-06-25", "E", "ECU", "GER",  "MetLife Stadium",       "East Rutherford"),
    ("2026-06-25", "E", "CUR", "CIV",  "Arrowhead Stadium",     "Kansas City"),
    ("2026-06-26", "F", "NED", "TUN",  "Lincoln Financial",     "Filadelfia"),
    ("2026-06-26", "F", "JPN", "SWE",  "Estadio BBVA",          "Monterrey"),
    ("2026-06-26", "C", "BRA", "SCO",  "Gillette Stadium",      "Foxborough"),
    ("2026-06-26", "C", "MAR", "HAI",  "NRG Stadium",           "Houston"),
    ("2026-06-27", "G", "BEL", "NZL",  "BC Place",              "Vancouver"),
    ("2026-06-27", "G", "EGY", "IRN",  "SoFi Stadium",          "Inglewood"),
    ("2026-06-27", "H", "ESP", "URU",  "Mercedes-Benz Stadium", "Atlanta"),
    ("2026-06-27", "H", "KSA", "CPV",  "Hard Rock Stadium",     "Miami"),
    ("2026-06-27", "I", "FRA", "NOR",  "MetLife Stadium",       "East Rutherford"),
    ("2026-06-27", "I", "SEN", "IRQ",  "AT&T Stadium",          "Arlington"),
    ("2026-06-27", "J", "ARG", "JOR",  "Levi's Stadium",        "Santa Clara"),
    ("2026-06-27", "J", "ALG", "AUT",  "AT&T Stadium",          "Arlington"),
    ("2026-06-27", "K", "POR", "EGY",  "NRG Stadium",           "Houston"),
    ("2026-06-27", "K", "UZB", "BEL",  "SoFi Stadium",          "Inglewood"),
    ("2026-06-27", "L", "ENG", "COL",  "Gillette Stadium",      "Foxborough"),
    ("2026-06-27", "L", "GHA", "PAN",  "Hard Rock Stadium",     "Miami"),
]

# ── Prioridad automática: equipos ordenados por fecha de primer partido ────────
def build_priority_order() -> list[tuple[str, str]]:
    """
    Retorna lista de (team_code, primera_fecha) ordenada cronológicamente.
    Cada equipo aparece UNA sola vez (su partido más temprano).
    """
    seen   = {}
    for fecha, grupo, a, b, *_ in WC2026_SCHEDULE:
        for team in (a, b):
            if team not in seen:
                seen[team] = fecha
    return sorted(seen.items(), key=lambda x: x[1])

PRIORITY_ORDER = build_priority_order()   # [(team_code, fecha), ...]

# ── requests estimadas por equipo (API-Football) ───────────────────────────────
# squad = 1 req.   stats por jugador = ~26 req (1 por jugador)
REQS_PER_TEAM_SQUAD  = 1
REQS_PER_TEAM_STATS  = 26   # promedio convocatoria
REQS_PER_TEAM_TOTAL  = REQS_PER_TEAM_SQUAD + REQS_PER_TEAM_STATS   # = 27

# =============================================================================
# FUENTE: API-Football — team IDs de selecciones nacionales
# =============================================================================
API_FOOTBALL_TEAM_IDS = {
    "ARG": 26,  "BRA": 6,   "FRA": 2,   "GER": 25,  "ESP": 9,
    "ENG": 10,  "POR": 27,  "NED": 1,   "BEL": 4,   "URU": 31,
    "COL": 30,  "MEX": 16,  "USA": 6,   "JPN": 21,  "KOR": 23,
    "MAR": 32,  "SEN": 33,  "AUS": 26,  "CRO": 3,   "NOR": 11,
    "SUI": 15,  "ECU": 36,  "PAR": 34,  "IRN": 45,  "KSA": 155,
    "QAT": 160, "EGY": 29,  "GHA": 22,  "TUN": 42,  "ALG": 5,
    "CAN": 95,  "CZE": 48,  "SWE": 13,  "AUT": 17,  "SCO": 12,
    "TUR": 19,  "BIH": 18,  "NZL": 56,  "UZB": 83,  "JOR": 79,
    "IRQ": 11,  "COD": 44,  "CPV": 94,  "CIV": 40,  "RSA": 38,
    "CUR": 132, "HAI": 60,  "PAN": 73,  "SCO": 12,
}

TEAM_FULL_NAMES = {
    "MEX":"México",       "RSA":"Sudáfrica",   "KOR":"Corea del Sur",
    "CZE":"Chequia",      "CAN":"Canadá",      "BIH":"Bosnia-Herz.",
    "USA":"Estados Unidos","PAR":"Paraguay",    "QAT":"Qatar",
    "SUI":"Suiza",        "BRA":"Brasil",       "MAR":"Marruecos",
    "HAI":"Haití",        "SCO":"Escocia",      "AUS":"Australia",
    "TUR":"Türkiye",      "GER":"Alemania",     "CUR":"Curazao",
    "NED":"Países Bajos", "JPN":"Japón",        "CIV":"Costa de Marfil",
    "ECU":"Ecuador",      "SWE":"Suecia",       "TUN":"Túnez",
    "ESP":"España",       "CPV":"Cabo Verde",   "BEL":"Bélgica",
    "EGY":"Egipto",       "KSA":"Arabia Saudita","URU":"Uruguay",
    "IRN":"Irán",         "NZL":"Nueva Zelanda","FRA":"Francia",
    "SEN":"Senegal",      "IRQ":"Irak",         "NOR":"Noruega",
    "ARG":"Argentina",    "ALG":"Argelia",      "AUT":"Austria",
    "JOR":"Jordania",     "POR":"Portugal",     "UZB":"Uzbekistán",
    "ENG":"Inglaterra",   "GHA":"Ghana",        "PAN":"Panamá",
    "COL":"Colombia",     "COD":"RD Congo",     "CRO":"Croacia",
}

FBREF_POS_MAP = {
    "GK":"GK","CB":"CB","LB":"LB","RB":"RB","LWB":"LB","RWB":"RB",
    "DM":"DM","CM":"CM","AM":"AM","LM":"CM","RM":"CM",
    "LW":"LW","RW":"RW","SS":"SS","CF":"FW","FW":"FW","ST":"FW",
    "MF":"CM","DF":"CB","FO":"FW",
}

# =============================================================================
# SELECCIÓN INTERACTIVA DE EQUIPOS
# =============================================================================

def show_priority_menu(limit: int = 100) -> list[str]:
    """
    Muestra el menú interactivo y retorna la lista de team_codes a cargar.
    """
    print()
    print("═"*70)
    print("  ⚽  SELECTOR DE EQUIPOS — Mundial 2026")
    print("  Límite API: 100 requests/día ≈ 3-4 equipos completos (squad+stats)")
    print("═"*70)

    # Calcular cuántos equipos caben en el límite
    max_equipos = limit // REQS_PER_TEAM_TOTAL
    print(f"\n  Con {limit} requests puedes cargar: "
          f"{max_equipos} equipos completos "
          f"({REQS_PER_TEAM_TOTAL} req/equipo) "
          f"o {limit} si solo cargas plantilla (sin stats, 1 req/equipo)\n")

    print("  OPCIONES:")
    print("  ─"*35)
    print("  [1] Automático: ordenado por fecha de primer partido")
    print("  [2] Por grupos (A–L)")
    print("  [3] Por partido (cargar ambos equipos de un match)")
    print("  [4] Selección manual de equipos")
    print("  [5] Todos (48 equipos — necesita varios días con plan free)")
    print()
    choice = input("  Elige una opción [1-5]: ").strip()
    print()

    if choice == "1":
        return _select_by_priority(max_equipos)
    elif choice == "2":
        return _select_by_group(max_equipos)
    elif choice == "3":
        return _select_by_match(max_equipos)
    elif choice == "4":
        return _select_manual(max_equipos)
    elif choice == "5":
        all_teams = [t for t, _ in PRIORITY_ORDER]
        print(f"  → {len(all_teams)} equipos seleccionados "
              f"(~{len(all_teams)*REQS_PER_TEAM_TOTAL} requests, "
              f"{len(all_teams)*REQS_PER_TEAM_TOTAL//limit} días con plan free)")
        return all_teams
    else:
        print("  Opción inválida. Usando modo automático.")
        return _select_by_priority(max_equipos)


def _select_by_priority(max_teams: int) -> list[str]:
    """Opción 1: primeros N equipos por fecha de primer partido."""
    print("  Equipos ordenados por fecha de primer partido:\n")
    print(f"  {'#':>3}  {'Código':<6}  {'País':<22}  {'Primer partido':<20}  {'Req'}")
    print("  " + "─"*62)

    total_req = 0
    available = []
    for i, (code, fecha) in enumerate(PRIORITY_ORDER, 1):
        req = REQS_PER_TEAM_TOTAL
        total_req += req
        marca = "✓" if i <= max_teams else "✗"
        print(f"  {i:>3}  {code:<6}  {TEAM_FULL_NAMES.get(code,code):<22}  {fecha:<20}  {req:>3}  {marca}")
        available.append(code)

    print(f"\n  Total requests si cargas los primeros {max_teams}: "
          f"{max_teams * REQS_PER_TEAM_TOTAL}")
    n = input(f"\n  ¿Cuántos equipos cargar? (1-{len(available)}, Enter={max_teams}): ").strip()
    n = int(n) if n.isdigit() else max_teams
    n = min(n, len(available))

    selected = available[:n]
    print(f"\n  ✓ Seleccionados: {', '.join(selected)}")
    return selected


def _select_by_group(max_teams: int) -> list[str]:
    """Opción 2: elegir grupos completos."""
    # Construir mapa grupo → equipos (en orden de partido)
    groups: dict[str, list[str]] = {}
    seen = set()
    for _, grp, a, b, *_ in WC2026_SCHEDULE:
        groups.setdefault(grp, [])
        for t in (a, b):
            if t not in seen:
                groups[grp].append(t)
                seen.add(t)

    print("  Grupos disponibles:\n")
    for g in sorted(groups):
        teams = groups[g]
        names = " · ".join(TEAM_FULL_NAMES.get(t, t) for t in teams)
        req   = len(teams) * REQS_PER_TEAM_TOTAL
        print(f"  Grupo {g}: {names:<55}  (~{req} req)")

    print()
    raw = input("  Escribe los grupos a cargar (ej: A B C, o 'Enter' para A): ").strip().upper()
    chosen_groups = raw.split() if raw else ["A"]

    selected = []
    for g in chosen_groups:
        for t in groups.get(g, []):
            if t not in selected:
                selected.append(t)

    req_total = len(selected) * REQS_PER_TEAM_TOTAL
    print(f"\n  ✓ {len(selected)} equipos seleccionados "
          f"(~{req_total} requests)")
    if req_total > 100:
        print(f"  ⚠  Excede 100 req del plan free. "
              f"Se cargarán los primeros {max_teams} equipos.")
        selected = selected[:max_teams]
    return selected


def _select_by_match(max_teams: int) -> list[str]:
    """Opción 3: seleccionar partidos del calendario."""
    print("  Partidos del Mundial 2026 (orden cronológico):\n")
    print(f"  {'#':>3}  {'Fecha':<12}  {'Gr':<3}  {'Partido':<35}  {'Req'}")
    print("  " + "─"*62)

    unique_matches = []
    seen_pairs = set()
    for fecha, grp, a, b, sede, ciudad in WC2026_SCHEDULE:
        pair = (a, b)
        if pair not in seen_pairs:
            unique_matches.append((fecha, grp, a, b, ciudad))
            seen_pairs.add(pair)

    for i, (fecha, grp, a, b, ciudad) in enumerate(unique_matches, 1):
        na = TEAM_FULL_NAMES.get(a, a)
        nb = TEAM_FULL_NAMES.get(b, b)
        partido = f"{na} vs {nb}"
        req = REQS_PER_TEAM_TOTAL * 2
        print(f"  {i:>3}  {fecha:<12}  {grp:<3}  {partido:<35}  ~{req}")

    print()
    raw = input("  Números de partido a cargar (ej: 1 2 3 6, o Enter para 1-4): ").strip()
    nums = [int(x) for x in raw.split() if x.isdigit()] if raw else list(range(1, 5))

    selected = []
    total_req = 0
    for n in nums:
        if 1 <= n <= len(unique_matches):
            _, _, a, b, _ = unique_matches[n-1]
            for t in (a, b):
                if t not in selected:
                    selected.append(t)
                    total_req += REQS_PER_TEAM_TOTAL

    print(f"\n  ✓ {len(selected)} equipos seleccionados "
          f"(~{total_req} requests)")
    if total_req > 100:
        print(f"  ⚠  Excede 100 req. Se cargarán los primeros {max_teams}.")
        selected = selected[:max_teams]
    return selected


def _select_manual(max_teams: int) -> list[str]:
    """Opción 4: escribir códigos manualmente."""
    print("  Todos los equipos disponibles:\n")
    codes = [t for t, _ in PRIORITY_ORDER]
    cols  = 8
    for i in range(0, len(codes), cols):
        row = codes[i:i+cols]
        print("  " + "  ".join(f"{c:<5}" for c in row))

    print()
    raw = input("  Escribe los códigos a cargar (ej: ARG FRA BRA): ").strip().upper()
    selected = [t.strip() for t in raw.split() if t.strip() in API_FOOTBALL_TEAM_IDS]

    if not selected:
        print("  Ningún código válido. Usando los primeros 3.")
        selected = codes[:3]

    req_total = len(selected) * REQS_PER_TEAM_TOTAL
    print(f"\n  ✓ {len(selected)} equipos: {', '.join(selected)}")
    print(f"  Requests estimadas: ~{req_total}")
    if req_total > 100:
        print(f"  ⚠  Excede 100 req. Se cargarán los primeros {max_teams}.")
        selected = selected[:max_teams]
    return selected

# =============================================================================
# DB HELPERS
# =============================================================================

def connect(db_url: str):
    if not HAS_PSYCOPG2:
        raise RuntimeError("pip install psycopg2-binary")
    return psycopg2.connect(db_url)


def get_season_id(cur, label: str = "2026") -> int:
    cur.execute("""
        SELECT s.season_id FROM seasons s
        JOIN competitions c ON c.competition_id = s.competition_id
        WHERE c.short_name = 'WC2026' AND s.label = %s
    """, (label,))
    row = cur.fetchone()
    if not row:
        raise ValueError("Temporada WC2026/2026 no encontrada. Ejecuta 02_seed_wc2026.sql primero.")
    return row[0]


def get_team_id(cur, team_code: str) -> Optional[int]:
    cur.execute("SELECT team_id FROM teams WHERE team_code = %s", (team_code,))
    row = cur.fetchone()
    return row[0] if row else None


def upsert_player(cur, p: dict) -> int:
    cur.execute("""
        INSERT INTO players
            (player_code, full_name, short_name, position_primary, foot,
             height_cm, weight_kg, date_of_birth, active)
        VALUES
            (%(code)s, %(name)s, %(short_name)s, %(pos)s::player_position,
             %(foot)s::player_foot, %(height)s, %(weight)s, %(dob)s, TRUE)
        ON CONFLICT (player_code) DO UPDATE SET
            full_name        = EXCLUDED.full_name,
            position_primary = EXCLUDED.position_primary,
            updated_at       = NOW()
        RETURNING player_id
    """, p)
    return cur.fetchone()[0]


def upsert_team_player(cur, team_id: int, player_id: int, season_id: int,
                        jersey: Optional[int] = None):
    cur.execute("""
        INSERT INTO team_players (team_id, player_id, season_id, jersey_number, status)
        VALUES (%s, %s, %s, %s, 'active')
        ON CONFLICT (team_id, player_id, season_id) DO NOTHING
    """, (team_id, player_id, season_id, jersey))


def upsert_player_season(cur, player_id: int, team_id: int, season_id: int, stats: dict):
    cur.execute("""
        INSERT INTO player_seasons (
            player_id, team_id, season_id,
            matches_played, matches_started, minutes_played,
            goals, assists, shots_total, shots_on_target,
            key_passes, dribbles_attempted, dribbles_completed,
            big_chances_created, expected_goals, expected_assists,
            tackles, tackles_won, interceptions, clearances, blocks,
            duels_total, duels_won, aerial_total, aerial_won,
            pass_total, pass_completed,
            saves, goals_conceded, clean_sheets,
            yellow_cards, red_cards, fouls_committed, fouls_drawn,
            rating_avg, rating_source
        ) VALUES (
            %(player_id)s, %(team_id)s, %(season_id)s,
            %(mp)s, %(ms)s, %(min)s,
            %(goals)s, %(assists)s, %(shots)s, %(shots_ot)s,
            %(key_pass)s, %(drb_att)s, %(drb_cmp)s,
            %(bcc)s, %(xg)s, %(xa)s,
            %(tackles)s, %(tkl_won)s, %(intercept)s, %(clr)s, %(blk)s,
            %(duels)s, %(duels_won)s, %(aerial)s, %(aerial_won)s,
            %(pass_tot)s, %(pass_cmp)s,
            %(saves)s, %(gc)s, %(cs)s,
            %(yc)s, %(rc)s, %(fouls_c)s, %(fouls_d)s,
            %(rating)s, %(rating_src)s
        )
        ON CONFLICT (player_id, team_id, season_id) DO UPDATE SET
            matches_played  = EXCLUDED.matches_played,
            goals           = EXCLUDED.goals,
            assists         = EXCLUDED.assists,
            shots_on_target = EXCLUDED.shots_on_target,
            expected_goals  = EXCLUDED.expected_goals,
            tackles         = EXCLUDED.tackles,
            interceptions   = EXCLUDED.interceptions,
            pass_total      = EXCLUDED.pass_total,
            pass_completed  = EXCLUDED.pass_completed,
            yellow_cards    = EXCLUDED.yellow_cards,
            red_cards       = EXCLUDED.red_cards,
            rating_avg      = EXCLUDED.rating_avg
    """, stats)


def upsert_match(cur, season_id: int, m: dict):
    """Inserta un partido del calendario WC2026 (sin resultado aún)."""
    # Obtener IDs de equipos
    cur.execute("SELECT team_id FROM teams WHERE team_code=%s", (m["home"],))
    row = cur.fetchone()
    if not row: return
    home_id = row[0]
    cur.execute("SELECT team_id FROM teams WHERE team_code=%s", (m["away"],))
    row = cur.fetchone()
    if not row: return
    away_id = row[0]

    cur.execute("""
        INSERT INTO matches
            (match_code, home_team_id, away_team_id, season_id,
             match_date, competition, stage, neutral_venue, altitude_m)
        VALUES
            (%(code)s, %(home_id)s, %(away_id)s, %(season_id)s,
             %(date)s, 'continental', 'group_stage', TRUE, 0)
        ON CONFLICT (match_code) DO NOTHING
    """, {
        "code":      f"WC2026_{m['home']}_{m['away']}",
        "home_id":   home_id,
        "away_id":   away_id,
        "season_id": season_id,
        "date":      m["date"],
    })

# =============================================================================
# CARGA DESDE API-FOOTBALL
# =============================================================================

def fetch_squad(team_fifa_id: int, api_key: str) -> list:
    if not HAS_REQUESTS: return []
    url = "https://v3.football.api-sports.io/players/squads"
    try:
        r = requests.get(url,
                         headers={"x-apisports-key": api_key},
                         params={"team": team_fifa_id},
                         timeout=15)
        data = r.json()
        players = data.get("response", [{}])[0].get("players", [])
        time.sleep(1.2)
        return players
    except Exception as e:
        print(f"    [WARN] squad {team_fifa_id}: {e}")
        return []


def fetch_player_stats(player_id: int, season: int, api_key: str) -> dict:
    if not HAS_REQUESTS: return {}
    url = "https://v3.football.api-sports.io/players"
    try:
        r = requests.get(url,
                         headers={"x-apisports-key": api_key},
                         params={"id": player_id, "season": season},
                         timeout=15)
        data = r.json()
        resp = data.get("response", [])
        time.sleep(1.2)
        return resp[0] if resp else {}
    except Exception as e:
        print(f"    [WARN] stats player {player_id}: {e}")
        return {}


def normalize_api_player(p_data: dict, squad_row: dict) -> tuple[dict, dict]:
    info  = p_data.get("player", {})
    stats_list = p_data.get("statistics", [])
    # Sumar stats de todas las ligas
    totals: dict = {}
    for s in stats_list:
        for section, vals in s.items():
            if isinstance(vals, dict):
                totals.setdefault(section, {})
                for k, v in vals.items():
                    if isinstance(v, (int, float)) and v is not None:
                        totals[section][k] = totals[section].get(k, 0) + v

    def iv(sec, k):
        return int(totals.get(sec, {}).get(k) or 0)
    def fv(sec, k):
        v = totals.get(sec, {}).get(k)
        return round(float(v), 2) if v else 0.0

    name = info.get("name") or squad_row.get("name", "Unknown")
    pid  = info.get("id", 0)
    code = f"API_{pid}"

    pos_raw = (info.get("position") or "Midfielder").split()[0].upper()
    pos = {"GOALKEEPER":"GK","DEFENDER":"CB",
           "MIDFIELDER":"CM","ATTACKER":"FW","FORWARD":"FW"}.get(pos_raw, "CM")

    dob = info.get("birth", {}).get("date")
    try:    dob = datetime.strptime(dob, "%Y-%m-%d").date() if dob else None
    except: dob = None

    def parse_cm(s):
        try: return int(str(s).replace("cm","").strip()) if s else None
        except: return None
    def parse_kg(s):
        try: return float(str(s).replace("kg","").replace(",",".").strip()) if s else None
        except: return None

    player_dict = {
        "code":       code,
        "name":       name,
        "short_name": name[:30],
        "pos":        pos,
        "foot":       (info.get("foot") or "right").lower(),
        "height":     parse_cm(info.get("height")),
        "weight":     parse_kg(info.get("weight")),
        "dob":        dob,
    }

    games = totals.get("games", {})
    stats_dict = {
        "mp":  iv("games","appearences"), "ms": iv("games","lineups"),
        "min": iv("games","minutes"),
        "goals":    iv("goals","total"), "assists": iv("goals","assists"),
        "shots":    iv("shots","total"), "shots_ot": iv("shots","on"),
        "key_pass": iv("passes","key"),
        "drb_att":  iv("dribbles","attempts"),
        "drb_cmp":  iv("dribbles","success"),
        "bcc":      0, "xg": 0.0, "xa": 0.0,
        "tackles":  iv("tackles","total"),
        "tkl_won":  iv("tackles","blocks"),
        "intercept":iv("tackles","interceptions"),
        "clr":      0, "blk": iv("tackles","blocks"),
        "duels":    iv("duels","total"), "duels_won": iv("duels","won"),
        "aerial":   0, "aerial_won": 0,
        "pass_tot": iv("passes","total"), "pass_cmp": iv("passes","accuracy"),
        "saves":    iv("goals","saves") or None,
        "gc":       iv("goals","conceded") or None,
        "cs":       None,
        "yc":       iv("cards","yellow"), "rc": iv("cards","red"),
        "fouls_c":  iv("fouls","committed"), "fouls_d": iv("fouls","drawn"),
        "rating":   fv("games","rating") or None,
        "rating_src": "api-football",
    }
    return player_dict, stats_dict


def load_teams_api(conn, teams: list[str], season_id: int,
                   api_key: str, only_squad: bool, dry_run: bool):
    """
    Carga los equipos indicados desde API-Football.
    Si only_squad=True, solo gasta 1 req por equipo (sin stats individuales).
    """
    cur = conn.cursor()
    req_count = 0
    total_players = 0

    for team_code in teams:
        fifa_id = API_FOOTBALL_TEAM_IDS.get(team_code)
        if not fifa_id:
            print(f"  [SKIP] {team_code}: sin FIFA ID mapeado")
            continue

        team_id = get_team_id(cur, team_code)
        if not team_id:
            print(f"  [SKIP] {team_code}: no encontrado en DB (ejecuta 02_seed_wc2026.sql)")
            continue

        print(f"\n  → {team_code} ({TEAM_FULL_NAMES.get(team_code,'')}) "
              f"[FIFA ID: {fifa_id}]")

        # ── 1 request: plantilla ─────────────────────────────────────────────
        if dry_run:
            print(f"    [DRY] Simularía GET /players/squads?team={fifa_id}  (1 req)")
            req_count += 1
            continue

        squad = fetch_squad(fifa_id, api_key)
        req_count += 1
        print(f"    ✓ Plantilla: {len(squad)} jugadores  (req #{req_count})")

        if not squad:
            continue

        # ── N requests: stats por jugador ────────────────────────────────────
        for p_basic in squad:
            pid_api  = p_basic.get("id")
            pname    = p_basic.get("name","?")
            jersey   = p_basic.get("number")

            if only_squad:
                # Solo insertar jugador sin stats
                pd = {
                    "code": f"API_{pid_api}", "name": pname,
                    "short_name": pname[:30], "pos": "CM",
                    "foot": "right", "height": None, "weight": None, "dob": None,
                }
                try:
                    db_pid = upsert_player(cur, pd)
                    upsert_team_player(cur, team_id, db_pid, season_id, jersey)
                    total_players += 1
                except Exception as e:
                    print(f"    [WARN] {pname}: {e}")
            else:
                # 1 request adicional por jugador
                p_full = fetch_player_stats(pid_api, 2024, api_key)
                req_count += 1

                if not p_full:
                    p_full = {"player": p_basic, "statistics": []}

                try:
                    player_dict, stats_dict = normalize_api_player(p_full, p_basic)
                    db_pid = upsert_player(cur, player_dict)
                    upsert_team_player(cur, team_id, db_pid, season_id, jersey)
                    stats_dict["player_id"] = db_pid
                    stats_dict["team_id"]   = team_id
                    stats_dict["season_id"] = season_id
                    upsert_player_season(cur, db_pid, team_id, season_id, stats_dict)
                    total_players += 1
                    print(f"    {pname:<25} req #{req_count}")
                except Exception as e:
                    print(f"    [WARN] {pname}: {e}")

        conn.commit()
        print(f"  ✓ {team_code}: commit OK  (requests usadas: {req_count})")

    cur.close()
    return req_count, total_players


# =============================================================================
# CARGA CSV DE CALENDARIO
# =============================================================================

def load_schedule(conn, season_id: int, dry_run: bool):
    """Inserta todos los partidos de la fase de grupos en la tabla matches."""
    cur = conn.cursor()
    count = 0
    for fecha, grp, a, b, sede, ciudad in WC2026_SCHEDULE:
        m = {"home": a, "away": b, "date": fecha}
        if dry_run:
            print(f"  [DRY] {fecha}  {a} vs {b}")
        else:
            upsert_match(cur, season_id, m)
        count += 1
    if not dry_run:
        conn.commit()
    cur.close()
    print(f"  ✓ {count} partidos del calendario insertados")


# =============================================================================
# CSV FALLBACK
# =============================================================================

def load_csv_fallback(conn, season_id: int, dry_run: bool):
    csv_path = Path(__file__).parent.parent / "data" / "players.csv"
    if not csv_path.exists():
        print("  [SKIP] data/players.csv no encontrado")
        return

    cur = conn.cursor()
    count = 0
    with open(csv_path) as f:
        for row in csv.DictReader(f):
            pos = FBREF_POS_MAP.get(row.get("position","CM").upper(), "CM")
            pd  = {
                "code": row["player_id"], "name": row["name"],
                "short_name": row["name"][:30], "pos": pos,
                "foot": "right", "height": None, "weight": None, "dob": None,
            }
            shots_ot  = int(row.get("shots_on_target", 0))
            shots_tot = max(shots_ot, int(row.get("shots_total", 0)))
            pass_cmp  = int(row.get("pass_completed", 0))
            pass_tot  = max(pass_cmp, int(row.get("pass_total", 0)))
            sd_ = {
                "mp":int(row.get("matches",0)), "ms":0, "min":int(row.get("minutes_played",0)),
                "goals":int(row.get("goals",0)), "assists":int(row.get("assists",0)),
                "shots":shots_tot, "shots_ot":shots_ot,
                "key_pass":0, "drb_att":int(row.get("dribbles_completed",0)),
                "drb_cmp":int(row.get("dribbles_completed",0)),
                "bcc":0, "xg":0.0, "xa":0.0,
                "tackles":int(row.get("tackles",0)), "tkl_won":0,
                "intercept":int(row.get("interceptions",0)),
                "clr":0, "blk":0, "duels":0, "duels_won":0, "aerial":0, "aerial_won":0,
                "pass_tot":pass_tot, "pass_cmp":pass_cmp,
                "saves":None, "gc":None, "cs":None,
                "yc":int(row.get("yellow_cards",0)), "rc":int(row.get("red_cards",0)),
                "fouls_c":0, "fouls_d":0,
                "rating":float(row.get("rating",7.0)) if row.get("rating") else None,
                "rating_src":"csv",
            }
            team_id = get_team_id(cur, row.get("team_id","")) or 1
            if not dry_run:
                try:
                    db_pid = upsert_player(cur, pd)
                    upsert_team_player(cur, team_id, db_pid, season_id)
                    sd_["player_id"] = db_pid
                    sd_["team_id"]   = team_id
                    sd_["season_id"] = season_id
                    upsert_player_season(cur, db_pid, team_id, season_id, sd_)
                    count += 1
                except Exception as e:
                    conn.rollback()
                    print(f"  [WARN] {pd['name']}: {str(e).split(chr(10))[0]}")

    if not dry_run:
        conn.commit()
    cur.close()
    print(f"  ✓ {count} jugadores desde CSV")


# =============================================================================
# RESUMEN
# =============================================================================

def print_summary(conn):
    cur = conn.cursor()
    cur.execute("SELECT COUNT(*) FROM players")
    np = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM player_seasons")
    ns = cur.fetchone()[0]
    cur.execute("""
        SELECT t.team_code, COUNT(tp.player_id)
        FROM team_players tp JOIN teams t ON t.team_id=tp.team_id
        GROUP BY t.team_code ORDER BY COUNT(tp.player_id) DESC LIMIT 10
    """)
    by_team = cur.fetchall()
    cur.close()
    print("\n" + "="*50)
    print(f"  Jugadores en DB : {np}")
    print(f"  Registros stats : {ns}")
    print(f"\n  Top equipos cargados:")
    for code, cnt in by_team:
        bar = "█" * min(cnt, 26)
        print(f"    {code:<6} {bar} {cnt}")
    print("="*50)


# =============================================================================
# CLI
# =============================================================================

def main():
    p = argparse.ArgumentParser(
        description="Cargador de jugadores WC2026 → PostgreSQL",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Ejemplos:
  # Menú interactivo (recomendado para plan free 100 req/día)
  python3 03_load_players.py --db postgresql://... --source api --api-key KEY

  # Cargar 2 equipos específicos sin menú
  python3 03_load_players.py --db ... --source api --api-key KEY --teams ARG FRA

  # Cargar todos los equipos de un grupo
  python3 03_load_players.py --db ... --source api --api-key KEY --groups A B

  # Cargar ambos equipos de los primeros N partidos
  python3 03_load_players.py --db ... --source api --api-key KEY --matches 1 2 3 4

  # Solo plantilla (1 req/equipo en lugar de 27) — útil para plan free
  python3 03_load_players.py --db ... --source api --api-key KEY --teams ARG --only-squad

  # Insertar calendario de partidos en la DB
  python3 03_load_players.py --db ... --load-schedule

  # Dry run: ver qué haría sin escribir nada
  python3 03_load_players.py --dry-run --teams ARG FRA
"""
    )
    p.add_argument("--db",
                   default="postgresql://postgres:postgres@localhost/whowins",
                   help="URL de conexión PostgreSQL")
    p.add_argument("--source", choices=["api","csv","all"], default="csv",
                   help="Fuente de datos")
    p.add_argument("--api-key", default=None, help="API key de api-football.com")
    p.add_argument("--dry-run", action="store_true",
                   help="Simula sin escribir a DB")

    # Selección de equipos (mutuamente excluyentes)
    sel = p.add_mutually_exclusive_group()
    sel.add_argument("--teams",    nargs="+", metavar="CODE",
                     help="Códigos de equipo a cargar (ej: ARG FRA BRA)")
    sel.add_argument("--groups",   nargs="+", metavar="GRP",
                     help="Grupos del Mundial a cargar (ej: A B C)")
    sel.add_argument("--matches",  nargs="+", type=int, metavar="N",
                     help="Números de partido del calendario (ej: 1 2 3)")
    sel.add_argument("--priority", type=int, metavar="N",
                     help="Primeros N equipos por fecha de primer partido")
    sel.add_argument("--all",      action="store_true",
                     help="Cargar los 48 equipos")

    p.add_argument("--only-squad", action="store_true",
                   help="Solo plantilla (1 req/equipo), sin stats individuales")
    p.add_argument("--limit", type=int, default=100,
                   help="Límite de requests disponibles (default: 100)")
    p.add_argument("--season", default="2024", type=int,
                   help="Temporada de stats a solicitar (default: 2024)")
    p.add_argument("--load-schedule", action="store_true",
                   help="Insertar el calendario de partidos WC2026 en la DB")
    args = p.parse_args()

    print("="*60)
    print("  ⚽  whowins — Loader WC2026")
    print(f"  Fuente   : {args.source}")
    print(f"  Dry run  : {args.dry_run}")
    print(f"  Límite   : {args.limit} requests")
    print("="*60)

    if args.dry_run:
        print("\n  [DRY RUN] No se escribe nada a la base de datos.\n")

    # ── Conexión ──────────────────────────────────────────────────────────────
    if not args.dry_run:
        if not HAS_PSYCOPG2:
            print("[ERROR] pip install psycopg2-binary"); sys.exit(1)
        try:
            conn = connect(args.db)
            cur  = conn.cursor()
            season_id = get_season_id(cur, "2026")
            cur.close()
            print(f"\n  ✓ PostgreSQL conectado | season_id={season_id}")
        except Exception as e:
            print(f"[ERROR] {e}"); sys.exit(1)
    else:
        conn      = None
        season_id = 0

    # ── Calendario ────────────────────────────────────────────────────────────
    if args.load_schedule:
        print("\n[CALENDARIO] Insertando partidos WC2026...")
        if not args.dry_run:
            load_schedule(conn, season_id, dry_run=False)
        else:
            load_schedule(None, 0, dry_run=True)

    # ── Determinar equipos a cargar ───────────────────────────────────────────
    if args.source in ("api", "all"):
        if not args.api_key and not args.dry_run:
            print("[ERROR] --api-key requerida para fuente api"); sys.exit(1)

        # Resolver selección
        if args.all:
            teams = [t for t, _ in PRIORITY_ORDER]
        elif args.teams:
            teams = [t.upper() for t in args.teams if t.upper() in API_FOOTBALL_TEAM_IDS]
        elif args.groups:
            seen, teams = set(), []
            for _, grp, a, b, *_ in WC2026_SCHEDULE:
                if grp.upper() in [g.upper() for g in args.groups]:
                    for t in (a, b):
                        if t not in seen:
                            teams.append(t); seen.add(t)
        elif args.matches:
            pairs = [(a, b) for _, _, a, b, *_ in WC2026_SCHEDULE]
            pairs = list(dict.fromkeys(pairs))   # dedup preservando orden
            seen, teams = set(), []
            for n in args.matches:
                if 1 <= n <= len(pairs):
                    for t in pairs[n-1]:
                        if t not in seen:
                            teams.append(t); seen.add(t)
        elif args.priority:
            teams = [t for t, _ in PRIORITY_ORDER[:args.priority]]
        else:
            # Menú interactivo
            teams = show_priority_menu(args.limit)

        if not teams:
            print("[WARN] Ningún equipo seleccionado."); sys.exit(0)

        # Calcular requests y advertir
        req_est = len(teams) * (1 if args.only_squad else REQS_PER_TEAM_TOTAL)
        print(f"\n  Equipos a cargar : {len(teams)}")
        print(f"  Requests estimadas: {req_est} / {args.limit}")
        if req_est > args.limit:
            dias = -(-req_est // args.limit)  # ceil
            print(f"  ⚠  Excede el límite diario. Necesitarás ~{dias} días.")
            r = input("  ¿Continuar de todas formas? [s/N]: ").strip().lower()
            if r != "s":
                print("  Cancelado.")
                sys.exit(0)

        print(f"\n  Orden de carga:")
        for i, t in enumerate(teams, 1):
            fecha = dict(PRIORITY_ORDER).get(t, "?")
            print(f"    {i:>2}. {t:<6} {TEAM_FULL_NAMES.get(t,''):<22} primer partido: {fecha}")

        print()
        req_used, n_players = load_teams_api(
            conn, teams, season_id, args.api_key or "",
            only_squad=args.only_squad, dry_run=args.dry_run
        )
        print(f"\n  Requests usadas : {req_used}")
        print(f"  Jugadores cargados: {n_players}")

    if args.source in ("csv", "all"):
        print("\n[CSV] Cargando jugadores desde CSV...")
        if not args.dry_run:
            load_csv_fallback(conn, season_id, dry_run=False)
        else:
            print("  [DRY] Se leería data/players.csv")

    if not args.dry_run and conn:
        print_summary(conn)
        conn.close()

    print("\n✓ Proceso completado.")


if __name__ == "__main__":
    main()
