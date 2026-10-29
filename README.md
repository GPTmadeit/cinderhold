# Cinderhold

Co-op voxel wave survival. Hold a ruined frontier outpost through the night against waves of ember-eyed Husks, with up to four friends on Windows, macOS, Linux and Android.

Everything in the game is generated in code: the voxel models, the map, and even the audio, which is synthesized at startup. There are no asset files beyond two open-licensed fonts. The outpost is built from 6.25 cm voxels (recessed mortar, cobbles, tiles, planks, grass) and the characters, props and weapons from 3 cm ones.

## Playing

- **Solo**: Main menu → Play Solo.
- **Co-op**: one player picks **Host Co-op**. Friends pick **Join Co-op** and type the host's address. The game uses **UDP port 47820**.
  - When hosting, the game asks your router to open the port (UPnP) and shows your **internet address** in the lobby, with a button to copy it. If the router has UPnP turned off, the lobby says so: forward UDP 47820 to your computer by hand, or use Tailscale or ZeroTier (the lobby lists those addresses too).
  - Everyone needs the same version (0.2.0 or later) to play together.
- **Friends**: Main menu → **Friends** shows your friend code. Add friends by code, or with **+ Friend** in a lobby. Friends you've played with can be joined straight from the list.
- **Encryption**: every co-op connection is encrypted (DTLS). Each install makes its own key and certificate on first launch. Joining a friend from the list also checks that it really is them (their certificate is pinned), and every joining player proves their friend code by signing a challenge from the host. Updates are downloaded over HTTPS only.
- Earn points by hitting and killing Husks. Spend them on doors, weapons on the walls, Tonics (perks), the Relic Cache (a random weapon) and the Ember Forge (weapon upgrades).
- When a teammate goes down, hold **Interact** next to them to revive them before they bleed out.
- Grenades: you start with two, get back up to two every round, and a Resupply fills you to four. They bounce, then go off after about two seconds, and never hurt survivors.
- Aiming down sights lines the gun's own sight (iron sights, red dot or scope) up with where shots go.

Default keys: WASD, mouse, `Shift` sprint, `C` crouch, `Space` jump, `R` reload, `E` interact, `V` melee (knife), `G` grenade, `1`/`2`/wheel to swap weapons, `Tab` scoreboard, `Esc` menu. Gamepads work (left bumper throws a grenade), and phones get touch controls. Everything can be rebound in Settings, which also has separate mouse and aim sensitivities.

## Updates (no reinstalling)

Installed copies update themselves from this repository's releases. Each release includes a small content patch (`cinderhold-X.Y.Z.pck` and `manifest.json`). The game downloads the patch, checks its SHA-256 and applies it on the next launch. A full download is only needed when a release moves to a new Godot engine version, and the game says so when that happens.

No account or token is needed. **Settings → Updates** has the controls, and the main menu shows a badge when an update is available. A GitHub token can be pasted there if GitHub ever rate-limits update checks from your network, but it's optional.

## Crash reports

Each session keeps a small log in `user://diagnostics`: a heartbeat every few seconds (scene, round, frame rate, memory) plus engine and script errors. If a session ends without a clean exit while the game was in the foreground, the next launch turns that log into a report, and the main menu offers **Copy report**. On Android 11 and later, the report also includes the system's reason for the exit, such as low memory, a native crash or not responding. Nothing leaves the device unless the player copies the report.

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
- `res://tests/dtls_pinning.tscn` checks encryption pinning, `res://tests/anim_gallery.tscn` shows every animation pose, and `res://tests/terrain_bench.tscn` times the map build.
- Dev flags after `--`: `--cam x,z,yaw,pitch` holds the camera, `--act kestrel@4,aim@6,melee@8,grenade@10` scripts actions for screenshots, `--bot 40` plays a match, `--host 2` / `--join 127.0.0.1` run co-op.

Layout: `scripts/core` (settings, networking, identity and friends, UPnP, audio synth, updater), `scripts/voxel` (greedy voxel mesher and all the models), `scripts/world` (`arena.gd`: map, doors, vents, enemy flow fields; `terrain.gd`: the bit-packed terrain mesher), `scripts/game` (match rules, weapons, perks, grenades, effects, procedural animation), `scripts/player`, `scripts/enemy`, `scripts/ui`.

Fonts: Bungee and Rajdhani, under the SIL Open Font License (see `assets/fonts`).
