#!/bin/bash
# -----------------------------
# Mouse-Based Per-Monitor Dimming
# (Stable Version)
# -----------------------------
# Requires: xrandr, xdotool
# -----------------------------

# Brightness levels
ACTIVE_BRIGHTNESS=0.8
DIM_BRIGHTNESS=0.2

# Toggle file
TOGGLE_FILE="$HOME/.fade_mouse_enabled"

# Mouse poll interval (seconds)
MOUSE_INTERVAL=0.05

# Geometry poll interval (seconds)
GEOM_INTERVAL=2

# -----------------------------
# Internal state
# -----------------------------
declare -A MON_X1 MON_X2 MON_Y1 MON_Y2 MON_LAST_BRIGHT
MONITORS=()

GEOM_HASH=""
LAST_GEOM_CHECK=0
GEOM_DIRTY=0

# -----------------------------
# Cleanup
# -----------------------------
restore_brightness() {
    for MON in "${MONITORS[@]}"; do
        xrandr --output "$MON" --brightness 1.0
    done
    exit
}
trap restore_brightness SIGINT SIGTERM

# -----------------------------
# Read monitor geometry ONCE
# -----------------------------
read_monitors() {
    MONITORS=()
    MON_X1=()
    MON_X2=()
    MON_Y1=()
    MON_Y2=()
    MON_LAST_BRIGHT=()

    mapfile -t lines < <(xrandr --listmonitors | tail -n +2)

    for line in "${lines[@]}"; do
        if [[ $line =~ ([0-9]+:[[:space:]]+[\+\*]*)([A-Za-z0-9-]+)[[:space:]]+([0-9]+)\/[0-9]+x([0-9]+)\/[0-9]+\+([0-9]+)\+([0-9]+) ]]; then
            NAME="${BASH_REMATCH[2]}"
            WIDTH="${BASH_REMATCH[3]}"
            HEIGHT="${BASH_REMATCH[4]}"
            X_OFF="${BASH_REMATCH[5]}"
            Y_OFF="${BASH_REMATCH[6]}"

            MONITORS+=("$NAME")
            MON_X1["$NAME"]=$X_OFF
            MON_Y1["$NAME"]=$Y_OFF
            MON_X2["$NAME"]=$((X_OFF + WIDTH))
            MON_Y2["$NAME"]=$((Y_OFF + HEIGHT))
            MON_LAST_BRIGHT["$NAME"]=""
        fi
    done
}

# -----------------------------
# Initial setup
# -----------------------------
read_monitors
GEOM_HASH="$(xrandr --listmonitors | sha1sum | awk '{print $1}')"

# -----------------------------
# Main loop
# -----------------------------
while true; do
    NOW=$(date +%s)

    # -------- Geometry check (SLOW PATH) --------
    if (( NOW - LAST_GEOM_CHECK >= GEOM_INTERVAL )); then
        LAST_GEOM_CHECK=$NOW

        NEW_HASH="$(xrandr --listmonitors | sha1sum | awk '{print $1}')"
        if [ "$NEW_HASH" != "$GEOM_HASH" ]; then
            GEOM_HASH="$NEW_HASH"
            GEOM_DIRTY=1
            read_monitors
            sleep "$MOUSE_INTERVAL"
            continue
        fi
    fi

    # Skip brightness work while geometry just changed
    if [ "$GEOM_DIRTY" -eq 1 ]; then
        GEOM_DIRTY=0
        sleep "$MOUSE_INTERVAL"
        continue
    fi

    # -------- Mouse logic (FAST PATH) --------
    eval "$(xdotool getmouselocation --shell)"

    ACTIVE_MON=""

    for MON in "${MONITORS[@]}"; do
        if [ "$X" -ge "${MON_X1[$MON]}" ] && [ "$X" -lt "${MON_X2[$MON]}" ] &&
           [ "$Y" -ge "${MON_Y1[$MON]}" ] && [ "$Y" -lt "${MON_Y2[$MON]}" ]; then
            ACTIVE_MON="$MON"
            break
        fi
    done

    for MON in "${MONITORS[@]}"; do
        TARGET="$ACTIVE_BRIGHTNESS"

        if [ -f "$TOGGLE_FILE" ] && [ "$MON" != "$ACTIVE_MON" ]; then
            TARGET="$DIM_BRIGHTNESS"
        fi

        if [ "${MON_LAST_BRIGHT[$MON]}" != "$TARGET" ]; then
            xrandr --output "$MON" --brightness "$TARGET"
            MON_LAST_BRIGHT["$MON"]="$TARGET"
        fi
    done

    sleep "$MOUSE_INTERVAL"
done
