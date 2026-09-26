#!/bin/bash

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
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
    CHOWN_NAME="nobody:users"
    SHARE_CHOWN_NAME="rbignell:users"
    FAILED=0
    CHANGED=0

    find "$BACKUP_ROOT" -maxdepth 1 -type d -name "20*" -mtime +30 -exec rm -rf {} \;
    log "Purged backups older than 1 month from $BACKUP_ROOT"
    mkdir -p "$LOG_DIR"

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
            log "$name already up to date ($latest_id), skipping download"
            return
        fi

        log "Downloading $name $latest_id from $dl_url..."
        backup_file "$jar"
        if curl -fsSL -o "$jar" "$dl_url"; then
            echo "$latest_id" > "$marker"
            log "Downloaded latest $name to $jar"
            CHANGED=1
        else
            log "Failed to download $name"
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

    chown "$CHOWN_NAME" "$MC_DIR"/*.jar "$PLUGINS_DIR"/*.jar
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