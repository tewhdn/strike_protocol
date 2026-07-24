"""Asyncio authoritative server for the Strike Protocol arena game.

The wire format is UTF-8 newline-delimited JSON.  This module intentionally
uses only the Python standard library so it can be deployed as a single small
service on Windows, Linux, or macOS.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import json
import logging
import math
import secrets
import string
import time
from collections import deque
from dataclasses import dataclass
from typing import Any, Coroutine, Deque, Dict, Iterable, List, Mapping, Optional, Set, Tuple

try:
    from ..protocol import (
        BULLET_DAMAGE,
        BULLET_RADIUS,
        BULLET_SPEED,
        BULLET_TTL,
        DEFAULT_HOST,
        DEFAULT_PORT,
        FIRE_INTERVAL,
        MAX_MESSAGE_BYTES,
        MAX_PLAYERS_PER_ROOM,
        PLAYER_MAX_HP,
        PLAYER_RADIUS,
        PLAYER_SPEED,
        PROTOCOL_NAME,
        PROTOCOL_VERSION,
        RESPAWN_DELAY,
        ROOM_CODE_ALPHABET,
        ROOM_CODE_LENGTH,
        TICK_RATE,
        WORLD_HEIGHT,
        WORLD_OBSTACLES,
        WORLD_WIDTH,
    )
except ImportError:  # Allows ``python strike_protocol/server/server.py``.
    import sys
    from pathlib import Path

    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from strike_protocol.protocol import (  # type: ignore[no-redef]
        BULLET_DAMAGE,
        BULLET_RADIUS,
        BULLET_SPEED,
        BULLET_TTL,
        DEFAULT_HOST,
        DEFAULT_PORT,
        FIRE_INTERVAL,
        MAX_MESSAGE_BYTES,
        MAX_PLAYERS_PER_ROOM,
        PLAYER_MAX_HP,
        PLAYER_RADIUS,
        PLAYER_SPEED,
        PROTOCOL_NAME,
        PROTOCOL_VERSION,
        RESPAWN_DELAY,
        ROOM_CODE_ALPHABET,
        ROOM_CODE_LENGTH,
        TICK_RATE,
        WORLD_HEIGHT,
        WORLD_OBSTACLES,
        WORLD_WIDTH,
    )


LOGGER = logging.getLogger("strike_protocol.server")

MAX_NAME_LENGTH = 24
MAX_ROOM_CODE_LENGTH = 8
MIN_ROOM_CODE_LENGTH = 4
MAX_MESSAGES_PER_SECOND = 120
MAX_PROTOCOL_ERRORS = 5
OUTBOX_SIZE = 128
WRITE_TIMEOUT = 5.0


class ProtocolError(Exception):
    """A client-visible validation error."""

    def __init__(self, code: str, message: str, **details: Any) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details


def _finite_number(value: Any, field: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ProtocolError("invalid_field", f"{field} must be a number", field=field)
    number = float(value)
    if not math.isfinite(number):
        raise ProtocolError("invalid_field", f"{field} must be finite", field=field)
    return number


def _boolean(value: Any, field: str) -> bool:
    if isinstance(value, bool):
        return value
    if value in (0, 1):
        return bool(value)
    raise ProtocolError("invalid_field", f"{field} must be a boolean", field=field)


def _normalise_angle(angle: float) -> float:
    return (angle + math.pi) % (2.0 * math.pi) - math.pi


def _clean_name(value: Any) -> str:
    if value is None:
        return "Pilot"
    if not isinstance(value, str):
        raise ProtocolError("invalid_name", "name must be a string")
    name = "".join(char for char in value.strip() if char.isprintable())
    if not name:
        raise ProtocolError("invalid_name", "name cannot be empty")
    if len(name) > MAX_NAME_LENGTH:
        raise ProtocolError(
            "invalid_name",
            f"name cannot exceed {MAX_NAME_LENGTH} characters",
            max_length=MAX_NAME_LENGTH,
        )
    return name


def _normalise_room_code(value: Any) -> Optional[str]:
    if value in (None, ""):
        return None
    if not isinstance(value, str):
        raise ProtocolError("invalid_room", "room code must be a string")
    code = value.strip().upper()
    if not (MIN_ROOM_CODE_LENGTH <= len(code) <= MAX_ROOM_CODE_LENGTH):
        raise ProtocolError(
            "invalid_room",
            f"room code must be {MIN_ROOM_CODE_LENGTH}-{MAX_ROOM_CODE_LENGTH} characters",
        )
    allowed = set(string.ascii_uppercase + string.digits)
    if any(char not in allowed for char in code):
        raise ProtocolError("invalid_room", "room code may contain only A-Z and 0-9")
    return code


def _parse_json_line(raw: bytes) -> Mapping[str, Any]:
    def reject_constant(value: str) -> None:
        raise ValueError(f"non-finite JSON number: {value}")

    try:
        decoded = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ProtocolError("invalid_encoding", "messages must be UTF-8") from exc
    try:
        value = json.loads(decoded, parse_constant=reject_constant)
    except (json.JSONDecodeError, ValueError) as exc:
        raise ProtocolError("invalid_json", "message is not valid JSON") from exc
    if not isinstance(value, dict):
        raise ProtocolError("invalid_message", "message must be a JSON object")
    return value


def _json_line(payload: Mapping[str, Any]) -> bytes:
    return (
        json.dumps(payload, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
        + "\n"
    ).encode("utf-8")


def _segment_circle_hit_t(
    start_x: float,
    start_y: float,
    end_x: float,
    end_y: float,
    center_x: float,
    center_y: float,
    radius: float,
) -> Optional[float]:
    """Return the first segment/circle intersection as a value in [0, 1]."""

    dx = end_x - start_x
    dy = end_y - start_y
    fx = start_x - center_x
    fy = start_y - center_y
    c = fx * fx + fy * fy - radius * radius
    if c <= 0.0:
        return 0.0
    a = dx * dx + dy * dy
    if a <= 1e-12:
        return None
    b = 2.0 * (fx * dx + fy * dy)
    discriminant = b * b - 4.0 * a * c
    if discriminant < 0.0:
        return None
    root = math.sqrt(discriminant)
    first = (-b - root) / (2.0 * a)
    second = (-b + root) / (2.0 * a)
    if 0.0 <= first <= 1.0:
        return first
    if 0.0 <= second <= 1.0:
        return second
    return None


def _segment_aabb_hit_t(
    start_x: float,
    start_y: float,
    end_x: float,
    end_y: float,
    left: float,
    top: float,
    right: float,
    bottom: float,
) -> Optional[float]:
    """Return the first intersection of a segment with an axis-aligned box."""

    direction_x = end_x - start_x
    direction_y = end_y - start_y
    first = 0.0
    last = 1.0
    for start, direction, minimum, maximum in (
        (start_x, direction_x, left, right),
        (start_y, direction_y, top, bottom),
    ):
        if abs(direction) <= 1e-12:
            if start < minimum or start > maximum:
                return None
            continue
        near = (minimum - start) / direction
        far = (maximum - start) / direction
        if near > far:
            near, far = far, near
        first = max(first, near)
        last = min(last, far)
        if first > last:
            return None
    return first if 0.0 <= first <= 1.0 else None


@dataclass(frozen=True)
class Obstacle:
    x: float
    y: float
    width: float
    height: float

    @property
    def right(self) -> float:
        return self.x + self.width

    @property
    def bottom(self) -> float:
        return self.y + self.height

    def public_state(self) -> Dict[str, float]:
        return {
            "x": self.x,
            "y": self.y,
            "width": self.width,
            "height": self.height,
        }


@dataclass
class Player:
    id: str
    name: str
    x: float
    y: float
    angle: float = 0.0
    hp: int = PLAYER_MAX_HP
    score: int = 0
    deaths: int = 0
    alive: bool = True
    input_x: float = 0.0
    input_y: float = 0.0
    wants_fire: bool = False
    shot_queued: bool = False
    fire_cooldown: float = 0.0
    respawn_at: float = 0.0
    last_input_seq: int = -1

    def public_state(self, game_time: float) -> Dict[str, Any]:
        return {
            "id": self.id,
            "player_id": self.id,
            "name": self.name,
            "x": round(self.x, 3),
            "y": round(self.y, 3),
            "angle": round(self.angle, 6),
            "hp": self.hp,
            "max_hp": PLAYER_MAX_HP,
            "score": self.score,
            "deaths": self.deaths,
            "alive": self.alive,
            "respawn_in": round(max(0.0, self.respawn_at - game_time), 3)
            if not self.alive
            else 0.0,
            "last_input_seq": self.last_input_seq,
        }


@dataclass
class Bullet:
    id: str
    owner_id: str
    x: float
    y: float
    vx: float
    vy: float
    ttl: float = BULLET_TTL

    def public_state(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "owner": self.owner_id,
            "owner_id": self.owner_id,
            "x": round(self.x, 3),
            "y": round(self.y, 3),
            "vx": round(self.vx, 3),
            "vy": round(self.vy, 3),
        }


class Room:
    """One independent authoritative arena simulation."""

    def __init__(
        self,
        code: str,
        *,
        max_players: int = MAX_PLAYERS_PER_ROOM,
        width: float = WORLD_WIDTH,
        height: float = WORLD_HEIGHT,
        obstacles: Optional[Iterable[Tuple[float, float, float, float]]] = None,
    ) -> None:
        self.code = code
        self.max_players = max_players
        self.width = float(width)
        self.height = float(height)
        obstacle_values = WORLD_OBSTACLES if obstacles is None else obstacles
        self.obstacles = [
            Obstacle(float(x), float(y), float(obstacle_width), float(obstacle_height))
            for x, y, obstacle_width, obstacle_height in obstacle_values
            if obstacle_width > 0.0
            and obstacle_height > 0.0
            and x >= 0.0
            and y >= 0.0
            and x + obstacle_width <= self.width
            and y + obstacle_height <= self.height
        ]
        self.players: Dict[str, Player] = {}
        self.sessions: Dict[str, ClientSession] = {}
        self.bullets: Dict[str, Bullet] = {}
        self.tick = 0
        self.game_time = 0.0
        self._spawn_cursor = 0
        self._bullet_counter = 0

    @property
    def full(self) -> bool:
        return len(self.players) >= self.max_players

    def _spawn_candidates(self) -> List[Tuple[float, float]]:
        margin_x = min(110.0, self.width * 0.15)
        margin_y = min(110.0, self.height * 0.18)
        return [
            (margin_x, margin_y),
            (self.width - margin_x, self.height - margin_y),
            (self.width - margin_x, margin_y),
            (margin_x, self.height - margin_y),
            (self.width * 0.5, margin_y),
            (self.width * 0.5, self.height - margin_y),
            (margin_x, self.height * 0.5),
            (self.width - margin_x, self.height * 0.5),
        ]

    def _position_blocked(self, x: float, y: float, radius: float) -> bool:
        return any(
            obstacle.x - radius < x < obstacle.right + radius
            and obstacle.y - radius < y < obstacle.bottom + radius
            for obstacle in self.obstacles
        )

    def choose_spawn(self, exclude_player_id: Optional[str] = None) -> Tuple[float, float]:
        candidates = self._spawn_candidates()
        if not candidates:
            return self.width * 0.5, self.height * 0.5
        offset = self._spawn_cursor % len(candidates)
        self._spawn_cursor += 1
        ordered = [
            point
            for point in candidates[offset:] + candidates[:offset]
            if not self._position_blocked(point[0], point[1], PLAYER_RADIUS)
        ]
        if not ordered:
            return PLAYER_RADIUS, PLAYER_RADIUS
        others = [
            player
            for player in self.players.values()
            if player.alive and player.id != exclude_player_id
        ]
        if not others:
            return ordered[0]
        return max(
            ordered,
            key=lambda point: min(
                (point[0] - player.x) ** 2 + (point[1] - player.y) ** 2
                for player in others
            ),
        )

    def _move_player(self, player: Player, delta_x: float, delta_y: float) -> None:
        old_x = player.x
        target_x = min(
            self.width - PLAYER_RADIUS,
            max(PLAYER_RADIUS, old_x + delta_x),
        )
        for obstacle in self.obstacles:
            if not (
                obstacle.y - PLAYER_RADIUS
                < player.y
                < obstacle.bottom + PLAYER_RADIUS
            ):
                continue
            left = obstacle.x - PLAYER_RADIUS
            right = obstacle.right + PLAYER_RADIUS
            if delta_x > 0.0 and old_x <= left < target_x:
                target_x = left
            elif delta_x < 0.0 and old_x >= right > target_x:
                target_x = right
        player.x = target_x

        old_y = player.y
        target_y = min(
            self.height - PLAYER_RADIUS,
            max(PLAYER_RADIUS, old_y + delta_y),
        )
        for obstacle in self.obstacles:
            if not (
                obstacle.x - PLAYER_RADIUS
                < player.x
                < obstacle.right + PLAYER_RADIUS
            ):
                continue
            top = obstacle.y - PLAYER_RADIUS
            bottom = obstacle.bottom + PLAYER_RADIUS
            if delta_y > 0.0 and old_y <= top < target_y:
                target_y = top
            elif delta_y < 0.0 and old_y >= bottom > target_y:
                target_y = bottom
        player.y = target_y

    def world_state(self) -> Dict[str, Any]:
        return {
            "width": self.width,
            "height": self.height,
            "obstacles": [obstacle.public_state() for obstacle in self.obstacles],
        }

    def add_player(self, session: "ClientSession", player_id: str, name: str) -> Player:
        if self.full:
            raise ProtocolError("room_full", "the room is full", room=self.code)
        x, y = self.choose_spawn()
        player = Player(id=player_id, name=name, x=x, y=y)
        self.players[player_id] = player
        self.sessions[player_id] = session
        return player

    def remove_player(self, player_id: str) -> Optional[Player]:
        self.sessions.pop(player_id, None)
        player = self.players.pop(player_id, None)
        for bullet_id, bullet in list(self.bullets.items()):
            if bullet.owner_id == player_id:
                self.bullets.pop(bullet_id, None)
        return player

    def _spawn_bullet(self, player: Player) -> Tuple[Bullet, Dict[str, Any]]:
        self._bullet_counter += 1
        bullet_id = f"b{self.tick:x}{self._bullet_counter:x}"
        direction_x = math.cos(player.angle)
        direction_y = math.sin(player.angle)
        muzzle_offset = PLAYER_RADIUS + BULLET_RADIUS + 4.0
        bullet = Bullet(
            id=bullet_id,
            owner_id=player.id,
            x=player.x + direction_x * muzzle_offset,
            y=player.y + direction_y * muzzle_offset,
            vx=direction_x * BULLET_SPEED,
            vy=direction_y * BULLET_SPEED,
        )
        self.bullets[bullet.id] = bullet
        player.fire_cooldown = FIRE_INTERVAL
        player.shot_queued = False
        return bullet, {
            "type": "shot",
            "room": self.code,
            "tick": self.tick,
            "player_id": player.id,
            "bullet": bullet.public_state(),
        }

    def _respawn(self, player: Player) -> Dict[str, Any]:
        player.x, player.y = self.choose_spawn(exclude_player_id=player.id)
        player.hp = PLAYER_MAX_HP
        player.alive = True
        player.respawn_at = 0.0
        player.fire_cooldown = 0.0
        player.input_x = 0.0
        player.input_y = 0.0
        player.wants_fire = False
        player.shot_queued = False
        return {
            "type": "respawned",
            "room": self.code,
            "tick": self.tick,
            "player": player.public_state(self.game_time),
        }

    def _damage_player(self, bullet: Bullet, victim: Player) -> List[Dict[str, Any]]:
        events: List[Dict[str, Any]] = []
        victim.hp = max(0, victim.hp - BULLET_DAMAGE)
        events.append(
            {
                "type": "hit",
                "room": self.code,
                "tick": self.tick,
                "bullet_id": bullet.id,
                "attacker_id": bullet.owner_id,
                "victim_id": victim.id,
                "damage": BULLET_DAMAGE,
                "hp": victim.hp,
            }
        )
        if victim.hp > 0:
            return events

        victim.alive = False
        victim.deaths += 1
        victim.respawn_at = self.game_time + RESPAWN_DELAY
        victim.input_x = 0.0
        victim.input_y = 0.0
        victim.wants_fire = False
        victim.shot_queued = False
        attacker = self.players.get(bullet.owner_id)
        if attacker is not None and attacker.id != victim.id:
            attacker.score += 1
        events.append(
            {
                "type": "eliminated",
                "room": self.code,
                "tick": self.tick,
                "attacker_id": bullet.owner_id,
                "victim_id": victim.id,
                "respawn_in": RESPAWN_DELAY,
            }
        )
        return events

    def step(self, dt: float) -> List[Dict[str, Any]]:
        dt = max(0.0, min(float(dt), 0.1))
        self.tick += 1
        self.game_time += dt
        events: List[Dict[str, Any]] = []

        for player in self.players.values():
            if not player.alive:
                if self.game_time >= player.respawn_at:
                    events.append(self._respawn(player))
                continue

            length = math.hypot(player.input_x, player.input_y)
            if length > 1.0:
                move_x = player.input_x / length
                move_y = player.input_y / length
            else:
                move_x = player.input_x
                move_y = player.input_y
            self._move_player(
                player,
                move_x * PLAYER_SPEED * dt,
                move_y * PLAYER_SPEED * dt,
            )
            player.fire_cooldown = max(0.0, player.fire_cooldown - dt)
            if (player.wants_fire or player.shot_queued) and player.fire_cooldown <= 0.0:
                _, event = self._spawn_bullet(player)
                events.append(event)

        for bullet_id, bullet in list(self.bullets.items()):
            old_x, old_y = bullet.x, bullet.y
            new_x = old_x + bullet.vx * dt
            new_y = old_y + bullet.vy * dt
            bullet.ttl -= dt

            nearest: Optional[Tuple[float, Player]] = None
            hit_radius = PLAYER_RADIUS + BULLET_RADIUS
            for player in self.players.values():
                if not player.alive or player.id == bullet.owner_id:
                    continue
                hit_t = _segment_circle_hit_t(
                    old_x,
                    old_y,
                    new_x,
                    new_y,
                    player.x,
                    player.y,
                    hit_radius,
                )
                if hit_t is not None and (nearest is None or hit_t < nearest[0]):
                    nearest = (hit_t, player)

            nearest_obstacle: Optional[Tuple[float, Obstacle]] = None
            for obstacle in self.obstacles:
                hit_t = _segment_aabb_hit_t(
                    old_x,
                    old_y,
                    new_x,
                    new_y,
                    obstacle.x - BULLET_RADIUS,
                    obstacle.y - BULLET_RADIUS,
                    obstacle.right + BULLET_RADIUS,
                    obstacle.bottom + BULLET_RADIUS,
                )
                if hit_t is not None and (
                    nearest_obstacle is None or hit_t < nearest_obstacle[0]
                ):
                    nearest_obstacle = (hit_t, obstacle)

            if nearest_obstacle is not None and (
                nearest is None or nearest_obstacle[0] <= nearest[0]
            ):
                hit_t, obstacle = nearest_obstacle
                bullet.x = old_x + (new_x - old_x) * hit_t
                bullet.y = old_y + (new_y - old_y) * hit_t
                events.append(
                    {
                        "type": "bullet_impact",
                        "room": self.code,
                        "tick": self.tick,
                        "bullet_id": bullet.id,
                        "x": round(bullet.x, 3),
                        "y": round(bullet.y, 3),
                        "obstacle": obstacle.public_state(),
                    }
                )
                self.bullets.pop(bullet_id, None)
                continue

            if nearest is not None:
                hit_t, victim = nearest
                bullet.x = old_x + (new_x - old_x) * hit_t
                bullet.y = old_y + (new_y - old_y) * hit_t
                events.extend(self._damage_player(bullet, victim))
                self.bullets.pop(bullet_id, None)
                continue

            bullet.x, bullet.y = new_x, new_y
            outside = (
                bullet.x < -BULLET_RADIUS
                or bullet.y < -BULLET_RADIUS
                or bullet.x > self.width + BULLET_RADIUS
                or bullet.y > self.height + BULLET_RADIUS
            )
            if bullet.ttl <= 0.0 or outside:
                self.bullets.pop(bullet_id, None)

        return events

    def snapshot(self) -> Dict[str, Any]:
        players = [
            player.public_state(self.game_time)
            for player in sorted(self.players.values(), key=lambda item: item.id)
        ]
        bullets = [
            bullet.public_state()
            for bullet in sorted(self.bullets.values(), key=lambda item: item.id)
        ]
        return {
            "type": "snapshot",
            "version": PROTOCOL_VERSION,
            "room": self.code,
            "room_code": self.code,
            "tick": self.tick,
            "time": round(self.game_time, 4),
            "server_time": round(time.time(), 3),
            "world": self.world_state(),
            "players": players,
            "bullets": bullets,
        }


class ClientSession:
    """Network state for one connected TCP client."""

    def __init__(
        self,
        game_server: "GameServer",
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        self.game_server = game_server
        self.reader = reader
        self.writer = writer
        self.address = writer.get_extra_info("peername")
        self.client_id = f"c{secrets.token_hex(5)}"
        self.name = "Pilot"
        self.hello_done = False
        self.room: Optional[Room] = None
        self.player_id: Optional[str] = None
        self.last_seen = asyncio.get_running_loop().time()
        self.protocol_errors = 0
        self.message_times: Deque[float] = deque()
        self.closed = False
        self.outbox: "asyncio.Queue[Optional[Tuple[str, Optional[bytes]]]]" = (
            asyncio.Queue(maxsize=OUTBOX_SIZE)
        )
        self.latest_snapshot: Optional[bytes] = None
        self.snapshot_pending = False
        self.writer_task: Optional[asyncio.Task[None]] = None

    def enqueue(self, payload: Mapping[str, Any], *, critical: bool = False) -> bool:
        if self.closed:
            return False
        try:
            line = _json_line(payload)
        except (TypeError, ValueError):
            LOGGER.exception("Failed to serialize server message")
            return False
        if payload.get("type") == "snapshot" and not critical:
            self.latest_snapshot = line
            if self.snapshot_pending:
                return True
            try:
                self.outbox.put_nowait(("snapshot", None))
                self.snapshot_pending = True
                return True
            except asyncio.QueueFull:
                self.latest_snapshot = None
                return False
        try:
            self.outbox.put_nowait(("message", line))
            return True
        except asyncio.QueueFull:
            self.game_server.schedule_disconnect(self, "slow_client")
            return False

    async def flush(self, timeout: float = 0.3) -> None:
        with contextlib.suppress(asyncio.TimeoutError):
            await asyncio.wait_for(self.outbox.join(), timeout=timeout)


class GameServer:
    """Lifecycle and protocol handling for all rooms and connections."""

    def __init__(
        self,
        host: str = DEFAULT_HOST,
        port: int = DEFAULT_PORT,
        *,
        tick_rate: int = TICK_RATE,
        max_players_per_room: int = MAX_PLAYERS_PER_ROOM,
        idle_timeout: float = 20.0,
        world_width: float = WORLD_WIDTH,
        world_height: float = WORLD_HEIGHT,
        obstacles: Optional[Iterable[Tuple[float, float, float, float]]] = None,
    ) -> None:
        if tick_rate <= 0 or tick_rate > 120:
            raise ValueError("tick_rate must be between 1 and 120")
        if max_players_per_room <= 0:
            raise ValueError("max_players_per_room must be positive")
        if idle_timeout <= 0.0:
            raise ValueError("idle_timeout must be positive")
        self.host = host
        self.port = int(port)
        self.tick_rate = int(tick_rate)
        self.max_players_per_room = int(max_players_per_room)
        self.idle_timeout = float(idle_timeout)
        self.world_width = float(world_width)
        self.world_height = float(world_height)
        self.obstacles = None if obstacles is None else tuple(obstacles)
        self.rooms: Dict[str, Room] = {}
        self.sessions: Set[ClientSession] = set()
        self._server: Optional[asyncio.AbstractServer] = None
        self._tick_task: Optional[asyncio.Task[None]] = None
        self._background_tasks: Set[asyncio.Task[Any]] = set()
        self._stopping = False

    @property
    def server(self) -> Optional[asyncio.AbstractServer]:
        return self._server

    @property
    def bound_port(self) -> int:
        if self._server and self._server.sockets:
            return int(self._server.sockets[0].getsockname()[1])
        return self.port

    @property
    def address(self) -> Tuple[str, int]:
        return self.host, self.bound_port

    async def start(self) -> "GameServer":
        if self._server is not None:
            return self
        self._stopping = False
        self._server = await asyncio.start_server(
            self._client_connected,
            self.host,
            self.port,
            limit=MAX_MESSAGE_BYTES + 1,
        )
        self.port = self.bound_port
        self._tick_task = asyncio.create_task(self._tick_loop(), name="strike-tick")
        LOGGER.info("Strike Protocol listening on %s:%d", self.host, self.bound_port)
        return self

    async def stop(self) -> None:
        if self._stopping:
            return
        self._stopping = True
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
            self._server = None
        if self._tick_task is not None:
            self._tick_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._tick_task
            self._tick_task = None
        await asyncio.gather(
            *(self._disconnect(session, "server_shutdown") for session in list(self.sessions)),
            return_exceptions=True,
        )
        pending = [task for task in self._background_tasks if not task.done()]
        if pending:
            await asyncio.gather(*pending, return_exceptions=True)
        self.rooms.clear()
        self._stopping = False

    async def __aenter__(self) -> "GameServer":
        return await self.start()

    async def __aexit__(self, *exc_info: Any) -> None:
        await self.stop()

    async def serve_forever(self) -> None:
        if self._server is None:
            await self.start()
        assert self._server is not None
        async with self._server:
            await self._server.serve_forever()

    def _schedule(self, coroutine: Coroutine[Any, Any, Any], name: str) -> asyncio.Task[Any]:
        task = asyncio.create_task(coroutine, name=name)
        self._background_tasks.add(task)
        task.add_done_callback(self._background_tasks.discard)
        return task

    def schedule_disconnect(self, session: ClientSession, reason: str) -> None:
        if not session.closed:
            self._schedule(self._disconnect(session, reason), f"disconnect-{session.client_id}")

    def create_room(self, code: Optional[str] = None) -> Room:
        if code is not None:
            code = _normalise_room_code(code)
            assert code is not None
            if code in self.rooms:
                raise ProtocolError("room_exists", "the room already exists", room=code)
        else:
            for _ in range(100):
                candidate = "".join(
                    secrets.choice(ROOM_CODE_ALPHABET) for _ in range(ROOM_CODE_LENGTH)
                )
                if candidate not in self.rooms:
                    code = candidate
                    break
            if code is None:
                raise RuntimeError("could not allocate a room code")
        room = Room(
            code,
            max_players=self.max_players_per_room,
            width=self.world_width,
            height=self.world_height,
            obstacles=self.obstacles,
        )
        self.rooms[code] = room
        return room

    async def _client_connected(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        session = ClientSession(self, reader, writer)
        self.sessions.add(session)
        session.writer_task = asyncio.create_task(
            self._writer_loop(session), name=f"writer-{session.client_id}"
        )
        LOGGER.debug("Client connected: %s", session.address)
        try:
            await self._reader_loop(session)
        finally:
            await self._disconnect(session, "connection_closed")

    async def _reader_loop(self, session: ClientSession) -> None:
        while not session.closed:
            try:
                raw = await session.reader.readline()
            except (asyncio.IncompleteReadError, ConnectionError):
                break
            except ValueError:
                self._send_error(session, "message_too_large", "message exceeds size limit")
                await session.flush()
                break
            if not raw:
                break
            if len(raw) > MAX_MESSAGE_BYTES:
                self._send_error(session, "message_too_large", "message exceeds size limit")
                await session.flush()
                break
            if not raw.strip():
                continue

            now = asyncio.get_running_loop().time()
            session.message_times.append(now)
            while session.message_times and now - session.message_times[0] > 1.0:
                session.message_times.popleft()
            if len(session.message_times) > MAX_MESSAGES_PER_SECOND:
                self._send_error(session, "rate_limited", "too many messages")
                break

            try:
                message = _parse_json_line(raw)
                session.last_seen = now
                await self._handle_message(session, message)
            except ProtocolError as exc:
                session.protocol_errors += 1
                self._send_error(session, exc.code, exc.message, **exc.details)
                if session.protocol_errors >= MAX_PROTOCOL_ERRORS:
                    await session.flush()
                    break
            except Exception:
                LOGGER.exception("Unexpected protocol handler error")
                self._send_error(session, "server_error", "internal server error")
                await session.flush()
                break

    async def _writer_loop(self, session: ClientSession) -> None:
        try:
            while not session.closed:
                queued = await session.outbox.get()
                try:
                    if queued is None:
                        return
                    kind, line = queued
                    if kind == "snapshot":
                        line = session.latest_snapshot
                        session.latest_snapshot = None
                        session.snapshot_pending = False
                    if line is None:
                        continue
                    session.writer.write(line)
                    await asyncio.wait_for(session.writer.drain(), timeout=WRITE_TIMEOUT)
                finally:
                    session.outbox.task_done()
        except (asyncio.CancelledError, ConnectionError, OSError, asyncio.TimeoutError):
            if not session.closed and not self._stopping:
                self.schedule_disconnect(session, "write_failed")

    async def _disconnect(self, session: ClientSession, reason: str) -> None:
        if session.closed:
            return
        session.closed = True
        self.sessions.discard(session)
        room = session.room
        player_id = session.player_id
        if room is not None and player_id is not None:
            player = room.remove_player(player_id)
            if player is not None:
                self._broadcast(
                    room,
                    {
                        "type": "player_left",
                        "room": room.code,
                        "player_id": player_id,
                        "reason": reason,
                    },
                )
            if not room.players:
                self.rooms.pop(room.code, None)
        session.room = None
        session.player_id = None

        writer_task = session.writer_task
        current_task = asyncio.current_task()
        if writer_task is not None and writer_task is not current_task:
            writer_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await writer_task
        session.writer.close()
        with contextlib.suppress(ConnectionError, OSError, asyncio.TimeoutError):
            await asyncio.wait_for(session.writer.wait_closed(), timeout=1.0)
        LOGGER.debug("Client disconnected (%s): %s", reason, session.address)

    def _send_error(
        self, session: ClientSession, code: str, message: str, **details: Any
    ) -> None:
        payload: Dict[str, Any] = {
            "type": "error",
            "ok": False,
            "code": code,
            "message": message,
        }
        if details:
            payload["details"] = details
        session.enqueue(payload, critical=True)

    def _broadcast(
        self,
        room: Room,
        payload: Mapping[str, Any],
        *,
        exclude: Optional[ClientSession] = None,
    ) -> None:
        for target in list(room.sessions.values()):
            if target is not exclude and not target.closed:
                target.enqueue(payload)

    async def _handle_message(
        self, session: ClientSession, message: Mapping[str, Any]
    ) -> None:
        message_type = message.get("type", message.get("t"))
        if not isinstance(message_type, str) or not message_type.strip():
            raise ProtocolError("missing_type", "message type is required")
        message_type = message_type.strip().lower()

        if message_type == "ping":
            session.enqueue(
                {
                    "type": "pong",
                    "ts": message.get("ts", message.get("client_time")),
                    "server_time": round(time.time(), 6),
                },
                critical=True,
            )
            return
        if message_type == "hello":
            self._handle_hello(session, message)
            return
        if message_type in ("join", "join_room", "create_room"):
            self._handle_join(session, message, message_type)
            return
        if message_type in ("input", "move", "state"):
            self._handle_input(session, message)
            return
        if message_type in ("shoot", "fire"):
            self._handle_shoot(session, message)
            return
        if message_type in ("leave", "disconnect"):
            session.enqueue({"type": "left", "ok": True}, critical=True)
            await session.flush()
            await self._disconnect(session, "client_leave")
            return
        raise ProtocolError(
            "unknown_type", f"unsupported message type: {message_type}", type=message_type
        )

    def _handle_hello(self, session: ClientSession, message: Mapping[str, Any]) -> None:
        if session.hello_done:
            raise ProtocolError("already_hello", "hello has already been accepted")
        version = message.get("version", message.get("protocol_version"))
        if isinstance(version, bool):
            version = None
        try:
            parsed_version = int(version)
        except (TypeError, ValueError):
            parsed_version = -1
        if parsed_version != PROTOCOL_VERSION:
            raise ProtocolError(
                "unsupported_version",
                f"protocol version {PROTOCOL_VERSION} is required",
                supported=[PROTOCOL_VERSION],
            )
        session.name = _clean_name(message.get("name", message.get("player_name")))
        session.hello_done = True
        session.enqueue(
            {
                "type": "hello_ok",
                "event": "welcome",
                "ok": True,
                "protocol": PROTOCOL_NAME,
                "version": PROTOCOL_VERSION,
                "client_id": session.client_id,
                "id": session.client_id,
                "tick_rate": self.tick_rate,
                "server_time": round(time.time(), 6),
            },
            critical=True,
        )

    def _handle_join(
        self,
        session: ClientSession,
        message: Mapping[str, Any],
        message_type: str,
    ) -> None:
        if not session.hello_done:
            raise ProtocolError("hello_required", "send hello before joining a room")
        if session.room is not None:
            raise ProtocolError("already_joined", "client is already in a room")

        if "name" in message or "player_name" in message:
            session.name = _clean_name(message.get("name", message.get("player_name")))
        raw_code = message.get("room", message.get("room_code", message.get("code")))
        code = _normalise_room_code(raw_code)
        create_requested = message_type == "create_room"
        if "create" in message:
            create_requested = _boolean(message["create"], "create")

        if code is None:
            room = self.create_room()
        elif code in self.rooms:
            room = self.rooms[code]
            if message_type == "create_room":
                raise ProtocolError("room_exists", "the room already exists", room=code)
        elif create_requested:
            room = self.create_room(code)
        else:
            raise ProtocolError("room_not_found", "room does not exist", room=code)

        player_id = f"p{secrets.token_hex(5)}"
        player = room.add_player(session, player_id, session.name)
        session.room = room
        session.player_id = player_id
        snapshot = room.snapshot()
        session.enqueue(
            {
                "type": "joined",
                "event": "room_joined",
                "ok": True,
                "room": room.code,
                "room_code": room.code,
                "player_id": player_id,
                "id": player_id,
                "tick_rate": self.tick_rate,
                "world": room.world_state(),
                "player": player.public_state(room.game_time),
                "snapshot": snapshot,
            },
            critical=True,
        )
        self._broadcast(
            room,
            {
                "type": "player_joined",
                "room": room.code,
                "player": player.public_state(room.game_time),
            },
            exclude=session,
        )

    @staticmethod
    def _require_player(session: ClientSession) -> Player:
        if session.room is None or session.player_id is None:
            raise ProtocolError("join_required", "join a room before sending gameplay input")
        player = session.room.players.get(session.player_id)
        if player is None:
            raise ProtocolError("not_in_room", "player no longer exists in the room")
        return player

    @staticmethod
    def _read_move(message: Mapping[str, Any]) -> Tuple[float, float]:
        move = message.get("move", message.get("movement"))
        if isinstance(move, Mapping):
            raw_x = move.get("x", move.get("dx", 0.0))
            raw_y = move.get("y", move.get("dy", 0.0))
        elif isinstance(move, (list, tuple)) and len(move) == 2:
            raw_x, raw_y = move
        elif move is None:
            raw_x = message.get("dx", message.get("move_x", message.get("x", 0.0)))
            raw_y = message.get("dy", message.get("move_y", message.get("y", 0.0)))
        else:
            raise ProtocolError("invalid_field", "move must be an object or [x, y]")
        move_x = max(-1.0, min(1.0, _finite_number(raw_x, "move.x")))
        move_y = max(-1.0, min(1.0, _finite_number(raw_y, "move.y")))
        return move_x, move_y

    @staticmethod
    def _apply_aim(player: Player, message: Mapping[str, Any]) -> None:
        if "angle" in message or "aim_angle" in message:
            raw_angle = message.get("angle", message.get("aim_angle"))
            player.angle = _normalise_angle(_finite_number(raw_angle, "angle"))
            return
        aim = message.get("aim", message.get("direction"))
        if aim is None:
            return
        if isinstance(aim, Mapping):
            aim_x = _finite_number(aim.get("x"), "aim.x")
            aim_y = _finite_number(aim.get("y"), "aim.y")
        elif isinstance(aim, (list, tuple)) and len(aim) == 2:
            aim_x = _finite_number(aim[0], "aim.x")
            aim_y = _finite_number(aim[1], "aim.y")
        else:
            raise ProtocolError("invalid_field", "aim must be an object or [x, y]")
        if abs(aim_x) > 1e-9 or abs(aim_y) > 1e-9:
            player.angle = math.atan2(aim_y, aim_x)

    def _handle_input(self, session: ClientSession, message: Mapping[str, Any]) -> None:
        player = self._require_player(session)
        sequence = message.get("seq", message.get("sequence"))
        if sequence is not None:
            if isinstance(sequence, bool) or not isinstance(sequence, int) or sequence < 0:
                raise ProtocolError("invalid_field", "seq must be a non-negative integer")
            if sequence <= player.last_input_seq:
                return
            player.last_input_seq = sequence
        player.input_x, player.input_y = self._read_move(message)
        self._apply_aim(player, message)
        if "shoot" in message or "fire" in message:
            player.wants_fire = _boolean(
                message.get("shoot", message.get("fire")), "shoot"
            )

    def _handle_shoot(self, session: ClientSession, message: Mapping[str, Any]) -> None:
        player = self._require_player(session)
        self._apply_aim(player, message)
        pressed = _boolean(message.get("pressed", True), "pressed")
        if pressed:
            player.shot_queued = True
        else:
            player.wants_fire = False

    async def tick_once(self, dt: Optional[float] = None) -> None:
        """Advance every room once; public for deterministic protocol tests."""

        step = 1.0 / self.tick_rate if dt is None else float(dt)
        now = asyncio.get_running_loop().time()
        for session in list(self.sessions):
            if now - session.last_seen > self.idle_timeout:
                self.schedule_disconnect(session, "timeout")

        for room in list(self.rooms.values()):
            events = room.step(step)
            for event in events:
                self._broadcast(room, event)
            self._broadcast(room, room.snapshot())

    async def _tick_loop(self) -> None:
        interval = 1.0 / self.tick_rate
        loop = asyncio.get_running_loop()
        deadline = loop.time()
        try:
            while True:
                deadline += interval
                await asyncio.sleep(max(0.0, deadline - loop.time()))
                await self.tick_once(interval)
                if loop.time() - deadline > interval * 4.0:
                    deadline = loop.time()
        except asyncio.CancelledError:
            raise
        except Exception:
            LOGGER.exception("Tick loop stopped unexpectedly")
            raise


StrikeServer = GameServer


async def run_server(
    host: str = DEFAULT_HOST,
    port: int = DEFAULT_PORT,
    **options: Any,
) -> None:
    game_server = GameServer(host, port, **options)
    await game_server.start()
    try:
        await game_server.serve_forever()
    finally:
        await game_server.stop()


def main(argv: Optional[Iterable[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Strike Protocol authoritative TCP server")
    parser.add_argument("--host", default=DEFAULT_HOST, help="listen address")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="TCP port")
    parser.add_argument("--tick-rate", type=int, default=TICK_RATE, help="simulation Hz")
    parser.add_argument("--idle-timeout", type=float, default=20.0, help="seconds")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(list(argv) if argv is not None else None)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    try:
        asyncio.run(
            run_server(
                args.host,
                args.port,
                tick_rate=args.tick_rate,
                idle_timeout=args.idle_timeout,
            )
        )
    except KeyboardInterrupt:
        LOGGER.info("Server stopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
