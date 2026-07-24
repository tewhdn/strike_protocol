"""Authoritative asyncio game server.

Exports are loaded lazily so ``python -m strike_protocol.server.server`` does
not import the runnable module twice during package initialization.
"""

__all__ = [
    "Bullet",
    "GameServer",
    "Obstacle",
    "Player",
    "Room",
    "StrikeServer",
    "run_server",
]


def __getattr__(name: str):
    if name in __all__:
        from .server import (  # local import keeps module execution clean
            Bullet,
            GameServer,
            Obstacle,
            Player,
            Room,
            StrikeServer,
            run_server,
        )

        return {
            "Bullet": Bullet,
            "GameServer": GameServer,
            "Obstacle": Obstacle,
            "Player": Player,
            "Room": Room,
            "StrikeServer": StrikeServer,
            "run_server": run_server,
        }[name]
    raise AttributeError(name)
