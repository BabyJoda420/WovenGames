# WovenGames

**Play your Windows Steam games on an Apple Silicon Mac, right from the Mac Steam app.**

Windows games in your Steam library get normal **Install** and **Play** buttons. No second Steam, no Windows, no
CrossOver licence. WovenGames is free and open source.

> **Beta.** WovenGames works for the games we've tested, but expect rough edges. Please
> [tell us how your games run](https://github.com/BabyJoda420/WovenGames/issues/new/choose).

## What you need

- A Mac with Apple Silicon (M1 or newer) and **macOS 14 Sonoma or later**
- Rosetta 2 (macOS offers to install it; or run `softwareupdate --install-rosetta`)
- The Mac **Steam** app in your Applications folder, signed in
- About 1 GB of free disk space for the engine, plus room for your games

## Install

1. Download **WovenGames-<version>.zip** from the [latest release](https://github.com/BabyJoda420/WovenGames/releases/latest),
   unzip it and move **WovenGames.app** to Applications.
2. The first time, **right-click** WovenGames and choose **Open**. (WovenGames is free and not notarized by Apple,
   so macOS asks once.)
3. Follow the setup assistant. It checks your Mac, downloads the game engine, asks you to allow **App Management**
   in System Settings (needed to change Steam), and sets up Steam.
4. Open Steam. Windows games now have Install and Play buttons. Install one and press Play.

## Playing

- Start games from **Steam** as usual. WovenGames picks the graphics mode for each game by itself.
- The WovenGames app's **Games** page lists your Windows games. Each game has its own settings (graphics mode,
  FPS counter, Retina resolution), a **Force Quit** button, and cards that explain what went wrong if a game
  doesn't start, with a one-click fix where there is one.
- **Games from outside Steam** (GOG, itch.io, a disc): click **+** on the Games page and choose the game's `.exe`.
- **Snapshots**: on a game's page, **Snapshots → Take Snapshot Now** saves the game's Windows setup, so you can go
  back if something breaks. WovenGames also takes one before every engine update.
- Games show up in macOS **Game Mode** with their own Dock icon.
- Games we've tested show a card on their page with how well they ran on our Mac, next to yours, so you know
  before you buy or download whether your Mac can handle them.

### Games we've tested

| Game | Result |
|---|---|
| Billie's Wheelie | ✅ Runs smoothly |
| Life is Strange: Double Exposure | 🟡 Plays at about 45 fps with WovenGames' recommended settings; the DirectX 12 mode hangs in the menu (being worked on) |
| Clair Obscur: Expedition 33 | 🟡 Playable on a MacBook Air M4: about 35 fps at 1280×832 on the lowest preset, and it looks rough. Set that resolution in the game (Settings → Graphics); at full resolution it runs at under 10 fps. Use D3DMetal (the default): DXMT draws the shadows wrong |

**Tip:** games run at your screen's full resolution by default, which is often too much for the Mac's graphics chip, especially on a MacBook Air. Picking about half the screen resolution in the game's graphics settings is the biggest speed-up.

Played something else? [Tell us how it went](https://github.com/BabyJoda420/WovenGames/issues/new/choose): it helps
everyone.

## Problems?

- **"WovenGames can't be opened"**: right-click the app and choose **Open** (only needed the first time).
- **A game doesn't start**: open the game's page in WovenGames. A card usually says why and offers a fix (often
  another graphics mode).
- **Steam wants to update**: WovenGames keeps Steam on a version it has checked, because a Steam update can break it.
  When a newer checked version is available, the app's Status page offers to update Steam safely.
- **Still stuck**: in WovenGames choose **Help → Report a Problem…**. It makes a zip with the logs (personal details
  removed). [Open an issue](https://github.com/BabyJoda420/WovenGames/issues/new/choose) and attach it.

**Not supported:** games with kernel-level anti-cheat (many competitive online shooters).

**Good to know:** WovenGames works by changing the Steam app on your Mac. Valve doesn't officially support that. We
know of no problems with Steam accounts, but you use it at your own risk.

## Uninstall

In WovenGames choose **WovenGames → Uninstall WovenGames…**. Steam goes back to how it was. Your games' saves and
settings are kept unless you choose to delete them. Then move WovenGames.app to the Trash.

## What's new

See the [CHANGELOG](CHANGELOG.md), or the notes on each [release](https://github.com/BabyJoda420/WovenGames/releases).

---

## For developers

WovenGames is a fork of [NotProton](https://github.com/NotProtonNot/NotProton) and
[steamplay-mac](https://github.com/thedankest/steamplay-mac) (see [UPSTREAM.md](UPSTREAM.md)). It switches on the Steam
Play machinery that macOS Steam already ships, and runs games on a Wine built from CodeWeavers' public CrossOver
sources. Graphics go through D3DMetal, DXMT or wined3d, picked per game. [PLAN.md](PLAN.md) has the architecture and
roadmap; [CONTRIBUTING.md](CONTRIBUTING.md) has how to help.

| Path | What |
|---|---|
| `engine/` | builds the Wine runner (deps, patched Wine, Steam bridge, graphics backends) |
| `notproton/` | Steam hook dylib, lsteamclient bridge, steam.exe shim, the compat tool's run script |
| `cli/` | the `woven` command-line tool and WovenGames.app (Swift) |
| `compat/` | known-good settings per game, and the Steam builds the hook has been checked on |

### The `woven` tool

Everything the app does is also a command. It's inside the app at `WovenGames.app/Contents/Resources/woven`.

```sh
woven install --latest      # engine + D3DMetal + Valve's Steam DLLs, each hash-checked
woven steam patch           # set up Steam (asks for App Management)
woven doctor                # is this Mac ready?
woven games                 # Windows games, with their settings
woven games add /path/to/Game.exe   # a game from outside Steam
woven snapshot take <appid>         # snapshot a game's prefix
woven uninstall             # restore Steam and remove WovenGames (keeps prefixes)
```

### Building

```sh
brew install mingw-w64 bison flex meson ninja ccache cmake pkgconf autoconf llvm lld nasm freetype
engine/scripts/build-all.sh          # the engine: about 15 GB of disk, 20–30 minutes
cd cli && swift build -c release     # the woven tool (needs Xcode)
cli/scripts/build-app.sh --open      # WovenGames.app
```

Tests: `swift test` in `cli/`, and `shellcheck` on the scripts.

### Steam builds

The hook finds its functions inside one Steam build, so WovenGames keeps Steam on a checked build.
`woven steam builds` (or the app's Status page) shows whether the installed build, a downloaded update and Valve's
newest builds are supported. `engine/scripts/check-steam-build.sh [public|publicbeta]` checks a build offline; the
daily `steam-watch` workflow does this and records the results in `compat/steam-builds.json`.

### Making a release

Add the release's section to [CHANGELOG.md](CHANGELOG.md), set `VERSION` and the version in
`cli/Sources/woven/Woven.swift`, then push a tag such as `v0.3.0`. `.github/workflows/release.yml` builds the engine and
the app on Apple Silicon and publishes them with that CHANGELOG section as the release notes. Tags with a `-`
(`v0.3.0-beta.1`) become pre-releases.

## License

GPL-3.0. See [NOTICE](NOTICE) for the parts under other licenses.
