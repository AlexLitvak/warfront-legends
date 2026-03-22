--!strict
--[[
	ShopHandler (Server)
	Server-authoritative purchase validation and inventory persistence.
	Handles buying weapons, upgrades, skins, and emotes. Provides
	BindableEvent/Function for CombatHandler to query equipped weapon
	and upgrade tiers.
]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
local ShopConfig = require(ReplicatedStorage:WaitForChild("ShopConfig"))

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

local DATASTORE_NAME = "PlayerShopData_v1"
local AUTOSAVE_INTERVAL = 60
local DATASTORE_RETRIES = 3

------------------------------------------------------------------------
-- DataStore (may fail in unpublished places)
------------------------------------------------------------------------

local shopStore = nil
local datastoreAvailable = false
do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(DATASTORE_NAME)
	end)
	if ok then
		shopStore = result
		datastoreAvailable = true
	else
		warn("[ShopHandler] DataStore unavailable (place not published?): " .. tostring(result))
	end
end

------------------------------------------------------------------------
-- Server-side BindableEvents (shared folder with CombatHandler, CoinManager)
------------------------------------------------------------------------

local serverEvents = ServerScriptService:FindFirstChild("ServerEvents") :: Folder
if not serverEvents then
	local folder = Instance.new("Folder")
	folder.Name = "ServerEvents"
	folder.Parent = ServerScriptService
	serverEvents = folder
end

-- CoinManager integration
local addPlayerCoins = serverEvents:FindFirstChild("AddPlayerCoins") :: BindableEvent
if not addPlayerCoins then
	local event = Instance.new("BindableEvent")
	event.Name = "AddPlayerCoins"
	event.Parent = serverEvents
	addPlayerCoins = event
end

local getPlayerCoins = serverEvents:FindFirstChild("GetPlayerCoins") :: BindableFunction
if not getPlayerCoins then
	local func = Instance.new("BindableFunction")
	func.Name = "GetPlayerCoins"
	func.Parent = serverEvents
	getPlayerCoins = func
end

-- EquipWeapon: fires to CombatHandler when player equips a different weapon
local equipWeaponEvent = serverEvents:FindFirstChild("EquipWeapon") :: BindableEvent
if not equipWeaponEvent then
	local event = Instance.new("BindableEvent")
	event.Name = "EquipWeapon"
	event.Parent = serverEvents
	equipWeaponEvent = event
end

-- GetWeaponTier: CombatHandler invokes to get a player's upgrade tier
local getWeaponTierFunc = serverEvents:FindFirstChild("GetWeaponTier") :: BindableFunction
if not getWeaponTierFunc then
	local func = Instance.new("BindableFunction")
	func.Name = "GetWeaponTier"
	func.Parent = serverEvents
	getWeaponTierFunc = func
end

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

type PlayerInventory = {
	ownedWeapons: { [string]: boolean },
	weaponTiers: { [string]: number },
	ownedSkins: { [string]: boolean },
	ownedEmotes: { [string]: boolean },
	equippedWeapon: string,
	equippedSkins: { [string]: string },  -- weaponName -> skinId
	equippedEmote: string,
}

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------

local inventories: { [Player]: PlayerInventory } = {}
local pendingSave: { [Player]: boolean } = {}

------------------------------------------------------------------------
-- Default inventory
------------------------------------------------------------------------

local function createDefaultInventory(): PlayerInventory
	return {
		ownedWeapons = { Sword = true },
		weaponTiers = { Sword = 1 },
		ownedSkins = {},
		ownedEmotes = {},
		equippedWeapon = "Sword",
		equippedSkins = {},
		equippedEmote = "",
	}
end

------------------------------------------------------------------------
-- DataStore helpers
------------------------------------------------------------------------

local function datastoreKey(player: Player): string
	return "Player_" .. tostring(player.UserId)
end

local function loadInventory(player: Player): PlayerInventory
	if not datastoreAvailable then
		return createDefaultInventory()
	end
	local key = datastoreKey(player)
	for attempt = 1, DATASTORE_RETRIES do
		local success, result = pcall(function()
			return shopStore:GetAsync(key)
		end)
		if success then
			if result and typeof(result) == "table" then
				-- Merge with defaults to handle schema migrations
				local inv = createDefaultInventory()
				local data = result :: { [string]: any }
				if data.ownedWeapons then inv.ownedWeapons = data.ownedWeapons end
				if data.weaponTiers then inv.weaponTiers = data.weaponTiers end
				if data.ownedSkins then inv.ownedSkins = data.ownedSkins end
				if data.ownedEmotes then inv.ownedEmotes = data.ownedEmotes end
				if data.equippedWeapon then inv.equippedWeapon = data.equippedWeapon end
				if data.equippedSkins then inv.equippedSkins = data.equippedSkins end
				if data.equippedEmote then inv.equippedEmote = data.equippedEmote end
				-- Ensure Sword is always owned
				inv.ownedWeapons.Sword = true
				if not inv.weaponTiers.Sword then
					inv.weaponTiers.Sword = 1
				end
				return inv
			end
			return createDefaultInventory()
		end
		warn(string.format("[ShopHandler] Load failed for %s (attempt %d): %s", player.Name, attempt, tostring(result)))
		if attempt < DATASTORE_RETRIES then
			task.wait(1)
		end
	end
	warn(string.format("[ShopHandler] All load attempts failed for %s, using defaults", player.Name))
	return createDefaultInventory()
end

local function saveInventory(player: Player)
	if not datastoreAvailable then
		return
	end
	local inv = inventories[player]
	if not inv then
		return
	end

	local key = datastoreKey(player)
	for attempt = 1, DATASTORE_RETRIES do
		local success, err = pcall(function()
			shopStore:SetAsync(key, inv)
		end)
		if success then
			pendingSave[player] = nil
			return
		end
		warn(string.format("[ShopHandler] Save failed for %s (attempt %d): %s", player.Name, attempt, tostring(err)))
		if attempt < DATASTORE_RETRIES then
			task.wait(1)
		end
	end
	warn(string.format("[ShopHandler] All save attempts failed for %s", player.Name))
end

local function saveInventoryByUserId(userId: number, inv: PlayerInventory)
	if not datastoreAvailable then
		return
	end
	local key = "Player_" .. tostring(userId)
	for attempt = 1, DATASTORE_RETRIES do
		local success, err = pcall(function()
			shopStore:SetAsync(key, inv)
		end)
		if success then
			return
		end
		warn(string.format("[ShopHandler] Shutdown save failed for UserId %d (attempt %d): %s", userId, attempt, tostring(err)))
		if attempt < DATASTORE_RETRIES then
			task.wait(0.5)
		end
	end
end

------------------------------------------------------------------------
-- Inventory serialization helper (returns a clean copy for the client)
------------------------------------------------------------------------

local function serializeInventory(inv: PlayerInventory): { [string]: any }
	return {
		ownedWeapons = inv.ownedWeapons,
		weaponTiers = inv.weaponTiers,
		ownedSkins = inv.ownedSkins,
		ownedEmotes = inv.ownedEmotes,
		equippedWeapon = inv.equippedWeapon,
		equippedSkins = inv.equippedSkins,
		equippedEmote = inv.equippedEmote,
	}
end

------------------------------------------------------------------------
-- Purchase logic
------------------------------------------------------------------------

local function handlePurchase(player: Player, itemId: string): (boolean, string, { [string]: any }?)
	local item = ShopConfig.Items[itemId]
	if not item then
		return false, "Item not found.", nil
	end

	local inv = inventories[player]
	if not inv then
		return false, "Inventory not loaded.", nil
	end

	-- Check already owned
	if item.category == "Weapons" then
		local weaponName = item.displayName
		if inv.ownedWeapons[weaponName] then
			return false, "Already owned.", nil
		end
	elseif item.category == "Upgrades" then
		local weaponName = item.weaponName :: string
		local tier = item.tier :: number
		-- Must own the weapon
		if not inv.ownedWeapons[weaponName] then
			return false, "You don't own this weapon.", nil
		end
		-- Must have previous tier
		local currentTier = inv.weaponTiers[weaponName] or 1
		if tier == 3 and currentTier < 2 then
			return false, "You need Tier 2 first.", nil
		end
		if currentTier >= tier then
			return false, "Already at this tier or higher.", nil
		end
	elseif item.category == "Skins" then
		if inv.ownedSkins[itemId] then
			return false, "Already owned.", nil
		end
		-- Must own the weapon for this skin
		local weaponName = item.weaponName :: string
		if not inv.ownedWeapons[weaponName] then
			return false, "You don't own this weapon.", nil
		end
	elseif item.category == "Emotes" then
		if inv.ownedEmotes[itemId] then
			return false, "Already owned.", nil
		end
	end

	-- Check balance
	local balance = getPlayerCoins:Invoke(player)
	if balance < item.price then
		return false, "Not enough coins.", nil
	end

	-- Deduct coins
	addPlayerCoins:Fire(player, -item.price, "ShopPurchase")

	-- Grant item
	if item.category == "Weapons" then
		local weaponName = item.displayName
		inv.ownedWeapons[weaponName] = true
		inv.weaponTiers[weaponName] = 1
	elseif item.category == "Upgrades" then
		local weaponName = item.weaponName :: string
		local tier = item.tier :: number
		inv.weaponTiers[weaponName] = tier
		-- Swap the visual Tool model if this is the equipped weapon
		if inv.equippedWeapon == weaponName then
			equipWeaponEvent:Fire(player, weaponName)
		end
	elseif item.category == "Skins" then
		inv.ownedSkins[itemId] = true
	elseif item.category == "Emotes" then
		inv.ownedEmotes[itemId] = true
	end

	pendingSave[player] = true

	return true, "Purchase successful!", serializeInventory(inv)
end

------------------------------------------------------------------------
-- Equip logic
------------------------------------------------------------------------

local function handleEquip(player: Player, itemId: string): (boolean, string, { [string]: any }?)
	local item = ShopConfig.Items[itemId]
	if not item then
		return false, "Item not found.", nil
	end

	local inv = inventories[player]
	if not inv then
		return false, "Inventory not loaded.", nil
	end

	if item.category == "Weapons" then
		local weaponName = item.displayName
		if not inv.ownedWeapons[weaponName] then
			return false, "You don't own this weapon.", nil
		end
		inv.equippedWeapon = weaponName
		-- Notify CombatHandler
		equipWeaponEvent:Fire(player, weaponName)
		-- Notify client
		Remotes.WeaponEquipped:FireClient(player, { weapon = weaponName })
	elseif item.category == "Skins" then
		if not inv.ownedSkins[itemId] then
			return false, "You don't own this skin.", nil
		end
		local weaponName = item.weaponName :: string
		inv.equippedSkins[weaponName] = itemId
	elseif item.category == "Emotes" then
		if not inv.ownedEmotes[itemId] then
			return false, "You don't own this emote.", nil
		end
		inv.equippedEmote = itemId
	else
		return false, "This item cannot be equipped.", nil
	end

	pendingSave[player] = true

	return true, "Equipped!", serializeInventory(inv)
end

------------------------------------------------------------------------
-- RemoteFunction handlers
------------------------------------------------------------------------

Remotes.ShopPurchase.OnServerInvoke = function(player: Player, request: { [string]: any }): { [string]: any }
	if typeof(request) ~= "table" then
		return { success = false, message = "Invalid request." }
	end

	local action = request.action :: string?
	local itemId = request.itemId :: string?

	if not action or not itemId then
		return { success = false, message = "Missing action or itemId." }
	end

	if typeof(action) ~= "string" or typeof(itemId) ~= "string" then
		return { success = false, message = "Invalid parameter types." }
	end

	if action == "purchase" then
		local ok, msg, inv = handlePurchase(player, itemId)
		return { success = ok, message = msg, inventory = inv }
	elseif action == "equip" then
		local ok, msg, inv = handleEquip(player, itemId)
		return { success = ok, message = msg, inventory = inv }
	else
		return { success = false, message = "Unknown action." }
	end
end

Remotes.LoadData.OnServerInvoke = function(player: Player): { [string]: any }
	local inv = inventories[player]
	if inv then
		return { success = true, inventory = serializeInventory(inv) }
	end
	return { success = false, message = "Inventory not loaded yet." }
end

------------------------------------------------------------------------
-- GetWeaponTier BindableFunction (CombatHandler calls this)
------------------------------------------------------------------------

getWeaponTierFunc.OnInvoke = function(player: Player, weaponName: string): number
	local inv = inventories[player]
	if not inv then
		return 1
	end
	return inv.weaponTiers[weaponName] or 1
end

------------------------------------------------------------------------
-- Player lifecycle
------------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	local inv = loadInventory(player)
	inventories[player] = inv
	print(string.format("[ShopHandler] %s loaded — equipped: %s", player.Name, inv.equippedWeapon))

	-- Tell CombatHandler which weapon is equipped (in case it's not the default Sword)
	if inv.equippedWeapon ~= "Sword" then
		equipWeaponEvent:Fire(player, inv.equippedWeapon)
	end
end

local function onPlayerRemoving(player: Player)
	if inventories[player] then
		saveInventory(player)
		inventories[player] = nil
		pendingSave[player] = nil
	end
end

------------------------------------------------------------------------
-- Auto-save loop
------------------------------------------------------------------------

task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL)
		for player, dirty in pendingSave do
			if dirty and player.Parent then
				task.spawn(saveInventory, player)
			end
		end
	end
end)

------------------------------------------------------------------------
-- Shutdown save (BindToClose)
------------------------------------------------------------------------

game:BindToClose(function()
	local saves: { { userId: number, inv: PlayerInventory } } = {}
	for player, inv in inventories do
		if pendingSave[player] then
			table.insert(saves, { userId = player.UserId, inv = inv })
		end
	end

	for _, data in saves do
		task.spawn(function()
			saveInventoryByUserId(data.userId, data.inv)
		end)
	end

	task.wait(2)
end)

------------------------------------------------------------------------
-- Init
------------------------------------------------------------------------

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[ShopHandler] Initialized")
