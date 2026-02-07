# Fade-Monitors-enhanced-dimming

## Mouse-aware auto-monitor dimming with idle dim, day/night dim, and optional gamma control (X11)


This does not aim to replace password protected screen saver but to act as a quality of life addition to the computer experience. 
Demo https://youtu.be/r4gVBZohfMI

**This script will auto dim whatever monitor your mouse is not on, idle dim to user's preferred settings, has an auto day/night dim, and has gamma controls** 
	
-Mouse-based dimming  and idle dim can be toggled on/off with a hotkey.



### Requirements:

-x11 session

-xrandr     - controls montior brightness/gamma

-xdotool    - reads mouse position

-xprintidle - for idle dim

-bc         - arbitrary precision calculator language

-hotkey toggle is required for both mouse-based and idle dim (this readme will use bindkeys)

### Install requirements (copy, paste(ctrl + shift + v) commands into terminal)
Open menu and search for terminal.

Copy/paste then hit enter

	sudo apt-get update
	
Then install

	sudo apt-get install xprintidle bc xdotool x11-xserver-utils

   (xrandr will be installed if not already)


Preferred hotkey method (we are using bindkeys):

	sudo apt install xbindkeys


### Installation:

1. Download the script

   -click on fade-monitors-enhanced-dimming script and to the right of where it says RAW click download raw file

   -files side panel may collapse. It will be next to repo name, in top left, below code.

2. Move it to ~/.local/bin 

   -if you don't see (.local) right click and show hidden files

3. Make the script executable (open up a terminal and copy/paste commands then hit enter)

		chmod +x ~/.local/bin/fade-monitors-enhanced-dimming.sh

### Using xbindkeys (recommended) (copy/paste commands into terminal)

1. Install bindkeys (if you haven't already)

		sudo apt install xbindkeys

2. Create (or open) the xbindkeys config file

		nano ~/.xbindkeysrc

3.Add this block (copy/paste)

	"if [ -f ~/.fade_mouse_enabled ]; then rm ~/.fade_mouse_enabled; else touch ~/.fade_mouse_enabled; fi"
   	F10

	"if [ -f ~/.idle_dim_enabled ]; then rm ~/.idle_dim_enabled; else touch ~/.idle>
		F9

4. Save and exit
	crtl + o, enter. crtl + x

5. Start or restart xbindkeys 

		killall xbindkeys
		xbindkeys

Run the script
	
	~/.local/bin/fade-monitors-enhanced-dimming.sh

   Press the F10 (or hotkey of choice) to toggle  mouse-based fading
 
   Press F9 (or hotkey of choice) to toggle idle dim

 How to stop the script

1. ctrl + c in terminal you started script or

2. close the terminal you started script in or

3. Open a new terminal, copy/paste then hit enter

		pkill -f fade-monitors-enhanced-dimming.sh

Mouse-based dim is off by default

Idle dim is off by default

Default inactivity time (idle dim) is set to (IDLE_TIMEOUT=60) second. Change in script.

IDLE_BRIGHTNESS, DAY_DIM_BRIGHTNESS, and NIGHT_DIM_BRIGHTNESS can be lowered to zero


### Settings
Can be changed by opening, altering, and saving the script and are located near the top. eg change IDLE_TIMEOUT=1 to 30

To turn gamma on make ENABLE_GAMMA=false =true

ENABLE_IDLE, INSTANT_MOUSE_DIM, and INSTANT_IDLE_DIM can also be toggled on and off by making them =true or =false.

**Day/Night brightness levels**
	
	DAY_ACTIVE_BRIGHTNESS=0.7
	DAY_DIM_BRIGHTNESS=0.3
	NIGHT_ACTIVE_BRIGHTNESS=0.5
	NIGHT_DIM_BRIGHTNESS=0.2
	IDLE_BRIGHTNESS=0.1

**Time window** (24h, HHMM format)
	
	NIGHT_START=1700   # 17:00 PM
	DAY_START=0730     # 07:00 AM

**Gamma control** (optional)
	
	ENABLE_GAMMA=false
	DAY_GAMMA="1.0:1.0:1.0"
	NIGHT_GAMMA="1.0:0.85:0.1"

**Idle settings**
	
	IDLE_TIMEOUT=1
	ENABLE_IDLE=true

### Run script at start up

**WARNING** setting script to run at start up and changing ACTIVE_BRIGHTNESS values to zero will blckout monitors and require you to do one of the recovery options in important information as restarting will just run the script.


Open Start up applications> click + then custom command>browse and select the script you downloaded

Do the same for xbindkeys (click + then custom command and search for .xbindkeys)



*Reset brightness command for xrandr if needed
	
	xrandr --output <output-name> --brightness 1.0


### Past releases without idle dim
Mouse-aware with day/night mode and gamma control

https://github.com/hisovereign/Fade-Monitors/tree/mouse-dim-auto-2d-stable-time-based


### Important Information

**Warning Blackout Monitor Warning** MIN_BRIGHTNESS can be changed however changing Active brightness values to zero will blackout monitors when idle dim activates and if you set it to run at start up you will need to **boot into a live USB session, mount system drive, nagivate to .local/bin and change the script**

or 

**BLIND** enter ctrl + alt + F2, put in your username, put in your password, then pkill -f fade-monitors-enhanced-dimming.sh, then (ctrl + alt + F1) or sometimes (ctrl + alt + F7). 


 **FLASH WARNING** Turning gamma on may conflict with other programns that alter gamma and can cause flashes

-The mouse polling interval is intentionally tuned for low CPU usage. Advanced users can adjust MOUSE_INTERVAL in the script to their preference

-Earlier versions sometimes caused brief flashes if multiple instances of Fade Monitors script ran simultaneously. This has been mitigated with single-instance locking however it is still possible if ran alongside a script without single-instance locking.

**Tested on Linux Mint Cinnamon 22.2, cinnamon version: 6.48, Linux kernal: 6.18.8-x64v3-xanmod1**

**-Update-** realized no password on screen lock bug probably happened after clearing system temporay files and cache then letting my pc go into screensaver/sleep wihtout restarting. Going to leave this code here for anyone who wants to stop script during screen saver (with slight brigtness pop at lock since brightness is reseting)

This resets brightness control during screen saver lock state. 

Tutorial video ( https://www.youtube.com/watch?v=rOjOFNGJkKw )

Copy/paste this first one between get_idle_time() FUNCTION and # Get mouse position

```# Check if screen is locked (Cinnamon-specific)
is_screen_locked() {
    # Method 1: Check for Cinnamon lock screen via window search
    if command -v xdotool &> /dev/null; then
        # Look for Cinnamon's lock screen window
        # Try common window names/classes used by Cinnamon screensaver
        if xdotool search --name "Screen Locker" 2>/dev/null | grep -q .; then
            return 0
        fi
        if xdotool search --class "cinnamon-screensaver" 2>/dev/null | grep -q .; then
            return 0
        fi
        if xdotool search --class "cinnamon-screenlocker" 2>/dev/null | grep -q .; then
            return 0
        fi
    fi
    
    # Method 2: Check via wmctrl (alternative)
    if command -v wmctrl &> /dev/null; then
        if wmctrl -l 2>/dev/null | grep -i "screen locker\|locked screen" &>/dev/null; then
            return 0
        fi
    fi
    
    # Method 3: Check if we can find the mouse (last resort)
    # When screen is locked, xdotool may fail to get mouse position
    mouse_output=$(timeout 0.5 xdotool getmouselocation --shell 2>&1)
    if echo "$mouse_output" | grep -i "error\|unable\|timeout" &>/dev/null; then
        # Mouse inaccessible - might be locked
        return 0
    fi
    
    return 1
}
```
And place this right above # -------- Apply brightness based on state --------

```    # -------- Screen lock check --------
    if is_screen_locked; then
        # Screen is locked - restore full brightness and pause normal operations
        for MON in "${MONITORS[@]}"; do
            xrandr --output "$MON" --brightness 1.0 2>/dev/null &
        done
        wait
        
        # Update tracking variables to prevent transitions when unlocking
        CURRENT_STATE="active"
        TRANSITION_IN_PROGRESS=false
        
        # Short sleep and skip the rest of the loop
        sleep "$MOUSE_INTERVAL"
        continue
    fi
```
Save and restart script. 
