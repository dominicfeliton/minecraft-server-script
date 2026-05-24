#!/usr/bin/env bash

#
# Subcommands:
#   start    : Start the server (updates/backups/cleanups, etc.)
#   stop     : Stop via tmux (if running) and kill the session
#   restart  : Stop then start
#   toggle   : If running, stop. Otherwise start.
#
# Environment variable:
#   PROJECT_NAME : "paper" (default), "velocity", "folia", or "spigot"
#
# Key features:
#  - Paper/Velocity/Folia: fetch builds from PaperMC's Fill API.
#  - Spigot: downloads BuildTools and compiles the requested MC version.
#  - Backup & clean the old world folders when version changes (Paper/Folia/Spigot).
#  - **Auto-agree to the EULA** (no manual editing).
#  - (Optional) Aikar flags, memory, tmux usage, WSL detection, etc.
#
# Adjust paths and environment details as needed!
#

########################################
#            CONFIGURATION             #
########################################

# These are defaults - they can be overridden by:
# 1. Environment variables (highest priority)
# 2. Config file (server.conf, .serverrc, etc.)
# 3. These defaults (lowest priority)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Will be set by config or environment, with fallback defaults
SERVER_DIR="${SERVER_DIR:-}"
PROJECT_NAME="${PROJECT_NAME:-}"
DEFAULT_WORLD_NAME="${DEFAULT_WORLD_NAME:-}"
DEFAULT_XMS="${DEFAULT_XMS:-}"
DEFAULT_XMX="${DEFAULT_XMX:-}"
JAVA_CMD="${JAVA_CMD:-}"
PAPERMC_API_BASE="${PAPERMC_API_BASE:-}"
PAPERMC_USER_AGENT="${PAPERMC_USER_AGENT:-}"
SPIGOT_BUILD_DIR="${SPIGOT_BUILD_DIR:-}"
TMUX_SESSION_NAME="${TMUX_SESSION_NAME:-}"
AUTO_AGREE_EULA="${AUTO_AGREE_EULA:-}"
CHECK_TAILSCALE_BIND="${CHECK_TAILSCALE_BIND:-}"

########################################
#          CONFIG FILE LOADING         #
########################################

load_config() {
  # Determine where to look for config
  # If SERVER_DIR is set, look there first
  local search_dir="${SERVER_DIR:-$SCRIPT_DIR}"

  local config_files=(
    "${search_dir}/server.conf"
    "${search_dir}/.serverrc"
    "${HOME}/.minecraft-server.conf"
    "/etc/minecraft-server.conf"
  )

  local config_loaded=false

  for config_file in "${config_files[@]}"; do
    if [[ -f "$config_file" ]]; then
      echo "Loading config from: $config_file"

      while IFS='=' read -r key value || [[ -n "$key" ]]; do
        # Skip comments and empty lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue

        # Remove leading/trailing whitespace
        key="$(echo "$key" | xargs)"
        value="$(echo "$value" | xargs)"

        # Remove quotes from value if present
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"

        # Only set if variable is currently empty
        # This allows environment variables to take priority
        case "$key" in
          SERVER_DIR|PROJECT_NAME|DEFAULT_WORLD_NAME|DEFAULT_XMS|DEFAULT_XMX|\
          JAVA_CMD|PAPERMC_API_BASE|PAPERMC_USER_AGENT|\
          SPIGOT_BUILD_DIR|TMUX_SESSION_NAME|AUTO_AGREE_EULA|CHECK_TAILSCALE_BIND)
            if [[ -z "${!key}" ]]; then
              printf -v "$key" '%s' "$value"
            fi
            ;;
        esac
      done < "$config_file"

      config_loaded=true
      break  # Only load first config found
    fi
  done

  if [[ "$config_loaded" == "false" ]]; then
    echo "No config file found, using defaults/environment variables."
  fi
}

# Load config
load_config

# Apply defaults for anything still unset
: "${SERVER_DIR:=$SCRIPT_DIR}"
: "${PROJECT_NAME:=paper}"
: "${DEFAULT_WORLD_NAME:=world}"
: "${DEFAULT_XMS:=2G}"
: "${DEFAULT_XMX:=2G}"
: "${JAVA_CMD:=java}"
: "${PAPERMC_API_BASE:=https://fill.papermc.io/v3}"
: "${PAPERMC_USER_AGENT:=minecraft-server-script/1.0 (https://github.com/dominicfeliton/minecraft-server-script)}"
: "${AUTO_AGREE_EULA:=true}"
: "${CHECK_TAILSCALE_BIND:=true}"

# Derived variables (depend on SERVER_DIR)
TMUX_SESSION_NAME="${TMUX_SESSION_NAME:-$(basename "$SERVER_DIR")}"
CURRENT_VERSION_FILE="${SERVER_DIR}/current_version.txt"
SPIGOT_BUILD_DIR="${SPIGOT_BUILD_DIR:-${SERVER_DIR}/buildtools}"
BUILD_TOOLS_JAR="${SPIGOT_BUILD_DIR}/BuildTools.jar"
SPIGOT_BUILT_JAR="${SERVER_DIR}/spigot-server.jar"
BUILD_TOOLS_JAR_URL="https://hub.spigotmc.org/jenkins/job/BuildTools/lastSuccessfulBuild/artifact/target/BuildTools.jar"

########################################
#             USAGE & HELP             #
########################################

usage() {
    cat << EOF
Usage:
  $(basename "$0") [subcommand] [arguments...]

Subcommands:
  start    [mc_version] [build_number] [--no-update] [--ignore-channel-switch] [--quick-upgrade|--full-upgrade] [--xms=###] [--xmx=###] [--java-cmd=...] [--no-tmux]
  stop
  restart  [mc_version] [build_number] ...
  toggle

If no subcommand is provided, or the first argument is an option, 'toggle' is used.

Environment variable:
  PROJECT_NAME=paper (default), velocity, folia, or spigot
EOF
}

########################################
#       DEPENDENCY & ENV CHECKS        #
########################################

# For Paper/Velocity/Folia/Spigot => we need curl; PaperMC projects also need jq
if [[ "$PROJECT_NAME" == "paper" || "$PROJECT_NAME" == "velocity" || "$PROJECT_NAME" == "folia" || "$PROJECT_NAME" == "spigot" ]]; then
  if ! command -v curl &>/dev/null; then
    echo "Error: 'curl' is required. Install it with your package manager first."
    exit 1
  fi
  if [[ "$PROJECT_NAME" != "spigot" ]]; then
    # Spigot doesn't absolutely require jq for build, but PaperMC projects do.
    if ! command -v jq &>/dev/null; then
      echo "Error: 'jq' is required for Paper/Velocity/Folia. Install it with your package manager first."
      exit 1
    fi
  fi
fi

if [[ ! -d "${SERVER_DIR}" ]]; then
  echo "Error: SERVER_DIR '${SERVER_DIR}' does not exist. Creating..."
  mkdir -p "${SERVER_DIR}"
  #exit 1
fi

########################################
#            GENERAL HELPERS           #
########################################

function trim_value() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

function read_server_property() {
  local key="$1"
  local properties_file="${SERVER_DIR}/server.properties"
  local line

  [[ -f "$properties_file" ]] || return 1
  line="$(grep -m1 -E "^[[:space:]]*${key}[[:space:]]*=" "$properties_file" 2>/dev/null)" || return 1
  trim_value "${line#*=}"
}

function read_velocity_bind_port() {
  local velocity_file="${SERVER_DIR}/velocity.toml"
  local line
  local bind_address
  local port

  [[ -f "$velocity_file" ]] || return 1
  line="$(grep -m1 -E "^[[:space:]]*bind[[:space:]]*=" "$velocity_file" 2>/dev/null)" || return 1
  bind_address="$(trim_value "${line#*=}")"

  if [[ "$bind_address" =~ ^\"([^\"]+)\" ]]; then
    bind_address="${BASH_REMATCH[1]}"
  elif [[ "$bind_address" =~ ^\'([^\']+)\' ]]; then
    bind_address="${BASH_REMATCH[1]}"
  else
    bind_address="${bind_address%%#*}"
    bind_address="$(trim_value "$bind_address")"
  fi

  port="${bind_address##*:}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$port"
}

function resolve_connection_port() {
  local server_port

  if [[ "$PROJECT_NAME" == "velocity" ]]; then
    server_port="$(read_velocity_bind_port || true)"
  else
    server_port="$(read_server_property "server-port" || true)"
  fi

  server_port="$(trim_value "$server_port")"
  [[ -n "$server_port" ]] || server_port="25565"
  printf '%s\n' "$server_port"
}

function is_tailscale_ipv4() {
  local ip="$1"
  local a
  local b
  local c
  local d

  IFS='.' read -r a b c d <<< "$ip"
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
  (( 10#$a == 100 && 10#$b >= 64 && 10#$b <= 127 && 10#$c >= 0 && 10#$c <= 255 && 10#$d >= 0 && 10#$d <= 255 ))
}

function tailscale_bind_preflight() {
  local server_ip
  local server_port
  local tailscale_ips
  local displayed_tailscale_ips

  [[ "$CHECK_TAILSCALE_BIND" == "true" ]] || return 0

  server_ip="$(read_server_property "server-ip" || true)"
  server_ip="$(trim_value "$server_ip")"
  [[ -n "$server_ip" ]] || return 0
  is_tailscale_ipv4 "$server_ip" || return 0

  server_port="$(resolve_connection_port)"

  if ! command -v tailscale &>/dev/null; then
    echo "Error: server.properties binds to Tailscale IP ${server_ip}:${server_port}, but the tailscale command was not found." >&2
    echo "Fix: install Tailscale, clear server-ip= in server.properties, or set server-ip to an address assigned to this host." >&2
    exit 1
  fi

  tailscale_ips="$(tailscale ip -4 2>&1 || true)"
  displayed_tailscale_ips="$(trim_value "$tailscale_ips")"
  [[ -n "$displayed_tailscale_ips" ]] || displayed_tailscale_ips="(none)"

  if ! grep -Fxq "$server_ip" <<< "$tailscale_ips"; then
    echo "Error: server.properties binds to Tailscale IP ${server_ip}:${server_port}, but this host does not currently have that Tailscale IPv4." >&2
    echo "tailscale ip -4 returned:" >&2
    echo "$displayed_tailscale_ips" >&2
    echo >&2
    echo "Suggested fixes:" >&2
    echo "  sudo tailscale up" >&2
    echo "  sed -i 's/^server-ip=.*/server-ip=/' ${SERVER_DIR}/server.properties" >&2
    echo "  or update server-ip to the current value from: tailscale ip -4" >&2
    exit 1
  fi

  echo "Tailscale bind OK: ${server_ip}:${server_port}"
}

########################################
#           SUBCOMMAND LOGIC           #
########################################

SUBCOMMAND="${1:-toggle}"

case "$SUBCOMMAND" in
  start|stop|restart|toggle)
    [[ $# -gt 0 ]] && shift
    ;;
  help|--help|-h)
    usage
    exit 0
    ;;
  -*)
    SUBCOMMAND="toggle"
    ;;
  *)
    usage
    exit 1
    ;;
esac

########################################
#             TMUX CHECKS              #
########################################

USE_TMUX=true
if ! command -v tmux &>/dev/null; then
  echo "Warning: tmux not installed. Disabling tmux usage."
  USE_TMUX=false
fi

########################################
#             PARSE ARGS               #
########################################

AUTO_UPDATE=true
MINECRAFT_VERSION=""
BUILD_NUMBER=""
USER_SUPPLIED_MINECRAFT_VERSION=false
AUTO_DETECTED_PAPERMC_UPGRADE=false
DOWNLOAD_PERFORMED=false
PAPERMC_SELECTED_CHANNEL=""
PAPERMC_DECLINED_STABLE_TARGET=""
PAPERMC_DECLINED_BETA_TARGET=""
PAPERMC_DECLINED_ALPHA_TARGET=""
PAPERMC_PROMPT_RESULT=""
IGNORE_CHANNEL_SWITCH=false
UPGRADE_MODE="ask"
XMS="${DEFAULT_XMS}"
XMX="${DEFAULT_XMX}"

args=("$@")
i=0
while [[ $i -lt $# ]]; do
  case "${args[$i]}" in
    --no-update)
      AUTO_UPDATE=false
      ;;
    --ignore-channel-switch)
      IGNORE_CHANNEL_SWITCH=true
      ;;
    --quick-upgrade)
      UPGRADE_MODE="quick"
      ;;
    --full-upgrade)
      UPGRADE_MODE="full"
      ;;
    --xms=*)
      XMS="${args[$i]#*=}"
      ;;
    --xmx=*)
      XMX="${args[$i]#*=}"
      ;;
    --java-cmd=*)
      JAVA_CMD="${args[$i]#*=}"
      ;;
    --no-tmux)
      USE_TMUX=false
      ;;
    -*)
      echo "Warning: Unrecognized option '${args[$i]}'"
      ;;
    *)
      if [[ -z "${args[$i]}" ]]; then
        :
      elif [[ -z "$MINECRAFT_VERSION" ]]; then
        MINECRAFT_VERSION="${args[$i]}"
        USER_SUPPLIED_MINECRAFT_VERSION=true
      elif [[ -z "$BUILD_NUMBER" ]]; then
        BUILD_NUMBER="${args[$i]}"
      fi
      ;;
  esac
  ((i++))
done

########################################
#           TOGGLE SUBCOMMAND          #
########################################

if [[ "$SUBCOMMAND" == "toggle" ]]; then
  if [[ "$USE_TMUX" == "false" ]]; then
    echo "[toggle] tmux disabled. Will 'start'."
    SUBCOMMAND="start"
  else
    if tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
      echo "[toggle] Session '$TMUX_SESSION_NAME' found. Stopping..."
      SUBCOMMAND="stop"
    else
      echo "[toggle] Session '$TMUX_SESSION_NAME' not found. Starting..."
      SUBCOMMAND="start"
    fi
  fi
fi

########################################
#             STOP SUBCOMMAND          #
########################################

if [[ "$SUBCOMMAND" == "stop" ]]; then
  echo "Stopping server (session: $TMUX_SESSION_NAME)..."
  if tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
    tmux send-keys -t "$TMUX_SESSION_NAME" "stop" C-m
    sleep 2
    tmux kill-session -t "$TMUX_SESSION_NAME"
    echo "Server stopped."
  else
    echo "No tmux session named '$TMUX_SESSION_NAME'. Probably not running."
  fi
  exit 0
fi

########################################
#            RESTART SUBCOMMAND        #
########################################

if [[ "$SUBCOMMAND" == "restart" ]]; then
  "$0" stop
  echo "Restarting server..."
  exec "$0" start "$MINECRAFT_VERSION" "$BUILD_NUMBER" \
       $( [[ "$AUTO_UPDATE" == "false" ]] && echo "--no-update" ) \
       --xms="$XMS" --xmx="$XMX" --java-cmd="$JAVA_CMD" \
       $( $USE_TMUX || echo "--no-tmux" )
fi

########################################
#        START SUBCOMMAND LOGIC        #
########################################

tailscale_bind_preflight

########################################
#            DETECT JAVA VER           #
########################################

function detect_java_version() {
  local verOutput
  verOutput=$("$JAVA_CMD" -version 2>&1 | head -n 1)
  local rawVersion
  rawVersion=$(echo "$verOutput" | sed -n 's/.*"\([0-9][^"]*\)".*/\1/p')

  local major
  if [[ "$rawVersion" =~ ^1\.([0-9]+).* ]]; then
    major="${BASH_REMATCH[1]}"  # e.g. 8
  else
    major="${rawVersion%%.*}"   # e.g. 11, 17, 22, etc.
  fi
  echo "$major"
}

JAVA_MAJOR_VERSION="$(detect_java_version)"
if [[ -n "$JAVA_MAJOR_VERSION" ]]; then
  echo "Detected Java major version: $JAVA_MAJOR_VERSION"
  if [[ "$PROJECT_NAME" == "folia" && "$JAVA_MAJOR_VERSION" -lt 17 ]]; then
    echo "Error: Folia requires Java 17+. Found $JAVA_MAJOR_VERSION."
    exit 1
  fi
fi

########################################
#    FLAGS FOR PAPER / FOLIA / VELO    #
########################################

AIKAR_FLAGS=(
  "-XX:+UseG1GC"
  "-XX:+ParallelRefProcEnabled"
  "-XX:MaxGCPauseMillis=200"
  "-XX:+UnlockExperimentalVMOptions"
  "-XX:+DisableExplicitGC"
  "-XX:+AlwaysPreTouch"
  "-XX:G1NewSizePercent=30"
  "-XX:G1MaxNewSizePercent=40"
  "-XX:G1HeapRegionSize=8M"
  "-XX:G1ReservePercent=20"
  "-XX:G1HeapWastePercent=5"
  "-XX:G1MixedGCCountTarget=4"
  "-XX:InitiatingHeapOccupancyPercent=15"
  "-XX:G1MixedGCLiveThresholdPercent=90"
  "-XX:G1RSetUpdatingPauseTimePercent=5"
  "-XX:SurvivorRatio=32"
  "-XX:+PerfDisableSharedMem"
  "-XX:MaxTenuringThreshold=1"
  "-Dusing.aikars.flags=https://mcflags.emc.gs"
  "-Daikars.new.flags=true"
)

GC_LOGGING_FLAGS=()
if [[ "$JAVA_MAJOR_VERSION" =~ ^[0-9]+$ ]]; then
  if (( JAVA_MAJOR_VERSION < 11 )); then
    GC_LOGGING_FLAGS=(
      "-Xloggc:gc.log"
      "-verbose:gc"
      "-XX:+PrintGCDetails"
      "-XX:+PrintGCDateStamps"
      "-XX:+PrintGCTimeStamps"
      "-XX:+UseGCLogFileRotation"
      "-XX:NumberOfGCLogFiles=5"
      "-XX:GCLogFileSize=1M"
    )
  else
    GC_LOGGING_FLAGS=(
      "-Xlog:gc*:logs/gc.log:time,uptime:filecount=5,filesize=1M"
    )
  fi
fi

VELOCITY_FLAGS_BASE=(
  "-XX:+AlwaysPreTouch"
  "-XX:+ParallelRefProcEnabled"
  "-XX:+UnlockExperimentalVMOptions"
  "-XX:+UseG1GC"
  "-XX:G1HeapRegionSize=4M"
  "-XX:MaxInlineLevel=15"
)

########################################
#      DETECT WSL ENVIRONMENT          #
########################################

function is_wsl() {
  # A simple check: if /proc/version contains "Microsoft" or "WSL"
  grep -qiE "(Microsoft|WSL)" /proc/version 2>/dev/null
}

########################################
#        SPIGOT BUILD (BuildTools)     #
########################################

function build_spigot_if_needed() {
  # We rely on 'git' and 'mvn' (Maven) typically.
  if ! command -v git &>/dev/null; then
    echo "Error: 'git' is required to build Spigot with BuildTools."
    exit 1
  fi
  if ! command -v mvn &>/dev/null; then
    echo "Warning: 'mvn' not found. BuildTools may download Maven itself."
  fi

  mkdir -p "$SPIGOT_BUILD_DIR"

  # Download BuildTools.jar if not present or if AUTO_UPDATE is ON
  if [[ ! -f "$BUILD_TOOLS_JAR" ]]; then
    echo "[Spigot] Downloading BuildTools.jar to ${BUILD_TOOLS_JAR}"
    curl -sSL "$BUILD_TOOLS_JAR_URL" -o "$BUILD_TOOLS_JAR"
  else
    if [[ "$AUTO_UPDATE" == "true" ]]; then
      echo "[Spigot] Auto-update => re-download BuildTools.jar"
      curl -sSL "$BUILD_TOOLS_JAR_URL" -o "$BUILD_TOOLS_JAR"
    else
      echo "[Spigot] BuildTools.jar already exists; no re-download (auto-update=OFF)."
    fi
  fi

  # If MINECRAFT_VERSION is empty => detect or use stable?
  if [[ -z "$MINECRAFT_VERSION" ]]; then
    if [[ -f "$CURRENT_VERSION_FILE" ]]; then
      MINECRAFT_VERSION="$(read_current_version_value)"
      echo "[Spigot] No version specified => using $MINECRAFT_VERSION from current_version.txt"
    else
      echo "[Spigot] No version specified + no current_version.txt => using 1.20.1"
      MINECRAFT_VERSION="1.20.1"
    fi
  fi

  # If spigot-server.jar for that version is present & auto-update=OFF => skip
  if [[ -f "$SPIGOT_BUILT_JAR" && "$AUTO_UPDATE" == "false" ]]; then
    echo "[Spigot] spigot-server.jar present, auto-update=OFF => using existing jar."
    return 0
  fi

  echo "=== Building Spigot (version ${MINECRAFT_VERSION}) via BuildTools ==="
  pushd "$SPIGOT_BUILD_DIR" >/dev/null || exit 1
  # Cleanup leftover stuff if needed
  rm -rf Spigot/ CraftBukkit/ work/ apache-maven-*/ Bukkit/

  # Actually run build
  "${JAVA_CMD}" -jar "${BUILD_TOOLS_JAR}" --rev "${MINECRAFT_VERSION}"

  if [[ $? -ne 0 ]]; then
    echo "Error: BuildTools failed!"
    exit 1
  fi

  local BUILT_SPIGOT_JAR
  BUILT_SPIGOT_JAR="${SPIGOT_BUILD_DIR}/spigot-${MINECRAFT_VERSION}.jar"
  if [[ -z "$BUILT_SPIGOT_JAR" || ! -f "$BUILT_SPIGOT_JAR" ]]; then
    echo "Error: No spigot-*.jar found in ${SPIGOT_BUILD_DIR}."
    exit 1
  fi

  # Move to server folder as spigot-server.jar
  cp "$BUILT_SPIGOT_JAR" "$SPIGOT_BUILT_JAR"
  popd >/dev/null || exit 1

  echo "=== Done. Built Spigot => $SPIGOT_BUILT_JAR ==="
}

########################################
#      BACKUP & CLEAN (Paper/Folia/Spigot)
########################################

backup_and_clean() {
  local old_version="$1"
  local new_version="$2"

  echo "Version changed from '${old_version}' to '${new_version}'."
  echo "Backup + clean..."

  local timestamp
  timestamp="$(date +%Y%m%d-%H%M%S)"
  local randstr=$(( RANDOM % 10000 ))
  local backup_dir="${SERVER_DIR}/${DEFAULT_WORLD_NAME}-${old_version}-${timestamp}-${randstr}"

  mkdir -p "$backup_dir"

  for wfolder in "${DEFAULT_WORLD_NAME}" "${DEFAULT_WORLD_NAME}_nether" "${DEFAULT_WORLD_NAME}_the_end"; do
    if [[ -d "${SERVER_DIR}/${wfolder}" ]]; then
      echo "Backing up '${wfolder}' => '${backup_dir}'"
      mv "${SERVER_DIR}/${wfolder}" "$backup_dir/" 2>/dev/null
    fi
  done

  echo "Wiping server dir except critical files..."
  shopt -s dotglob
  for item in "${SERVER_DIR}"/*; do
    if [[ "$(basename "$item")" == "$(basename "$backup_dir")" ]]; then
      continue
    fi
    case "$(basename "$item")" in
      world-*|plugins|server.properties|eula.txt|$(basename "$0")|$(basename "${CURRENT_VERSION_FILE}"))
        continue
        ;;
    esac
    echo "Remove '$item'? [y/N]"
    read -r confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
      rm -rf "${item}"
    fi
  done
  shopt -u dotglob
}

choose_upgrade_mode() {
  local old_version="$1"
  local new_version="$2"
  local confirm

  case "$UPGRADE_MODE" in
    quick)
      echo "Version changed from '${old_version}' to '${new_version}'."
      echo "Quick upgrade selected => jar-only update; skipping backup/clean."
      echo "Back up worlds first if this is not a disposable or already-backed-up server."
      return 0
      ;;
    full)
      backup_and_clean "$old_version" "$new_version"
      return 0
      ;;
    ask)
      ;;
    *)
      die "Invalid UPGRADE_MODE '${UPGRADE_MODE}'. Use ask, quick, or full."
      ;;
  esac

  if [[ ! -t 0 ]]; then
    echo "Version changed from '${old_version}' to '${new_version}'."
    echo "Non-interactive shell detected => defaulting to quick jar-only upgrade."
    echo "Use --full-upgrade to run the full backup/clean path."
    return 0
  fi

  echo "----------------------------------------"
  echo "Version changed from '${old_version}' to '${new_version}'."
  echo "Choose upgrade mode:"
  echo "  [q] Quick jar-only upgrade (default): do not move worlds or clean server files."
  echo "  [f] Full backup + clean: move world folders into a timestamped backup dir, then prompt to remove old server files."
  echo "  [c] Cancel."
  echo "Upgrade mode [q/f/c, default q]:"
  read -r confirm

  case "$confirm" in
    f|F|full|FULL)
      backup_and_clean "$old_version" "$new_version"
      ;;
    c|C|cancel|CANCEL)
      die "Upgrade cancelled."
      ;;
    *)
      echo "Quick upgrade selected => jar-only update; skipping backup/clean."
      echo "Back up worlds first if this is not a disposable or already-backed-up server."
      ;;
  esac
}

maybe_backup_and_clean() {
  # Paper, Folia, or Spigot do backups on version change
  if [[ "$PROJECT_NAME" == "paper" || "$PROJECT_NAME" == "folia" || "$PROJECT_NAME" == "spigot" ]]; then
    if [[ -f "$CURRENT_VERSION_FILE" ]]; then
      local last_ver
      last_ver="$(read_current_version_value)"
      if [[ "$last_ver" != "$MINECRAFT_VERSION" && -n "$MINECRAFT_VERSION" ]]; then
        if [[ "$AUTO_DETECTED_PAPERMC_UPGRADE" == "true" ]]; then
          echo "Auto-detected PaperMC upgrade accepted."
        fi
        choose_upgrade_mode "$last_ver" "$MINECRAFT_VERSION"
      else
        echo "No version change or version not specified => no backup/clean."
      fi
    else
      echo "No ${CURRENT_VERSION_FILE}; skipping backup/clean."
    fi
  else
    echo "Skipping backup/clean (PROJECT_NAME=$PROJECT_NAME)."
  fi
}

########################################
#   PAPERMC DOWNLOAD RESOLUTION        #
########################################

function die() {
  echo "Error: $*" >&2
  exit 1
}

function is_papermc_project() {
  [[ "$PROJECT_NAME" == "paper" || "$PROJECT_NAME" == "velocity" || "$PROJECT_NAME" == "folia" ]]
}

function valid_api_value() {
  [[ -n "$1" && "$1" != "null" ]]
}

function read_current_version_value() {
  local line

  [[ -f "$CURRENT_VERSION_FILE" ]] || return 1

  if grep -q '^VERSION=' "$CURRENT_VERSION_FILE"; then
    line="$(grep -m1 '^VERSION=' "$CURRENT_VERSION_FILE")"
    trim_value "${line#VERSION=}"
    return 0
  fi

  IFS= read -r line < "$CURRENT_VERSION_FILE" || return 1
  trim_value "$line"
}

function read_papermc_state() {
  PAPERMC_STATE_VERSION=""
  PAPERMC_STATE_BUILD=""
  PAPERMC_STATE_CHANNEL=""
  PAPERMC_STATE_DECLINED_STABLE_TARGET=""
  PAPERMC_STATE_DECLINED_BETA_TARGET=""
  PAPERMC_STATE_DECLINED_ALPHA_TARGET=""
  PAPERMC_STATE_FORMAT=""

  [[ -f "$CURRENT_VERSION_FILE" ]] || return 1

  if grep -q '^VERSION=' "$CURRENT_VERSION_FILE"; then
    local key
    local value
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
      key="$(trim_value "$key")"
      value="$(trim_value "$value")"
      case "$key" in
        VERSION)
          PAPERMC_STATE_VERSION="$value"
          ;;
        BUILD)
          PAPERMC_STATE_BUILD="$value"
          ;;
        CHANNEL)
          PAPERMC_STATE_CHANNEL="$value"
          ;;
        DECLINED_STABLE_TARGET)
          PAPERMC_STATE_DECLINED_STABLE_TARGET="$value"
          ;;
        DECLINED_BETA_TARGET)
          PAPERMC_STATE_DECLINED_BETA_TARGET="$value"
          ;;
        DECLINED_ALPHA_TARGET)
          PAPERMC_STATE_DECLINED_ALPHA_TARGET="$value"
          ;;
      esac
    done < "$CURRENT_VERSION_FILE"
    PAPERMC_STATE_FORMAT="key-value"
  else
    IFS= read -r PAPERMC_STATE_VERSION < "$CURRENT_VERSION_FILE" || return 1
    PAPERMC_STATE_VERSION="$(trim_value "$PAPERMC_STATE_VERSION")"
    PAPERMC_STATE_FORMAT="legacy"
  fi

  valid_api_value "$PAPERMC_STATE_VERSION"
}

function write_papermc_state() {
  valid_api_value "$MINECRAFT_VERSION" || die "Cannot write PaperMC state without a version."
  valid_api_value "$BUILD_NUMBER" || die "Cannot write PaperMC state without a build number."
  valid_api_value "$PAPERMC_SELECTED_CHANNEL" || die "Cannot write PaperMC state without a channel."

  {
    printf 'VERSION=%s\n' "$MINECRAFT_VERSION"
    printf 'BUILD=%s\n' "$BUILD_NUMBER"
    printf 'CHANNEL=%s\n' "$PAPERMC_SELECTED_CHANNEL"
    printf 'DECLINED_STABLE_TARGET=%s\n' "$PAPERMC_DECLINED_STABLE_TARGET"
    printf 'DECLINED_BETA_TARGET=%s\n' "$PAPERMC_DECLINED_BETA_TARGET"
    printf 'DECLINED_ALPHA_TARGET=%s\n' "$PAPERMC_DECLINED_ALPHA_TARGET"
  } > "$CURRENT_VERSION_FILE"
}

function papermc_fetch_json() {
  local url="$1"
  local description="$2"
  local response

  if ! response="$(curl -fsSL -H "User-Agent: ${PAPERMC_USER_AGENT}" "$url")"; then
    echo "Error: failed to fetch ${description} from ${url}" >&2
    return 1
  fi

  if ! jq -e . >/dev/null 2>&1 <<< "$response"; then
    echo "Error: invalid JSON while fetching ${description} from ${url}" >&2
    return 1
  fi

  if jq -e '.ok == false' >/dev/null 2>&1 <<< "$response"; then
    local message
    message="$(jq -r '.message // "unknown PaperMC API error"' <<< "$response")"
    echo "Error: PaperMC API rejected ${description}: ${message}" >&2
    return 1
  fi

  printf '%s\n' "$response"
}

function resolve_papermc_build() {
  local project="$1"
  local mc_version="$2"
  local requested_build="$3"
  local channel_filter="${4:-STABLE}"
  local builds_url="${PAPERMC_API_BASE}/projects/${project}/versions/${mc_version}/builds"
  local builds_json
  local build_json

  valid_api_value "$project" || return 1
  valid_api_value "$mc_version" || return 1

  if ! builds_json="$(papermc_fetch_json "$builds_url" "builds for ${project} ${mc_version}")"; then
    return 1
  fi

  if [[ -n "$requested_build" ]]; then
    build_json="$(jq -c --arg build "$requested_build" 'first(.[] | select(((.id // .number) | tostring) == $build)) // empty' <<< "$builds_json")"
  elif [[ "$channel_filter" == "ANY" ]]; then
    build_json="$(jq -c '[.[]] | max_by((.id // .number) | tonumber? // 0) // empty' <<< "$builds_json")"
  else
    build_json="$(jq -c --arg channel "$channel_filter" '[.[] | select(.channel == $channel)] | max_by((.id // .number) | tonumber? // 0) // empty' <<< "$builds_json")"
  fi

  valid_api_value "$build_json" || return 1

  RESOLVED_VERSION="$mc_version"
  RESOLVED_BUILD="$(jq -r '(.id // .number // empty)' <<< "$build_json")"
  RESOLVED_CHANNEL="$(jq -r '(.channel // empty)' <<< "$build_json")"
  RESOLVED_JAR_NAME="$(jq -r '(.downloads."server:default".name // empty)' <<< "$build_json")"
  RESOLVED_DOWNLOAD_URL="$(jq -r '(.downloads."server:default".url // empty)' <<< "$build_json")"

  valid_api_value "$RESOLVED_BUILD" || return 1
  valid_api_value "$RESOLVED_JAR_NAME" || return 1
  valid_api_value "$RESOLVED_DOWNLOAD_URL" || return 1

  return 0
}

function load_papermc_project_versions() {
  local project_url="${PAPERMC_API_BASE}/projects/${PROJECT_NAME}"
  local project_json
  local version

  PAPERMC_PROJECT_VERSIONS=()

  if ! project_json="$(papermc_fetch_json "$project_url" "project info for ${PROJECT_NAME}")"; then
    return 1
  fi

  if ! jq -e '.versions | type == "object"' >/dev/null 2>&1 <<< "$project_json"; then
    echo "Error: PaperMC project response for ${PROJECT_NAME} did not include a versions object." >&2
    return 1
  fi

  while IFS= read -r version; do
    [[ -n "$version" ]] && PAPERMC_PROJECT_VERSIONS+=("$version")
  done < <(jq -r '.versions | to_entries[] | .value[]' <<< "$project_json")

  [[ ${#PAPERMC_PROJECT_VERSIONS[@]} -gt 0 ]]
}

function papermc_version_index() {
  local needle="$1"
  local i=0
  local version

  for version in "${PAPERMC_PROJECT_VERSIONS[@]}"; do
    if [[ "$version" == "$needle" ]]; then
      printf '%s\n' "$i"
      return 0
    fi
    ((i++))
  done

  return 1
}

function papermc_version_is_newer() {
  local candidate="$1"
  local current="$2"
  local candidate_index
  local current_index

  candidate_index="$(papermc_version_index "$candidate")" || return 1
  current_index="$(papermc_version_index "$current")" || return 1
  (( candidate_index < current_index ))
}

function find_latest_papermc_build_by_channel() {
  local channel="$1"
  local version

  for version in "${PAPERMC_PROJECT_VERSIONS[@]}"; do
    if resolve_papermc_build "$PROJECT_NAME" "$version" "" "$channel"; then
      return 0
    fi
  done

  return 1
}

function format_papermc_build_label() {
  local version="$1"
  local build="$2"
  local channel="$3"

  printf '%s build %s (%s)\n' "${version:-unknown}" "${build:-unknown}" "${channel:-unknown}"
}

function papermc_channel_rank() {
  case "$1" in
    ALPHA)
      printf '1\n'
      ;;
    BETA)
      printf '2\n'
      ;;
    STABLE)
      printf '3\n'
      ;;
    *)
      printf '0\n'
      ;;
  esac
}

function papermc_channel_is_better() {
  local candidate_channel="$1"
  local current_channel="$2"
  local candidate_rank
  local current_rank

  candidate_rank="$(papermc_channel_rank "$candidate_channel")"
  current_rank="$(papermc_channel_rank "$current_channel")"
  (( candidate_rank > current_rank ))
}

function prompt_papermc_choice() {
  local reason="$1"
  local current_label="$2"
  local target_label="$3"
  local detail="$4"
  local question="$5"
  local confirm

  PAPERMC_PROMPT_RESULT="unshown"
  [[ -t 0 ]] || return 1

  echo "----------------------------------------"
  echo "$reason"
  echo "Current ${PROJECT_NAME}: ${current_label}"
  echo "Target ${PROJECT_NAME}:  ${target_label}"
  echo
  echo "$detail"
  echo "Before accepting, make sure you have backed up your worlds and followed the proper Minecraft/Paper upgrade path."
  echo "If this changes the saved Minecraft version, you will choose quick jar-only upgrade or full backup/clean before startup."
  echo "$question"
  read -r confirm
  if [[ "$confirm" =~ ^[yY]$ ]]; then
    PAPERMC_PROMPT_RESULT="accepted"
    return 0
  fi

  PAPERMC_PROMPT_RESULT="declined"
  return 1
}

function papermc_target_key() {
  local version="$1"
  local build="$2"
  local channel="$3"

  printf '%s:%s:%s\n' "$version" "$build" "$channel"
}

function papermc_declined_target_matches() {
  local channel="$1"
  local target="$2"

  case "$channel" in
    ALPHA)
      [[ "$PAPERMC_DECLINED_ALPHA_TARGET" == "$target" ]]
      ;;
    BETA)
      [[ "$PAPERMC_DECLINED_BETA_TARGET" == "$target" ]]
      ;;
    STABLE)
      [[ "$PAPERMC_DECLINED_STABLE_TARGET" == "$target" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

function record_papermc_declined_target() {
  local channel="$1"
  local target="$2"

  case "$channel" in
    ALPHA)
      PAPERMC_DECLINED_ALPHA_TARGET="$target"
      ;;
    BETA)
      PAPERMC_DECLINED_BETA_TARGET="$target"
      ;;
    STABLE)
      PAPERMC_DECLINED_STABLE_TARGET="$target"
      ;;
    *)
      return 0
      ;;
  esac
}

function clear_papermc_declined_target() {
  local channel="$1"

  case "$channel" in
    ALPHA)
      PAPERMC_DECLINED_ALPHA_TARGET=""
      ;;
    BETA)
      PAPERMC_DECLINED_BETA_TARGET=""
      ;;
    STABLE)
      PAPERMC_DECLINED_STABLE_TARGET=""
      ;;
  esac
}

function apply_resolved_papermc_build() {
  MINECRAFT_VERSION="$RESOLVED_VERSION"
  BUILD_NUMBER="$RESOLVED_BUILD"
  PAPERMC_SELECTED_CHANNEL="$RESOLVED_CHANNEL"
  JAR_NAME="$RESOLVED_JAR_NAME"
  DOWNLOAD_URL="$RESOLVED_DOWNLOAD_URL"
  FILE="${SERVER_DIR}/${JAR_NAME}"
}

function capture_resolved_current() {
  current_version="$RESOLVED_VERSION"
  current_build="$RESOLVED_BUILD"
  current_channel="$RESOLVED_CHANNEL"
  current_jar_name="$RESOLVED_JAR_NAME"
  current_download_url="$RESOLVED_DOWNLOAD_URL"
}

function capture_resolved_latest_stable() {
  latest_stable_version="$RESOLVED_VERSION"
  latest_stable_build="$RESOLVED_BUILD"
  latest_stable_channel="$RESOLVED_CHANNEL"
  latest_stable_jar_name="$RESOLVED_JAR_NAME"
  latest_stable_download_url="$RESOLVED_DOWNLOAD_URL"
}

function capture_resolved_latest_alpha() {
  latest_alpha_version="$RESOLVED_VERSION"
  latest_alpha_build="$RESOLVED_BUILD"
  latest_alpha_channel="$RESOLVED_CHANNEL"
  latest_alpha_jar_name="$RESOLVED_JAR_NAME"
  latest_alpha_download_url="$RESOLVED_DOWNLOAD_URL"
}

function capture_resolved_latest_beta() {
  latest_beta_version="$RESOLVED_VERSION"
  latest_beta_build="$RESOLVED_BUILD"
  latest_beta_channel="$RESOLVED_CHANNEL"
  latest_beta_jar_name="$RESOLVED_JAR_NAME"
  latest_beta_download_url="$RESOLVED_DOWNLOAD_URL"
}

function set_papermc_target() {
  MINECRAFT_VERSION="$1"
  BUILD_NUMBER="$2"
  PAPERMC_SELECTED_CHANNEL="$3"
  JAR_NAME="$4"
  DOWNLOAD_URL="$5"
  FILE="${SERVER_DIR}/${JAR_NAME}"
}

function infer_saved_papermc_track() {
  local saved_version="$1"
  local saved_build="$2"
  local saved_channel="$3"

  if valid_api_value "$saved_channel"; then
    printf '%s\n' "$saved_channel"
    return 0
  fi

  if valid_api_value "$saved_build" && resolve_papermc_build "$PROJECT_NAME" "$saved_version" "$saved_build"; then
    printf '%s\n' "$RESOLVED_CHANNEL"
    return 0
  fi

  if resolve_papermc_build "$PROJECT_NAME" "$saved_version" "" "STABLE"; then
    printf 'STABLE\n'
    return 0
  fi

  if resolve_papermc_build "$PROJECT_NAME" "$saved_version" "" "BETA"; then
    printf 'BETA\n'
    return 0
  fi

  if resolve_papermc_build "$PROJECT_NAME" "$saved_version" "" "ALPHA"; then
    printf 'ALPHA\n'
    return 0
  fi

  if resolve_papermc_build "$PROJECT_NAME" "$saved_version" "" "ANY"; then
    printf '%s\n' "$RESOLVED_CHANNEL"
    return 0
  fi

  return 1
}

function resolve_saved_papermc_build() {
  local saved_version="$1"
  local saved_build="$2"
  local saved_track="$3"

  if [[ "$AUTO_UPDATE" == "false" ]] && valid_api_value "$saved_build" && resolve_papermc_build "$PROJECT_NAME" "$saved_version" "$saved_build"; then
    capture_resolved_current
    return 0
  fi

  case "$saved_track" in
    ALPHA)
      if resolve_papermc_build "$PROJECT_NAME" "$saved_version" "" "ALPHA"; then
        capture_resolved_current
        return 0
      fi
      ;;
    BETA)
      if resolve_papermc_build "$PROJECT_NAME" "$saved_version" "" "BETA"; then
        capture_resolved_current
        return 0
      fi
      ;;
    *)
      if resolve_papermc_build "$PROJECT_NAME" "$saved_version" "" "$saved_track"; then
        capture_resolved_current
        return 0
      fi
      ;;
  esac

  if [[ "$saved_track" != "STABLE" ]] && resolve_papermc_build "$PROJECT_NAME" "$saved_version" "" "STABLE"; then
    capture_resolved_current
    return 0
  fi

  if [[ "$saved_track" != "BETA" && "$saved_track" != "ALPHA" ]] && resolve_papermc_build "$PROJECT_NAME" "$saved_version" "" "BETA"; then
    capture_resolved_current
    return 0
  fi

  if resolve_papermc_build "$PROJECT_NAME" "$saved_version" "" "ANY"; then
    capture_resolved_current
    return 0
  fi

  return 1
}

function choose_explicit_papermc_target() {
  if [[ -n "$BUILD_NUMBER" ]]; then
    echo "Using requested ${PROJECT_NAME} $MINECRAFT_VERSION build $BUILD_NUMBER..."
    if resolve_papermc_build "$PROJECT_NAME" "$MINECRAFT_VERSION" "$BUILD_NUMBER"; then
      apply_resolved_papermc_build
      return 0
    fi
    die "No valid ${PROJECT_NAME} download for explicit version '${MINECRAFT_VERSION}' build '${BUILD_NUMBER}'."
  fi

  echo "No build number => resolving ${PROJECT_NAME} $MINECRAFT_VERSION..."
  if resolve_papermc_build "$PROJECT_NAME" "$MINECRAFT_VERSION" "" "STABLE"; then
    apply_resolved_papermc_build
    return 0
  fi

  if resolve_papermc_build "$PROJECT_NAME" "$MINECRAFT_VERSION" "" "ANY"; then
    echo "Warning: ${PROJECT_NAME} $MINECRAFT_VERSION has no STABLE build. Using latest available build ${RESOLVED_BUILD} (${RESOLVED_CHANNEL})."
    apply_resolved_papermc_build
    return 0
  fi

  die "No valid ${PROJECT_NAME} download found for explicit version '${MINECRAFT_VERSION}'."
}

function choose_default_papermc_target() {
  if find_latest_papermc_build_by_channel "STABLE"; then
    apply_resolved_papermc_build
    echo "No version specified + no current_version.txt => using latest stable ${PROJECT_NAME} ${MINECRAFT_VERSION} build ${BUILD_NUMBER}."
    return 0
  fi

  if find_latest_papermc_build_by_channel "ANY"; then
    echo "Warning: no STABLE ${PROJECT_NAME} build found. Using latest available ${RESOLVED_VERSION} build ${RESOLVED_BUILD} (${RESOLVED_CHANNEL})."
    apply_resolved_papermc_build
    return 0
  fi

  die "No ${PROJECT_NAME} builds could be resolved from PaperMC."
}

function resolve_papermc_download_info() {
  local current_version=""
  local current_build=""
  local current_channel=""
  local current_jar_name=""
  local current_download_url=""
  local latest_stable_version=""
  local latest_stable_build=""
  local latest_stable_channel=""
  local latest_stable_jar_name=""
  local latest_stable_download_url=""
  local latest_beta_version=""
  local latest_beta_build=""
  local latest_beta_channel=""
  local latest_beta_jar_name=""
  local latest_beta_download_url=""
  local latest_alpha_version=""
  local latest_alpha_build=""
  local latest_alpha_channel=""
  local latest_alpha_jar_name=""
  local latest_alpha_download_url=""
  local saved_version=""
  local saved_build=""
  local saved_channel=""
  local saved_track=""
  local current_label
  local target_label
  local target_key
  local channel_switch_channel
  local channel_switch_reason
  local channel_switch_detail
  local channel_switch_question

  load_papermc_project_versions || die "No ${PROJECT_NAME} versions could be resolved from PaperMC."

  if find_latest_papermc_build_by_channel "STABLE"; then
    capture_resolved_latest_stable
  fi

  if find_latest_papermc_build_by_channel "BETA"; then
    capture_resolved_latest_beta
  fi

  if find_latest_papermc_build_by_channel "ALPHA"; then
    capture_resolved_latest_alpha
  fi

  if [[ "$USER_SUPPLIED_MINECRAFT_VERSION" == "true" ]]; then
    choose_explicit_papermc_target
    return 0
  fi

  if ! read_papermc_state; then
    choose_default_papermc_target
    return 0
  fi

  saved_version="$PAPERMC_STATE_VERSION"
  saved_build="$PAPERMC_STATE_BUILD"
  saved_channel="$PAPERMC_STATE_CHANNEL"
  PAPERMC_DECLINED_STABLE_TARGET="$PAPERMC_STATE_DECLINED_STABLE_TARGET"
  PAPERMC_DECLINED_BETA_TARGET="$PAPERMC_STATE_DECLINED_BETA_TARGET"
  PAPERMC_DECLINED_ALPHA_TARGET="$PAPERMC_STATE_DECLINED_ALPHA_TARGET"
  echo "No version specified => using $saved_version from current_version.txt"
  if valid_api_value "$saved_build" || valid_api_value "$saved_channel"; then
    echo "Saved PaperMC state: version=${saved_version}, build=${saved_build:-unknown}, channel=${saved_channel:-unknown}"
  fi

  saved_track="$(infer_saved_papermc_track "$saved_version" "$saved_build" "$saved_channel")" || die "No valid ${PROJECT_NAME} download found for saved version '${saved_version}'."
  resolve_saved_papermc_build "$saved_version" "$saved_build" "$saved_track" || die "No valid ${PROJECT_NAME} download found for saved version '${saved_version}' on ${saved_track} track."
  set_papermc_target "$current_version" "$current_build" "$current_channel" "$current_jar_name" "$current_download_url"

  if [[ "$AUTO_UPDATE" == "true" && "$IGNORE_CHANNEL_SWITCH" != "true" ]]; then
    for channel_switch_channel in STABLE BETA; do
      papermc_channel_is_better "$channel_switch_channel" "$PAPERMC_SELECTED_CHANNEL" || continue
      if ! resolve_papermc_build "$PROJECT_NAME" "$current_version" "" "$channel_switch_channel"; then
        continue
      fi

      current_label="$(format_papermc_build_label "$current_version" "$current_build" "$current_channel")"
      target_label="$(format_papermc_build_label "$RESOLVED_VERSION" "$RESOLVED_BUILD" "$RESOLVED_CHANNEL")"
      target_key="$(papermc_target_key "$RESOLVED_VERSION" "$RESOLVED_BUILD" "$RESOLVED_CHANNEL")"

      if papermc_declined_target_matches "$RESOLVED_CHANNEL" "$target_key"; then
        echo "Skipping previously declined ${RESOLVED_CHANNEL} target: ${target_label}"
        continue
      fi

      if [[ "$RESOLVED_CHANNEL" == "STABLE" ]]; then
        channel_switch_reason="A STABLE build is available for this saved version."
        channel_switch_detail="This keeps the same Minecraft/Paper version and switches from ${PAPERMC_SELECTED_CHANNEL} to STABLE. Use --ignore-channel-switch to skip channel suggestions for this run."
        channel_switch_question="Switch this version to STABLE? [y/N]"
      else
        channel_switch_reason="A BETA build is available for this saved version."
        channel_switch_detail="This keeps the same Minecraft/Paper version and switches from ${PAPERMC_SELECTED_CHANNEL} to BETA. Use --ignore-channel-switch to skip channel suggestions for this run."
        channel_switch_question="Switch this version to BETA? [y/N]"
      fi

      if prompt_papermc_choice "$channel_switch_reason" "$current_label" "$target_label" "$channel_switch_detail" "$channel_switch_question"; then
        clear_papermc_declined_target "$RESOLVED_CHANNEL"
        set_papermc_target "$RESOLVED_VERSION" "$RESOLVED_BUILD" "$RESOLVED_CHANNEL" "$RESOLVED_JAR_NAME" "$RESOLVED_DOWNLOAD_URL"
        AUTO_DETECTED_PAPERMC_UPGRADE=true
        return 0
      elif [[ "$PAPERMC_PROMPT_RESULT" == "declined" ]]; then
        record_papermc_declined_target "$RESOLVED_CHANNEL" "$target_key"
      fi
      break
    done
  fi

  if [[ "$AUTO_UPDATE" == "true" && ( "$saved_track" == "ALPHA" || "$saved_track" == "BETA" ) && "$latest_beta_version" != "$current_version" ]]; then
    if valid_api_value "$latest_beta_version" && papermc_version_is_newer "$latest_beta_version" "$current_version"; then
      if [[ "$IGNORE_CHANNEL_SWITCH" == "true" && "$latest_beta_channel" != "$PAPERMC_SELECTED_CHANNEL" ]]; then
        :
      else
        current_label="$(format_papermc_build_label "$current_version" "$current_build" "$current_channel")"
        target_label="$(format_papermc_build_label "$latest_beta_version" "$latest_beta_build" "$latest_beta_channel")"
        target_key="$(papermc_target_key "$latest_beta_version" "$latest_beta_build" "$latest_beta_channel")"
        if papermc_declined_target_matches "$latest_beta_channel" "$target_key"; then
          echo "Skipping previously declined ${latest_beta_channel} target: ${target_label}"
        elif prompt_papermc_choice "A newer beta ${PROJECT_NAME} version is available." "$current_label" "$target_label" "This stays on a pre-STABLE track and updates to a newer BETA Minecraft/Paper version." "Switch to this newer BETA jar? [y/N]"; then
          clear_papermc_declined_target "$latest_beta_channel"
          set_papermc_target "$latest_beta_version" "$latest_beta_build" "$latest_beta_channel" "$latest_beta_jar_name" "$latest_beta_download_url"
          AUTO_DETECTED_PAPERMC_UPGRADE=true
          return 0
        elif [[ "$PAPERMC_PROMPT_RESULT" == "declined" ]]; then
          record_papermc_declined_target "$latest_beta_channel" "$target_key"
        fi
      fi
    fi
  fi

  if [[ "$AUTO_UPDATE" == "true" && "$saved_track" == "ALPHA" && "$latest_alpha_version" != "$current_version" ]]; then
    if valid_api_value "$latest_alpha_version" && papermc_version_is_newer "$latest_alpha_version" "$current_version"; then
      current_label="$(format_papermc_build_label "$current_version" "$current_build" "$current_channel")"
      target_label="$(format_papermc_build_label "$latest_alpha_version" "$latest_alpha_build" "$latest_alpha_channel")"
      target_key="$(papermc_target_key "$latest_alpha_version" "$latest_alpha_build" "$latest_alpha_channel")"
      if papermc_declined_target_matches "$latest_alpha_channel" "$target_key"; then
        echo "Skipping previously declined ${latest_alpha_channel} target: ${target_label}"
      elif prompt_papermc_choice "A newer experimental ${PROJECT_NAME} version is available." "$current_label" "$target_label" "This stays on the ALPHA track and updates to a newer experimental Minecraft/Paper version." "Switch to this newer ALPHA jar? [y/N]"; then
        clear_papermc_declined_target "$latest_alpha_channel"
        set_papermc_target "$latest_alpha_version" "$latest_alpha_build" "$latest_alpha_channel" "$latest_alpha_jar_name" "$latest_alpha_download_url"
        AUTO_DETECTED_PAPERMC_UPGRADE=true
        return 0
      elif [[ "$PAPERMC_PROMPT_RESULT" == "declined" ]]; then
        record_papermc_declined_target "$latest_alpha_channel" "$target_key"
      fi
    fi
  fi

  if [[ "$AUTO_UPDATE" == "true" && "$IGNORE_CHANNEL_SWITCH" != "true" && "$PAPERMC_SELECTED_CHANNEL" != "STABLE" ]]; then
    if valid_api_value "$latest_stable_version" && [[ "$latest_stable_version" != "$current_version" ]]; then
      current_label="$(format_papermc_build_label "$current_version" "$current_build" "$current_channel")"
      target_label="$(format_papermc_build_label "$latest_stable_version" "$latest_stable_build" "$latest_stable_channel")"
      target_key="$(papermc_target_key "$latest_stable_version" "$latest_stable_build" "$latest_stable_channel")"
      if papermc_declined_target_matches "$latest_stable_channel" "$target_key"; then
        echo "Skipping previously declined ${latest_stable_channel} target: ${target_label}"
      elif prompt_papermc_choice "The saved ${PROJECT_NAME} version is still pre-STABLE; the latest stable release is different." "$current_label" "$target_label" "This switches from the current pre-STABLE track to the latest STABLE PaperMC download." "Switch to the latest stable jar? [y/N]"; then
        clear_papermc_declined_target "$latest_stable_channel"
        set_papermc_target "$latest_stable_version" "$latest_stable_build" "$latest_stable_channel" "$latest_stable_jar_name" "$latest_stable_download_url"
        AUTO_DETECTED_PAPERMC_UPGRADE=true
        return 0
      elif [[ "$PAPERMC_PROMPT_RESULT" == "declined" ]]; then
        record_papermc_declined_target "$latest_stable_channel" "$target_key"
      fi
    fi
  fi

  if [[ "$AUTO_UPDATE" == "true" && "$saved_track" == "STABLE" ]]; then
    if valid_api_value "$latest_stable_version" && [[ "$latest_stable_version" != "$current_version" || "$latest_stable_build" != "$current_build" ]]; then
      current_label="$(format_papermc_build_label "$current_version" "$current_build" "$current_channel")"
      target_label="$(format_papermc_build_label "$latest_stable_version" "$latest_stable_build" "$latest_stable_channel")"
      target_key="$(papermc_target_key "$latest_stable_version" "$latest_stable_build" "$latest_stable_channel")"
      if papermc_declined_target_matches "$latest_stable_channel" "$target_key"; then
        echo "Skipping previously declined ${latest_stable_channel} target: ${target_label}"
      elif prompt_papermc_choice "A newer stable ${PROJECT_NAME} download is available." "$current_label" "$target_label" "This performs a drop-in jar update on the STABLE track." "Continue with this stable jar update? [y/N]"; then
        clear_papermc_declined_target "$latest_stable_channel"
        set_papermc_target "$latest_stable_version" "$latest_stable_build" "$latest_stable_channel" "$latest_stable_jar_name" "$latest_stable_download_url"
        AUTO_DETECTED_PAPERMC_UPGRADE=true
        return 0
      elif [[ "$PAPERMC_PROMPT_RESULT" == "declined" ]]; then
        record_papermc_declined_target "$latest_stable_channel" "$target_key"
      fi
    fi
  fi

  if [[ "$PAPERMC_SELECTED_CHANNEL" == "ALPHA" || "$PAPERMC_SELECTED_CHANNEL" == "BETA" || "$PAPERMC_SELECTED_CHANNEL" == "STABLE" ]]; then
    echo "Continuing on ${PAPERMC_SELECTED_CHANNEL} track: ${MINECRAFT_VERSION} build ${BUILD_NUMBER}."
  else
    echo "Continuing on ${saved_track} track: ${MINECRAFT_VERSION} build ${BUILD_NUMBER}."
  fi
}

remove_old_jars() {
  if [[ "$PROJECT_NAME" == "spigot" ]]; then
    echo "[${PROJECT_NAME}] Skipping remove_old_jars..."
    return
  fi
  echo "Removing old .jar files except the current one..."
  find "${SERVER_DIR}" -maxdepth 1 -type f -name "*.jar" ! -name "${JAR_NAME}" -exec rm -v {} \;
}

download_jar() {
  local tmp_file

  valid_api_value "$JAR_NAME" || die "Resolved jar name is invalid: '${JAR_NAME}'"
  valid_api_value "$DOWNLOAD_URL" || die "Resolved download URL is invalid for ${PROJECT_NAME} ${MINECRAFT_VERSION} build ${BUILD_NUMBER}."

  if [[ -f "${FILE}" && "$AUTO_UPDATE" == "false" ]]; then
    echo "Auto-update OFF => using existing ${JAR_NAME}."
    return 0
  fi

  if [[ -f "${FILE}" ]]; then
    echo "Auto-update ON => re-download ${JAR_NAME} if changed..."
  else
    echo "Downloading ${JAR_NAME}..."
  fi

  tmp_file="$(mktemp "${SERVER_DIR}/.${JAR_NAME}.tmp.XXXXXX")" || die "Unable to create a temporary download file in ${SERVER_DIR}."
  if ! curl -fsSL -H "User-Agent: ${PAPERMC_USER_AGENT}" "$DOWNLOAD_URL" -o "$tmp_file"; then
    rm -f "$tmp_file"
    die "Download failed for ${JAR_NAME} from ${DOWNLOAD_URL}."
  fi

  if [[ ! -s "$tmp_file" ]]; then
    rm -f "$tmp_file"
    die "Downloaded ${JAR_NAME} is empty."
  fi

  mv -f "$tmp_file" "$FILE"
  DOWNLOAD_PERFORMED=true
}

if is_papermc_project; then
  resolve_papermc_download_info
elif [[ "$PROJECT_NAME" == "spigot" ]]; then
  # We'll build into spigot-server.jar
  JAR_NAME="spigot-server.jar"
  FILE="${SPIGOT_BUILT_JAR}"  # same path
else
  die "Unsupported PROJECT_NAME '${PROJECT_NAME}'. Use paper, velocity, folia, or spigot."
fi

########################################
#  AUTO-ACCEPT EULA (IF DESIRED)       #
########################################

function ensure_eula() {
  if [[ "$AUTO_AGREE_EULA" != "true" ]]; then
    echo "AUTO_AGREE_EULA is not true; leaving eula.txt unchanged."
    return
  fi

  local eulaFile="${SERVER_DIR}/eula.txt"
  if [[ ! -f "$eulaFile" ]]; then
    echo "eula.txt not found; creating it with eula=true"
    echo "eula=true" > "$eulaFile"
  else
    # If line "eula=false" exists, replace it
    if grep -q '^eula=false' "$eulaFile"; then
      sed -i 's/eula=false/eula=true/' "$eulaFile"
      echo "Set eula=true in $eulaFile"
    fi
  fi
}

########################################
#        MAIN START SEQUENCE           #
########################################

maybe_backup_and_clean

# Build or fetch server jar as needed
if [[ "$PROJECT_NAME" == "spigot" ]]; then
  build_spigot_if_needed
  [[ -n "$MINECRAFT_VERSION" ]] && echo "$MINECRAFT_VERSION" > "$CURRENT_VERSION_FILE"
elif is_papermc_project; then
  download_jar
  if [[ "$DOWNLOAD_PERFORMED" == "true" ]]; then
    remove_old_jars
  fi
  [[ -s "$FILE" ]] || die "Server jar is missing or empty: ${FILE:-unset}"
  write_papermc_state
fi

if [[ -z "$FILE" || "$FILE" == */null || ! -s "$FILE" ]]; then
  die "Server jar is missing or empty: ${FILE:-unset}"
fi

CONNECTION_PORT="$(resolve_connection_port)"

cd "${SERVER_DIR}" || {
  echo "Error: cd into $SERVER_DIR failed."
  exit 1
}

mkdir -p logs

# Make sure eula.txt is accepted
ensure_eula

echo "----------------------------------------"
echo "PROJECT_NAME         = ${PROJECT_NAME}"
echo "SERVER_DIR           = ${SERVER_DIR}"
echo "MINECRAFT_VERSION    = ${MINECRAFT_VERSION}"
echo "BUILD_NUMBER         = ${BUILD_NUMBER}"
echo "PAPERMC_CHANNEL      = ${PAPERMC_SELECTED_CHANNEL}"
echo "JAR_NAME             = ${JAR_NAME}"
echo "FILE                 = ${FILE}"
echo "AUTO_UPDATE          = ${AUTO_UPDATE}"
echo "CURRENT_VERSION_FILE = ${CURRENT_VERSION_FILE}"
echo "XMS                  = ${XMS}"
echo "XMX                  = ${XMX}"
echo "JAVA_CMD             = ${JAVA_CMD}"
echo "JAVA_MAJOR_VERSION   = ${JAVA_MAJOR_VERSION}"
echo "USE_TMUX             = ${USE_TMUX}"
echo "TMUX_SESSION_NAME    = ${TMUX_SESSION_NAME}"
echo "CHECK_TAILSCALE_BIND = ${CHECK_TAILSCALE_BIND}"
echo "IGNORE_CHANNEL_SWITCH = ${IGNORE_CHANNEL_SWITCH}"
echo "UPGRADE_MODE         = ${UPGRADE_MODE}"
echo "----------------------------------------"

echo "Starting ${PROJECT_NAME} server..."

# Build Java flags
if [[ "$PROJECT_NAME" == "velocity" ]]; then
  SERVER_FLAGS=(
    "-Xms${XMS}"
    "-Xmx${XMX}"
    "${VELOCITY_FLAGS_BASE[@]}"
  )
elif [[ "$PROJECT_NAME" == "folia" ]]; then
  SERVER_FLAGS=(
    "-Xms${XMS}"
    "-Xmx${XMX}"
    "${AIKAR_FLAGS[@]}"
    "${GC_LOGGING_FLAGS[@]}"
  )
elif [[ "$PROJECT_NAME" == "spigot" ]]; then
  SERVER_FLAGS=(
    "-Xms${XMS}"
    "-Xmx${XMX}"
    "${AIKAR_FLAGS[@]}"
    "${GC_LOGGING_FLAGS[@]}"
  )
else
  # Paper
  SERVER_FLAGS=(
    "-Xms${XMS}"
    "-Xmx${XMX}"
    "${AIKAR_FLAGS[@]}"
    "${GC_LOGGING_FLAGS[@]}"
  )
fi

EXTRA_ARGS="--nogui"
if [[ "$PROJECT_NAME" == "velocity" ]]; then
  EXTRA_ARGS=""
fi

echo "Server Flags  : ${SERVER_FLAGS[*]}"
echo "Extra Args    : ${EXTRA_ARGS}"
echo "----------------------------------------"

function print_connection_info() {
  local connection_port="${CONNECTION_PORT:-25565}"

  if is_wsl; then
    # Grab the first IP from hostname -I
    local ipAddr
    ipAddr="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [[ -z "$ipAddr" ]]; then
      ipAddr="(WSL IP not detected automatically)"
    fi
    echo "======================================================"
    echo "WSL DETECTED! Use ${ipAddr}:${connection_port} to connect from your Windows host."
    echo "======================================================"
  else
    echo "======================================================"
    echo "NON-WSL ENVIRONMENT! Use localhost:${connection_port} to connect."
    echo "======================================================"
  fi
}

# Start the server
if [[ "$USE_TMUX" == "true" ]]; then
  if tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
    echo "tmux session '$TMUX_SESSION_NAME' exists! Aborting start."
    exit 1
  fi
  if ! tmux new-session -d -s "$TMUX_SESSION_NAME" \
    "${JAVA_CMD} ${SERVER_FLAGS[*]} -jar \"${FILE}\" ${EXTRA_ARGS}"; then
    echo "Failed to create tmux session '$TMUX_SESSION_NAME'."
    exit 1
  fi
  sleep 2
  if ! tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
    echo "Server process exited immediately; tmux session '$TMUX_SESSION_NAME' is not running."
    echo "Check the server output/logs in ${SERVER_DIR}/logs for details."
    exit 1
  fi
  echo "Server started in tmux session '$TMUX_SESSION_NAME'."
  print_connection_info
else
  print_connection_info
  exec "${JAVA_CMD}" "${SERVER_FLAGS[@]}" -jar "${FILE}" ${EXTRA_ARGS}
fi
