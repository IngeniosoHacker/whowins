# whowins — Pipeline SQL / WC2026
## Orden de ejecución

```
01_schema.sql          → Crea todas las tablas, vistas y funciones
02_seed_wc2026.sql     → Inserta los 48 equipos, grupos y temporada WC2026
03_load_players.py     → Carga jugadores y stats (FBref / API-Football / CSV)
04_generate_config.py  → Genera config/teams_wc2026.json desde la DB
```

---

## 1. Crear el esquema

```bash
psql -U postgres -d whowins -f sql/01_schema.sql
psql -U postgres -d whowins -f sql/02_seed_wc2026.sql
```

---

## 2. Instalar dependencias Python

```bash
pip install psycopg2-binary pandas soccerdata requests
```

---

## 3. Cargar jugadores

### Opción A — FBref (gratuito, no requiere API key)
Descarga stats de las ligas más representativas automáticamente.
```bash
python3 sql/03_load_players.py \
  --db postgresql://postgres:postgres@localhost/whowins \
  --source fbref
```

### Opción B — API-Football (plantillas oficiales WC2026)
Requiere registro gratuito en https://dashboard.api-football.com
```bash
python3 sql/03_load_players.py \
  --db postgresql://postgres:postgres@localhost/whowins \
  --source api \
  --api-key TU_API_KEY
```

### Opción C — Ambas (recomendado: FBref para stats + API para plantillas)
```bash
python3 sql/03_load_players.py \
  --db postgresql://postgres:postgres@localhost/whowins \
  --source all \
  --api-key TU_API_KEY
```

### Opción D — CSV fallback (sin internet)
```bash
python3 sql/03_load_players.py \
  --db postgresql://postgres:postgres@localhost/whowins \
  --source csv
```

### Dry run (verificar sin escribir)
```bash
python3 sql/03_load_players.py --dry-run
```

---

## 4. Generar config para whowins

```bash
# Todos los 48 equipos
python3 sql/04_generate_config.py \
  --db postgresql://postgres:postgres@localhost/whowins

# Solo un grupo
python3 sql/04_generate_config.py --group A B

# Solo equipos específicos
python3 sql/04_generate_config.py --teams ARG FRA BRA GER ESP
```

---

## 5. Correr predicciones con datos reales

```bash
# Argentina vs Francia (grupo D vs grupo E, cancha neutral)
whowins ARG FRA --config config/teams_wc2026.json

# Brasil vs Marruecos (local: Brasil)
whowins BRA MAR --home BRA --config config/teams_wc2026.json

# Partido con clima y altitud específicos
whowins COL ECU --home COL --altitude 2600 --weather cloudy \
  --config config/teams_wc2026.json
```

---

## Fuentes de datos

| Fuente | URL | Requiere key | Datos |
|--------|-----|-------------|-------|
| **FBref** | fbref.com | No | Stats avanzadas, xG, xA, 20+ ligas |
| **API-Football** | api-football.com | Sí (gratis) | Plantillas oficiales, lesiones, ratings |
| **football-data.org** | football-data.org | Sí (gratis) | Partidos, resultados, tablas |
| **Transfermarkt** | transfermarkt.com | No | Valores, posiciones, edades |

### Registro API-Football (gratis, 100 req/día)
1. https://dashboard.api-football.com/register
2. Copiar API key del dashboard
3. Pasar con `--api-key TU_KEY`

---

## Temporadas recomendadas

| Dato | Temporadas | Razón |
|------|-----------|-------|
| Stats de jugadores | 2024-25, 2023-24 | Forma actual |
| Historial de partidos | 2022-23 a 2024-25 | 3 años = ~100 partidos/equipo |
| Head-to-head | Todo disponible | Bayesiano lo pondera por antigüedad |

---

## Estructura de la DB generada

```
countries (56 filas)
competitions (1: WC2026)
seasons (1: 2026)
teams (48 selecciones)
wc2026_groups (48 filas: equipo → grupo A-L)
players (~1,200 jugadores, 26 por selección)
player_seasons (~1,200 × 3 temporadas = ~3,600 filas)
team_players (~1,200 vínculos jugador-selección)
matches (partidos WC2026 + historial previo)
weather_conditions (por partido)
```
