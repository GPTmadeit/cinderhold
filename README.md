# Cinderhold

Co-op voxel wave survival. Hold out through the night against waves of ember-eyed Husks, with up to four friends on Windows, macOS, Linux and Android, on two maps:

- **Cinderhold Outpost**: a ruined frontier fort of barracks, a great hall, a courtyard and a garden.
- **Times Square**: 42nd to 47th Street around the bowtie where Broadway crosses 7th Avenue, built from Manhattan's real street layout and buildings (OpenStreetMap). It's at one fifth of real size, with heights scaled less so the streets stay canyons. You start in the square between 44th and 45th; barricades open Duffy Square and the red steps to the north, One Times Square to the south, and the side streets.

Everything in the game is generated in code: the voxel models, the maps, and even the audio, which is synthesized at startup. There are no asset files beyond two open-licensed fonts. The outpost is built from 6.25 cm voxels (recessed mortar, cobbles, tiles, planks, grass), Times Square's street level from 12.5 cm ones (asphalt, crossings, curbs, storefronts with signs), and the characters, props and weapons from 3 cm ones.

## Playing

- **Solo**: Main menu → Play Solo. The **Map** button next to it picks the map.
- **Co-op**: one player picks **Host Co-op**. Friends pick **Join Co-op** and type the host's address. The game uses **UDP port 47820**.
  - When hosting, the game asks your router to open the port (UPnP) and shows your **internet address** in the lobby, with a button to copy it. If the router has UPnP turned off, the lobby says so: forward UDP 47820 to your computer by hand, or use Tailscale or ZeroTier (the lobby lists those addresses too).
  - The host picks the map in the lobby; everyone else sees it there.
  - Everyone needs the same version (0.3.0 or later) to play together.
- **Friends**: Main menu → **Friends** shows your friend code. Add friends by code, or with **+ Friend** in a lobby. Friends you've played with can be joined straight from the list.
  - **Status and notifications**: once you've both added each other, you see whether a friend is online and what they're doing (in the menu, in a lobby, hosting, or in a match on a given map and round), and you get a notice when they come online, start hosting, send a friend request or invite you. **Invite** buttons in the lobby send your friends a one-click join.
  - This goes through a small relay (a Cloudflare Worker, source in `relay/`). It only stores friend codes, display names, who added whom and when you were last seen. Your status, and your internet address while you host, go only to friends who added you back. Your device proves its friend code by signing a challenge, so nobody can pose as you. **Settings → Gameplay → Friend status** turns all of this off.
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
- `res://tests/dtls_pinning.tscn` checks encryption pinning, `res://tests/anim_gallery.tscn` shows every animation pose, and `res://tests/terrain_bench.tscn` and `res://tests/city_bench.tscn` time the map builds.
- Dev flags after `--`: `--map times_square` picks the map, `--cam x,z,yaw,pitch[,height]` holds the camera, `--act kestrel@4,aim@6,melee@8,grenade@10` scripts actions for screenshots, `--bot 40` plays a match, `--host 2` / `--join 127.0.0.1` run co-op, `--relay ws://127.0.0.1:8787` uses a local friend relay.

Layout: `scripts/core` (settings, networking, identity, friends and presence, UPnP, audio synth, updater), `scripts/voxel` (greedy voxel mesher and all the models), `scripts/world` (`arena.gd`: doors, vents, enemy flow fields; `terrain.gd`: the bit-packed terrain mesher; `maps/`: one file per map, plus Times Square's builder and generated data), `scripts/game` (match rules, weapons, perks, grenades, effects, procedural animation), `scripts/player`, `scripts/enemy`, `scripts/ui`.

### Times Square map data

`tools/manhattan/build_times_square.py` turns an OpenStreetMap extract (buildings and their 3D parts, streets, subway entrances) into `scripts/world/maps/times_square_data.gd`: the 1 m gameplay grid, a street-level raster at 8 cells per metre, the skyline at 4 per metre, building heights and kinds. `python3 tools/manhattan/build_times_square.py --fetch osm.json` downloads a fresh extract from the Overpass API (and keeps a copy); `python3 tools/manhattan/build_times_square.py osm.json` rebuilds from a saved one.

### Friend relay

`relay/` is the Cloudflare Worker behind friend status (one Durable Object, WebSocket hibernation, free tier). `npm install`, then `npx wrangler dev` runs it locally and `node test/relay.test.mjs` tests it; `npx wrangler deploy` publishes it.

## Credits

- Fonts: Bungee and Rajdhani, under the SIL Open Font License (see `assets/fonts`).
- Times Square map data © OpenStreetMap contributors, available under the [Open Database License](https://www.openstreetmap.org/copyright). The data derived from it in `scripts/world/maps/times_square_data.gd` is available under the same licence.
