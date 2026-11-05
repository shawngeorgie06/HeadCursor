# HeadCursor

Control the Mac cursor by moving your head while wearing AirPods. This is an early prototype, built to find out whether the idea feels good enough to replace a trackpad for everyday navigation and reading code.

## Status

| Feature | State |
| --- | --- |
| Cursor follows head movement | Works and feels smooth (tested on AirPods Pro 3, macOS 27.2) |
| Trackpad or keyboard use pauses tracking | Works |
| Slow mode | Built, not tested yet |
| Pause-to-click | Built, not tested yet, off by default |
| Tilt-to-scroll | Built, not tested yet |
| Right-click and drag | Not built |

The earbuds must be in your ears. In the one test with them in their open case, with default settings, no motion data arrived.

## Requirements

- macOS 14 or later
- AirPods that report head motion, such as AirPods Pro
- Xcode command line tools
- A code signing identity. `build.sh` uses one named `NotchPill Self-Signed`, so change that line to your own. macOS can drop permissions after a rebuild if the signature isn't stable.

## Run it

```sh
zsh build.sh
open HeadMouseSpike.app
```

The build script quits any running copy first. On first run, allow Motion & Fitness and Accessibility access when macOS asks, then open the app again if the cursor doesn't respond.

## Controls

| Keys | Action |
| --- | --- |
| ⌃⌥H | Turn on or off |
| ⌃⌥P | Slow mode |
| ⌃⌥D | Pause-to-click |
| ⌃⌥R | Re-center tilt |

The menu bar item has the same options, plus flips for left/right, up/down and scroll direction, and Quit.

Logs are written to `~/Library/Logs/HeadMouseSpike.log`.
