# Cinderhold

Co-op voxel wave survival. Hold a ruined frontier outpost through the night against waves of ember-eyed Husks, with up to four friends on Windows, macOS, Linux and Android.

Everything in the game is generated in code: the voxel models, the map, and even the audio, which is synthesized at startup. There are no asset files beyond two open-licensed fonts.

## Playing

- **Solo**: Main menu → Play Solo.
- **Co-op**: one player picks **Host Co-op**. Friends pick **Join Co-op** and type the host's address. The lobby lists the host's LAN, ZeroTier or Tailscale addresses. The game uses **UDP port 47820**.
- Earn points by hitting and killing Husks. Spend them on doors, weapons on the walls, Tonics (perks), the Relic Cache (a random weapon) and the Ember Forge (weapon upgrades).
- When a teammate goes down, hold **Interact** next to them to revive them before they bleed out.

Default keys: WASD, mouse, `Shift` sprint, `C` crouch, `Space` jump, `R` reload, `E` interact, `V` melee, `1`/`2`/wheel to swap weapons, `Tab` scoreboard, `Esc` menu. Gamepads work, and phones get touch controls. Everything can be rebound in Settings.

## Updates (no reinstalling)

Installed copies update themselves from this repository's releases. Each release includes a small content patch (`cinderhold-X.Y.Z.pck` and `manifest.json`). The game downloads the patch, checks its SHA-256 and applies it on the next launch. A full download is only needed when a release moves to a new Godot engine version, and the game says so when that happens.

The repository is private, so each install needs a GitHub token to read releases:

1. Create a [fine-grained token](https://github.com/settings/personal-access-tokens/new) with access to **only** `GPTmadeit/cinderhold` and the permission **Contents: Read-only**.
2. In the game, open **Settings → Updates** and paste it. The token is stored only on that device.
3. Click **Check for updates**. It also checks on startup, and the main menu shows a badge when an update is available.

## Releasing

```bash
scripts/tools/set_version.sh 0.2.0     # bumps version.gd, project.godot, export presets
git commit -am "Release 0.2.0" && git tag v0.2.0
git push && git push --tags            # CI builds every platform + the patch and publishes the release
```

The tag must match `scripts/core/version.gd`. CI needs the repo secrets `ANDROID_KEYSTORE_B64` and `ANDROID_KEYSTORE_PASSWORD`, which are set already. The keystore lives outside the repo.

## Development

- Godot **4.7.2** (standard build, no .NET).
- `godot --path . -- --solo` starts straight into a solo match.
- `tests/shot.sh out.png 8 --solo` renders a screenshot on a hidden Hyprland workspace, and `--fps-log 14` benchmarks instead.
- `godot --headless --path . res://tests/compile_all.tscn` compile-checks every script.

Layout: `scripts/core` (settings, networking, audio synth, updater), `scripts/voxel` (greedy voxel mesher and all the models), `scripts/world/arena.gd` (map, doors, zones, enemy flow fields), `scripts/game` (match rules, weapons, perks), `scripts/player`, `scripts/enemy`, `scripts/ui`.

Fonts: Bungee and Rajdhani, under the SIL Open Font License (see `assets/fonts`).
