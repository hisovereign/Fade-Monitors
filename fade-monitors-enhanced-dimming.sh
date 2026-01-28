#!/bin/bash
# -----------------------------
# Enhanced Mouse-Based Per-Monitor Dimming with Idle Support
# -----------------------------
# Requires: xrandr, xdotool, xprintidle, bc
# -----------------------------

# -----------------------------
# USER CONFIG
# -----------------------------

# Brightness levels
ACTIVE_BRIGHTNESS=0.6
DIM_BRIGHTNESS=0.2
IDLE_BRIGHTNESS=0.1

# Idle settings
IDLE_TIMEOUT=90           # Seconds of inactivity before idle dim (e.g., 60s = 1 minute)
ENABLE_IDLE=true          # Set to false to disable idle dimming entirely

# Smooth transition settings - MOUSE DIM
SMOOTH_DIM_MOUSE_STEPS=10      # Steps for mouse-based dimming transitions
SMOOTH_DIM_MOUSE_INTERVAL=0.02 # Seconds between steps for mouse dimming
INSTANT_MOUSE_DIM=true        # Override smooth dimming with instant for mouse

# Smooth transition settings - IDLE DIM  
SMOOTH_DIM_IDLE_STEPS=10       # Steps for idle dimming transitions (slower)
SMOOTH_DIM_IDLE_INTERVAL=0.02  # Seconds between steps for idle dimming
INSTANT_IDLE_DIM=false         # Override smooth dimming with instant for idle

# Toggle files
TOGGLE_FILE="$HOME/.fade_mouse_enabled"
IDLE_TOGGLE_FILE="$HOME/.idle_dim_enabled"

# Poll intervals
MOUSE_INTERVAL=0.1          # Mouse polling (10 times/sec)
IDLE_CHECK_INTERVAL=1       # Idle check interval (every 1 second)
GEOM_INTERVAL=2             # Monitor geometry check interval

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
GEOM_DIRTY=0

# State management
CURRENT_STATE="active"  # "active" or "idle"
LAST_ACTIVE_MON=""
TRANSITION_IN_PROGRESS=false
LAST_ACTIVITY_TIME=$(date +%s)

# -----------------------------
# FUNCTIONS
# -----------------------------

# Cleanup
restore_brightness() {
    for MON in "${MONITORS[@]}"; do
        xrandr --output "$MON" --brightness 1.0 2>/dev/null
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
            MON_TARGET_BRIGHT["$NAME"]=$ACTIVE_BRIGHTNESS
            MON_CURRENT_BRIGHT["$NAME"]=$ACTIVE_BRIGHTNESS
        fi
    done
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

# Parallel xrandr updates for performance
parallel_xrandr() {
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
        
        xrandr --output "$mon" --brightness "$brightness" 2>/dev/null &
        pids+=($!)
        idx=$((idx + 2))
    done
    
    wait "${pids[@]}" 2>/dev/null
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
        parallel_xrandr "${brightness_args[@]}"
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
        step_size=$(echo "scale=6; (${MON_TARGET_BRIGHT[$MON]} - ${START_BRIGHTNESS[$MON]}) / $steps" | bc 2>/dev/null || echo "0")
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
                current=$(echo "scale=6; ${START_BRIGHTNESS[$MON]} + ${STEP_SIZES[$MON]} * $step" | bc 2>/dev/null || echo "${MON_TARGET_BRIGHT[$MON]}")
                
                # Clamp between 0 and 1
                if [ "$(echo "$current < 0" | bc -l 2>/dev/null)" -eq 1 ]; then
                    current=0
                elif [ "$(echo "$current > 1" | bc -l 2>/dev/null)" -eq 1 ]; then
                    current=1
                fi
            fi
            
            MON_CURRENT_BRIGHT["$MON"]="$current"
            brightness_args+=("$MON" "$current")
        done
        
        parallel_xrandr "${brightness_args[@]}"
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
    parallel_xrandr "${final_brightness_args[@]}"
    
    TRANSITION_IN_PROGRESS=false
}

# Apply idle brightness
apply_idle_brightness() {
    # Set target brightness for idle state (all monitors same)
    for MON in "${MONITORS[@]}"; do
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
                local target="$ACTIVE_BRIGHTNESS"
            else
                local target="$DIM_BRIGHTNESS"
            fi
        else
            # Toggle is OFF - all monitors get ACTIVE_BRIGHTNESS
            local target="$ACTIVE_BRIGHTNESS"
        fi
        
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

read_monitors
GEOM_HASH="$(echo "$XRANDR_LIST" | sha1sum | awk '{print $1}')"

# Print configuration
echo "Enhanced Mouse-Based Dimming with Idle Support" >&2
echo "=============================================" >&2
echo "Active brightness: $ACTIVE_BRIGHTNESS" >&2
echo "Dim brightness: $DIM_BRIGHTNESS" >&2
echo "Idle brightness: $IDLE_BRIGHTNESS" >&2
echo "Idle timeout: ${IDLE_TIMEOUT}s" >&2
echo "Idle enabled: $ENABLE_IDLE" >&2
echo "Idle toggle file: $IDLE_TOGGLE_FILE" >&2
echo "Idle toggle state: $([ -f "$IDLE_TOGGLE_FILE" ] && echo "OFF (file exists = disabled)" || echo "ON (no file = enabled)")" >&2
echo "" >&2
echo "Mouse transition: ${SMOOTH_DIM_MOUSE_STEPS} steps, ${SMOOTH_DIM_MOUSE_INTERVAL}s interval" >&2
echo "Mouse instant: $INSTANT_MOUSE_DIM" >&2
echo "Idle transition: ${SMOOTH_DIM_IDLE_STEPS} steps, ${SMOOTH_DIM_IDLE_INTERVAL}s interval" >&2
echo "Idle instant: $INSTANT_IDLE_DIM" >&2
echo "" >&2
echo "Toggle file: $TOGGLE_FILE" >&2
echo "Mouse toggle state: $([ -f "$TOGGLE_FILE" ] && echo "ON (per-monitor dimming)" || echo "OFF (all monitors active)")" >&2
echo "" >&2
echo "Parallel updates: ENABLED" >&2
echo "" >&2

# -----------------------------
# MAIN LOOP
# -----------------------------
while true; do
    NOW=$(date +%s)
    
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
            
            # State transitions
            case "$CURRENT_STATE" in
                "active")
                    if [ "$idle_time" -ge "$IDLE_TIMEOUT" ]; then
                        echo "Entering idle state (idle for ${idle_time}s)" >&2
                        CURRENT_STATE="idle"
                        LAST_ACTIVITY_TIME=$((NOW - IDLE_TIMEOUT))
                    fi
                    ;;
                "idle")
                    if [ "$idle_time" -lt "$IDLE_TIMEOUT" ]; then
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
