# WovenGames — Plan

Play your Windows Steam library from the **native macOS Steam client** on Apple Silicon.
There's one Steam (the Mac one), real Install and Play buttons, and no CrossOver.

- **License:** GPL-3.0. Parts derived from Valve code keep Valve's licenses. Details below.
- **Basis:** a fork of [NotProton](https://github.com/NotProtonNot/NotProton) (the Steam hook and Steam bridge) and
  [steamplay-mac](https://github.com/thedankest/steamplay-mac) (a Wine engine built from CrossOver's public sources).
- **First test game:** Clair Obscur: Expedition 33 (UE5, DX12 → D3DMetal).

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
comes out, we update the hook's signature database and then lift the pin.

## 2. Repository layout

Current state: `engine/` (steamplay-mac) and `notproton/` (the NotProton fork, kept whole so upstream fixes still merge cleanly).
The split into `steamhook/` and `bridge/` below is the target layout, done during M3.

Engine build output goes to `~/Library/Caches/WovenGames/engine` (about 15 GB), because the repo path contains spaces.

### Target layout

| Path | What it holds | Origin |
|---|---|---|
| `engine/` | Wine runner build scripts and patch series. Output: `wovengames-runner-<ver>.tar.zst` | steamplay-mac |
| `steamhook/` | the dylib injected into Steam, signature DB, web UI patches | NotProton `dylib/` |
| `bridge/` | lsteamclient (macOS port), steam.exe shim, ntdll routing | NotProton + Valve Proton |
| `cli/` | `woven` Swift command-line tool (the engine API that everything else calls) | new |
| `app/` | `WovenGames.app` SwiftUI app: onboarding, per-game settings, logs, uninstall | new (borrows from NotProton `app/`) |
| `compat/` | per-game overrides (backend, env, DLL overrides) as JSON | new |
| `docs/` | install, troubleshooting, compatibility list | new |

Runtime data lives in `~/Library/Application Support/WovenGames/`: `runners/`, `prefixes/<appid>/`
(one Wine prefix per game, like Proton's compatdata), `d3dmetal/`, `logs/`.

**CrossOver compatibility shim: dropped.** Because we replace NotProton's CrossOver dependency
directly, nothing needs a fake CrossOver anymore.

## 3. `woven` CLI (milestone 2 target)

```
woven doctor                      # Rosetta, Steam build, permissions, disk space, D3DMetal status
woven runner install|list|use     # install/select a Wine runner
woven d3dmetal import <GPTK.dmg>  # import Apple's D3DMetal (you download it from Apple yourself)
woven prefix create|delete <id>
woven backend detect <game.exe>   # reads the game's PE imports and prints the auto-picked backend
woven run [--backend X] <exe>     # run any Windows exe (games outside Steam, testing)
woven steam status|patch|unpatch  # inject or remove the hook; back up and restore Steam's Info.plist and signature
woven steam pin|unpin             # writes or removes steam.cfg
```

## 4. Milestones

| # | Goal | Done when |
|---|---|---|
| M0 | Repo scaffold: git, GPL-3, NOTICE/attribution, fork imports at pinned commits (UPSTREAM.md) | ✅ done |
| M1 | **Engine**: build the runner locally (~20–30 min, ~15 GB) | ✅ done: `tests/probe-backends.sh` passes all backends on an M4 |
| M2 | **CLI**: `woven` with doctor/runner/prefix/backend/run | ✅ done: d3dprobe runs via `woven run`, auto backend |
| M3 | **Steam integration**: patch, pin, register the compat tool, rename notproton→wovengames (paths, tool name, dylib) | ✅ done 2026-10-10: Billie's Wheelie (Unity, app 3180310) installs and plays from macOS Steam on DXMT, Steam build 1788652215. Expedition 33 still to do once ~55 GB is free |
| M4 | **App**: SwiftUI onboarding (permissions, D3DMetal import, Steam patch), per-game settings, one-click uninstall that restores Steam | 🟡 in progress: WovenGames.app (Status + Games pages), per-game settings, known-good settings database (`compat/`), Update Hook. Enabling per game isn't needed: the hook defaults every unmapped Windows-only game to WovenGames. Setup assistant with an App Management walkthrough (probe, open the settings pane, check again, quit & reopen) |
| M5 | **Distribution**: CI builds the runner and app and publishes Releases, so users never compile; Steam-build tracking | 🟡 release package, `woven install` (fetches D3DMetal and Valve's DLLs, verified identical to a local setup, all backends pass), app installs from releases, workflows ready. First run happens once the repo is public. Steam build tracking: `woven steam builds`, a Status-page section, `doctor`, `check-steam-build.sh` (offline signature check against Valve's CDN) and a daily `steam-watch` workflow that opens PRs for new builds |

**M5 decisions (2026-10-10):** release builds run on GitHub Actions' Apple Silicon runners, once the repo is public, so the minutes are free. Releases do **not** contain D3DMetal: the app downloads Gcenx's hash-pinned GPTK repack on first run, so we never redistribute Apple's files. Builds are ad-hoc signed for now (no Developer ID): users right-click → Open on first launch.

### Tested games

| Game | Engine / API | Result |
|---|---|---|
| Billie's Wheelie (3180310) | Unity 2022.3, D3D11 | ✅ smooth on DXMT (after the Unity detection fix; wined3d was broken) |
| Life is Strange: Double Exposure (1874000) | UE5, D3D12 | 🟡 D3D12/D3DMetal hangs in the menu. `-dx11` on DXMT: gameplay ~45 fps with a few hitches. Menu: exclusive fullscreen at native 2560×1664 lands in the top-left corner without Retina mode (`WOVEN_RETINA=1` fixes it); the title scene is GPU-bound at ~337 ms/frame at native resolution (`compat/1874000.env`) |

### Notes for M4 (from M3 testing)

- macOS Steam runs a `KEY=value` placed *before* `%command%` as the program ("OS Error 260"). Options must come after it:
  `%command% MTL_HUD_ENABLED=1`. The app's per-game settings should write them in that form, or the hook should rewrite them.
- The Makefile still builds `out/notproton.dylib`, and `woven setup` installs it as `wovengames.dylib`. Rename the build target too.
- The `NOTPROTON_*` launch-option variables (`NOTPROTON_RETINA`, `NOTPROTON_SYSHUD`, ...) still carry the old name. Add `WOVEN_*` aliases.
- The hook logs `rtti: no unique type name ...CompatManager_GetCompatTools...` on build 1788652215. Harmless so far, but watch it ([NotProton#92](https://github.com/NotProtonNot/NotProton/issues/92)).

## 5. Things you'll need to do yourself (I can't do these for you)

- D3DMetal: for local builds the engine fetches Gcenx's hash-pinned repack of Apple's GPTK 3.0, which Apple's license allows for personal, non-commercial use. For **public releases (M5)** we must make sure we don't redistribute it beyond those terms, e.g. by having the app download it on the user's Mac.
- Grant **App Management** permission in System Settings so we can modify Steam.app.
- Sign in to Steam yourself; WovenGames never handles credentials.
- Later (M5): an Apple Developer ID (99 USD/year) if you want signed, notarized releases. Without one, users must right-click → Open.

## 6. Risks

- **Steam pinning:** Valve may eventually force updates. Each new Steam build needs a signature-DB update.
- **Modifying Steam.app** (injection and re-signing) isn't sanctioned by Valve; there's an unknown account risk.
- **Rosetta 2:** Apple says macOS 27 is the last release with full Rosetta. Later versions keep only a subset aimed at older games.
  FEX (an alternative x86 emulator) is the long-term fallback; NotProton already supports a FEX runner.
- **Not supported:** games with kernel-level anti-cheat.
- **Licensing:** `lsteamclient` and the Steamworks headers fall under Valve's Steamworks SDK license, not GPL. Valve DLLs
  and D3DMetal are downloaded and hash-checked at install time and **never committed** to the repo.
