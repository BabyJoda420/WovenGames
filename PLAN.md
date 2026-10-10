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
Steam is therefore pinned with `steam.cfg` → `BootStrapperInhibitAll=Enable`. When a new Steam build
comes out, we update the hook's signature database and then lift the pin.

## 2. Repository layout (planned)

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
| M0 | Repo scaffold: git, GPL-3, NOTICE/attribution, fork imports, rename notproton→wovengames | builds unchanged from the forks |
| M1 | **Engine**: build the runner locally (~20–30 min, ~15 GB) | `d3dprobe` passes on DXMT, D3DMetal and wined3d |
| M2 | **CLI**: `woven` with doctor/runner/prefix/backend/run | a Windows exe runs via `woven run` |
| M3 | **Steam integration**: patch, pin and register the compat tool | **Expedition 33 installs and plays from macOS Steam's own buttons** |
| M4 | **App**: SwiftUI onboarding (permissions, D3DMetal import, Steam patch), per-game settings, one-click uninstall that restores Steam | a non-technical user can set it up |
| M5 | **Distribution**: CI builds the runner and app and publishes Releases, so users never compile; Steam-build tracking | download, open, play |

## 5. Things you'll need to do yourself (I can't do these for you)

- Download **Apple Game Porting Toolkit 3.0** (for D3DMetal) from developer.apple.com. It needs your Apple ID sign-in, and Apple's license doesn't let us redistribute it.
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
