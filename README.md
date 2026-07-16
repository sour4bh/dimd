# dimd

Idle backlight dimmer for MacBooks that stay awake to run background agents.

## Why

`pmset -c displaysleep 0` keeps the display awake whenever on AC power, so GUI
workflows (browser automation, screen capture) never hit WindowServer occlusion
throttling. But that leaves the panel burning at full brightness 24/7. macOS has
no native "stay awake, backlight off" mode — display sleep is all-or-nothing.

dimd fills the gap: it fades the built-in backlight to 0% when you walk away,
while the display stays technically awake.

## Behavior

| State | Display | Backlight |
|---|---|---|
| Battery | sleeps (native `displaysleep 10`) | untouched |
| AC, external monitor connected | never sleeps | untouched |
| AC, no monitor, input active | never sleeps | untouched |
| AC, no monitor, idle ≥ 10 min | never sleeps | fades to 0% |

Dimming announces itself with a goodnight double-blink before the backlight
closes (`./dimd --demo` plays the full sequence on demand). Restore is instant
(≤ 0.25 s) on any input, monitor connect, or switch to battery. Brightness is saved before dimming and restored exactly; the saved
value persists across daemon restarts (`~/.local/state/dimd/brightness`).

## Requirements

- `pmset -c displaysleep 0` (one-time, sudo)
- Brightness control uses the private `DisplayServices` framework — the only
  per-display brightness API that reaches the built-in panel on Apple Silicon
  (same route as the `brightness` CLI). `./dimd --selftest` verifies it.

## Install

```sh
make install     # build, copy plist, bootstrap launchd agent
make status      # detected power/display/idle state + agent state
make log         # tail the daemon log
make uninstall
```

## Test

```sh
./dimd --status                       # what the daemon sees right now
launchctl bootout gui/$(id -u)/local.dimd
./dimd --threshold 15                 # unplug monitor, hands off 15s → dims; touch input → restores
make install                          # re-install the real agent
```

## Notes

- The display never sleeping on AC means no display-sleep auto-lock; the screen
  saver lock (if configured) still applies.
- If "Automatically adjust brightness" fights the 0% level, disable it in
  System Settings → Displays.
