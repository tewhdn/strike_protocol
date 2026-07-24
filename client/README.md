# Strike Protocol Godot Client

This folder is a native Godot 4 project. It does not use HTML, a browser
runtime, or a WebSocket transport.

## Run

1. Install Godot 4.3 or newer.
2. Import this folder as a project and run `main.tscn` (or press F6/F5).
3. Use the default endpoint `127.0.0.1:8765`, then choose **Connect to
   Server**. The matching TCP server lives in `../server`.

The client speaks UTF-8 newline-delimited JSON over `StreamPeerTCP` using
protocol v1. It sends `hello`, `join`, 30 Hz `input`, one-shot `shoot`,
five-second `ping`, and `leave` packets. Snapshot fields are parsed from the
server-authoritative `players` and `bullets` arrays; unknown additive fields are
ignored.

## Controls

- Desktop: `WASD` or arrow keys to move, mouse to aim, left mouse to fire, `R`
  to reload, `Esc` to leave the current screen.
- Touch devices: left virtual stick moves, right stick aims and fires, and the
  reload button is shown beside the weapon counter.
- **Offline Training** starts a local match with seven autonomous bots. It is
  useful when the TCP server is not running and also demonstrates the complete
  HUD and touch layout.

The renderer uses the supplied PNG artwork when available and falls back to
the matching SVG files. The attribution and source links are in
`assets/ATTRIBUTION.md`.
