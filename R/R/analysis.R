#!/usr/bin/env Rscript
# =============================================================================
# whowins v2 — Motor estadístico Bayesiano
# Pipeline: ANOVA → Regresión Multinomial → Naive Bayes por jugador
#            → Actualización Bayesiana head-to-head → Poisson goles
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
  library(jsonlite)
  library(ggplot2)
  library(car)
  library(MASS)
  library(nnet)      # multinom — regresión multinomial
  library(e1071)     # naiveBayes
  library(lmtest)
  library(pROC)
})

`%||%` <- function(a, b) if (!is.null(a)) a else b

# ── Helpers ───────────────────────────────────────────────────────────────────
msg <- function(...) cat(paste0("[INFO] ", ..., "\n"), file=stderr())
err <- function(...) { cat(paste0("[ERROR] ", ..., "\n"), file=stderr()); quit(status=1) }

# ── CLI ───────────────────────────────────────────────────────────────────────
parse_args <- function() {
  args <- commandArgs(trailingOnly=TRUE)
  if (length(args) < 2) err("Uso: whowins <TeamA> <TeamB> [--home <team|neutral>] [--weather <clear|cloudy|rain>] [--altitude <m>] [--output <dir>] [--config <path>]")
  a <- list(team_a="", team_b="", home="neutral", weather="clear",
            altitude=NA_real_, output="output", config="config/teams.json")
  a$team_a <- args[1]; a$team_b <- args[2]
  i <- 3
  while (i <= length(args)) {
    switch(args[i],
      "--home"     = { a$home     <- args[i+1]; i <- i+2 },
      "--weather"  = { a$weather  <- args[i+1]; i <- i+2 },
      "--altitude" = { a$altitude <- as.numeric(args[i+1]); i <- i+2 },
      "--output"   = { a$output   <- args[i+1]; i <- i+2 },
      "--config"   = { a$config   <- args[i+1]; i <- i+2 },
      { i <- i+1 })
  }
  a
}

# ── Carga de datos ────────────────────────────────────────────────────────────
load_data <- function(cfg_path) {
  if (!file.exists(cfg_path)) err(paste("Config no encontrado:", cfg_path))
  cfg  <- fromJSON(cfg_path)
  base <- dirname(cfg_path) %>% dirname()
  ds   <- cfg$data_sources

  # ── Modo PostgreSQL ──────────────────────────────────────────────────────────
  # Activo cuando config tiene players_db con dsn no-nulo
  use_db <- !is.null(ds$players_db) &&
            !is.null(ds$players_db$dsn) &&
            nchar(ds$players_db$dsn) > 0

  if (use_db) {
    msg("Fuente de datos: PostgreSQL")

    # Verificar que DBI y RPostgres estén instalados
    for (pkg in c("DBI","RPostgres")) {
      if (!requireNamespace(pkg, quietly=TRUE)) {
        msg(paste("Paquete", pkg, "no encontrado — instalando..."))
        tryCatch(
          install.packages(pkg, repos="https://cloud.r-project.org/", quiet=TRUE),
          error = function(e) err(paste(
            pkg, "es necesario para modo PostgreSQL.",
            "Instala con: install.packages('", pkg, "')",
            "\nO usa fuente CSV configurando players_csv en el JSON."
          ))
        )
      }
    }

    db_cfg      <- ds$players_db
    dsn         <- db_cfg$dsn           # "host=X dbname=Y user=Z password=W"
    view_player <- db_cfg$player_view  %||% "v_player_details"
    view_match  <- db_cfg$match_view   %||% "v_match_history"
    season_lbl  <- db_cfg$season_label %||% NULL

    # Parsear DSN simple (host= dbname= user= password= port=)
    parse_dsn <- function(dsn_str) {
      parts <- strsplit(trimws(dsn_str), "\\s+")[[1]]
      kv    <- lapply(parts, function(p) strsplit(p, "=")[[1]])
      setNames(
        lapply(kv, function(x) if (length(x) > 1) x[2] else ""),
        sapply(kv, `[[`, 1)
      )
    }

    con <- tryCatch({
      if (grepl("^postgresql://|^postgres://", dsn)) {
        # URL style: postgresql://user:pass@host:port/dbname
        DBI::dbConnect(RPostgres::Postgres(), service = NULL,
                       .connection_string = dsn)
      } else {
        # DSN style: host=X dbname=Y user=Z password=W port=5432
        p <- parse_dsn(dsn)
        DBI::dbConnect(
          RPostgres::Postgres(),
          host     = p[["host"]]     %||% "localhost",
          dbname   = p[["dbname"]]   %||% p[["database"]] %||% "whowins",
          user     = p[["user"]]     %||% Sys.getenv("PGUSER", "postgres"),
          password = p[["password"]] %||% Sys.getenv("PGPASSWORD", ""),
          port     = as.integer(p[["port"]] %||% "5432")
        )
      }
    }, error = function(e) {
      err(paste("No se pudo conectar a PostgreSQL:", e$message,
                "\nVerifica el DSN en el JSON o usa fuente CSV."))
    })
    msg("Conexión PostgreSQL establecida.")

    # Construir filtro de temporada si se especificó
    season_filter <- if (!is.null(season_lbl) && nchar(season_lbl) > 0)
      paste0(" WHERE season_label = '", season_lbl, "'") else ""

    # ── Leer jugadores desde vista v_player_details ──────────────────────────
    player_query <- paste0(
      "SELECT player_code AS player_id,
              name,
              COALESCE(team_id_code, 'UNKNOWN') AS team_id,
              position::text AS position,
              matches,
              goals,
              assists,
              shots_on_target,
              COALESCE(pass_accuracy, 0) AS pass_accuracy,
              COALESCE(dribbles_completed, 0) AS dribbles_completed,
              COALESCE(tackles, 0) AS tackles,
              COALESCE(interceptions, 0) AS interceptions,
              COALESCE(yellow_cards, 0) AS yellow_cards,
              COALESCE(red_cards, 0) AS red_cards,
              minutes_played,
              COALESCE(rating, 7.0) AS rating,
              -- Campos extendidos (aprovechados si existen)
              COALESCE(big_chances_created, 0) AS big_chances_created,
              COALESCE(duels_won_pct, 50) AS duels_won_pct,
              COALESCE(expected_goals, 0) AS expected_goals,
              COALESCE(expected_assists, 0) AS expected_assists
       FROM ", view_player
    )

    players <- tryCatch(
      DBI::dbGetQuery(con, player_query),
      error = function(e) err(paste("Error leyendo jugadores:", e$message))
    )
    msg(paste("Jugadores cargados desde DB:", nrow(players)))

    # ── Leer partidos desde vista v_match_history ────────────────────────────
    match_query <- paste0(
      "SELECT match_code AS match_id,
              match_date::date AS date,
              home_team,
              away_team,
              home_goals,
              away_goals,
              result,
              altitude_m,
              weather,
              COALESCE(temperature_c, 20) AS temperature_c,
              COALESCE(humidity_pct, 60) AS humidity_pct,
              COALESCE(wind_kmh, 10) AS wind_kmh,
              weather_num
       FROM ", view_match
    )

    matches <- tryCatch(
      DBI::dbGetQuery(con, match_query),
      error = function(e) err(paste("Error leyendo partidos:", e$message))
    )
    msg(paste("Partidos cargados desde DB:", nrow(matches)))

    # ── Leer equipos y jugadores desde fn_team_players ────────────────────────
    # Reconstruir teams config desde la DB
    teams_in_db <- tryCatch({
      DBI::dbGetQuery(con, paste0(
        "SELECT t.team_code, t.full_name, t.stadium, t.altitude_home_m,
                g.wc_group,
                array_agg(p.player_code ORDER BY tp.jersey_number NULLS LAST)
                  FILTER (WHERE p.player_code IS NOT NULL) AS player_codes
         FROM teams t
         JOIN wc2026_groups g    ON g.team_code  = t.team_code
         LEFT JOIN team_players tp ON tp.team_id = t.team_id
         LEFT JOIN players p    ON p.player_id   = tp.player_id
         GROUP BY t.team_code, t.full_name, t.stadium, t.altitude_home_m, g.wc_group"
      ))
    }, error = function(e) {
      msg(paste("[WARN] No se pudo leer wc2026_groups:", e$message))
      NULL
    })

    if (!is.null(teams_in_db) && nrow(teams_in_db) > 0) {
      # Reconstruir lista de equipos en formato idéntico al JSON
      team_list <- lapply(seq_len(nrow(teams_in_db)), function(i) {
        r <- teams_in_db[i, ]
        codes <- if (is.character(r$player_codes))
          strsplit(gsub("[{}]","", r$player_codes), ",")[[1]]
        else character(0)
        list(
          full_name       = r$full_name,
          stadium         = r$stadium %||% "",
          altitude_home_m = r$altitude_home_m,
          players         = trimws(codes)
        )
      })
      names(team_list) <- teams_in_db$team_code
      cfg$teams <- team_list
      msg(paste("Equipos leídos desde DB:", length(team_list)))
    } else {
      msg("[WARN] wc2026_groups no encontrada — usando equipos del JSON")
    }

    DBI::dbDisconnect(con)

  } else {
    # ── Modo CSV (legacy) ───────────────────────────────────────────────────────
    msg("Fuente de datos: CSV")
    if (is.null(ds$players_csv) || is.null(ds$matches_csv))
      err("Configura players_csv y matches_csv en data_sources, o configura players_db con dsn.")

    players <- read_csv(file.path(base, ds$players_csv), show_col_types=FALSE)
    matches <- read_csv(file.path(base, ds$matches_csv), show_col_types=FALSE)
    msg(paste("Jugadores CSV:", nrow(players), "| Partidos CSV:", nrow(matches)))
  }

  # Normalizar columna 'weather' si viene como weather_num desde DB
  if (!"weather" %in% names(matches) && "weather_num" %in% names(matches)) {
    matches$weather <- dplyr::case_when(
      matches$weather_num == 0 ~ "clear",
      matches$weather_num == 1 ~ "cloudy",
      matches$weather_num >= 2 ~ "rain",
      TRUE ~ "clear"
    )
  }

  list(cfg=cfg, players=players, matches=matches)
}

# ── Stats agregadas por equipo ────────────────────────────────────────────────
team_stats <- function(players, team_id, player_ids, strict=FALSE) {
  df <- players %>% filter(player_id %in% player_ids)
  if (nrow(df) == 0) {
    if (strict) err(paste("Sin jugadores para:", team_id))
    msg(paste("[WARN] Sin jugadores en DB para", team_id, "- usando valores promedio"))
    return(tibble(
      team=team_id, avg_goals=0.05, avg_assists=0.04, avg_shots_ot=0.5,
      avg_pass_acc=75.0, avg_tackles=1.2, avg_intercept=1.0,
      avg_dribbles=0.8, avg_rating=7.0, discipline=0.1
    ))
  }
  safe_pm <- function(x, m) ifelse(m > 0, x / m, 0)
  tibble(
    team          = team_id,
    avg_goals     = mean(safe_pm(df$goals,             df$matches), na.rm=TRUE),
    avg_assists   = mean(safe_pm(df$assists,            df$matches), na.rm=TRUE),
    avg_shots_ot  = mean(safe_pm(df$shots_on_target,   df$matches), na.rm=TRUE),
    avg_pass_acc  = mean(df$pass_accuracy,                          na.rm=TRUE),
    avg_tackles   = mean(safe_pm(df$tackles,            df$matches), na.rm=TRUE),
    avg_intercept = mean(safe_pm(df$interceptions,      df$matches), na.rm=TRUE),
    avg_dribbles  = mean(safe_pm(df$dribbles_completed, df$matches), na.rm=TRUE),
    avg_rating    = mean(df$rating,                                  na.rm=TRUE),
    discipline    = mean(safe_pm(df$yellow_cards + df$red_cards*3,
                                 df$matches),                        na.rm=TRUE)
  )
}

# ── Features por partido ──────────────────────────────────────────────────────
build_features <- function(matches, players, cfg) {
  tc <- cfg$teams

  # Only aggregate teams that actually appear in the matches history
  # OR that have players loaded — avoids crashing on teams not yet in DB
  teams_in_matches <- unique(c(matches$home_team, matches$away_team))
  teams_with_data  <- names(tc)[sapply(names(tc), function(tid) {
    has_matches  <- tid %in% teams_in_matches
    has_players  <- any(players$player_id %in% (tc[[tid]]$players %||% character(0)))
    has_matches || has_players
  })]

  if (length(teams_with_data) == 0) teams_with_data <- names(tc)

  agg <- lapply(teams_with_data, function(tid) {
    team_stats(players, tid, tc[[tid]]$players %||% character(0), strict=FALSE)
  }) %>% bind_rows()

  matches <- matches %>%
    mutate(
      result3 = factor(case_when(
        result == "home_win"  ~ "home",
        result == "draw"      ~ "draw",
        result == "away_win"  ~ "away"
      ), levels=c("home","draw","away")),
      home_win    = as.integer(result == "home_win"),
      weather_num = case_when(weather=="clear"~0, weather=="cloudy"~1, weather=="rain"~2, TRUE~0)
    ) %>%
    left_join(agg %>% rename_with(~paste0("h_", .), -team), by=c("home_team"="team")) %>%
    left_join(agg %>% rename_with(~paste0("a_", .), -team), by=c("away_team"="team")) %>%
    mutate(
      diff_goals    = h_avg_goals    - a_avg_goals,
      diff_assists  = h_avg_assists  - a_avg_assists,
      diff_shots    = h_avg_shots_ot - a_avg_shots_ot,
      diff_pass     = h_avg_pass_acc - a_avg_pass_acc,
      diff_tackles  = h_avg_tackles  - a_avg_tackles,
      diff_rating   = h_avg_rating   - a_avg_rating,
      diff_discipl  = h_discipline   - a_discipline,
      home_altitude = altitude_m
    )
  matches
}

# ── 1. ANOVA multifactorial ───────────────────────────────────────────────────
run_anova <- function(data, sig=0.05) {
  msg("ANOVA multifactorial...")
  factors <- c("diff_goals","diff_assists","diff_shots","diff_pass",
               "diff_tackles","diff_rating","diff_discipl","home_altitude","weather_num")

  res <- lapply(factors, function(f) {
    m <- tryCatch(lm(as.formula(paste("home_win ~", f)), data=data), error=function(e) NULL)
    if (is.null(m)) return(tibble(factor=f, F_value=NA_real_, p_value=NA_real_, significant=FALSE, eta_sq=NA_real_))
    a <- anova(m)
    ss_factor <- a$`Sum Sq`[1]; ss_total <- sum(a$`Sum Sq`)
    tibble(factor=f, F_value=round(a$`F value`[1],4),
           p_value=round(a$`Pr(>F)`[1],6),
           significant=a$`Pr(>F)`[1] < sig,
           eta_sq=round(ss_factor/ss_total, 4))
  }) %>% bind_rows()

  sig_factors <- res %>% filter(significant) %>% pull(factor)

  # ANOVA multifactorial si hay 2+ factores sig
  multi <- NULL
  if (length(sig_factors) >= 2) {
    frm <- as.formula(paste("home_win ~", paste(sig_factors, collapse=" + ")))
    multi <- anova(lm(frm, data=data))
  }

  list(one_way=res, sig_factors=sig_factors, multi=multi)
}

# ── 2. Regresión Multinomial (3 clases) ───────────────────────────────────────
run_multinomial <- function(data, sig_factors) {
  msg("Regresión Multinomial (home / draw / away)...")
  all_f <- c("diff_goals","diff_assists","diff_shots","diff_pass",
             "diff_tackles","diff_rating","diff_discipl","home_altitude","weather_num")
  feats <- if (length(sig_factors) > 0) sig_factors else all_f
  feats <- intersect(feats, all_f)

  dc <- data[, c("result3", feats)]
  dc <- dc[complete.cases(dc), ]
  if (nrow(dc) < 15) { feats <- all_f; dc <- data[, c("result3", feats)]; dc <- dc[complete.cases(dc),] }

  frm <- as.formula(paste("result3 ~", paste(feats, collapse=" + ")))
  model <- tryCatch(
    multinom(frm, data=dc, trace=FALSE, maxit=300),
    error=function(e) { msg(paste("Multinomial falló:", e$message)); NULL }
  )
  list(model=model, feats=feats, data=dc)
}

# ── Predicción multinomial para nuevos datos ──────────────────────────────────
predict_multinomial <- function(mfit, new_row) {
  if (is.null(mfit$model)) return(c(home=1/3, draw=1/3, away=1/3))
  nd <- new_row[, intersect(mfit$feats, names(new_row)), drop=FALSE]
  p  <- tryCatch(predict(mfit$model, newdata=nd, type="probs"),
                 error=function(e) NULL)
  if (is.null(p) || length(p) < 3) return(c(home=1/3, draw=1/3, away=1/3))
  if (is.matrix(p)) p <- p[1,]
  # asegura nombres
  if (is.null(names(p))) names(p) <- c("home","draw","away")
  p[c("home","draw","away")]
}

# ── 3. Naive Bayes por jugador ────────────────────────────────────────────────
# Para cada jugador calcula P(victoria_equipo | stats_jugador)
# usando los partidos donde ese equipo participó.
run_naive_bayes_players <- function(matches, players, cfg, team_a, team_b) {
  msg("Naive Bayes por jugador...")
  tc     <- cfg$teams
  pl_a   <- players %>% filter(player_id %in% tc[[team_a]]$players)
  pl_b   <- players %>% filter(player_id %in% tc[[team_b]]$players)

  # Partidos de cada equipo con resultado relativo
  matches_a <- matches %>%
    filter(home_team == team_a | away_team == team_a) %>%
    mutate(
      team_won  = case_when(
        home_team == team_a & result == "home_win" ~ "win",
        away_team == team_a & result == "away_win" ~ "win",
        result == "draw"                           ~ "draw",
        TRUE                                       ~ "loss"
      ),
      is_home = as.integer(home_team == team_a)
    )

  matches_b <- matches %>%
    filter(home_team == team_b | away_team == team_b) %>%
    mutate(
      team_won  = case_when(
        home_team == team_b & result == "home_win" ~ "win",
        away_team == team_b & result == "away_win" ~ "win",
        result == "draw"                           ~ "draw",
        TRUE                                       ~ "loss"
      ),
      is_home = as.integer(home_team == team_b)
    )

  # Función de impacto individual con Naive Bayes
  player_nb_score <- function(pl_df, match_df) {
    if (nrow(match_df) < 3) return(pl_df %>% mutate(nb_win_prob=0.5, nb_importance=0.5))

    # features del equipo en esos partidos (proxy: stats del jugador × resultado)
    results <- match_df$team_won

    pl_df %>% rowwise() %>% mutate(
      # Likelihood: P(stats_jugador | victoria) vs P(stats_jugador | derrota)
      # Usamos Gaussian NB manual sobre métricas normalizadas del jugador
      goals_pm    = goals / matches,
      assists_pm  = assists / matches,
      shots_pm    = shots_on_target / matches,
      tackle_pm   = tackles / matches,
      nb_win_prob = {
        # Prior de victoria del equipo
        p_win  <- mean(results == "win",  na.rm=TRUE)
        p_draw <- mean(results == "draw", na.rm=TRUE)
        p_loss <- 1 - p_win - p_draw
        # Likelihood gaussiana: cuántos sigmas sobre la media del equipo
        # es este jugador en métricas ofensivas/defensivas
        team_avg_goals   <- mean(pl_df$goals / pl_df$matches, na.rm=TRUE)
        team_sd_goals    <- max(sd(pl_df$goals / pl_df$matches, na.rm=TRUE), 0.01)
        team_avg_rating  <- mean(pl_df$rating, na.rm=TRUE)
        team_sd_rating   <- max(sd(pl_df$rating, na.rm=TRUE), 0.01)
        z_goals  <- (goals_pm  - team_avg_goals)  / team_sd_goals
        z_rating <- (rating    - team_avg_rating) / team_sd_rating
        # P(win|jugador) ∝ P(win) × exp(0.4*z_goals + 0.3*z_rating)
        raw_win  <- p_win  * exp(0.4*z_goals + 0.3*z_rating)
        raw_draw <- p_draw * exp(0)
        raw_loss <- p_loss * exp(-0.2*z_goals - 0.1*z_rating)
        total    <- raw_win + raw_draw + raw_loss
        if (total <= 0) 0.5 else raw_win / total
      },
      nb_importance = abs(nb_win_prob - 0.5) * 2   # 0=neutral, 1=muy influyente
    ) %>% ungroup()
  }

  nb_a <- player_nb_score(pl_a, matches_a)
  nb_b <- player_nb_score(pl_b, matches_b)

  # Probabilidad agregada del equipo desde NB de jugadores
  p_win_a_nb <- mean(nb_a$nb_win_prob, na.rm=TRUE)
  p_win_b_nb <- mean(nb_b$nb_win_prob, na.rm=TRUE)

  list(
    nb_a         = nb_a,
    nb_b         = nb_b,
    p_win_a_nb   = p_win_a_nb,
    p_win_b_nb   = p_win_b_nb
  )
}

# ── 4. Actualización Bayesiana (prior + head-to-head) ─────────────────────────
bayesian_update <- function(prior_probs, matches, team_a, team_b) {
  msg("Actualización Bayesiana head-to-head...")

  # Partidos directos entre A y B
  h2h <- matches %>%
    filter((home_team==team_a & away_team==team_b) |
           (home_team==team_b & away_team==team_a)) %>%
    mutate(
      winner = case_when(
        home_team==team_a & result=="home_win" ~ "A",
        away_team==team_a & result=="away_win" ~ "A",
        result=="draw"                         ~ "draw",
        TRUE                                   ~ "B"
      )
    )

  n_h2h <- nrow(h2h)
  msg(paste("  Enfrentamientos directos encontrados:", n_h2h))

  if (n_h2h == 0) {
    # Sin historial H2H: prior queda intacto
    return(list(
      posterior    = prior_probs,
      n_h2h        = 0,
      h2h_wins_a   = 0,
      h2h_draws    = 0,
      h2h_wins_b   = 0,
      update_weight = 0
    ))
  }

  # Conteos head-to-head
  w_a  <- sum(h2h$winner == "A")
  d    <- sum(h2h$winner == "draw")
  w_b  <- sum(h2h$winner == "B")

  # Likelihood: P(h2h_data | resultado) usando suavizado de Laplace
  alpha <- 1   # pseudocuenta Laplace
  lk_a    <- (w_a + alpha) / (n_h2h + 3*alpha)
  lk_draw <- (d   + alpha) / (n_h2h + 3*alpha)
  lk_b    <- (w_b + alpha) / (n_h2h + 3*alpha)

  # Peso del H2H: crece con más partidos (techo en ~0.55 con 20 partidos)
  w_h2h <- min(0.55, n_h2h / (n_h2h + 15))

  # Posterior = (1-w)*prior + w*likelihood
  post_a    <- (1 - w_h2h) * prior_probs["A"]    + w_h2h * lk_a
  post_draw <- (1 - w_h2h) * prior_probs["draw"] + w_h2h * lk_draw
  post_b    <- (1 - w_h2h) * prior_probs["B"]    + w_h2h * lk_b

  # Normalizar
  total  <- post_a + post_draw + post_b
  post_a <- post_a / total; post_draw <- post_draw / total; post_b <- post_b / total

  list(
    posterior     = c(A=post_a, draw=post_draw, B=post_b),
    n_h2h         = n_h2h,
    h2h_wins_a    = w_a,
    h2h_draws     = d,
    h2h_wins_b    = w_b,
    update_weight = round(w_h2h, 3),
    lk            = c(A=lk_a, draw=lk_draw, B=lk_b)
  )
}

# ── 5. Modelo Poisson de goles + predicción de marcador ─────────────────────
run_poisson <- function(matches, players, cfg, team_a, team_b, home_team) {
  msg("Distribución Poisson de goles...")
  tc <- cfg$teams

  has_history <- nrow(matches) > 0

  # ── Lambdas desde historial de partidos ────────────────────────────────────
  if (has_history) {
    get_lambda <- function(team) {
      df <- matches %>%
        filter(home_team == team | away_team == team) %>%
        mutate(scored   = if_else(home_team == team, home_goals, away_goals),
               conceded = if_else(home_team == team, away_goals, home_goals))
      if (nrow(df) == 0) return(list(att=1.3, def=1.3))
      list(att=mean(df$scored, na.rm=TRUE), def=mean(df$conceded, na.rm=TRUE))
    }
    la <- get_lambda(team_a)
    lb <- get_lambda(team_b)
    league_avg <- mean(c(matches$home_goals, matches$away_goals), na.rm=TRUE)
    if (!is.finite(league_avg) || league_avg <= 0) league_avg <- 1.3

    lambda_a <- (la$att / league_avg) * (lb$def / league_avg) * league_avg
    lambda_b <- (lb$att / league_avg) * (la$def / league_avg) * league_avg

  } else {
    # ── Sin historial: estimar lambdas desde stats de jugadores ──────────────
    msg("  Sin partidos históricos — estimando goles desde stats de jugadores")
    sa <- team_stats(players, team_a, tc[[team_a]]$players %||% character(0))
    sb <- team_stats(players, team_b, tc[[team_b]]$players %||% character(0))

    # Proxy: goles/partido del equipo × factor ofensivo vs defensivo rival
    # Escalar avg_goals (por jugador) al equipo completo (~11 en campo)
    team_goals_a <- sa$avg_goals * 4.5   # ~4.5 jugadores ofensivos contribuyen
    team_goals_b <- sb$avg_goals * 4.5

    # Ajuste por calidad defensiva relativa (pass_acc, tackles como proxy)
    def_adj_a <- (sb$avg_tackles / max(sa$avg_tackles, 0.1)) * 0.15 + 0.85
    def_adj_b <- (sa$avg_tackles / max(sb$avg_tackles, 0.1)) * 0.15 + 0.85

    lambda_a <- max(0.5, min(team_goals_a * def_adj_a, 4.0))
    lambda_b <- max(0.5, min(team_goals_b * def_adj_b, 4.0))
  }

  # ── Ajuste localía ─────────────────────────────────────────────────────────
  if      (home_team == team_a) { lambda_a <- lambda_a * 1.12; lambda_b <- lambda_b * 0.90 }
  else if (home_team == team_b) { lambda_b <- lambda_b * 1.12; lambda_a <- lambda_a * 0.90 }

  lambda_a <- max(0.3, lambda_a)
  lambda_b <- max(0.3, lambda_b)

  # ── Matriz de probabilidad de marcadores (hasta 8 goles c/u) ──────────────
  max_g <- 8
  g_range <- 0:max_g
  score_matrix <- outer(g_range, g_range,
    FUN = function(x, y) dpois(x, lambda_a) * dpois(y, lambda_b))
  rownames(score_matrix) <- as.character(g_range)
  colnames(score_matrix) <- as.character(g_range)

  p_a_wins <- sum(score_matrix[row(score_matrix) > col(score_matrix)])
  p_b_wins <- sum(score_matrix[row(score_matrix) < col(score_matrix)])
  p_draw   <- sum(diag(score_matrix))

  # Normalizar
  tot      <- p_a_wins + p_b_wins + p_draw
  p_a_wins <- p_a_wins / tot
  p_b_wins <- p_b_wins / tot
  p_draw   <- p_draw   / tot

  # ── Top 10 marcadores más probables ───────────────────────────────────────
  sm_flat <- as.data.frame(as.table(score_matrix)) %>%
    setNames(c("g_a","g_b","prob")) %>%
    mutate(
      g_a    = as.integer(as.character(g_a)),
      g_b    = as.integer(as.character(g_b)),
      score  = paste0(g_a, "-", g_b),
      result = case_when(
        g_a > g_b ~ paste0(team_a, " gana"),
        g_a < g_b ~ paste0(team_b, " gana"),
        TRUE      ~ "Empate"
      )
    ) %>%
    arrange(desc(prob)) %>%
    slice_head(n=10)

  most_likely <- sm_flat$score[1]

  # ── Simulación Monte Carlo para intervalos de goles ───────────────────────
  set.seed(42)
  n_sim <- 50000
  sim_a <- rpois(n_sim, lambda_a)
  sim_b <- rpois(n_sim, lambda_b)

  # Goles totales esperados con IC 80%
  total_goals <- sim_a + sim_b
  goals_ci_lo <- quantile(total_goals, 0.10)
  goals_ci_hi <- quantile(total_goals, 0.90)

  list(
    lambda_a      = round(lambda_a, 3),
    lambda_b      = round(lambda_b, 3),
    p_a           = round(p_a_wins, 4),
    p_draw        = round(p_draw,   4),
    p_b           = round(p_b_wins, 4),
    exp_goals_a   = round(lambda_a, 2),
    exp_goals_b   = round(lambda_b, 2),
    most_likely   = most_likely,
    top_scores    = sm_flat,
    score_matrix  = score_matrix,
    goals_ci_lo   = round(goals_ci_lo, 1),
    goals_ci_hi   = round(goals_ci_hi, 1),
    used_history  = has_history,
    sim_a         = sim_a,
    sim_b         = sim_b
  )
}

# ── 6. Fusión Bayesiana final ─────────────────────────────────────────────────
# Combina multinomial + NB jugadores + Poisson + H2H update
fuse_models <- function(p_multi, p_nb, p_poisson, bayes_update,
                         home_team, team_a, team_b) {
  msg("Fusionando modelos (ensemble Bayesiano)...")

  # Probabilidades de cada fuente en formato (A, draw, B)
  pm <- c(A=unname(p_multi["home"]), draw=unname(p_multi["draw"]), B=unname(p_multi["away"]))

  # NB de jugadores → convertir a 3 clases (draw como residual)
  nb_raw_a  <- p_nb$p_win_a_nb
  nb_raw_b  <- p_nb$p_win_b_nb
  nb_sum    <- nb_raw_a + nb_raw_b
  if (nb_sum <= 0) nb_sum <- 1
  nb_draw   <- max(0.05, 1 - nb_sum) * 0.4
  nb_a_norm <- nb_raw_a / (nb_raw_a + nb_raw_b + nb_draw)
  nb_b_norm <- nb_raw_b / (nb_raw_a + nb_raw_b + nb_draw)
  nb_d_norm <- nb_draw  / (nb_raw_a + nb_raw_b + nb_draw)
  pn <- c(A=nb_a_norm, draw=nb_d_norm, B=nb_b_norm)

  pp <- c(A=p_poisson$p_a, draw=p_poisson$p_draw, B=p_poisson$p_b)

  # Pesos del ensemble (se puede tunear)
  w_multi   <- 0.35
  w_nb      <- 0.25
  w_poisson <- 0.40
  ensemble  <- w_multi*pm + w_nb*pn + w_poisson*pp
  ensemble  <- ensemble / sum(ensemble)

  # Ajuste local/visitante (+4 pp al equipo local)
  home_bonus <- 0.04
  if      (home_team == team_a) { ensemble["A"] <- ensemble["A"] + home_bonus }
  else if (home_team == team_b) { ensemble["B"] <- ensemble["B"] + home_bonus }
  ensemble <- ensemble / sum(ensemble)

  # Actualización Bayesiana con H2H
  prior_for_update <- c(A=unname(ensemble["A"]), draw=unname(ensemble["draw"]), B=unname(ensemble["B"]))
  # Re-usar el objeto bayes_update ya calculado con este prior
  # (recalculamos el posterior con el ensemble como nuevo prior)
  n_h2h <- bayes_update$n_h2h
  if (n_h2h > 0) {
    lk       <- bayes_update$lk
    w_h2h    <- bayes_update$update_weight
    post     <- (1 - w_h2h)*prior_for_update + w_h2h*lk
    post     <- post / sum(post)
  } else {
    post <- prior_for_update
  }

  list(
    final     = post,
    ensemble  = ensemble,
    per_model = list(multinomial=pm, naive_bayes=pn, poisson=pp),
    weights   = c(multinomial=w_multi, naive_bayes=w_nb, poisson=w_poisson)
  )
}

# ── Métricas del modelo multinomial ──────────────────────────────────────────
model_metrics <- function(mfit) {
  if (is.null(mfit$model)) return(list(accuracy=NA, coefs=NULL))
  pred  <- predict(mfit$model, type="class")
  real  <- mfit$data$result3
  acc   <- mean(pred == real, na.rm=TRUE)
  coefs <- tryCatch(coef(mfit$model), error=function(e) NULL)
  list(accuracy=round(acc,4), coefs=coefs)
}

# ── Impacto de jugadores ──────────────────────────────────────────────────────
player_impact <- function(players, nb_res, cfg, team_a, team_b) {
  tc <- cfg$teams
  pl_a <- players %>% filter(player_id %in% tc[[team_a]]$players) %>% mutate(team=team_a)
  pl_b <- players %>% filter(player_id %in% tc[[team_b]]$players) %>% mutate(team=team_b)

  # Unir probabilidades NB
  nb_a_tbl <- nb_res$nb_a[, c("player_id","nb_win_prob","nb_importance")]
  nb_b_tbl <- nb_res$nb_b[, c("player_id","nb_win_prob","nb_importance")]

  combined <- bind_rows(pl_a, pl_b) %>%
    left_join(bind_rows(nb_a_tbl, nb_b_tbl), by="player_id") %>%
    mutate(
      goals_pm   = goals / matches,
      assists_pm = assists / matches,
      impact_score = goals_pm*3 + assists_pm*2 +
                     (shots_on_target/matches)*0.5 +
                     (tackles/matches)*0.3 +
                     (interceptions/matches)*0.3 +
                     rating*0.5 +
                     (nb_win_prob %||% 0.5 - 0.5)*4 -
                     (yellow_cards + red_cards*3)/matches*0.5
    ) %>%
    arrange(desc(impact_score))
  combined
}

# ── Gráficas ──────────────────────────────────────────────────────────────────
save_plots <- function(anova_res, fusion, nb_res, pl_impact, poisson,
                        bayes_upd, team_a, team_b, out_dir) {
  theme_ww <- theme_minimal(base_size=12) +
    theme(plot.title=element_text(face="bold", size=13),
          legend.position="bottom")

  final <- fusion$final

  # 1. Probabilidades finales
  tryCatch({
    df <- tibble(
      equipo = factor(c(team_a,"Empate",team_b), levels=c(team_a,"Empate",team_b)),
      prob   = c(final["A"], final["draw"], final["B"]) * 100,
      color  = c("#1565C0","#757575","#B71C1C")
    )
    g <- ggplot(df, aes(x=equipo, y=prob, fill=equipo)) +
      geom_col(width=0.55) +
      geom_text(aes(label=paste0(round(prob,1),"%")), vjust=-0.5, size=5.5, fontface="bold") +
      scale_fill_manual(values=setNames(df$color, df$equipo)) +
      labs(title=paste("Predicción final:", team_a, "vs", team_b),
           subtitle="Ensemble Bayesiano (Multinomial + Naive Bayes + Poisson + H2H)",
           x="", y="Probabilidad (%)") +
      theme_ww + theme(legend.position="none") + ylim(0, max(df$prob)*1.2)
    ggsave(file.path(out_dir,"01_probabilidades.png"), g, width=7, height=5, dpi=150)
  }, error=function(e) msg(paste("Plot 1:", e$message)))

  # 2. Comparación de modelos
  tryCatch({
    pm <- fusion$per_model
    df2 <- bind_rows(
      tibble(modelo="Multinomial",  equipo=c(team_a,"Empate",team_b),
             prob=c(pm$multinomial["A"],pm$multinomial["draw"],pm$multinomial["B"])*100),
      tibble(modelo="Naive Bayes",  equipo=c(team_a,"Empate",team_b),
             prob=c(pm$naive_bayes["A"],pm$naive_bayes["draw"],pm$naive_bayes["B"])*100),
      tibble(modelo="Poisson",      equipo=c(team_a,"Empate",team_b),
             prob=c(pm$poisson["A"],pm$poisson["draw"],pm$poisson["B"])*100),
      tibble(modelo="Final (H2H)",  equipo=c(team_a,"Empate",team_b),
             prob=c(final["A"],final["draw"],final["B"])*100)
    ) %>% mutate(
      modelo=factor(modelo, levels=c("Multinomial","Naive Bayes","Poisson","Final (H2H)")),
      equipo=factor(equipo, levels=c(team_a,"Empate",team_b))
    )
    g2 <- ggplot(df2, aes(x=modelo, y=prob, fill=equipo)) +
      geom_col(position="dodge") +
      scale_fill_manual(values=c("#1565C0","#757575","#B71C1C")) +
      geom_text(aes(label=paste0(round(prob,0),"%")),
                position=position_dodge(width=0.9), vjust=-0.4, size=3.2) +
      labs(title="Probabilidades por modelo", x="", y="%", fill="") +
      theme_ww + ylim(0, 75)
    ggsave(file.path(out_dir,"02_comparacion_modelos.png"), g2, width=9, height=5, dpi=150)
  }, error=function(e) msg(paste("Plot 2:", e$message)))

  # 3. ANOVA — importancia de factores (eta²)
  tryCatch({
    df3 <- anova_res$one_way %>% filter(!is.na(eta_sq)) %>%
      arrange(desc(eta_sq))
    g3 <- ggplot(df3, aes(x=reorder(factor, eta_sq), y=eta_sq*100, fill=significant)) +
      geom_col() + coord_flip() +
      scale_fill_manual(values=c("FALSE"="#BDBDBD","TRUE"="#43A047"),
                        labels=c("No significativo","Significativo p<0.05")) +
      labs(title="Tamaño de efecto por factor (ANOVA — η²)",
           x="Factor", y="η² (%)", fill="") +
      theme_ww
    ggsave(file.path(out_dir,"03_anova_eta2.png"), g3, width=8, height=5, dpi=150)
  }, error=function(e) msg(paste("Plot 3:", e$message)))

  # 4. Top jugadores NB — impacto
  tryCatch({
    top <- pl_impact %>% group_by(team) %>%
      slice_max(impact_score, n=5) %>% ungroup()
    g4 <- ggplot(top, aes(x=reorder(name, impact_score), y=impact_score, fill=team)) +
      geom_col() + coord_flip() +
      scale_fill_manual(values=c("#1565C0","#B71C1C")) +
      labs(title="Top 5 jugadores por impacto (índice NB-ponderado)",
           x="Jugador", y="Índice de impacto", fill="Equipo") +
      theme_ww
    ggsave(file.path(out_dir,"04_jugadores_impacto.png"), g4, width=9, height=5, dpi=150)
  }, error=function(e) msg(paste("Plot 4:", e$message)))

  # 5. Probabilidad NB por jugador
  tryCatch({
    df5 <- pl_impact %>% arrange(team, desc(nb_win_prob)) %>%
      mutate(name=factor(name, levels=rev(name)))
    g5 <- ggplot(df5, aes(x=name, y=(nb_win_prob %||% 0.5)*100, fill=team)) +
      geom_col() + coord_flip() +
      geom_hline(yintercept=50, linetype="dashed", color="gray40") +
      scale_fill_manual(values=c("#1565C0","#B71C1C")) +
      labs(title="P(victoria equipo | jugador) — Naive Bayes",
           x="Jugador", y="P(win) %", fill="Equipo") +
      theme_ww
    ggsave(file.path(out_dir,"05_nb_por_jugador.png"), g5, width=9, height=6, dpi=150)
  }, error=function(e) msg(paste("Plot 5:", e$message)))

  # 6. Heatmap de marcadores + Top-10 barras
  tryCatch({
    # 6a — Heatmap (hasta 5-5)
    sm      <- poisson$score_matrix
    max_show <- min(5, nrow(sm)-1)
    sm_df <- as.data.frame(sm[1:(max_show+1), 1:(max_show+1)]) %>%
      tibble::rownames_to_column("goles_A") %>%
      pivot_longer(-goles_A, names_to="goles_B", values_to="prob") %>%
      mutate(prob_pct = round(prob*100, 2),
             goles_A  = factor(goles_A, levels=as.character(0:max_show)),
             goles_B  = factor(goles_B, levels=as.character(0:max_show)))
    g6a <- ggplot(sm_df, aes(x=goles_B, y=goles_A, fill=prob_pct)) +
      geom_tile(color="white", linewidth=0.5) +
      geom_text(aes(label=paste0(prob_pct,"%")), size=3.2, fontface="bold") +
      scale_fill_gradient(low="#FFF9C4", high="#E53935") +
      labs(title="Probabilidad de marcadores exactos (Poisson)",
           subtitle=paste(team_a, "(filas) vs", team_b, "(columnas)"),
           x=paste("Goles", team_b), y=paste("Goles", team_a), fill="Prob %") +
      theme_ww
    ggsave(file.path(out_dir,"06_matriz_scores.png"), g6a, width=7, height=6, dpi=150)

    # 6b — Top-10 marcadores más probables (barras)
    ts <- poisson$top_scores %>%
      mutate(score = factor(score, levels=rev(score)),
             color = case_when(
               grepl(paste0("^", team_a, " gana"), result) ~ "#1565C0",
               grepl(paste0("^", team_b, " gana"), result) ~ "#B71C1C",
               TRUE ~ "#757575"
             ))
    g6b <- ggplot(ts, aes(x=score, y=prob*100, fill=result)) +
      geom_col() + coord_flip() +
      geom_text(aes(label=paste0(round(prob*100,1),"%")), hjust=-0.1, size=3.5) +
      scale_fill_manual(values=c(
        setNames("#1565C0", paste0(team_a, " gana")),
        setNames("#B71C1C", paste0(team_b, " gana")),
        "Empate" = "#757575"
      )) +
      labs(title="Top 10 marcadores más probables",
           x="Marcador", y="Probabilidad (%)", fill="") +
      theme_ww + ylim(0, max(ts$prob*100) * 1.2)
    ggsave(file.path(out_dir,"06b_top_scores.png"), g6b, width=8, height=5, dpi=150)
  }, error=function(e) msg(paste("Plot 6:", e$message)))

  # 7. Actualización Bayesiana — prior vs posterior
  tryCatch({
    if (bayes_upd$n_h2h > 0) {
      ens <- fusion$ensemble
      post <- fusion$final
      df7 <- bind_rows(
        tibble(etapa="Prior (ensemble)", resultado=c(team_a,"Empate",team_b),
               prob=c(ens["A"],ens["draw"],ens["B"])*100),
        tibble(etapa="Posterior (H2H)",  resultado=c(team_a,"Empate",team_b),
               prob=c(post["A"],post["draw"],post["B"])*100)
      ) %>% mutate(etapa=factor(etapa, levels=c("Prior (ensemble)","Posterior (H2H)")),
                   resultado=factor(resultado, levels=c(team_a,"Empate",team_b)))
      g7 <- ggplot(df7, aes(x=etapa, y=prob, fill=resultado)) +
        geom_col(position="dodge") +
        scale_fill_manual(values=c("#1565C0","#757575","#B71C1C")) +
        geom_text(aes(label=paste0(round(prob,1),"%")),
                  position=position_dodge(width=0.9), vjust=-0.3, size=3.5) +
        labs(title=paste("Actualización Bayesiana con H2H (n =",bayes_upd$n_h2h,"partidos)"),
             x="", y="Probabilidad (%)", fill="") +
        theme_ww + ylim(0,75)
      ggsave(file.path(out_dir,"07_bayes_update.png"), g7, width=8, height=5, dpi=150)
    }
  }, error=function(e) msg(paste("Plot 7:", e$message)))

  msg(paste("Gráficas guardadas en:", out_dir))
}

# ── Reporte completo ───────────────────────────────────────────────────────────
write_report <- function(team_a, team_b, fusion, bayes_upd, anova_res,
                          mfit_metrics, nb_res, pl_impact, poisson,
                          conditions, out_dir) {
  f   <- fusion$final
  pm  <- fusion$per_model
  sep <- paste0(strrep("─", 76))

  lines <- c(
    strrep("=",78),
    " WHOWINS v2 — ANÁLISIS ESTADÍSTICO BAYESIANO COMPLETO",
    paste(" Partido  :", team_a, "vs", team_b),
    paste(" Generado :", format(Sys.time(),"%Y-%m-%d %H:%M:%S")),
    strrep("=",78), "",
    sep, " CONDICIONES", sep,
    paste(" Local    :", ifelse(conditions$home=="neutral","Cancha neutral", conditions$home)),
    paste(" Clima    :", conditions$weather),
    paste(" Altitud  :", round(conditions$altitude), "m.s.n.m"),
    "", sep, " RESULTADO FINAL (Ensemble Bayesiano)", sep,
    sprintf(" %-12s  %5.1f%%", team_a, f["A"]*100),
    sprintf(" %-12s  %5.1f%%", "Empate",   f["draw"]*100),
    sprintf(" %-12s  %5.1f%%", team_b, f["B"]*100),
    "",
    paste(" Resultado más probable:", poisson$most_likely),
    paste(" Goles esperados:", team_a, poisson$exp_goals_a, " | ", team_b, poisson$exp_goals_b),
    "", sep, " PROBABILIDADES POR MODELO", sep,
    sprintf(" %-20s  %s: %4.1f%%  Empate: %4.1f%%  %s: %4.1f%%",
      "Multinomial",
      team_a, pm$multinomial["A"]*100, pm$multinomial["draw"]*100, team_b, pm$multinomial["B"]*100),
    sprintf(" %-20s  %s: %4.1f%%  Empate: %4.1f%%  %s: %4.1f%%",
      "Naive Bayes",
      team_a, pm$naive_bayes["A"]*100, pm$naive_bayes["draw"]*100, team_b, pm$naive_bayes["B"]*100),
    sprintf(" %-20s  %s: %4.1f%%  Empate: %4.1f%%  %s: %4.1f%%",
      "Poisson",
      team_a, pm$poisson["A"]*100, pm$poisson["draw"]*100, team_b, pm$poisson["B"]*100),
    sprintf(" %-20s  %s: %4.1f%%  Empate: %4.1f%%  %s: %4.1f%%",
      "Ensemble",
      team_a, fusion$ensemble["A"]*100, fusion$ensemble["draw"]*100, team_b, fusion$ensemble["B"]*100),
    sprintf(" %-20s  %s: %4.1f%%  Empate: %4.1f%%  %s: %4.1f%%  [w=%.2f, n=%d]",
      "Final (H2H update)",
      team_a, f["A"]*100, f["draw"]*100, team_b, f["B"]*100,
      bayes_upd$update_weight, bayes_upd$n_h2h),
    "", sep, " ACTUALIZACIÓN BAYESIANA — HEAD TO HEAD", sep,
    paste(" Enfrentamientos directos:", bayes_upd$n_h2h),
    paste(" Victorias", team_a, ":", bayes_upd$h2h_wins_a),
    paste(" Empates                :", bayes_upd$h2h_draws),
    paste(" Victorias", team_b, ":", bayes_upd$h2h_wins_b),
    paste(" Peso del H2H           :", bayes_upd$update_weight,
          "(0=sin efecto, 0.55=máximo)"),
    "", sep, " ANOVA MULTIFACTORIAL", sep,
    sprintf(" %-24s  %8s  %10s  %8s  %s",
            "Factor","F-value","p-value","η²","Sig."),
    strrep("-",65)
  )

  for (i in seq_len(nrow(anova_res$one_way))) {
    r <- anova_res$one_way[i,]
    lines <- c(lines, sprintf(" %-24s  %8.3f  %10.6f  %8.4f  %s",
      r$factor, r$F_value %||% 0, r$p_value %||% 1,
      r$eta_sq %||% 0, ifelse(r$significant,"***","")))
  }

  lines <- c(lines,
    paste(" Factores significativos:", paste(anova_res$sig_factors, collapse=", ")),
    "", sep, " MODELO MULTINOMIAL", sep,
    paste(" Precisión (accuracy):", mfit_metrics$accuracy)
  )

  if (!is.null(mfit_metrics$coefs)) {
    lines <- c(lines, " Coeficientes:")
    for (cl in rownames(mfit_metrics$coefs)) {
      for (v in colnames(mfit_metrics$coefs)) {
        lines <- c(lines, sprintf("   [%s] %-22s: %+.6f", cl, v, mfit_metrics$coefs[cl,v]))
      }
    }
  }

  lines <- c(lines, "", sep, " NAIVE BAYES — SCORES POR JUGADOR", sep)

  for (tid in c(team_a, team_b)) {
    nb_tbl <- if (tid==team_a) nb_res$nb_a else nb_res$nb_b
    lines <- c(lines, paste0(" [ ", tid, " ]"),
      sprintf("  %-22s  Pos  Goles  Asist  Rating  P(win)%%  Importancia",
              "Jugador"),
      strrep("-",72))
    for (j in seq_len(nrow(nb_tbl))) {
      r <- nb_tbl[j,]
      lines <- c(lines, sprintf("  %-22s  %-4s  %5d  %5d  %6.1f  %7.1f%%  %10.3f",
        r$name, r$position, r$goals, r$assists, r$rating,
        (r$nb_win_prob %||% 0.5)*100, r$nb_importance %||% 0))
    }
    lines <- c(lines, "")
  }

  lines <- c(lines, sep, " POISSON — DISTRIBUCIÓN DE GOLES", sep,
    paste(" λ", team_a, ":", poisson$lambda_a),
    paste(" λ", team_b, ":", poisson$lambda_b),
    paste(" Goles esperados:", team_a, poisson$exp_goals_a, "|", team_b, poisson$exp_goals_b),
    paste(" Goles totales (IC 80%):", poisson$goals_ci_lo, "–", poisson$goals_ci_hi),
    paste(" Fuente:", ifelse(poisson$used_history,
                             "historial de partidos",
                             "stats de jugadores (sin historial histórico)")),
    "",
    " TOP 10 MARCADORES MÁS PROBABLES:",
    sprintf(" %-6s  %-30s  %s", "Rank", "Marcador (resultado)", "Prob %"),
    strrep("-", 50)
  )

  ts <- poisson$top_scores
  for (i in seq_len(min(10, nrow(ts)))) {
    lines <- c(lines, sprintf(" %4d.  %-4s  %-26s  %5.2f%%",
      i, ts$score[i], ts$result[i], ts$prob[i]*100))
  }

  lines <- c(lines, "",
    " Matriz de probabilidad de marcadores (0-5 × 0-5):",
    sprintf(" %-6s %s", paste0(team_a, "↓"), paste(sprintf("%6s", 0:5), collapse="")),
    strrep("-", 44)
  )
  sm <- round(poisson$score_matrix[1:6, 1:6]*100, 1)
  for (i in 1:6) {
    lines <- c(lines, sprintf(" %-6s %s", rownames(sm)[i],
      paste(sprintf("%6.2f", sm[i,]), collapse="")))
  }

  lines <- c(lines, "",
    strrep("=",78),
    " Archivos generados en:", paste(" ", out_dir),
    strrep("=",78))

  writeLines(lines, file.path(out_dir,"reporte_completo.txt"))
  invisible(file.path(out_dir,"reporte_completo.txt"))
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════
main <- function() {
  args      <- parse_args()
  team_a    <- args$team_a
  team_b    <- args$team_b
  home_team <- args$home
  weather   <- args$weather
  altitude  <- args$altitude
  out_dir   <- args$output
  cfg_path  <- args$config

  dir.create(out_dir, recursive=TRUE, showWarnings=FALSE)

  # 0. Datos
  msg(paste("Cargando datos:", cfg_path))
  d       <- load_data(cfg_path)
  cfg     <- d$cfg
  players <- d$players
  matches <- d$matches

  tc <- cfg$teams
  if (!team_a %in% names(tc)) err(paste("Equipo no en config:", team_a))
  if (!team_b %in% names(tc)) err(paste("Equipo no en config:", team_b))

  sig_level <- cfg$model_settings$anova_significance %||% 0.05

  # Altitud por defecto
  if (is.na(altitude)) {
    altitude <- if (home_team == team_a)      tc[[team_a]]$altitude_home_m
                else if (home_team == team_b) tc[[team_b]]$altitude_home_m
                else mean(c(tc[[team_a]]$altitude_home_m, tc[[team_b]]$altitude_home_m))
  }

  # 1. Features históricas
  msg("Construyendo features históricas...")
  feats <- build_features(matches, players, cfg)

  # 2. ANOVA
  anova_res <- run_anova(feats, sig_level)
  msg(paste("Factores sig:", paste(anova_res$sig_factors, collapse=", ")))

  # 3. Regresión Multinomial
  mfit <- run_multinomial(feats, anova_res$sig_factors)
  metrics <- model_metrics(mfit)
  msg(paste("Multinomial accuracy:", metrics$accuracy))

  # Punto a predecir
  sa <- team_stats(players, team_a, tc[[team_a]]$players)
  sb <- team_stats(players, team_b, tc[[team_b]]$players)
  weather_num <- switch(weather, clear=0, cloudy=1, rain=2, 0)

  new_row <- data.frame(
    diff_goals    = sa$avg_goals    - sb$avg_goals,
    diff_assists  = sa$avg_assists  - sb$avg_assists,
    diff_shots    = sa$avg_shots_ot - sb$avg_shots_ot,
    diff_pass     = sa$avg_pass_acc - sb$avg_pass_acc,
    diff_tackles  = sa$avg_tackles  - sb$avg_tackles,
    diff_rating   = sa$avg_rating   - sb$avg_rating,
    diff_discipl  = sa$discipline   - sb$discipline,
    home_altitude = altitude,
    weather_num   = weather_num
  )

  p_multi <- predict_multinomial(mfit, new_row)

  # 4. Naive Bayes por jugador
  nb_res <- run_naive_bayes_players(matches, players, cfg, team_a, team_b)

  # 5. Poisson
  poisson <- run_poisson(matches, players, cfg, team_a, team_b, home_team)

  # 6. H2H Bayesiano (prior neutro; se actualizará en fuse)
  bayes_upd <- bayesian_update(
    prior_probs=c(A=1/3, draw=1/3, B=1/3),
    matches=matches, team_a=team_a, team_b=team_b
  )

  # 7. Fusión
  fusion <- fuse_models(p_multi, nb_res, poisson, bayes_upd,
                         home_team, team_a, team_b)

  # 8. Impacto de jugadores
  pl_impact <- player_impact(players, nb_res, cfg, team_a, team_b)

  # 9. Gráficas
  save_plots(anova_res, fusion, nb_res, pl_impact, poisson,
              bayes_upd, team_a, team_b, out_dir)

  # 10. Reporte
  conditions <- list(home=home_team, weather=weather, altitude=altitude)
  write_report(team_a, team_b, fusion, bayes_upd, anova_res, metrics,
                nb_res, pl_impact, poisson, conditions, out_dir)

  # ── Salida estándar ────────────────────────────────────────────────────────
  f <- fusion$final
  cat("\n")
  cat(paste0(strrep("═", 48), "\n"))
  cat(sprintf("  ⚽  %s  vs  %s\n", team_a, team_b))
  cat(paste0(strrep("─", 48), "\n"))
  cat(sprintf("  %-18s  %5.1f%%\n", team_a,   round(f["A"]*100, 1)))
  cat(sprintf("  %-18s  %5.1f%%\n", "Empate",  round(f["draw"]*100, 1)))
  cat(sprintf("  %-18s  %5.1f%%\n", team_b,   round(f["B"]*100, 1)))
  cat(paste0(strrep("─", 48), "\n"))

  cat(sprintf("  Goles esperados : %s %.2f  |  %s %.2f\n",
              team_a, poisson$exp_goals_a, team_b, poisson$exp_goals_b))
  cat(sprintf("  Goles totales   : %.1f – %.1f  (IC 80%%)\n",
              poisson$goals_ci_lo, poisson$goals_ci_hi))
  cat(sprintf("  Datos usados    : %s\n",
              ifelse(poisson$used_history, "historial de partidos", "stats de jugadores (sin historial)")))
  cat(sprintf("  H2H             : %d partidos  (peso Bayesiano: %.2f)\n",
              bayes_upd$n_h2h, bayes_upd$update_weight))

  cat(paste0(strrep("─", 48), "\n"))
  cat("  Top marcadores más probables:\n")
  ts <- poisson$top_scores
  for (i in seq_len(min(5, nrow(ts)))) {
    cat(sprintf("    %d. %s  (%s)  %.1f%%\n",
                i, ts$score[i], ts$result[i], ts$prob[i]*100))
  }
  cat(paste0(strrep("═", 48), "\n"))
  cat(sprintf("\n  Reporte : %s/reporte_completo.txt\n", out_dir))
  cat(sprintf("  Gráficas: %s/0*.png\n", out_dir))
  cat("\n")
}

main()
