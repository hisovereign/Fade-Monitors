#!/bin/bash

# -----------------------------
# Monitor Fade + Night Gamma Script
# -----------------------------

MONITORS=("DisplayPort-1" "HDMI-A-0")
MON_X_START=(0 1920)
MON_X_END=(1920 3840)

# Brightness settings
FULL_BRIGHTNESS=1.0
NIGHT_BRIGHTNESS=0.6
OFF_BRIGHTNESS=0.2

# Gamma for night (warm)
NIGHT_GAMMA="1.0:0.85:0.7"

# Toggle file for mouse-based fading
TOGGLE_FILE="$HOME/.fade_mouse_enabled"

# Ensure script cleans up on exit
restore_brightness() {
    for MON in "${MONITORS[@]}"; do
        xrandr --output "$MON" --brightness 1.0 --gamma 1.0:1.0:1.0
    done
    exit
}
trap restore_brightness SIGINT SIGTERM

while true; do
    # Mouse position
    eval $(xdotool getmouselocation --shell)

    # Time in minutes since midnight
    HOUR=$(date +%H)
    MIN=$(date +%M)
    TIME_MIN=$((10#$HOUR * 60 + 10#$MIN))

    # Determine baseline brightness
    if [ $TIME_MIN -ge 1050 ] || [ $TIME_MIN -lt 360 ]; then  # After 17:30
        BASE_BRIGHTNESS=$NIGHT_BRIGHTNESS
        BASE_GAMMA=$NIGHT_GAMMA
    else
        BASE_BRIGHTNESS=$FULL_BRIGHTNESS
        BASE_GAMMA="1.0:1.0:1.0"
    fi

    for i in ${!MONITORS[@]}; do
        MON=${MONITORS[$i]}
        START=${MON_X_START[$i]}
        END=${MON_X_END[$i]}

        # Default: baseline brightness and gamma
        TARGET_BRIGHT=$BASE_BRIGHTNESS
        TARGET_GAMMA=$BASE_GAMMA

        # Mouse-based fading only if toggle file exists
        if [ -f "$TOGGLE_FILE" ]; then
            if ! { [ "$X" -ge "$START" ] && [ "$X" -lt "$END" ]; }; then
                TARGET_BRIGHT=$OFF_BRIGHTNESS
            fi
        fi

        # Apply instantly with gamma
        xrandr --output "$MON" --brightness $TARGET_BRIGHT --gamma $TARGET_GAMMA
    done

    sleep 0.05
done
