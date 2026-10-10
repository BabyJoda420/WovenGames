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

| App id | Game | Settings |
|---|---|---|
| 1874000 | Life is Strange: Double Exposure | DXMT, `-dx11` (D3D12 hangs in the menu) |
