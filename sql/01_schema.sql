-- =============================================================================
-- whowins — Esquema PostgreSQL
-- Versión: 2.0
-- Descripción: Base de datos completa para predicción de partidos de fútbol.
--              Soporta múltiples ligas, temporadas y competiciones.
-- =============================================================================

-- Extensiones útiles
CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "pg_trgm";    -- búsqueda difusa de nombres

-- =============================================================================
-- TIPOS ENUMERADOS
-- =============================================================================

CREATE TYPE player_position AS ENUM (
    'GK',   -- Portero
    'CB',   -- Central
    'LB',   -- Lateral izquierdo
    'RB',   -- Lateral derecho
    'DM',   -- Mediocampista defensivo
    'CM',   -- Mediocampista central
    'AM',   -- Mediocampista ofensivo
    'LW',   -- Extremo izquierdo
    'RW',   -- Extremo derecho
    'SS',   -- Segundo delantero / Media punta
    'FW'    -- Delantero centro
);

CREATE TYPE player_foot AS ENUM ('right', 'left', 'both');

CREATE TYPE player_status AS ENUM (
    'active',    -- Disponible y en plantilla
    'injured',   -- Lesionado
    'suspended', -- Sancionado
    'loaned',    -- Cedido a otro club
    'retired',   -- Retirado
    'released'   -- Sin contrato
);

CREATE TYPE match_result AS ENUM ('home_win', 'draw', 'away_win');

CREATE TYPE weather_condition AS ENUM (
    'clear',        -- Despejado
    'partly_cloudy',-- Parcialmente nublado
    'cloudy',       -- Nublado
    'fog',          -- Niebla
    'drizzle',      -- Llovizna
    'rain',         -- Lluvia
    'heavy_rain',   -- Lluvia intensa
    'snow',         -- Nieve
    'storm'         -- Tormenta
);

CREATE TYPE competition_type AS ENUM (
    'league',       -- Liga regular
    'cup',          -- Copa nacional
    'continental',  -- Copa continental (Libertadores, Champions, etc.)
    'friendly',     -- Amistoso
    'playoff',      -- Playoff / liguilla
    'supercup'      -- Supercopa
);

CREATE TYPE match_stage AS ENUM (
    'regular',           -- Jornada de liga
    'group_stage',       -- Fase de grupos
    'round_of_32',
    'round_of_16',
    'quarterfinal',
    'semifinal',
    'third_place',
    'final'
);

-- =============================================================================
-- TABLA: countries
-- Catálogo de países (normaliza nacionalidad y sede)
-- =============================================================================
CREATE TABLE countries (
    country_id   SERIAL        PRIMARY KEY,
    iso_code     CHAR(2)       NOT NULL UNIQUE,   -- ISO 3166-1 alpha-2
    name         VARCHAR(100)  NOT NULL,
    continent    VARCHAR(30)
);

-- =============================================================================
-- TABLA: competitions
-- Liga, copa, torneo — una fila por competición
-- =============================================================================
CREATE TABLE competitions (
    competition_id   SERIAL              PRIMARY KEY,
    name             VARCHAR(100)        NOT NULL,
    short_name       VARCHAR(20),
    country_id       INT                 REFERENCES countries(country_id),
    type             competition_type    NOT NULL DEFAULT 'league',
    level            SMALLINT            DEFAULT 1,  -- 1=primera, 2=segunda, etc.
    active           BOOLEAN             NOT NULL DEFAULT TRUE,
    created_at       TIMESTAMPTZ         NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- TABLA: seasons
-- Temporada de una competición (ej: Liga 2024-25)
-- =============================================================================
CREATE TABLE seasons (
    season_id       SERIAL       PRIMARY KEY,
    competition_id  INT          NOT NULL REFERENCES competitions(competition_id),
    label           VARCHAR(20)  NOT NULL,   -- ej: '2024-25'
    start_date      DATE         NOT NULL,
    end_date        DATE,
    active          BOOLEAN      NOT NULL DEFAULT FALSE,
    UNIQUE (competition_id, label)
);

-- =============================================================================
-- TABLA: teams
-- Un club / equipo. Independiente de temporada.
-- =============================================================================
CREATE TABLE teams (
    team_id          SERIAL        PRIMARY KEY,
    team_code        VARCHAR(10)   NOT NULL UNIQUE,  -- 'TeamA', 'RMADRID', etc.
    full_name        VARCHAR(100)  NOT NULL,
    short_name       VARCHAR(30),
    country_id       INT           REFERENCES countries(country_id),
    city             VARCHAR(80),
    stadium          VARCHAR(100),
    altitude_home_m  SMALLINT      NOT NULL DEFAULT 0
                                   CHECK (altitude_home_m >= 0 AND altitude_home_m <= 5500),
    founded_year     SMALLINT      CHECK (founded_year >= 1800),
    primary_color    CHAR(7),      -- hex ej: '#FF0000'
    secondary_color  CHAR(7),
    active           BOOLEAN       NOT NULL DEFAULT TRUE,
    created_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- TABLA: players
-- Un jugador. Sus stats son SIEMPRE acumuladas por temporada en player_seasons.
-- Esta tabla solo guarda datos que NO cambian entre temporadas.
-- =============================================================================
CREATE TABLE players (
    player_id       SERIAL          PRIMARY KEY,
    player_code     VARCHAR(10)     UNIQUE,          -- 'P001', 'P002', etc. (para compatibilidad CSV)
    full_name       VARCHAR(120)    NOT NULL,
    short_name      VARCHAR(60),
    date_of_birth   DATE,
    country_id      INT             REFERENCES countries(country_id),
    nationality2    INT             REFERENCES countries(country_id),  -- doble nacionalidad
    position_primary   player_position NOT NULL,
    position_secondary player_position,
    foot            player_foot     NOT NULL DEFAULT 'right',
    height_cm       SMALLINT        CHECK (height_cm BETWEEN 140 AND 230),
    weight_kg       NUMERIC(4,1)    CHECK (weight_kg BETWEEN 40 AND 140),
    active          BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- TABLA: player_seasons
-- Stats ACUMULADAS de un jugador en una temporada concreta.
-- Esta es la tabla que alimenta directamente al modelo R.
-- Una fila = un jugador × una temporada × un equipo.
-- =============================================================================
CREATE TABLE player_seasons (
    ps_id            SERIAL          PRIMARY KEY,
    player_id        INT             NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    team_id          INT             NOT NULL REFERENCES teams(team_id),
    season_id        INT             NOT NULL REFERENCES seasons(season_id),

    -- ── Uso (minutos)
    matches_played   SMALLINT        NOT NULL DEFAULT 0 CHECK (matches_played >= 0),
    matches_started  SMALLINT        NOT NULL DEFAULT 0 CHECK (matches_started >= 0),
    minutes_played   INT             NOT NULL DEFAULT 0 CHECK (minutes_played >= 0),

    -- ── Ofensivo
    goals                   SMALLINT        NOT NULL DEFAULT 0 CHECK (goals >= 0),
    assists                 SMALLINT        NOT NULL DEFAULT 0 CHECK (assists >= 0),
    shots_total             SMALLINT        NOT NULL DEFAULT 0,
    shots_on_target         SMALLINT        NOT NULL DEFAULT 0,
    shot_accuracy           NUMERIC(5,2)    -- % shots on target / total  (calculado)
                            GENERATED ALWAYS AS (
                                CASE WHEN shots_total > 0
                                     THEN ROUND(shots_on_target::NUMERIC / shots_total * 100, 2)
                                     ELSE 0 END
                            ) STORED,
    key_passes              SMALLINT        NOT NULL DEFAULT 0,
    dribbles_attempted      SMALLINT        NOT NULL DEFAULT 0,
    dribbles_completed      SMALLINT        NOT NULL DEFAULT 0,
    dribble_success         NUMERIC(5,2)    GENERATED ALWAYS AS (
                                CASE WHEN dribbles_attempted > 0
                                     THEN ROUND(dribbles_completed::NUMERIC / dribbles_attempted * 100, 2)
                                     ELSE 0 END
                            ) STORED,
    big_chances_created     SMALLINT        NOT NULL DEFAULT 0,
    expected_goals          NUMERIC(6,2)    DEFAULT 0,  -- xG si disponible
    expected_assists        NUMERIC(6,2)    DEFAULT 0,  -- xA si disponible

    -- ── Defensivo
    tackles                 SMALLINT        NOT NULL DEFAULT 0,
    tackles_won             SMALLINT        NOT NULL DEFAULT 0,
    interceptions           SMALLINT        NOT NULL DEFAULT 0,
    clearances              SMALLINT        NOT NULL DEFAULT 0,
    blocks                  SMALLINT        NOT NULL DEFAULT 0,
    duels_total             SMALLINT        NOT NULL DEFAULT 0,
    duels_won               SMALLINT        NOT NULL DEFAULT 0,
    aerial_total            SMALLINT        NOT NULL DEFAULT 0,
    aerial_won              SMALLINT        NOT NULL DEFAULT 0,
    duels_won_pct           NUMERIC(5,2)    GENERATED ALWAYS AS (
                                CASE WHEN duels_total > 0
                                     THEN ROUND(duels_won::NUMERIC / duels_total * 100, 2)
                                     ELSE 0 END
                            ) STORED,

    -- ── Pase
    pass_total              INT             NOT NULL DEFAULT 0,
    pass_completed          INT             NOT NULL DEFAULT 0,
    pass_accuracy           NUMERIC(5,2)    GENERATED ALWAYS AS (
                                CASE WHEN pass_total > 0
                                     THEN ROUND(pass_completed::NUMERIC / pass_total * 100, 2)
                                     ELSE 0 END
                            ) STORED,
    long_pass_accuracy      NUMERIC(5,2),   -- % pases largos completados
    cross_accuracy          NUMERIC(5,2),   -- % centros completados

    -- ── Portero (NULL para no porteros)
    saves                   SMALLINT,
    goals_conceded          SMALLINT,
    clean_sheets            SMALLINT,
    save_percentage         NUMERIC(5,2),   -- % disparos salvados (manual, no calculada)
    goals_prevented         NUMERIC(6,2),   -- xG concedido - goles reales

    -- ── Disciplina
    yellow_cards            SMALLINT        NOT NULL DEFAULT 0 CHECK (yellow_cards >= 0),
    red_cards               SMALLINT        NOT NULL DEFAULT 0 CHECK (red_cards >= 0),
    fouls_committed         SMALLINT        NOT NULL DEFAULT 0,
    fouls_drawn             SMALLINT        NOT NULL DEFAULT 0,

    -- ── Valoración general
    rating_avg              NUMERIC(4,2)    CHECK (rating_avg BETWEEN 0 AND 10),
    rating_source           VARCHAR(20),    -- 'sofascore', 'whoscored', 'fbref', etc.

    -- ── Restricciones de integridad
    CONSTRAINT chk_started_vs_played   CHECK (matches_started <= matches_played),
    CONSTRAINT chk_shots_on_vs_total   CHECK (shots_on_target <= shots_total),
    CONSTRAINT chk_tackles_won         CHECK (tackles_won <= tackles),
    CONSTRAINT chk_duels_won           CHECK (duels_won <= duels_total),
    CONSTRAINT chk_aerial_won          CHECK (aerial_won <= aerial_total),
    CONSTRAINT chk_pass_completed      CHECK (pass_completed <= pass_total),
    UNIQUE (player_id, team_id, season_id)
);

-- =============================================================================
-- TABLA: team_players
-- Plantilla activa: qué jugadores pertenecen a qué equipo en qué temporada.
-- Reemplaza el archivo config/teams.json.
-- =============================================================================
CREATE TABLE team_players (
    tp_id          SERIAL         PRIMARY KEY,
    team_id        INT            NOT NULL REFERENCES teams(team_id),
    player_id      INT            NOT NULL REFERENCES players(player_id),
    season_id      INT            NOT NULL REFERENCES seasons(season_id),
    jersey_number  SMALLINT       CHECK (jersey_number BETWEEN 1 AND 99),
    status         player_status  NOT NULL DEFAULT 'active',
    date_joined    DATE,
    date_left      DATE,
    transfer_fee_eur BIGINT,      -- en euros, NULL si no aplica
    is_captain     BOOLEAN        NOT NULL DEFAULT FALSE,
    UNIQUE (team_id, player_id, season_id)
);

-- =============================================================================
-- TABLA: weather_conditions
-- Catálogo de condiciones climáticas (una fila por partido)
-- =============================================================================
CREATE TABLE weather_conditions (
    weather_id        SERIAL              PRIMARY KEY,
    condition         weather_condition   NOT NULL DEFAULT 'clear',
    temperature_c     NUMERIC(4,1),       -- Temperatura en °C
    humidity_pct      NUMERIC(4,1)        CHECK (humidity_pct BETWEEN 0 AND 100),
    wind_kmh          NUMERIC(5,1)        CHECK (wind_kmh >= 0),
    precipitation_mm  NUMERIC(5,1)        NOT NULL DEFAULT 0 CHECK (precipitation_mm >= 0),
    uv_index          NUMERIC(3,1)        CHECK (uv_index BETWEEN 0 AND 15),
    visibility_km     NUMERIC(4,1)        CHECK (visibility_km >= 0),
    -- Índice numérico para el modelo (calculado automáticamente)
    weather_num       SMALLINT            GENERATED ALWAYS AS (
                          CASE condition
                              WHEN 'clear'         THEN 0
                              WHEN 'partly_cloudy' THEN 1
                              WHEN 'cloudy'        THEN 1
                              WHEN 'fog'           THEN 2
                              WHEN 'drizzle'       THEN 2
                              WHEN 'rain'          THEN 2
                              WHEN 'heavy_rain'    THEN 3
                              WHEN 'snow'          THEN 3
                              WHEN 'storm'         THEN 3
                              ELSE 0
                          END
                      ) STORED
);

-- =============================================================================
-- TABLA: matches
-- Un partido. Fuente principal para el modelo de regresión y Poisson.
-- =============================================================================
CREATE TABLE matches (
    match_id        SERIAL              PRIMARY KEY,
    match_code      VARCHAR(20)         UNIQUE,     -- 'M001', código externo
    home_team_id    INT                 NOT NULL REFERENCES teams(team_id),
    away_team_id    INT                 NOT NULL REFERENCES teams(team_id),
    season_id       INT                 NOT NULL REFERENCES seasons(season_id),
    weather_id      INT                 REFERENCES weather_conditions(weather_id),
    match_date      TIMESTAMPTZ         NOT NULL,
    competition     competition_type    NOT NULL DEFAULT 'league',
    stage           match_stage         NOT NULL DEFAULT 'regular',
    neutral_venue   BOOLEAN             NOT NULL DEFAULT FALSE,
    altitude_m      SMALLINT            NOT NULL DEFAULT 0,
    attendance      INT                 CHECK (attendance >= 0),

    -- Resultado
    home_goals      SMALLINT            CHECK (home_goals >= 0),
    away_goals      SMALLINT            CHECK (away_goals >= 0),
    home_goals_ht   SMALLINT            CHECK (home_goals_ht >= 0),  -- medio tiempo
    away_goals_ht   SMALLINT            CHECK (away_goals_ht >= 0),
    result          match_result,       -- NULL si el partido no se ha jugado aún

    -- Extra time / penalties
    went_to_et      BOOLEAN             NOT NULL DEFAULT FALSE,
    went_to_pens    BOOLEAN             NOT NULL DEFAULT FALSE,
    home_pens       SMALLINT,
    away_pens       SMALLINT,

    -- Notas
    notes           TEXT,

    CONSTRAINT chk_teams_differ CHECK (home_team_id <> away_team_id),
    CONSTRAINT chk_result_consistency CHECK (
        (result IS NULL AND home_goals IS NULL) OR
        (result = 'home_win' AND home_goals > away_goals) OR
        (result = 'draw'     AND home_goals = away_goals) OR
        (result = 'away_win' AND home_goals < away_goals)
    ),
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- TABLA: match_player_stats
-- Stats individuales de un jugador EN UN PARTIDO CONCRETO.
-- La tabla más granular y valiosa para el modelo Bayesiano.
-- =============================================================================
CREATE TABLE match_player_stats (
    mps_id           SERIAL          PRIMARY KEY,
    match_id         INT             NOT NULL REFERENCES matches(match_id) ON DELETE CASCADE,
    player_id        INT             NOT NULL REFERENCES players(player_id),
    team_id          INT             NOT NULL REFERENCES teams(team_id),

    -- Participación
    started          BOOLEAN         NOT NULL DEFAULT FALSE,
    minutes_played   SMALLINT        NOT NULL DEFAULT 0 CHECK (minutes_played BETWEEN 0 AND 120),
    position_played  player_position,

    -- Ofensivo
    goals            SMALLINT        NOT NULL DEFAULT 0 CHECK (goals >= 0),
    assists          SMALLINT        NOT NULL DEFAULT 0 CHECK (assists >= 0),
    shots_total      SMALLINT        NOT NULL DEFAULT 0,
    shots_on_target  SMALLINT        NOT NULL DEFAULT 0,
    key_passes       SMALLINT        NOT NULL DEFAULT 0,
    dribbles_completed SMALLINT      NOT NULL DEFAULT 0,
    big_chances_created SMALLINT     NOT NULL DEFAULT 0,

    -- Defensivo
    tackles          SMALLINT        NOT NULL DEFAULT 0,
    interceptions    SMALLINT        NOT NULL DEFAULT 0,
    clearances       SMALLINT        NOT NULL DEFAULT 0,
    duels_won        SMALLINT        NOT NULL DEFAULT 0,
    aerial_won       SMALLINT        NOT NULL DEFAULT 0,

    -- Pase
    pass_total       SMALLINT        NOT NULL DEFAULT 0,
    pass_completed   SMALLINT        NOT NULL DEFAULT 0,

    -- Portero
    saves            SMALLINT,
    goals_conceded   SMALLINT,

    -- Disciplina
    yellow_cards     SMALLINT        NOT NULL DEFAULT 0 CHECK (yellow_cards IN (0,1)),
    red_cards        SMALLINT        NOT NULL DEFAULT 0 CHECK (red_cards IN (0,1)),
    fouls_committed  SMALLINT        NOT NULL DEFAULT 0,

    -- Valoración
    rating           NUMERIC(4,2)    CHECK (rating BETWEEN 0 AND 10),

    UNIQUE (match_id, player_id),
    CONSTRAINT chk_mps_shots CHECK (shots_on_target <= shots_total),
    CONSTRAINT chk_mps_pass  CHECK (pass_completed <= pass_total)
);

-- =============================================================================
-- ÍNDICES
-- =============================================================================

-- players
CREATE INDEX idx_players_code     ON players(player_code);
CREATE INDEX idx_players_name_trgm ON players USING gin(full_name gin_trgm_ops);

-- player_seasons
CREATE INDEX idx_ps_player        ON player_seasons(player_id);
CREATE INDEX idx_ps_team          ON player_seasons(team_id);
CREATE INDEX idx_ps_season        ON player_seasons(season_id);

-- team_players
CREATE INDEX idx_tp_team          ON team_players(team_id);
CREATE INDEX idx_tp_player        ON team_players(player_id);
CREATE INDEX idx_tp_season        ON team_players(season_id);
CREATE INDEX idx_tp_active        ON team_players(team_id, season_id) WHERE status = 'active';

-- matches
CREATE INDEX idx_matches_home     ON matches(home_team_id);
CREATE INDEX idx_matches_away     ON matches(away_team_id);
CREATE INDEX idx_matches_season   ON matches(season_id);
CREATE INDEX idx_matches_date     ON matches(match_date);
CREATE INDEX idx_matches_code     ON matches(match_code);

-- match_player_stats
CREATE INDEX idx_mps_match        ON match_player_stats(match_id);
CREATE INDEX idx_mps_player       ON match_player_stats(player_id);
CREATE INDEX idx_mps_team         ON match_player_stats(team_id);

-- =============================================================================
-- VISTA: v_team_season_stats
-- Stats agregadas por equipo × temporada.
-- El modelo R puede leer esta vista directamente en lugar de calcularlas en R.
-- =============================================================================
CREATE OR REPLACE VIEW v_team_season_stats AS
SELECT
    tp.team_id,
    t.team_code,
    t.full_name                                         AS team_name,
    ps.season_id,
    COUNT(DISTINCT ps.player_id)                        AS n_players,

    -- Ofensivo (promedios por partido)
    ROUND(AVG(ps.goals::NUMERIC        / NULLIF(ps.matches_played,0)), 4) AS avg_goals_pm,
    ROUND(AVG(ps.assists::NUMERIC      / NULLIF(ps.matches_played,0)), 4) AS avg_assists_pm,
    ROUND(AVG(ps.shots_on_target::NUMERIC / NULLIF(ps.matches_played,0)), 4) AS avg_shots_ot_pm,
    ROUND(AVG(ps.dribbles_completed::NUMERIC / NULLIF(ps.matches_played,0)), 4) AS avg_dribbles_pm,
    ROUND(AVG(ps.big_chances_created::NUMERIC / NULLIF(ps.matches_played,0)), 4) AS avg_bcc_pm,

    -- Pase
    ROUND(AVG(ps.pass_accuracy), 2)                     AS avg_pass_accuracy,

    -- Defensivo
    ROUND(AVG(ps.tackles::NUMERIC      / NULLIF(ps.matches_played,0)), 4) AS avg_tackles_pm,
    ROUND(AVG(ps.interceptions::NUMERIC / NULLIF(ps.matches_played,0)), 4) AS avg_interceptions_pm,
    ROUND(AVG(ps.duels_won_pct), 2)                     AS avg_duels_won_pct,
    ROUND(AVG(ps.aerial_won::NUMERIC   / NULLIF(ps.matches_played,0)), 4) AS avg_aerial_pm,

    -- Disciplina (índice ponderado: 1pt amarilla, 3pt roja)
    ROUND(AVG((ps.yellow_cards + ps.red_cards * 3)::NUMERIC / NULLIF(ps.matches_played,0)), 4) AS discipline_index,

    -- Valoración
    ROUND(AVG(ps.rating_avg), 2)                        AS avg_rating,

    -- Totales
    SUM(ps.goals)                                       AS total_goals,
    SUM(ps.assists)                                     AS total_assists,
    SUM(ps.minutes_played)                              AS total_minutes

FROM team_players tp
JOIN player_seasons ps  ON ps.player_id = tp.player_id
                       AND ps.team_id   = tp.team_id
                       AND ps.season_id = tp.season_id
JOIN teams t            ON t.team_id    = tp.team_id
WHERE tp.status = 'active'
GROUP BY tp.team_id, t.team_code, t.full_name, ps.season_id;

-- =============================================================================
-- VISTA: v_match_history
-- Historial de partidos con stats de ambos equipos ya calculadas.
-- Equivale al data.frame que construye build_features() en R.
-- =============================================================================
CREATE OR REPLACE VIEW v_match_history AS
SELECT
    m.match_id,
    m.match_code,
    m.match_date,
    m.season_id,
    m.competition,
    m.stage,
    m.neutral_venue,
    m.altitude_m,
    m.attendance,

    -- Equipos
    ht.team_code   AS home_team,
    at.team_code   AS away_team,

    -- Resultado
    m.home_goals,
    m.away_goals,
    m.result,
    CASE m.result
        WHEN 'home_win' THEN  1
        WHEN 'draw'     THEN  0
        WHEN 'away_win' THEN -1
    END                    AS result_num,

    -- Clima
    wc.condition           AS weather,
    wc.weather_num,
    wc.temperature_c,
    wc.humidity_pct,
    wc.wind_kmh,
    wc.precipitation_mm,

    -- Diferenciales (home - away) — features directas del modelo
    ROUND((h.avg_goals_pm        - a.avg_goals_pm),        4) AS diff_goals,
    ROUND((h.avg_assists_pm      - a.avg_assists_pm),      4) AS diff_assists,
    ROUND((h.avg_shots_ot_pm     - a.avg_shots_ot_pm),     4) AS diff_shots,
    ROUND((h.avg_pass_accuracy   - a.avg_pass_accuracy),   4) AS diff_pass,
    ROUND((h.avg_tackles_pm      - a.avg_tackles_pm),      4) AS diff_tackles,
    ROUND((h.avg_rating          - a.avg_rating),          4) AS diff_rating,
    ROUND((h.discipline_index    - a.discipline_index),    4) AS diff_discipl,
    ROUND((h.avg_duels_won_pct   - a.avg_duels_won_pct),   4) AS diff_duels,
    ROUND((h.avg_aerial_pm       - a.avg_aerial_pm),       4) AS diff_aerial,
    m.altitude_m                                               AS home_altitude

FROM matches m
JOIN teams ht                   ON ht.team_id    = m.home_team_id
JOIN teams at                   ON at.team_id    = m.away_team_id
LEFT JOIN weather_conditions wc ON wc.weather_id = m.weather_id
LEFT JOIN v_team_season_stats h ON h.team_id     = m.home_team_id
                                AND h.season_id  = m.season_id
LEFT JOIN v_team_season_stats a ON a.team_id     = m.away_team_id
                                AND a.season_id  = m.season_id
WHERE m.result IS NOT NULL;

-- =============================================================================
-- VISTA: v_player_details
-- Vista completa de jugadores activos con sus stats de la temporada más reciente.
-- Equivale al players.csv que consume el motor R.
-- =============================================================================
CREATE OR REPLACE VIEW v_player_details AS
SELECT
    p.player_id,
    p.player_code,
    p.full_name                             AS name,
    p.short_name,
    p.position_primary                      AS position,
    p.position_secondary,
    p.foot,
    p.height_cm,
    p.weight_kg,
    p.date_of_birth,
    EXTRACT(YEAR FROM AGE(p.date_of_birth)) AS age,
    c.name                                  AS nationality,

    -- Stats de la temporada más reciente disponible
    ps.season_id,
    tp.team_id,
    t.team_code                             AS team_id_code,
    tp.jersey_number,
    tp.status,
    tp.is_captain,

    -- Campos que usa el modelo directamente
    ps.matches_played                       AS matches,
    ps.minutes_played,
    ps.goals,
    ps.assists,
    ps.shots_on_target,
    ps.pass_accuracy,
    ps.dribbles_completed,
    ps.tackles,
    ps.interceptions,
    ps.yellow_cards,
    ps.red_cards,
    ps.rating_avg                           AS rating,

    -- Campos extendidos para futuras versiones del modelo
    ps.big_chances_created,
    ps.duels_won_pct,
    ps.aerial_won,
    ps.key_passes,
    ps.expected_goals,
    ps.expected_assists,
    ps.saves,
    ps.clean_sheets,
    ps.fouls_committed,
    ps.fouls_drawn,
    ps.shot_accuracy,
    ps.dribble_success,
    ps.long_pass_accuracy

FROM players p
JOIN team_players tp
    ON tp.player_id = p.player_id
    AND tp.season_id = (
        SELECT MAX(tp2.season_id)
        FROM team_players tp2
        WHERE tp2.player_id = p.player_id
    )
JOIN teams t         ON t.team_id  = tp.team_id
LEFT JOIN countries c ON c.country_id = p.country_id
LEFT JOIN player_seasons ps
    ON ps.player_id = p.player_id
    AND ps.team_id  = tp.team_id
    AND ps.season_id = tp.season_id
WHERE p.active = TRUE;

-- =============================================================================
-- FUNCIÓN: fn_team_players(team_code, season_label)
-- Devuelve los player_codes de un equipo en una temporada.
-- Usada por el loader R para reemplazar config/teams.json.
-- =============================================================================
CREATE OR REPLACE FUNCTION fn_team_players(
    p_team_code    TEXT,
    p_season_label TEXT DEFAULT NULL
)
RETURNS TABLE (player_code VARCHAR, player_id INT)
LANGUAGE sql STABLE AS $$
    SELECT p.player_code, p.player_id
    FROM team_players tp
    JOIN players p   ON p.player_id  = tp.player_id
    JOIN teams t     ON t.team_id    = tp.team_id
    JOIN seasons s   ON s.season_id  = tp.season_id
    WHERE t.team_code = p_team_code
      AND tp.status   = 'active'
      AND (p_season_label IS NULL OR s.label = p_season_label)
    ORDER BY tp.jersey_number NULLS LAST;
$$;

-- =============================================================================
-- TRIGGER: actualizar updated_at automáticamente
-- =============================================================================
CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_players_updated
    BEFORE UPDATE ON players
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TRIGGER trg_teams_updated
    BEFORE UPDATE ON teams
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- =============================================================================
-- COMENTARIOS DE TABLA (documentación interna)
-- =============================================================================
COMMENT ON TABLE players           IS 'Datos fijos del jugador (no cambian entre temporadas)';
COMMENT ON TABLE player_seasons    IS 'Stats acumuladas del jugador por temporada y equipo';
COMMENT ON TABLE team_players      IS 'Plantilla: qué jugadores pertenecen a cada equipo por temporada';
COMMENT ON TABLE matches           IS 'Historial de partidos jugados y pendientes';
COMMENT ON TABLE match_player_stats IS 'Stats individuales por jugador por partido (máxima granularidad)';
COMMENT ON TABLE weather_conditions IS 'Condiciones climáticas por partido';
COMMENT ON VIEW  v_team_season_stats IS 'Stats agregadas por equipo×temporada — input directo al modelo R';
COMMENT ON VIEW  v_match_history     IS 'Historial con diferenciales precalculados — equivale a build_features() en R';
COMMENT ON VIEW  v_player_details    IS 'Vista completa equivalente a players.csv para el modelo';

COMMENT ON COLUMN player_seasons.pass_accuracy        IS 'Calculado automáticamente: pass_completed / pass_total * 100';
COMMENT ON COLUMN player_seasons.shot_accuracy        IS 'Calculado automáticamente: shots_on_target / shots_total * 100';
COMMENT ON COLUMN player_seasons.dribble_success      IS 'Calculado automáticamente: dribbles_completed / dribbles_attempted * 100';
COMMENT ON COLUMN weather_conditions.weather_num      IS 'Índice numérico para el modelo: 0=despejado, 1=nublado, 2=lluvia/niebla, 3=tormenta/nieve';
