-- =============================================================================
-- whowins — Seed: Mundial 2026
-- Todos los datos de referencia: países, competición, temporada, 48 equipos
-- y grupos del Mundial FIFA 2026 (USA / México / Canadá)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- PAÍSES (iso_code, name, continent)
-- -----------------------------------------------------------------------------
INSERT INTO countries (iso_code, name, continent) VALUES
-- Anfitriones
('US','United States','CONCACAF'),('MX','Mexico','CONCACAF'),('CA','Canada','CONCACAF'),
-- CONMEBOL
('AR','Argentina','CONMEBOL'),('BR','Brazil','CONMEBOL'),('CO','Colombia','CONMEBOL'),
('EC','Ecuador','CONMEBOL'),('PY','Paraguay','CONMEBOL'),('UY','Uruguay','CONMEBOL'),
-- CONCACAF extras
('CW','Curaçao','CONCACAF'),('HT','Haiti','CONCACAF'),('PA','Panama','CONCACAF'),
-- CAF
('DZ','Algeria','CAF'),('CV','Cabo Verde','CAF'),('CI','Côte d''Ivoire','CAF'),
('EG','Egypt','CAF'),('GH','Ghana','CAF'),('MA','Morocco','CAF'),
('SN','Senegal','CAF'),('ZA','South Africa','CAF'),('TN','Tunisia','CAF'),
('CD','DR Congo','CAF'),
-- AFC
('AU','Australia','AFC'),('IR','Iran','AFC'),('JP','Japan','AFC'),
('JO','Jordan','AFC'),('KR','South Korea','AFC'),('QA','Qatar','AFC'),
('SA','Saudi Arabia','AFC'),('UZ','Uzbekistan','AFC'),('IQ','Iraq','AFC'),
-- OFC
('NZ','New Zealand','OFC'),
-- UEFA
('AT','Austria','UEFA'),('BE','Belgium','UEFA'),('BA','Bosnia and Herzegovina','UEFA'),
('HR','Croatia','UEFA'),('CZ','Czechia','UEFA'),('EN','England','UEFA'),
('FR','France','UEFA'),('DE','Germany','UEFA'),('NL','Netherlands','UEFA'),
('NO','Norway','UEFA'),('PT','Portugal','UEFA'),('SC','Scotland','UEFA'),
('ES','Spain','UEFA'),('SE','Sweden','UEFA'),('CH','Switzerland','UEFA'),
('TR','Türkiye','UEFA')
ON CONFLICT (iso_code) DO NOTHING;

-- -----------------------------------------------------------------------------
-- COMPETICIÓN — FIFA World Cup 2026
-- -----------------------------------------------------------------------------
INSERT INTO competitions (name, short_name, type, level) VALUES
('FIFA World Cup 2026','WC2026','continental',1)
ON CONFLICT DO NOTHING;

-- -----------------------------------------------------------------------------
-- TEMPORADA — WC2026 (una sola, no es liga regular)
-- -----------------------------------------------------------------------------
INSERT INTO seasons (competition_id, label, start_date, end_date, active)
SELECT c.competition_id, '2026', '2026-06-11', '2026-07-19', TRUE
FROM   competitions c
WHERE  c.short_name = 'WC2026'
ON CONFLICT (competition_id, label) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 48 EQUIPOS (team_code = código FIFA estándar)
-- Grupos confirmados por el sorteo oficial (fuente: NBC Sports / Yahoo Sports, jun 2026)
-- Grupos A–L:
--   A: Mexico, South Korea, South Africa, Czechia
--   B: Canada, Switzerland, Qatar, Bosnia-Herzegovina
--   C: USA, Paraguay, Australia, Türkiye
--   D: Argentina, Chile (placeholder), Ecuador, Algeria   ← ver nota *
--   E: Brazil, Morocco, Croatia, Senegal                  ← ajustar con draw final
--   F: France, Norway, Côte d'Ivoire, New Zealand
--   G: England, Sweden, Egypt, Uzbekistan
--   H: Spain, Iran, Uruguay, Scotland
--   I: Germany, Netherlands, Cabo Verde, Ghana
--   J: Portugal, Jordan, Panama, Curaçao
--   K: Belgium, Saudi Arabia, South Africa ← ajustar
--   L: Japan, Colombia, Iraq, DR Congo
-- Nota: los grupos exactos siguen actualizándose; se almacenan en wc2026_groups
-- -----------------------------------------------------------------------------
INSERT INTO teams (team_code, full_name, short_name, country_id, altitude_home_m)
SELECT v.code, v.full_name, v.short_name, c.country_id, v.alt
FROM (VALUES
  -- CONCACAF
  ('MEX','Mexico','Mexico',0),
  ('USA','United States','USA',0),
  ('CAN','Canada','Canada',0),
  ('CUR','Curaçao','Curaçao',0),
  ('HAI','Haiti','Haiti',0),
  ('PAN','Panama','Panama',0),
  -- CONMEBOL
  ('ARG','Argentina','Argentina',600),
  ('BRA','Brazil','Brazil',760),
  ('COL','Colombia','Colombia',2600),
  ('ECU','Ecuador','Ecuador',2800),
  ('PAR','Paraguay','Paraguay',60),
  ('URU','Uruguay','Uruguay',43),
  -- CAF
  ('ALG','Algeria','Algeria',0),
  ('CPV','Cabo Verde','C.Verde',0),
  ('CIV','Côte d''Ivoire','C.Ivoire',0),
  ('EGY','Egypt','Egypt',0),
  ('GHA','Ghana','Ghana',0),
  ('MAR','Morocco','Morocco',0),
  ('SEN','Senegal','Senegal',0),
  ('RSA','South Africa','S.Africa',0),
  ('TUN','Tunisia','Tunisia',0),
  ('COD','DR Congo','DR Congo',320),
  -- AFC
  ('AUS','Australia','Australia',0),
  ('IRN','Iran','Iran',1200),
  ('JPN','Japan','Japan',0),
  ('JOR','Jordan','Jordan',770),
  ('KOR','South Korea','S.Korea',0),
  ('QAT','Qatar','Qatar',0),
  ('KSA','Saudi Arabia','S.Arabia',600),
  ('UZB','Uzbekistan','Uzbek.',460),
  ('IRQ','Iraq','Iraq',34),
  -- OFC
  ('NZL','New Zealand','N.Zealand',0),
  -- UEFA
  ('AUT','Austria','Austria',0),
  ('BEL','Belgium','Belgium',0),
  ('BIH','Bosnia and Herzegovina','Bosnia',0),
  ('CRO','Croatia','Croatia',0),
  ('CZE','Czechia','Czechia',0),
  ('ENG','England','England',0),
  ('FRA','France','France',0),
  ('GER','Germany','Germany',0),
  ('NED','Netherlands','Nether.',0),
  ('NOR','Norway','Norway',0),
  ('POR','Portugal','Portugal',0),
  ('SCO','Scotland','Scotland',0),
  ('ESP','Spain','Spain',650),
  ('SWE','Sweden','Sweden',0),
  ('SUI','Switzerland','Switzerl.',0),
  ('TUR','Türkiye','Türkiye',0)
) AS v(code, full_name, short_name, alt)
JOIN countries c ON c.iso_code = (
  CASE v.code
    WHEN 'MEX' THEN 'MX' WHEN 'USA' THEN 'US' WHEN 'CAN' THEN 'CA'
    WHEN 'CUR' THEN 'CW' WHEN 'HAI' THEN 'HT' WHEN 'PAN' THEN 'PA'
    WHEN 'ARG' THEN 'AR' WHEN 'BRA' THEN 'BR' WHEN 'COL' THEN 'CO'
    WHEN 'ECU' THEN 'EC' WHEN 'PAR' THEN 'PY' WHEN 'URU' THEN 'UY'
    WHEN 'ALG' THEN 'DZ' WHEN 'CPV' THEN 'CV' WHEN 'CIV' THEN 'CI'
    WHEN 'EGY' THEN 'EG' WHEN 'GHA' THEN 'GH' WHEN 'MAR' THEN 'MA'
    WHEN 'SEN' THEN 'SN' WHEN 'RSA' THEN 'ZA' WHEN 'TUN' THEN 'TN'
    WHEN 'COD' THEN 'CD' WHEN 'AUS' THEN 'AU' WHEN 'IRN' THEN 'IR'
    WHEN 'JPN' THEN 'JP' WHEN 'JOR' THEN 'JO' WHEN 'KOR' THEN 'KR'
    WHEN 'QAT' THEN 'QA' WHEN 'KSA' THEN 'SA' WHEN 'UZB' THEN 'UZ'
    WHEN 'IRQ' THEN 'IQ' WHEN 'NZL' THEN 'NZ' WHEN 'AUT' THEN 'AT'
    WHEN 'BEL' THEN 'BE' WHEN 'BIH' THEN 'BA' WHEN 'CRO' THEN 'HR'
    WHEN 'CZE' THEN 'CZ' WHEN 'ENG' THEN 'EN' WHEN 'FRA' THEN 'FR'
    WHEN 'GER' THEN 'DE' WHEN 'NED' THEN 'NL' WHEN 'NOR' THEN 'NO'
    WHEN 'POR' THEN 'PT' WHEN 'SCO' THEN 'SC' WHEN 'ESP' THEN 'ES'
    WHEN 'SWE' THEN 'SE' WHEN 'SUI' THEN 'CH' WHEN 'TUR' THEN 'TR'
  END
)
ON CONFLICT (team_code) DO NOTHING;

-- -----------------------------------------------------------------------------
-- TABLA AUXILIAR: grupos del Mundial 2026
-- (no forma parte del esquema base, se usa solo para el seed y el config)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wc2026_groups (
    wc_group   CHAR(1)      NOT NULL,
    team_code  VARCHAR(10)  NOT NULL REFERENCES teams(team_code),
    seed       SMALLINT,
    PRIMARY KEY (team_code)
);

INSERT INTO wc2026_groups (wc_group, team_code, seed) VALUES
-- Grupo A
('A','MEX',1),('A','KOR',2),('A','RSA',3),('A','CZE',4),
-- Grupo B
('B','CAN',1),('B','SUI',2),('B','QAT',3),('B','BIH',4),
-- Grupo C
('C','USA',1),('C','PAR',2),('C','AUS',3),('C','TUR',4),
-- Grupo D
('D','ARG',1),('D','ECU',2),('D','ALG',3),('D','COL',4),
-- Grupo E (draw final pendiente — ajustar)
('E','BRA',1),('E','MAR',2),('E','CRO',3),('E','SEN',4),
-- Grupo F
('F','FRA',1),('F','NOR',2),('F','CIV',3),('F','NZL',4),
-- Grupo G
('G','ENG',1),('G','SWE',2),('G','EGY',3),('G','UZB',4),
-- Grupo H
('H','ESP',1),('H','IRN',2),('H','URU',3),('H','SCO',4),
-- Grupo I
('I','GER',1),('I','NED',2),('I','CPV',3),('I','GHA',4),
-- Grupo J
('J','POR',1),('J','JOR',2),('J','PAN',3),('J','CUR',4),
-- Grupo K
('K','BEL',1),('K','KSA',2),('K','JPN',3),('K','TUN',4),
-- Grupo L
('L','HAI',1),('L','COL',2),('L','IRQ',3),('L','COD',4)
ON CONFLICT (team_code) DO NOTHING;

-- Vincular equipos a la temporada WC2026 en team_players (sin jugadores aún)
-- Se hace desde el script de carga de jugadores (03_load_players.py)

-- Verificación rápida
SELECT wc_group, string_agg(team_code,' · ' ORDER BY seed) AS teams
FROM   wc2026_groups
GROUP  BY wc_group
ORDER  BY wc_group;
;
