-- config.lua — Color Rush
-- A huge multicoloured platform split into a grid of tiles. Every wave the
-- server calls out one colour; players sprint onto tiles of that colour before
-- the timer dies. When it does, every tile that ISN'T the called colour
-- despawns — and whoever was standing on one goes into the void. The grid
-- shrinks from the outside as waves pass until one player is left.

Config = {}

Config.Command      = "colorrush"      -- join/leave the lobby
Config.StartCommand = "crstart"        -- force-start the lobby early
Config.MenuCommand  = "colorrushmenu"  -- queue menu

-- ── Rewards (FREE to join — no entry fee) ───────────────────────────────────
Config.WinReward     = 1500   -- flat credits to the last player standing
Config.SurvivalBonus = 100    -- credits per wave survived, paid to everyone

-- ── Lobby ───────────────────────────────────────────────────────────────────
Config.MinPlayers   = 2
Config.MaxPlayers   = 32
Config.LobbyWaitSec = 45     -- countdown armed by the first joiner
Config.MaxRooms     = 8      -- rooms that can exist (and play) at the same time

-- ── Arena ───────────────────────────────────────────────────────────────────
-- Config.Center is the CENTRE OF THE TOP SURFACE of the platform — the height
-- players actually stand at, not the base of the model.
--
--   DevFallback ON  → point this at flat solid ground (see below).
--   DevFallback OFF → point this high in the air, over open water or empty map,
--                     so eliminated players actually fall into nothing.
--
-- Two centres, because the two modes need opposite things. The active one is
-- resolved into Config.Center from Config.DevFallback further down, so flipping
-- that single flag is all it takes to switch modes.
--
-- RealCenter: high in the air so eliminated players fall into nothing. This is
-- the one value you still want to tune -- the default hangs in plain sight over
-- the Del Perro coast. Park it over open ocean.
Config.RealCenter = vector3(-1600.0, -1100.0, 250.0)

-- DevCenter: flat solid ground, for the marker fallback. Default is the LSIA
-- apron -- flat, empty, and big enough for the 104 m grid. Driving on tarmac
-- exercises the whole game except the fall, so it stays a useful test even
-- though the real arena is in the sky.
Config.DevCenter  = vector3(-1270.0, -3000.0, 13.95)

Config.Grid          = 8      -- sections per side (Grid² = 64 sections)
Config.TileSize      = 13.0   -- metres per section: 8 x 13.0 = 104 m platform
Config.StandTolerance = { below = 2.0, above = 5.0 }  -- below = fallen; above is ignored (jumps land)
-- Elimination: only falling off the deck (the wrong colours vanish at the buzzer).

-- ── Car jump ────────────────────────────────────────────────────────────────
-- One jump per wave (key rebindable in Settings > Key Bindings > FiveM).
Config.JumpKey      = "E"
Config.JumpVelocity = 9.0      -- m/s straight up
Config.JumpForward  = 3.0      -- m/s extra along the car's nose

-- ── Waves ───────────────────────────────────────────────────────────────────
Config.RushTimeSec      = 9.0   -- seconds to reach the called colour, wave 1
Config.RushTimeStep     = 0.3   -- shaved off the timer each wave
Config.RushTimeMin      = 4.5   -- never goes below this
Config.BreatherSec      = 4.0   -- pause between the purge and the next call
Config.FallWatchSec     = 0.75    -- brief fall window before eliminated players spectate
Config.ShrinkEveryWaves = 3     -- shrink the grid this often
Config.ShrinkRings      = 1     -- rings peeled off each side when it shrinks
Config.MinGridSide      = 4     -- stop shrinking here (4x4 = 52 m)
-- One join = a MATCH of Config.Rounds rounds. Each round runs waves until one
-- player is left (or MaxWaves); then everyone respawns on a full grid for the
-- next. Most round wins takes the match (WinReward, split on a tie).
Config.Rounds           = 5
Config.MaxWaves         = 50    -- per round; 0 = no limit
-- Spare tiles the called colour must have beyond the number of players still
-- alive. This also caps the shrink: the arena never gets smaller than the
-- living field can physically stand on, so nobody is eliminated by geometry.
Config.TileHeadroom     = 2
-- Metres of room one CAR needs on a section without being shunted off. Everyone
-- drives, so this is a car footprint plus a gap — roughly 4 cars to a 13 m
-- section. Capacity is computed by AREA from this; too small and cars are packed
-- tighter than they can survive, too large and colours get stripped out of play.
Config.PlayerSpacing    = 6.0

-- ── Cars ────────────────────────────────────────────────────────────────────
-- Each ROUND one category is drawn at random and every player gets a random
-- car from it, so the field is matched but different every round. Base-game
-- models only. Drop a category or a car to take it out of the draw.
Config.CarClasses = {
    { name = "Super", cars = {
        "adder", "zentorno", "t20", "osiris", "entityxf", "cheetah", "turismor", "reaper",
        "fmj", "pfister811", "tempesta", "italigtb", "nero", "vagner", "xa21", "tyrus",
        "sc1", "cyclone", "visione", "autarch", "krieger", "emerus", "thrax", "zorrusso", "furia" } },
    { name = "Sports", cars = {
        "comet2", "comet5", "comets2r", "carbonizzare", "elegy", "elegy2", "feltzer2",
        "furoregt", "jester", "jester3", "jugular", "kuruma", "massacro", "neon",
        "pariah", "penumbra2", "rapidgt", "schafter3", "schlagen", "schwarzer",
        "specter", "sultan2", "vstr", "banshee", "buffalo2", "italigto",
        "ninef", "omnis", "growler", "calico", "euros", "zr350", "remus" } },
    { name = "Muscle", cars = {
        "dominator", "dominator3", "gauntlet", "gauntlet4", "buccaneer2", "dukes", "sabregt2",
        "vigero", "phoenix", "blade", "ruiner", "stalion", "ellie", "impaler", "yosemite",
        "deviant", "vamos", "clique", "tulip", "hermes" } },
    { name = "Sports Classics", cars = {
        "ztype", "stinger", "monroe", "jb700", "cheetah2", "infernus2", "torero", "turismo2",
        "gt500", "savestra", "viseris", "z190", "michelli", "fagaloa", "cheburek", "rapidgt3",
        "retinue", "ardent", "mamba", "coquette2" } },
    { name = "Coupes", cars = {
        "cogcabrio", "exemplar", "f620", "felon", "jackal", "oracle2", "sentinel", "sentinel2",
        "windsor", "zion", "previon", "kanjosj" } },
    { name = "Sedans", cars = {
        "asea", "fugitive", "glendale", "ingot", "intruder", "premier", "primo", "schafter2",
        "stanier", "stratum", "sultan", "tailgater", "washington", "warrener", "cinquemila", "deity" } },
    { name = "Compacts", cars = {
        "blista", "brioso", "dilettante", "issi2", "panto", "prairie", "rhapsody", "asbo",
        "kanjo", "club", "weevil", "brioso2" } },
    { name = "SUVs", cars = {
        "baller2", "cavalcade2", "dubsta", "granger", "gresley", "huntley", "landstalker2",
        "mesa", "patriot", "rocoto", "seminole2", "toros", "xls", "rebla", "novak" } },
    { name = "Off-road", cars = {
        "sandking", "rebel2", "bifta", "brawler", "dubsta3", "kamacho", "mesa3", "riata",
        "trophytruck", "caracara2", "everon", "winky", "hellion" } },
}
-- Cars take no damage in a round: elimination is decided purely by which section
-- you are on, so a wrecked engine in the scrum should never decide it.
Config.CarInvincible = true

-- ── Colours ─────────────────────────────────────────────────────────────────
-- One entry per colour variant. `model` is the streamed .ydr for that colour
-- (see Docs/BLENDER_TILE_GUIDE.md — one base mesh, one export per colour).
-- `rgb` is used for the HUD banner and for the DevFallback markers, so keep it
-- matched to the actual texture or the called colour won't read right.
-- Max 9 colours (the layout is packed one digit per tile).
Config.Colors = {
    -- `tint` = SetObjectTextureVariation index on the stunt-block prop. Check
    -- them in game with /crtint <0-15> and adjust if a colour looks wrong.
    { name = "RED",    rgb = { 214,  40,  40 }, model = "spz_cr_tile_red",    tint = 2  },
    { name = "BLUE",   rgb = {  40, 110, 225 }, model = "spz_cr_tile_blue",   tint = 7  },
    { name = "GREEN",  rgb = {  40, 190,  90 }, model = "spz_cr_tile_green",  tint = 6  },
    { name = "YELLOW", rgb = { 240, 205,  50 }, model = "spz_cr_tile_yellow", tint = 5  },
    { name = "ORANGE", rgb = { 240, 130,  35 }, model = "spz_cr_tile_orange", tint = 4  },
    { name = "PURPLE", rgb = { 150,  70, 210 }, model = "spz_cr_tile_purple", tint = 8  },
}

-- ── Dev fallback (play it before the models exist) ──────────────────────────
-- ON: no props are spawned at all. The grid is drawn as coloured markers on
-- whatever solid ground Config.Center sits on, and losing tiles eliminates you
-- logically instead of dropping you. Every bit of game logic — colour calls,
-- occupancy, elimination, shrink, payouts — is testable today.
-- OFF: real tiles spawn from Config.Colors[].model and physically despawn.
Config.DevFallback      = false   -- OFF: real platform in the sky
Config.FallbackDrawDist = 20.0   -- only draw markers this close (frame cost)

-- Everything downstream (Grid maths, spawns, the z window) reads Config.Center,
-- so resolve it here rather than teaching each call site about the two modes.
Config.Center = Config.DevFallback and Config.DevCenter or Config.RealCenter

-- ── Tile props (real mode) ──────────────────────────────────────────────────
-- Sections use OUR streamed tiles (Config.Colors[].model, registered by
-- stream/spz_colorrush.ytyp) -- solid colour, no overlay. Only if those fail to
-- load does it fall back to a VANILLA flat prop: the first
-- model in this list that loads is used, measured with GetModelDimensions, and
-- repeated as many times as it takes to cover one 13 m section. Colour comes
-- from a flat coloured marker drawn on top of each section (always correct),
-- plus SetObjectTextureVariation on the prop where the model supports it.
Config.TileProps = {
    "stt_prop_stunt_bblock_mdm3",
    "stt_prop_stunt_bblock_lrg3",
    "prop_container_05a",
}
Config.MaxPropsPerSide = 6   -- safety cap on props per section side
-- Solid colour square drawn on each section (the colour you rush to). The
-- "hollow players" bug was spz-core ghosting, not this -- fixed with spz:contact.
Config.ColorOverlay = true

-- ── Tile spawning (real mode) ──────────────────────────────────────────────
Config.SpawnBatch = 40    -- tiles created per frame (only 25 now, so one frame)

-- ── Grid maths ──────────────────────────────────────────────────────────────
-- Shared by client and server on purpose: both sides must agree exactly on
-- which tile a given coordinate is, or the server would eliminate people who
-- were visibly standing on the right colour.
Grid = {}

function Grid.span()    return Config.Grid * Config.TileSize end
function Grid.originX() return Config.Center.x - (Grid.span() * 0.5) end
function Grid.originY() return Config.Center.y - (Grid.span() * 0.5) end

-- 0-based tile coords → world centre of that tile
function Grid.tileCenter(ix, iy)
    return Grid.originX() + ((ix + 0.5) * Config.TileSize),
           Grid.originY() + ((iy + 0.5) * Config.TileSize)
end

function Grid.index(ix, iy) return (iy * Config.Grid) + ix + 1 end

function Grid.fromIndex(i)
    local z = i - 1
    return z % Config.Grid, math.floor(z / Config.Grid)
end

-- World XY → tile index, or nil if off the grid entirely
function Grid.atCoords(x, y)
    local ix = math.floor((x - Grid.originX()) / Config.TileSize)
    local iy = math.floor((y - Grid.originY()) / Config.TileSize)
    if ix < 0 or iy < 0 or ix >= Config.Grid or iy >= Config.Grid then return nil end
    return Grid.index(ix, iy), ix, iy
end

function Grid.total() return Config.Grid * Config.Grid end

-- How many players one section can physically hold.
function Grid.tileCapacity()
    local spacing = Config.PlayerSpacing or 1.2
    return math.max(1, math.floor((Config.TileSize / spacing) ^ 2))
end
