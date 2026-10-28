fx_version 'cerulean'
game 'gta5'

name 'spz-colorrush'
description 'SPiceZ Minigame — Color Rush. A huge multicoloured platform; a colour is called, everyone rushes to it, every other colour despawns. Grid shrinks each wave until one player is left. Free to play.'
version '1.1.0'
author 'SPiceZ-Core'
lua54 'yes'

shared_scripts {
  '@ox_lib/init.lua',
  'config.lua',
}

client_scripts {
  'client/main.lua',
}

server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'server/main.lua',
}

-- stream/ holds the six tile drawables (spz_cr_tile_<colour>.ydr), each with its
-- diffuse texture embedded, so there are no separate .ytd files. A stream/ folder
-- is auto-detected by cerulean and needs no manifest entry — do NOT list it under
-- files{}, that is for ordinary client downloads and would ship the .ydr twice.
-- Built from _source/spz_cr_tiles.blend; see Docs/BLENDER_TILE_GUIDE.md.

-- The archetypes for the six tiles. Without this the .ydr files stream but the
-- model hashes don't exist, and RequestModel fails. Built by
-- _source/pipeline/export_ytyp.py.
data_file 'DLC_ITYP_REQUEST' 'stream/spz_colorrush.ytyp'

dependencies {
  'ox_lib',
  'spz-minigames',   -- shared in-game HUD
  'oxmysql',
  'spz-core',
  'spz-identity',
  'spz-progression',
}
