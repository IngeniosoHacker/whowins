# ⚽ whowins v2 — Predictor Estadístico de Fútbol (Mundial 2026)

Predice el resultado de un partido combinando **Regresión Multinomial + Naive
Bayes por jugador + Distribución de Poisson + Actualización Bayesiana
head-to-head**, todo filtrado previamente por **ANOVA multifactorial**.
Incluye pipeline completo de base de datos PostgreSQL con los 48 equipos del
Mundial 2026.

```
whowins ARG FRA
# → Argentina 58%   Francia 25%   Empate 17%
# → Resultado más probable: 2-1
```

---

## Tabla de contenidos

1. [Requisitos](#1-requisitos)
2. [Inicio rápido](#2-inicio-rápido)
3. [Uso del comando](#3-uso-del-comando)
4. [Fuentes de datos: CSV vs PostgreSQL](#4-fuentes-de-datos-csv-vs-postgresql)
5. [Setup de PostgreSQL desde cero](#5-setup-de-postgresql-desde-cero)
6. [Cargar jugadores del Mundial 2026](#6-cargar-jugadores-del-mundial-2026)
7. [Generar config desde la base de datos](#7-generar-config-desde-la-base-de-datos)
8. [Formato de archivos CSV](#8-formato-de-archivos-csv)
9. [Configuración de equipos (JSON)](#9-configuración-de-equipos-json)
10. [Metodología estadística](#10-metodología-estadística)
11. [Archivos de salida](#11-archivos-de-salida)
12. [Ejemplos — Mundial 2026](#12-ejemplos--mundial-2026)
13. [Estructura del proyecto](#13-estructura-del-proyecto)
14. [Preguntas frecuentes](#14-preguntas-frecuentes)

---

## 1. Requisitos

| Componente   | Versión mínima | Notas |
|--------------|---------------|-------|
| **R**        | 4.0           | Motor estadístico |
| **Bash**     | 4.0           | CLI principal |
| **Python**   | 3.8           | Pipeline de base de datos |
| **PostgreSQL** | 14          | Opcional — modo CSV no lo necesita |

**Paquetes R** (el instalador los agrega automáticamente):
```
dplyr  tidyr  readr  jsonlite  ggplot2  car  MASS
nnet   e1071  lmtest  pROC
```
Para modo PostgreSQL, además: `DBI`, `RPostgres`

**Paquetes Python** (el setup los instala automáticamente):
```
psycopg2-binary   soccerdata (opcional)   requests (opcional)
```

---

## 2. Inicio rápido

### Sin base de datos (modo CSV — listo en 2 minutos)

```bash
unzip whowins_v2_wc2026.zip && cd whowins/
bash install.sh
whowins TeamA TeamB
```

### Con PostgreSQL y datos reales del Mundial 2026

```bash
unzip whowins_v2_wc2026.zip && cd whowins/

# Un solo comando crea la DB, aplica el esquema, inserta los 48 equipos,
# carga el calendario y genera el config JSON
python3 sql/setup.py \
  --host localhost --user postgres --password tu_password \
  --api-key TU_API_KEY

# Predecir
whowins ARG FRA --config config/teams_wc2026.json
```

---

## 3. Uso del comando

```
whowins <EquipoA> <EquipoB> [opciones]
```

| Opción | Valores | Default | Descripción |
|--------|---------|---------|-------------|
| `--home` | código de equipo ó `neutral` | `neutral` | Quién juega de local |
| `--weather` | `clear` `cloudy` `rain` | `clear` | Condición climática |
| `--altitude` | metros | altitud del estadio local | Altitud del estadio |
| `--output` | directorio | `output/<timestamp>` | Carpeta de resultados |
| `--config` | ruta .json | `config/teams.json` | Archivo de equipos |
| `--list` | — | — | Lista equipos disponibles en el config |
| `--help` | — | — | Ayuda |

**Ejemplos:**

```bash
# Cancha neutral
whowins ARG FRA

# Con ventaja local y clima
whowins MEX KOR --home MEX --altitude 2240 --weather cloudy

# Con config del Mundial
whowins BRA GER --config config/teams_wc2026.json --home BRA

# Ver qué equipos hay cargados
whowins --list --config config/teams_wc2026.json

# Guardar en carpeta propia
whowins ESP ENG --output resultados/semifinal --config config/teams_wc2026.json
```

**Salida en consola:**

```
Argentina 58%
Francia 25%
Empate 17%

Resultado más probable : 2-1
Goles esperados        : Argentina 1.8  |  Francia 1.2
Enfrentamientos H2H    : 8  (peso Bayesiano: 0.35)

Reporte: output/20260615_ARG_vs_FRA/reporte_completo.txt
Gráficas: output/20260615_ARG_vs_FRA/0*.png
```

---

## 4. Fuentes de datos: CSV vs PostgreSQL

El motor R detecta automáticamente el modo según el campo `data_sources` del
JSON de configuración.

### Modo CSV

```json
"data_sources": {
  "players_csv": "data/players.csv",
  "matches_csv": "data/matches.csv",
  "players_db":  null
}
```

- No requiere PostgreSQL
- Ideal para pruebas o ligas propias
- Edita los CSV directamente con tus datos

### Modo PostgreSQL

```json
"data_sources": {
  "players_csv": null,
  "matches_csv": null,
  "players_db": {
    "dsn":          "host=localhost dbname=whowins user=postgres password=secret",
    "player_view":  "v_player_details",
    "match_view":   "v_match_history",
    "season_label": "2026"
  }
}
```

También acepta URL completa:
```json
"dsn": "postgresql://postgres:secret@localhost:5432/whowins"
```

El motor lee desde las vistas precalculadas de la DB, que incluyen todos los
diferenciales y métricas que necesita el modelo. Las variables de entorno
`PGHOST`, `PGUSER`, `PGPASSWORD`, `PGDATABASE` también son reconocidas.

Para instalar los paquetes R necesarios:
```r
install.packages(c("DBI", "RPostgres"))
```

---

## 5. Setup de PostgreSQL desde cero

`sql/setup.py` orquesta **todo el proceso** desde cero en un solo comando.
No necesitas ejecutar nada más.

### Qué hace internamente

```
Paso 1  Crea la base de datos (CREATE DATABASE whowins)
Paso 2  Aplica el esquema   → sql/01_schema.sql
           tablas: players, player_seasons, team_players, teams,
                   matches, match_player_stats, weather_conditions,
                   seasons, competitions, countries, wc2026_groups
           vistas: v_player_details, v_match_history, v_team_season_stats
           funciones: fn_team_players(), fn_set_updated_at()
Paso 3  Inserta seed        → sql/02_seed_wc2026.sql
           48 selecciones, 12 grupos (A–L), temporada WC2026
Paso 4  Inserta calendario  → 74 partidos de fase de grupos
Paso 5  Carga jugadores     → CSV local + API-Football (si hay key)
Paso 6  Genera config JSON  → config/teams_wc2026.json
```

### Uso mínimo (sin datos de API)

```bash
python3 sql/setup.py
```

Crea la DB en `localhost` con usuario `postgres`, aplica el esquema completo,
inserta los 48 equipos y carga los datos de `data/players.csv` como base.

### Uso completo con datos reales

```bash
python3 sql/setup.py \
  --host localhost \
  --user postgres \
  --password mi_password \
  --dbname whowins \
  --api-key TU_API_KEY \
  --groups A B C D
```

### Todas las opciones de setup.py

**Conexión:**

| Opción | Default | Descripción |
|--------|---------|-------------|
| `--host` | `localhost` (ó `$PGHOST`) | Host de PostgreSQL |
| `--port` | `5432` (ó `$PGPORT`) | Puerto |
| `--user` | `postgres` (ó `$PGUSER`) | Usuario |
| `--password` | `` (ó `$PGPASSWORD`) | Contraseña |
| `--dbname` | `whowins` (ó `$PGDATABASE`) | Nombre de la base de datos |

**Datos:**

| Opción | Descripción |
|--------|-------------|
| `--api-key KEY` | API key de api-football.com (gratis en dashboard.api-football.com) |
| `--api-limit N` | Requests disponibles hoy (default: 100) |
| `--only-squad` | Solo plantilla sin stats individuales (1 req/equipo en vez de ~27) |

**Selección de equipos a cargar** (mutuamente excluyentes):

| Opción | Ejemplo | Descripción |
|--------|---------|-------------|
| `--teams` | `--teams ARG FRA BRA` | Equipos específicos por código |
| `--groups` | `--groups A B C` | Grupos completos del Mundial |
| `--matches` | `--matches 1 2 3 4` | Ambos equipos de los primeros N partidos |
| `--priority N` | `--priority 6` | Primeros N equipos por fecha de partido |

**Control:**

| Opción | Descripción |
|--------|-------------|
| `--schema-only` | Solo crea DB y esquema, sin datos |
| `--reset` | Borra la DB y la recrea desde cero (pide confirmación) |
| `--dry-run` | Muestra qué haría sin ejecutar nada |
| `--skip-schedule` | No inserta el calendario de partidos |

### Ejemplos de setup.py

```bash
# Solo esquema, sin datos (para configurar primero la DB)
python3 sql/setup.py --schema-only

# Simular sin escribir nada
python3 sql/setup.py --dry-run --api-key FAKE --groups A

# Servidor remoto, solo los 4 primeros partidos del Mundial
python3 sql/setup.py \
  --host db.miservidor.com \
  --user admin --password secret \
  --api-key TU_KEY \
  --matches 1 2 3 4

# Borrar todo y empezar de cero
python3 sql/setup.py --reset --api-key TU_KEY

# Usar variables de entorno (útil en CI/CD)
export PGHOST=localhost PGUSER=postgres PGPASSWORD=secret PGDATABASE=whowins
python3 sql/setup.py --api-key TU_KEY
```

---

## 6. Cargar jugadores del Mundial 2026

`sql/03_load_players.py` permite cargar jugadores de forma incremental, por
ejemplo un grupo de equipos cada día respetando el límite de 100 req/día del
plan gratuito de API-Football.

### Límite de requests

Con el plan gratuito (100 req/día):

| Modo | Requests por equipo | Equipos por día |
|------|--------------------:|----------------:|
| Solo plantilla (`--only-squad`) | 1 | 100 |
| Plantilla + stats individuales | ~27 | 3 |

### Menú interactivo

Sin opciones de selección, aparece un menú:

```bash
python3 sql/03_load_players.py \
  --db postgresql://postgres:secret@localhost/whowins \
  --source api --api-key TU_KEY
```

```
══════════════════════════════════════════════════════════════════════
  ⚽  SELECTOR DE EQUIPOS — Mundial 2026
  Límite API: 100 requests/día ≈ 3-4 equipos completos (squad+stats)
══════════════════════════════════════════════════════════════════════

  [1] Automático: ordenado por fecha de primer partido
  [2] Por grupos (A–L)
  [3] Por partido (cargar ambos equipos de un match)
  [4] Selección manual de equipos
  [5] Todos (48 equipos — necesita varios días con plan free)
```

### Sin menú — opciones directas

```bash
# Equipos específicos
python3 sql/03_load_players.py --db ... --api-key KEY \
  --source api --teams ARG FRA GER

# Grupo completo
python3 sql/03_load_players.py --db ... --api-key KEY \
  --source api --groups A B

# Los primeros 4 partidos del Mundial (MEX, RSA, KOR, CZE, CAN, BIH, USA, PAR)
python3 sql/03_load_players.py --db ... --api-key KEY \
  --source api --matches 1 2 3 4

# Los 6 equipos que juegan antes (prioridad automática)
python3 sql/03_load_players.py --db ... --api-key KEY \
  --source api --priority 6

# Solo plantilla (1 req/equipo) para conservar el límite
python3 sql/03_load_players.py --db ... --api-key KEY \
  --source api --teams ARG FRA --only-squad

# Insertar el calendario de partidos
python3 sql/03_load_players.py --db ... --load-schedule

# Ver qué haría sin gastar requests
python3 sql/03_load_players.py --dry-run --teams ARG FRA
```

### Estrategia para el plan free (100 req/día)

```
Día 1 → --matches 1 2 3 4    (8 equipos, ~8 req si --only-squad)
          o --matches 1       (MEX + RSA, ~2 req, con stats ~54 req)
Día 2 → --matches 5 6        (BRA, MAR, QAT, SUI)
Día 3 → --matches 7 8        (HAI, SCO, AUS, TUR)
...y así hasta completar los 48
```

---

## 7. Generar config desde la base de datos

```bash
python3 sql/04_generate_config.py \
  --db postgresql://postgres:secret@localhost/whowins \
  --output config/teams_wc2026.json
```

El archivo generado apunta automáticamente a la DB, de modo que `whowins`
leerá los datos en vivo sin necesidad de exportar CSVs.

```bash
# Solo algunos grupos
python3 sql/04_generate_config.py --db ... --group A B C

# Solo equipos específicos
python3 sql/04_generate_config.py --db ... --teams ARG FRA BRA GER ESP ENG
```

---

## 8. Formato de archivos CSV

Solo necesario en **modo CSV**. En modo PostgreSQL se leen las vistas de la DB.

### `data/players.csv`

| Columna | Tipo | Descripción |
|---------|------|-------------|
| `player_id` | texto | ID único — debe coincidir con `players` en el JSON |
| `name` | texto | Nombre completo |
| `team_id` | texto | Código del equipo (debe existir en el JSON) |
| `position` | texto | `GK CB LB RB DM CM AM LW RW SS FW` |
| `matches` | entero | Partidos jugados |
| `goals` | entero | Goles totales |
| `assists` | entero | Asistencias totales |
| `shots_on_target` | entero | Tiros a puerta |
| `pass_accuracy` | decimal | % pases completados (0–100) |
| `dribbles_completed` | entero | Regates completados |
| `tackles` | entero | Entradas realizadas |
| `interceptions` | entero | Intercepciones |
| `yellow_cards` | entero | Tarjetas amarillas |
| `red_cards` | entero | Tarjetas rojas |
| `minutes_played` | entero | Minutos jugados |
| `rating` | decimal | Valoración media (0–10) |

### `data/matches.csv`

| Columna | Tipo | Descripción |
|---------|------|-------------|
| `match_id` | texto | ID único del partido |
| `date` | fecha | `YYYY-MM-DD` |
| `home_team` | texto | Código del equipo local |
| `away_team` | texto | Código del equipo visitante |
| `home_goals` | entero | Goles del local |
| `away_goals` | entero | Goles del visitante |
| `result` | texto | `home_win` · `draw` · `away_win` |
| `altitude_m` | entero | Altitud del estadio en metros |
| `weather` | texto | `clear` · `cloudy` · `rain` |
| `temperature_c` | decimal | Temperatura en °C |
| `humidity_pct` | decimal | Humedad relativa (0–100) |
| `wind_kmh` | decimal | Viento en km/h |

---

## 9. Configuración de equipos (JSON)

```json
{
  "teams": {
    "ARG": {
      "full_name":       "Argentina",
      "stadium":         "Estadio Monumental",
      "altitude_home_m": 25,
      "players": ["P001","P002","P003","...","P026"]
    },
    "FRA": {
      "full_name":       "France",
      "stadium":         "Stade de France",
      "altitude_home_m": 30,
      "players": ["P027","P028","..."]
    }
  },
  "data_sources": {
    "players_csv": "data/players.csv",
    "matches_csv": "data/matches.csv",
    "players_db":  null
  },
  "model_settings": {
    "anova_significance":    0.05,
    "home_advantage_weight": 1.0
  }
}
```

> Los `player_id` en `players` deben coincidir con la columna `player_id`
> del CSV (modo CSV) o con `player_code` en PostgreSQL (modo DB).

---

## 10. Metodología estadística

```
Datos históricos (CSV o PostgreSQL)
          │
          ▼
  ANOVA multifactorial
  ─────────────────────────────────────────────────────────────
  Evalúa significancia estadística (F-test, p < 0.05) de:
    Diferenciales equipo: goles · asistencias · tiros · pases ·
                          tackles · rating · disciplina
    Factores contextuales: altitud · clima
  Solo los factores SIGNIFICATIVOS pasan al siguiente paso.
          │
          ├──► Regresión Multinomial (nnet::multinom)        35%
          │    3 clases: home_win / draw / away_win
          │    Features: diferenciales filtrados por ANOVA
          │
          ├──► Naive Bayes por jugador (e1071)               25%
          │    P(victoria | stats_jugador_i) para cada jugador
          │    Cuantifica el impacto individual de cada jugador
          │
          └──► Distribución de Poisson (Dixon-Coles)         40%
               λ = (ataque / media_liga) × (defensa_rival / media_liga) × media
               Matriz de probabilidad de marcadores hasta 7-7
               Ajuste local: ×1.10 local · ×0.92 visitante
          │
          ▼
  Ensemble ponderado  →  Prior
          │
          ▼
  Actualización Bayesiana head-to-head
  ─────────────────────────────────────────────────────────────
  posterior ∝ prior × likelihood(historial_A_vs_B)
  Peso H2H: w = n_partidos / (n_partidos + 15)  [máx 0.55]
    0 partidos H2H  →  w = 0  (posterior = prior)
    20+ partidos    →  w ≈ 0.57 (historial domina)
          │
          ▼
  Probabilidades finales + ajuste de localía (±4 pp)
```

---

## 11. Archivos de salida

Por cada ejecución se crea `output/<timestamp>_<A>_vs_<B>/`:

| Archivo | Contenido |
|---------|-----------|
| `reporte_completo.txt` | Todas las estadísticas, coeficientes, tablas NB y Poisson |
| `01_probabilidades.png` | Barras de probabilidad final |
| `02_comparacion_modelos.png` | Probabilidades de cada modelo del ensemble |
| `03_anova_eta2.png` | Importancia de factores (tamaño de efecto η²) |
| `04_jugadores_impacto.png` | Top 5 jugadores por índice de impacto |
| `05_nb_por_jugador.png` | P(victoria) por jugador — Naive Bayes |
| `06_matriz_scores.png` | Probabilidad de cada marcador 0-0 a 5-5 |
| `07_bayes_update.png` | Prior vs posterior tras actualización H2H |
| `analysis.log` | Log completo de la ejecución R |

---

## 12. Ejemplos — Mundial 2026

```bash
CONFIG="--config config/teams_wc2026.json"

# ── Jornada 1 (11-12 jun) ─────────────────────────────────────────────────
whowins MEX RSA --home MEX --altitude 2240 $CONFIG   # Azteca
whowins KOR CZE $CONFIG
whowins CAN BIH --home CAN $CONFIG
whowins USA PAR --home USA $CONFIG

# ── Fase de grupos — partidos clave ──────────────────────────────────────
whowins BRA MAR --weather rain $CONFIG
whowins FRA NOR $CONFIG
whowins GER NED $CONFIG
whowins ARG ALG $CONFIG
whowins ESP KSA $CONFIG
whowins ENG GHA $CONFIG

# ── Cruces hipotéticos de octavos ─────────────────────────────────────────
whowins ARG FRA $CONFIG
whowins BRA GER $CONFIG
whowins ESP ENG $CONFIG

# ── Final hipotética ──────────────────────────────────────────────────────
whowins ARG FRA --output resultados/final_2026 $CONFIG
```

---

## 13. Estructura del proyecto

```
whowins/
├── whowins                  ← Comando principal (Bash)
├── install.sh               ← Instala paquetes R y crea symlink
├── README.md                ← Este archivo
│
├── R/
│   └── analysis.R           ← Motor estadístico (~1040 líneas)
│                               Lee CSV o PostgreSQL según config
│
├── config/
│   ├── teams.json           ← Config ejemplo (CSV, 3 equipos)
│   └── teams_wc2026.json    ← Generado por setup.py (48 selecciones, DB)
│
├── data/                    ← CSVs para modo sin DB
│   ├── players.csv
│   └── matches.csv
│
├── sql/
│   ├── setup.py             ← ★ Orquestador completo: crea DB + todo
│   ├── 01_schema.sql        ← Tablas, vistas, tipos, funciones
│   ├── 02_seed_wc2026.sql   ← 48 equipos + grupos A-L WC2026
│   ├── 03_load_players.py   ← Cargador incremental con selector de equipos
│   ├── 04_generate_config.py← Genera teams_wc2026.json desde la DB
│   └── README_SQL.md        ← Guía detallada del pipeline SQL
│
└── output/                  ← Resultados (creado automáticamente)
    └── <timestamp>_A_vs_B/
        ├── reporte_completo.txt
        ├── 01_probabilidades.png
        ├── ...
        └── analysis.log
```

---

## 14. Preguntas frecuentes

**¿Puedo crear la base de datos desde cero sin saber SQL?**
Sí. `python3 sql/setup.py` hace todo: crea la DB, aplica el esquema, inserta
los 48 equipos del Mundial y genera el JSON de configuración. No necesitas
ejecutar ningún archivo `.sql` manualmente.

**¿Dónde consigo la API key de API-Football?**
En https://dashboard.api-football.com — el plan gratuito da 100 requests/día,
suficiente para cargar 3-4 equipos completos por día o hasta 100 plantillas
(sin stats individuales con `--only-squad`).

**¿Cuántos años de historial necesito?**
Con 1 temporada funciona. El óptimo es 3 temporadas (~100 partidos por equipo).
Más de 4 años añade ruido si la plantilla cambió significativamente.

**¿Qué pasa si dos equipos nunca se han enfrentado?**
El peso Bayesiano del H2H es 0 y el posterior es igual al ensemble. El sistema
funciona igual, simplemente sin ese ajuste.

**¿El sistema predice el marcador exacto?**
Sí. El modelo Poisson genera la matriz de probabilidad para todos los marcadores
de 0-0 a 5-5. El marcador más probable se reporta en consola y la gráfica
`06_matriz_scores.png` muestra la distribución completa.

**¿Cómo agrego mi propia liga (no del Mundial)?**
Agrega los equipos en `config/teams.json`, llena `data/players.csv` y
`data/matches.csv`, y ejecuta con `--config config/teams.json`.

**¿Puedo usar el sistema en Windows?**
El comando `whowins` requiere Bash. En Windows usa WSL2 o Git Bash.
El pipeline Python (`setup.py`, `03_load_players.py`) funciona nativo.

**¿Por qué el modelo usa Poisson y no solo la regresión?**
La regresión multinomial predice la clase (gana/empata/pierde) pero no el
marcador exacto ni la distribución de goles. Poisson modela el número de goles
como variable aleatoria, lo que permite calcular la probabilidad de cada
marcador posible (1-0, 2-1, etc.) y es el estándar en modelos de fútbol
desde Dixon & Coles (1997).

---

*whowins v2 — Ensemble Bayesiano: ANOVA · Multinomial · Naive Bayes · Poisson · H2H*
