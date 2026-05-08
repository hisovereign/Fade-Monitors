#!/bin/bash
# -----------------------------
# Enhanced Mouse-Based Multi-Monitor Dimming with Idle, Day/Night Modes, and Gamma Control
# (version with time-transition, per‑transition lock, smooth gamma, and idle gamma fade)
# -----------------------------
# Requires: xrandr, xdotool, xprintidle, bc
# -----------------------------

# -----------------------------
# USER CONFIG
# -----------------------------

# Day/Night brightness levels
DAY_ACTIVE_BRIGHTNESS=0.7
DAY_DIM_BRIGHTNESS=0.3
NIGHT_ACTIVE_BRIGHTNESS=0.4
NIGHT_DIM_BRIGHTNESS=0.1
IDLE_BRIGHTNESS=0.1

# Time window (24h, HHMM format)
NIGHT_START=1700   # 17:00 PM
DAY_START=0730     # 07:30 AM

# Gamma control (optional)
ENABLE_GAMMA=false
DAY_GAMMA="1.0:1.0:1.0"
NIGHT_GAMMA="1.0:0.85:0.1"

# Idle settings
IDLE_TIMEOUT=90              # Seconds of inactivity before idle dim
ENABLE_IDLE=false             # Set to false to disable idle dimming entirely

# Smooth transition settings - MOUSE DIM
SMOOTH_DIM_MOUSE_STEPS=10        # Steps for mouse-based dimming transitions
SMOOTH_DIM_MOUSE_INTERVAL=0.01   # Seconds between steps for mouse dimming
INSTANT_MOUSE_DIM=true          # Override smooth dimming with instant for mouse

# Smooth transition settings - IDLE DIM
SMOOTH_DIM_IDLE_STEPS=10         # Steps for idle dimming transitions
SMOOTH_DIM_IDLE_INTERVAL=0.01    # Seconds between steps for idle dimming
INSTANT_IDLE_DIM=false           # Override smooth dimming with instant for idle

# Smooth transition settings - TIME (day/night) DIM
SMOOTH_DIM_TIME_STEPS=20         # Steps for day/night transitions
SMOOTH_DIM_TIME_INTERVAL=0.05    # Seconds between steps for time-based dimming
INSTANT_TIME_DIM=false           # Override smooth dimming with instant for time

# Toggle files
TOGGLE_FILE="$HOME/.fade_mouse_enabled"
IDLE_TOGGLE_FILE="$HOME/.idle_dim_enabled"

# Poll intervals
MOUSE_INTERVAL=1.0           # Mouse polling
IDLE_CHECK_INTERVAL=1        # Idle check interval (every 1 second)
GEOM_INTERVAL=2              # Monitor geometry check interval
TIME_CHECK_INTERVAL=30       # Time state check interval (every 30 seconds)

# -----------------------------
# COMMAND PARSER
# -----------------------------
if [[ $# -gt 0 ]]; then
    case "$1" in
        toggle-mouse)
            if [ -f "$TOGGLE_FILE" ]; then
                rm "$TOGGLE_FILE"
                echo "Mouse dimming OFF"
            else
                touch "$TOGGLE_FILE"
                echo "Mouse dimming ON"
            fi
            exit 0
            ;;
        toggle-idle)
            if [ -f "$IDLE_TOGGLE_FILE" ]; then
                rm "$IDLE_TOGGLE_FILE"
                echo "Idle dimming OFF"
            else
                touch "$IDLE_TOGGLE_FILE"
                echo "Idle dimming ON"
            fi
            exit 0
            ;;
        *)
            echo "Usage: $0 [toggle-mouse|toggle-idle]"
            exit 1
            ;;
    esac
fi

# -----------------------------
# SINGLE-INSTANCE LOCK
# -----------------------------
LOCKFILE="$HOME/.fade_mouse.lock"
exec 9>"$LOCKFILE" || exit 1
flock -n 9 || exit 0

# Transition lock file (used internally by smooth_transition and smooth_gamma_transition)
TRANSITION_LOCKFILE="$HOME/.fade_mouse.transition.lock"

# -----------------------------
# Internal state
# -----------------------------
declare -A MON_X1 MON_X2 MON_Y1 MON_Y2 MON_TARGET_BRIGHT MON_CURRENT_BRIGHT
declare -A START_BRIGHTNESS STEP_SIZES
MONITORS=()

GEOM_HASH=""
LAST_GEOM_CHECK=0
LAST_IDLE_CHECK=0
LAST_TIME_CHECK=0
GEOM_DIRTY=0

# State management
CURRENT_STATE="active"               # "active" or "idle"
CURRENT_TIME_STATE="day"             # "day" or "night"
CURRENT_ACTIVE_BRIGHTNESS="$DAY_ACTIVE_BRIGHTNESS"
CURRENT_DIM_BRIGHTNESS="$DAY_DIM_BRIGHTNESS"
CURRENT_GAMMA="$DAY_GAMMA"
LAST_APPLIED_GAMMA=""                # tracks last applied gamma
LAST_ACTIVE_MON=""
LAST_ACTIVITY_TIME=$(date +%s)

# ============================================
# HIDDEN SAFETY MINIMUM
# ============================================
# Minimum limit for active day and night brightness.
# This ensures screens never go completely black during active use.
MIN_BRIGHTNESS=0.1
# ============================================

# -----------------------------
# FUNCTIONS
# -----------------------------

# Cleanup
restore_brightness() {
    for MON in "${MONITORS[@]}"; do
        xrandr --output "$MON" --brightness 1.0 --gamma 1.0:1.0:1.0 2>/dev/null
    done
}

cleanup() {
    restore_brightness
    flock -u 9
    exit 0
}

trap cleanup EXIT SIGINT SIGTERM

# Read monitor geometry (unchanged)
read_monitors() {
    MONITORS=()
    MON_X1=()
    MON_X2=()
    MON_Y1=()
    MON_Y2=()
    MON_TARGET_BRIGHT=()
    MON_CURRENT_BRIGHT=()

    mapfile -t lines < <(echo "$XRANDR_LIST" | tail -n +2)

    for line in "${lines[@]}"; do
        if [[ $line =~ ([0-9]+:[[:space:]]+[\+\*]*)([A-Za-z0-9-]+)[[:space:]]+([0-9]+)/[0-9]+x([0-9]+)/[0-9]+\+([0-9]+)\+([0-9]+) ]]; then
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

            # Apply minimum brightness for initial state (active state)
            local initial_brightness="$CURRENT_ACTIVE_BRIGHTNESS"
            if [ "$(echo "$initial_brightness < $MIN_BRIGHTNESS" \
                | bc -l 2>/dev/null)" -eq 1 ]; then
                initial_brightness="$MIN_BRIGHTNESS"
            fi

            MON_TARGET_BRIGHT["$NAME"]="$initial_brightness"
            MON_CURRENT_BRIGHT["$NAME"]="$initial_brightness"
        fi
    done
}

# Time helper functions
current_time_hhmm() {
    date +%H%M
}

is_night() {
    local NOW NIGHT DAY
    NOW=$((10#$(current_time_hhmm)))
    NIGHT=$((10#$NIGHT_START))
    DAY=$((10#$DAY_START))

    if (( NIGHT > DAY )); then
        # Night wraps past midnight (e.g., 1700-0800)
        (( NOW >= NIGHT || NOW < DAY ))
    else
        # Normal case (e.g., 0800-1700)
        (( NOW >= NIGHT && NOW < DAY ))
    fi
}

# Smooth gamma-only transition (used when idle dimmed)
smooth_gamma_transition() {
    # Only if gamma is enabled and the target differs
    [ "$ENABLE_GAMMA" = true ] || return
    [ "$CURRENT_GAMMA" != "$LAST_APPLIED_GAMMA" ] || return

    # Acquire the transition lock to avoid conflicts with any other transition
    exec 10>"$TRANSITION_LOCKFILE" 2>/dev/null || return 1
    if ! flock -n 10; then
        exec 10>&-
        return 0
    fi

    local steps="$SMOOTH_DIM_TIME_STEPS"
    local interval="$SMOOTH_DIM_TIME_INTERVAL"

    IFS=':' read -r -a start_g <<< "${LAST_APPLIED_GAMMA:-1.0:1.0:1.0}"
    IFS=':' read -r -a target_g <<< "$CURRENT_GAMMA"

    local gamma_step_r gamma_step_g gamma_step_b
    gamma_step_r=$(echo "scale=6; (${target_g[0]} - ${start_g[0]}) / $steps" | bc 2>/dev/null || echo 0)
    gamma_step_g=$(echo "scale=6; (${target_g[1]} - ${start_g[1]}) / $steps" | bc 2>/dev/null || echo 0)
    gamma_step_b=$(echo "scale=6; (${target_g[2]} - ${start_g[2]}) / $steps" | bc 2>/dev/null || echo 0)

    for ((step=1; step<=steps; step++)); do
        local r g b
        r=$(echo "scale=6; ${start_g[0]} + ${gamma_step_r} * $step" | bc 2>/dev/null || echo "${target_g[0]}")
        g=$(echo "scale=6; ${start_g[1]} + ${gamma_step_g} * $step" | bc 2>/dev/null || echo "${target_g[1]}")
        b=$(echo "scale=6; ${start_g[2]} + ${gamma_step_b} * $step" | bc 2>/dev/null || echo "${target_g[2]}")

        local current_gamma="${r}:${g}:${b}"
        for MON in "${MONITORS[@]}"; do
            # Brightness stays at idle level; only gamma changes
            xrandr --output "$MON" --brightness "$IDLE_BRIGHTNESS" --gamma "$current_gamma" 2>/dev/null &
        done
        wait
        sleep "$interval"
    done

    # Final exact gamma
    for MON in "${MONITORS[@]}"; do
        xrandr --output "$MON" --brightness "$IDLE_BRIGHTNESS" --gamma "$CURRENT_GAMMA" 2>/dev/null &
    done
    wait

    LAST_APPLIED_GAMMA="$CURRENT_GAMMA"
    exec 10>&-
}

# Update time state – uses smooth gamma transition when idle
update_time_state() {
    local new_time_state

    if is_night; then
        new_time_state="night"
    else
        new_time_state="day"
    fi

    if [ "$new_time_state" != "$CURRENT_TIME_STATE" ]; then
        echo "Time state changing from $CURRENT_TIME_STATE to $new_time_state" >&2

        CURRENT_TIME_STATE="$new_time_state"

        if [ "$CURRENT_TIME_STATE" = "night" ]; then
            CURRENT_ACTIVE_BRIGHTNESS="$NIGHT_ACTIVE_BRIGHTNESS"
            CURRENT_DIM_BRIGHTNESS="$NIGHT_DIM_BRIGHTNESS"
            CURRENT_GAMMA="$NIGHT_GAMMA"
        else
            CURRENT_ACTIVE_BRIGHTNESS="$DAY_ACTIVE_BRIGHTNESS"
            CURRENT_DIM_BRIGHTNESS="$DAY_DIM_BRIGHTNESS"
            CURRENT_GAMMA="$DAY_GAMMA"
        fi

        if [ "$CURRENT_STATE" = "active" ]; then
            apply_time_transition
        else
            # Idle: smoothly fade just the gamma, brightness stays idle
            smooth_gamma_transition
        fi

        return 1
    fi

    return 0
}

# Get idle time (fallback already present)
get_idle_time() {
    if [ "$ENABLE_IDLE" = false ]; then
        echo "0"
        return 0
    fi

    local idle_ms=0
    local max_attempts=3

    for attempt in $(seq 1 $max_attempts); do
        idle_ms=$(xprintidle 2>/dev/null)

        if [ $? -eq 0 ] && [[ "$idle_ms" =~ ^[0-9]+$ ]]; then
            idle_seconds=$((idle_ms / 1000))

            # CRITICAL: Check if system just woke from sleep.
            if [ "$idle_seconds" -ge 300 ] && [ -f "/sys/power/resume_time" ]; then
                RESUME_TIME=$(cat "/sys/power/resume_time" 2>/dev/null || echo "0")
                if [ -n "$RESUME_TIME" ] && [ "$RESUME_TIME" != "0" ]; then
                    current_time=$(date +%s)
                    if [ $((current_time - RESUME_TIME)) -lt 30 ]; then
                        echo "0"
                        return 0
                    fi
                fi
            fi

            echo "$idle_seconds"
            return 0
        fi

        if [ $attempt -eq $max_attempts ]; then
            echo "0"
            return 1
        fi

        sleep 0.5
    done
}

# Get mouse position
get_mouse_position() {
    mouse_output=$(xdotool getmouselocation --shell 2>/dev/null || echo "X=0;Y=0")
    eval "$mouse_output" 2>/dev/null
}

# Parallel xrandr updates for mouse/idle modes (no gamma interpolation)
parallel_xrandr_brightness() {
    local brightness_args=()
    while [ $# -ge 2 ]; do
        brightness_args+=("$1" "$2")
        shift 2
    done

    local pids=()
    local idx=0

    while [ $idx -lt ${#brightness_args[@]} ]; do
        local mon="${brightness_args[$idx]}"
        local brightness="${brightness_args[$((idx+1))]}"

        if [ "$ENABLE_GAMMA" = true ]; then
            xrandr --output "$mon" --brightness "$brightness" \
                --gamma "$CURRENT_GAMMA" 2>/dev/null &
        else
            xrandr --output "$mon" --brightness "$brightness" 2>/dev/null &
        fi
        pids+=($!)
        idx=$((idx + 2))
    done

    wait "${pids[@]}" 2>/dev/null
}

# Apply gamma (instant) – now only used in initial setup / geometry changes
apply_gamma() {
    if [ "$ENABLE_GAMMA" != true ]; then
        return
    fi

    if [ "$CURRENT_GAMMA" = "$LAST_APPLIED_GAMMA" ]; then
        return
    fi

    local pids=()
    for MON in "${MONITORS[@]}"; do
        xrandr --output "$MON" --gamma "$CURRENT_GAMMA" 2>/dev/null &
        pids+=($!)
    done
    wait "${pids[@]}" 2>/dev/null

    LAST_APPLIED_GAMMA="$CURRENT_GAMMA"
    echo "Gamma set to: $CURRENT_GAMMA" >&2
}

# Apply minimum brightness (unchanged)
apply_minimum_brightness() {
    local target_brightness="$1"
    local current_state="$2"
    local is_dimmed="$3"

    if [ "$current_state" = "idle" ] || [ "$is_dimmed" = "true" ]; then
        echo "$target_brightness"
        return 0
    fi

    if [ "$(echo "$target_brightness < $MIN_BRIGHTNESS" \
        | bc -l 2>/dev/null)" -eq 1 ]; then
        echo "$MIN_BRIGHTNESS"
    else
        echo "$target_brightness"
    fi
}

# Smooth transition function (time mode interpolates gamma, idle gamma fade separate)
smooth_transition() {
    local mode="$1"  # "mouse", "idle", or "time"

    local steps interval instant
    case "$mode" in
        "mouse")
            steps="$SMOOTH_DIM_MOUSE_STEPS"
            interval="$SMOOTH_DIM_MOUSE_INTERVAL"
            instant="$INSTANT_MOUSE_DIM"
            ;;
        "idle")
            steps="$SMOOTH_DIM_IDLE_STEPS"
            interval="$SMOOTH_DIM_IDLE_INTERVAL"
            instant="$INSTANT_IDLE_DIM"
            ;;
        "time")
            steps="$SMOOTH_DIM_TIME_STEPS"
            interval="$SMOOTH_DIM_TIME_INTERVAL"
            instant="$INSTANT_TIME_DIM"
            ;;
        *)
            return 1
            ;;
    esac

    # --- Acquire transition lock ---
    exec 10>"$TRANSITION_LOCKFILE" 2>/dev/null || return 1
    if ! flock -n 10; then
        exec 10>&-
        return 0
    fi

    # For time mode, prepare gamma interpolation
    if [ "$mode" = "time" ] && [ "$ENABLE_GAMMA" = true ]; then
        IFS=':' read -r -a start_g <<< "$START_GAMMA"
        IFS=':' read -r -a target_g <<< "$TARGET_GAMMA"

        gamma_step_r=$(echo "scale=6; (${target_g[0]} - ${start_g[0]}) / $steps" | bc 2>/dev/null || echo 0)
        gamma_step_g=$(echo "scale=6; (${target_g[1]} - ${start_g[1]}) / $steps" | bc 2>/dev/null || echo 0)
        gamma_step_b=$(echo "scale=6; (${target_g[2]} - ${start_g[2]}) / $steps" | bc 2>/dev/null || echo 0)
    fi

    # Instant mode shortcut
    if [ "$instant" = true ]; then
        local brightness_args=()
        for MON in "${MONITORS[@]}"; do
            MON_CURRENT_BRIGHT["$MON"]="${MON_TARGET_BRIGHT[$MON]}"
            brightness_args+=("$MON" "${MON_TARGET_BRIGHT[$MON]}")
        done
        if [ "$mode" = "time" ] && [ "$ENABLE_GAMMA" = true ]; then
            parallel_xrandr_brightness "${brightness_args[@]}"
            apply_gamma
        else
            parallel_xrandr_brightness "${brightness_args[@]}"
        fi
        exec 10>&-
        return 0
    fi

    # Smooth transition
    START_BRIGHTNESS=()
    STEP_SIZES=()

    for MON in "${MONITORS[@]}"; do
        START_BRIGHTNESS["$MON"]="${MON_CURRENT_BRIGHT[$MON]}"
        local step_size
        step_size=$(echo "scale=6; (${MON_TARGET_BRIGHT[$MON]} - \
            ${START_BRIGHTNESS[$MON]}) / $steps" | bc 2>/dev/null || echo "0")
        STEP_SIZES["$MON"]="$step_size"
    done

    for ((step=1; step<=steps; step++)); do
        local brightness_args=()

        # Compute interpolated gamma for this step (only for time mode with gamma)
        local current_gamma=""
        if [ "$mode" = "time" ] && [ "$ENABLE_GAMMA" = true ]; then
            local r g b
            r=$(echo "scale=6; ${start_g[0]} + ${gamma_step_r} * $step" | bc 2>/dev/null || echo "${target_g[0]}")
            g=$(echo "scale=6; ${start_g[1]} + ${gamma_step_g} * $step" | bc 2>/dev/null || echo "${target_g[1]}")
            b=$(echo "scale=6; ${start_g[2]} + ${gamma_step_b} * $step" | bc 2>/dev/null || echo "${target_g[2]}")
            current_gamma="${r}:${g}:${b}"
        fi

        for MON in "${MONITORS[@]}"; do
            local current
            if [ "${STEP_SIZES[$MON]}" = "0" ]; then
                current="${MON_TARGET_BRIGHT[$MON]}"
            else
                current=$(echo "scale=6; ${START_BRIGHTNESS[$MON]} + \
                    ${STEP_SIZES[$MON]} * $step" | bc 2>/dev/null || \
                    echo "${MON_TARGET_BRIGHT[$MON]}")
            fi

            # Clamp according to mode
            if [ "$mode" = "idle" ]; then
                if [ "$(echo "$current < 0" | bc -l 2>/dev/null)" -eq 1 ]; then
                    current=0
                elif [ "$(echo "$current > 1" | bc -l 2>/dev/null)" -eq 1 ]; then
                    current=1
                fi
            else
                local is_dimmed=false
                if [ -f "$TOGGLE_FILE" ] && [ "$MON" != "$LAST_ACTIVE_MON" ] \
                    && [ -n "$LAST_ACTIVE_MON" ]; then
                    is_dimmed=true
                fi

                if [ "$is_dimmed" = "false" ] \
                    && [ "$(echo "$current < $MIN_BRIGHTNESS" \
                        | bc -l 2>/dev/null)" -eq 1 ]; then
                    current="$MIN_BRIGHTNESS"
                elif [ "$(echo "$current > 1" | bc -l 2>/dev/null)" -eq 1 ]; then
                    current=1
                fi
            fi

            MON_CURRENT_BRIGHT["$MON"]="$current"

            if [ "$mode" = "time" ] && [ "$ENABLE_GAMMA" = true ]; then
                xrandr --output "$MON" --brightness "$current" --gamma "$current_gamma" 2>/dev/null &
            else
                brightness_args+=("$MON" "$current")
            fi
        done

        if [ "$mode" != "time" ] || [ "$ENABLE_GAMMA" != true ]; then
            parallel_xrandr_brightness "${brightness_args[@]}"
        else
            wait
        fi

        sleep "$interval"
    done

    # Final exact values
    for MON in "${MONITORS[@]}"; do
        MON_CURRENT_BRIGHT["$MON"]="${MON_TARGET_BRIGHT[$MON]}"
    done

    if [ "$mode" = "time" ] && [ "$ENABLE_GAMMA" = true ]; then
        # Apply final gamma precisely
        for MON in "${MONITORS[@]}"; do
            xrandr --output "$MON" --brightness "${MON_TARGET_BRIGHT[$MON]}" \
                --gamma "$TARGET_GAMMA" 2>/dev/null &
        done
        wait
        LAST_APPLIED_GAMMA="$TARGET_GAMMA"
    else
        local final_brightness_args=()
        for MON in "${MONITORS[@]}"; do
            final_brightness_args+=("$MON" "${MON_TARGET_BRIGHT[$MON]}")
        done
        parallel_xrandr_brightness "${final_brightness_args[@]}"
    fi

    exec 10>&-
}

# Apply idle brightness (unchanged)
apply_idle_brightness() {
    for MON in "${MONITORS[@]}"; do
        MON_TARGET_BRIGHT["$MON"]="$IDLE_BRIGHTNESS"
    done
    smooth_transition "idle"
}

# Apply active (mouse‑based) brightness (unchanged)
apply_active_brightness() {
    if [ ! -f "$TOGGLE_FILE" ]; then
        local brightness_args=()
        for MON in "${MONITORS[@]}"; do
            MON_TARGET_BRIGHT["$MON"]="$CURRENT_ACTIVE_BRIGHTNESS"
            MON_CURRENT_BRIGHT["$MON"]="$CURRENT_ACTIVE_BRIGHTNESS"
            brightness_args+=("$MON" "$CURRENT_ACTIVE_BRIGHTNESS")
        done
        parallel_xrandr_brightness "${brightness_args[@]}"
        LAST_ACTIVE_MON=""
        return 0
    fi

    get_mouse_position

    local active_mon=""
    for MON in "${MONITORS[@]}"; do
        if [ "$X" -ge "${MON_X1[$MON]}" ] && [ "$X" -lt "${MON_X2[$MON]}" ] \
            && [ "$Y" -ge "${MON_Y1[$MON]}" ] && [ "$Y" -lt "${MON_Y2[$MON]}" ]; then
            active_mon="$MON"
            break
        fi
    done

    if [ -z "$active_mon" ] && [ ${#MONITORS[@]} -gt 0 ]; then
        active_mon="${MONITORS[0]}"
    fi

    local needs_update=false
    for MON in "${MONITORS[@]}"; do
        local is_dimmed=false
        local target

        if [ "$MON" = "$active_mon" ]; then
            target="$CURRENT_ACTIVE_BRIGHTNESS"
            is_dimmed=false
        else
            target="$CURRENT_DIM_BRIGHTNESS"
            is_dimmed=true
        fi

        target=$(apply_minimum_brightness "$target" "active" "$is_dimmed")

        local current_target="${MON_TARGET_BRIGHT[$MON]}"
        if [ "$(echo "$current_target != $target" | bc -l 2>/dev/null)" -eq 1 ]; then
            MON_TARGET_BRIGHT["$MON"]="$target"
            needs_update=true
        fi
    done

    if [ "$needs_update" = true ]; then
        smooth_transition "mouse"
    fi

    LAST_ACTIVE_MON="$active_mon"
}

# Time‑based transition – now passes gamma start/target to smooth_transition
apply_time_transition() {
    if [ ! -f "$TOGGLE_FILE" ]; then
        for MON in "${MONITORS[@]}"; do
            MON_TARGET_BRIGHT["$MON"]="$CURRENT_ACTIVE_BRIGHTNESS"
        done
    else
        local active_mon="$LAST_ACTIVE_MON"
        if [ -z "$active_mon" ] && [ ${#MONITORS[@]} -gt 0 ]; then
            active_mon="${MONITORS[0]}"
        fi
        for MON in "${MONITORS[@]}"; do
            local target is_dimmed=false
            if [ "$MON" = "$active_mon" ]; then
                target="$CURRENT_ACTIVE_BRIGHTNESS"
            else
                target="$CURRENT_DIM_BRIGHTNESS"
                is_dimmed=true
            fi
            target=$(apply_minimum_brightness "$target" "active" "$is_dimmed")
            MON_TARGET_BRIGHT["$MON"]="$target"
        done
    fi

    # Gamma: start from last applied, target is CURRENT_GAMMA
    START_GAMMA="${LAST_APPLIED_GAMMA:-$CURRENT_GAMMA}"
    TARGET_GAMMA="$CURRENT_GAMMA"

    smooth_transition "time"
}

# -----------------------------
# INITIALIZATION
# -----------------------------

for cmd in xrandr xdotool bc; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is required but not installed" >&2
        exit 1
    fi
done

if [ "$ENABLE_IDLE" = true ] && ! command -v xprintidle &> /dev/null; then
    echo "Warning: xprintidle not found. Idle dimming will be disabled." >&2
    ENABLE_IDLE=false
fi

XRANDR_LIST=$(xrandr --listmonitors 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$XRANDR_LIST" ]; then
    echo "Error: Failed to get monitor list from xrandr" >&2
    exit 1
fi

if is_night; then
    CURRENT_TIME_STATE="night"
    CURRENT_ACTIVE_BRIGHTNESS="$NIGHT_ACTIVE_BRIGHTNESS"
    CURRENT_DIM_BRIGHTNESS="$NIGHT_DIM_BRIGHTNESS"
    CURRENT_GAMMA="$NIGHT_GAMMA"
else
    CURRENT_TIME_STATE="day"
    CURRENT_ACTIVE_BRIGHTNESS="$DAY_ACTIVE_BRIGHTNESS"
    CURRENT_DIM_BRIGHTNESS="$DAY_DIM_BRIGHTNESS"
    CURRENT_GAMMA="$DAY_GAMMA"
fi

read_monitors
GEOM_HASH="$(echo "$XRANDR_LIST" | sha1sum | awk '{print $1}')"

# Apply initial gamma (forces setting LAST_APPLIED_GAMMA)
apply_gamma

# Force initial brightness and gamma (fix for single/multi monitor startup)
for MON in "${MONITORS[@]}"; do
    if [ "$ENABLE_GAMMA" = true ]; then
        xrandr --output "$MON" --brightness "${MON_TARGET_BRIGHT[$MON]}" \
               --gamma "$CURRENT_GAMMA" 2>/dev/null &
    else
        xrandr --output "$MON" --brightness "${MON_TARGET_BRIGHT[$MON]}" 2>/dev/null &
    fi
done
wait

EFFECTIVE_TIMEOUT="$IDLE_TIMEOUT"
if [ "$IDLE_TIMEOUT" -eq 0 ]; then
    EFFECTIVE_TIMEOUT=1
fi

# Print configuration
echo "Enhanced Mouse-Based Dimming with Idle & Time-Based Support" >&2
echo "=========================================================" >&2
echo "Day settings:" >&2
echo "  Active brightness: $DAY_ACTIVE_BRIGHTNESS" >&2
echo "  Dim brightness: $DAY_DIM_BRIGHTNESS" >&2
echo "  Gamma: $DAY_GAMMA" >&2
echo "Night settings:" >&2
echo "  Active brightness: $NIGHT_ACTIVE_BRIGHTNESS" >&2
echo "  Dim brightness: $NIGHT_DIM_BRIGHTNESS" >&2
echo "  Gamma: $NIGHT_GAMMA" >&2
echo "" >&2
echo "Time windows: Day starts at ${DAY_START:0:2}:${DAY_START:2:2}, \
Night starts at ${NIGHT_START:0:2}:${NIGHT_START:2:2}" >&2
echo "Current time state: $CURRENT_TIME_STATE" >&2
echo "Gamma enabled: $ENABLE_GAMMA" >&2
echo "" >&2
echo "Idle brightness: $IDLE_BRIGHTNESS" >&2
echo "Idle timeout: ${IDLE_TIMEOUT}s (effective: ${EFFECTIVE_TIMEOUT}s)" >&2
echo "Idle enabled: $ENABLE_IDLE" >&2
echo "Idle toggle file: $IDLE_TOGGLE_FILE" >&2
echo -n "Idle toggle state: " >&2
if [ -f "$IDLE_TOGGLE_FILE" ]; then
    echo "OFF (file exists = disabled)" >&2
else
    echo "ON (no file = enabled)" >&2
fi
echo "" >&2
echo "Mouse transition: ${SMOOTH_DIM_MOUSE_STEPS} steps, \
${SMOOTH_DIM_MOUSE_INTERVAL}s interval" >&2
echo "Mouse instant: $INSTANT_MOUSE_DIM" >&2
echo "Idle transition: ${SMOOTH_DIM_IDLE_STEPS} steps, \
${SMOOTH_DIM_IDLE_INTERVAL}s interval" >&2
echo "Idle instant: $INSTANT_IDLE_DIM" >&2
echo "Time transition: ${SMOOTH_DIM_TIME_STEPS} steps, \
${SMOOTH_DIM_TIME_INTERVAL}s interval" >&2
echo "Time instant: $INSTANT_TIME_DIM" >&2
echo "" >&2
echo "Toggle file: $TOGGLE_FILE" >&2
echo -n "Mouse toggle state: " >&2
if [ -f "$TOGGLE_FILE" ]; then
    echo "ON (per-monitor dimming)" >&2
else
    echo "OFF (all monitors active)" >&2
fi
echo "" >&2
echo "Parallel updates: ENABLED" >&2
echo "Hidden safety minimum: ${MIN_BRIGHTNESS} (active monitors only)" >&2
echo "Note: Mouse-aware and idle dim can be set to 0" >&2
echo "" >&2

# -----------------------------
# MAIN LOOP
# -----------------------------
while true; do
    NOW=$(date +%s)

    if (( NOW - LAST_TIME_CHECK >= TIME_CHECK_INTERVAL )); then
        LAST_TIME_CHECK=$NOW
        if ! update_time_state; then
            echo "Time state changed to $CURRENT_TIME_STATE" >&2
        fi
    fi

    if (( NOW - LAST_GEOM_CHECK >= GEOM_INTERVAL )); then
        LAST_GEOM_CHECK=$NOW
        XRANDR_LIST=$(xrandr --listmonitors 2>/dev/null)
        if [ $? -eq 0 ]; then
            NEW_HASH="$(echo "$XRANDR_LIST" | sha1sum | awk '{print $1}')"
            if [ "$NEW_HASH" != "$GEOM_HASH" ]; then
                GEOM_HASH="$NEW_HASH"
                GEOM_DIRTY=1
                read_monitors
                apply_gamma
                case "$CURRENT_STATE" in
                    "active")
                        apply_active_brightness
                        ;;
                    "idle")
                        apply_idle_brightness
                        ;;
                esac
                echo "Monitor configuration changed" >&2
            fi
        fi
    fi

    if [ "$GEOM_DIRTY" -eq 1 ]; then
        GEOM_DIRTY=0
        continue
    fi

    if (( NOW - LAST_IDLE_CHECK >= IDLE_CHECK_INTERVAL )); then
        LAST_IDLE_CHECK=$NOW

        if [ "$ENABLE_IDLE" = true ] && [ ! -f "$IDLE_TOGGLE_FILE" ]; then
            idle_time=$(get_idle_time)

            effective_timeout="$IDLE_TIMEOUT"
            if [ -z "$effective_timeout" ] || [ "${effective_timeout:-0}" -eq 0 ]; then
                effective_timeout=1
            fi

            case "$CURRENT_STATE" in
                "active")
                    if [ -n "$idle_time" ] && [ "$idle_time" -ge "$effective_timeout" ]; then
                        echo "Entering idle state (idle for ${idle_time}s)" >&2
                        CURRENT_STATE="idle"
                        LAST_ACTIVITY_TIME=$((NOW - idle_time))
                    fi
                    ;;
                "idle")
                    if [ -n "$idle_time" ] && [ "$idle_time" -lt "$effective_timeout" ]; then
                        echo "Waking from idle (idle for ${idle_time}s)" >&2
                        CURRENT_STATE="active"
                        LAST_ACTIVITY_TIME=$NOW
                    fi
                    ;;
            esac
        else
            CURRENT_STATE="active"
        fi
    fi

    case "$CURRENT_STATE" in
        "active")
            apply_active_brightness
            ;;
        "idle")
            apply_idle_brightness
            ;;
    esac

    sleep "$MOUSE_INTERVAL"
done
