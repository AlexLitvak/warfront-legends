--!strict
--[[
	GameManager (Server)
	Master match controller that manages the full player-facing flow:
	  Lobby → Queueing → Generating → Countdown → InProgress → Results → Lobby

	Queue system:
	  - Separate queues for FFA (8 players, min 4 after 60s), 2v2 (4), 3v3 (6)
	  - Players join/leave queues via RemoteEvents
	  - Queue counts broadcast to all queued players in real-time

	Arena integration:
	  - Uses ArenaManager BindableFunction/Event API for arena lifecycle
	  - SelectArena → SetupArena → SpawnMatchPlayers → StartArenaHazards → CleanupArena

	Combat tracking:
	  - Kills/deaths per player, team scores for team modes
	  - Win conditions: kill threshold OR timer expiry
	  - End-of-match coin awards via CoinManager
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage:WaitForChild("GameConfig"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

------------------------------------------------------------------------
-- Lobby platform (so players don't fall into the void)
------------------------------------------------------------------------

local lobbyPlatform = Instance.new("Part")
lobbyPlatform.Name = "LobbyPlatform"
lobbyPlatform.Size = Vector3.new(100, 3, 100)
lobbyPlatform.Position = Vector3.new(0, -1.5, 0)
lobbyPlatform.Anchored = true
lobbyPlatform.Material = Enum.Material.SmoothPlastic
lobbyPlatform.Color = Color3.fromRGB(40, 40, 50)
lobbyPlatform.TopSurface = Enum.SurfaceType.Smooth
lobbyPlatform.BottomSurface = Enum.SurfaceType.Smooth
lobbyPlatform.Parent = Workspace

local lobbySpawn = Instance.new("SpawnLocation")
lobbySpawn.Name = "LobbySpawn"
lobbySpawn.Size = Vector3.new(8, 1, 8)
lobbySpawn.Position = Vector3.new(0, 0.5, 0)
lobbySpawn.Anchored = true
lobbySpawn.Transparency = 1
lobbySpawn.CanCollide = false
lobbySpawn.Neutral = true
lobbySpawn.Parent = Workspace

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

local DEV_MODE = true -- Set to false for production

local COUNTDOWN_DURATION = if DEV_MODE then 2 else 5
local RESULTS_DURATION = 10
local TIMER_TICK = 1
local QUEUE_TIMEOUT_FFA = if DEV_MODE then 0 else 60 -- seconds before FFA starts with min players

------------------------------------------------------------------------
-- Game mode definitions
------------------------------------------------------------------------

type GameMode = "FFA" | "2v2" | "3v3"

local MODE_CONFIG: { [GameMode]: {
	minPlayers: number,
	maxPlayers: number,
	matchDuration: number,
	killThreshold: number,
	respawnTime: number,
	teamSize: number,
	teamCount: number,
} } = {
	FFA = {
		minPlayers = if DEV_MODE then 1 else 4,
		maxPlayers = GameConfig.MAX_PLAYERS_FFA,
		matchDuration = GameConfig.MATCH_DURATION_FFA,
		killThreshold = GameConfig.KILL_THRESHOLD_FFA,
		respawnTime = GameConfig.RESPAWN_TIME_FFA,
		teamSize = 0,
		teamCount = 0,
	},
	["2v2"] = {
		minPlayers = if DEV_MODE then 1 else 4,
		maxPlayers = if DEV_MODE then 1 else GameConfig.MAX_PLAYERS_2V2,
		matchDuration = GameConfig.MATCH_DURATION_TEAM,
		killThreshold = GameConfig.KILL_THRESHOLD_2V2,
		respawnTime = GameConfig.RESPAWN_TIME_TEAM,
		teamSize = if DEV_MODE then 1 else 2,
		teamCount = 2,
	},
	["3v3"] = {
		minPlayers = if DEV_MODE then 1 else 6,
		maxPlayers = if DEV_MODE then 1 else GameConfig.MAX_PLAYERS_3V3,
		matchDuration = GameConfig.MATCH_DURATION_TEAM,
		killThreshold = GameConfig.KILL_THRESHOLD_3V3,
		respawnTime = GameConfig.RESPAWN_TIME_TEAM,
		teamSize = if DEV_MODE then 1 else 3,
		teamCount = 2,
	},
}

------------------------------------------------------------------------
-- Server-side BindableEvents / BindableFunctions
------------------------------------------------------------------------

local serverEvents = ServerScriptService:FindFirstChild("ServerEvents") :: Folder
if not serverEvents then
	local folder = Instance.new("Folder")
	folder.Name = "ServerEvents"
	folder.Parent = ServerScriptService
	serverEvents = folder
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

-- Kill tracking (CombatHandler fires this)
local onPlayerKill = getOrCreateBindable("BindableEvent", "OnPlayerKill") :: BindableEvent

-- Coin system
local addPlayerCoins = getOrCreateBindable("BindableEvent", "AddPlayerCoins") :: BindableEvent

-- Team query (CombatHandler invokes this to check friendly fire)
local getPlayerTeamFunc = getOrCreateBindable("BindableFunction", "GetPlayerTeam") :: BindableFunction

-- ArenaManager API
local selectArenaFunc = getOrCreateBindable("BindableFunction", "SelectArena") :: BindableFunction
local setupArenaFunc = getOrCreateBindable("BindableFunction", "SetupArena") :: BindableFunction
local spawnMatchPlayersEvent = getOrCreateBindable("BindableEvent", "SpawnMatchPlayers") :: BindableEvent
local startArenaHazardsEvent = getOrCreateBindable("BindableEvent", "StartArenaHazards") :: BindableEvent
local cleanupArenaEvent = getOrCreateBindable("BindableEvent", "CleanupArena") :: BindableEvent

------------------------------------------------------------------------
-- Match state
------------------------------------------------------------------------

type MatchPhase = "Lobby" | "Queueing" | "Generating" | "Countdown" | "InProgress" | "Results"

type PlayerMatchStats = {
	kills: number,
	deaths: number,
	damageDealt: number,
	assists: number,
	coinsEarned: number,
}

local currentPhase: MatchPhase = "Lobby"
local currentGameMode: GameMode = "FFA"
local matchPlayers: { Player } = {}
local playerStats: { [Player]: PlayerMatchStats } = {}
local matchTimeRemaining: number = 0
local matchLoopThread: thread? = nil
local currentArenaFolder: Folder? = nil
local currentArenaType: string = ""

-- Team state
local teamAssignments: { [Player]: number } = {}
local teamScores: { [number]: number } = {}

local TEAM_NAMES: { [number]: string } = {
	[1] = "Blue",
	[2] = "Red",
}

------------------------------------------------------------------------
-- Queue state
------------------------------------------------------------------------

type QueueEntry = {
	player: Player,
	joinedAt: number,
}

local queues: { [GameMode]: { QueueEntry } } = {
	FFA = {},
	["2v2"] = {},
	["3v3"] = {},
}

-- Track which queue each player is in (nil = not queued)
local playerQueue: { [Player]: GameMode } = {}

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function isTeamMode(): boolean
	return currentGameMode == "2v2" or currentGameMode == "3v3"
end

local function getPlayerTeam(player: Player): number
	return teamAssignments[player] or 0
end

local function setPhase(newPhase: MatchPhase)
	currentPhase = newPhase
	print(string.format("[GameManager] Phase → %s (mode: %s)", newPhase, currentGameMode))
end

local function broadcastMatchState(data: { [string]: any })
	data.state = currentPhase
	data.gameMode = currentGameMode

	if isTeamMode() then
		data.teamScores = teamScores
		local teamMap: { [string]: number } = {}
		for player, team in teamAssignments do
			if player.Parent then
				teamMap[player.Name] = team
			end
		end
		data.teamMap = teamMap
	end

	Remotes.MatchStateChange:FireAllClients(data)
end

------------------------------------------------------------------------
-- Queue management
------------------------------------------------------------------------

local function getQueuePlayerCount(mode: GameMode): number
	return #queues[mode]
end

local function broadcastQueueUpdate(mode: GameMode)
	local config = MODE_CONFIG[mode]
	local count = getQueuePlayerCount(mode)
	local needed = config.maxPlayers

	for _, entry in queues[mode] do
		if entry.player.Parent then
			Remotes.QueueUpdate:FireClient(entry.player, {
				mode = mode,
				count = count,
				needed = needed,
			})
		end
	end
end

local function removeFromQueue(player: Player)
	local mode = playerQueue[player]
	if not mode then
		return
	end

	local queue = queues[mode]
	for i, entry in queue do
		if entry.player == player then
			table.remove(queue, i)
			break
		end
	end

	playerQueue[player] = nil
	broadcastQueueUpdate(mode)
end

local function addToQueue(player: Player, mode: GameMode)
	-- Remove from any existing queue first
	removeFromQueue(player)

	local config = MODE_CONFIG[mode]
	if not config then
		return
	end

	-- Don't allow joining if a match is launching for this mode
	-- (or if the queue is already full)
	if getQueuePlayerCount(mode) >= config.maxPlayers then
		return
	end

	table.insert(queues[mode], {
		player = player,
		joinedAt = os.clock(),
	})
	playerQueue[player] = mode

	broadcastQueueUpdate(mode)
end

--- Pull players from a queue to form a match. Returns the list of players.
local function drainQueue(mode: GameMode, count: number): { Player }
	local queue = queues[mode]
	local players: { Player } = {}

	local pulled = 0
	while pulled < count and #queue > 0 do
		local entry = table.remove(queue, 1) :: QueueEntry
		if entry.player.Parent then
			table.insert(players, entry.player)
			playerQueue[entry.player] = nil
			pulled += 1
		end
	end

	broadcastQueueUpdate(mode)
	return players
end

-- Forward declaration (launchMatch is defined after checkQueues)
local launchMatch: (mode: GameMode, playerCount: number) -> ()

--- Check if any queue is ready to launch a match.
local function checkQueues()
	-- Don't start a new match if one is already running
	if currentPhase ~= "Lobby" then
		return
	end

	-- Check each mode
	for _, mode: GameMode in { "FFA", "2v2", "3v3" } :: { GameMode } do
		local config = MODE_CONFIG[mode]
		local count = getQueuePlayerCount(mode)

		if mode == "FFA" then
			-- FFA: starts at 8 players, OR after 60s with minimum 4
			if count >= config.maxPlayers then
				launchMatch(mode, config.maxPlayers)
				return
			end

			-- Check timeout with minimum players
			if count >= config.minPlayers then
				local queue = queues[mode]
				local oldestEntry = queue[1]
				if oldestEntry and (os.clock() - oldestEntry.joinedAt) >= QUEUE_TIMEOUT_FFA then
					launchMatch(mode, count)
					return
				end
			end
		else
			-- Team modes: start when exact player count is met
			if count >= config.maxPlayers then
				launchMatch(mode, config.maxPlayers)
				return
			end
		end
	end
end

------------------------------------------------------------------------
-- Team assignment
------------------------------------------------------------------------

local function assignTeams()
	teamAssignments = {}
	teamScores = { [1] = 0, [2] = 0 }

	local config = MODE_CONFIG[currentGameMode]
	if not config or config.teamSize == 0 then
		return
	end

	-- Shuffle players for random team assignment
	local shuffled = table.clone(matchPlayers)
	for i = #shuffled, 2, -1 do
		local j = math.random(1, i)
		shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
	end

	-- First half → team 1, second half → team 2
	local teamSize = config.teamSize
	for i, player in shuffled do
		if i <= teamSize then
			teamAssignments[player] = 1
		else
			teamAssignments[player] = 2
		end
	end

	-- Notify each player
	for player, team in teamAssignments do
		if player.Parent then
			Remotes.TeamAssignment:FireClient(player, {
				team = team,
				teamName = TEAM_NAMES[team],
				gameMode = currentGameMode,
			})
		end
	end
end

------------------------------------------------------------------------
-- Standings & coin awards
------------------------------------------------------------------------

local function getStandings(): { { name: string, kills: number, deaths: number, assists: number, damageDealt: number, coinsEarned: number, team: number? } }
	local standings = {}
	for _, player in matchPlayers do
		if player.Parent then
			local stats = playerStats[player]
			if stats then
				table.insert(standings, {
					name = player.Name,
					kills = stats.kills,
					deaths = stats.deaths,
					assists = stats.assists,
					damageDealt = stats.damageDealt,
					coinsEarned = stats.coinsEarned,
					team = if isTeamMode() then teamAssignments[player] else nil,
				})
			end
		end
	end
	table.sort(standings, function(a, b)
		return a.kills > b.kills
	end)
	return standings
end

local function awardEndOfMatchCoins(winnerPlayer: Player?, winningTeam: number?)
	for _, player in matchPlayers do
		if not player.Parent then
			continue
		end
		local stats = playerStats[player]
		if not stats then
			continue
		end

		-- Everyone gets match completion coins
		addPlayerCoins:Fire(player, GameConfig.COINS_MATCH_COMPLETE, "MatchComplete")
		stats.coinsEarned += GameConfig.COINS_MATCH_COMPLETE

		-- Winner bonus
		if isTeamMode() then
			if winningTeam and teamAssignments[player] == winningTeam then
				addPlayerCoins:Fire(player, GameConfig.COINS_WIN_BONUS, "MatchWin")
				stats.coinsEarned += GameConfig.COINS_WIN_BONUS
			end
		else
			if player == winnerPlayer then
				addPlayerCoins:Fire(player, GameConfig.COINS_WIN_BONUS, "MatchWin")
				stats.coinsEarned += GameConfig.COINS_WIN_BONUS
			end
		end
	end
end

------------------------------------------------------------------------
-- Respawning
------------------------------------------------------------------------

local function respawnInArena(player: Player)
	if not player.Parent or currentPhase ~= "InProgress" then
		return
	end

	-- Re-spawn character, then ArenaManager will handle positioning
	-- if there's an active arena folder
	if currentArenaFolder then
		spawnMatchPlayersEvent:Fire({ player }, currentArenaFolder)
	else
		player:LoadCharacter()
	end
end

local function respawnAfterDelay(player: Player)
	local config = MODE_CONFIG[currentGameMode]
	local respawnTime = if config then config.respawnTime else GameConfig.RESPAWN_TIME_FFA

	task.delay(respawnTime, function()
		if currentPhase == "InProgress" and player.Parent then
			respawnInArena(player)
		end
	end)
end

------------------------------------------------------------------------
-- Match phases
------------------------------------------------------------------------

-- Forward declarations
local runResults: () -> ()
local runMatch: () -> ()
local runCountdown: () -> ()

launchMatch = function(mode: GameMode, playerCount: number)
	if currentPhase ~= "Lobby" then
		return
	end

	currentGameMode = mode

	-- Pull players from queue
	matchPlayers = drainQueue(mode, playerCount)
	if #matchPlayers < MODE_CONFIG[mode].minPlayers then
		-- Not enough valid players after draining (some may have disconnected)
		-- Return them to lobby
		matchPlayers = {}
		setPhase("Lobby")
		return
	end

	-- Initialize stats
	playerStats = {}
	for _, player in matchPlayers do
		playerStats[player] = {
			kills = 0,
			deaths = 0,
			damageDealt = 0,
			assists = 0,
			coinsEarned = 0,
		}
	end

	-- Assign teams for team modes
	if isTeamMode() then
		assignTeams()
	end

	-- Generate arena
	setPhase("Generating")
	broadcastMatchState({})

	local arenaType = selectArenaFunc:Invoke(if DEV_MODE then "JungleRuins" else "random")
	currentArenaType = arenaType
	local arenaFolder = setupArenaFunc:Invoke(arenaType)
	currentArenaFolder = arenaFolder

	if not arenaFolder then
		warn("[GameManager] Arena generation failed, aborting match")
		matchPlayers = {}
		playerStats = {}
		teamAssignments = {}
		teamScores = {}
		currentArenaFolder = nil
		currentArenaType = ""
		setPhase("Lobby")
		return
	end

	-- Hide lobby platform during match
	lobbyPlatform.Transparency = 1
	lobbyPlatform.CanCollide = false
	lobbySpawn.Enabled = false

	-- Spawn all match players in the arena
	spawnMatchPlayersEvent:Fire(matchPlayers, arenaFolder)

	-- Run countdown
	runCountdown()
end

runCountdown = function()
	setPhase("Countdown")

	local remaining = COUNTDOWN_DURATION
	while remaining > 0 do
		broadcastMatchState({
			countdown = remaining,
			arenaName = currentArenaType,
		})

		task.wait(1)
		remaining -= 1

		-- Abort if too many players left
		local alive = 0
		for _, player in matchPlayers do
			if player.Parent then
				alive += 1
			end
		end
		if alive < MODE_CONFIG[currentGameMode].minPlayers then
			print("[GameManager] Not enough players during countdown, aborting")
			cleanupArenaEvent:Fire()
			lobbyPlatform.Transparency = 0
			lobbyPlatform.CanCollide = true
			lobbySpawn.Enabled = true
			matchPlayers = {}
			playerStats = {}
			teamAssignments = {}
			teamScores = {}
			currentArenaFolder = nil
			currentArenaType = ""
			setPhase("Lobby")
			broadcastMatchState({})
			return
		end
	end

	-- FIGHT!
	broadcastMatchState({
		countdown = 0,
		arenaName = currentArenaType,
	})
	task.wait(0.5)

	runMatch()
end

runMatch = function()
	setPhase("InProgress")

	local config = MODE_CONFIG[currentGameMode]
	matchTimeRemaining = if config then config.matchDuration else GameConfig.MATCH_DURATION_FFA

	-- Start arena hazards (ArenaManager handles 5s grace period internally)
	startArenaHazardsEvent:Fire(currentArenaType)

	broadcastMatchState({
		timeRemaining = matchTimeRemaining,
		standings = getStandings(),
	})

	-- Death → respawn loop for each match player
	for _, player in matchPlayers do
		task.spawn(function()
			while currentPhase == "InProgress" and player.Parent do
				local character = player.Character or player.CharacterAdded:Wait()
				local humanoid = character:WaitForChild("Humanoid") :: Humanoid
				humanoid.Died:Wait()
				respawnAfterDelay(player)

				if currentPhase == "InProgress" and player.Parent then
					player.CharacterAdded:Wait()
				end
			end
		end)
	end

	-- Match timer loop
	matchLoopThread = task.spawn(function()
		while matchTimeRemaining > 0 and currentPhase == "InProgress" do
			task.wait(TIMER_TICK)
			matchTimeRemaining -= TIMER_TICK

			broadcastMatchState({
				timeRemaining = matchTimeRemaining,
				standings = getStandings(),
			})
		end

		if currentPhase == "InProgress" then
			runResults()
		end
	end)
end

runResults = function()
	setPhase("Results")

	local standings = getStandings()
	local resultData: { [string]: any } = {
		standings = standings,
		arenaName = currentArenaType,
	}

	if isTeamMode() then
		local score1 = teamScores[1] or 0
		local score2 = teamScores[2] or 0
		local winningTeam: number? = nil
		if score1 > score2 then
			winningTeam = 1
		elseif score2 > score1 then
			winningTeam = 2
		end

		resultData.winningTeam = winningTeam
		resultData.winner = if winningTeam then ("Team " .. TEAM_NAMES[winningTeam]) else "Draw"
		resultData.teamScores = teamScores

		awardEndOfMatchCoins(nil, winningTeam)
	else
		local winnerName = if #standings > 0 then standings[1].name else "Nobody"
		resultData.winner = winnerName

		local winner: Player? = nil
		for _, player in matchPlayers do
			if player.Parent and player.Name == winnerName then
				winner = player
				break
			end
		end

		awardEndOfMatchCoins(winner, nil)
	end

	-- Send detailed results to each match player
	for _, player in matchPlayers do
		if player.Parent then
			local stats = playerStats[player]
			local personalData = table.clone(resultData)
			if stats then
				personalData.personalStats = {
					kills = stats.kills,
					deaths = stats.deaths,
					assists = stats.assists,
					damageDealt = stats.damageDealt,
					coinsEarned = stats.coinsEarned,
				}
			end
			personalData.lastMode = currentGameMode
			Remotes.MatchResults:FireClient(player, personalData)
		end
	end

	-- Also broadcast general state change
	broadcastMatchState(resultData)

	-- Wait for results screen
	task.wait(RESULTS_DURATION)

	-- Cleanup
	cleanupArenaEvent:Fire()

	-- Restore lobby platform
	lobbyPlatform.Transparency = 0
	lobbyPlatform.CanCollide = true
	lobbySpawn.Enabled = true

	-- Respawn all match players for lobby
	for _, player in matchPlayers do
		if player.Parent then
			player:LoadCharacter()
		end
	end

	matchPlayers = {}
	playerStats = {}
	teamAssignments = {}
	teamScores = {}
	currentArenaFolder = nil
	currentArenaType = ""
	matchLoopThread = nil

	setPhase("Lobby")
	broadcastMatchState({})
end

------------------------------------------------------------------------
-- Kill handling (from CombatHandler)
------------------------------------------------------------------------

local function onKillDuringMatch(killer: Player, victim: Player)
	if currentPhase ~= "InProgress" then
		return
	end

	local killerStats = playerStats[killer]
	if killerStats then
		killerStats.kills += 1
	end

	local victimStats = playerStats[victim]
	if victimStats then
		victimStats.deaths += 1
	end

	if isTeamMode() then
		local killerTeam = teamAssignments[killer]
		if killerTeam then
			teamScores[killerTeam] = (teamScores[killerTeam] or 0) + 1
		end
	end

	-- Broadcast updated scores
	broadcastMatchState({
		timeRemaining = matchTimeRemaining,
		standings = getStandings(),
	})

	-- Check kill threshold win
	local config = MODE_CONFIG[currentGameMode]
	local threshold = if config then config.killThreshold else GameConfig.KILL_THRESHOLD_FFA

	if isTeamMode() then
		for _, score in teamScores do
			if score >= threshold then
				if matchLoopThread then
					task.cancel(matchLoopThread)
					matchLoopThread = nil
				end
				runResults()
				return
			end
		end
	else
		if killerStats and killerStats.kills >= threshold then
			if matchLoopThread then
				task.cancel(matchLoopThread)
				matchLoopThread = nil
			end
			runResults()
			return
		end
	end

	-- Respawn victim after delay
	respawnAfterDelay(victim)
end

------------------------------------------------------------------------
-- GetPlayerTeam (CombatHandler queries this for friendly fire)
------------------------------------------------------------------------

getPlayerTeamFunc.OnInvoke = function(player: Player): number
	return getPlayerTeam(player)
end

------------------------------------------------------------------------
-- Queue RemoteEvent handlers
------------------------------------------------------------------------

Remotes.JoinQueue.OnServerEvent:Connect(function(player: Player, data: { [string]: any })
	local mode = data.mode :: string?
	if not mode then
		return
	end

	-- Validate mode
	if mode ~= "FFA" and mode ~= "2v2" and mode ~= "3v3" then
		return
	end

	-- Can't queue if already in a match
	if table.find(matchPlayers, player) then
		return
	end

	addToQueue(player, mode :: GameMode)
	checkQueues()
end)

Remotes.LeaveQueue.OnServerEvent:Connect(function(player: Player)
	removeFromQueue(player)
end)

------------------------------------------------------------------------
-- Player lifecycle
------------------------------------------------------------------------

Players.CharacterAutoLoads = false

local function onPlayerAdded(player: Player)
	-- Spawn in lobby
	player:LoadCharacter()

	-- Notify of current state
	if currentPhase == "Lobby" then
		Remotes.MatchStateChange:FireClient(player, {
			state = "Lobby",
		})
	else
		-- Match in progress — let them know
		local stateData: { [string]: any } = {
			state = currentPhase,
			gameMode = currentGameMode,
			timeRemaining = if currentPhase == "InProgress" then matchTimeRemaining else nil,
			standings = if currentPhase == "InProgress" then getStandings() else nil,
		}
		Remotes.MatchStateChange:FireClient(player, stateData)
	end
end

local function onPlayerRemoving(player: Player)
	-- Remove from queue
	removeFromQueue(player)

	-- Remove from active match
	local idx = table.find(matchPlayers, player)
	if idx then
		table.remove(matchPlayers, idx)
	end
	playerStats[player] = nil
	teamAssignments[player] = nil

	-- End match early if not enough players
	if currentPhase == "InProgress" then
		local alive = 0
		for _, p in matchPlayers do
			if p.Parent then
				alive += 1
			end
		end
		if alive < MODE_CONFIG[currentGameMode].minPlayers then
			if matchLoopThread then
				task.cancel(matchLoopThread)
				matchLoopThread = nil
			end
			runResults()
		end
	end
end

------------------------------------------------------------------------
-- Queue check loop (handles FFA timeout)
------------------------------------------------------------------------

task.spawn(function()
	while true do
		task.wait(1)
		if currentPhase == "Lobby" then
			checkQueues()
		end
	end
end)

------------------------------------------------------------------------
-- Init
------------------------------------------------------------------------

onPlayerKill.Event:Connect(function(killer: Player, victim: Player)
	onKillDuringMatch(killer, victim)
end)

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[GameManager] Initialized — queue-based match system active")
