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

## Building the engine

```sh
brew install mingw-w64 bison flex meson ninja ccache cmake pkgconf autoconf llvm lld nasm freetype
engine/scripts/build-all.sh
```

This needs about 15 GB of disk. The result is a runner in `engine/dist/runners/<id>`.

## License

GPL-3.0. See [NOTICE](NOTICE) for the parts under other licenses.
