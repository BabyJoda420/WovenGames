# Changelog

What changed in each WovenGames release, newest first. Each release on GitHub shows its section of this file.

## Unreleased

## 0.3.1 — 2026-10-16

### Fixed
- Steam sometimes hangs at the very end of closing, and then patching or restoring Steam gave up with "Steam is
  still running". WovenGames now recognises exactly that case and force-quits Steam, which loses nothing because
  Steam has already finished closing down. A Steam that is still busy (updating itself, uploading saves, or asking
  you something) is never force-quit.

## 0.3.0 — 2026-10-16

Everything from the 0.3.0 betas, plus one fix.

### New
- **Windows games from outside Steam.** Add any Windows game (GOG, itch.io, a disc install …) with **+** on the
  Games page. It runs like a Steam game: automatic graphics choice, per-game settings, Game Mode, launch problem
  help and Force Quit.
- **How well a game runs, up front.** A tested game's page shows a card with how it ran on the Mac we tested it on
  (runs well / playable with compromises / runs poorly / doesn't work), tips for playing it, and your own Mac's
  chip and memory to compare. These reports update from GitHub without a new app version.
- **Prefix snapshots.** Save a game's Windows environment (prefix) from its page with **Snapshots → Take Snapshot
  Now**, and put it back later. Snapshots are instant and take no extra disk space until the game changes its
  files. WovenGames also takes one automatically before every engine update.
- **Uninstall WovenGames** (app menu): restores Steam to how it was and removes WovenGames. Your games' prefixes
  and saves are kept unless you choose to delete them.
- **Engine per game.** When more than one engine version is installed, a game's page lets you pick which one it
  uses, so a new engine can be tried on one game first.

### Improved
- Tested *Clair Obscur: Expedition 33*: playable on a MacBook Air M4 at about 35 fps at 1280×832 on the lowest
  preset. WovenGames keeps it on D3DMetal, because DXMT draws its shadows as a checkerboard.
- Tip in the README: choosing about half your screen's resolution in a game's graphics settings is the biggest
  speed-up, especially on a MacBook Air.
- When an Unreal Engine game closes right after starting, WovenGames suggests DXMT **with** the `-dx11` option it
  needs, as one click.
- Launch options typed in the wrong place in Steam can be moved into the game's WovenGames settings with one click.
- A game's launch log says where its graphics mode came from (your settings, WovenGames' recommendation, Steam
  launch options or automatic).
- `woven doctor` checks the App Management permission that patching Steam needs.

### Fixed
- **Engine updates after replacing the app.** If you updated WovenGames by downloading its zip from GitHub instead
  of updating in the app, WovenGames thought it was already up to date and kept the older game engine. It now
  notices when the engine is behind the app and installs the matching engine, without downloading the app again.
- After setting up or restoring Steam, Steam was left closed; it now opens again if it was open.
- The main Steam library could be read twice, which would have broken deleting prefixes.

## 0.3.0-beta.3 — 2026-10-15

### New
- **How well a game runs, up front.** A tested game's page now shows a card with how it ran on the Mac we
  tested it on (runs well / playable with compromises / runs poorly / doesn't work), tips for playing it, and
  your own Mac's chip and memory to compare. These reports update from GitHub without a new app version.

### Improved
- *Clair Obscur: Expedition 33*: WovenGames now keeps it on D3DMetal and shows its report: about 35 fps at
  1280×832 on a MacBook Air M4. DXMT draws its shadows as a checkerboard, so it isn't used.
- A game's launch log now says where its graphics mode came from (your game settings, WovenGames'
  recommendation, Steam launch options), instead of always "launch options".

## 0.3.0-beta.2 — 2026-10-14

### Improved
- Tested *Clair Obscur: Expedition 33*; added a tip that choosing about half your screen's resolution in the game's graphics settings is the biggest speed-up, especially on a MacBook Air (see the README).

### Fixed
- After setting up or restoring Steam (WovenGames' "Patch Steam" or "Restore Steam", or the `woven` tool), Steam was left closed; it now opens again if it was open.

## 0.3.0-beta.1 — 2026-10-14

### New
- **Windows games from outside Steam.** Add any Windows game (GOG, itch.io, a disc install …) with **+** on the
  Games page. It runs exactly like a Steam game: automatic graphics choice, per-game settings, Game Mode, launch
  problem help and Force Quit.
- **Prefix snapshots.** Save a game's Windows environment (prefix) from its page with **Snapshots → Take
  Snapshot Now**, and put it back later. Snapshots are instant and take no extra disk space until the game changes
  its files. WovenGames also takes one automatically before every engine update.
- **Uninstall WovenGames** (app menu): restores Steam to how it was and removes WovenGames. Your games' prefixes
  and saves are kept unless you choose to delete them.
- **Engine per game.** When more than one engine version is installed, a game's page lets you pick which one it
  uses, so a new engine can be tried on one game first.

### Improved
- When an Unreal Engine game closes right after starting, WovenGames now suggests DXMT **with** the `-dx11` option
  it needs, as one click.
- Launch options typed in the wrong place in Steam can be moved into the game's WovenGames settings with one click.
- `woven doctor` checks the App Management permission that patching Steam needs.

### Fixed
- The main Steam library could be read twice, which would have broken deleting prefixes.

## 0.2.1 — 2026-10-14

### Improved
- Game Mode now also works for games whose Steam entry starts a launcher, not the game itself (for example
  Unreal Engine games with a small start-up program).

## 0.2.0 — 2026-10-14

Everything from 0.2.0-beta.1, plus:

### Fixed
- A game that crashed at start was reported as having run fine; WovenGames now sees the real exit code.
- Quitting WovenGames during a Steam update asks first and keeps Steam pinned on a working build.
- A Steam update that brings an unexpected Steam version stops at once, pinned.
- A game installed in two Steam library folders was listed twice, and crashed the app.
- An invalid line in the global settings file stopped every game from starting.
- A crash report could include your Steam account name; it is now always removed.
- An old game session could be mistaken for a running one.
- An app update now checks the new app before replacing the engine.
- A failed Steam update could leave Steam unpinned.

## 0.2.0-beta.1 — 2026-10-14

### New
- **Games library** with covers and artwork, Play and Force Quit, and cards that explain why a launch failed and
  how to fix it.
- **Game Mode** for Windows games: each game starts from its own app with its own Dock icon.
- **Menu bar companion**, a Settings window, **Report a Problem** (a zip with personal details removed) and a Help menu.
- **Steam updates from WovenGames**: update Steam to a build the hook has been checked on, then pin it again.
- **Live recommendations**: known-good settings for games are fetched from GitHub.
- **App updates**, with an option for beta versions.

## 0.1.1 — 2026-10-10

### Fixed
- The app crashed on a settings line that is just "=".
- A broken hook could be shown as working after macOS reused Steam's process id.
- Installing the engine while a game runs is refused (it deleted the engine under the game).
- `woven install` checks the download against its published checksum.
- Restore Steam only puts the saved Info.plist back if it belongs to the installed Steam.
- Opening a game's page no longer rewrites its settings.
- Steamworks Common Redistributables no longer shows up as a game.

## 0.1.0 — 2026-10-10

First release.

- Play Windows games from the **macOS Steam app**: Install and Play buttons on Windows games, one Steam, no CrossOver.
- WovenGames.app sets everything up: engine install, App Management permission, Steam patch and update pin.
- Graphics are picked per game: D3DMetal for DirectX 12, DXMT for DirectX 10/11, wined3d for older games.
- Per-game settings (graphics, Metal HUD, Retina, msync) and known-good settings for tested games.
- `woven` command-line tool for everything the app does.
