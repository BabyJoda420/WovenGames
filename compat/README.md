# Known-good settings per game

One file per Steam app id, `<appid>.env`. `woven setup` installs them to
`~/Library/Application Support/WovenGames/compat/`, and the compat tool's run script reads them
before every launch.

- Lines are `KEY=VALUE`, and `#` starts a comment. Allowed names: `CX_GRAPHICS_BACKEND`
  (`d3dmetal`, `dxmt`, `wined3d`), `WOVEN_GAME_ARGS` (extra game arguments), and `WINE*`, `DXMT_*`,
  `D3DM_*`, `MTL_*`, `ROSETTA_*` (and `NOTPROTON_*`, the older name of `WOVEN_*` settings).
- Priority, highest first: Steam launch options, then the user's settings in the app
  (`games/<appid>.env`), then these files, then `global.env`.
- Say in a comment what fails without the setting, and on which Mac, macOS and Steam build it
  was tested.

## Game reports ("how well it runs")

Files can also include player-facing compatibility notes using lines starting with `#! `:

```sh
#! rating=playable
#! tested=MacBook Air (M4, 16 GB)
#! note=About 35 fps at 1280x832 on the lowest preset. Looks rough, but plays.
#! note=Don't use DXMT: it draws the shadows as a checkerboard.
```

- **`rating`**: `great` (Runs well), `playable` (Playable with compromises), `poor` (Runs poorly), or `broken` (Doesn't work).
- **`tested`**: Mac model, chip, and memory where this was verified (e.g. `MacBook Air (M4, 16 GB)`).
- **`note`**: Short tips for players (up to 6 notes, max 300 characters each). Players read these directly in the WovenGames app, so write in plain, friendly language for gamers.

The run script treats `#!` lines as comments, and `CompatSync` preserves them during upstream updates.

| App id | Game | Settings |
|---|---|---|
| 1874000 | Life is Strange: Double Exposure | DXMT, `-dx11` (D3D12 hangs in the menu) |
| 1903340 | Clair Obscur: Expedition 33 | D3DMetal; report: playable at 1280×832 on a MacBook Air M4 (DXMT breaks shadows) |
