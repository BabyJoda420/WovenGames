# WovenGames — Plan

Play your Windows Steam library from the **native macOS Steam client** on Apple Silicon.
There's one Steam (the Mac one), real Install and Play buttons, and no CrossOver.

- **License:** GPL-3.0. Parts derived from Valve code keep Valve's licenses. Details below.
- **Basis:** a fork of [NotProton](https://github.com/NotProtonNot/NotProton) (the Steam hook and Steam bridge) and
  [steamplay-mac](https://github.com/thedankest/steamplay-mac) (a Wine engine built from CrossOver's public sources).
- **First test game:** Clair Obscur: Expedition 33 (UE5, DX12 → D3DMetal). Not tested yet.

---

## 1. How it works

```
macOS Steam.app ──(DYLD_INSERT_LIBRARIES via Info.plist LSEnvironment, ad-hoc re-sign)──► wovengames.dylib
   │  turns on Steam Play, which ships inside macOS Steam but is switched off
   │  registers the compatibility tool "WovenGames" → Install/Play buttons on Windows games
   ▼
compat tool `run` script ──► per-game .app launcher (Dock icon, macOS Game Mode)
   ▼
x86_64 Wine (CrossOver 26.x LGPL sources + Proton/Highball patches) under Rosetta 2
   ├─ graphics: auto-picked per game (DX12→D3DMetal, DX10/11→DXMT, older→wined3d)
   └─ steam.exe shim → game.exe
          └─ steamclient64.dll ─► builtin lsteamclient ─► macOS steamclient.dylib
             (achievements, cloud saves, overlay and DRM all go through the ONE Mac Steam)
```

The hook finds functions inside one specific Steam build, so a Steam update would break it.
Steam is therefore pinned with `steam.cfg` → `BootStrapperInhibitUpdateOnLaunch=enable`, the same setting NotProton uses (`InhibitAll` can stop Steam from signing in). When a new Steam build
comes out, we update the hook's signature database and then lift the pin (`woven steam update` does the unpin, restart and re-pin).

## 2. Repository layout

| Path | What it holds | Origin |
|---|---|---|
| `engine/` | Wine runner build scripts and patch series. Output: `dist/runners/<id>`, packaged as `wovengames-engine-<ver>.tar.xz` | steamplay-mac |
| `notproton/` | Steam hook dylib, signature DB, lsteamclient, steam.exe shim, helpers, the compat tool `run` script | NotProton |
| `cli/` | Swift package: `WovenCore` (all the logic), the `woven` CLI and the `WovenGames` SwiftUI app (`Sources/WovenGamesApp`) | new |
| `compat/` | per-game known-good settings (`<appid>.env`) and the checked Steam builds (`steam-builds.json`) | new |
| `.github/workflows/` | tests, releases, daily Steam build check | new |

`notproton/` stays whole so upstream fixes still merge cleanly. The split into `steamhook/` and `bridge/`
that this plan used to target is shelved. `notproton/app` (NotProton's own app) isn't built, but it can't be
deleted: `engine/scripts/fetch-valve-bridge.sh` and `package-release.sh` read
`notproton/app/Sources/NotProtonApp/Resources/valve-packages.manifest`, the list of Valve DLLs to fetch.

The engine's work tree is `~/Library/Developer/WovenGames/engine` (about 15 GB), outside the repo because the repo
path contains spaces. It used to be `~/Library/Caches`, which macOS purged.

Runtime data lives in `~/Library/Application Support/WovenGames/`: `runners/` (D3DMetal goes into the runner's
`lib/renderers/d3dmetal`), `prefixes/<name>/` (only for `woven prefix` and `woven run`), `games/<appid>.env` (the user's per-game settings), `compat/` (known-good settings), `global.env`, `launchers/`
(per-game .app bundles), `backups/` (Steam's Info.plist), `logs/` and the hook log `wovengames.log`.
Steam games get one Wine prefix each where Proton keeps them: `<Steam library>/steamapps/compatdata/<appid>/pfx`,
with the launch log `wovengames-run.log` next to it.

**CrossOver compatibility shim: dropped.** Because we replace NotProton's CrossOver dependency
directly, nothing needs a fake CrossOver anymore.

## 3. `woven` CLI

```
woven doctor                              # Mac, Rosetta, disk space, engine and backends, Steam build, hook, pin, App Management
woven install [--latest]                  # engine + D3DMetal + Valve's Steam DLLs from a release, each hash-checked
woven setup                               # install a local engine build instead
woven runner list|install|use
woven prefix list|create|delete <id>
woven backend detect <game.exe>           # reads the game's PE imports and prints the auto-picked backend
woven run [--backend X] <exe>             # run any Windows exe (games outside Steam, testing)
woven steam status|builds|update|patch|unpatch|pin|unpin|log
woven games list|diagnose|quit
woven games add <exe> [--name N] [-- args] | play <id> | remove <id>   # Windows games from outside Steam
woven snapshot list|take|restore|delete <appid>   # prefix snapshots (APFS clones)
woven uninstall [--delete-prefixes] [--dry-run]
woven compat sync                         # fetch the newest known-good settings from GitHub
woven update                              # app/engine updates
woven report                              # problem report zip, personal data removed
```

## 4. Milestones

| # | Goal | Status |
|---|---|---|
| M0 | Repo scaffold: git, GPL-3, NOTICE/attribution, fork imports at pinned commits (UPSTREAM.md) | ✅ done |
| M1 | **Engine**: build the runner locally (~20–30 min, ~15 GB) | ✅ done: `tests/probe-backends.sh` passes all backends on an M4 |
| M2 | **CLI**: `woven` with doctor/runner/prefix/backend/run | ✅ done: d3dprobe runs via `woven run`, auto backend |
| M3 | **Steam integration**: patch, pin, register the compat tool, rename notproton→wovengames | ✅ done 2026-10-10: Billie's Wheelie (Unity, app 3180310) installs and plays from macOS Steam on DXMT, Steam build 1788652215 |
| M4 | **App**: onboarding, per-game settings, one-click uninstall that restores Steam | ✅ done (uninstall in v0.3): setup assistant (Mac → engine → App Management → Steam), Status page, Games library (art, Play/Force Quit, launch problem cards, per-game backend/HUD/Retina/msync), menu bar companion, Settings, Report a Problem, Restore Steam, and `woven uninstall` / Uninstall WovenGames… |
| M5 | **Distribution**: CI builds the runner and app and publishes Releases; Steam build tracking | ✅ done: releases 0.1.0, 0.1.1, 0.2.0-beta.1, 0.2.0 and 0.2.1 built by `release.yml`. `woven install` and the app install from releases. The daily `steam-watch` workflow checks new Steam builds offline, commits the results to `compat/steam-builds.json` and opens an issue if a build breaks the hook |

**M5 decisions (2026-10-10):** release builds run on GitHub Actions' Apple Silicon runners (free for public
repos). Releases do **not** contain D3DMetal: the app downloads Gcenx's hash-pinned GPTK repack on first run,
so we never redistribute Apple's files.

**Signing (decided 2026-10-14, final):** releases are ad-hoc signed. There will be **no Apple Developer ID and
no notarization**, so users right-click → Open on first launch. This isn't an open question; design around it.

### v0.3 (scope agreed 2026-10-14)

| # | Item | Size | Status |
|---|---|---|---|
| I1 | UE5 D3D12 on D3DMetal: reproduce the `DXGIAdapter::QueryVideoMemoryInfo` spin from Double Exposure, then patch | L | 🟡 lead: D3DMetal reports a 24 GB budget on a 16 GB Mac (`d3dprobe`); unconfirmed: Expedition 33 (UE5 D3D12) runs on D3DMetal with no menu hang, so the hang is specific to Double Exposure, and capping its texture pool changed nothing |
| I2 | Launch problem cards: move launch options placed before `%command%` into `games/<appid>.env` with one click; after a failed launch, suggest the next backend (and `-dx11` for UE games on DXMT) | S–M | ✅ |
| I3 | Fixtures that check the shell `detect_d3d` and Swift `BackendDetector` pick the same backend, run in CI | S | ✅ 25 cases |
| I4 | `woven doctor` checks the App Management permission | S | ✅ |
| F1 | `woven uninstall [--delete-prefixes]` and an app menu item: restore Steam, remove the compat tool, runners, launchers and support folder; game prefixes are kept by default (finishes M4) | M | ✅ |
| F2 | Prefix snapshots as APFS clones (instant, no extra space), taken automatically before engine updates, with restore | M | ✅ `woven snapshot`, game page menu |
| F3 | Non-Steam Windows games (GOG, itch, ...) in the Games library: own prefix, backend detection, launcher bundle and Game Mode | M–L | ✅ `woven games add/play/remove`, + on the Games page |
| F4 | Per-game runner (`WOVEN_RUNNER=<id>`), so a patched engine can be tried on one game | M | ✅ |

Build order: I3, I4, F1 → F4 (needed to test I1 safely) → I1 → I2 → F2 → F3.
Later: per-game Windows version and virtual desktop, MetalFX upscaling, sharing working settings from the app,
prefix templates and persistent shader caches (once measured).

### Tested games

| Game | Engine / API | Result |
|---|---|---|
| Billie's Wheelie (3180310) | Unity 2022.3, D3D11 | ✅ smooth on DXMT (after the Unity detection fix; wined3d was broken) |
| Life is Strange: Double Exposure (1874000) | UE5, D3D12 | 🟡 D3D12/D3DMetal hangs in the menu (spins in `DXGIAdapter::QueryVideoMemoryInfo`). `-dx11` on DXMT: gameplay ~45 fps with a few hitches. Menu: exclusive fullscreen at native 2560×1664 lands in the top-left corner without Retina mode (`WOVEN_RETINA=1` fixes it); the title scene is GPU-bound at ~337 ms/frame at native resolution (`compat/1874000.env`) |
| Clair Obscur: Expedition 33 (1903340) | UE5, D3D12 | 🟡 starts and plays on D3DMetal (picked automatically), no menu hang; one or two visual quirks. MacBook Air M4 16 GB, title screen, median fps: 2560×1664 native 37 fps (gameplay 8–10 fps on Low, player report), 1470×956 87 fps, 1280×832 103 fps (2.3–2.8×). GPU at 98%: GPU-bound by resolution. No fps change from FSR 4 off, `r.Streaming.PoolSize=2048`, `D3DM_SUPPORT_DXR=0` or a 30 fps cap, so the D3DMetal 24 GB budget lead does not explain this game's speed. Chip reached ~88 °C; a fanless Air throttles in longer sessions. DXMT with `-dx11` also starts, at about half the memory; fps not measured yet |

### Known quirks

- macOS Steam runs a `KEY=value` placed *before* `%command%` as the program ("OS Error 260"). Options must come
  after it: `%command% MTL_HUD_ENABLED=1`. The app writes settings to `games/<appid>.env` instead, and
  `woven games diagnose` / the launch problem cards flag misplaced options.
- `NOTPROTON_*` launch-option variables still work as aliases of `WOVEN_*`.
- The hook logs `rtti: no unique type name ...CompatManager_GetCompatTools...` on build 1788652215. Harmless so
  far, but watch it ([NotProton#92](https://github.com/NotProtonNot/NotProton/issues/92)).

## 5. Things you'll need to do yourself (I can't do these for you)

- Grant **App Management** permission in System Settings so we can modify Steam.app.
- Sign in to Steam yourself; WovenGames never handles credentials.
- D3DMetal comes from Gcenx's hash-pinned repack of Apple's GPTK 3.0, which Apple's license allows for personal,
  non-commercial use. WovenGames downloads it on the user's Mac and never redistributes it.

## 6. Risks

- **Steam pinning:** Valve may eventually force updates. Each new Steam build needs a signature-DB update.
- **Modifying Steam.app** (injection and re-signing) isn't sanctioned by Valve; there's an unknown account risk.
- **Rosetta 2:** Apple says macOS 27 is the last release with full Rosetta. Later versions keep only a subset aimed at older games.
  FEX (an alternative x86 emulator) is the long-term fallback; NotProton already supports a FEX runner.
- **Not supported:** games with kernel-level anti-cheat.
- **Licensing:** `lsteamclient` and the Steamworks headers fall under Valve's Steamworks SDK license, not GPL. Valve DLLs
  and D3DMetal are downloaded and hash-checked at install time and **never committed** to the repo.
