#!/bin/bash
# -----------------------------
# Enhanced Mouse-Based Per-Monitor Dimming with Idle & Time-Based Support
# -----------------------------
# Requires: xrandr, xdotool, xprintidle, bc
# -----------------------------

# -----------------------------
# USER CONFIG
# -----------------------------

# Day/Night brightness levels
DAY_ACTIVE_BRIGHTNESS=0.7
DAY_DIM_BRIGHTNESS=0.3
NIGHT_ACTIVE_BRIGHTNESS=0.5
NIGHT_DIM_BRIGHTNESS=0.2
IDLE_BRIGHTNESS=0.1

# Time window (24h, HHMM format)
NIGHT_START=1700   # 17:00 PM
DAY_START=0700     # 07:00 AM

# Gamma control (optional)
ENABLE_GAMMA=false
DAY_GAMMA="1.0:1.0:1.0"
NIGHT_GAMMA="1.0:0.85:0.1"

# Idle settings
IDLE_TIMEOUT=1           # Seconds of inactivity before idle dim
ENABLE_IDLE=true         # Set to false to disable idle dimming entirely

# Smooth transition settings - MOUSE DIM
SMOOTH_DIM_MOUSE_STEPS=10      # Steps for mouse-based dimming transitions
SMOOTH_DIM_MOUSE_INTERVAL=0.02 # Seconds between steps for mouse dimming
INSTANT_MOUSE_DIM=true         # Override smooth dimming with instant for mouse

# Smooth transition settings - IDLE DIM
SMOOTH_DIM_IDLE_STEPS=10       # Steps for idle dimming transitions
SMOOTH_DIM_IDLE_INTERVAL=0.02  # Seconds between steps for idle dimming
INSTANT_IDLE_DIM=true          # Override smooth dimming with instant for idle

# Toggle files
TOGGLE_FILE="$HOME/.fade_mouse_enabled"
IDLE_TOGGLE_FILE="$HOME/.idle_dim_enabled"

# Poll intervals
MOUSE_INTERVAL=0.1          # Mouse polling (10 times/sec)
IDLE_CHECK_INTERVAL=1       # Idle check interval (every 1 second)
GEOM_INTERVAL=2             # Monitor geometry check interval
TIME_CHECK_INTERVAL=30      # Time state check interval (every 30 seconds)

# -----------------------------
# SINGLE-INSTANCE LOCK
# -----------------------------
LOCKFILE="$HOME/.fade_mouse.lock"
exec 9>"$LOCKFILE" || exit 1
flock -n 9 || exit 0

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
CURRENT_STATE="active"        # "active" or "idle"
CURRENT_TIME_STATE="day"      # "day" or "night"
CURRENT_ACTIVE_BRIGHTNESS="$DAY_ACTIVE_BRIGHTNESS"
CURRENT_DIM_BRIGHTNESS="$DAY_DIM_BRIGHTNESS"
CURRENT_GAMMA="$DAY_GAMMA"
LAST_ACTIVE_MON=""
TRANSITION_IN_PROGRESS=false
LAST_ACTIVITY_TIME=$(date +%s)

# ============================================
# HIDDEN SAFETY MINIMUM -
# ============================================
# Minimum brightness for all states except idle
# Idle brightness (IDLE_BRIGHTNESS) is exempt from this minimum
# This ensures screens never go completely black during active use
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

# Read monitor geometry
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
        if [[ $line =~ \
([0-9]+:[[:space:]]+[\+\*]*)([A-Za-z0-9-]+)[[:space:]]+([0-9]+)\/[0-9]+x([0-9]+)\/[0-9]+\+([0-9]+)\+([0-9]+) \
        ]]; then
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
            if [ "$(echo "$initial_brightness < $MIN_BRIGHTNESS" | bc -l 2>/dev/null)" -eq 1 ]; then
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

        # Apply gamma change immediately if enabled
        if [ "$ENABLE_GAMMA" = true ]; then
            for MON in "${MONITORS[@]}"; do
                xrandr --output "$MON" --gamma "$CURRENT_GAMMA" 2>/dev/null &
            done
            wait
            echo "Gamma set to: $CURRENT_GAMMA" >&2
        fi

        # Trigger brightness update on next cycle
        return 1
    fi

    return 0
}

# Get idle time with robust error handling
get_idle_time() {
    if [ "$ENABLE_IDLE" = false ]; then
        echo "0"
        return 0
    fi

    # Check for disable file (inverted logic - file exists means idle is OFF)
    if [ -f "$IDLE_TOGGLE_FILE" ]; then
        echo "0"
        return 0
    fi

    local idle_ms=0
    local max_attempts=3

    # Try multiple times with increasing backoff
    for attempt in $(seq 1 $max_attempts); do
        idle_ms=$(xprintidle 2>/dev/null)

        if [ $? -eq 0 ] && [[ "$idle_ms" =~ ^[0-9]+$ ]]; then
            echo "$((idle_ms / 1000))"
            return 0
        fi

        # If it's the last attempt, return 0 (assume active)
        if [ $attempt -eq $max_attempts ]; then
            echo "0"
            return 1
        fi

        # Wait before retry
        sleep 0.1
    done
}

# Get mouse position
get_mouse_position() {
    mouse_output=$(xdotool getmouselocation --shell 2>/dev/null || echo "X=0;Y=0")
    eval "$mouse_output" 2>/dev/null
}

# Parallel xrandr updates for performance (with gamma support)
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

# Apply gamma to all monitors
apply_gamma() {
    if [ "$ENABLE_GAMMA" = true ]; then
        local pids=()
        for MON in "${MONITORS[@]}"; do
            xrandr --output "$MON" --gamma "$CURRENT_GAMMA" 2>/dev/null &
            pids+=($!)
        done
        wait "${pids[@]}" 2>/dev/null
    fi
}

# Apply minimum brightness constraint (except for idle)
apply_minimum_brightness() {
    local target_brightness="$1"
    local current_state="$2"  # "active" or "idle"
    
    # Don't apply minimum to idle state
    if [ "$current_state" = "idle" ]; then
        echo "$target_brightness"
        return 0
    fi
    
    # Apply minimum to active/dim states
    if [ "$(echo "$target_brightness < $MIN_BRIGHTNESS" | bc -l 2>/dev/null)" -eq 1 ]; then
        echo "$MIN_BRIGHTNESS"
    else
        echo "$target_brightness"
    fi
}

# Smooth transition function
smooth_transition() {
    local mode="$1"  # "mouse" or "idle"
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
        *)
            return 1
            ;;
    esac

    # Instant mode
    if [ "$instant" = true ]; then
        local brightness_args=()
        for MON in "${MONITORS[@]}"; do
            MON_CURRENT_BRIGHT["$MON"]="${MON_TARGET_BRIGHT[$MON]}"
            brightness_args+=("$MON" "${MON_TARGET_BRIGHT[$MON]}")
        done
        parallel_xrandr_brightness "${brightness_args[@]}"
        return 0
    fi

    # Smooth transition
    TRANSITION_IN_PROGRESS=true

    # Calculate start values and step sizes for each monitor
    START_BRIGHTNESS=()
    STEP_SIZES=()

    for MON in "${MONITORS[@]}"; do
        START_BRIGHTNESS["$MON"]="${MON_CURRENT_BRIGHT[$MON]}"
        local step_size
        step_size=$(echo "scale=6; (${MON_TARGET_BRIGHT[$MON]} - \
            ${START_BRIGHTNESS[$MON]}) / $steps" | bc 2>/dev/null || echo "0")
        STEP_SIZES["$MON"]="$step_size"
    done

    # Perform smooth transition
    for ((step=1; step<=steps; step++)); do
        local brightness_args=()

        for MON in "${MONITORS[@]}"; do
            local current
            if [ "${STEP_SIZES[$MON]}" = "0" ]; then
                current="${MON_TARGET_BRIGHT[$MON]}"
            else
                current=$(echo "scale=6; ${START_BRIGHTNESS[$MON]} + \
                    ${STEP_SIZES[$MON]} * $step" | bc 2>/dev/null || \
                    echo "${MON_TARGET_BRIGHT[$MON]}")
            fi

            # Clamp between appropriate limits based on mode
            if [ "$mode" = "idle" ]; then
                # For idle: only clamp to 0-1
                if [ "$(echo "$current < 0" | bc -l 2>/dev/null)" -eq 1 ]; then
                    current=0
                elif [ "$(echo "$current > 1" | bc -l 2>/dev/null)" -eq 1 ]; then
                    current=1
                fi
            else
                # For mouse/active: apply minimum brightness
                if [ "$(echo "$current < $MIN_BRIGHTNESS" | bc -l 2>/dev/null)" -eq 1 ]; then
                    current="$MIN_BRIGHTNESS"
                elif [ "$(echo "$current > 1" | bc -l 2>/dev/null)" -eq 1 ]; then
                    current=1
                fi
            fi

            MON_CURRENT_BRIGHT["$MON"]="$current"
            brightness_args+=("$MON" "$current")
        done

        parallel_xrandr_brightness "${brightness_args[@]}"
        sleep "$interval"
    done

    # Ensure final exact targets
    for MON in "${MONITORS[@]}"; do
        MON_CURRENT_BRIGHT["$MON"]="${MON_TARGET_BRIGHT[$MON]}"
    done

    local final_brightness_args=()
    for MON in "${MONITORS[@]}"; do
        final_brightness_args+=("$MON" "${MON_TARGET_BRIGHT[$MON]}")
    done
    parallel_xrandr_brightness "${final_brightness_args[@]}"

    TRANSITION_IN_PROGRESS=false
}

# Apply idle brightness
apply_idle_brightness() {
    # Set target brightness for idle state (all monitors same)
    for MON in "${MONITORS[@]}"; do
        # IDLE_BRIGHTNESS is exempt from minimum constraint
        MON_TARGET_BRIGHT["$MON"]="$IDLE_BRIGHTNESS"
    done

    # Apply smooth transition
    if [ "$TRANSITION_IN_PROGRESS" = false ]; then
        smooth_transition "idle"
    fi
}

# Apply active (mouse-based) brightness
apply_active_brightness() {
    # Get mouse position
    get_mouse_position

    # Find active monitor
    local active_mon=""
    for MON in "${MONITORS[@]}"; do
        if [ "$X" -ge "${MON_X1[$MON]}" ] && [ "$X" -lt "${MON_X2[$MON]}" ] &&
           [ "$Y" -ge "${MON_Y1[$MON]}" ] && [ "$Y" -lt "${MON_Y2[$MON]}" ]; then
            active_mon="$MON"
            break
        fi
    done

    # If no active monitor found, default to first monitor
    if [ -z "$active_mon" ] && [ ${#MONITORS[@]} -gt 0 ]; then
        active_mon="${MONITORS[0]}"
    fi

    # Check toggle state
    local toggle_state=false
    if [ -f "$TOGGLE_FILE" ]; then
        toggle_state=true
    fi

    # Set targets for each monitor
    local needs_update=false
    for MON in "${MONITORS[@]}"; do
        if [ "$toggle_state" = true ]; then
            if [ "$MON" = "$active_mon" ]; then
                local target="$CURRENT_ACTIVE_BRIGHTNESS"
            else
                local target="$CURRENT_DIM_BRIGHTNESS"
            fi
        else
            # Toggle is OFF - all monitors get current active brightness
            local target="$CURRENT_ACTIVE_BRIGHTNESS"
        fi

        # Apply minimum brightness constraint (except for idle, but we're in active state)
        target=$(apply_minimum_brightness "$target" "active")

        # Check if target changed
        local current_target="${MON_TARGET_BRIGHT[$MON]}"
        if [ "$(echo "$current_target != $target" | bc -l 2>/dev/null)" -eq 1 ]; then
            MON_TARGET_BRIGHT["$MON"]="$target"
            needs_update=true
        fi
    done

    # Apply transition if needed
    if [ "$needs_update" = true ] && [ "$TRANSITION_IN_PROGRESS" = false ]; then
        smooth_transition "mouse"
    fi

    # Update tracking
    LAST_ACTIVE_MON="$active_mon"
}

# -----------------------------
# INITIALIZATION
# -----------------------------

# Check for required commands
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

# Initialize monitor data
XRANDR_LIST=$(xrandr --listmonitors 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$XRANDR_LIST" ]; then
    echo "Error: Failed to get monitor list from xrandr" >&2
    exit 1
fi

# Set initial time state
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

# Apply initial gamma
apply_gamma

# Calculate effective timeout for display (0 becomes 1)
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
echo "Idle toggle state: $([ -f "$IDLE_TOGGLE_FILE" ] && \
echo "OFF (file exists = disabled)" || echo "ON (no file = enabled)")" >&2
echo "" >&2
echo "Mouse transition: ${SMOOTH_DIM_MOUSE_STEPS} steps, \
${SMOOTH_DIM_MOUSE_INTERVAL}s interval" >&2
echo "Mouse instant: $INSTANT_MOUSE_DIM" >&2
echo "Idle transition: ${SMOOTH_DIM_IDLE_STEPS} steps, \
${SMOOTH_DIM_IDLE_INTERVAL}s interval" >&2
echo "Idle instant: $INSTANT_IDLE_DIM" >&2
echo "" >&2
echo "Toggle file: $TOGGLE_FILE" >&2
echo "Mouse toggle state: $([ -f "$TOGGLE_FILE" ] && \
echo "ON (per-monitor dimming)" || echo "OFF (all monitors active)")" >&2
echo "" >&2
echo "Parallel updates: ENABLED" >&2
echo "Hidden safety minimum: ${MIN_BRIGHTNESS} (active/dim states only)" >&2
echo "" >&2

# -----------------------------
# MAIN LOOP
# -----------------------------
while true; do
    NOW=$(date +%s)

    # -------- Time state check --------
    if (( NOW - LAST_TIME_CHECK >= TIME_CHECK_INTERVAL )); then
        LAST_TIME_CHECK=$NOW

        # Update time state - if it changed, we need to update brightness
        if ! update_time_state; then
            # Time state changed, force brightness update on next cycle
            echo "Time state changed to $CURRENT_TIME_STATE" >&2
        fi
    fi

    # -------- Geometry check --------
    if (( NOW - LAST_GEOM_CHECK >= GEOM_INTERVAL )); then
        LAST_GEOM_CHECK=$NOW
        XRANDR_LIST=$(xrandr --listmonitors 2>/dev/null)
        if [ $? -eq 0 ]; then
            NEW_HASH="$(echo "$XRANDR_LIST" | sha1sum | awk '{print $1}')"
            if [ "$NEW_HASH" != "$GEOM_HASH" ]; then
                GEOM_HASH="$NEW_HASH"
                GEOM_DIRTY=1
                read_monitors
                # Reapply gamma after geometry change
                apply_gamma
                echo "Monitor configuration changed" >&2
            fi
        fi
    fi

    # Skip brightness work while geometry just changed
    if [ "$GEOM_DIRTY" -eq 1 ]; then
        GEOM_DIRTY=0
        continue
    fi

    # -------- Idle check --------
    if (( NOW - LAST_IDLE_CHECK >= IDLE_CHECK_INTERVAL )); then
        LAST_IDLE_CHECK=$NOW

        if [ "$ENABLE_IDLE" = true ]; then
            idle_time=$(get_idle_time)

            # Calculate effective timeout (0 becomes 1) with proper integer handling
            effective_timeout="$IDLE_TIMEOUT"
            # Fix for integer expression error: ensure variable is not empty
            if [ -z "$effective_timeout" ] || [ "${effective_timeout:-0}" -eq 0 ]; then
                effective_timeout=1
            fi

            # State transitions - ensure variables are numeric and not empty
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
            # Force active state if idle is disabled
            CURRENT_STATE="active"
        fi
    fi

    # -------- Apply brightness based on state --------
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
