@echo off
REM =============================================================================
REM   run_mcserver.bat  (Windows)
REM
REM   Mirrors the essential functionality of the original Bash script, except:
REM     - No tmux-based subcommands. 
REM     - It simply: (1) builds or fetches, (2) maybe backs up worlds, and (3) starts server in foreground.
REM
REM   Arguments (like the Bash script):
REM       [mc_version] [build_number] [--no-update] [--xms=###] [--xmx=###] [--java-cmd=...]
REM
REM   Environment variables:
REM     PROJECT_NAME : "paper" (default), "velocity", "folia", or "spigot"
REM     SERVER_DIR   : path to the server directory
REM
REM   Key features:
REM    - Folia: local Git clone + Docker-based build.
REM    - Paper/Velocity: fetch from PaperMC’s API (requires curl, typically jq).
REM    - Spigot: uses BuildTools for the specified version (requires Git + Java).
REM    - Backup & clean old worlds if version changes (Paper/Folia/Spigot).
REM    - Aikar GC flags, memory (Xms, Xmx), minimal usage instructions.
REM
REM =============================================================================


:: --------------------- CONFIGURATION DEFAULTS ---------------------
if not defined SERVER_DIR (
    set "SERVER_DIR=C:\MinecraftServers\myserver"
)
if not defined PROJECT_NAME (
    set "PROJECT_NAME=paper"  :: "paper", "velocity", "folia", or "spigot"
)

set "CURRENT_VERSION_FILE=%SERVER_DIR%\current_version.txt"
set "DEFAULT_WORLD_NAME=world"

set "DEFAULT_XMS=2G"
set "DEFAULT_XMX=2G"

:: The Java command. If you have a custom path, set "JAVA_CMD=C:\Path\to\java.exe"
if not defined JAVA_CMD (
    set "JAVA_CMD=java"
)

:: Folia-related:
set "FOLIA_SRC_DIR=C:\FoliaSource"
set "FOLIA_GIT_URL=https://github.com/PaperMC/Folia.git"
set "FOLIA_BRANCH=master"
set "FOLIA_DOCKER_CTX=C:\folia_docker_build"

:: Spigot-related:
set "SPIGOT_BUILD_DIR=%SERVER_DIR%\buildtools"
set "BUILD_TOOLS_JAR_URL=https://hub.spigotmc.org/jenkins/job/BuildTools/lastSuccessfulBuild/artifact/target/BuildTools.jar"
set "BUILD_TOOLS_JAR=%SPIGOT_BUILD_DIR%\BuildTools.jar"
set "SPIGOT_BUILT_JAR=%SERVER_DIR%\spigot-server.jar"

:: Aikar flags for Paper/Folia/Spigot, etc.:
set "AIKAR_FLAGS=-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 -Dusing.aikars.flags=https://mcflags.emc.gs -Daikars.new.flags=true"

:: We'll assign GC_LOGGING_FLAGS after we detect Java version.
set "GC_LOGGING_FLAGS="
set "VELOCITY_FLAGS_BASE=-XX:+AlwaysPreTouch -XX:+ParallelRefProcEnabled -XX:+UnlockExperimentalVMOptions -XX:+UseG1GC -XX:G1HeapRegionSize=4M -XX:MaxInlineLevel=15"


:: --------------------- PARSE ARGUMENTS ---------------------
call :parse_args %*

:: --------------------- DETECT JAVA VERSION ---------------------
call :detect_java_version

:: Possibly set GC_LOGGING_FLAGS here if you want detailed logs for Java 8 vs. 11+.
if defined JAVA_MAJOR_VERSION (
    if %JAVA_MAJOR_VERSION% lss 11 (
        set "GC_LOGGING_FLAGS=-Xloggc:gc.log -verbose:gc -XX:+PrintGCDetails -XX:+PrintGCDateStamps -XX:+PrintGCTimeStamps -XX:+UseGCLogFileRotation -XX:NumberOfGCLogFiles=5 -XX:GCLogFileSize=1M"
    ) else (
        set "GC_LOGGING_FLAGS=-Xlog:gc*:logs/gc.log:time,uptime:filecount=5,filesize=1M"
    )
)

:: --------------------- MAIN SEQUENCE ---------------------
if not exist "%SERVER_DIR%" (
    echo Error: SERVER_DIR "%SERVER_DIR%" does not exist.
    goto :eof
)

:: 1) Maybe backup/clean if Paper/Folia/Spigot + version changed
call :maybe_backup_and_clean

:: 2) Build or fetch the jar
if /i "%PROJECT_NAME%"=="folia" (
    call :docker_build_folia_if_needed
    if defined MINECRAFT_VERSION echo %MINECRAFT_VERSION% > "%CURRENT_VERSION_FILE%"
) else if /i "%PROJECT_NAME%"=="spigot" (
    call :build_spigot_if_needed
    if defined MINECRAFT_VERSION echo %MINECRAFT_VERSION% > "%CURRENT_VERSION_FILE%"
) else if /i "%PROJECT_NAME%"=="paper" (
    call :paper_velo_fetch
    if defined MINECRAFT_VERSION echo %MINECRAFT_VERSION% > "%CURRENT_VERSION_FILE%"
) else if /i "%PROJECT_NAME%"=="velocity" (
    call :paper_velo_fetch
    if defined MINECRAFT_VERSION echo %MINECRAFT_VERSION% > "%CURRENT_VERSION_FILE%"
) else (
    echo [ERROR] Unknown PROJECT_NAME=%PROJECT_NAME%
    goto :eof
)

:: 3) Construct final flags + run in foreground
pushd "%SERVER_DIR%"
if not exist logs mkdir logs

echo ---------------------------------------------
echo PROJECT_NAME         = %PROJECT_NAME%
echo SERVER_DIR           = %SERVER_DIR%
echo MINECRAFT_VERSION    = %MINECRAFT_VERSION%
echo BUILD_NUMBER         = %BUILD_NUMBER%
echo JAR_NAME             = %JAR_NAME%
echo FILE                 = %FILE%
echo AUTO_UPDATE          = %AUTO_UPDATE%
echo CURRENT_VERSION_FILE = %CURRENT_VERSION_FILE%
echo XMS                  = %XMS%
echo XMX                  = %XMX%
echo JAVA_CMD             = %JAVA_CMD%
echo JAVA_MAJOR_VERSION   = %JAVA_MAJOR_VERSION%
echo ---------------------------------------------

call :build_server_flags

echo Starting %PROJECT_NAME% server...
echo(
"%JAVA_CMD%" %FINAL_FLAGS%

popd
goto :eof


::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
::                   parse_args: handle arguments                        ::
::  [mc_version] [build_number] [--no-update] [--xms=###] [--xmx=###]     ::
::  [--java-cmd=...]                                                    ::
::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:parse_args
set "MINECRAFT_VERSION="
set "BUILD_NUMBER="
set "AUTO_UPDATE=true"
set "XMS=%DEFAULT_XMS%"
set "XMX=%DEFAULT_XMX%"
setlocal enabledelayedexpansion

:args_loop
if "%~1"=="" (
    endlocal & goto :args_done
)

set "arg=%~1"
echo %arg% | findstr /i "^--no-update$" >nul
if not errorlevel 1 (
    set "AUTO_UPDATE=false"
    shift
    goto args_loop
)

echo %arg% | findstr /i "^--xms=" >nul
if not errorlevel 1 (
    set "XMS=%arg:~6%"
    shift
    goto args_loop
)

echo %arg% | findstr /i "^--xmx=" >nul
if not errorlevel 1 (
    set "XMX=%arg:~6%"
    shift
    goto args_loop
)

echo %arg% | findstr /i "^--java-cmd=" >nul
if not errorlevel 1 (
    set "JAVA_CMD=%arg:~12%"
    shift
    goto args_loop
)

echo %arg% | findstr /i "^-" >nul
if not errorlevel 1 (
    echo [WARN] Unrecognized option "%arg%"
    shift
    goto args_loop
)

:: If it's not a dash, it must be mc_version or build_number
if not defined MINECRAFT_VERSION (
    set "MINECRAFT_VERSION=%arg%"
) else if not defined BUILD_NUMBER (
    set "BUILD_NUMBER=%arg%"
) else (
    echo [WARN] Extra argument "%arg%" ignored
)
shift
goto args_loop

:args_done
endlocal & (
    set "MINECRAFT_VERSION=%MINECRAFT_VERSION%"
    set "BUILD_NUMBER=%BUILD_NUMBER%"
    set "AUTO_UPDATE=%AUTO_UPDATE%"
    set "XMS=%XMS%"
    set "XMX=%XMX%"
    set "JAVA_CMD=%JAVA_CMD%"
)
goto :eof


::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
::                detect_java_version (naive approach)                   ::
::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:detect_java_version
set "JAVA_MAJOR_VERSION="

for /f "delims=" %%L in ('"%JAVA_CMD%" -version 2^>^&1 ^| findstr /i /r ""1\.[0-9] " ^') do (
    set "verline=%%L"
)

if not defined verline (
    echo [WARN] Could not parse Java version; continuing anyway.
    goto :eof
)

:: If we see "1.xx", assume Java 8
echo %verline%| findstr /i /r " \"1\.[0-9]" >nul
if not errorlevel 1 (
    set "JAVA_MAJOR_VERSION=8"
    goto :eof
)

:: Otherwise, we parse e.g. "17.0.8"
for %%A in (%verline%) do (
    if "%%~A"=="version" (
        rem skip
    ) else (
        echo %%~A| findstr /i /r "^[0-9][0-9]*\." >nul
        if not errorlevel 1 (
            for /f "tokens=1 delims=." %%B in ("%%~A") do (
                set "JAVA_MAJOR_VERSION=%%B"
                goto :eof
            )
        )
    )
)
goto :eof


::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
::                   maybe_backup_and_clean                              ::
::  For Paper/Folia/Spigot => if version changed, call backup_and_clean. ::
::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:maybe_backup_and_clean
if /i "%PROJECT_NAME%"=="paper"  (goto do_backup)
if /i "%PROJECT_NAME%"=="folia"  (goto do_backup)
if /i "%PROJECT_NAME%"=="spigot" (goto do_backup)
echo Skipping backup/clean (PROJECT_NAME=%PROJECT_NAME%).
goto :eof

:do_backup
if exist "%CURRENT_VERSION_FILE%" (
    set /p "LAST_VER="<"%CURRENT_VERSION_FILE%"
    if "%LAST_VER%"=="%MINECRAFT_VERSION%" (
        echo No version change => no backup/clean
        goto :eof
    )
    if "%MINECRAFT_VERSION%"=="" (
        echo No MC version => skip backup/clean
        goto :eof
    )
    call :backup_and_clean "%LAST_VER%" "%MINECRAFT_VERSION%"
) else (
    echo No current_version.txt => skip backup/clean
)
goto :eof


::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
::                     backup_and_clean                                  ::
::  Similar logic to the Bash script, prompting for manual deletion.      ::
::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:backup_and_clean
set "OLD_VERSION=%~1"
set "NEW_VERSION=%~2"

echo Version changed from "%OLD_VERSION%" to "%NEW_VERSION%". Backup + clean...

:: We'll generate a timestamp
set "TIMESTAMP="
for /f "tokens=2 delims==." %%A in ('wmic os get localdatetime /value') do (
    set "TIMESTAMP=%%A"
    goto :tsdone
)
:tsdone
if not defined TIMESTAMP (
    :: fallback
    set "TIMESTAMP=%date:~10,4%%date:~4,2%%date:~7,2%-%time:~0,2%%time:~3,2%"
)
set /a RANDSTR=%RANDOM%
set "BACKUP_DIR=%SERVER_DIR%\%DEFAULT_WORLD_NAME%-%OLD_VERSION%-%TIMESTAMP%-%RANDSTR%"

mkdir "%BACKUP_DIR%"

for %%W in ("%DEFAULT_WORLD_NAME%" "%DEFAULT_WORLD_NAME%_nether" "%DEFAULT_WORLD_NAME%_the_end") do (
    if exist "%SERVER_DIR%\%%~W" (
        echo Backing up "%%~W" => "%BACKUP_DIR%"
        move "%SERVER_DIR%\%%~W" "%BACKUP_DIR%" >nul
    )
)

echo Wiping server dir except critical files...
for %%I in ("%SERVER_DIR%\*") do (
    if /i "%%~nxI"=="%~nx0"           (goto skip_item)
    if /i "%%~nxI"=="%~nxBACKUP_DIR%" (goto skip_item)
    if /i "%%~nxI"=="plugins"         (goto skip_item)
    if /i "%%~nxI"=="server.properties"   (goto skip_item)
    if /i "%%~nxI"=="eula.txt"        (goto skip_item)
    if /i "%%~nxI"=="current_version.txt" (goto skip_item)

    :: Also skip the build script, jars, etc.:
    if /i "%%~xI"==".jar" (goto skip_item)
    if /i "%%~nxI"=="buildtools" (goto skip_item)

    echo Remove "%%~nxI"? [y/N]
    set /p "confirm=>"
    if /i "!confirm!"=="y" (
        rmdir /S /Q "%%~fI" 2>nul
        del   "%%~fI" 2>nul
    )

    :skip_item
)
goto :eof


::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
::                        paper_velo_fetch                               ::
::  Equivalent to "remove_old_jars + download_jar" from your Bash script  ::
::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:paper_velo_fetch
if not defined MINECRAFT_VERSION (
    if exist "%CURRENT_VERSION_FILE%" (
        set /p "MINECRAFT_VERSION="<"%CURRENT_VERSION_FILE%"
        echo Using MINECRAFT_VERSION=%MINECRAFT_VERSION% from current_version.txt
    ) else (
        echo No MINECRAFT_VERSION => fallback to 1.20.1
        set "MINECRAFT_VERSION=1.20.1"
    )
)

if not defined BUILD_NUMBER (
    echo No build number => fetching "latest build" from PaperMC...
    set "API_URL=https://api.papermc.io/v2/projects/%PROJECT_NAME%/versions/%MINECRAFT_VERSION%"
    curl -s %API_URL% > "%TEMP%\paper.json"
    findstr /i /r "\"builds\":[[]" "%TEMP%\paper.json" > "%TEMP%\builds_line.txt"
    set /p "BUILDS_LINE="<"%TEMP%\builds_line.txt"
    :: e.g. "builds":[400,401,402]
    for /f "tokens=* delims=[]," %%B in ("%BUILDS_LINE%") do (
        set "BUILD_NUMBER=%%~B"
    )
    if "%BUILD_NUMBER%"=="" set "BUILD_NUMBER=latest"
    del "%TEMP%\paper.json"
    del "%TEMP%\builds_line.txt"
)

set "API_URL=https://api.papermc.io/v2/projects/%PROJECT_NAME%/versions/%MINECRAFT_VERSION%"
set "BUILD_API_URL=%API_URL%/builds/%BUILD_NUMBER%"

:: Parse jar name
curl -s %BUILD_API_URL% > "%TEMP%\buildinfo.json"
findstr /i "\"application\":{\"name\":" "%TEMP%\buildinfo.json" > "%TEMP%\dl_line.txt"
set "JAR_NAME="
set /p "DL_LINE="<"%TEMP%\dl_line.txt"
for /f "tokens=1,2 delims=:{}\", " %%A in ("%DL_LINE%") do (
    if /i "%%~A"=="name" (
        set "JAR_NAME=%%~B"
    )
)
del "%TEMP%\buildinfo.json"
del "%TEMP%\dl_line.txt"

if not defined JAR_NAME (
    echo Could not parse jar name => fallback server.jar
    set "JAR_NAME=server.jar"
)

set "FILE=%SERVER_DIR%\%JAR_NAME%"

:: remove_old_jars part => remove old .jar except our JAR_NAME
for %%R in ("%SERVER_DIR%\*.jar") do (
    if /i "%%~nxR"=="%JAR_NAME%" (goto skip_rm)
    echo Removing old jar "%%~nxR"
    del "%%~fR"
    :skip_rm
)

if exist "%FILE%" (
    if /i "%AUTO_UPDATE%"=="true" (
        echo Auto-update ON => re-download %JAR_NAME%
        curl -s --fail "%BUILD_API_URL%/downloads/%JAR_NAME%" -o "%FILE%"
    ) else (
        echo Auto-update OFF => skip
    )
) else (
    echo Downloading %JAR_NAME% ...
    curl -s --fail "%BUILD_API_URL%/downloads/%JAR_NAME%" -o "%FILE%"
)

goto :eof


::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
::                    docker_build_folia_if_needed                       ::
::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:docker_build_folia_if_needed
echo === Checking Folia updates in %FOLIA_SRC_DIR% ===

where docker >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Docker not installed or not on PATH.
    goto :folia_end
)

docker info >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Docker not usable by current user.
    goto :folia_end
)

if not exist "%FOLIA_SRC_DIR%\.git" (
    echo Cloning Folia...
    git clone --branch "%FOLIA_BRANCH%" "%FOLIA_GIT_URL%" "%FOLIA_SRC_DIR%"
    if errorlevel 1 (
        echo [ERROR] git clone failed.
        goto :folia_end
    )
)

pushd "%FOLIA_SRC_DIR%"
git fetch origin
if errorlevel 1 (
    echo [ERROR] git fetch failed.
    popd
    goto :folia_end
)
for /f "delims=" %%L in ('git rev-parse HEAD') do set "LOCAL_HASH=%%L"
for /f "delims=" %%L in ('git rev-parse origin/%FOLIA_BRANCH%') do set "REMOTE_HASH=%%L"

echo [FOLIA] Local:  %LOCAL_HASH%
echo [FOLIA] Remote: %REMOTE_HASH%
popd

if /i "%AUTO_UPDATE%"=="false" (
    echo [Folia] Auto-update=OFF
    if not exist "%SERVER_DIR%\folia-server.jar" (
        echo No folia-server.jar => must build
        call :docker_build_folia
    ) else (
        echo Using existing folia-server.jar
    )
    goto :folia_end
)

if not "%LOCAL_HASH%"=="%REMOTE_HASH%" (
    echo Folia upstream changed => pulling + building
    pushd "%FOLIA_SRC_DIR%"
    git pull --rebase origin "%FOLIA_BRANCH%"
    popd
    call :docker_build_folia
) else (
    echo Folia is up-to-date
    if not exist "%SERVER_DIR%\folia-server.jar" (
        echo Missing folia-server.jar => building
        call :docker_build_folia
    ) else (
        echo folia-server.jar present => no build
    )
)

:folia_end
goto :eof


::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
::                         docker_build_folia                            ::
::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:docker_build_folia
echo === Building Folia in Docker (OpenJDK 22) ===

if not exist "%FOLIA_DOCKER_CTX%" mkdir "%FOLIA_DOCKER_CTX%"
robocopy "%FOLIA_SRC_DIR%" "%FOLIA_DOCKER_CTX%" /mir >nul

(
    echo FROM openjdk:22-jdk-bookworm
    echo RUN apt-get update && apt-get upgrade -y && apt-get install -y git findutils
    echo RUN git config --global user.name "Test User"
    echo RUN git config --global user.email "testemail@test.com"
    echo WORKDIR /FoliaSource
    echo COPY . /FoliaSource
    echo RUN .^/gradlew applyPatches && .^/gradlew createReobfBundlerJar
) > "%FOLIA_DOCKER_CTX%\Dockerfile"

docker build -t local-folia:latest "%FOLIA_DOCKER_CTX%"
if errorlevel 1 (
    echo [ERROR] Docker build failed.
    goto :eof
)

docker create --name tempfolia local-folia:latest >nul
docker cp tempfolia:/FoliaSource/build/libs "%SERVER_DIR%\build-output"
set "BUILT_JAR="
for /f "delims=" %%J in ('dir /b /o:-d "%SERVER_DIR%\build-output" ^| findstr /i ".jar$"') do (
    if not defined BUILT_JAR set "BUILT_JAR=%SERVER_DIR%\build-output\%%~J"
)
if not defined BUILT_JAR (
    echo [ERROR] No JAR found in build-output
    docker rm tempfolia >nul
    goto :eof
)
move "%BUILT_JAR%" "%SERVER_DIR%\folia-server.jar" >nul
rmdir /S /Q "%SERVER_DIR%\build-output" >nul
docker rm tempfolia >nul

echo Built Folia => %SERVER_DIR%\folia-server.jar
goto :eof


::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
::                      build_spigot_if_needed                           ::
::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:build_spigot_if_needed
where git >nul 2>nul
if errorlevel 1 (
    echo [ERROR] git is required to build Spigot with BuildTools.
    goto :eof
)

if not exist "%SPIGOT_BUILD_DIR%" mkdir "%SPIGOT_BUILD_DIR%"

if not exist "%BUILD_TOOLS_JAR%" (
    echo Downloading BuildTools => %BUILD_TOOLS_JAR%
    curl -s --fail "%BUILD_TOOLS_JAR_URL%" -o "%BUILD_TOOLS_JAR%"
) else (
    if /i "%AUTO_UPDATE%"=="true" (
        echo Re-downloading BuildTools (auto-update=ON)
        curl -s --fail "%BUILD_TOOLS_JAR_URL%" -o "%BUILD_TOOLS_JAR%"
    ) else (
        echo BuildTools.jar already exists
    )
)

if not defined MINECRAFT_VERSION (
    if exist "%CURRENT_VERSION_FILE%" (
        set /p "MINECRAFT_VERSION="<"%CURRENT_VERSION_FILE%"
        echo Using version from %CURRENT_VERSION_FILE% => %MINECRAFT_VERSION%
    ) else (
        echo No version => fallback to 1.20.1
        set "MINECRAFT_VERSION=1.20.1"
    )
)

if exist "%SPIGOT_BUILT_JAR%" (
    if /i "%AUTO_UPDATE%"=="false" (
        echo spigot-server.jar present => not rebuilding
        set "JAR_NAME=spigot-server.jar"
        set "FILE=%SPIGOT_BUILT_JAR%"
        goto :eof
    )
)

echo === Building Spigot %MINECRAFT_VERSION% via BuildTools ===
pushd "%SPIGOT_BUILD_DIR%"
rmdir /S /Q Spigot 2>nul
rmdir /S /Q CraftBukkit 2>nul
rmdir /S /Q work 2>nul
rmdir /S /Q apache-maven-* 2>nul
rmdir /S /Q Bukkit 2>nul

"%JAVA_CMD%" -jar "%BUILD_TOOLS_JAR%" --rev "%MINECRAFT_VERSION%"
if errorlevel 1 (
    echo [ERROR] BuildTools failed
    popd
    goto :eof
)

:: We assume "spigot-<version>.jar" was produced
if exist "spigot-%MINECRAFT_VERSION%.jar" (
    copy "spigot-%MINECRAFT_VERSION%.jar" "%SPIGOT_BUILT_JAR%" >nul
    set "JAR_NAME=spigot-server.jar"
    set "FILE=%SPIGOT_BUILT_JAR%"
    echo Done building Spigot => %SPIGOT_BUILT_JAR%
) else (
    echo [ERROR] Could not find spigot-%MINECRAFT_VERSION%.jar
)
popd
goto :eof


::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
::                      build_server_flags                               ::
::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:build_server_flags
:: Decide on flags based on PROJECT_NAME
if /i "%PROJECT_NAME%"=="velocity" (
    set "SERVER_FLAGS=-Xms%XMS% -Xmx%XMX% %VELOCITY_FLAGS_BASE%"
    set "EXTRA_ARGS="
) else if /i "%PROJECT_NAME%"=="folia" (
    set "SERVER_FLAGS=-Xms%XMS% -Xmx%XMX% %AIKAR_FLAGS% %GC_LOGGING_FLAGS%"
    set "EXTRA_ARGS=--nogui"
) else if /i "%PROJECT_NAME%"=="spigot" (
    set "SERVER_FLAGS=-Xms%XMS% -Xmx%XMX% %AIKAR_FLAGS% %GC_LOGGING_FLAGS%"
    set "EXTRA_ARGS=--nogui"
) else (
    :: paper
    set "SERVER_FLAGS=-Xms%XMS% -Xmx%XMX% %AIKAR_FLAGS% %GC_LOGGING_FLAGS%"
    set "EXTRA_ARGS=--nogui"
)

:: JAR_NAME and FILE set in previous fetch/build steps
set "FINAL_FLAGS=%SERVER_FLAGS% -jar %FILE% %EXTRA_ARGS%"
goto :eof
