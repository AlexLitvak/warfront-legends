--!strict
--[[
	ArenaManager (Server Script)
	Orchestrates the full arena lifecycle during a match. Other server scripts
	(primarily GameManager) control it via BindableFunctions and BindableEvents
	in the ServerEvents folder.

	Exported API (in ServerEvents):

	BindableFunctions (return values):
	  SelectArena(mode: string) → string
	      "random" picks a random arena; a specific name uses that arena.
	  SetupArena(arenaType: string) → Folder?
	      Generates the arena and returns the arena folder.

	BindableEvents (fire-and-forget):
	  SpawnMatchPlayers  — fire with (players: {Player}, arenaFolder: Folder)
	  StartArenaHazards  — fire with (arenaType: string)
	  CleanupArena       — fire with no args

	Intended call sequence from GameManager:
	  Pre-match:
	    1. local arenaType = SelectArena:Invoke("random")
	    2. local arenaFolder = SetupArena:Invoke(arenaType)
	    3. SpawnMatchPlayers:Fire(matchPlayers, arenaFolder)
	    4. (5-second countdown displayed to players)
	  Match start:
	    5. StartArenaHazards:Fire(arenaType)
	    6. GameManager enables combat
	  Match end:
	    7. GameManager disables combat
	    8. (10-second results screen)
	    9. CleanupArena:Fire()
	    10. Players returned to menu state
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ArenaConfig = require(ReplicatedStorage:WaitForChild("ArenaConfig"))
local ArenaGenerator = require(ServerScriptService:WaitForChild("ArenaGenerator"))
local GameConfig = require(ReplicatedStorage:WaitForChild("GameConfig"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

------------------------------------------------------------------------
-- ServerEvents
------------------------------------------------------------------------

local serverEvents = ServerScriptService:FindFirstChild("ServerEvents")
if not serverEvents then
	serverEvents = Instance.new("Folder")
	serverEvents.Name = "ServerEvents"
	serverEvents.Parent = ServerScriptService
end

local function getOrCreateBindable(className: string, name: string): Instance
	local existing = serverEvents:FindFirstChild(name)
	if existing then
		return existing
	end
	local inst = Instance.new(className)
	inst.Name = name
	inst.Parent = serverEvents
	return inst
end

-- ArenaManager API
local SelectArenaFunc = getOrCreateBindable("BindableFunction", "SelectArena") :: BindableFunction
local SetupArenaFunc = getOrCreateBindable("BindableFunction", "SetupArena") :: BindableFunction
local SpawnMatchPlayersEvent = getOrCreateBindable("BindableEvent", "SpawnMatchPlayers") :: BindableEvent
local StartArenaHazardsEvent = getOrCreateBindable("BindableEvent", "StartArenaHazards") :: BindableEvent
local CleanupArenaEvent = getOrCreateBindable("BindableEvent", "CleanupArena") :: BindableEvent

-- ArenaHazards control (created by ArenaHazards.server.luau)
local StartHazardsEvent = getOrCreateBindable("BindableEvent", "StartHazards") :: BindableEvent
local StopHazardsEvent = getOrCreateBindable("BindableEvent", "StopHazards") :: BindableEvent

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------

local currentArenaFolder: Folder? = nil
local currentArenaType: string = ""

------------------------------------------------------------------------
-- 1. ARENA SELECTION
-- Picks an arena type. Supports "random" or a specific arena name.
-- Returns the selected arena type string.
------------------------------------------------------------------------

SelectArenaFunc.OnInvoke = function(mode: string): string
	if mode == "random" then
		local arena = ArenaConfig.GetRandomArena()
		currentArenaType = arena.name
		print("[ArenaManager] Selected arena (random): " .. arena.displayName)
		return arena.name
	end

	-- Check if the mode string is a valid arena name
	local arena = ArenaConfig.GetArena(mode)
	if arena then
		currentArenaType = arena.name
		print("[ArenaManager] Selected arena: " .. arena.displayName)
		return arena.name
	end

	-- Unknown name — fall back to random
	warn("[ArenaManager] Unknown arena '" .. mode .. "', falling back to random")
	local fallback = ArenaConfig.GetRandomArena()
	currentArenaType = fallback.name
	return fallback.name
end

------------------------------------------------------------------------
-- 2. ARENA GENERATION
-- Calls ArenaGenerator.generate() with a fresh seed, notifies all
-- clients via Remotes.ArenaGenerated, returns the arena folder.
------------------------------------------------------------------------

SetupArenaFunc.OnInvoke = function(arenaType: string): Folder?
	print("[ArenaManager] Setting up arena: " .. arenaType)

	-- ArenaGenerator.generate handles cleanup of any previous arena
	local result = ArenaGenerator.generate(arenaType)

	currentArenaFolder = result.arenaFolder
	currentArenaType = result.arenaName

	-- Notify all clients (UI, music, arena-specific HUD elements)
	Remotes.ArenaGenerated:FireAllClients({
		arenaType = result.arenaName,
		seed = result.seed,
		spawnCount = #result.spawnPoints,
	})

	print(
		"[ArenaManager] Arena ready: "
			.. result.arenaName
			.. " (seed="
			.. result.seed
			.. ", "
			.. #result.spawnPoints
			.. " spawns)"
	)

	return result.arenaFolder
end

------------------------------------------------------------------------
-- 3. HAZARD ACTIVATION
-- Waits a 5-second grace period after match start, then fires
-- StartHazards to ArenaHazards.server.luau.
------------------------------------------------------------------------

StartArenaHazardsEvent.Event:Connect(function(arenaType: string)
	print("[ArenaManager] Hazard grace period (5s) for: " .. arenaType)
	task.wait(5)

	-- Verify match hasn't been cleaned up during the grace period
	if currentArenaType == "" or currentArenaFolder == nil then
		print("[ArenaManager] Arena was cleaned up during grace period — skipping hazards")
		return
	end

	StartHazardsEvent:Fire(arenaType)
	print("[ArenaManager] Hazards activated for: " .. arenaType)
end)

------------------------------------------------------------------------
-- 4. PLAYER SPAWNING
-- Collects SpawnLocations from the arena folder, assigns one per player
-- (distributed evenly, no duplicates unless more players than spawns),
-- teleports characters, and applies spawn protection.
------------------------------------------------------------------------

SpawnMatchPlayersEvent.Event:Connect(function(players: { Player }, arenaFolder: Folder)
	-- Collect all SpawnLocations in the arena
	local spawnLocations: { SpawnLocation } = {}
	for _, descendant in arenaFolder:GetDescendants() do
		if descendant:IsA("SpawnLocation") then
			table.insert(spawnLocations, descendant)
		end
	end

	if #spawnLocations == 0 then
		warn("[ArenaManager] No SpawnLocations found in arena folder!")
		return
	end

	-- Assign each player a unique spawn (wrap if more players than spawns)
	for i, player in players do
		local spawnIndex = ((i - 1) % #spawnLocations) + 1
		local spawn = spawnLocations[spawnIndex]

		-- Ensure the player has a loaded character
		if not player.Character or not player.Character:FindFirstChild("HumanoidRootPart") then
			player:LoadCharacter()
			if not player.Character then
				player.CharacterAdded:Wait()
			end
			-- Wait for HumanoidRootPart to exist
			local character = player.Character
			if character and not character:FindFirstChild("HumanoidRootPart") then
				character:WaitForChild("HumanoidRootPart", 5)
			end
		end

		local character = player.Character
		if not character then
			warn("[ArenaManager] Could not load character for " .. player.Name)
			continue
		end

		-- Teleport to assigned spawn (3 studs above spawn surface)
		local spawnCFrame = spawn.CFrame + Vector3.new(0, 3, 0)
		character:PivotTo(spawnCFrame)

		-- Apply spawn protection via ForceField
		-- ForceField makes Humanoid:TakeDamage() deal zero damage
		local forceField = Instance.new("ForceField")
		forceField.Name = "SpawnProtection"
		forceField.Parent = character

		task.delay(GameConfig.SPAWN_PROTECTION, function()
			if forceField.Parent then
				forceField:Destroy()
			end
		end)
	end

	print(
		"[ArenaManager] Spawned "
			.. #players
			.. " players across "
			.. #spawnLocations
			.. " spawn points"
	)
end)

------------------------------------------------------------------------
-- 5. ARENA CLEANUP
-- Stops all hazards, removes the arena from Workspace, resets lighting.
------------------------------------------------------------------------

CleanupArenaEvent.Event:Connect(function()
	print("[ArenaManager] Cleaning up arena")

	-- Stop all active hazards
	StopHazardsEvent:Fire()

	-- Remove arena and reset lighting
	ArenaGenerator.clearArena()

	currentArenaFolder = nil
	currentArenaType = ""

	print("[ArenaManager] Cleanup complete")
end)

------------------------------------------------------------------------
-- Init
------------------------------------------------------------------------

print("[ArenaManager] Loaded — awaiting match events")
