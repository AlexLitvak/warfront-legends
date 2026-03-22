--!strict
--[[
	WeaponManager (Server)
	Manages visual weapon Tools: clones the correct Tool from ServerStorage
	into the player's Backpack and auto-equips it so the character holds the
	weapon model. Listens for weapon swaps (EquipWeapon event) and respawns
	(CharacterAdded) to keep the visual in sync with the data layer.

	Tool naming convention: {WeaponName}_level{Tier}
	  e.g. Sword_level1, Axe_level2, Bow_level1

	Attack input is NOT handled here — CombatClient → CombatHandler via
	RemoteEvents handles all combat. The Tool is purely visual.
]]

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")

------------------------------------------------------------------------
-- Weapon prefab folder
------------------------------------------------------------------------

local weaponsFolder = ServerStorage:FindFirstChild("Weapons")
if not weaponsFolder then
	warn("[WeaponManager] ServerStorage/Weapons/ folder not found — weapon visuals disabled")
end

------------------------------------------------------------------------
-- Server-side BindableEvents (shared with ShopHandler / CombatHandler)
------------------------------------------------------------------------

local serverEvents = ServerScriptService:FindFirstChild("ServerEvents") :: Folder
if not serverEvents then
	local folder = Instance.new("Folder")
	folder.Name = "ServerEvents"
	folder.Parent = ServerScriptService
	serverEvents = folder
end

local equipWeaponEvent = serverEvents:FindFirstChild("EquipWeapon") :: BindableEvent
if not equipWeaponEvent then
	local event = Instance.new("BindableEvent")
	event.Name = "EquipWeapon"
	event.Parent = serverEvents
	equipWeaponEvent = event
end

local getWeaponTierFunc = serverEvents:FindFirstChild("GetWeaponTier") :: BindableFunction
if not getWeaponTierFunc then
	local func = Instance.new("BindableFunction")
	func.Name = "GetWeaponTier"
	func.Parent = serverEvents
	getWeaponTierFunc = func
end

------------------------------------------------------------------------
-- Per-player state
------------------------------------------------------------------------

local equippedWeapons: { [Player]: string } = {}

------------------------------------------------------------------------
-- Core: grant a weapon Tool to a player
------------------------------------------------------------------------

local function grantWeapon(player: Player, weaponName: string, tier: number)
	if not weaponsFolder then
		return
	end

	local toolName = weaponName .. "_level" .. tostring(tier)
	local prefab = weaponsFolder:FindFirstChild(toolName)
	if not prefab then
		warn(string.format("[WeaponManager] Prefab '%s' not found in ServerStorage/Weapons — skipping visual", toolName))
		return
	end

	-- Remove any existing weapon Tools from Backpack and Character
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, child in backpack:GetChildren() do
			if child:IsA("Tool") then
				child:Destroy()
			end
		end
	end

	local character = player.Character
	if character then
		for _, child in character:GetChildren() do
			if child:IsA("Tool") then
				child:Destroy()
			end
		end
	end

	-- Clone and configure the new Tool
	local tool = prefab:Clone()
	tool.CanBeDropped = false

	-- Strip any embedded scripts — the Tool is purely visual.
	-- Attack logic is handled by CombatClient → CombatHandler via RemoteEvents.
	for _, descendant in tool:GetDescendants() do
		if descendant:IsA("BaseScript") then
			descendant:Destroy()
		end
	end

	-- Parent to Backpack
	if not backpack then
		warn(string.format("[WeaponManager] %s has no Backpack — cannot grant weapon", player.Name))
		return
	end
	tool.Parent = backpack

	-- Auto-equip so the character holds it immediately
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid:EquipTool(tool)
		end
	end
end

------------------------------------------------------------------------
-- Player lifecycle
------------------------------------------------------------------------

local function onCharacterAdded(player: Player, character: Model)
	-- Wait for Humanoid to be ready before equipping
	local humanoid = character:WaitForChild("Humanoid", 5)
	if not humanoid then
		warn(string.format("[WeaponManager] %s character has no Humanoid", player.Name))
		return
	end

	local weaponName = equippedWeapons[player] or "Sword"

	-- Query the tier from ShopHandler
	local tier: number = 1
	local ok, result = pcall(function()
		return getWeaponTierFunc:Invoke(player, weaponName)
	end)
	if ok and typeof(result) == "number" then
		tier = result
	end

	grantWeapon(player, weaponName, tier)
end

local function onPlayerAdded(player: Player)
	equippedWeapons[player] = "Sword"

	player.CharacterAdded:Connect(function(character: Model)
		onCharacterAdded(player, character)
	end)

	-- Handle case where character already exists
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end
end

local function onPlayerRemoving(player: Player)
	equippedWeapons[player] = nil
end

------------------------------------------------------------------------
-- Listen for weapon equip changes from ShopHandler
------------------------------------------------------------------------

equipWeaponEvent.Event:Connect(function(player: Player, weaponName: string)
	equippedWeapons[player] = weaponName

	-- If the player has a character, swap the Tool immediately
	local character = player.Character
	if not character then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local tier: number = 1
	local ok, result = pcall(function()
		return getWeaponTierFunc:Invoke(player, weaponName)
	end)
	if ok and typeof(result) == "number" then
		tier = result
	end

	grantWeapon(player, weaponName, tier)
end)

------------------------------------------------------------------------
-- Init
------------------------------------------------------------------------

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[WeaponManager] Initialized")
