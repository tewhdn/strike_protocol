# Strike Protocol asset notes

## Files shipped in this repository

The following files are original, deliberately simple vector placeholders made
for this project on 2026-07-23. They do not contain copied third-party artwork:

| PNG fallback | SVG source | Intended use |
| --- | --- | --- |
| `player_blue.png` | `player_blue.svg` | Local player / blue team |
| `enemy_red.png` | `enemy_red.svg` | Opponent / red team |
| `rifle.png` | `rifle.svg` | Weapon sprite |
| `crate.png` | `crate.svg` | Cover prop |
| `bullet.png` | `bullet.svg` | Projectile |
| `logo.png` | `logo.svg` | Start and connection screens |

The extra SVGs (`crosshair.svg`, `floor_tile.svg`, `medkit.svg`,
`muzzle_flash.svg`, and `spawn_beacon.svg`) are also original project artwork.
They are included as optional effects and UI decoration; the current client can
fall back to procedural drawing if a texture is unavailable.

Permission: these project-generated placeholders are dedicated to the public
domain under [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/),
to the extent that dedication is legally possible. Keep this file with copies
or modified versions. The `generate_assets.ps1` script only uses Windows
`System.Drawing` and is included so the PNG fallbacks can be regenerated from
the source geometry.

## Online replacement packs (not bundled)

The user request mentioned finding shooter art online. Network access was not
assumed while assembling this repository, so no remote pack is silently copied
into the game. These are vetted starting points; download and review the
license terms at the source before shipping a replacement:

| Pack | License / attribution | Link |
| --- | --- | --- |
| Kenney Topdown Shooter | CC0; attribution appreciated but not required | [kenney.nl/assets/topdown-shooter](https://kenney.nl/assets/topdown-shooter) |
| Kenney UI Pack | CC0; attribution appreciated but not required | [kenney.nl/assets/ui-pack](https://kenney.nl/assets/ui-pack) |
| Kenney Digital Audio | CC0; attribution appreciated but not required | [kenney.nl/assets/digital-audio](https://kenney.nl/assets/digital-audio) |
| Game-icons.net | CC BY 3.0; credit the icon author and link the license | [game-icons.net](https://game-icons.net/) |

For a replacement, preserve the existing filenames or update the texture paths
in the scene/script that consumes them. Do not mix a CC BY icon into a release
without adding the individual author credits to this table.
