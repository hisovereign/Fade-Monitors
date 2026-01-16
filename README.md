# Fade-Monitors
Mouse-aware monitor dimming (X11)

This script will auto dim whatever monitor your mouse is not on
	-Mouse-based dimming can be toggled off with a hotkey.

(This version does not have time-based brightness or gamma control but has been updated to auto-detect monitors so no need to input x, y axis)

**This is the updated stable version of the mouse-based auto-dim stand-alone script

-Improved architechture that reduces CPU consumption and prevents cumulative lag during repeated display layout changes



Requirements:

	-x11 session (not Wayland)
	-xrandr - controls montior brightness/gamma
	-xdotool - reads mouse position


Install requirements (copy/paste commands into terminal)

	sudo apt install x11-xserver-utils xdotool

	(xrandr will be installed if not already)


Optional (for hotkey support):

	sudo apt install xbindkeys




Installation:

	1. Download the script
	(click on fade-monitor-sauto-2d-stable and to the right of where it says RAW click download raw file)

	2. Make the script executable

	chmod +x fade-monitors-auto-2d-stable.sh

	Run manually
		~/fade-monitors-auto-2d-stable.sh
	Stop
		pkill -f fade-monitors-auto-2d-stable.sh
	
Using xbindkeys (recommended) (copy/paste commands into terminal)

	1. Install bindkeys

	sudo apt install xbindkeys

	2. Create (or open) the xbindkeys config file

	nano ~/.xbindkeysrc

	3.Add this block (copy/paste)

	"if [ -f ~/.fade_mouse_enabled ]; then rm ~/.fade_mouse_enabled; else touch ~/.fade_mouse_enabled; fi"
   	F10


	4. Save and exit
	crtl + o, enter. crtl + x

	5. Start or restart xbindkeys 

	killall xbindkeys
	xbindkeys

	5. Press the F10 (or designated key) to toggle mouse-based fading.



Run script at start up

	Open Start up applications> click + then custom command>browse and select the script you downloaded

	Do the same for xbindkeys (click + then custom command and search for .xbindkeys)



*Reset brightness command for xrandr if needed
	
	xrandr --output <output-name> --brightness 1.0
