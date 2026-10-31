-- server/main.lua — Color Rush
-- Rooms → waves of "rush to the called colour" → the server reads every
-- player's real coords to decide who fell, so nothing about elimination is
-- client-trusted. The tiles themselves are spawned client-side as local
-- objects (see client/main.lua) — the server only ever ships the LAYOUT, a
-- one-digit-per-tile string, so a grid costs zero server entities.
--
-- Several rooms can play at once: each round has its own routing bucket, and
-- the platform is client-local, so every room gets its own copy of the deck.

local Log = SPZ and SPZ.Logger and SPZ.Logger("spz-colorrush") or nil
local function log(m) if Log then Log.info(m) else print("[colorrush] " .. m) end end

local EV = "spz-colorrush:"

local Rooms = {}         -- [id] = { id, name, host, private, max, members = { [src] = { pid, name } }, armed, armedAt, round }
local RoomOf = {}        -- [src] = room
local Invites = {}       -- [src] = { [roomId] = true, last = roomId }
local nextRoomId = 1

-- ── Helpers ─────────────────────────────────────────────────────────────────

local function notify(src, msg, t)
    TriggerClientEvent(EV .. "notify", src, msg, t or "info")
end

local function pidOf(src)
    local ok, p = pcall(function() return exports["spz-identity"]:GetProfile(src) end)
    return ok and p and p.id or nil, ok and p or nil
end

local function nameOf(src)
    local _, prof = pidOf(src)
    return (prof and prof.username) or GetPlayerName(src) or ("Racer" .. src)
end

local function srcFromPid(pid)
    for _, s in ipairs(GetPlayers()) do
        if pidOf(tonumber(s)) == pid then return tonumber(s) end
    end
    return nil
end

local function payPid(pid, amt, reason)
    if not pid or amt <= 0 then return end
    local s = srcFromPid(pid)
    if s and GetResourceState("spz-progression") == "started" then
        exports["spz-progression"]:GrantBonus(s, { credits = amt, reason = reason })
    else
        MySQL.update.await("UPDATE players SET credits = credits + ? WHERE id = ?", { amt, pid })
    end
end

local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

local function shuffle(t)
    for i = #t, 2, -1 do local j = math.random(i); t[i], t[j] = t[j], t[i] end
end

local function roundOf(src)
    local room = RoomOf[src]
    local r = room and room.round
    return (r and r.players[src]) and r or nil
end

local function toAll(r, event, payload)
    if not r then return end
    for src in pairs(r.players) do TriggerClientEvent(event, src, payload) end
end

local function aliveList(r)
    local out = {}
    if not r then return out end
    for src, p in pairs(r.players) do
        if p.alive then out[#out + 1] = src end
    end
    return out
end

-- spz-core ghosts every player unless BOTH carry `spz:contact`; round players
-- get it so their cars actually shove each other.
local function setContact(src, on)
    if GetPlayerName(src) then Player(src).state:set("spz:contact", on or nil, true) end
end

-- Cars are created HERE: spz-core buckets run strict entity lockdown and delete
-- networked entities a client creates.
-- One random category per round (Config.CarClasses), a random car from it per
-- player. r.carClass is cleared when a new round respawns everyone.
local function roundClass(r)
    if not r.carClass then
        local list = Config.CarClasses or {}
        r.carClass = list[math.random(math.max(1, #list))] or { name = "Sports", cars = Config.Cars or { "sultan" } }
    end
    return r.carClass
end

local function tellClass(src, cls, model)
    TriggerClientEvent("ox_lib:notify", src, {
        title = cls.name:upper() .. " ROUND",
        description = ("Your car: %s"):format(model),
        type = "inform", duration = 4000,
    })
end

local function spawnCarFor(_, bucketId, x, y, z, heading, pool)
    -- A bad model name in the config fails to create; try a few others.
    local veh, model = 0, nil
    for _ = 1, 4 do
        model = pool[math.random(#pool)]
        veh = CreateVehicleServerSetter(joaat(model), "automobile", x, y, z, heading or 0.0)
        local dl = GetGameTimer() + 3000
        while veh ~= 0 and not DoesEntityExist(veh) and GetGameTimer() < dl do Wait(0) end
        if veh ~= 0 and DoesEntityExist(veh) then break end
        print(("^3[cars] could not create '%s', retrying^7"):format(tostring(model)))
        veh = 0
    end
    if veh == 0 then return nil end
    if bucketId ~= 0 then SetEntityRoutingBucket(veh, bucketId) end
    SetEntityOrphanMode(veh, 2)
    return veh, model
end

local function deleteCar(p)
    local veh = p and p.veh
    if p then p.veh = nil end
    if not veh or not DoesEntityExist(veh) then return end
    DeleteEntity(veh)
    -- A car whose driver just disconnected is mid hand-over to another client,
    -- and a delete in that window can be lost. Check again and retry.
    for _, ms in ipairs({ 500, 2000, 5000 }) do
        SetTimeout(ms, function()
            if DoesEntityExist(veh) then DeleteEntity(veh) end
        end)
    end
end

local function eliminate(r, src, why)
    local p = r and r.players[src]
    if not p or not p.alive then return end
    p.alive = false
    p.outAt = GetGameTimer()
    TriggerClientEvent(EV .. "eliminated", src, { why = why, waves = p.waves or 0 })
    toAll(r, EV .. "feed", { name = p.name, why = why })
end

-- Match over: most round wins takes WinReward (split on a tie); everyone gets
-- SurvivalBonus per wave survived. Then everyone home, room back to its lobby.
local function endRound(r, why)
    if not r or not r.active then return end
    r.active = false
    if r.room.round == r then r.room.round = nil end

    local best = 0
    for _, p in pairs(r.players) do if not p.left then best = math.max(best, p.roundWins or 0) end end
    local winners = {}
    for _, p in pairs(r.players) do
        if not p.left and best > 0 and (p.roundWins or 0) == best then winners[#winners + 1] = p end
    end

    for src, p in pairs(r.players) do
        deleteCar(p)
        setContact(src, false)
        local won = best > 0 and (p.roundWins or 0) == best and not p.left
        local total = (p.waves or 0) * (Config.SurvivalBonus or 0)
        if won then total = total + math.floor((Config.WinReward or 0) / math.max(1, #winners)) end
        if total > 0 then payPid(p.pid, total, "Color Rush") end
        if not p.left then
            TriggerClientEvent(EV .. "over", src, {
                won = won, payout = total, waves = p.waves or 0, roundWins = p.roundWins or 0,
                rounds = Config.Rounds or 1, survivors = #winners, reason = why,
            })
        end
    end

    SetTimeout(1500, function()
        if r.bucketId and r.bucketId ~= 0 and GetResourceState("spz-core") == "started" then
            exports["spz-core"]:DeleteBucket(r.bucketId)
        end
    end)
    SetTimeout(4000, function()
        if Rooms[r.room.id] ~= r.room then return end
        -- Match over: the room closes and everyone is out of the lobby.
        Rooms[r.room.id] = nil
        for s in pairs(r.room.members) do
            RoomOf[s] = nil
            if GetPlayerName(s) then Player(s).state:set("mgRoom", nil, true) end
            notify(s, "Match over — you left the room. Open the hub to play again.")
        end
    end)

    pcall(function()
        local who = (#winners == 1) and winners[1].name or (#winners .. " winners")
        exports["spz-log"]:Log("minigame", "Color Rush", ("%s — %s (%s)"):format(who, why, r.room.name), "success")
    end)
    log(("room %d match over: %s"):format(r.room.id, why))
end

local function eachRound(fn)
    for _, room in pairs(Rooms) do
        if room.round and room.round.active then fn(room.round) end
    end
end

-- ── Layout ──────────────────────────────────────────────────────────────────
-- Colours are dealt round-robin over a SHUFFLED list of active tiles, so every
-- colour ends up with the same count +/-1. That matters: if one colour could
-- come up short there would be a wave where not everyone can physically fit.

local function buildLayout(ring, alive)
    local active = {}
    for iy = ring, Config.Grid - 1 - ring do
        for ix = ring, Config.Grid - 1 - ring do
            active[#active + 1] = Grid.index(ix, iy)
        end
    end

    -- Drop colours out of play if the shrinking grid can no longer give the
    -- called colour enough ROOM to hold everyone still alive. Capacity is by
    -- area, not tile count: one 13 m section holds a crowd, so counting tiles
    -- as one-player-each would strip colours out for no reason.
    local headroom = Config.TileHeadroom or 2
    local cap = Grid.tileCapacity()
    local colorCount = #Config.Colors
    while colorCount > 2 and (math.floor(#active / colorCount) * cap) < (alive + headroom) do
        colorCount = colorCount - 1
    end

    shuffle(active)

    local cells = {}
    for i = 1, Grid.total() do cells[i] = 0 end
    for n, idx in ipairs(active) do
        cells[idx] = ((n - 1) % colorCount) + 1
    end

    local buf = {}
    for i = 1, #cells do buf[i] = tostring(cells[i]) end
    return table.concat(buf), cells, colorCount, #active
end

-- Fall watcher: anyone whose car drops below the deck goes to spectate right
-- away. A live player who drives off the edge mid-wave is eliminated on the
-- spot instead of waiting for the wave to resolve. Eliminated players who
-- never fall (dev fallback) are moved after Config.FallWatchSec.
local FALL_DROP = 6.0   -- metres below the deck that count as fallen
CreateThread(function()
    while true do
        Wait(200)
        eachRound(function(r)
            if not (r.wave and r.wave > 0) then return end
            for src, p in pairs(r.players) do
                if not p.spectating and not p.left then
                    local ped = GetPlayerPed(src)
                    local fallen = false
                    if ped ~= 0 then
                        local veh = GetVehiclePedIsIn(ped) or 0
                        local ent = (veh ~= 0 and DoesEntityExist(veh)) and veh or ped
                        fallen = GetEntityCoords(ent).z < (Config.Center.z - FALL_DROP)
                    end
                    if p.alive and fallen then eliminate(r, src, "fell off") end
                    if not p.alive and (fallen or GetGameTimer() - (p.outAt or 0)
                            > math.floor((Config.FallWatchSec or 0.75) * 1000)) then
                        p.spectating = true
                        TriggerClientEvent(EV .. "spectate", src)
                    end
                end
            end
        end)
    end
end)

-- The ring (tiles peeled off each side) a wave is played on. ONE formula for
-- both building a wave and predicting the next one: the old predictor used
-- wave/N instead of (wave-1)/N and skipped the player cap, so it protected the
-- wrong band and an outer tile holding the called colour could vanish under
-- players at the next grid with no warning.
local function ringFor(wave, alive)
    -- Peel rings off the outside as the game goes on.
    local steps    = math.floor((wave - 1) / (Config.ShrinkEveryWaves or 2)) * (Config.ShrinkRings or 1)
    local maxSteps = math.floor((Config.Grid - (Config.MinGridSide or 6)) / 2)

    -- ...but never faster than the field thins. The shrink is on a wave clock
    -- while eliminations are not, so a crowded late game could otherwise reach
    -- a grid where the called colour physically cannot hold everyone alive —
    -- players would then be eliminated by geometry instead of reaction time.
    -- Worst case is two colours left, so the called colour gets half the deck,
    -- and each tile holds Grid.tileCapacity() players.
    local headroom = Config.TileHeadroom or 2
    local needTiles = (2 * (alive + headroom)) / Grid.tileCapacity()
    local needSide = math.ceil(math.sqrt(needTiles))
    local capSide  = math.max(Config.MinGridSide or 6, math.min(Config.Grid, needSide))
    local capRing  = math.floor((Config.Grid - capSide) / 2)

    return math.min(steps, math.max(0, maxSteps), math.max(0, capRing))
end

local function chooseTarget(cells, colorCount, ring, nextRing)
    local removed, retained = {}, {}
    for iy = ring, Config.Grid - 1 - ring do
        for ix = ring, Config.Grid - 1 - ring do
            local idx = Grid.index(ix, iy)
            if nextRing > ring and (ix < nextRing or ix >= Config.Grid - nextRing
                or iy < nextRing or iy >= Config.Grid - nextRing) then
                removed[#removed + 1] = idx
            else
                retained[#retained + 1] = idx
            end
        end
    end

    local removedColors = {}
    for _, idx in ipairs(removed) do removedColors[cells[idx]] = true end
    local candidates = {}
    for color = 1, colorCount do
        if not removedColors[color] then candidates[#candidates + 1] = color end
    end

    if #candidates > 0 then return candidates[math.random(#candidates)] end

    -- If the random layout used every colour in the shrinking band, move EVERY
    -- tile of the chosen colour out of the band (swap with a retained tile of
    -- another colour), so no tile that is about to vanish shows the call.
    local target = math.random(colorCount)
    local k = 1
    for _, removedIdx in ipairs(removed) do
        if cells[removedIdx] == target then
            while k <= #retained and cells[retained[k]] == target do k = k + 1 end
            if k > #retained then break end
            cells[removedIdx], cells[retained[k]] = cells[retained[k]], cells[removedIdx]
            k = k + 1
        end
    end
    return target
end

-- One wave: lay a fresh grid → call a colour → rush window → purge → breather.
local function runWave(r)
    r.wave = (r.wave or 0) + 1

    local alive = #aliveList(r)

    -- Never shrink past what the previous wave announced (r.nextRing): players
    -- were warned about exactly that band and the called colour avoided it.
    local ring = ringFor(r.wave, alive)
    if r.nextRing then ring = math.min(ring, r.nextRing) end
    ring = math.max(ring, r.ring or 0)
    local packed, cells, colorCount, activeTiles = buildLayout(ring, alive)
    r.cells = cells
    r.ring  = ring

    r.phase  = "build"
    r.endsAt = nil
    -- The band the NEXT wave will drop. Fewer players only ever allows a
    -- smaller grid, so predicting with today's count never under-shrinks.
    r.nextRing = math.max(ring, ringFor(r.wave + 1, alive))
    r.target = chooseTarget(cells, colorCount, ring, r.nextRing)
    local packedBuf = {}
    for i = 1, #cells do packedBuf[i] = tostring(cells[i]) end
    packed = table.concat(packedBuf)
    toAll(r, EV .. "layout", { packed = packed, ring = ring, wave = r.wave, colors = colorCount })
    Wait(1200)
    if not r.active then return end

    -- Call it.
    r.rushTime = math.max(Config.RushTimeMin or 3.5,
                          (Config.RushTimeSec or 9.0) - ((r.wave - 1) * (Config.RushTimeStep or 0.4)))
    r.phase    = "call"
    r.endsAt   = GetGameTimer() + math.floor(r.rushTime * 1000)
    toAll(r, EV .. "call", { target = r.target, seconds = r.rushTime, wave = r.wave,
                             ring = ring, doomRing = r.nextRing })
    log(("room %d wave %d: %s · %d tiles · %d colours · %.1fs · %d alive"):format(
        r.room.id, r.wave, Config.Colors[r.target].name, activeTiles, colorCount, r.rushTime, alive))

    -- Nobody is judged on the colour under them: server positions lag the real
    -- car and a car mid-jump is over whatever tile is below it, so that check
    -- eliminated people who made it. The only way out is FALLING - the wrong
    -- tiles vanish at the buzzer and the fall watcher catches whoever drops.
    while r.active and GetGameTimer() < r.endsAt do Wait(100) end
    if not r.active then return end

    -- Everything that is not the called colour goes away.
    r.phase = "purge"
    for i = 1, Grid.total() do
        if r.cells[i] ~= 0 and r.cells[i] ~= r.target then r.cells[i] = 0 end
    end
    toAll(r, EV .. "purge", { target = r.target })

    -- Spectate is sent per player by the fall watcher, the moment they drop
    -- off the deck.
    r.phase = "breather"
    Wait(math.floor((Config.BreatherSec or 4.0) * 1000))
    if not r.active then return end

    -- Still up after the breather = survived the wave (fallers are already out).
    for _, src in ipairs(aliveList(r)) do
        local p = r.players[src]
        p.waves = (p.waves or 0) + 1
    end
end

local function spawnSpots()
    local spots = {}
    for iy = 0, Config.Grid - 1 do
        for ix = 0, Config.Grid - 1 do spots[#spots + 1] = { ix, iy } end
    end
    shuffle(spots)
    return spots
end

-- Everyone back on a fresh, full-size grid for the next round of the match.
local function restartRound(r)
    r.carClass = nil   -- new round: draw a new car category
    r.wave, r.ring, r.nextRing, r.target, r.endsAt = 0, 0, nil, nil, nil
    r.phase = "build"

    local present = {}
    for src, p in pairs(r.players) do
        deleteCar(p)
        if not p.left then
            p.alive, p.spectating, p.outAt = true, false, nil
            present[#present + 1] = src
        end
    end

    local packed, cells = buildLayout(0, #present)
    r.cells = cells

    local spots = spawnSpots()
    for n, src in ipairs(present) do
        local p = r.players[src]
        local s = spots[n] or spots[((n - 1) % #spots) + 1]
        local tx, ty = Grid.tileCenter(s[1], s[2])
        p.spawn = vector3(tx, ty, Config.Center.z + 1.0)
        p.heading = (math.deg(math.atan(Config.Center.y - ty, Config.Center.x - tx)) - 90.0) % 360.0
        TriggerClientEvent(EV .. "respawn", src, {
            spawn = p.spawn, heading = p.heading, packed = packed,
            round = r.roundNo, rounds = Config.Rounds or 1,
        })
    end
    -- Spectators (left mid-match) still get the new grid to look at.
    toAll(r, EV .. "layout", { packed = packed, ring = 0, wave = 0 })

    Wait(2500)
    for n = 3, 1, -1 do
        if not r.active then return end
        toAll(r, EV .. "countdown", n)
        Wait(1000)
    end
end

local function roundThread(r)
    CreateThread(function()
        while r.active do
            runWave(r)
            if not r.active then return end

            local alive = aliveList(r)
            local capped = Config.MaxWaves and Config.MaxWaves > 0 and (r.wave or 0) >= Config.MaxWaves
            if #alive <= 1 or capped then
                -- Round over: survivors take the round.
                local names = {}
                for _, src in ipairs(alive) do
                    local p = r.players[src]
                    p.roundWins = (p.roundWins or 0) + 1
                    names[#names + 1] = p.name
                end
                local why = (#alive == 0 and "everyone fell") or (#alive == 1 and "last one standing") or "wave limit reached"

                -- Nobody left to play against: no point running more rounds.
                local present = 0
                for _, p in pairs(r.players) do if not p.left then present = present + 1 end end

                if (r.roundNo or 1) >= (Config.Rounds or 1) or present < 2 then
                    endRound(r, why)
                    return
                end

                local standings = {}
                for _, p in pairs(r.players) do
                    if not p.left then standings[#standings + 1] = { name = p.name, wins = p.roundWins or 0 } end
                end
                table.sort(standings, function(a, b) return a.wins > b.wins end)
                toAll(r, EV .. "roundOver", {
                    round = r.roundNo, rounds = Config.Rounds, winners = names, why = why, standings = standings,
                })
                Wait(5000)
                if not r.active then return end
                r.roundNo = (r.roundNo or 1) + 1
                restartRound(r)
            end
        end
    end)
end

-- ── HUD state broadcast ─────────────────────────────────────────────────────

CreateThread(function()
    while true do
        Wait(250)
        eachRound(function(r)
            local remain = r.endsAt and math.max(0, (r.endsAt - GetGameTimer()) / 1000) or 0
            local alive  = #aliveList(r)
            local total  = count(r.players)

            local rows = {}
            for src, p in pairs(r.players) do
                if not p.left then
                    local wins = p.roundWins or 0
                    rows[#rows + 1] = { src = src, name = p.name, out = not p.alive,
                        value = ("%d W"):format(wins), valueColor = wins > 0 and "ok" or "dim",
                        sub = ("%d wave%s survived"):format(p.waves or 0, (p.waves or 0) == 1 and "" or "s"),
                        _w = wins, _v = p.waves or 0 }
                end
            end
            table.sort(rows, function(a, b)
                if a._w ~= b._w then return a._w > b._w end
                if a.out ~= b.out then return not a.out end
                if a._v ~= b._v then return a._v > b._v end
                return a.name < b.name
            end)
            for _, row in ipairs(rows) do row._w, row._v = nil, nil end
            local board = { title = "Standings", rows = rows }

            for src, p in pairs(r.players) do
                TriggerClientEvent(EV .. "state", src, {
                    phase = r.phase, target = r.target, wave = r.wave,
                    round = r.roundNo, rounds = Config.Rounds,
                    remain = remain, alive = alive, total = total,
                    me = p.alive, board = board,
                })
            end
        end)
    end
end)

-- ── Rooms ───────────────────────────────────────────────────────────────────

local function roomMax(room) return room.max or Config.MaxPlayers end
local function disarm(room) room.armed, room.armedAt = false, nil end

local function startRound(room)
    disarm(room)
    if room.round then return end
    if count(room.members) < Config.MinPlayers then
        for s in pairs(room.members) do notify(s, "Not enough players to start.", "warning") end
        return
    end

    local roster = {}
    for src, e in pairs(room.members) do roster[#roster + 1] = { src = src, pid = e.pid, name = e.name } end

    local bucketId = 0
    if GetResourceState("spz-core") == "started" then
        bucketId = exports["spz-core"]:CreateBucket(("colorrush:%d"):format(room.id))
        SetRoutingBucketPopulationEnabled(bucketId, false)
    end

    local r = { room = room, active = true, bucketId = bucketId, players = {}, wave = 0,
                phase = "build", cells = {}, ring = 0, roundNo = 1 }
    for i = 1, Grid.total() do r.cells[i] = 0 end
    room.round = r

    for _, m in ipairs(roster) do
        r.players[m.src] = { pid = m.pid, name = m.name, alive = true, waves = 0 }
        -- Same as joining a race: the freeroam car goes (spz-vehicles).
        pcall(function()
            if GetResourceState("spz-vehicles") == "started" then exports["spz-vehicles"]:DespawnVehicle(m.src) end
        end)
        if bucketId ~= 0 then exports["spz-core"]:AssignPlayerToBucket(m.src, bucketId) end
    end

    -- Scatter spawns across the full grid on DISTINCT sections, so nobody
    -- starts with an advantage and no two cars spawn on the same spot.
    local spots = spawnSpots()

    -- Build the first layout NOW and ship it with the start event, so the
    -- platform exists before anyone's car is released onto it.
    local packed = nil
    pcall(function() packed = buildLayout(0, #roster) end)

    local n = 0
    for src, p in pairs(r.players) do
        n = n + 1
        local s = spots[n] or spots[((n - 1) % #spots) + 1]
        local tx, ty = Grid.tileCenter(s[1], s[2])
        local heading = (math.deg(math.atan(Config.Center.y - ty, Config.Center.x - tx)) - 90.0) % 360.0
        p.spawn, p.heading = vector3(tx, ty, Config.Center.z + 1.0), heading
        setContact(src, true)
        TriggerClientEvent(EV .. "start", src, {
            spawn = p.spawn, heading = heading,
            packed = type(packed) == "string" and packed or nil,
        })
    end

    log(("room %d round start: %d players"):format(room.id, #roster))

    -- 3-2-1 once everyone has faded in and has a car, then wave 1.
    CreateThread(function()
        Wait(2500)
        for c = 3, 1, -1 do
            if not r.active then return end
            toAll(r, EV .. "countdown", c)
            Wait(1000)
        end
        if r.active then roundThread(r) end
    end)
end

local function arm(room)
    if room.armed or room.round then return end
    room.armed, room.armedAt = true, GetGameTimer()
    local token = room.armedAt
    SetTimeout((Config.LobbyWaitSec or 45) * 1000, function()
        if Rooms[room.id] == room and room.armed and room.armedAt == token and not room.round then
            CreateThread(function() startRound(room) end)
        end
    end)
end

-- Busy elsewhere → hidden from invite lists. Queued racers still show: joining
-- a room takes them out of the race queue (see leaveRaceQueue).
local function invitable(sid)
    local st = Player(sid).state
    if st.mgRoom or st.inMinigame or st.inRace or st.inTimeTrial or st.inPursuit then return false end
    return true
end

-- Joining a minigame room drops your E-join race queue spot instead of refusing.
local function leaveRaceQueue(src)
    local st = Player(src).state
    if not (st.inQueue or st.pendingRace) or st.inRace then return end
    if GetResourceState("spz-races") ~= "started" then return end
    pcall(function() exports["spz-races"]:LeaveQueue(src) end)
end

local function busy(src)
    if RoomOf[src] then return "already in a room" end
    local st = Player(src).state
    -- One minigame room at a time, across every game.
    if st.mgRoom and st.mgRoom ~= GetCurrentResourceName() then return "already in another minigame room — leave it first" end
    if st.inRace then return "in a race" end
    if st.inTimeTrial then return "in a time trial" end
    return nil
end

local function addMember(room, src)
    local pid, prof = pidOf(src)
    if not pid then return false, "Profile not ready." end
    room.members[src] = { pid = pid, name = (prof and prof.username) or GetPlayerName(src) }
    RoomOf[src] = room
    if Invites[src] then Invites[src][room.id] = nil end
    local n = count(room.members)
    for s in pairs(room.members) do
        if s ~= src then notify(s, ("%s joined %s (%d/%d)"):format(room.members[src].name, room.name, n, roomMax(room)), "success") end
    end
    Player(src).state:set("mgRoom", GetCurrentResourceName(), true)
    leaveRaceQueue(src)
    -- No auto-start: only the room host starts the match.
    return true
end

local function removeMember(src, why)
    local room = RoomOf[src]
    if not room then return end
    local e = room.members[src]
    room.members[src] = nil
    RoomOf[src] = nil
    if GetPlayerName(src) then Player(src).state:set("mgRoom", nil, true) end
    if not next(room.members) then Rooms[room.id] = nil; return end
    if room.host == src then
        room.host = next(room.members)
        notify(room.host, "You are now the room host.", "info")
    end
    if count(room.members) < Config.MinPlayers then disarm(room) end
    for s in pairs(room.members) do
        notify(s, ("%s left the room%s."):format(e and e.name or "Someone", why and (" (" .. why .. ")") or ""), "warning")
    end
end

local function createRoom(src, opts)
    local b = busy(src)
    if b then return false, "You are " .. b .. "." end
    local maxRooms = Config.MaxRooms or 8
    if count(Rooms) >= maxRooms then return false, ("All %d rooms are in use."):format(maxRooms) end
    opts = type(opts) == "table" and opts or {}

    local name = tostring(opts.name or ""):gsub("[^%w%s%-_'!%.]", ""):sub(1, 24)
    if name:match("^%s*$") then name = nameOf(src) .. "'s room" end
    local max = math.floor(tonumber(opts.max) or Config.MaxPlayers)
    max = math.max(Config.MinPlayers, math.min(Config.MaxPlayers, max))

    local room = { id = nextRoomId, name = name, host = src, private = opts.private == true, max = max, members = {} }
    nextRoomId = nextRoomId + 1
    Rooms[room.id] = room
    local ok, err = addMember(room, src)
    if not ok then Rooms[room.id] = nil; return false, err end
    log(("room %d created by %s (%s, max %d%s)"):format(room.id, nameOf(src), name, max, room.private and ", private" or ""))
    return true, ("Created %s."):format(name)
end

local function joinRoom(src, id)
    local room = Rooms[tonumber(id) or -1]
    if not room then return false, "That room is gone." end
    if RoomOf[src] == room then return true end
    local b = busy(src)
    if b then return false, "You are " .. b .. "." end
    if room.round then return false, "That room is mid-round — wait for it to finish." end
    if room.private and not (Invites[src] and Invites[src][room.id]) then return false, "That room is invite-only." end
    if count(room.members) >= roomMax(room) then return false, "That room is full." end
    local ok, err = addMember(room, src)
    if not ok then return false, err end
    return true, ("Joined %s."):format(room.name)
end

-- Public matchmaking: the fullest open public room, else a new one.
local function quickJoin(src)
    local best
    for _, room in pairs(Rooms) do
        if not room.private and not room.round and count(room.members) < roomMax(room)
            and (not best or count(room.members) > count(best.members)) then
            best = room
        end
    end
    if best then return joinRoom(src, best.id) end
    return createRoom(src, {})
end

local function roomView(room, viewer)
    local roster = {}
    for s, e in pairs(room.members) do
        roster[#roster + 1] = { src = s, name = e.name, isMe = (s == viewer), host = (s == room.host) }
    end
    table.sort(roster, function(a, b)
        if a.host ~= b.host then return a.host end
        return a.name < b.name
    end)
    return {
        id = room.id, name = room.name, private = room.private, host = nameOf(room.host),
        count = #roster, max = roomMax(room), live = room.round ~= nil,
        wave = room.round and room.round.wave or nil,
        armed = room.armed,
        armedRemain = room.armed and math.max(0, (Config.LobbyWaitSec or 45) - math.floor((GetGameTimer() - room.armedAt) / 1000)) or nil,
        roster = roster,
    }
end

-- Shape kept compatible with the old single-lobby menu (inLobby/count/roster…),
-- plus the room list for the hub.
local function lobbyStateFor(src)
    local room = RoomOf[src]
    local rooms = {}
    for _, rm in pairs(Rooms) do
        local invited = Invites[src] and Invites[src][rm.id] or false
        if not rm.private or invited or rm == room then
            local v = roomView(rm, src)
            v.roster, v.invited, v.mine = nil, invited and true or false, rm == room
            rooms[#rooms + 1] = v
        end
    end
    table.sort(rooms, function(a, b)
        if a.mine ~= b.mine then return a.mine end
        if a.invited ~= b.invited then return a.invited end
        if a.live ~= b.live then return not a.live end
        return a.count > b.count
    end)

    local v = room and roomView(room, src)
    return {
        rooms = rooms, maxRooms = Config.MaxRooms or 8,
        room = v, isHost = room ~= nil and room.host == src,
        inRound = roundOf(src) ~= nil,
        roundLive = v and v.live or false,
        inLobby = room ~= nil,
        count = v and v.count or 0, min = Config.MinPlayers, max = v and v.max or Config.MaxPlayers,
        armed = v and v.armed or false, armedRemain = v and v.armedRemain or nil,
        roster = v and v.roster or {}, wave = v and v.wave or nil,
    }
end

local function reply(src, ok, msg)
    if msg then notify(src, msg, ok and "success" or "error") end
    return lobbyStateFor(src)
end

local function toggleJoin(src)
    if RoomOf[src] then
        if roundOf(src) then notify(src, "You are in a round.", "error"); return end
        removeMember(src, "left")
        notify(src, "Left the room.")
        return
    end
    local ok, msg = quickJoin(src)
    if msg then notify(src, msg, ok and "success" or "error") end
end

local function startNow(src)
    local room = RoomOf[src]
    if not room then return false, "Join a room first with /" .. Config.Command end
    if room.host ~= src then return false, "Only the room host can start." end
    if room.round then return false, "A round is already running." end
    if count(room.members) < Config.MinPlayers then return false, ("Need %d players."):format(Config.MinPlayers) end
    CreateThread(function() startRound(room) end)
    return true
end

-- ── Commands / callbacks ────────────────────────────────────────────────────

RegisterCommand(Config.Command, function(source) if source > 0 then toggleJoin(source) end end, false)

RegisterCommand(Config.StartCommand, function(source)
    if source <= 0 then return end
    local ok, msg = startNow(source)
    if not ok then notify(source, msg, "error") end
end, false)

lib.callback.register(EV .. "lobbyState", function(src) return lobbyStateFor(src) end)
lib.callback.register(EV .. "joinToggle", function(src) toggleJoin(src); return lobbyStateFor(src) end)
lib.callback.register(EV .. "createRoom", function(src, opts) return reply(src, createRoom(src, opts)) end)
lib.callback.register(EV .. "joinRoom", function(src, id) return reply(src, joinRoom(src, id)) end)
lib.callback.register(EV .. "leaveRoom", function(src)
    if roundOf(src) then return reply(src, false, "You are in a round.") end
    if not RoomOf[src] then return reply(src, false) end
    removeMember(src, "left")
    return reply(src, true, "Left the room.")
end)
lib.callback.register(EV .. "startRoom", function(src) return reply(src, startNow(src)) end)
lib.callback.register(EV .. "kick", function(src, target)
    local room = RoomOf[src]
    target = tonumber(target)
    if not room or room.host ~= src then return reply(src, false, "Only the host can do that.") end
    if room.round then return reply(src, false, "Not during a round.") end
    if not target or target == src or RoomOf[target] ~= room then return reply(src, false) end
    removeMember(target, "removed by host")
    notify(target, ("You were removed from %s."):format(room.name), "warning")
    return reply(src, true)
end)

-- Online players eligible to invite: not already in a room.
lib.callback.register(EV .. "online", function(src)
    local list = {}
    for _, pid in ipairs(GetPlayers()) do
        local sid = tonumber(pid)
        if sid ~= src and not RoomOf[sid] and invitable(sid) then
            list[#list + 1] = { source = sid, name = nameOf(sid) }
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end)

-- ── Invites ─────────────────────────────────────────────────────────────────

RegisterNetEvent(EV .. "invite", function(targetSrc)
    local src = source
    local room = RoomOf[src]
    targetSrc = tonumber(targetSrc)
    if not room then notify(src, "Join a room before inviting.", "error"); return end
    if not targetSrc or not GetPlayerName(targetSrc) then notify(src, "That player is not online.", "error"); return end
    if RoomOf[targetSrc] then notify(src, "They are already in a room.", "info"); return end
    if count(room.members) >= roomMax(room) then notify(src, "Room full.", "error"); return end

    Invites[targetSrc] = Invites[targetSrc] or {}
    Invites[targetSrc][room.id] = true
    Invites[targetSrc].last = room.id
    TriggerClientEvent(EV .. "invited", targetSrc, { fromSrc = src, fromName = room.members[src].name, room = room.id, roomName = room.name })
    notify(src, ("Invite sent to %s."):format(nameOf(targetSrc)), "success")
end)

RegisterNetEvent(EV .. "acceptInvite", function(roomId)
    local src = source
    if RoomOf[src] then return end
    local id = tonumber(roomId) or (Invites[src] and Invites[src].last)
    if not id then return end
    local ok, msg = joinRoom(src, id)
    if msg then notify(src, msg, ok and "success" or "error") end
end)

-- ── Round plumbing ──────────────────────────────────────────────────────────

-- Client is standing at its spawn with the platform built: NOW create its car.
-- Creating it here (player already nearby, in the bucket) means the player gets
-- ownership straight away and can drive it.
RegisterNetEvent(EV .. "ready", function()
    local src = source
    local r = roundOf(src)
    local p = r and r.players[src]
    if not p or p.veh or not p.spawn then return end
    local cls = roundClass(r)
    local veh, model = spawnCarFor(src, r.bucketId or 0, p.spawn.x, p.spawn.y, p.spawn.z, p.heading, cls.cars)
    if veh then tellClass(src, cls, model) end
    if not r.active then if veh then DeleteEntity(veh) end return end
    p.veh = veh
    TriggerClientEvent(EV .. "car", src, { netId = veh and NetworkGetNetworkIdFromEntity(veh) or nil })
end)

-- "Leave minigame" from the Esc / radial menu. Counts as eliminated; they are
-- taken out of the round entirely so the end-of-round payout skips them.
RegisterNetEvent(EV .. "leave", function()
    local src = source
    local r = roundOf(src)
    local p = r and r.players[src]
    if p then
        deleteCar(p)
        setContact(src, false)
        r.players[src] = nil
        TriggerClientEvent(EV .. "over", src, { won = false, waves = p.waves or 0, payout = 0 })
        SetTimeout(600, function()
            if GetPlayerName(src) and GetResourceState("spz-core") == "started" then
                exports["spz-core"]:RemovePlayerFromBucket(src)
            end
        end)
        toAll(r, EV .. "feed", { name = p.name, why = "left" })
    end
    removeMember(src, "left")
end)

AddEventHandler("playerDropped", function()
    local src = source
    -- Whatever they were sitting in goes too, even if it is not the car this
    -- game handed them (or that handle was already lost).
    local ped = GetPlayerPed(src)
    local seat = ped ~= 0 and GetVehiclePedIsIn(ped, false) or 0
    if seat ~= 0 and roundOf(src) then deleteCar({ veh = seat }) end
    local r = roundOf(src)
    if r then
        local p = r.players[src]
        p.alive, p.left = false, true
        deleteCar(p)
    end
    removeMember(src, "disconnected")
    Invites[src] = nil
end)

AddEventHandler("onResourceStop", function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, room in pairs(Rooms) do
        if room.round then endRound(room.round, "resource stopped") end
    end
end)
