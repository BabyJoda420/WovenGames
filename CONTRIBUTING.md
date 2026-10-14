# Contributing to WovenGames

Thanks for your interest in helping with WovenGames! Here is how to report issues, test games, and contribute code.

## Reporting Bugs and Game Compatibility

- **Report a bug:** Open an issue using the [Bug report](https://github.com/BabyJoda420/WovenGames/issues/new?template=bug_report.yml) template. Please include a problem report zip from **Help → Report a Problem** in the app (or run `woven report` in Terminal). This collects diagnostic logs with your Steam account name and personal details automatically removed.
- **Report game compatibility:** Let us know what works and what settings helped by opening a [Game report](https://github.com/BabyJoda420/WovenGames/issues/new?template=game_report.yml).

Before opening an issue, check the [Problems section in the README](https://github.com/BabyJoda420/WovenGames#problems) for known issues and quick fixes.

## Building from Source

For prerequisites and build commands for both the engine and the Swift app/CLI tool, see the [building instructions in the README](https://github.com/BabyJoda420/WovenGames#building).

## Running Tests

Before submitting code, run the test suites:

- **Swift core and app tests:**
  ```sh
  cd cli && swift test
  ```
- **Shell script linting:**
  ```sh
  shellcheck notproton/dylib/feats/compat_run.sh
  ```

## Making Changes

- **Commits:** Plain, short, factual commit messages; one feature or fix per commit (for example: `Game Mode for games started through a launcher exe`).
- **Changelog:** Every user-visible change gets an entry in `CHANGELOG.md` under "Unreleased" (New / Improved / Fixed), written for players, in the same branch as the change.
- **Target audience:** Keep player-facing text (release notes, README, app UI) clear and friendly for normal Mac users rather than developers.
- **Constraints:** Never commit Apple binaries, Valve proprietary files, or credentials. WovenGames uses ad-hoc codesigning and does not require Apple Developer certificates.
