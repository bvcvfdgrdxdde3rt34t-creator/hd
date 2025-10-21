-- services & modules
local CollectionService  = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local UnitStats          = require(game.ReplicatedStorage.UnitStatsModule)
local ProfileService     = require(script.ProfileService)
local DataRequest        = game.ReplicatedStorage.DataRequest
local Alert              = game.ReplicatedStorage.Remotes.Alert
 
-- friend boost setup
local BOOST_PER_FRIEND = 10   -- 10%
local BOOST_CAP        = 50   -- max 50%
 
local function computeFriendBoost(player)
    -- check mutuals in server
    local boost = 0
    for _, other in ipairs(game.Players:GetPlayers()) do
        if other ~= player and player:IsFriendsWith(other.UserId) then
            boost += BOOST_PER_FRIEND
        end
    end
    return math.clamp(boost, 0, BOOST_CAP)
end
 
-- update one player’s boost stat
local function refreshBoostFor(player)
    local ls = player:FindFirstChild("leaderstats")
    if ls then
        local fb = ls:FindFirstChild("FriendBoost")
        if fb then
            fb.Value = computeFriendBoost(player)
        end
    end
end
 
-- refresh everyone when roster changes
local function refreshAllBoosts()
    for _, plr in ipairs(game.Players:GetPlayers()) do
        refreshBoostFor(plr)
    end
end
 
-- handle data requests
DataRequest.OnServerInvoke = function(Player)
    if not ProfileService:IsLoaded(Player) then     
        local t0 = os.clock()
        repeat task.wait(.5) until ProfileService:IsLoaded(Player) or os.clock() - t0 >= 20
    end
    return ProfileService:GetPlayerProfile(Player)
end
 
-- setup stats when a player spawns in
local function OnPlayerAdded(Player)
    repeat task.wait(.1) until ProfileService:IsLoaded(Player) 
    ProfileService:Replicate(Player)
    local Data = ProfileService:GetPlayerProfile(Player)
 
    local leaderstats = Instance.new("Folder")
    leaderstats.Name = "leaderstats"
    leaderstats.Parent = Player
 
    local Cash = Instance.new("NumberValue")
    Cash.Name = "Cash"
    Cash.Value = Data.Cash
    Cash.Parent = leaderstats
 
    local Cash2 = Instance.new("NumberValue")
    Cash2.Name = "G$"
    Cash2.Value = Data.PremiumCurrency
    Cash2.Parent = leaderstats
 
    local Rebirths = Instance.new("NumberValue")
    Rebirths.Name = "Rebirth"
    Rebirths.Value = Data.Rebirth
    Rebirths.Parent = leaderstats
 
    local Steal = Instance.new("NumberValue")
    Steal.Name = "Steal"
    Steal.Value = Data.Steal
    Steal.Parent = leaderstats
 
    local friendBoost = Instance.new("IntValue")
    friendBoost.Name  = "FriendBoost"
    friendBoost.Value = computeFriendBoost(Player)
    friendBoost.Parent = leaderstats
 
    -- sync live values
    coroutine.wrap(function()
        while true do
            task.wait()
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
    OnPlayerAdded(p)
    refreshAllBoosts()
end
 
game.Players.PlayerAdded:Connect(OnPlayerAdded)
game.Players.PlayerRemoving:Connect(function(Player)
    local Data = ProfileService:GetPlayerProfile(Player)
    Data.LastExit = os.time()
    refreshAllBoosts()
end)
 
-- belt refs
local SPAWN_INTERVAL = 3
local Belt      = workspace:WaitForChild("Belt")
local BeltStart = workspace:WaitForChild("BeltStart")
local BeltEnd   = workspace:WaitForChild("BeltEnd")
 
-- path tokens (cancel support)
local activePathTokens = {}
 
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
    local pool = {}
    for rarity, weight in pairs(rarityWeights) do
        for _ = 1, math.floor(weight * 10) do
            table.insert(pool, rarity)
        end
    end
    return pool[math.random(1, #pool)]
end
 
-- pick hero from rarity, respect pity
local function getRandomHero()
    local rarity = getRandomRarity()
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
    if not list then return end
 
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
    if not hum or not root then return end
 
    local token = {}
    activePathTokens[npc] = token
 
    local path = PathfindingService:CreatePath({
        AgentRadius  = 2,
        AgentHeight  = 5,
        AgentCanJump = false,
    })
    path:ComputeAsync(root.Position, destination)
 
    if path.Status == Enum.PathStatus.Success then
        for _, wp in ipairs(path:GetWaypoints()) do
            if activePathTokens[npc] ~= token then return end
            hum:MoveTo(wp.Position)
            local ok = hum.MoveToFinished:Wait()
            if not ok then break end
        end
    else
        warn("path failed:", npc.Name)
    end
end
 
-- pity countdown
coroutine.wrap(function()
    while task.wait(1) do
        local now = os.clock()
        for rarity, threshold in pairs(SpawnThresholds) do
            local counter = game.ReplicatedStorage:FindFirstChild("Guranteed"..rarity)
            if counter then
                counter.Value = SpawnThresholds[rarity] - (now - LastSpawned[rarity])
            end
            if now - LastSpawned[rarity] >= threshold then
                print("guaranteed", rarity)
                LastSpawned[rarity] = now
                GuranteedSpawns[rarity] = true
            end
        end
    end
end)()
 
-- main spawn loop
local activeCount = 0
local MAX_ACTIVE_NPCS = 25
 
while true do
    if activeCount >= MAX_ACTIVE_NPCS then
        task.wait(SPAWN_INTERVAL)
        continue
    end
 
    task.wait(SPAWN_INTERVAL)
 
    local name, rarity = getRandomHero()
    if not name then continue end
 
    local template = game.ReplicatedStorage.Units:FindFirstChild(name)
    if not template then
        print("missing:", name)
        continue
    end
 
    coroutine.wrap(function()
        local hero = template:Clone()
        hero.Parent = Belt
        hero:SetPrimaryPartCFrame(BeltStart.CFrame + Vector3.new(0, 3, 0))
        warn("spawned:", name, "|", rarity)
        hero:WaitForChild("HumanoidRootPart"):SetNetworkOwner(nil)
 
        local al = hero.Humanoid:LoadAnimation(script.WalkAnim)
        al:AdjustSpeed(1.5)
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
            frame.RarityText.TextColor3 = colors[rarity]
        end
 
        -- no collides
        for _, part in pairs(hero:GetChildren()) do
            if part:IsA("BasePart") then
                game.PhysicsService:SetPartCollisionGroup(part, "NPCS")
            end
        end
 
        -- buy prompt
        local prompt = hero:FindFirstChildWhichIsA("ProximityPrompt", true)
        if prompt then
            prompt.Triggered:Connect(function(player)
                local data = ProfileService:GetPlayerProfile(player)
                local cost = UnitStats[rarity][name].Cost or 100
                if data and data.Cash >= cost then
                    -- already owned? ping prev owner
                    if hero:GetAttribute("Purchased") then
                        local oldBuyer = hero:GetAttribute("Purchased")
                        local oldPlr = game.Players:FindFirstChild(oldBuyer)
                        if oldPlr then
                            Alert:FireClient(oldPlr, {Text = player.Name.." stole your hero!", Color = Color3.fromRGB(255, 0, 4)})
                        else
                            return
                        end
                    end
 
                    data.Cash -= cost
                    hero:SetAttribute("Purchased", player.Name)
 
                    -- redirect + clean up
                    moveWithPath(hero, workspace.SpawnLocation.Position)
                    if hero and hero.Parent and hero:GetAttribute("Purchased") == player.Name then
                        al:Stop()
                        hero:Destroy()
                        activeCount -= 1
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
                activeCount -= 1
            end
        end)
    end)()
end