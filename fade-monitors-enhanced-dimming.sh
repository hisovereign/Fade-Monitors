#!/bin/bash
# -----------------------------
# Professional Enhanced Dimming
# Optimized for minimal latency
# -----------------------------
# Requires: xrandr, xdotool, xprintidle, bc
# -----------------------------

# -----------------------------
# USER CONFIG
# -----------------------------

# Brightness levels
ACTIVE_BRIGHTNESS=0.7
DIM_BRIGHTNESS=0.2
IDLE_BRIGHTNESS=0.0

# Idle settings
IDLE_TIMEOUT=5
IDLE_ENABLED=true

# Dimming transitions
INSTANT_DIM=false
SMOOTH_DIM_STEPS=10
SMOOTH_DIM_INTERVAL=0.02

# Wake-up transitions
INSTANT_WAKE=true           # Default to instant for responsiveness
SMOOTH_WAKE_STEPS=10
SMOOTH_WAKE_INTERVAL=0.02

# Performance tuning
XRR_MIN_INTERVAL=0.010      # Minimum 10ms between xrandr calls
ADAPTIVE_TIMING=false       # Set to false to simplify

# Toggle file
TOGGLE_FILE="$HOME/.fade_mouse_enabled"

# Stop file
STOP_FILE="$HOME/.fade_mouse_stopped"

# Poll intervals (seconds)
MOUSE_INTERVAL=0.1
GEOM_INTERVAL=5

# Logging (set to true for debugging)
ENABLE_LOGGING=false
LOG_FILE="/tmp/fade_monitors.log"

# -----------------------------
# PERFORMANCE-OPTIMIZED CORE
# -----------------------------

# Fast floating point comparison
float_eq() {
    awk -v a="$1" -v b="$2" -v tol="0.001" '
        BEGIN {
            diff = a - b
            if (diff < 0) diff = -diff
            exit (diff >= tol)
        }
    ' 2>/dev/null
}

# Parallel xrandr execution
parallel_xrandr() {
    local brightness="$1"
    local pids=()
    local monitor
    
    for monitor in "${MONITORS[@]}"; do
        xrandr --output "$monitor" --brightness "$brightness" 2>/dev/null &
        pids+=($!)
    done
    
    wait "${pids[@]}" 2>/dev/null
}

# -----------------------------
# SINGLE-INSTANCE LOCK
# -----------------------------
LOCKFILE="$HOME/.fade_mouse.lock"
exec 9>"$LOCKFILE" || exit 1
flock -n 9 || exit 0

# -----------------------------
# Internal state
# -----------------------------
declare -A MON_X1 MON_X2 MON_Y1 MON_Y2
declare -A MON_TARGET_BRIGHT MON_CURRENT_BRIGHT
MONITORS=()

GEOM_HASH=""
LAST_GEOM_CHECK=0
LAST_IDLE_CHECK=0
GEOM_DIRTY=0

CURRENT_STATE="active"
LAST_ACTIVE_MON=""
LAST_ACTIVITY_TIME=0
TOGGLE_STATE=false

LAST_X=-1
LAST_Y=-1

TRANSITION_IN_PROGRESS=false
TRANSITION_START_TIME=0

# Cache for mouse position
CACHED_X=0
CACHED_Y=0
CACHE_TIME=0

# -----------------------------
# DEPENDENCY CHECK
# -----------------------------
check_dependencies() {
    local deps=("xrandr" "xdotool" "bc")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing dependencies: ${missing[*]}" >&2
        exit 1
    fi
    
    if [ "$IDLE_ENABLED" = true ] && ! command -v xprintidle &> /dev/null; then
        echo "xprintidle not found, disabling idle detection" >&2
        IDLE_ENABLED=false
    fi
}

check_dependencies

# -----------------------------
# CLEANUP
# -----------------------------
cleanup() {
    for MON in "${MONITORS[@]}"; do
        xrandr --output "$MON" --brightness 1.0 2>/dev/null
    done
    flock -u 9
    exit 0
}

trap cleanup EXIT SIGINT SIGTERM

# -----------------------------
# GEOMETRY FUNCTIONS
# -----------------------------
read_monitors() {
    MONITORS=()
    
    while IFS= read -r line; do
        if [[ $line =~ ([0-9]+:[[:space:]]+[\+\*]*)([A-Za-z0-9-]+)[[:space:]]+([0-9]+)/[0-9]+x([0-9]+)/[0-9]+\+([0-9]+)\+([0-9]+) ]]; then
            local name="${BASH_REMATCH[2]}"
            local width="${BASH_REMATCH[3]}"
            local height="${BASH_REMATCH[4]}"
            local x_off="${BASH_REMATCH[5]}"
            local y_off="${BASH_REMATCH[6]}"
            
            MONITORS+=("$name")
            MON_X1["$name"]=$x_off
            MON_Y1["$name"]=$y_off
            MON_X2["$name"]=$((x_off + width))
            MON_Y2["$name"]=$((y_off + height))
        fi
    done < <(xrandr --listmonitors 2>/dev/null | tail -n +2)
    
    if [ ${#MONITORS[@]} -eq 0 ]; then
        echo "No monitors found" >&2
        return 1
    fi
    return 0
}

# -----------------------------
# SIMULTANEOUS TRANSITION
# -----------------------------
transition_all() {
    local mode="$1"
    local steps interval instant
    
    case "$mode" in
        "dim") 
            steps="$SMOOTH_DIM_STEPS"
            interval="$SMOOTH_DIM_INTERVAL"
            instant="$INSTANT_DIM"
            ;;
        "wake") 
            steps="$SMOOTH_WAKE_STEPS"
            interval="$SMOOTH_WAKE_INTERVAL"
            instant="$INSTANT_WAKE"
            ;;
        *) 
            return 1 
            ;;
    esac
    
    # Instant mode
    if [ "$instant" = true ]; then
        for MON in "${MONITORS[@]}"; do
            MON_CURRENT_BRIGHT["$MON"]="${MON_TARGET_BRIGHT[$MON]}"
        done
        first_mon="${MONITORS[0]}"
        target_bright="${MON_TARGET_BRIGHT[$first_mon]}"
        parallel_xrandr "$target_bright"
        return 0
    fi
    
    # Smooth transition
    TRANSITION_IN_PROGRESS=true
    TRANSITION_START_TIME=$(date +%s.%N 2>/dev/null)
    
    # Calculate start and target arrays
    local -a start_values target_values step_values
    local i=0
    
    for MON in "${MONITORS[@]}"; do
        start_values[i]="${MON_CURRENT_BRIGHT[$MON]:-1.0}"
        target_values[i]="${MON_TARGET_BRIGHT[$MON]:-1.0}"
        step_values[i]=$(echo "scale=6; (${target_values[i]} - ${start_values[i]}) / $steps" | bc 2>/dev/null)
        i=$((i + 1))
    done
    
    # Main transition loop
    for ((step=1; step<=steps; step++)); do
        # Check for stop file
        if [ -f "$STOP_FILE" ]; then
            break
        fi
        
        # Calculate current brightness for all monitors
        brightness_to_set=""
        for ((i=0; i<${#MONITORS[@]}; i++)); do
            current=$(echo "scale=6; ${start_values[i]} + ${step_values[i]} * $step" | bc 2>/dev/null)
            
            # Clamp between 0 and 1
            if [ "$(echo "$current < 0" | bc -l 2>/dev/null)" -eq 1 ]; then
                current=0
            elif [ "$(echo "$current > 1" | bc -l 2>/dev/null)" -eq 1 ]; then
                current=1
            fi
            
            MON_CURRENT_BRIGHT["${MONITORS[i]}"]="$current"
            
            if [ -z "$brightness_to_set" ]; then
                brightness_to_set="$current"
            fi
        done
        
        # Apply in parallel
        parallel_xrandr "$brightness_to_set"
        
        # Sleep for interval
        sleep "$interval"
    done
    
    # Final exact values
    for ((i=0; i<${#MONITORS[@]}; i++)); do
        MON_CURRENT_BRIGHT["${MONITORS[i]}"]="${target_values[i]}"
    done
    
    # Apply final brightness
    first_mon="${MONITORS[0]}"
    final_bright="${target_values[0]}"
    parallel_xrandr "$final_bright"
    
    TRANSITION_IN_PROGRESS=false
}

# -----------------------------
# ACTIVITY DETECTION
# -----------------------------
get_idle_time() {
    if [ "$IDLE_ENABLED" = false ]; then
        echo "0"
        return 0
    fi
    
    idle_ms=$(xprintidle 2>/dev/null || echo "0")
    echo "$((idle_ms / 1000))"
}

get_mouse_position() {
    now=$(date +%s.%N 2>/dev/null)
    
    # Use cache if recent (50ms)
    if [ -n "$now" ] && [ -n "$CACHE_TIME" ]; then
        if [ "$(echo "$now - $CACHE_TIME < 0.05" | bc -l 2>/dev/null)" -eq 1 ]; then
            X=$CACHED_X
            Y=$CACHED_Y
            return
        fi
    fi
    
    # Get fresh position
    mouse_output=$(xdotool getmouselocation --shell 2>/dev/null)
    if [ -n "$mouse_output" ]; then
        eval "$mouse_output" 2>/dev/null
        CACHED_X=$X
        CACHED_Y=$Y
        CACHE_TIME=$now
    else
        X=0
        Y=0
    fi
}

# -----------------------------
# BRIGHTNESS LOGIC FUNCTIONS
# -----------------------------
apply_idle_brightness() {
    # Set target brightness for idle state
    for MON in "${MONITORS[@]}"; do
        MON_TARGET_BRIGHT["$MON"]="$IDLE_BRIGHTNESS"
    done
    
    # Apply the transition
    transition_all "dim"
}

apply_active_brightness() {
    # Get mouse position
    get_mouse_position
    
    # Find active monitor
    active_mon=""
    toggle_state=false
    
    if [ -f "$TOGGLE_FILE" ]; then
        toggle_state=true
    fi
    
    for MON in "${MONITORS[@]}"; do
        if [ "$X" -ge "${MON_X1[$MON]}" ] && [ "$X" -lt "${MON_X2[$MON]}" ] &&
           [ "$Y" -ge "${MON_Y1[$MON]}" ] && [ "$Y" -lt "${MON_Y2[$MON]}" ]; then
            active_mon="$MON"
            break
        fi
    done
    
    # Set targets for each monitor
    needs_update=false
    for MON in "${MONITORS[@]}"; do
        target="$ACTIVE_BRIGHTNESS"
        if [ "$toggle_state" = true ] && [ "$MON" != "$active_mon" ]; then
            target="$DIM_BRIGHTNESS"
        fi
        
        # Check if target changed
        current_target="${MON_TARGET_BRIGHT[$MON]:-1.0}"
        if ! float_eq "$current_target" "$target"; then
            MON_TARGET_BRIGHT["$MON"]="$target"
            needs_update=true
        fi
    done
    
    # Apply transition if needed
    if [ "$needs_update" = true ] && [ "$TRANSITION_IN_PROGRESS" = false ]; then
        mode="dim"
        if [ "$CURRENT_STATE" = "restoring" ]; then
            mode="wake"
        fi
        transition_all "$mode"
    fi
    
    # Store for state tracking
    LAST_ACTIVE_MON="$active_mon"
    TOGGLE_STATE="$toggle_state"
}

# -----------------------------
# INITIALIZATION
# -----------------------------
echo "Enhanced Per-Monitor Dimming Script" >&2
echo "==================================" >&2

# Read monitor configuration
if ! read_monitors; then
    echo "Failed to read monitor configuration. Exiting." >&2
    exit 1
fi

# Initialize brightness tracking
for MON in "${MONITORS[@]}"; do
    MON_CURRENT_BRIGHT["$MON"]=1.0
    MON_TARGET_BRIGHT["$MON"]=1.0
done

# Initial mouse position
get_mouse_position
LAST_X=$X
LAST_Y=$Y
LAST_ACTIVITY_TIME=$(date +%s)

echo "Found ${#MONITORS[@]} monitor(s): ${MONITORS[*]}" >&2
echo "Script initialized successfully." >&2

# -----------------------------
# MAIN LOOP - NO LOCAL VARIABLES
# -----------------------------
while true; do
    # Check for stop file
    if [ -f "$STOP_FILE" ]; then
        rm -f "$STOP_FILE" 2>/dev/null
        exit 0
    fi
    
    # Get current timestamp
    NOW=$(date +%s)
    
    # Monitor Configuration Check
    if [ $((NOW - LAST_GEOM_CHECK)) -ge $GEOM_INTERVAL ]; then
        LAST_GEOM_CHECK=$NOW
        new_hash=$(xrandr --listmonitors 2>/dev/null | sha1sum | awk '{print $1}')
        if [ "$new_hash" != "$GEOM_HASH" ]; then
            GEOM_HASH="$new_hash"
            read_monitors
        fi
    fi
    
    # Idle State Check
    if [ $((NOW - LAST_IDLE_CHECK)) -ge 1 ]; then
        LAST_IDLE_CHECK=$NOW
        
        # Check mouse movement
        get_mouse_position
        if [ "$X" != "$LAST_X" ] || [ "$Y" != "$LAST_Y" ]; then
            LAST_X=$X
            LAST_Y=$Y
            LAST_ACTIVITY_TIME=$NOW
        fi
        
        # State transitions
        if [ "$IDLE_ENABLED" = true ]; then
            idle_time=$(get_idle_time)
            
            case "$CURRENT_STATE" in
                "active")
                    if [ "$idle_time" -ge "$IDLE_TIMEOUT" ]; then
                        CURRENT_STATE="idle"
                    fi
                    ;;
                "idle")
                    if [ "$idle_time" -lt "$IDLE_TIMEOUT" ]; then
                        CURRENT_STATE="restoring"
                    fi
                    ;;
                "restoring")
                    CURRENT_STATE="active"
                    ;;
            esac
        fi
    fi
    
    # Apply brightness based on state
    case "$CURRENT_STATE" in
        "active"|"restoring")
            apply_active_brightness
            ;;
        "idle")
            apply_idle_brightness
            ;;
    esac
    
    # Sleep for next iteration
    sleep "$MOUSE_INTERVAL"
done
