-- client/main.lua — Color Rush
-- The server owns everything that decides the game (which colour is called, who
-- was standing where, who is out). The client owns everything cosmetic: it
-- builds the tile grid as LOCAL objects from the layout string, deletes the
-- losing colours on cue, draws the HUD, and parks the eliminated overhead.
--
-- Tiles are deliberately local (CreateObject with isNetwork = false). A 30x30
-- grid is 900 entities — networked, that would eat the entity budget and flood
-- sync for no benefit, since every client can derive the identical grid from
-- the same layout string.

local active  = false
local alive   = false
local HUD     = exports["spz-minigames"]   -- shared in-game HUD (all on-screen text)
local state   = { phase = "build", wave = 0, remain = 0, alive = 0, total = 0 }
local jumpUsed = nil   -- "round:wave" the car jump was spent in (waves restart every round)
local tiles   = {}     -- [tileIndex] = object handle (real mode only)
local cells   = {}     -- [tileIndex] = colour index, 0 = no tile
local myBackH
local myBack  = nil
local myVeh   = 0      -- the car this player drives for the round
local spectating = false
local loaded  = false

RegisterNetEvent("spz-colorrush:notify", function(msg, t)
    lib.notify({ description = msg, type = t or "info" })
end)

-- ── Model loading ───────────────────────────────────────────────────────────
-- Preferred: our own streamed tiles (stream/spz_cr_tile_<colour>.ydr, one solid
-- colour each, registered by stream/spz_colorrush.ytyp). One model per colour,
-- one object per section.
-- Fallback: if any of them fail to load, sections are built from a vanilla prop
-- (Config.TileProps) repeated n x n, coloured by `tint` + the overlay.

local colorModels = nil   -- [colourIdx] = { hash, zOff }  (custom tiles)
local tileProp = nil      -- { hash, nx, ny, stepX, stepY, zOff }  (fallback)
local tileColor = {}      -- [tileIndex] = colour the section currently shows

-- After a match everyone spawns at the hub's shared return point (DK garage).
local function returnPoint(ped)
    if GetResourceState("spz-minigames") == "started" then
        local ok, p = pcall(function() return exports["spz-minigames"]:ReturnPoint() end)
        if ok and p then return vector3(p.x, p.y, p.z), p.w end
    end
    return GetEntityCoords(ped), GetEntityHeading(ped)
end

local function loadModel(name)
    local hash = GetHashKey(name)
    if not IsModelInCdimage(hash) then return nil end
    RequestModel(hash)
    local dl = GetGameTimer() + 10000
    while not HasModelLoaded(hash) and GetGameTimer() < dl do Wait(20) end
    return HasModelLoaded(hash) and hash or nil
end

local function ensureModels()
    if Config.DevFallback or loaded then return true end

    local all = {}
    for idx, c in ipairs(Config.Colors) do
        local hash = c.model and loadModel(c.model)
        if not hash then all = nil; break end
        local _, mx = GetModelDimensions(hash)
        all[idx] = { hash = hash, zOff = -mx.z }   -- top face flush with Center.z
    end
    if all then
        colorModels = all
        loaded = true
        return true
    end

    for _, name in ipairs(Config.TileProps or {}) do
        local hash = loadModel(name)
        if hash then
            local mn, mx = GetModelDimensions(hash)
            -- X and Y measured separately: using one size for both made the
            -- props overlap along their long axis, and overlapping coplanar
            -- tops z-fight (the flickering pattern).
            local cap = Config.MaxPropsPerSide or 6
            local sx = math.max(0.5, mx.x - mn.x)
            local sy = math.max(0.5, mx.y - mn.y)
            local nx = math.min(cap, math.max(1, math.ceil(Config.TileSize / sx)))
            local ny = math.min(cap, math.max(1, math.ceil(Config.TileSize / sy)))
            tileProp = {
                hash = hash, nx = nx, ny = ny,
                stepX = Config.TileSize / nx, stepY = Config.TileSize / ny,
                zOff = -mx.z,
            }
            loaded = true
            return true
        end
    end
    lib.notify({
        title = "COLOR RUSH",
        description = "No platform prop could be loaded. Set Config.DevFallback = true to play on the ground.",
        type = "error", duration = 12000,
    })
    return false
end

--- True when sections are our own solid-colour tiles (no overlay needed).
local function usingCustomTiles() return colorModels ~= nil end

-- ── Grid build / purge ──────────────────────────────────────────────────────

local function deleteObjs(list)
    for _, obj in ipairs(list or {}) do
        if obj ~= 0 and DoesEntityExist(obj) then DeleteEntity(obj) end
    end
end

local function deleteTile(i)
    deleteObjs(tiles[i])
    tiles[i] = nil
    tileColor[i] = nil
end

local function clearTiles()
    for i in pairs(tiles) do deleteTile(i) end
    tiles = {}
    tileColor = {}
end

local function placeObj(hash, x, y, z)
    -- Local, non-networked: strict bucket lockdown only blocks networked
    -- client entities, and every client builds the same grid anyway.
    local obj = CreateObjectNoOffset(hash, x, y, z, false, false, false)
    if obj == 0 then return nil end
    SetEntityCoordsNoOffset(obj, x, y, z, false, false, false)
    SetEntityRotation(obj, 0.0, 0.0, 0.0, 2, true)
    FreezeEntityPosition(obj, true)
    SetEntityAsMissionEntity(obj, true, true)
    SetEntityDynamic(obj, false)
    SetEntityLodDist(obj, 1000)
    return obj
end

local function spawnTile(i, colorIdx)
    local ix, iy = Grid.fromIndex(i)
    local cx, cy = Grid.tileCenter(ix, iy)
    local list = {}

    if colorModels then
        local m = colorModels[colorIdx]
        local obj = m and placeObj(m.hash, cx, cy, Config.Center.z + m.zOff)
        if obj then list[1] = obj end
    else
        local p = tileProp
        local half = Config.TileSize * 0.5
        local tint = Config.Colors[colorIdx] and Config.Colors[colorIdx].tint
        for a = 0, p.nx - 1 do
            for b = 0, p.ny - 1 do
                local x = cx - half + (a + 0.5) * p.stepX
                local y = cy - half + (b + 0.5) * p.stepY
                -- Checkerboard a tiny height step so overlaps never z-fight.
                local z = Config.Center.z + p.zOff - (((a + b) % 2 == 0) and 0.0 or 0.03)
                local obj = placeObj(p.hash, x, y, z)
                if obj then
                    if tint then SetObjectTextureVariation(obj, tint) end
                    list[#list + 1] = obj
                end
            end
        end
    end
    tiles[i] = list
    tileColor[i] = colorIdx
end

-- Diff against what is already standing: only sections that appear, vanish or
-- change colour are touched, so a new wave never pulls the floor out from
-- under the cars.
local function buildGrid(packed)
    local made = 0
    for i = 1, Grid.total() do
        local c = tonumber(packed:sub(i, i)) or 0
        cells[i] = c
        if not Config.DevFallback and (colorModels or tileProp) then
            if c > 0 and tiles[i] and tileColor[i] ~= c then
                if colorModels then
                    -- New colour = different model: place the new tile first,
                    -- then remove the old one, so there is never a gap.
                    local old = tiles[i]
                    spawnTile(i, c)
                    deleteObjs(old)
                else
                    local tint = Config.Colors[c].tint
                    for _, obj in ipairs(tiles[i]) do
                        if tint and DoesEntityExist(obj) then SetObjectTextureVariation(obj, tint) end
                    end
                    tileColor[i] = c
                end
            elseif c > 0 and not tiles[i] then
                spawnTile(i, c)
                made = made + 1
                if (made % (Config.SpawnBatch or 40)) == 0 then Wait(0) end
            elseif c == 0 and tiles[i] then
                deleteTile(i)
            end
        end
    end
end

local function purgeGrid(target)
    for i = 1, Grid.total() do
        if cells[i] ~= 0 and cells[i] ~= target then
            cells[i] = 0
            deleteTile(i)
        end
    end
end

-- ── Car ─────────────────────────────────────────────────────────────────────

--- Take over the car the server created for us (see server spawnCarFor).
local function claimCar(netId)
    if not netId then return 0 end
    local dl = GetGameTimer() + 8000
    while not NetworkDoesEntityExistWithNetworkId(netId) and GetGameTimer() < dl do Wait(50) end
    if not NetworkDoesEntityExistWithNetworkId(netId) then
        lib.notify({ title = "COLOR RUSH", description = "Your car failed to arrive", type = "error" })
        return 0
    end
    local veh = NetToVeh(netId)
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)
    TaskWarpPedIntoVehicle(ped, veh, -1)
    dl = GetGameTimer() + 3000
    while GetPedInVehicleSeat(veh, -1) ~= ped and GetGameTimer() < dl do Wait(20) end
    dl = GetGameTimer() + 3000
    while not NetworkHasControlOfEntity(veh) and GetGameTimer() < dl do
        NetworkRequestControlOfEntity(veh); Wait(20)
    end
    FreezeEntityPosition(veh, false)
    SetVehicleUndriveable(veh, false)
    SetVehicleHandbrake(veh, false)
    SetVehicleOnGroundProperly(veh)

    SetVehicleEngineOn(veh, true, true, false)
    SetVehicleDirtLevel(veh, 0.0)
    SetVehicleNumberPlateText(veh, ("CR%03d"):format(math.random(0, 999)))

    if Config.CarInvincible then
        -- Elimination is decided by the section you are on. A car destroyed in
        -- the scrum must never decide it, and a burning wreck mid-round would
        -- drag the death/respawn flow into the middle of a wave.
        SetEntityInvincible(veh, true)
        SetVehicleCanBeVisiblyDamaged(veh, false)
        SetVehicleTyresCanBurst(veh, false)
        SetVehicleWheelsCanBreak(veh, false)
    end
    return veh
end

local function deleteCar()
    if myVeh ~= 0 and DoesEntityExist(myVeh) then
        SetEntityAsMissionEntity(myVeh, true, true)
        DeleteEntity(myVeh)
    end
    myVeh = 0
end

-- ── Spectate / cleanup ──────────────────────────────────────────────────────

local function enterSpectate()
    if spectating then return end
    spectating = true
    -- The car has already done its job falling; take it with us so 30 wrecks
    -- are not left tumbling below the arena.
    deleteCar()
    local ped = PlayerPedId()
    SetEntityInvincible(ped, true)
    SetEntityVisible(ped, false, false)
    SetEntityCollision(ped, false, false)
    SetEntityCoords(ped, Config.Center.x, Config.Center.y - 10.0, Config.Center.z + 45.0, false, false, false, false)
    FreezeEntityPosition(ped, true)
end

local function cleanup()
    active = false
    alive = false
    HUD:Hud(nil)
    TriggerServerEvent("spz:setPlayerFlag", "inMinigame", false)
    TriggerEvent("spz:minigameChanged")
    spectating = false
    clearTiles()
    deleteCar()
    cells = {}

    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)
    SetEntityVisible(ped, true, false)
    SetEntityCollision(ped, true, true)
    SetEntityInvincible(ped, false)

    if myBack then
        SetEntityCoords(ped, myBack.x, myBack.y, myBack.z, false, false, false, false)
        if myBackH then SetEntityHeading(ped, myBackH) end
        myBack = nil
    end
end


-- Countdown / GO clips from spz-raceUI (ui/public/aud), game audio as fallback.
local function playClip(name)
    if GetResourceState("spz-raceUI") == "started" then
        local ok = pcall(function() exports["spz-raceUI"]:PlaySound(name, 1.0) end)
        if ok then return end
    end
    if name == "go" then
        PlaySoundFrontend(-1, "GO", "HUD_MINI_GAME_SOUNDSET", true)
    else
        PlaySoundFrontend(-1, "3_2_1", "HUD_MINI_GAME_SOUNDSET", true)
    end
end

-- Big centred number for the 3-2-1, shown for ~0.9 s.
local function flashCount(txt, color)
    HUD:Flash(txt, color, 900)
end


-- Joining a minigame: despawn the freeroam car the player was driving, so it
-- isn't left abandoned in freeroam (or dragged into the minigame world).
local function despawnFreeroamCar()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 or GetPedInVehicleSeat(veh, -1) ~= ped then return end
    local dl = GetGameTimer() + 1000
    while not NetworkHasControlOfEntity(veh) and GetGameTimer() < dl do
        NetworkRequestControlOfEntity(veh); Wait(0)
    end
    SetEntityAsMissionEntity(veh, true, true)
    DeleteVehicle(veh)
    if DoesEntityExist(veh) then DeleteEntity(veh) end
end

-- ── Round events ────────────────────────────────────────────────────────────

RegisterNetEvent("spz-colorrush:start", function(d)
    DoScreenFadeOut(300)
    Wait(300)

    if not ensureModels() then
        DoScreenFadeIn(300)
        return
    end

    active = true
    alive = true
    spectating = false
    jumpUsed = nil
    TriggerServerEvent("spz:setPlayerFlag", "inMinigame", "Color Rush")
    TriggerEvent("spz:minigameChanged")

    local ped = PlayerPedId()
    myBack, myBackH = returnPoint(ped)
    despawnFreeroamCar()
    ped = PlayerPedId()

    SetEntityCoords(ped, d.spawn.x, d.spawn.y, d.spawn.z + 2.0, false, false, false, false)
    FreezeEntityPosition(ped, true)
    -- Invincible throughout: elimination is decided by the server on section
    -- colour, so the fall off the edge should never also kill the ped and drag
    -- the respawn flow into the middle of a round.
    SetEntityInvincible(ped, true)
    ClearPedTasksImmediately(ped)
    -- Drops the ghosting pair exclusions spz-core put on this ped, so cars in
    -- the round actually collide (server sets spz:contact for everyone here).
    SetEntityCollision(ped, true, true)
    ResetEntityAlpha(ped)

    -- Platform first, then ask for the car: the server only creates it once
    -- the grid exists under it (spz-colorrush:car below).
    if d.packed then buildGrid(d.packed) end
    Wait(250)
    TriggerServerEvent("spz-colorrush:ready")

    lib.notify({
        title = "COLOR RUSH",
        description = "Drive onto the colour that gets called. Every other section disappears.",
        type = "inform", duration = 6000,
    })
    DoScreenFadeIn(500)
end)

-- Outer band that collapses at the end of this wave: [ring, doomRing) on each
-- side. Drawn red during the rush so nobody parks on it.
local doom = nil

-- Next round of the match: out of spectate, back onto a fresh full grid, new car.
RegisterNetEvent("spz-colorrush:respawn", function(d)
    if not active then return end
    DoScreenFadeOut(300)
    Wait(300)
    deleteCar()
    spectating = false
    alive = true
    doom = nil
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)
    SetEntityVisible(ped, true, false)
    SetEntityCollision(ped, true, true)
    SetEntityCoords(ped, d.spawn.x, d.spawn.y, d.spawn.z + 2.0, false, false, false, false)
    FreezeEntityPosition(ped, true)
    if d.packed then buildGrid(d.packed) end
    Wait(250)
    TriggerServerEvent("spz-colorrush:ready")
    lib.notify({ title = ("ROUND %d / %d"):format(d.round or 0, d.rounds or 0),
                 description = "Fresh grid — back on the platform.", type = "inform", duration = 4000 })
    DoScreenFadeIn(500)
end)

RegisterNetEvent("spz-colorrush:roundOver", function(d)
    if not active then return end
    local who = (#(d.winners or {}) > 0) and table.concat(d.winners, ", ") or "nobody"
    local lines = {}
    for i, s in ipairs(d.standings or {}) do
        if i > 5 then break end
        lines[#lines + 1] = ("%d. %s — %d"):format(i, s.name, s.wins)
    end
    lib.notify({
        title = ("ROUND %d / %d — %s"):format(d.round or 0, d.rounds or 0, who),
        description = table.concat(lines, "\n"), type = "success", duration = 5000,
    })
end)

RegisterNetEvent("spz-colorrush:car", function(d)
    if not active then return end
    myVeh = claimCar(d.netId)
    if myVeh == 0 then FreezeEntityPosition(PlayerPedId(), false) end
end)

RegisterNetEvent("spz-colorrush:countdown", function(n)
    if not active then return end
    flashCount(tostring(n))
    playClip("countdown")
end)

RegisterNetEvent("spz-colorrush:layout", function(d)
    if not active then return end
    doom = nil               -- the warned band is gone; the new grid starts clean
    buildGrid(d.packed)
end)

local function inDoom(ix, iy)
    if not doom then return false end
    local lo, hi = doom.to, Config.Grid - doom.to
    return ix < lo or ix >= hi or iy < lo or iy >= hi
end

RegisterNetEvent("spz-colorrush:call", function(d)
    if not active then return end
    local c = Config.Colors[d.target]
    if not c then return end
    playClip("go")
    doom = (d.doomRing and d.ring and d.doomRing > d.ring) and { from = d.ring, to = d.doomRing } or nil
    lib.notify({ title = c.name .. "!", description = ("Wave %d — go!"):format(d.wave or 0), type = "warning", duration = 2500 })
    if doom then
        lib.notify({ title = "Edge collapsing", description = "The red outer tiles drop after this wave — stay inside.",
                     type = "error", duration = 4000 })
    end
end)

-- Red pulse over the collapsing band (any mode: real tiles or fallback).
CreateThread(function()
    while true do
        if active and doom and next(cells) then
            local a = math.floor(90 + 70 * math.abs(math.sin(GetGameTimer() / 220.0)))
            local h = Config.TileSize * 0.5
            local z = Config.DevFallback and (Config.Center.z - 0.85) or (Config.Center.z + 0.1)
            for iy = doom.from, Config.Grid - 1 - doom.from do
                for ix = doom.from, Config.Grid - 1 - doom.from do
                    local c = cells[Grid.index(ix, iy)]
                    if c and c > 0 and inDoom(ix, iy) then
                        local x, y = Grid.tileCenter(ix, iy)
                        local x1, x2, y1, y2 = x - h, x + h, y - h, y + h
                        DrawPoly(x1, y1, z, x2, y2, z, x2, y1, z, 255, 40, 40, a)
                        DrawPoly(x1, y1, z, x1, y2, z, x2, y2, z, 255, 40, 40, a)
                        DrawPoly(x2, y1, z, x2, y2, z, x1, y1, z, 255, 40, 40, a)
                        DrawPoly(x2, y2, z, x1, y2, z, x1, y1, z, 255, 40, 40, a)
                    end
                end
            end
            Wait(0)
        else
            Wait(250)
        end
    end
end)

RegisterNetEvent("spz-colorrush:purge", function(d)
    if not active then return end
    purgeGrid(d.target)
    PlaySoundFrontend(-1, "Explosion_Text", "GTAO_Exec_SMPL_Intro_Sounds", true)
end)

RegisterNetEvent("spz-colorrush:eliminated", function(d)
    if not active then return end
    alive = false
    lib.notify({
        title = "ELIMINATED",
        description = ("%s · survived %d wave(s)"):format(d.why or "wrong tile", d.waves or 0),
        type = "error", duration = 6000,
    })
    -- In fallback mode there is no edge to fall off, so the hit needs to land
    -- some other way: cut the engine and let them coast to a stop.
    if Config.DevFallback and myVeh ~= 0 and DoesEntityExist(myVeh) then
        SetVehicleEngineOn(myVeh, false, true, true)
        SetVehicleUndriveable(myVeh, true)
    end
end)

RegisterNetEvent("spz-colorrush:spectate", function()
    if active and not alive then enterSpectate() end
end)

RegisterNetEvent("spz-colorrush:feed", function(d)
    lib.notify({ description = ("%s — %s"):format(d.name or "A player", d.why or "out"), type = "inform", duration = 2500 })
end)

RegisterNetEvent("spz-colorrush:state", function(s)
    state = s
    if s.me ~= nil then alive = s.me end
end)

RegisterNetEvent("spz-colorrush:over", function(r)
    local msg
    if r.won then
        msg = (r.survivors and r.survivors > 1)
            and ("Match won — tied on %d round win(s)"):format(r.roundWins or 0)
            or ("Match won — %d of %d rounds!"):format(r.roundWins or 0, r.rounds or 0)
    else
        msg = ("%d round win(s) of %d · %d wave(s) survived"):format(r.roundWins or 0, r.rounds or 0, r.waves or 0)
    end
    if (r.payout or 0) > 0 then msg = msg .. (" · +%d credits"):format(r.payout) end

    DoScreenFadeOut(400)
    Wait(400)
    cleanup()
    HUD:Shard(r.won and "Match won" or "Match over", msg, r.won and "ok" or "accent", 7000)
    DoScreenFadeIn(600)
end)

-- ── HUD ─────────────────────────────────────────────────────────────────────

-- Defined further down with the car jump; read here for the footer.
local jumpFoot

CreateThread(function()
    while true do
        if active then
            local col = state.target and Config.Colors[state.target] or nil
            local hud = { chips = {
                ("Round %d / %d"):format(state.round or 1, state.rounds or 1),
                ("Wave %d"):format(state.wave or 0),
                ("%d / %d alive"):format(state.alive or 0, state.total or 0),
            } }

            if state.phase == "call" and col then
                hud.status = { label = "Get to", value = col.name, color = col.rgb,
                               sub = ("%.1f s"):format(state.remain or 0) }
            elseif state.phase == "build" then
                hud.status = { label = "Get ready", value = "New grid", color = "dim" }
            elseif state.phase == "purge" or state.phase == "resolve" then
                hud.status = col and { label = "Only", value = col.name, color = col.rgb, sub = "remains" }
                          or { value = "Purge", color = "bad" }
            elseif state.phase == "breather" then
                hud.status = { label = "Breathe", value = "Next colour", color = "dim" }
            end
            if doom then hud.alert = "Edge collapsing — stay off the red" end
            hud.board = state.board

            if not alive then
                hud.foot = { text = "Spectating", color = "bad" }
            elseif jumpFoot then
                hud.foot = jumpFoot()
            end

            -- key bar (live bindings, resolved by spz-minigames)
            hud.keys = {}
            if alive and not spectating and (state.wave or 0) > 0 then
                local ready = jumpUsed ~= ((state.round or 1) .. ":" .. (state.wave or 0))   -- same key as jumpKey() below
                hud.keys[1] = { cmd = "+cr_jump", default = Config.JumpKey or "E", pad = "RLEFT_INDEX", label = "Jump", hot = ready, dim = not ready }
            end
            hud.keys[#hud.keys + 1] = { control = 200, default = "ESC", pad = "START_INDEX", label = "Menu · leave" }
            HUD:Hud(hud)
            Wait(100)
        else
            Wait(500)
        end
    end
end)

-- ── Dev fallback: draw the grid as markers ──────────────────────────────────
-- No props, no streaming, no models — the whole game is playable on any flat
-- patch of solid ground. Only tiles within FallbackDrawDist are drawn, since
-- the full 900 would be a per-frame marker flood.

CreateThread(function()
    while true do
        -- Real mode draws nothing unless Config.ColorOverlay is on (see config).
        if active and next(cells) and (Config.DevFallback or (Config.ColorOverlay and not usingCustomTiles())) then
            local p = GetEntityCoords(PlayerPedId())
            local reach = Config.DevFallback and math.ceil((Config.FallbackDrawDist or 20.0) / Config.TileSize) or Config.Grid
            local _, cix, ciy = Grid.atCoords(p.x, p.y)

            -- Off the grid entirely? Aim the draw window at the arena centre so
            -- the player can still see where to run back to.
            if not cix then
                cix = math.floor(Config.Grid / 2)
                ciy = math.floor(Config.Grid / 2)
            end

            for iy = math.max(0, ciy - reach), math.min(Config.Grid - 1, ciy + reach) do
                for ix = math.max(0, cix - reach), math.min(Config.Grid - 1, cix + reach) do
                    local i = Grid.index(ix, iy)
                    local c = cells[i]
                    if c and c > 0 then
                        local rgb = Config.Colors[c].rgb
                        local x, y = Grid.tileCenter(ix, iy)
                        -- Real mode: a thin coloured slab just on top of the
                        -- prop is what shows the section's colour.
                        -- A filled square covering the whole section (a
                        -- DrawMarker cylinder only showed as a thin ring).
                        local h = Config.TileSize * 0.48
                        local z = Config.DevFallback and (Config.Center.z - 0.9) or (Config.Center.z + 0.06)
                        local x1, x2, y1, y2 = x - h, x + h, y - h, y + h
                        DrawPoly(x1, y1, z, x2, y2, z, x2, y1, z, rgb[1], rgb[2], rgb[3], 235)
                        DrawPoly(x1, y1, z, x1, y2, z, x2, y2, z, rgb[1], rgb[2], rgb[3], 235)
                        DrawPoly(x2, y1, z, x2, y2, z, x1, y1, z, rgb[1], rgb[2], rgb[3], 235)
                        DrawPoly(x2, y2, z, x1, y2, z, x1, y1, z, rgb[1], rgb[2], rgb[3], 235)
                    end
                end
            end
            Wait(0)
        else
            Wait(500)
        end
    end
end)

-- ── Queue menu ──────────────────────────────────────────────────────────────

local function openLobbyMenu()
    local st = lib.callback.await("spz-colorrush:lobbyState", false)
    if not st then return end

    if st.roundLive then
        lib.notify({ description = ("A round is live (wave %d)."):format(st.wave or 0), type = "warning" })
        return
    end

    local online = lib.callback.await("spz-colorrush:online", false) or {}
    local inviteOptions = {}
    if #online == 0 then
        inviteOptions[1] = { title = "No one else online", disabled = true }
    else
        for _, p in ipairs(online) do
            inviteOptions[#inviteOptions + 1] = {
                title = p.name, icon = "user-plus",
                onSelect = function() TriggerServerEvent("spz-colorrush:invite", p.source) end,
            }
        end
    end
    lib.registerContext({
        id = "spz_colorrush_invite", title = "Invite Player", menu = "spz_colorrush_lobby",
        search = #online > 6, options = inviteOptions,
    })

    local mainOptions = {
        {
            title = st.inLobby and "Leave Room" or "Quick Join",
            description = st.inLobby and "You are queued — tap to leave" or "Free to join",
            icon = st.inLobby and "right-from-bracket" or "right-to-bracket",
            iconColor = st.inLobby and "#ff4d5e" or "#22c55e",
            onSelect = function()
                lib.callback.await("spz-colorrush:joinToggle", false)
                openLobbyMenu()
            end,
        },
        {
            title = "Invite Player", description = #online .. " online",
            icon = "user-plus", arrow = true, menu = "spz_colorrush_invite",
        },
        {
            title = ("── %s %d/%d%s ──"):format(st.room and st.room.name or "Room", st.count, st.max,
                st.armed and (" · starts in " .. (st.armedRemain or 0) .. "s") or ""),
            disabled = true,
        },
    }

    if #st.roster == 0 then
        mainOptions[#mainOptions + 1] = { title = "Queue is empty", disabled = true }
    else
        for _, r in ipairs(st.roster) do
            mainOptions[#mainOptions + 1] = { title = (r.isMe and "★ " or "") .. r.name, disabled = true }
        end
    end

    lib.registerContext({ id = "spz_colorrush_lobby", title = "🎨 Color Rush", options = mainOptions })
    lib.showContext("spz_colorrush_lobby")
end

RegisterCommand(Config.MenuCommand, function() openLobbyMenu() end, false)

-- /crtint <0-15>: spawns a test block in front of you with that texture
-- variation, to find the right `tint` for each colour in config.lua.
local tintProbe = 0
RegisterCommand("crtint", function(_, args)
    if tintProbe ~= 0 and DoesEntityExist(tintProbe) then DeleteEntity(tintProbe) end
    if not ensureModels() or not tileProp then
        lib.notify({ description = "Using the custom colour tiles — /crtint is only for the vanilla fallback." })
        return
    end
    local n = tonumber(args[1]) or 0
    local ped = PlayerPedId()
    local p = GetOffsetFromEntityInWorldCoords(ped, 0.0, 8.0, 0.0)
    tintProbe = CreateObjectNoOffset(tileProp.hash, p.x, p.y, p.z, false, false, false)
    FreezeEntityPosition(tintProbe, true)
    SetObjectTextureVariation(tintProbe, n)
    lib.notify({ title = "COLOR RUSH", description = ("Texture variation %d"):format(n) })
end, false)
RegisterKeyMapping(Config.MenuCommand, "Color Rush queue menu", "keyboard", "")

RegisterNetEvent("spz-colorrush:invited", function(d)
    -- Racing / queued / in another minigame: a dialog would grab mouse focus
    -- and lock the car mid-race. Just tell them; the invite is kept, so the
    -- room shows as invited in the hub once they are free.
    do
        local st = LocalPlayer.state
        if st.inRace or st.inQueue or st.inMinigame or st.inTimeTrial then
            lib.notify({ title = "Color Rush invite",
                description = ("%s invited you to %s — open the minigames hub when you're free."):format(d.fromName or "Someone", d.roomName or "their room"),
                type = "inform", duration = 7000 })
            return
        end
    end
    local resp = lib.alertDialog({
        header = "Color Rush Invite",
        content = ("**%s** invited you to **%s** (Color Rush)."):format(d.fromName or "Someone", d.roomName or "their room"),
        centered = true, cancel = true,
        labels = { cancel = "Dismiss", confirm = "Join" },
    })
    if resp == "confirm" then TriggerServerEvent("spz-colorrush:acceptInvite", d.room) end
end)

AddEventHandler("spz:leaveMinigame", function()
    if active then TriggerServerEvent("spz-colorrush:leave") end
end)

AddEventHandler("onResourceStop", function(res)
    if res == GetCurrentResourceName() and active then cleanup() end
end)

-- ── Car jump: one per wave ──────────────────────────────────────────────────
-- Purely a movement aid (the server still judges where you land), so it lives
-- on the client. Keyed by round AND wave: wave numbers restart every round, so
-- a jump spent in round 1 wave 1 used to show JUMP USED in round 2 wave 1.
local function jumpKey() return (state.round or 1) .. ":" .. (state.wave or 0) end

RegisterCommand("+cr_jump", function()
    if not active or not alive or spectating then return end
    if myVeh == 0 or not DoesEntityExist(myVeh) then return end
    if (state.wave or 0) <= 0 or jumpUsed == jumpKey() then return end
    if GetPedInVehicleSeat(myVeh, -1) ~= PlayerPedId() then return end
    if IsEntityInAir(myVeh) then return end
    jumpUsed = jumpKey()
    local v = GetEntityVelocity(myVeh)
    local f = GetEntityForwardVector(myVeh)
    local fwd = Config.JumpForward or 0.0
    SetEntityVelocity(myVeh, v.x + f.x * fwd, v.y + f.y * fwd, v.z + (Config.JumpVelocity or 9.0))
    PlaySoundFrontend(-1, "Hit_In", "PLAYER_SWITCH_CUSTOM_SOUNDSET", true)
end, false)
RegisterCommand("-cr_jump", function() end, false)
RegisterKeyMapping("+cr_jump", "Color Rush: car jump (once per wave)", "keyboard", Config.JumpKey or "E")
RegisterKeyMapping("+cr_jump", "Color Rush: car jump (controller)", "PAD_DIGITALBUTTON", "RLEFT_INDEX")

jumpFoot = function()
    if spectating or (state.wave or 0) <= 0 then return nil end
    if jumpUsed ~= jumpKey() then
        return { text = "Jump ready", cmd = "+cr_jump", default = Config.JumpKey or "E", pad = "RLEFT_INDEX", color = "ok" }
    end
    return { text = "Jump used", color = "dim" }
end
