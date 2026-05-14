# Fade-Monitors

## Mouse-aware auto-monitor dimming with idle dim, day/night dim, and optional gamma control (X11)


-This script will auto dim whatever monitor your mouse is not on, idle dim to user's preferred settings, has an auto day/night dim, and has gamma controls
	

**No terminal install instructions:** https://youtu.be/21lYYaiAEU8

**For .deb release installation and config change instructions see bottom of readme**


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

   -click on fade-monitors script and to the right of where it says RAW click download raw file

   -files side panel may collapse. It will be next to repo name, in top left, below code.

3. Move it to ~/.local/bin/

   -if you don't see (.local) right click while in /home and show hidden files

   -if you don't have a folder named bin in ~/.local/ then create it

5. Make the script executable (open up a terminal and copy/paste commands then hit enter)
```
	chmod +x ~/.local/bin/fade-monitors
```
 Using xbindkeys  (copy/paste commands into terminal)

1. Install bindkeys (if you haven't already)
```
	sudo apt install xbindkeys
```
2. Create (or open) the xbindkeys config file
```
	nano ~/.xbindkeysrc
```
3.Add this block (copy/paste)
```
# Toggle mouse-based monitor dimming
"~/.local/bin/fade-monitors toggle-mouse"
        F10

# Toggle idle dimming
"~/.local/bin/fade-monitors toggle-idle"
        F9
```

4. Save and exit
	crtl + o, enter. crtl + x

5. Start or restart xbindkeys 
```
	killall xbindkeys
	xbindkeys
```
How to run the script

  - Copy/paste into terminal
```
fade-monitors &
```
   Press F10 (or hotkey of choice) to toggle  mouse-based fading
 
   Press F9 (or hotkey of choice) to toggle idle dim

How to stop the script

   - Copy/paste into terminal
```
pkill -f fade-monitors
```

### Settings

Settings can now be changed by altering config or running comands in terminal w/ fade-monitors [command]

| Command | Description |
|---------|-------------|
|toggle-mouse| Toggle mouse-based dimming on/off|
|toggle-idle| Toggle idle dimming on/off|
|set <key> <value>| Change a configuration value|
|get <key>| Print a configuration value|
|list-settings| Show runtime status and configuration|
|reload | Signal fade-monitors to reload configuration|
|help | Show this help|

Configuration keys (use with set/get):
```
  DAY_ACTIVE_BRIGHTNESS, DAY_DIM_BRIGHTNESS, NIGHT_ACTIVE_BRIGHTNESS,
  NIGHT_DIM_BRIGHTNESS, IDLE_BRIGHTNESS, NIGHT_START, DAY_START,
  ENABLE_GAMMA, DAY_GAMMA, NIGHT_GAMMA, IDLE_TIMEOUT,
  SMOOTH_DIM_MOUSE_STEPS, SMOOTH_DIM_MOUSE_INTERVAL, INSTANT_MOUSE_DIM,
  SMOOTH_DIM_IDLE_STEPS, SMOOTH_DIM_IDLE_INTERVAL, INSTANT_IDLE_DIM,
  SMOOTH_DIM_TIME_STEPS, SMOOTH_DIM_TIME_INTERVAL, INSTANT_TIME_DIM,
  MOUSE_INTERVAL, IDLE_CHECK_INTERVAL, GEOM_INTERVAL, TIME_CHECK_INTERVAL
```
Examples
```
  fade-monitors toggle-idle
  fade-monitors set DAY_ACTIVE_BRIGHTNESS 0.7
  fade-monitors set NIGHT_START 1800 
  fade-monitors set ENABLE_GAMMA true
  fade-monitors set DAY_GAMMA 1.0:1.0:1.0
  fade-monitors list-settings
```
To alter config go to config file in ~/.config/fade-monitors/config, make changes, save, and then either

1. run reload command ```fade-monitors reload```

2. or restart script by killing process and restarting

### Run script at start up

Open Start up applications> click + then custom command> go to and select the script at ~/.local/bin/fade-monitors

Do the same for xbindkeys (click + then custom command, search for and select bindkeys)



*Reset brightness command for xrandr if needed
	
	xrandr --output <output-name> --brightness 1.0


### Past releases without idle dim
Mouse-aware with day/night mode and gamma control

https://github.com/hisovereign/Fade-Monitors/tree/mouse-dim-auto-2d-stable-time-based

### fade-monitors Cinnamon applet installation

Copy the fade-monitors@hisovereign folder and place it in ~/.local/share/cinnamon/applets

You can do this manually with these steps

-Create a new folder in ~/.local/share/cinnamon/applets and name it fade-monitors@hisovereign

-download the applet.js and metadata.json and palce it in folder you made

-restart cinnamon (alt + F2, type r then hit enter) or restart pc

-Right-click on panel > click on applets> add fade-monitors applet to panel

Note - applet only works with script named fade-monitors

### Important Information


 **FLASH WARNING** Turning gamma on may conflict with other programns that alter gamma and can cause flashes

-The mouse polling interval is intentionally tuned for low CPU usage. Advanced users can adjust MOUSE_INTERVAL via the config file (~/.config/fade-monitors/config) or with fade-monitors set MOUSE_INTERVAL 0.5, etc eg. 0.5, 0.3, 0.1

- GAMERS - mouse-polling (interval) determines how often script checks your mouse position. Lower values (0.3, 0.1) increase cpu usage as the script polls more frequently; this causes fps drops depending on the poll rate. 1.0 seems to be imperceptible but it does add around a 1 second delay to monitor dimming. 

-Earlier versions sometimes caused brief flashes if multiple instances of Fade Monitors script ran simultaneously. This has been mitigated with single-instance locking however it is still possible if ran alongside a script without single-instance locking.

**Tested on Linux Mint Cinnamon 22.3, desktop environment: Cinnamon 6.6.7, Linux kernal: 6.8.0-111-generic**


### .deb Installation ###

Note- this is currently an older version of fade-monitors script without commands

1. Download the latest `.deb` from the [Releases page](https://github.com/hisovereign/Fade-Monitors/releases)

2. After download, open a terminal and copy/paste (ctrl + shift + v) command below then hit enter 

        sudo dpkg -i fade-monitors.deb
        sudo apt install -f

OR

Right-click on the fade-monitors.deb package>open with package installer>install package then open a terminal and run sudo apt install -f

Mouse-aware and idle dim need toggles for use and user will need to maually set or install the hotkeys. This readme has install instructions for and uses xbindkeys

Command to open readme

	nano /usr/share/doc/fade-monitors/README.md

**settings change** 

Open a terminal, copy/paste ( ctrl + shift + v ) command then hit enter

	sudo nano /etc/fade-monitors/config

save (ctrl + o, enter), exit (ctrl + x)

Restart fade-monitors

	pkill -f fade-monitors
	fade-monitors
