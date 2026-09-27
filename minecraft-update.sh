#!/bin/bash

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

# Plugin-specific logging: writes to the main log AND to a plugin-update.log
# kept in the server's plugins folder, so plugin/version history lives next to
# the jars it describes.
plog() {
    log "$1"
    [ -n "$PLUGIN_LOG_FILE" ] && echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$PLUGIN_LOG_FILE"
}

update_server() {
    SERVER_NAME="$1"
    BACKUP_ROOT="/mnt/user/share/backups/minecraft/old"
    TODAY=$(date +%Y-%m-%d)
    BACKUP_DIR="$BACKUP_ROOT/$TODAY"
    MC_DIR="/mnt/user/appdata/$SERVER_NAME/minecraft"
    PLUGINS_DIR="$MC_DIR/plugins"
    LOG_DIR="/var/log/scripts"
    LOG_FILE="$LOG_DIR/update_minecraft.log"
    PLUGIN_LOG_FILE="$PLUGINS_DIR/plugin-update.log"
    CHOWN_NAME="nobody:users"
    SHARE_CHOWN_NAME="rbignell:users"
    FAILED=0
    CHANGED=0

    find "$BACKUP_ROOT" -maxdepth 1 -type d -name "20*" -mtime +30 -exec rm -rf {} \;
    log "Purged backups older than 1 month from $BACKUP_ROOT"
    mkdir -p "$LOG_DIR"
    mkdir -p "$PLUGINS_DIR"

    backup_file() {
        local file="$1"
        if [ -f "$file" ]; then
            mkdir -p "$BACKUP_DIR"
            cp "$file" "$BACKUP_DIR/"
            log "Backed up $file to $BACKUP_DIR"
        fi
    }

    # Download a jar only if the resolved version differs from the one recorded
    # in a marker file next to the jar. Skips the download (and backup) when the
    # installed version already matches.
    #   $1 = human-readable name   $2 = target jar path
    #   $3 = latest version id     $4 = download url
    download_if_new() {
        local name="$1" jar="$2" latest_id="$3" dl_url="$4"
        local marker="$jar.version"

        if [ -z "$latest_id" ]; then
            log "Failed to resolve latest $name version"
            FAILED=1
            return
        fi

        if [ -f "$jar" ] && [ -f "$marker" ] && [ "$(cat "$marker")" = "$latest_id" ]; then
            plog "$name already up to date ($latest_id), skipping download"
            return
        fi

        plog "Downloading $name $latest_id from $dl_url..."
        backup_file "$jar"
        if curl -fsSL -o "$jar" "$dl_url"; then
            echo "$latest_id" > "$marker"
            plog "Downloaded latest $name to $jar"
            CHANGED=1
        else
            plog "Failed to download $name"
            FAILED=1
        fi
    }

    # Like download_if_new, but only downloads when the latest version is
    # strictly NEWER than the recorded one (version comparison via sort -V),
    # rather than merely different. Always downloads on first install.
    #   $1 = human-readable name   $2 = target jar path
    #   $3 = latest version         $4 = download url
    download_if_newer() {
        local name="$1" jar="$2" latest_ver="$3" dl_url="$4"
        local marker="$jar.version"
        local current_ver

        if [ -z "$latest_ver" ]; then
            log "Failed to resolve latest $name version"
            FAILED=1
            return
        fi

        if [ -f "$jar" ] && [ -f "$marker" ]; then
            current_ver=$(cat "$marker")
            # If the newest of the two equals the current version, then the
            # latest is not newer, so there is nothing to do.
            if [ "$current_ver" = "$latest_ver" ] || \
               [ "$(printf '%s\n%s\n' "$current_ver" "$latest_ver" | sort -V | tail -n 1)" = "$current_ver" ]; then
                plog "$name already up to date (installed $current_ver, latest $latest_ver), skipping download"
                return
            fi
        fi

        plog "Downloading $name $latest_ver from $dl_url..."
        backup_file "$jar"
        if curl -fsSL -o "$jar" "$dl_url"; then
            echo "$latest_ver" > "$marker"
            plog "Downloaded latest $name to $jar"
            CHANGED=1
        else
            plog "Failed to download $name"
            FAILED=1
        fi
    }

    # PaperMC (v3 API)
    # In v3, .versions is an object keyed by minor version, each mapping to an
    # array of full version strings (newest first). Walk them newest-first and
    # pick the first version whose latest build is on the STABLE channel, then
    # use the download URL the API hands back.
    PAPER_API="https://fill.papermc.io/v3/projects/paper"
    PAPER_VERSION=""
    PAPER_JAR_URL=""
    PAPER_SHA256=""
    for candidate in $(curl -s "$PAPER_API" | jq -r '[.versions[][]] | .[]'); do
        build_json=$(curl -s "$PAPER_API/versions/$candidate/builds/latest")
        if [ "$(echo "$build_json" | jq -r '.channel' 2>/dev/null)" = "STABLE" ]; then
            PAPER_VERSION="$candidate"
            PAPER_JAR_URL=$(echo "$build_json" | jq -r '.downloads."server:default".url' 2>/dev/null)
            PAPER_SHA256=$(echo "$build_json" | jq -r '.downloads."server:default".checksums.sha256' 2>/dev/null)
            break
        fi
    done
    PAPER_JAR="$MC_DIR/paper_server.jar"
    # Major Minecraft version this server targets (e.g. "26" from "26.1.2"),
    # used to gate plugins that declare per-game-version compatibility.
    MC_MAJOR=$(echo "$PAPER_VERSION" | cut -d. -f1)
    if [ -z "$PAPER_JAR_URL" ] || [ "$PAPER_JAR_URL" = "null" ]; then
        log "Failed to resolve latest stable PaperMC build from API"
        FAILED=1
    elif [ -f "$PAPER_JAR" ] && [ -n "$PAPER_SHA256" ] && [ "$PAPER_SHA256" != "null" ] \
         && [ "$(sha256sum "$PAPER_JAR" | awk '{print $1}')" = "$PAPER_SHA256" ]; then
        log "PaperMC already up to date ($PAPER_VERSION), skipping download"
    else
        log "Downloading PaperMC $PAPER_VERSION from $PAPER_JAR_URL..."
        backup_file "$PAPER_JAR"
        if curl -fsSL "$PAPER_JAR_URL" -o "$PAPER_JAR"; then
            log "Downloaded latest PaperMC to $PAPER_JAR"
            CHANGED=1
        else
            log "Failed to download PaperMC"
            FAILED=1
        fi
    fi

    # Geyser (GeyserMC v2 API)
    GEYSER_JAR="$PLUGINS_DIR/Geyser-Spigot.jar"
    GEYSER_VER=$(curl -s "https://download.geysermc.org/v2/projects/geyser" | jq -r '.versions[-1]' 2>/dev/null)
    GEYSER_BUILD=$(curl -s "https://download.geysermc.org/v2/projects/geyser/versions/$GEYSER_VER" | jq -r '.builds[-1]' 2>/dev/null)
    GEYSER_ID=""
    [ -n "$GEYSER_VER" ] && [ "$GEYSER_VER" != "null" ] && [ -n "$GEYSER_BUILD" ] && [ "$GEYSER_BUILD" != "null" ] && GEYSER_ID="$GEYSER_VER-$GEYSER_BUILD"
    download_if_new "Geyser" "$GEYSER_JAR" "$GEYSER_ID" \
        "https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/spigot"

    # Floodgate (GeyserMC v2 API)
    FLOODGATE_JAR="$PLUGINS_DIR/floodgate-spigot.jar"
    FLOODGATE_VER=$(curl -s "https://download.geysermc.org/v2/projects/floodgate" | jq -r '.versions[-1]' 2>/dev/null)
    FLOODGATE_BUILD=$(curl -s "https://download.geysermc.org/v2/projects/floodgate/versions/$FLOODGATE_VER" | jq -r '.builds[-1]' 2>/dev/null)
    FLOODGATE_ID=""
    [ -n "$FLOODGATE_VER" ] && [ "$FLOODGATE_VER" != "null" ] && [ -n "$FLOODGATE_BUILD" ] && [ "$FLOODGATE_BUILD" != "null" ] && FLOODGATE_ID="$FLOODGATE_VER-$FLOODGATE_BUILD"
    download_if_new "Floodgate" "$FLOODGATE_JAR" "$FLOODGATE_ID" \
        "https://download.geysermc.org/v2/projects/floodgate/versions/latest/builds/latest/downloads/spigot"

    # ViaVersion
    html=$(curl -s 'https://hangar.papermc.io/ViaVersion/ViaVersion/versions?channel=Release&platform=PAPER')
    latest=$(echo "$html" | grep -oP 'ViaVersion/ViaVersion/versions/\K[0-9]+\.[0-9]+\.[0-9]+' | sort -Vr | head -n 1)
    VIAVERSION_JAR="$PLUGINS_DIR/ViaVersion.jar"
    download_if_new "ViaVersion" "$VIAVERSION_JAR" "$latest" \
        "https://hangarcdn.papermc.io/plugins/ViaVersion/ViaVersion/versions/${latest}/PAPER/ViaVersion-${latest}.jar"

    # ViaBackwards
    html=$(curl -s 'https://hangar.papermc.io/ViaVersion/ViaBackwards/versions?channel=Release&platform=PAPER')
    latest=$(echo "$html" | grep -oP 'ViaVersion/ViaBackwards/versions/\K[0-9]+\.[0-9]+\.[0-9]+' | sort -Vr | head -n 1)
    VIABACKWARDS_JAR="$PLUGINS_DIR/ViaBackwards.jar"
    download_if_new "ViaBackwards" "$VIABACKWARDS_JAR" "$latest" \
        "https://hangarcdn.papermc.io/plugins/ViaVersion/ViaBackwards/versions/${latest}/PAPER/ViaBackwards-${latest}.jar"

    # DirectionHUD (Hangar API, "other" namespace)
    # The Hangar API returns the latest Release version and a ready-to-use
    # download URL for the PAPER platform, so we use those directly. Versions
    # look like "1.8.1.2+1.21.7"; download_if_newer compares them so we only
    # fetch a strictly newer release (and always download on first install).
    DIRECTIONHUD_API="https://hangar.papermc.io/api/v1/projects/other/DirectionHUD/versions?channel=Release&limit=1"
    dh_json=$(curl -s "$DIRECTIONHUD_API")
    DIRECTIONHUD_VER=$(echo "$dh_json" | jq -r '.result[0].name' 2>/dev/null)
    DIRECTIONHUD_URL=$(echo "$dh_json" | jq -r '.result[0].downloads.PAPER.downloadUrl' 2>/dev/null)
    DIRECTIONHUD_JAR="$PLUGINS_DIR/DirectionHUD.jar"
    if [ -z "$DIRECTIONHUD_URL" ] || [ "$DIRECTIONHUD_URL" = "null" ]; then
        plog "Failed to resolve latest DirectionHUD download from API"
        FAILED=1
    else
        download_if_newer "DirectionHUD" "$DIRECTIONHUD_JAR" "$DIRECTIONHUD_VER" "$DIRECTIONHUD_URL"
    fi

    # NickNamer+ (Modrinth API)
    # Only install/update if a Release version declares support for this
    # server's Minecraft major version ($MC_MAJOR). Modrinth exposes per-version
    # game_versions and a direct file URL, so we pick the newest compatible one.
    # If nothing lists the server version, we skip (not an error) so we never
    # install a build that isn't declared compatible.
    NICKNAMER_JAR="$PLUGINS_DIR/NickNamerPlus.jar"
    nn_json=$(curl -s "https://api.modrinth.com/v2/project/nicknamer%2B/version?loaders=%5B%22paper%22%5D")
    # Newest version (by version_number) whose game_versions include MC_MAJOR.x
    nn_match=$(echo "$nn_json" | jq -r --arg maj "$MC_MAJOR" '
        [ .[] | select(any(.game_versions[]; startswith($maj + "."))) ]
        | sort_by(.date_published) | last // empty
        | "\(.version_number)\t\(.files[0].url)"' 2>/dev/null)
    if [ -z "$MC_MAJOR" ]; then
        plog "Skipping NickNamer+: could not determine server Minecraft version"
    elif [ -z "$nn_match" ]; then
        NN_SUPPORTED=$(echo "$nn_json" | jq -r '[.[].game_versions[]] | unique | join(", ")' 2>/dev/null)
        plog "Skipping NickNamer+: no release declares support for Minecraft ${MC_MAJOR}.x (supports: ${NN_SUPPORTED})"
    else
        NICKNAMER_VER=$(echo "$nn_match" | cut -f1)
        NICKNAMER_URL=$(echo "$nn_match" | cut -f2)
        download_if_newer "NickNamer+" "$NICKNAMER_JAR" "$NICKNAMER_VER" "$NICKNAMER_URL"
    fi

    chown "$CHOWN_NAME" "$MC_DIR"/*.jar "$PLUGINS_DIR"/*.jar
    [ -f "$PLUGIN_LOG_FILE" ] && chown "$CHOWN_NAME" "$PLUGIN_LOG_FILE"
    log "Set ownership to $CHOWN_NAME"
    if [ -d "$BACKUP_DIR" ]; then
        chmod 777 "$BACKUP_DIR"
        chown -R "$SHARE_CHOWN_NAME" "$BACKUP_DIR"
        log "Set permissions to $BACKUP_DIR"
    fi

    if [ "$FAILED" -ne 0 ]; then
        log "Not restarting container due to failures"
        /usr/local/emhttp/webGui/scripts/notify \
            -e "Minecraft Update Failed" \
            -s "Update failed for $SERVER_NAME." \
            -d "Update failed for $SERVER_NAME. Please check the logs." \
            -i "alert"
    elif [ "$CHANGED" -eq 0 ]; then
        log "No updates found for $SERVER_NAME, container not restarted"
    else
        docker restart "$SERVER_NAME"
        log "Restarting $SERVER_NAME container"
        log "Update complete for $SERVER_NAME."
        /usr/local/emhttp/webGui/scripts/notify \
            -e "Minecraft Update" \
            -s "Update complete for $SERVER_NAME." \
            -d "The Minecraft server $SERVER_NAME has been updated successfully." \
            -i "normal"
    fi
}

# List of servers to update
for SERVER in binhex-minecraftserver binhex-minecraftserver2; do
    update_server "$SERVER"
done