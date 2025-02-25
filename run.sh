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
#  - Folia: checks a local Git repo for upstream changes and builds in Docker (OpenJDK 22).
#  - Paper/Velocity: fetch builds from PaperMC's API.
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

# --- FOLIA-RELATED CONFIG ---
: "${FOLIA_SRC_DIR:=/home/minecraft/FoliaSource}"   # local Git clone
FOLIA_GIT_URL="https://github.com/PaperMC/Folia.git"
#FOLIA_BRANCH="master"    # or "main", etc.
FOLIA_BRANCH="dev/hard-fork"

# Docker build context directory
: "${FOLIA_DOCKER_CTX=/home/minecraft/folia_docker_build}"

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

# For Paper/Velocity/Spigot => we need curl & jq
if [[ "$PROJECT_NAME" != "folia" ]]; then
  if ! command -v curl &>/dev/null; then
    echo "Error: 'curl' is required. Install it with your package manager first."
    exit 1
  fi
  if [[ "$PROJECT_NAME" != "spigot" ]]; then
    # spigot doesn't absolutely require jq for build, but Paper/Velocity do
    if ! command -v jq &>/dev/null; then
      echo "Error: 'jq' is required for Paper/Velocity. Install it with your package manager first."
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
      if [[ -z "$MINECRAFT_VERSION" ]]; then
        MINECRAFT_VERSION="${args[$i]}"
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
#   DOCKER-BASED FOLIA BUILD (JDK 22)  #
########################################

function docker_build_folia_if_needed() {
  echo "=== Checking for Folia updates in local repo ==="

  # 1) Check Docker
  if ! command -v docker &>/dev/null; then
    echo "Error: Docker not installed. Exiting."
    exit 1
  fi
  if ! docker info &>/dev/null; then
    echo "Error: Current user cannot run docker (missing perms?). Exiting."
    exit 1
  fi

  # 2) Ensure local git clone
  if [[ ! -d "$FOLIA_SRC_DIR/.git" ]]; then
    echo "[Folia] Cloning repo into $FOLIA_SRC_DIR ..."
    git clone --branch "$FOLIA_BRANCH" "$FOLIA_GIT_URL" "$FOLIA_SRC_DIR"
    [[ $? -ne 0 ]] && { echo "Error: git clone failed."; exit 1; }
  fi

  # 3) Fetch remote changes
  echo "[Folia] Fetching remote..."
  pushd "$FOLIA_SRC_DIR" >/dev/null || exit 1
  git fetch origin
  [[ $? -ne 0 ]] && { echo "Error: git fetch failed."; exit 1; }

  local LOCAL_HASH
  LOCAL_HASH="$(git rev-parse HEAD)"
  local REMOTE_HASH
  REMOTE_HASH="$(git rev-parse origin/$FOLIA_BRANCH)"
  echo "[Folia] Local HEAD:  $LOCAL_HASH"
  echo "[Folia] Remote HEAD: $REMOTE_HASH"

  popd >/dev/null || exit 1

  # 4) If --no-update => skip pulling. If jar missing, force build
  if [[ "$AUTO_UPDATE" == "false" ]]; then
    echo "[Folia] Auto-update OFF, not pulling changes..."
    if [[ ! -f "${SERVER_DIR}/folia-server.jar" ]]; then
      echo "[Folia] No folia-server.jar => forced Docker build..."
      docker_build_folia
    else
      echo "[Folia] Using existing jar. No build."
    fi
    return 0
  fi

  # 5) If there's a difference, pull + build. If jar missing, build anyway
  if [[ "$LOCAL_HASH" != "$REMOTE_HASH" ]]; then
    echo "[Folia] Upstream changes detected. Pulling + building..."
    pushd "$FOLIA_SRC_DIR" >/dev/null || exit 1
    git pull --rebase origin "$FOLIA_BRANCH"
    [[ $? -ne 0 ]] && { echo "Error: git pull failed."; exit 1; }
    popd >/dev/null || exit 1

    docker_build_folia
  else
    echo "[Folia] No remote changes (HEAD is up-to-date)."
    if [[ ! -f "${SERVER_DIR}/folia-server.jar" ]]; then
      echo "[Folia] jar missing => forced Docker build..."
      docker_build_folia
    else
      echo "[Folia] jar is present => no build needed."
    fi
  fi
}

function docker_build_folia() {
  echo "=== Building Folia in Docker (OpenJDK 22) ==="

  mkdir -p "$FOLIA_DOCKER_CTX"

  # 1) Sync Folia source to build context:
  rsync -av --delete "$FOLIA_SRC_DIR/" "$FOLIA_DOCKER_CTX/"

  # 2) Create Dockerfile (AFTER rsync, so it won't get overwritten)
  cat > "$FOLIA_DOCKER_CTX/Dockerfile" << 'EOF'
FROM amazoncorretto:21

# Install missing tools using yum
RUN yum update -y && yum install -y git findutils

RUN git config --global user.name "Test User"
RUN git config --global user.email "testemail@test.com"

WORKDIR /FoliaSource
COPY . /FoliaSource

# Build Folia
RUN ./gradlew applyAllPatches && ./gradlew createMojmapBundlerJar
EOF

  # 3) Build the Docker image
  echo "[Folia] docker build => local-folia:latest"
  docker build -t local-folia:latest "$FOLIA_DOCKER_CTX"
  if [[ $? -ne 0 ]]; then
    echo "Error: Docker build failed. Exiting."
    exit 1
  fi

  # 4) Create container so we can docker cp
  docker create --name tempfolia local-folia:latest
  if [[ $? -ne 0 ]]; then
    echo "Error: docker create failed. Exiting."
    exit 1
  fi

  # 5) Create a temporary directory for copying files
  local temp_output_dir="${SERVER_DIR}/build-output"
  mkdir -p "$temp_output_dir"
  
  # 6) Search for Folia bundler jar in potential locations
  echo "[Folia] Searching for bundler jar in container..."
  
  # First, try to find all potential bundler jar files in the container
  # This command creates a script inside the container that finds all files that match the pattern
  docker exec tempfolia sh -c "find /FoliaSource -type f -name '*bundler*mojmap.jar' -o -name '*mojmap*bundler.jar'" > "$temp_output_dir/bundler_paths.txt"
  
  if [ ! -s "$temp_output_dir/bundler_paths.txt" ]; then
    echo "[Folia] No bundler jar found with specific pattern. Trying broader search..."
    # If no specific bundler jar is found, try a broader search for any mojmap jar
    docker exec tempfolia sh -c "find /FoliaSource -type f -name '*mojmap*.jar'" > "$temp_output_dir/bundler_paths.txt"
  fi
  
  if [ ! -s "$temp_output_dir/bundler_paths.txt" ]; then
    echo "[Folia] Still no jars found. Trying even broader search for any jar..."
    # Last resort - try to find any jar files
    docker exec tempfolia sh -c "find /FoliaSource -path '*/build/libs/*.jar'" > "$temp_output_dir/bundler_paths.txt"
  fi
  
  # Check if we found any paths
  if [ ! -s "$temp_output_dir/bundler_paths.txt" ]; then
    echo "Error: Could not find any jar files in the container!"
    docker rm tempfolia >/dev/null 2>&1
    exit 1
  fi
  
  # Copy each found jar file to our temp directory
  while read -r jar_path; do
    if [ -n "$jar_path" ]; then
      echo "[Folia] Found jar: $jar_path"
      local jar_filename=$(basename "$jar_path")
      docker cp "tempfolia:$jar_path" "$temp_output_dir/$jar_filename"
      echo "[Folia] Copied: $jar_filename"
    fi
  done < "$temp_output_dir/bundler_paths.txt"
  
  # 7) Find the most appropriate jar to use as server jar
  local BUILT_JAR=""
  
  # First priority: bundler jars with mojmap in the name
  BUILT_JAR="$(find "$temp_output_dir" -type f -name '*bundler*mojmap*.jar' | sort -r | head -n1)"
  
  # Second priority: any mojmap jar
  if [[ -z "$BUILT_JAR" ]]; then
    BUILT_JAR="$(find "$temp_output_dir" -type f -name '*mojmap*.jar' | sort -r | head -n1)"
  fi
  
  # Third priority: any jar file
  if [[ -z "$BUILT_JAR" ]]; then
    BUILT_JAR="$(find "$temp_output_dir" -type f -name '*.jar' | sort -r | head -n1)"
  fi
  
  if [[ -z "$BUILT_JAR" ]]; then
    echo "Error: No JAR found in build-output after copying!"
    docker rm tempfolia >/dev/null 2>&1
    exit 1
  fi
  
  echo "[Folia] Using jar: $(basename "$BUILT_JAR")"
  mv "$BUILT_JAR" "${SERVER_DIR}/folia-server.jar"
  
  # 8) Cleanup
  rm -rf "$temp_output_dir"
  docker rm tempfolia >/dev/null 2>&1

  echo "=== Done. Built Folia (folia-server.jar) is in ${SERVER_DIR} ==="
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
#   PAPER/VELOCITY DOWNLOAD LOGIC      #
########################################

remove_old_jars() {
  # For spigot or folia, skip this function (they have separate logic).
  if [[ "$PROJECT_NAME" == "folia" || "$PROJECT_NAME" == "spigot" ]]; then
    echo "[${PROJECT_NAME}] Skipping remove_old_jars..."
    return
  fi
  echo "Removing old .jar files except the current one..."
  find "${SERVER_DIR}" -maxdepth 1 -type f -name "*.jar" ! -name "${JAR_NAME}" -exec rm -v {} \;
}

download_jar() {
  if [[ -f "${FILE}" ]]; then
    if [[ "$AUTO_UPDATE" == "true" ]]; then
      echo "Auto-update ON => re-download if changed..."
      curl -sSL "${BUILD_API_URL}/downloads/${JAR_NAME}" -o "${FILE}"
    else
      echo "Auto-update OFF => skip download."
    fi
  else
    echo "Downloading ${JAR_NAME}..."
    curl -sSL "${BUILD_API_URL}/downloads/${JAR_NAME}" -o "${FILE}"
  fi
}

########################################
#      PAPER/VELOCITY BUILD INFO       #
########################################

if [[ "$PROJECT_NAME" == "paper" || "$PROJECT_NAME" == "velocity" ]]; then
  if [[ -z "$MINECRAFT_VERSION" ]]; then
    if [[ -f "$CURRENT_VERSION_FILE" ]]; then
      MINECRAFT_VERSION="$(< "$CURRENT_VERSION_FILE")"
      echo "No version specified => using $MINECRAFT_VERSION from current_version.txt"
    else
      echo "No version specified + no current_version.txt => fetching latest from PaperMC..."
      MINECRAFT_VERSION="$(curl -sSL "https://api.papermc.io/v2/projects/${PROJECT_NAME}" | jq -r '.versions[-1]')"
    fi
  fi

  if [[ -z "$BUILD_NUMBER" ]]; then
    echo "No build number => fetching latest build for $MINECRAFT_VERSION..."
    API_URL="https://api.papermc.io/v2/projects/${PROJECT_NAME}/versions/${MINECRAFT_VERSION}"
    BUILD_NUMBER="$(curl -sSL "${API_URL}" | jq -r '.builds[-1]')"
  else
    API_URL="https://api.papermc.io/v2/projects/${PROJECT_NAME}/versions/${MINECRAFT_VERSION}"
  fi

  BUILD_API_URL="${API_URL}/builds/${BUILD_NUMBER}"
  JAR_NAME="$(curl -sSL "${BUILD_API_URL}" | jq -r '.downloads.application.name')"
  FILE="${SERVER_DIR}/${JAR_NAME}"

elif [[ "$PROJECT_NAME" == "folia" ]]; then
  # Folia => we use 'folia-server.jar'
  JAR_NAME="folia-server.jar"
  FILE="${SERVER_DIR}/${JAR_NAME}"

elif [[ "$PROJECT_NAME" == "spigot" ]]; then
  # We'll build into spigot-server.jar
  JAR_NAME="spigot-server.jar"
  FILE="${SPIGOT_BUILT_JAR}"  # same path
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
if [[ "$PROJECT_NAME" == "folia" ]]; then
  docker_build_folia_if_needed
elif [[ "$PROJECT_NAME" == "spigot" ]]; then
  build_spigot_if_needed
  [[ -n "$MINECRAFT_VERSION" ]] && echo "$MINECRAFT_VERSION" > "$CURRENT_VERSION_FILE"
elif [[ "$PROJECT_NAME" == "paper" || "$PROJECT_NAME" == "velocity" ]]; then
  remove_old_jars
  download_jar
  [[ -n "$MINECRAFT_VERSION" ]] && echo "$MINECRAFT_VERSION" > "$CURRENT_VERSION_FILE"
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
  tmux new-session -d -s "$TMUX_SESSION_NAME" \
    "${JAVA_CMD} ${SERVER_FLAGS[*]} -jar \"${FILE}\" ${EXTRA_ARGS}"
  echo "Server started in tmux session '$TMUX_SESSION_NAME'."
  print_connection_info
else
  print_connection_info
  exec "${JAVA_CMD}" "${SERVER_FLAGS[@]}" -jar "${FILE}" ${EXTRA_ARGS}
fi