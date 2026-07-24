# Strike Protocol TCP v1

Strike Protocol uses a server-authoritative 2D arena simulation. Clients send
intent only; they never send trusted positions, health, damage, or scores.

## Transport

- Raw TCP, default port `8765`.
- UTF-8 JSON objects separated by one newline byte (`\n`).
- Exactly one JSON object per line. The maximum encoded line size is 16 KiB.
- Protocol version: `1`.
- Server simulation and snapshots: 30 Hz by default.
- Coordinates are pixels. `(0, 0)` is the top-left of a `1600 x 900` arena.
- `world.obstacles` is the authoritative list of solid axis-aligned rectangles.
- Angles are radians, where `0` points right and positive values turn clockwise
  in screen coordinates.

Incoming packets may use `t` as an alias for `type`. Server packets always use
`type`. Unknown fields are ignored so additive protocol changes stay compatible.

## Connection flow

The required flow is `hello`, then `join`, then gameplay messages. A client
should send `ping` at least every 5 seconds. The default inactivity timeout is
20 seconds.

### Hello

Client:

```json
{"type":"hello","version":1,"name":"Player"}
```

Server:

```json
{"type":"hello_ok","ok":true,"protocol":"strike-tcp-jsonl","version":1,"client_id":"c...","tick_rate":30,"server_time":1770000000.0}
```

Names are trimmed, printable, non-empty, and at most 24 characters.

### Create or join a room

Create a room with a generated six-character code:

```json
{"type":"join"}
```

Join an existing room:

```json
{"type":"join","room":"A2BC3D"}
```

Create a room with an explicit code:

```json
{"type":"join","room":"DUEL01","create":true}
```

`join_room` and `create_room` are accepted aliases. `room_code` and `code` are
accepted aliases for `room`.

Successful response:

```json
{
  "type":"joined",
  "ok":true,
  "room":"A2BC3D",
  "room_code":"A2BC3D",
  "player_id":"p...",
  "tick_rate":30,
  "world":{"width":1600.0,"height":900.0,"obstacles":[{"x":300.0,"y":160.0,"width":150.0,"height":48.0}]},
  "player":{"id":"p...","name":"Player","x":110.0,"y":110.0,"hp":100,"alive":true},
  "snapshot":{"type":"snapshot","tick":0,"players":[],"bullets":[]}
}
```

Room codes contain 4-8 uppercase ASCII letters or digits. Generated codes omit
ambiguous characters. A room is removed after its last player disconnects.

## Gameplay input

Input is the current control state, not a position update:

```json
{
  "type":"input",
  "seq":42,
  "move":{"x":1.0,"y":-0.25},
  "aim":{"x":0.8,"y":0.6},
  "shoot":true
}
```

- `seq` is an optional monotonically increasing non-negative integer. Stale
  sequenced input is ignored. The latest accepted value appears in snapshots.
- `move.x` and `move.y` are clamped to `[-1, 1]`; diagonal movement is
  normalized by the server.
- `aim` is a direction vector. `angle` or `aim_angle` can be sent instead.
- `shoot` is held-fire state. Omit it to preserve the current state.
- `movement`, `[x,y]`, `dx`/`dy`, and `move_x`/`move_y` are accepted aliases.
- `move` and `state` are accepted aliases for the `input` packet type.

A one-shot packet is also supported:

```json
{"type":"shoot","angle":0.0}
```

`fire` is an alias. `{"type":"shoot","pressed":false}` releases held fire.
The server enforces fire rate, bullet speed, collision, damage, and respawning.

## Snapshots and events

The server sends a complete state at the configured tick rate:

```json
{
  "type":"snapshot",
  "version":1,
  "room":"A2BC3D",
  "tick":108,
  "time":3.6,
  "world":{"width":1600.0,"height":900.0,"obstacles":[{"x":300.0,"y":160.0,"width":150.0,"height":48.0}]},
  "players":[
    {"id":"p1","player_id":"p1","name":"Player","x":400.0,"y":320.0,"angle":0.5,"hp":75,"max_hp":100,"score":1,"deaths":0,"alive":true,"respawn_in":0.0,"last_input_seq":42}
  ],
  "bullets":[
    {"id":"b1","owner":"p1","owner_id":"p1","x":500.0,"y":330.0,"vx":790.0,"vy":431.0}
  ]
}
```

Discrete event packet types are:

- `player_joined`: contains `room` and `player`.
- `player_left`: contains `room`, `player_id`, and `reason`.
- `shot`: contains `room`, `tick`, `player_id`, and `bullet`.
- `bullet_impact`: contains the stopped bullet position and hit `obstacle`.
- `hit`: contains attacker/victim IDs, damage, and remaining HP.
- `eliminated`: contains attacker/victim IDs and `respawn_in`.
- `respawned`: contains the reset `player` state.

Snapshots remain the source of truth; clients may use events for immediate
effects and audio.

## Ping and disconnect

Client:

```json
{"type":"ping","ts":123.5}
```

Server echoes `ts`:

```json
{"type":"pong","ts":123.5,"server_time":1770000000.0}
```

`{"type":"leave"}` or `{"type":"disconnect"}` returns `left` and closes the
connection. TCP EOF also removes the player from the room.

## Errors

Validation failures do not change game state:

```json
{"type":"error","ok":false,"code":"invalid_field","message":"move.x must be a number","details":{"field":"move.x"}}
```

Common codes include `invalid_json`, `message_too_large`, `rate_limited`,
`unsupported_version`, `hello_required`, `join_required`, `room_not_found`,
`room_full`, `invalid_name`, `invalid_room`, and `unknown_type`. Five protocol
errors or sustained message flooding closes the connection.
