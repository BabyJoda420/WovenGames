# Upstream sources

WovenGames is a fork. The trees below were imported unchanged at these commits, then modified
in this repository's history.

| Directory | Upstream | Branch | Commit | License |
|---|---|---|---|---|
| `notproton/` | https://github.com/Drustburn/NotProton (fork of https://github.com/NotProtonNot/NotProton) | `selfbuilt-wine` | `ff101e690d39334468cdad45454a548eb98d4361` | GPL-3.0, with Valve-licensed parts (see `notproton/NOTICE`) |
| `engine/` | https://github.com/thedankest/steamplay-mac (same as https://github.com/Drustburn/steamplay-mac) | `main` | `b7e1ce16950f` | GPL-3.0 |

`engine/notproton` is a symlink to `../notproton`. It replaces steamplay-mac's git submodule, which pointed at the same commit.

To check what has changed upstream since then, run `git log <commit>..origin/<branch>` in a clone of each repo.
