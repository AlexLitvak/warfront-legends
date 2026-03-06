--!strict
--[[
	CoinManager (Server)
	Single authority for player coin balances. All coin awards flow
	through the AddPlayerCoins BindableEvent. Persists balances to
	DataStoreService with auto-save and save-on-leave.
]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

local DATASTORE_NAME = "PlayerCoins_v1"
local AUTOSAVE_INTERVAL = 60 -- seconds (per spec)
local DATASTORE_RETRIES = 3

------------------------------------------------------------------------
-- DataStore (may fail in unpublished places)
------------------------------------------------------------------------

local coinStore = nil
local datastoreAvailable = false
do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(DATASTORE_NAME)
	end)
	if ok then
		coinStore = result
		datastoreAvailable = true
	else
		warn("[CoinManager] DataStore unavailable (place not published?): " .. tostring(result))
	end
end

------------------------------------------------------------------------
-- Server-side BindableEvent: other scripts fire this to award coins
------------------------------------------------------------------------

local serverEvents = ServerScriptService:FindFirstChild("ServerEvents") :: Folder
if not serverEvents then
	local folder = Instance.new("Folder")
	folder.Name = "ServerEvents"
	folder.Parent = ServerScriptService
	serverEvents = folder
end

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

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------

local coinBalances: { [Player]: number } = {}
local pendingSave: { [Player]: boolean } = {} -- tracks players with unsaved changes

------------------------------------------------------------------------
-- DataStore helpers
------------------------------------------------------------------------

local function datastoreKey(player: Player): string
	return "Player_" .. tostring(player.UserId)
end

local function loadCoins(player: Player): number
	if not datastoreAvailable then
		return 0
	end
	local key = datastoreKey(player)
	for attempt = 1, DATASTORE_RETRIES do
		local success, result = pcall(function()
			return coinStore:GetAsync(key)
		end)
		if success then
			return (result :: number?) or 0
		end
		warn(string.format("[CoinManager] Load failed for %s (attempt %d): %s", player.Name, attempt, tostring(result)))
		if attempt < DATASTORE_RETRIES then
			task.wait(1)
		end
	end
	warn(string.format("[CoinManager] All load attempts failed for %s, starting at 0", player.Name))
	return 0
end

local function saveCoins(player: Player)
	if not datastoreAvailable then
		return
	end
	local balance = coinBalances[player]
	if balance == nil then
		return
	end

	local key = datastoreKey(player)
	for attempt = 1, DATASTORE_RETRIES do
		local success, err = pcall(function()
			coinStore:SetAsync(key, balance)
		end)
		if success then
			pendingSave[player] = nil
			return
		end
		warn(string.format("[CoinManager] Save failed for %s (attempt %d): %s", player.Name, attempt, tostring(err)))
		if attempt < DATASTORE_RETRIES then
			task.wait(1)
		end
	end
	warn(string.format("[CoinManager] All save attempts failed for %s", player.Name))
end

--- Save a player by UserId (used during BindToClose when Player object may be gone)
local function saveCoinsByUserId(userId: number, balance: number)
	if not datastoreAvailable then
		return
	end
	local key = "Player_" .. tostring(userId)
	for attempt = 1, DATASTORE_RETRIES do
		local success, err = pcall(function()
			coinStore:SetAsync(key, balance)
		end)
		if success then
			return
		end
		warn(string.format("[CoinManager] Shutdown save failed for UserId %d (attempt %d): %s", userId, attempt, tostring(err)))
		if attempt < DATASTORE_RETRIES then
			task.wait(0.5)
		end
	end
end

------------------------------------------------------------------------
-- Core coin operations
------------------------------------------------------------------------

local function addCoins(player: Player, amount: number, reason: string)
	local balance = coinBalances[player]
	if balance == nil then
		return -- player not loaded yet or already left
	end

	coinBalances[player] = balance + amount
	pendingSave[player] = true

	-- Notify the client of the change
	Remotes.CoinUpdate:FireClient(player, {
		amount = amount,
		reason = reason,
		newBalance = coinBalances[player],
	})

	print(string.format("[CoinManager] %s +%d coins (%s) → %d total", player.Name, amount, reason, coinBalances[player]))
end

local function getCoins(player: Player): number
	return coinBalances[player] or 0
end

------------------------------------------------------------------------
-- Player lifecycle
------------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	local balance = loadCoins(player)
	coinBalances[player] = balance
	print(string.format("[CoinManager] %s loaded with %d coins", player.Name, balance))

	-- Send initial balance to client
	Remotes.CoinUpdate:FireClient(player, {
		amount = 0,
		reason = "Init",
		newBalance = balance,
	})
end

local function onPlayerRemoving(player: Player)
	if coinBalances[player] ~= nil then
		saveCoins(player)
		coinBalances[player] = nil
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
				task.spawn(saveCoins, player)
			end
		end
	end
end)

------------------------------------------------------------------------
-- Shutdown save (BindToClose)
------------------------------------------------------------------------

game:BindToClose(function()
	-- Collect all pending saves before player references become invalid
	local saves: { { userId: number, balance: number } } = {}
	for player, balance in coinBalances do
		if pendingSave[player] then
			table.insert(saves, { userId = player.UserId, balance = balance })
		end
	end

	-- Save all in parallel
	local threads: { thread } = {}
	for _, data in saves do
		table.insert(threads, task.spawn(function()
			saveCoinsByUserId(data.userId, data.balance)
		end))
	end

	-- Wait for all saves to finish (BindToClose gives us 30 seconds)
	task.wait(2)
end)

------------------------------------------------------------------------
-- Init
------------------------------------------------------------------------

-- BindableEvent: other scripts fire (player, amount, reason)
addPlayerCoins.Event:Connect(function(player: Player, amount: number, reason: string)
	addCoins(player, amount, reason)
end)

-- BindableFunction: other scripts invoke (player) → number
getPlayerCoins.OnInvoke = function(player: Player): number
	return getCoins(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- Handle players already in the server
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[CoinManager] Initialized")
