
# THIS IS THE ORIGINAL FADE MONITORS SCRIPT. PLEASE USE THE UPDATED RELEASE FROM CURRENT BRANCH IN LINK BELOW

https://github.com/hisovereign/Fade-Monitors/blob/Fade-Monitors-enhanced-dimming/README.md
(Fade Monitors enhanced dimming w/ idle dim, day/night dim, and optional gamma control.
(0.5-2% cpu)

## FOR STANDALONE BRANCH (Mouse-Based Auto-Detecting 2D Monitor Dimming only)

https://github.com/hisovereign/Fade-Monitors/blob/mouse-dim-auto-2d-stable/README.md

 ### For previous Fade Monitors time-based script

https://github.com/hisovereign/Fade-Monitors/blob/mouse-dim-auto-2d-stable-time-based/README.md


⚠️ Note: The following version, fade-monitors-night-gamma, does not implement single-instance locking. Running multiple Fade Monitor scripts simultaneously may cause gamma or brightness flashes and will increase cpu usage.

⚠️ WARNING: Changing brightness values to zero will blackout monitors and you will need to **boot into a Mint live USB session, mount system drive, nagivate to .local/bin and change the script**

or

**BLIND** ctrl + alt +F2, put in your username, put in your password, then pkill -f fade-monitors-night-gamma.sh, then (ctrl + alt + F1) or sometimes (ctrl + alt + F7). This will temporarily kill script and you can then change values and restart computer.

# Fade-Monitors
Mouse-aware and time based monitor dimming with gamma control (X11)

This script will auto dim whatever monitor your mouse is not on and also adjusts the brightness and gamma of all monitors at specific times. 
	
  -Mouse-based dimming can be toggled off with a hotkey.
	-Time-based dimming/gamma adjustments will always remain active.


Requirements:

	-x11 session (not Wayland)
	-xrandr - controls montior brightness/gamma
	-xdotool - reads mouse position


Install requirements on Debian/Ubuntu/Mint (copy/paste commands into terminal)

	sudo apt install x11-xserver-utils xdotool

	(xrandr will be installed if not already)


Optional (for hotkey support):

	sudo apt install xbindkeys





Installation:

	1. Download the script
	(click on green code button and hit download zip)

	2. Make the script executable

	chmod +x fade-monitors-night-gamma.sh


	3. Get names and positions for your monitors (only side by side monitors supported)

	xrandr --listmonitors

	Example output:

	Monitors: 2
 	0: +*DisplayPort-1 1920/527x1080/296+0+170  DisplayPort-1
 	1: +HDMI-A-0 1920/930x1080/523+1920+0  HDMI-A-0


Here you want to copy where DisplayPort-1 and HDMI-A-0 are but they should be relevent to your monitors

Double click on the script and check display. Plug in the names in this part of the script

	MONITORS=("DisplayPort-1" "HDMI-A-0")
	MON_X_START=(0 1920)
	MON_X_END=(1920 3840)

You will also need the x position for each monitor. 
(Here we plug in 0 and 1920 as X start and 1920 and 3840 as X end; The 3840 is 1920 + 1920)


	Save the file and close.


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
		-Time based-based brightness will continue working normally




Running the script manually:

	~/fade-monitors-night-gamma.sh &

Stop: 

	pkill -f fade-monitors-night-gamma.sh


Run script at start up
**WARNING** Running script at start up and changing brightness values to zero will blackout monitors and you will need to boot into live usb session to recover

	Open Start up applications> click + then custom command>browse and select the script you downloaded

	Do the same for xbindkeys (click + then custom command and search for .xbindkeys)




Configuratuion: (can all be changed in script)

Default times are 06:00 and 17:30
Default auto dim for inactive monitor 20% 
Default brightness/gamma at 100% between 06:00 - 17:30
Default dim level between 17:30 - 06:00 60% brightness 
Default gamma between 17:30 - 06:00 is set to "warm" to reduce blue light 


To change the timing you'll have to do some conversions but I'm going to place some sample times you can just plug in.

It can be found in this part of the script:


# Determine baseline brightness
    if [ $TIME_MIN -ge 1050 ] || [ $TIME_MIN -lt 360 ]; then 


Here 1050 is 17:30 and 360 is 06:00

05:00 = 300
05:30 = 330
06:30 = 390
07:00 = 420
07:30 = 450

17:00 = 1020
18:00 = 1080
18:30 = 1110
19:00 = 1140
19:30 = 1170
20:00 = 1200

*Reset brightness command for xrandr if needed

	xrandr --output <output-name> --brightness 1.0
	
⚠️ Note: This script **does not work with Nightlight or Redshift**. Using them at the same time will cause conflicts with brightness and gamma adjustments.
