<p align="center"><img src="docs/banner.png" alt="Wakeline: a live 3D light-race screensaver for macOS" width="100%"></p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-0b1220?style=flat-square" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-0b1220?style=flat-square" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Metal-live%203D-2f8dff?style=flat-square" alt="Live Metal rendering">
  <img src="https://img.shields.io/badge/license-MIT-19f07a?style=flat-square" alt="MIT license">
</p>

Two bikes race around your screen and wrap it in glowing walls, lap inside lap. At a random moment one bike swerves into the other's trail and blows up. The walls burn away and a new race starts.

Wakeline renders every frame live, so each race plays out differently.

<p align="center"><img src="docs/hero.gif" alt="A blue bike crashes into the green trail and explodes" width="720"></p>

## Screenshots

| Side by side | Lap after lap |
| --- | --- |
| ![Green and blue bikes race side by side with their walls behind them](docs/shot-race.jpg) | ![Green and blue walls nested around the screen](docs/shot-laps.jpg) |
| ![The two bikes up close, one lane apart](docs/shot-duel.jpg) | ![An arrowhead bike racing past the glowing walls](docs/shot-detail.jpg) |

| Blue goes down | Green goes down |
| --- | --- |
| ![The camera drops in on a blue explosion](docs/shot-crash.jpg) | ![A green explosion spreads across the walls](docs/shot-boom.jpg) |

## What you get

- **A new race each time.** The crash time, the loser, the lane width and the spiral direction all come from a random roll.
- **An overhead camera.** You see the whole maze, then the camera drops in on the crash in slow motion.
- **A mirror floor.** Bikes, walls and sparks reflect in black glass.
- **One race per display.** Three screens get three separate races.
- **No dependencies.** Swift, Metal and nothing else.

## Install

You need an Apple Silicon Mac on macOS 14 or later, plus Apple's Command Line Tools. You don't need Xcode. We test on macOS 26.5, so older versions may need a tweak.

```bash
git clone https://github.com/1upcreative/wakeline.git
```

```bash
cd wakeline
```

```bash
./build.sh
```

```bash
./install.sh
```

Open **System Settings**, click **Screen Saver**, and pick **Wakeline**.

`install.sh` installs for your user account only. If you already have a copy, it moves the old one to `~/Library/Application Support/Wakeline` first.

## Try it before you install

The build also makes a preview app that runs the same engine in a window:

```bash
open "build/Wakeline Preview.app"
```

Press **F** for full screen, **N** for the next race, and **Esc** to quit.

## Uninstall

Open `~/Library/Screen Savers` in Finder and move `Wakeline.saver` to the Trash.

## Privacy

Wakeline collects nothing. It has no network code, no accounts and no tracking. It asks for no permissions and saves no files.

## Under the hood

| Part | Where |
| --- | --- |
| Race rules and bike AI | `Sources/Core/Race.swift` |
| Camera | `Sources/Core/Director.swift` |
| Sparks and explosions | `Sources/Core/World.swift`, `Sources/Core/Particles.swift` |
| Metal renderer | `Sources/Core/Renderer.swift` |
| Shaders | `Resources/Wakeline.metal` |
| Bike model, built in headless Blender | `tools/build_assets.py` |
| macOS screensaver wrapper | `Sources/Saver/WakelineSaverView.swift` |

Wakeline compiles its bundled shaders when it starts. It downloads nothing.

To test the race rules without opening a window, run this after a build:

```bash
"build/Wakeline Preview.app/Contents/MacOS/Wakeline Preview" --simtest 1000
```

## Security

See [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).
