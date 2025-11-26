-- services & modules
local CollectionService  = game:GetService("CollectionService") -- tagging stuff
local PathfindingService = game:GetService("PathfindingService") -- path calc
local UnitStats          = require(game.ReplicatedStorage.UnitStatsModule) -- unit data
local ProfileService     = require(script.ProfileService) -- saves
local DataRequest        = game.ReplicatedStorage.DataRequest -- remote for pulling data
local Alert              = game.ReplicatedStorage.Remotes.Alert -- alert popup

-- friend boost setup
local BOOST_PER_FRIEND = 10   -- 10% per friend
local BOOST_CAP        = 50   -- max 50, no getting silly

-- small helper for friend boost
local function computeFriendBoost(player)
    -- check mutuals in server
    local boost = 0

    -- super simple loop, not worth optimizing
    for _, other in ipairs(game.Players:GetPlayers()) do
        if other ~= player and player:IsFriendsWith(other.UserId) then
            boost += BOOST_PER_FRIEND -- add up
        end
    end

    return math.clamp(boost, 0, BOOST_CAP) -- clamp so it doesn't go wild
end

-- update one player’s boost stat
local function refreshBoostFor(player)
    -- quick ls lookup
    local ls = player:FindFirstChild("leaderstats")
    if ls then
        -- small sanity check
        local fb = ls:FindFirstChild("FriendBoost")
        if fb then
            fb.Value = computeFriendBoost(player) -- drop in new value
        end
    end
end

-- refresh everyone when roster changes
local function refreshAllBoosts()
    -- lazy loop since player count is small
    for _, plr in ipairs(game.Players:GetPlayers()) do
        refreshBoostFor(plr)
    end
end

-- handle data requests
DataRequest.OnServerInvoke = function(Player)
    -- wait for load (roblox loves being slow)
    if not ProfileService:IsLoaded(Player) then     
        local t0 = os.clock()
        repeat 
            task.wait(.5) -- tiny cooldown
        until ProfileService:IsLoaded(Player) or os.clock() - t0 >= 20 -- timeout safety
    end

    -- fallback, send whatever we get
    return ProfileService:GetPlayerProfile(Player) 
end

-- setup stats when a player spawns in
local function OnPlayerAdded(Player)
    -- wait until fully loaded
    repeat task.wait(.1) until ProfileService:IsLoaded(Player)

    ProfileService:Replicate(Player) -- push data to client
    local Data = ProfileService:GetPlayerProfile(Player)

    -- ls folder
    local leaderstats = Instance.new("Folder")
    leaderstats.Name = "leaderstats"
    leaderstats.Parent = Player

    -- cash
    local Cash = Instance.new("NumberValue")
    Cash.Name = "Cash"
    Cash.Value = Data.Cash
    Cash.Parent = leaderstats

    -- premium
    local Cash2 = Instance.new("NumberValue")
    Cash2.Name = "G$"
    Cash2.Value = Data.PremiumCurrency
    Cash2.Parent = leaderstats

    -- rebirths
    local Rebirths = Instance.new("NumberValue")
    Rebirths.Name = "Rebirth"
    Rebirths.Value = Data.Rebirth
    Rebirths.Parent = leaderstats

    -- steal stat
    local Steal = Instance.new("NumberValue")
    Steal.Name = "Steal"
    Steal.Value = Data.Steal
    Steal.Parent = leaderstats

    -- friend boost stat
    local friendBoost = Instance.new("IntValue")
    friendBoost.Name  = "FriendBoost"
    friendBoost.Value = computeFriendBoost(Player)
    friendBoost.Parent = leaderstats

    -- sync live values
    coroutine.wrap(function()
        -- runs forever basically, keep stats synced
        while true do
            task.wait() -- small delay so it’s not too spammy

            -- make sure player didn't disappear magically
            if Player then
                Cash.Value     = Data.Cash
                Cash2.Value    = Data.PremiumCurrency
                Rebirths.Value = Data.Rebirth
                Steal.Value    = Data.Steal
            end
        end
    end)()
end

-- init for current players
for _, p in ipairs(game.Players:GetPlayers()) do
    OnPlayerAdded(p)     -- setup
    refreshAllBoosts()   -- update boosts
end

game.Players.PlayerAdded:Connect(OnPlayerAdded)

game.Players.PlayerRemoving:Connect(function(Player)
    -- quick exit stamp
    local Data = ProfileService:GetPlayerProfile(Player)
    Data.LastExit = os.time()

    refreshAllBoosts() -- clean boost list
end)

-- belt refs
local SPAWN_INTERVAL = 3 -- spawn timing (slow enough)
local Belt      = workspace:WaitForChild("Belt")
local BeltStart = workspace:WaitForChild("BeltStart")
local BeltEnd   = workspace:WaitForChild("BeltEnd")

-- path tokens (cancel support)
local activePathTokens = {} -- used to stop old paths

-- rarity weights
local rarityWeights = {
    Common       = 60,
    Rare         = 25,
    Epic         = 8,
    Legendary    = 4,
    Mythic       = 1.5,
    Ascended     = 0.7,
    Divine       = 0.5,
    Celestial    = 0.3,
    Transcendent = 0.05,
}
-- really simple weighted system, nothing fancy

-- pity flags
local GuranteedSpawns = {
    Legendary = false,
    Mythic    = false,
    Ascended  = false
}

-- pity timers (s)
local SpawnThresholds = {
    Legendary = 1800, -- 30m
    Mythic    = 3600, -- 1h
    Ascended  = 7200  -- 2h
}

-- last pity times
local LastSpawned = {
    Legendary = os.clock(),
    Mythic    = os.clock(),
    Ascended  = os.clock()
}

-- roll rarity
local function getRandomRarity()
    local pool = {} -- temp pool
    -- cheap weight system, good enough
    for rarity, weight in pairs(rarityWeights) do
        for _ = 1, math.floor(weight * 10) do
            table.insert(pool, rarity)
        end
    end
    return pool[math.random(1, #pool)] -- pick random
end

-- pick hero from rarity, respect pity
local function getRandomHero()
    local rarity = getRandomRarity()

    -- pity overrides (simple but works)
    if GuranteedSpawns.Legendary then
        rarity = "Legendary"
        GuranteedSpawns.Legendary = false
    elseif GuranteedSpawns.Mythic then
        rarity = "Mythic"
        GuranteedSpawns.Mythic = false
    elseif GuranteedSpawns.Ascended then
        rarity = "Ascended"
        GuranteedSpawns.Ascended = false
    end

    local list = UnitStats[rarity]
    if not list then return end -- no list somehow

    -- convert dictionary → array
    local keys = {}
    for name in pairs(list) do
        table.insert(keys, name)
    end
    return keys[math.random(1, #keys)], rarity
end

-- move npc along path
local function moveWithPath(npc, destination)
    local hum  = npc:FindFirstChildOfClass("Humanoid")
    local root = npc:FindFirstChild("HumanoidRootPart")
    if not hum or not root then return end -- missing stuff

    local token = {} -- this path’s token
    activePathTokens[npc] = token -- store token

    -- create path (default settings mostly)
    local path = PathfindingService:CreatePath({
        AgentRadius  = 2,
        AgentHeight  = 5,
        AgentCanJump = false, -- no jumping on belt
    })
    path:ComputeAsync(root.Position, destination)

    -- try following the path
    if path.Status == Enum.PathStatus.Success then
        for _, wp in ipairs(path:GetWaypoints()) do
            -- stop if canceled
            if activePathTokens[npc] ~= token then return end

            hum:MoveTo(wp.Position)
            local ok = hum.MoveToFinished:Wait()
            if not ok then break end -- sometimes fails
        end
    else
        warn("path failed:", npc.Name) -- debug
    end
end

-- pity countdown
coroutine.wrap(function()
    while task.wait(1) do
        local now = os.clock()

        -- tiny loop, no need to optimize
        for rarity, threshold in pairs(SpawnThresholds) do
            -- countdown ui
            local counter = game.ReplicatedStorage:FindFirstChild("Guranteed"..rarity)
            if counter then
                counter.Value = SpawnThresholds[rarity] - (now - LastSpawned[rarity])
            end

            -- check if pity triggers
            if now - LastSpawned[rarity] >= threshold then
                print("guaranteed", rarity) -- debug spam
                LastSpawned[rarity] = now
                GuranteedSpawns[rarity] = true -- mark next spawn
            end
        end
    end
end)()

-- main spawn loop
local activeCount = 0 -- how many npcs alive rn
local MAX_ACTIVE_NPCS = 25 -- cap so belt doesn't clog

while true do
    -- simple throttle
    if activeCount >= MAX_ACTIVE_NPCS then
        task.wait(SPAWN_INTERVAL)
        continue
    end

    task.wait(SPAWN_INTERVAL)

    local name, rarity = getRandomHero()
    if not name then continue end -- bad roll

    local template = game.ReplicatedStorage.Units:FindFirstChild(name)
    if not template then
        print("missing:", name) -- missing template
        continue
    end

    coroutine.wrap(function()
        -- setup npc
        local hero = template:Clone()
        hero.Parent = Belt
        hero:SetPrimaryPartCFrame(BeltStart.CFrame + Vector3.new(0, 3, 0)) -- place above belt
        warn("spawned:", name, "|", rarity)

        hero:WaitForChild("HumanoidRootPart"):SetNetworkOwner(nil) -- server controls it

        local al = hero.Humanoid:LoadAnimation(script.WalkAnim)
        al:AdjustSpeed(1.5) -- walk speed
        al:Play()

        activeCount += 1

        -- gui labels
        local frame = hero.BillboardGui.Frame
        frame.RarityText.Text = rarity
        frame.Cost.Text       = "$"..UnitStats[rarity][name].Cost
        frame.UnitName.Text   = name
        frame.Tick.Text       = "$"..UnitStats[rarity][name].CashReward.."/s"   

        -- rarity colors (quick n dirty)
        local colors = {
            Common       = Color3.fromRGB(179, 179, 179),
            Rare         = Color3.fromRGB(0, 200, 255),
            Epic         = Color3.fromRGB(183, 0, 255),
            Legendary    = Color3.fromRGB(231, 204, 0),
            Mythic       = Color3.fromRGB(231, 0, 4),
            Ascended     = Color3.fromRGB(64, 64, 231),
            Divine       = Color3.fromRGB(255, 247, 0),
            Celestial    = Color3.fromRGB(0, 255, 204),
            Transcendent = Color3.fromRGB(173, 0, 3),
        }
        if colors[rarity] then
            frame.RarityText.TextColor3 = colors[rarity] -- set color
        end

        -- no collides
        for _, part in pairs(hero:GetChildren()) do
            if part:IsA("BasePart") then
                game.PhysicsService:SetPartCollisionGroup(part, "NPCS") -- drop in npc group
            end
        end

        -- buy prompt
        local prompt = hero:FindFirstChildWhichIsA("ProximityPrompt", true)
        if prompt then
            prompt.Triggered:Connect(function(player)
                local data = ProfileService:GetPlayerProfile(player)
                local cost = UnitStats[rarity][name].Cost or 100

                -- basic cash check
                if data and data.Cash >= cost then

                    -- already owned? ping prev owner
                    if hero:GetAttribute("Purchased") then
                        local oldBuyer = hero:GetAttribute("Purchased")
                        local oldPlr = game.Players:FindFirstChild(oldBuyer)

                        -- notify if they still exist
                        if oldPlr then
                            Alert:FireClient(oldPlr, {
                                Text = player.Name.." stole your hero!",
                                Color = Color3.fromRGB(255, 0, 4)
                            })
                        else
                            return
                        end
                    end

                    data.Cash -= cost
                    hero:SetAttribute("Purchased", player.Name) -- mark as bought

                    -- redirect + clean up
                    moveWithPath(hero, workspace.SpawnLocation.Position)

                    if hero and hero.Parent and hero:GetAttribute("Purchased") == player.Name then
                        al:Stop()
                        hero:Destroy()
                        activeCount -= 1 -- free slot
                    end
                end
            end)
        end

        -- if never bought, just walk out
        task.spawn(function()
            moveWithPath(hero, BeltEnd.Position)
            if hero and hero.Parent and not hero:GetAttribute("Purchased") then
                al:Stop()
                hero:Destroy()
                activeCount -= 1 -- cleaned
            end
        end)
    end)()
end
