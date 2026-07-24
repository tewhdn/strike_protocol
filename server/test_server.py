"""Small dependency-free protocol and simulation smoke test.

Run from the repository root:

    python -m strike_protocol.server.test_server
"""

from __future__ import annotations

import asyncio
import json
import math
import unittest
from typing import Any, Dict, Optional

try:
    from strike_protocol.protocol import BULLET_DAMAGE, PLAYER_RADIUS, PROTOCOL_VERSION
    from strike_protocol.server.server import GameServer, Player, Room
except ModuleNotFoundError:  # Allows ``python strike_protocol/server/test_server.py``.
    import sys
    from pathlib import Path

    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from strike_protocol.protocol import BULLET_DAMAGE, PLAYER_RADIUS, PROTOCOL_VERSION
    from strike_protocol.server.server import GameServer, Player, Room


async def send(writer: asyncio.StreamWriter, payload: Dict[str, Any]) -> None:
    writer.write((json.dumps(payload, separators=(",", ":")) + "\n").encode("utf-8"))
    await writer.drain()


async def receive_type(
    reader: asyncio.StreamReader,
    wanted: str,
    *,
    player_id: Optional[str] = None,
    timeout: float = 2.0,
) -> Dict[str, Any]:
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    seen = []
    while loop.time() < deadline:
        remaining = deadline - loop.time()
        raw = await asyncio.wait_for(reader.readline(), timeout=remaining)
        if not raw:
            raise AssertionError(f"connection closed while waiting for {wanted}")
        message = json.loads(raw)
        seen.append(message.get("type"))
        if message.get("type") != wanted:
            continue
        if player_id is not None and wanted == "snapshot":
            matching = [p for p in message["players"] if p["id"] == player_id]
            if not matching:
                continue
        return message
    raise AssertionError(f"timed out waiting for {wanted}; saw {seen}")


class TcpProtocolTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.server = GameServer("127.0.0.1", 0, idle_timeout=10.0)
        await self.server.start()

    async def asyncTearDown(self) -> None:
        await self.server.stop()

    async def test_handshake_room_input_snapshot_and_ping(self) -> None:
        alice_reader, alice_writer = await asyncio.open_connection(
            "127.0.0.1", self.server.bound_port
        )
        bob_reader, bob_writer = await asyncio.open_connection(
            "127.0.0.1", self.server.bound_port
        )
        self.addAsyncCleanup(self._close_writer, alice_writer)
        self.addAsyncCleanup(self._close_writer, bob_writer)

        await send(
            alice_writer,
            {"type": "hello", "version": PROTOCOL_VERSION, "name": "Alice"},
        )
        hello = await receive_type(alice_reader, "hello_ok")
        self.assertEqual(hello["version"], PROTOCOL_VERSION)

        await send(alice_writer, {"type": "join"})
        alice_joined = await receive_type(alice_reader, "joined")
        room_code = alice_joined["room"]
        alice_id = alice_joined["player_id"]
        initial_x = alice_joined["player"]["x"]
        self.assertGreater(len(alice_joined["world"]["obstacles"]), 0)

        await send(
            bob_writer,
            {"t": "hello", "version": PROTOCOL_VERSION, "name": "Bob"},
        )
        await receive_type(bob_reader, "hello_ok")
        await send(bob_writer, {"type": "join", "room_code": room_code})
        bob_joined = await receive_type(bob_reader, "joined")
        self.assertEqual(bob_joined["room"], room_code)

        await send(
            alice_writer,
            {
                "type": "input",
                "seq": 1,
                "move": {"x": 1.0, "y": 0.0},
                "aim": {"x": 1.0, "y": 0.0},
                "shoot": False,
            },
        )
        moved_x = initial_x
        acknowledged = False
        for _ in range(90):
            snapshot = await receive_type(alice_reader, "snapshot", player_id=alice_id)
            state = next(p for p in snapshot["players"] if p["id"] == alice_id)
            moved_x = state["x"]
            acknowledged = state["last_input_seq"] == 1
            if acknowledged and moved_x > initial_x:
                break
        self.assertTrue(acknowledged)
        self.assertGreater(moved_x, initial_x)

        await send(alice_writer, {"type": "ping", "ts": 12.5})
        pong = await receive_type(alice_reader, "pong")
        self.assertEqual(pong["ts"], 12.5)

    @staticmethod
    async def _close_writer(writer: asyncio.StreamWriter) -> None:
        writer.close()
        try:
            await writer.wait_closed()
        except (ConnectionError, OSError):
            pass


class ValidationAndTimeoutTest(unittest.IsolatedAsyncioTestCase):
    async def test_handshake_validation_and_idle_disconnect(self) -> None:
        server = GameServer("127.0.0.1", 0, idle_timeout=1.0)
        await server.start()
        reader, writer = await asyncio.open_connection("127.0.0.1", server.bound_port)
        try:
            await send(writer, {"type": "join"})
            error = await receive_type(reader, "error")
            self.assertEqual(error["code"], "hello_required")

            await send(
                writer,
                {"type": "hello", "version": PROTOCOL_VERSION, "name": "Idle"},
            )
            await receive_type(reader, "hello_ok")
            eof = await asyncio.wait_for(reader.readline(), timeout=2.0)
            self.assertEqual(eof, b"")
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except (ConnectionError, OSError):
                pass
            await server.stop()


class AuthoritativeSimulationTest(unittest.TestCase):
    def test_bullet_collision_elimination_and_respawn(self) -> None:
        room = Room("TEST01", width=500.0, height=300.0)
        shooter = Player("p1", "Shooter", 100.0, 150.0, angle=0.0)
        victim = Player("p2", "Target", 180.0, 150.0, hp=BULLET_DAMAGE)
        room.players = {shooter.id: shooter, victim.id: victim}
        shooter.shot_queued = True

        events = []
        for _ in range(5):
            events.extend(room.step(1.0 / 30.0))
            if not victim.alive:
                break

        self.assertFalse(victim.alive)
        self.assertEqual(victim.hp, 0)
        self.assertEqual(shooter.score, 1)
        self.assertIn("hit", [event["type"] for event in events])
        self.assertIn("eliminated", [event["type"] for event in events])

        victim.respawn_at = room.game_time
        respawn_events = room.step(1.0 / 30.0)
        self.assertTrue(victim.alive)
        self.assertEqual(victim.hp, 100)
        self.assertIn("respawned", [event["type"] for event in respawn_events])
        self.assertTrue(math.isfinite(victim.x) and math.isfinite(victim.y))

    def test_player_and_bullet_collide_with_obstacle(self) -> None:
        wall = [(250.0, 50.0, 40.0, 200.0)]
        movement_room = Room(
            "MOVE01", width=500.0, height=300.0, obstacles=wall
        )
        player = Player("p1", "Runner", 180.0, 150.0, input_x=1.0)
        movement_room.players[player.id] = player
        for _ in range(20):
            movement_room.step(1.0 / 30.0)
        self.assertAlmostEqual(player.x, 250.0 - PLAYER_RADIUS)

        shooting_room = Room(
            "SHOT01", width=500.0, height=300.0, obstacles=wall
        )
        shooter = Player("p1", "Shooter", 100.0, 150.0, angle=0.0)
        target = Player("p2", "Target", 350.0, 150.0)
        shooter.shot_queued = True
        shooting_room.players = {shooter.id: shooter, target.id: target}
        events = []
        for _ in range(10):
            events.extend(shooting_room.step(1.0 / 30.0))
            if any(event["type"] == "bullet_impact" for event in events):
                break
        self.assertIn("bullet_impact", [event["type"] for event in events])
        self.assertEqual(target.hp, 100)
        self.assertEqual(shooting_room.bullets, {})
        self.assertEqual(shooting_room.world_state()["obstacles"][0]["x"], 250.0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
