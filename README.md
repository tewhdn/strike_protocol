# Strike Protocol

中文快速说明：[README.zh-CN.md](README.zh-CN.md)

Strike Protocol is a native Godot 4 top-down arena shooter with a
server-authoritative Python backend. Desktop and mobile builds use a persistent
raw TCP connection with newline-delimited JSON; this is not an HTML or browser
game.

## What is included

- Godot 4.3 client with keyboard/mouse and dual-stick touch controls.
- Python 3.10+ authoritative TCP server with rooms, movement, shooting,
  damage, scoring, respawn, snapshots, heartbeat, and input validation.
- Offline training mode for checking controls without a server.
- Native export path for Windows, Linux, macOS, Android, and iOS.
- Original SVG/PNG placeholder art plus links to online CC0 replacement packs.

## Quick start

Run these commands from the repository directory that contains the
`strike_protocol` folder.

1. Verify the server and protocol:

   ```powershell
   python -m strike_protocol.server.test_server
   ```

   Windows users can run `strike_protocol/run_tests.cmd` instead.

2. Start a TCP server for local and LAN clients:

   ```powershell
   python -m strike_protocol.server.server --host 0.0.0.0 --port 8765
   ```

   On Windows, `strike_protocol/run_server.cmd` or `run_server.ps1` starts the
   same server without requiring the command to be typed manually.

3. In Godot 4.3 or newer, import this project file:

   ```text
   strike_protocol/client/project.godot
   ```

4. Press **F6/F5** in Godot. Use `127.0.0.1:8765` when client and server are
   on the same computer. On a phone or another computer, enter the server
   computer's LAN IPv4 address, for example `192.168.1.20:8765`.

With a Godot executable available on `PATH`, the native client can also be
started directly:

```powershell
godot --path strike_protocol/client
```

## Controls

| Platform | Movement | Aim / fire | Other |
| --- | --- | --- | --- |
| Desktop | `WASD` or arrow keys | Mouse / hold left mouse button | `R` reload, `Esc` leave, `Enter` connect from menu |
| Touchscreen | Left virtual stick | Right virtual stick; move it beyond the dead zone to fire | On-screen actions |

The menu also provides **Training**, which runs an offline local match.

## Project map

```text
strike_protocol/
|-- client/
|   |-- project.godot
|   |-- main.tscn
|   |-- scripts/
|   `-- assets/
|-- server/
|   |-- server.py
|   `-- test_server.py
|-- docs/BUILD_AND_NETWORK.md
|-- protocol.md
`-- protocol.py
```

Read [docs/BUILD_AND_NETWORK.md](docs/BUILD_AND_NETWORK.md) before exporting a
phone build or exposing the server outside a LAN. Wire details and packet
examples are in [protocol.md](protocol.md). Asset origin and replacement links
are in [client/assets/ATTRIBUTION.md](client/assets/ATTRIBUTION.md).

## Art status

The bundled art is locally generated project artwork, not a scraped or
uncredited web pack. It is intentionally lightweight so the game runs
immediately and remains redistributable. The attribution file lists online
MIT packs from Kenney that can replace these placeholders later without
changing the network or gameplay implementation.

## Important network note

`0.0.0.0` is the server's listen address, not an address clients can connect
to. `127.0.0.1` only reaches the same device. A phone must use the server's LAN
IP or public host. Raw TCP traffic is plaintext; do not treat this prototype as
a secure Internet service without adding transport security and authentication.
