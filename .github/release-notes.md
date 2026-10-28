**Cinderhold** is a co-op voxel wave-survival game for up to four players. Hold a ruined frontier outpost through the night against waves of ember-eyed Husks.

### Downloads

| Platform | File | How to start it |
|---|---|---|
| Windows (64-bit) | `Cinderhold-windows-x86_64.zip` | Unzip and run `Cinderhold.exe`. The build isn't code-signed, so SmartScreen may warn: choose **More info → Run anyway**. |
| macOS (Intel and Apple silicon) | `Cinderhold-macos-universal.zip` | Unzip and open `Cinderhold.app`. It isn't notarized, so the first time, approve it in **System Settings → Privacy & Security → Open Anyway**. |
| Linux (x86-64) | `Cinderhold-linux-x86_64.zip` | Unzip, then `chmod +x Cinderhold.x86_64` and run it. |
| Android | `Cinderhold-android.apk` | Open the APK on your phone and allow installs from that app when asked. |

`cinderhold-{{VERSION}}.pck` and `manifest.json` are the in-game update. You don't need to download them yourself.

### Updating

Installed copies update themselves. Open **Settings → Updates**, or click the badge on the main menu, then **Download update** and **Restart**. No account or token is needed. A full download is only needed when a release changes the game engine, and the game says so when that happens.

### Playing together

One player picks **Host Co-op**. Friends pick **Join Co-op** and enter the host's address, which can be a LAN, ZeroTier or Tailscale IP. The game uses UDP port **47820**.
