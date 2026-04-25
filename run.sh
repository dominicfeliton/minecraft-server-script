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

: "${SERVER_DIR:=/tmp/wwc_test_server}"
TMUX_SESSION_NAME="$(basename "$SERVER_DIR")"

: "${PROJECT_NAME:=paper}"  # "paper", "velocity", "folia", or "spigot"

CURRENT_VERSION_FILE="${SERVER_DIR}/current_version.txt"
DEFAULT_WORLD_NAME="world"

DEFAULT_XMS="2G"
DEFAULT_XMX="2G"

JAVA_CMD="java"  # Overridden by --java-cmd= if passed

PAPERMC_API_BASE="https://fill.papermc.io/v3"
: "${PAPERMC_USER_AGENT:=minecraft-server-script/1.0 (https://github.com/dominicfeliton/minecraft-server-script)}"

# --- SPIGOT-RELATED CONFIG ---
# Where we keep or download BuildTools:
SPIGOT_BUILD_DIR="${SERVER_DIR}/buildtools"
BUILD_TOOLS_JAR_URL="https://hub.spigotmc.org/jenkins/job/BuildTools/lastSuccessfulBuild/artifact/target/BuildTools.jar"
BUILD_TOOLS_JAR="${SPIGOT_BUILD_DIR}/BuildTools.jar"
SPIGOT_BUILT_JAR="${SERVER_DIR}/spigot-server.jar"

########################################
#             USAGE & HELP             #
########################################

usage() {
    cat << EOF
Usage:
  $(basename "$0") <subcommand> [arguments...]

Subcommands:
  start    [mc_version] [build_number] [--no-update] [--xms=###] [--xmx=###] [--java-cmd=...] [--no-tmux]
  stop
  restart  [mc_version] [build_number] ...
  toggle

If no subcommand is provided, 'toggle' is used.

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
#           SUBCOMMAND LOGIC           #
########################################

SUBCOMMAND="$1"
[[ -z "$SUBCOMMAND" ]] && SUBCOMMAND="toggle"

case "$SUBCOMMAND" in
  start|stop|restart|toggle)
    shift
    ;;
  help|--help|-h)
    usage
    exit 0
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
XMS="${DEFAULT_XMS}"
XMX="${DEFAULT_XMX}"

args=("$@")
i=0
while [[ $i -lt $# ]]; do
  case "${args[$i]}" in
    --no-update)
      AUTO_UPDATE=false
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
      MINECRAFT_VERSION="$(< "$CURRENT_VERSION_FILE")"
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

maybe_backup_and_clean() {
  # Paper, Folia, or Spigot do backups on version change
  if [[ "$PROJECT_NAME" == "paper" || "$PROJECT_NAME" == "folia" || "$PROJECT_NAME" == "spigot" ]]; then
    if [[ "$AUTO_DETECTED_PAPERMC_UPGRADE" == "true" ]]; then
      echo "Auto-detected PaperMC upgrade accepted => jar-only update; skipping backup/clean."
      echo "Back up worlds and follow the proper upgrade path before running upgraded Minecraft versions in production."
      return
    fi
    if [[ -f "$CURRENT_VERSION_FILE" ]]; then
      local last_ver
      last_ver="$(< "$CURRENT_VERSION_FILE")"
      if [[ "$last_ver" != "$MINECRAFT_VERSION" && -n "$MINECRAFT_VERSION" ]]; then
        backup_and_clean "$last_ver" "$MINECRAFT_VERSION"
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
  else
    build_json="$(jq -c 'first(.[] | select(.channel == "STABLE")) // empty' <<< "$builds_json")"
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

function find_latest_stable_papermc_build() {
  local project="$1"
  local project_url="${PAPERMC_API_BASE}/projects/${project}"
  local project_json
  local version

  if ! project_json="$(papermc_fetch_json "$project_url" "project info for ${project}")"; then
    return 1
  fi

  if ! jq -e '.versions | type == "object"' >/dev/null 2>&1 <<< "$project_json"; then
    echo "Error: PaperMC project response for ${project} did not include a versions object." >&2
    return 1
  fi

  while IFS= read -r version; do
    [[ -z "$version" ]] && continue
    if resolve_papermc_build "$project" "$version" ""; then
      return 0
    fi
  done < <(jq -r '.versions | to_entries[] | .value[]' <<< "$project_json")

  return 1
}

function prompt_for_papermc_upgrade() {
  local current_version="$1"
  local current_build="$2"
  local latest_version="$3"
  local latest_build="$4"
  local reason="$5"
  local confirm

  [[ -t 0 ]] || return 1

  echo "----------------------------------------"
  echo "${reason}"
  echo "Current ${PROJECT_NAME}: ${current_version:-unknown} build ${current_build:-unknown}"
  echo "Latest stable ${PROJECT_NAME}: ${latest_version} build ${latest_build}"
  echo
  echo "This will perform a drop-in jar update only."
  echo "Before accepting, make sure you have backed up your worlds and followed the proper Minecraft/Paper upgrade path."
  echo "No world folders or server files will be removed for this auto-detected upgrade."
  echo "Continue with this jar-only update? [y/N]"
  read -r confirm
  [[ "$confirm" =~ ^[yY]$ ]]
}

function apply_resolved_papermc_build() {
  MINECRAFT_VERSION="$RESOLVED_VERSION"
  BUILD_NUMBER="$RESOLVED_BUILD"
  JAR_NAME="$RESOLVED_JAR_NAME"
  DOWNLOAD_URL="$RESOLVED_DOWNLOAD_URL"
  FILE="${SERVER_DIR}/${JAR_NAME}"
}

function fail_with_latest_stable_hint() {
  local requested_version="$1"
  local requested_build="$2"
  local latest_version="$3"
  local latest_build="$4"

  if valid_api_value "$latest_version" && valid_api_value "$latest_build"; then
    die "No valid ${PROJECT_NAME} download for version '${requested_version}' build '${requested_build:-latest stable}'. Latest stable is ${latest_version} build ${latest_build}."
  fi

  die "No valid ${PROJECT_NAME} download for version '${requested_version}' build '${requested_build:-latest stable}', and no latest stable ${PROJECT_NAME} build could be resolved."
}

function resolve_papermc_download_info() {
  local selected_from_current_file=false
  local current_valid=false
  local current_version=""
  local current_build=""
  local current_jar_name=""
  local current_download_url=""
  local latest_version=""
  local latest_build=""
  local latest_jar_name=""
  local latest_download_url=""

  if [[ -z "$MINECRAFT_VERSION" ]]; then
    if [[ -f "$CURRENT_VERSION_FILE" ]]; then
      MINECRAFT_VERSION="$(< "$CURRENT_VERSION_FILE")"
      selected_from_current_file=true
      echo "No version specified => using $MINECRAFT_VERSION from current_version.txt"
    else
      echo "No version specified + no current_version.txt => resolving latest stable ${PROJECT_NAME} from PaperMC..."
      if ! find_latest_stable_papermc_build "$PROJECT_NAME"; then
        die "No latest stable ${PROJECT_NAME} build could be resolved from PaperMC."
      fi
      apply_resolved_papermc_build
      return 0
    fi
  fi

  if [[ "$USER_SUPPLIED_MINECRAFT_VERSION" == "true" ]]; then
    if [[ -z "$BUILD_NUMBER" ]]; then
      echo "No build number => fetching latest stable build for $MINECRAFT_VERSION..."
    else
      echo "Using requested build $BUILD_NUMBER for $MINECRAFT_VERSION..."
    fi

    if resolve_papermc_build "$PROJECT_NAME" "$MINECRAFT_VERSION" "$BUILD_NUMBER"; then
      apply_resolved_papermc_build
      return 0
    fi

    if find_latest_stable_papermc_build "$PROJECT_NAME"; then
      latest_version="$RESOLVED_VERSION"
      latest_build="$RESOLVED_BUILD"
    fi
    fail_with_latest_stable_hint "$MINECRAFT_VERSION" "$BUILD_NUMBER" "$latest_version" "$latest_build"
  fi

  if find_latest_stable_papermc_build "$PROJECT_NAME"; then
    latest_version="$RESOLVED_VERSION"
    latest_build="$RESOLVED_BUILD"
    latest_jar_name="$RESOLVED_JAR_NAME"
    latest_download_url="$RESOLVED_DOWNLOAD_URL"
  else
    die "No latest stable ${PROJECT_NAME} build could be resolved from PaperMC."
  fi

  if resolve_papermc_build "$PROJECT_NAME" "$MINECRAFT_VERSION" "$BUILD_NUMBER"; then
    current_valid=true
    current_version="$RESOLVED_VERSION"
    current_build="$RESOLVED_BUILD"
    current_jar_name="$RESOLVED_JAR_NAME"
    current_download_url="$RESOLVED_DOWNLOAD_URL"
  fi

  if [[ "$current_valid" == "false" ]]; then
    if prompt_for_papermc_upgrade "$MINECRAFT_VERSION" "$BUILD_NUMBER" "$latest_version" "$latest_build" "No stable ${PROJECT_NAME} download was found for the saved version."; then
      MINECRAFT_VERSION="$latest_version"
      BUILD_NUMBER="$latest_build"
      JAR_NAME="$latest_jar_name"
      DOWNLOAD_URL="$latest_download_url"
      FILE="${SERVER_DIR}/${JAR_NAME}"
      AUTO_DETECTED_PAPERMC_UPGRADE=true
      return 0
    fi
    fail_with_latest_stable_hint "$MINECRAFT_VERSION" "$BUILD_NUMBER" "$latest_version" "$latest_build"
  fi

  if [[ "$AUTO_UPDATE" == "true" && "$selected_from_current_file" == "true" && ( "$current_version" != "$latest_version" || "$current_build" != "$latest_build" ) ]]; then
    if prompt_for_papermc_upgrade "$current_version" "$current_build" "$latest_version" "$latest_build" "A newer stable ${PROJECT_NAME} download is available."; then
      MINECRAFT_VERSION="$latest_version"
      BUILD_NUMBER="$latest_build"
      JAR_NAME="$latest_jar_name"
      DOWNLOAD_URL="$latest_download_url"
      FILE="${SERVER_DIR}/${JAR_NAME}"
      AUTO_DETECTED_PAPERMC_UPGRADE=true
      return 0
    fi
    echo "Keeping ${PROJECT_NAME} ${current_version} build ${current_build}."
  fi

  MINECRAFT_VERSION="$current_version"
  BUILD_NUMBER="$current_build"
  JAR_NAME="$current_jar_name"
  DOWNLOAD_URL="$current_download_url"
  FILE="${SERVER_DIR}/${JAR_NAME}"
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
  [[ -n "$MINECRAFT_VERSION" ]] && echo "$MINECRAFT_VERSION" > "$CURRENT_VERSION_FILE"
fi

if [[ -z "$FILE" || "$FILE" == */null || ! -s "$FILE" ]]; then
  die "Server jar is missing or empty: ${FILE:-unset}"
fi

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
  if is_wsl; then
    # Grab the first IP from hostname -I
    local ipAddr
    ipAddr="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [[ -z "$ipAddr" ]]; then
      ipAddr="(WSL IP not detected automatically)"
    fi
    echo "======================================================"
    echo "WSL DETECTED! Use ${ipAddr}:25565 to connect from your Windows host."
    echo "======================================================"
  else
    echo "======================================================"
    echo "NON-WSL ENVIRONMENT! Use localhost:25565 to connect."
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
