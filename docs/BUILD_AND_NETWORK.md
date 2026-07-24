# Native build and TCP networking guide

This guide covers local play, LAN tests, public Internet tests, and native
desktop/mobile exports. The project intentionally has no HTML client: web
browsers cannot open arbitrary raw TCP sockets, while Godot's native
`StreamPeerTCP` can.

## 1. Requirements

- Python 3.10 or newer for the dedicated server. It uses only the standard
  library; there is no package install step.
- Godot 4.3 or newer for the client.
- Godot export templates matching the editor version.
- For Android: a supported JDK and Android SDK configured in Godot.
- For iOS: macOS, Xcode, an Apple developer identity, and a provisioning team.

The client uses the GL Compatibility renderer, which is the broadest native
choice for older PCs and phones.

## 2. Verify and start the server

Open a shell in the directory that contains `strike_protocol`.

Run the dependency-free integration test first:

```powershell
python -m strike_protocol.server.test_server
```

Start a local/LAN server on TCP port `8765`:

```powershell
python -m strike_protocol.server.server --host 0.0.0.0 --port 8765
```

For packet and connection diagnostics, add `--verbose`:

```powershell
python -m strike_protocol.server.server --host 0.0.0.0 --port 8765 --verbose
```

Useful optional tuning flags are `--tick-rate 30` and `--idle-timeout 20`.
Stop the server with `Ctrl+C`. The server process must remain running for every
online client; offline Training does not need it.

## 3. Run the Godot project

In the Godot Project Manager, choose **Import**, browse to
`strike_protocol/client/project.godot`, then run the project. No add-on install
or asset import step is required. Godot will generate its local `.godot` import
cache when the project first opens.

Address selection:

| Client location | Address entered in the game |
| --- | --- |
| Same computer as server | `127.0.0.1`, port `8765` |
| Another device on the same Wi-Fi/LAN | Server computer's LAN IPv4, such as `192.168.1.20`, port `8765` |
| Across the Internet | Server DNS name or public IPv4, port mapped to `8765/TCP` |

Do not enter `0.0.0.0`; it only means "listen on all local interfaces." Do not
enter `127.0.0.1` on a phone unless the server actually runs on that phone.

## 4. LAN setup

1. Connect the server and all clients to the same local network. Guest Wi-Fi
   often isolates devices and will not work.
2. Find the server computer's IPv4 address. On Windows, run `ipconfig` and use
   the active adapter's IPv4 Address.
3. Allow inbound TCP `8765` in the server computer's firewall. Keep the rule on
   the Private profile where possible. An administrator can create a Windows
   rule with:

   ```powershell
   New-NetFirewallRule -DisplayName "Strike Protocol TCP 8765" -Direction Inbound -Profile Private -Protocol TCP -LocalPort 8765 -Action Allow
   ```

4. From another Windows computer, verify reachability before opening the game:

   ```powershell
   Test-NetConnection -ComputerName 192.168.1.20 -Port 8765
   ```

Replace the example IP with the server's actual address. If the test fails,
check that the Python process is still running, both devices are on the same
subnet, the firewall rule applies to the active network profile, and Wi-Fi
client isolation is disabled.

## 5. Internet setup

Raw TCP needs an end-to-end route. On a home connection:

1. Give the server computer a stable LAN address (DHCP reservation is best).
2. In the router, forward an external TCP port, normally `8765`, to the server
   LAN address and internal TCP port `8765`.
3. Allow that TCP port in the operating-system firewall.
4. Give remote players the router's public IPv4 or a DNS name, never its private
   `192.168.x.x` address.

Forward **TCP**, not UDP. Some providers use carrier-grade NAT (CGNAT), which
prevents inbound port forwarding. In that case use a VPS, request a public IP,
or put players and server on a private overlay network such as WireGuard or
Tailscale. A cloud server also needs an inbound TCP rule in its security group.

Security limits of the current prototype:

- Messages and player names are plaintext JSON over TCP.
- There is no account authentication or TLS certificate check.
- The server validates gameplay and message sizes, but it is not a complete
  anti-abuse gateway.

For testing with known players, a trusted LAN or private VPN is the simplest
deployment. Before a public release, add TLS, identity/authentication,
connection rate limits, logs/metrics, and an update strategy. Never expose
admin services such as SSH just because the game port is open.

## 6. Desktop export

1. In Godot, open **Editor > Manage Export Templates** and install the template
   version matching the editor.
2. Open **Project > Export** and add a Windows Desktop, Linux/BSD, or macOS
   preset.
3. Keep `project.godot`, `main.tscn`, scripts, and imported assets in the export.
   The default resource filter includes them.
4. Set the executable name and architecture, then choose **Export Project**.

For macOS distribution, sign and notarize the `.app`. For Windows distribution,
code signing is optional for local testing but reduces SmartScreen warnings.
The Python server remains a separate process or host; it is not embedded in the
Godot client export.

## 7. Android export

1. Install matching Godot export templates.
2. Install/configure the Android SDK and JDK under Godot **Editor Settings >
   Export > Android**.
3. Add an Android preset under **Project > Export**.
4. Choose a unique package name, for example `com.example.strikeprotocol`, and
   landscape orientation.
5. Ensure the Android `INTERNET` permission is enabled in the export preset.
6. Export a debug APK for device testing. For release, configure a release
   keystore and export an AAB for Play distribution.

The phone must connect to the computer's LAN IP, not `127.0.0.1`. Android's
cleartext HTTP setting does not replace the socket permission; this project
uses a raw TCP socket rather than HTTP.

## 8. iOS export

1. On macOS, install Xcode and matching Godot export templates.
2. Add an iOS preset, then set a unique bundle identifier, development team,
   signing identity, and provisioning profile.
3. Export the Xcode project, open it in Xcode, select a real device/team, and
   build or archive it.
4. For connections to LAN addresses on iOS 14+, add a clear
   `NSLocalNetworkUsageDescription` string to the app's `Info.plist`; the user
   must allow local-network access when prompted.

Test on a physical iPhone/iPad because simulator routing and permissions can
differ. App Store distribution also requires valid signing, privacy metadata,
and review of the plaintext-network security limits described above.

## 9. Asset replacement and export size

The client ships with original PNG fallbacks and SVG sources in
`client/assets`. Their source and license are recorded in
`client/assets/ATTRIBUTION.md`. Godot imports only assets referenced by the
project/export resource filter. When replacing them with an online pack:

1. Confirm the exact asset license at the source page.
2. Preserve alpha transparency and roughly the existing canvas dimensions.
3. Preserve filenames, or update every corresponding `res://assets/...` path.
4. Record the creator, URL, asset version/date, and license in
   `ATTRIBUTION.md` before distributing the build.

Kenney's Topdown Shooter, UI Pack, and Digital Audio packs are listed as CC0
starting points. They are recommendations, not files currently bundled in the
repository.

## 10. Troubleshooting checklist

| Symptom | Most likely check |
| --- | --- |
| Connection immediately fails | Server process, host spelling, TCP port, firewall |
| PC client works but phone fails | Phone used `127.0.0.1`, guest Wi-Fi isolation, mobile permission |
| LAN works but Internet fails | Router TCP forwarding, public IP, CGNAT, cloud security group |
| Connects then drops | Server idle timeout, mobile sleep/network switch, unstable NAT |
| Controls show but nothing moves | Join/ready state, server logs, protocol version |
| Android build has no network | `INTERNET` permission and actual LAN/public address |

Protocol framing, message examples, limits, and server-authoritative behavior
are documented in `strike_protocol/protocol.md`.
