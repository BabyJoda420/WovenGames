# WovenGames

Play your **Windows Steam games from the native macOS Steam client** on Apple Silicon, with
real Install and Play buttons, one Steam, and no CrossOver.

> **Status: pre-alpha, under construction.** Nothing is user-ready yet. See [PLAN.md](PLAN.md).

WovenGames is a fork of [NotProton](https://github.com/NotProtonNot/NotProton) and
[steamplay-mac](https://github.com/thedankest/steamplay-mac); see [UPSTREAM.md](UPSTREAM.md).
It switches on the Steam Play machinery that macOS Steam already ships, and runs games on a
Wine built from CodeWeavers' public CrossOver sources. Graphics go through D3DMetal, DXMT or
wined3d, picked per game.

## Layout

| Path | What |
|---|---|
| `engine/` | builds the Wine runner (deps, patched Wine, Steam bridge, graphics backends) |
| `notproton/` | Steam hook dylib, lsteamclient bridge, steam.exe shim, setup app (to be renamed) |
| `cli/` | `woven`, the command-line tool (Swift): doctor, runners, prefixes, backend detection, run |

## Building the engine

```sh
brew install mingw-w64 bison flex meson ninja ccache cmake pkgconf autoconf llvm lld nasm freetype
engine/scripts/build-all.sh
```

This needs about 15 GB of disk. The result is a runner in `engine/dist/runners/<id>`.

## The `woven` tool

```sh
cd cli && swift build -c release      # needs Xcode (or Command Line Tools with a macOS 14+ SDK)
.build/release/woven doctor            # is this Mac ready?
.build/release/woven runner install    # install the newest engine build
.build/release/woven backend detect /path/to/Game.exe
.build/release/woven run /path/to/Game.exe
```

## License

GPL-3.0. See [NOTICE](NOTICE) for the parts under other licenses.

## The app

```sh
cli/scripts/build-app.sh --open      # builds cli/.build/WovenGames.app and opens it
```

- **Status** lists the checks, installs the engine, patches or restores Steam, and pins Steam's build.
- **Games** lists installed Windows games. Each game has its own graphics backend, Metal HUD, Retina and msync
  settings (stored in `~/Library/Application Support/WovenGames/games/<appid>.env`), plus its launch log and prefix tools.
