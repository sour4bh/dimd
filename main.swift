// dimd — keep the display awake on AC, dim the backlight when idle.
//
// `pmset -c displaysleep 0` keeps displays awake on AC power so long-running
// GUI workflows (browser automation, screen capture) never hit WindowServer
// occlusion throttling. dimd adds the missing piece: on AC with no external
// monitor, once input has been idle past the configured threshold it blinks
// goodnight and fades the built-in backlight to 0%; any input, a power-source
// change, or a monitor connect restores it instantly.

import Foundation

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("dimd: \(message)\n".utf8))
    exit(1)
}

let help = """
dimd — keep the display awake, dim the backlight when idle

usage: dimd <command>

  status               power / displays / idle / brightness / lid angle
  blink                play the goodnight blink at current brightness
  demo                 blink, fade to black, hold, restore
  dim                  dim now (next input restores)
  wake                 restore the backlight now
  lid [--watch]        read the lid angle sensor
  config               show configuration (~/.config/dimd/config)
  config set <k> <v>   set threshold | blinks | dip | fade (restarts daemon)
  selftest             verify brightness control works
  daemon               run the idle watcher (used by launchd)
"""

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first ?? "help" {
case "help", "--help", "-h": print(help)
case "status": runStatus()
case "blink": runBlink()
case "demo": runDemo()
case "dim": runDim()
case "wake": runWake()
case "lid": runLid(watch: arguments.contains("--watch"))
case "config": runConfig(Array(arguments.dropFirst()))
case "selftest": runSelftest()
case "daemon": Daemon.shared.run()
default: die("unknown command '\(arguments[0])'\n\(help)")
}
