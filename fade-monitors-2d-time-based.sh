#!/bin/bash
# -----------------------------
# Mouse-Based Per-Monitor Dimming
# (Stable + Time-Based Brightness + Optional Gamma)
# Optimized to further reduce CPU usage
# -----------------------------
# Requires: xrandr, xdotool
# -----------------------------

# -----------------------------
# USER CONFIG
# -----------------------------

# Day / Night brightness
DAY_BRIGHTNESS=0.7
NIGHT_BRIGHTNESS=0.5
DIM_BRIGHTNESS=0.2

# Time window (24h, HHMM)
NIGHT_START=1700
DAY_START=0600

# Gamma control (optional)
ENABLE_GAMMA=true
DAY_GAMMA="1.0:1.0:1.0"
NIGHT_GAMMA="1.0:0.85:0.1"

# Toggle file (mouse dim enable/disable)
TOGGLE_FILE="$HOME/.fade_mouse_enabled"

# Poll intervals
MOUSE_INTERVAL=0.05
GEOM_INTERVAL=2

# -----------------------------
# SINGLE-INSTANCE LOCK
# -----------------------------
LOCKFILE="$HOME/.fade_mouse.lock"
exec 9>"$LOCKFILE" || exit 1
flock -n 9 || exit 0

# -----------------------------
# Internal state
# -----------------------------
declare -A MON_X1 MON_X2 MON_Y1 MON_Y2 MON_LAST_BRIGHT
MONITORS=()

GEOM_HASH=""
LAST_GEOM_CHECK=0
GEOM_DIRTY=0
LAST_GAMMA_STATE=""
LAST_TIME_STATE=""

# -----------------------------
# Cleanup
# -----------------------------
restore_brightness() {
    for MON in "${MONITORS[@]}"; do
        xrandr --output "$MON" --brightness 1.0 --gamma 1.0:1.0:1.0
    done
}
trap restore_brightness EXIT SIGINT SIGTERM

# -----------------------------
# Read monitor geometry
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
# Time helpers
# -----------------------------
current_time_hhmm() {
    date +%H%M
}

is_night() {
    NOW=$((10#$(current_time_hhmm)))
    NIGHT=$((10#$NIGHT_START))
    DAY=$((10#$DAY_START))

    if (( NIGHT > DAY )); then
        (( NOW >= NIGHT || NOW < DAY ))
    else
        (( NOW >= NIGHT && NOW < DAY ))
    fi
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

    # -------- Geometry check (slow path) --------
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

    if [ "$GEOM_DIRTY" -eq 1 ]; then
        GEOM_DIRTY=0
        sleep "$MOUSE_INTERVAL"
        continue
    fi

    # -------- Time-based baseline --------
    if is_night; then
        BASE_BRIGHTNESS="$NIGHT_BRIGHTNESS"
        TARGET_GAMMA="$NIGHT_GAMMA"
        TIME_STATE="night"
    else
        BASE_BRIGHTNESS="$DAY_BRIGHTNESS"
        TARGET_GAMMA="$DAY_GAMMA"
        TIME_STATE="day"
    fi

    # Only apply gamma if changed
    if [ "$ENABLE_GAMMA" = true ] && [ "$TIME_STATE" != "$LAST_GAMMA_STATE" ]; then
        for MON in "${MONITORS[@]}"; do
            xrandr --output "$MON" --gamma "$TARGET_GAMMA"
        done
        LAST_GAMMA_STATE="$TIME_STATE"
    fi

    # -------- Mouse logic --------
    eval "$(xdotool getmouselocation --shell)"

    ACTIVE_MON=""
    for MON in "${MONITORS[@]}"; do
        if [ "$X" -ge "${MON_X1[$MON]}" ] && [ "$X" -lt "${MON_X2[$MON]}" ] &&
           [ "$Y" -ge "${MON_Y1[$MON]}" ] && [ "$Y" -lt "${MON_Y2[$MON]}" ]; then
            ACTIVE_MON="$MON"
            break
        fi
    done

    # -------- Apply per-monitor brightness --------
    for MON in "${MONITORS[@]}"; do
        TARGET="$BASE_BRIGHTNESS"
        if [ -f "$TOGGLE_FILE" ] && [ "$MON" != "$ACTIVE_MON" ]; then
            TARGET="$DIM_BRIGHTNESS"
        fi

        # Only update if changed
        if [ "${MON_LAST_BRIGHT[$MON]}" != "$TARGET" ]; then
            if [ "$ENABLE_GAMMA" = true ]; then
                xrandr --output "$MON" --brightness "$TARGET" --gamma "$TARGET_GAMMA"
            else
                xrandr --output "$MON" --brightness "$TARGET"
            fi
            MON_LAST_BRIGHT["$MON"]="$TARGET"
        fi
    done

    sleep "$MOUSE_INTERVAL"
done
