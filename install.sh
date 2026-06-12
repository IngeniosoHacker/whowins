#!/usr/bin/env bash
# =============================================================================
# install.sh — Instala whowins en el sistema
# Uso: sudo bash install.sh   (o sin sudo si tienes permisos en /usr/local/bin)
# =============================================================================

set -euo pipefail

BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${WHOWINS_HOME:-$HOME/.whowins}"
BIN_LINK="${WHOWINS_BIN:-/usr/local/bin/whowins}"

echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════╗"
echo "  ║   Instalando whowins...          ║"
echo "  ╚══════════════════════════════════╝"
echo -e "${RESET}"

# ── 1. Verificar R ────────────────────────────────────────────────────────────
echo -e "${BOLD}[1/4] Verificando R...${RESET}"
if ! command -v Rscript &>/dev/null; then
  echo -e "${RED}  R no está instalado.${RESET}"
  echo "  Ubuntu/Debian: sudo apt-get install r-base"
  echo "  macOS:         brew install r"
  echo "  Windows:       https://cran.r-project.org/"
  exit 1
fi
echo -e "${GREEN}  ✔ R $(Rscript --version 2>&1 | head -1 | awk '{print $NF}') encontrado.${RESET}"

# ── 2. Instalar paquetes R ────────────────────────────────────────────────────
echo -e "${BOLD}[2/4] Instalando paquetes R...${RESET}"
Rscript -e "
pkgs <- c('dplyr','tidyr','readr','jsonlite','ggplot2','car','MASS','glmnet','lmtest','pROC')
missing <- pkgs[!pkgs %in% installed.packages()[,1]]
if (length(missing) == 0) {
  cat('  Todos los paquetes ya están instalados.\n')
} else {
  cat('  Instalando:', paste(missing, collapse=', '), '\n')
  install.packages(missing,
    repos = c(CRAN='https://cloud.r-project.org/'),
    quiet = TRUE,
    dependencies = TRUE)
  still_miss <- missing[!missing %in% installed.packages()[,1]]
  if (length(still_miss) > 0)
    cat('  ADVERTENCIA: No se pudo instalar:', paste(still_miss, collapse=', '), '\n')
  else
    cat('  OK: todos instalados.\n')
}
" 2>&1 | grep -v "^Warning\|^In \|^There \|^See \|^A version"

echo -e "${GREEN}  ✔ Paquetes R listos.${RESET}"

# ── 3. Copiar archivos ────────────────────────────────────────────────────────
echo -e "${BOLD}[3/4] Copiando archivos a $INSTALL_DIR ...${RESET}"
mkdir -p "$INSTALL_DIR"/{R,config,data,output}

cp -r "$SCRIPT_DIR/R/"         "$INSTALL_DIR/R/"
cp -r "$SCRIPT_DIR/config/"    "$INSTALL_DIR/config/"

# Copiar datos de ejemplo solo si no existen
for f in players.csv matches.csv; do
  if [[ ! -f "$INSTALL_DIR/data/$f" ]]; then
    cp "$SCRIPT_DIR/data/$f" "$INSTALL_DIR/data/$f"
    echo "  + data/$f (datos de ejemplo)"
  else
    echo "  ~ data/$f (existente, no sobreescrito)"
  fi
done

# Crear wrapper que apunte al directorio de instalación
cat > "$INSTALL_DIR/whowins" <<'WRAPPER'
#!/usr/bin/env bash
WHOWINS_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$WHOWINS_HOME/../whowins_runner.sh" "$@"
WRAPPER

# Runner principal que se llama desde cualquier directorio
cat > "$INSTALL_DIR/../whowins_runner.sh" <<RUNNER
#!/usr/bin/env bash
WHOWINS_HOME="$INSTALL_DIR"
cd "\$WHOWINS_HOME"
exec bash whowins "\$@"
RUNNER

cp "$SCRIPT_DIR/whowins" "$INSTALL_DIR/whowins"
chmod +x "$INSTALL_DIR/whowins"

echo -e "${GREEN}  ✔ Archivos copiados.${RESET}"

# ── 4. Crear symlink en PATH ───────────────────────────────────────────────────
echo -e "${BOLD}[4/4] Creando comando 'whowins' en $BIN_LINK ...${RESET}"

LAUNCHER="$INSTALL_DIR/launcher.sh"
cat > "$LAUNCHER" <<LAUNCHER_EOF
#!/usr/bin/env bash
cd "$INSTALL_DIR"
exec bash whowins "\$@"
LAUNCHER_EOF
chmod +x "$LAUNCHER"

# Intentar symlink global, sino solo en ~/bin
if ln -sf "$LAUNCHER" "$BIN_LINK" 2>/dev/null; then
  echo -e "${GREEN}  ✔ Instalado en $BIN_LINK${RESET}"
else
  # Fallback: ~/bin
  mkdir -p "$HOME/bin"
  ln -sf "$LAUNCHER" "$HOME/bin/whowins"
  echo -e "${YELLOW}  ✔ Instalado en ~/bin/whowins${RESET}"
  echo -e "  Asegúrate de tener ~/bin en tu PATH:"
  echo -e "  ${BOLD}export PATH=\"\$HOME/bin:\$PATH\"${RESET}"
fi

echo ""
echo -e "${BOLD}${GREEN}  ══════════════════════════════════════${RESET}"
echo -e "${BOLD}${GREEN}  ✔ whowins instalado correctamente!${RESET}"
echo -e "${BOLD}${GREEN}  ══════════════════════════════════════${RESET}"
echo ""
echo -e "  Uso básico:"
echo -e "  ${BOLD}whowins TeamA TeamB${RESET}"
echo -e "  ${BOLD}whowins TeamA TeamB --home TeamA --weather rain${RESET}"
echo ""
echo -e "  Equipos de ejemplo disponibles:"
echo -e "  ${YELLOW}TeamA, TeamB, TeamC${RESET}"
echo ""
echo -e "  Para agregar tus equipos, edita:"
echo -e "  ${BOLD}$INSTALL_DIR/config/teams.json${RESET}"
echo ""
