# dimd

![dimd — display stays awake, backlight fades to 0% when you walk away, the lid is a brightness fader](.github/social-preview.png)

**Idle backlight dimmer for MacBooks that stay awake to run background agents —
plus a lid-angle brightness fader.**

[![release](https://img.shields.io/github/v/release/sour4bh/dimd?color=4c94f8)](https://github.com/sour4bh/dimd/releases)
[![platform](https://img.shields.io/badge/platform-macOS%20(Apple%20Silicon)-black)](#requirements)
[![swift](https://img.shields.io/badge/swift-5-F05138)](Makefile)
[![license](https://img.shields.io/github/license/sour4bh/dimd?color=green)](LICENSE)

The display stays awake, the backlight blinks goodnight and fades to 0% when
you walk away, and any keypress brings it back instantly. Tilt the lid and it
becomes a physical brightness knob, gliding with the native brightness-key
animation. Single binary, no dependencies, no accessibility permissions.

## Install

Homebrew (Apple Silicon):

```sh
brew install sour4bh/tap/dimd
sudo pmset -c displaysleep 0            # one-time: keep the display awake on AC
brew services start sour4bh/tap/dimd    # run the idle-dimming daemon
dimd demo                               # see the goodnight blink + fade + restore
```

Homebrew 6.0+ asks you to `brew trust sour4bh/tap` the first time — it does
this for every third-party tap.

From source:

```sh
git clone https://github.com/sour4bh/dimd && cd dimd
make install     # build, install launchd agent
dimd demo        # see the goodnight blink + fade + restore
```

## Why

`pmset -c displaysleep 0` keeps the display awake whenever on AC power, so GUI
workflows (browser automation, screen capture) never hit WindowServer occlusion
throttling. But that leaves the panel burning at full brightness 24/7. macOS has
no native "stay awake, backlight off" mode — display sleep is all-or-nothing.

dimd fills the gap: it fades the built-in backlight to 0% when you walk away,
while the display stays technically awake.

This is the "turn off the MacBook screen but keep it running" mode Apple never
shipped. Unlike clamshell mode, it needs no external display, keyboard, or
mouse; unlike `caffeinate`, Amphetamine, or KeepingYouAwake — which keep the
*system* awake but leave the panel lit — dimd actually takes the backlight to
zero. Half-close the lid and the screen fades to black while overnight builds,
downloads, and AI coding agents (Claude Code and friends) keep running.

## Behavior

| State | Display | Backlight |
|---|---|---|
| Battery | sleeps (native `displaysleep 10`) | untouched |
| AC, external monitor connected | never sleeps | untouched |
| AC, no monitor, input active | never sleeps | untouched |
| AC, no monitor, idle past threshold | never sleeps | fades to 0% |

Dimming announces itself with a goodnight double-blink before the backlight
closes. Restore is instant (≤ 0.25 s) on any input, monitor connect, or switch
to battery.

With `lidfader=on`, the lid becomes a physical brightness knob: at 69° and
above the panel stays at your setpoint (brightness keys keep working, the
daemon follows them); tilting below 69° scales the backlight down to 0% at
15°, tracked at 60 Hz while the lid moves. The idle goodnight-dim still
applies on top. Brightness is saved before dimming and restored exactly; the saved
value persists across daemon restarts (`~/.local/state/dimd/brightness`).

## Commands

```
dimd status              power / displays / idle / brightness / lid angle
dimd blink               play the goodnight blink at current brightness
dimd demo                blink, fade to black, hold, restore
dimd dim                 dim now (next input restores)
dimd wake                restore the backlight now
dimd set <0-100>         set brightness with a smooth ramp
dimd lid [--watch]       read the lid angle sensor
dimd fader               lid angle drives the backlight, live (Ctrl-C restores)
                         your current brightness at 69° and above; fades out toward 15°
dimd config              show configuration
dimd config set <k> <v>  set a key (restarts the daemon)
dimd selftest            verify brightness control works
dimd daemon              run the idle watcher (used by launchd)
```

## Configuration

`~/.config/dimd/config`, key=value lines:

| Key | Default | Meaning |
|---|---|---|
| `threshold` | `600` | idle seconds before dimming |
| `blinks` | `2` | goodnight blinks before the fade |
| `dip` | `0.35` | blink dip depth (0–1, fraction of current brightness) |
| `fade` | `0.9` | fade-to-black duration in seconds |
| `lidfader` | `off` | lid angle drives the backlight, always-on in the daemon |

`dimd config set` writes the file and restarts the daemon; if you edit the file
by hand, `launchctl kickstart -k gui/$(id -u)/local.dimd` to reload.

## Requirements

- `pmset -c displaysleep 0` (one-time, sudo)
- Brightness control uses the private `DisplayServices` framework — the only
  per-display brightness API that reaches the built-in panel on Apple Silicon
  (same route as the `brightness` CLI). `dimd selftest` verifies it.

## Managing

```sh
make status      # detected state + agent state
make log         # tail the daemon log
make uninstall   # bootout the agent, remove binary + plist
```

## Design notes

- The statefile (`~/.local/state/dimd/brightness`) is the single source of
  truth for "dimmed": the daemon, `dimd dim`, and `dimd wake` coordinate
  through it, so a manual dim gets restore-on-input for free and dims survive
  daemon restarts. Its mtime marks when the dim began, so only input *newer
  than the dim* wakes it.
- `dimd lid` reads the lid angle HID sensor (usage page 0x20, usage 0x8A,
  feature report 1) on Apple Silicon MacBooks. `dimd fader` maps the angle
  (15°–69°) onto the backlight, topping out at whatever brightness you
  started with — groundwork for lid-angle automations (dim on half-closed
  lid, peek-to-wake).
- `DisplayServicesSetBrightnessSmooth(display, delta)` is the native animated
  ramp the brightness keys use — its float argument is a **delta from current**,
  not an absolute target (pass an absolute and it silently clamps; this is why
  it's often reported as broken). `rampBrightness` wraps it; the fader
  retargets it at 20 Hz and the system interpolates. Software 120 Hz
  micro-stepping remains as the fallback and for the timed goodnight
  animation.

## Notes

- The display never sleeping on AC means no display-sleep auto-lock; the screen
  saver lock (if configured) still applies.
- If "Automatically adjust brightness" fights the 0% level, disable it in
  System Settings → Displays.

## References

The hidden hinge sensor behind `dimd lid` has been in MacBooks since 2019 —
and went properly viral in 2025:

- [samhenrigold/LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor) —
  the app that made the sensor famous (creaky-door and theremin modes), and the
  [writeup](https://samhenri.gold/labs/20250906-lid-angle-sensor/) behind it
- ["The MacBook has a sensor that knows the exact angle of the screen hinge"](https://news.ycombinator.com/item?id=45158968)
  on Hacker News ·
  [the r/pcmasterrace post](https://www.reddit.com/r/pcmasterrace/comments/1nczrh7/macbook_has_a_sensor_that_knows_the_exact_angle/) ·
  [Tom's Hardware](https://www.tomshardware.com/software/developer-tools/engineer-taps-into-apples-hidden-lidanglesensor-api-to-create-a-creaky-door-simulator)
- [MacRumors (2019): 16-inch MacBook Pro features new "lid angle sensor"](https://www.macrumors.com/2019/11/19/16-inch-macbook-pro-lid-angle-sensor/) —
  the original discovery via an Apple service document, and the
  [iFixit teardown analysis](https://www.ifixit.com/News/33952/apple-put-a-hinge-sensor-in-the-16-macbook-pro-what-could-it-be-for)
- [Hackaday: beating Apple's secret lid-angle sensor calibration](https://hackaday.com/2023/09/26/beating-apples-secret-lid-angle-sensor-calibration-with-custom-tool/)
- Other readers of the same sensor:
  [pybooklid](https://github.com/tcsenpai/pybooklid) (Python),
  [lid-angle-rs](https://github.com/wangfu91/lid-angle-rs) (Rust)

## Related projects

- [nriley/brightness](https://github.com/nriley/brightness) — brightness CLI;
  the same private DisplayServices route dimd uses to reach the built-in panel
  on Apple Silicon
- [MonitorControl](https://github.com/MonitorControl/MonitorControl) and
  [Lunar](https://github.com/alin23/Lunar) — brightness control for external
  displays over DDC
- [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake),
  [Amphetamine](https://apps.apple.com/us/app/amphetamine/id937984704), and
  the built-in `caffeinate(8)` — prevent the Mac from sleeping; dimd is the
  complement that turns the screen off while it stays awake
