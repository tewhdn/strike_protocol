"""Constants shared by the native clients and the Python TCP server."""

PROTOCOL_NAME = "strike-tcp-jsonl"
PROTOCOL_VERSION = 1

DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 8765
TICK_RATE = 30
MAX_MESSAGE_BYTES = 16 * 1024

WORLD_WIDTH = 1600.0
WORLD_HEIGHT = 900.0
MAX_PLAYERS_PER_ROOM = 8

# Cover geometry is shared with native clients. Values are x, y, width, height
# in the default 1600 x 900 arena; clients should render these as solid AABBs.
WORLD_OBSTACLES = (
    (300.0, 160.0, 150.0, 48.0),
    (640.0, 116.0, 54.0, 168.0),
    (987.0, 167.0, 167.0, 48.0),
    (1253.0, 321.0, 60.0, 193.0),
    (773.0, 399.0, 167.0, 96.0),
    (320.0, 566.0, 67.0, 180.0),
    (573.0, 662.0, 200.0, 49.0),
    (1047.0, 617.0, 173.0, 50.0),
)

PLAYER_MAX_HP = 100
PLAYER_RADIUS = 18.0
PLAYER_SPEED = 260.0
RESPAWN_DELAY = 2.5

BULLET_DAMAGE = 25
BULLET_RADIUS = 5.0
BULLET_SPEED = 900.0
BULLET_TTL = 1.8
FIRE_INTERVAL = 0.18

ROOM_CODE_LENGTH = 6
ROOM_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
