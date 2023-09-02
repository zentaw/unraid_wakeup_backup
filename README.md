# unraid_wakeup_backup

## What is this?
I got inspired by Spaceinvader One backup solution in unraid. This is a script that runs that script/s, which is normaly powered off, by powering on server and when done safely powering off server.
https://github.com/SpaceinvaderOne/Unraid_ZFS_Dataset_Snapshot_and_Replications


# Requirements
1. Unraid Plugins
  - wake on lan plugin, uses "etherwake" cli, https://forums.unraid.net/topic/36613-wake-on-lan-plugin-for-unraid-61/
  - UserScripts (optional)

2. Wake on lan enabled or a WiFi plug.
  - WIFI_PLUG used is a "Shelly Plug S". To turn on host by switching on power (BIOS powerloss = always on)

## Run this script on a cron, make more script in userscripts and add them to array IMPORTED_SCRIPTS
example cron "7 minutes past 22:00 and 10:00 every day"
```bash
7 22,10 * * *
```

# Thanks for your awesome contribution
Spaceinvader One
https://www.youtube.com/@SpaceinvaderOne

Sanoid
https://github.com/jimsalterjrs/sanoid
