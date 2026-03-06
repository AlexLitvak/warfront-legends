--!strict
--[[
	GameManager (Server)
	Manages the match lifecycle: lobby → countdown → match → results.
	Supports three game modes that rotate each match:
	  • FFA   — free-for-all, individual kill scoring
	  • 2v2   — two teams of two, team kill scoring
	  • 3v3   — two teams of three, team kill scoring
	Tracks kills/deaths, enforces timers and kill thresholds, handles
	respawning, team assignment, and broadcasts state to all clients.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage:WaitForChild("GameConfig"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

------------------------------------------------------------------------
-- Match-flow constants
------------------------------------------------------------------------

local MIN_PLAYERS_TO_START = 2
local COUNTDOWN_DURATION = 10
local RESULTS_DURATION = 10
local TIMER_TICK = 1

------------------------------------------------------------------------
-- Game mode definitions
------------------------------------------------------------------------

type GameMode = "FFA" | "2v2" | "3v3"

local MODE_ROTATION: { GameMode } = { "FFA", "2v2", "3v3" }
local currentModeIndex = 1

local MODE_CONFIG: { [GameMode]: {
	minPlayers: number,
	maxPlayers: number,
	matchDuration: number,
	killThreshold: number,
	respawnTime: number,
	teamSize: number,      -- 0 = FFA
	teamCount: number,     -- 0 = FFA
} } = {
	FFA = {
		minPlayers = 2,
		maxPlayers = GameConfig.MAX_PLAYERS_FFA,
		matchDuration = GameConfig.MATCH_DURATION_FFA,
		killThreshold = GameConfig.KILL_THRESHOLD_FFA,
		respawnTime = GameConfig.RESPAWN_TIME_FFA,
		teamSize = 0,
		teamCount = 0,
	},
	["2v2"] = {
		minPlayers = 4,
		maxPlayers = GameConfig.MAX_PLAYERS_2V2,
		matchDuration = GameConfig.MATCH_DURATION_TEAM,
		killThreshold = GameConfig.KILL_THRESHOLD_2V2,
		respawnTime = GameConfig.RESPAWN_TIME_TEAM,
		teamSize = 2,
		teamCount = 2,
	},
	["3v3"] = {
		minPlayers = 6,
		maxPlayers = GameConfig.MAX_PLAYERS_3V3,
		matchDuration = GameConfig.MATCH_DURATION_TEAM,
		killThreshold = GameConfig.KILL_THRESHOLD_3V3,
		respawnTime = GameConfig.RESPAWN_TIME_TEAM,
		teamSize = 3,
		teamCount = 2,
	},
}

------------------------------------------------------------------------
-- Server-side BindableEvents
------------------------------------------------------------------------

local serverEvents = ServerScriptService:FindFirstChild("ServerEvents") :: Folder
if not serverEvents then
	local folder = Instance.new("Folder")
	folder.Name = "ServerEvents"
	folder.Parent = ServerScriptService
	serverEvents = folder
end

local onPlayerKill = serverEvents:FindFirstChild("OnPlayerKill") :: BindableEvent
if not onPlayerKill then
	local event = Instance.new("BindableEvent")
	event.Name = "OnPlayerKill"
	event.Parent = serverEvents
	onPlayerKill = event
end

local addPlayerCoins = serverEvents:FindFirstChild("AddPlayerCoins") :: BindableEvent
if not addPlayerCoins then
	local event = Instance.new("BindableEvent")
	event.Name = "AddPlayerCoins"
	event.Parent = serverEvents
	addPlayerCoins = event
end

-- GetPlayerTeam: CombatHandler invokes to check team for friendly fire
local getPlayerTeamFunc = serverEvents:FindFirstChild("GetPlayerTeam") :: BindableFunction
if not getPlayerTeamFunc then
	local func = Instance.new("BindableFunction")
	func.Name = "GetPlayerTeam"
	func.Parent = serverEvents
	getPlayerTeamFunc = func
end

------------------------------------------------------------------------
-- Match state
------------------------------------------------------------------------

type MatchState = "WaitingForPlayers" | "Countdown" | "InProgress" | "Results"

type PlayerMatchStats = {
	kills: number,
	deaths: number,
	coinsEarned: number,
}

local currentState: MatchState = "WaitingForPlayers"
local currentGameMode: GameMode = "FFA"
local matchPlayers: { Player } = {}
local playerStats: { [Player]: PlayerMatchStats } = {}
local matchTimeRemaining: number = 0
local countdownRemaining: number = 0
local matchLoopThread: thread? = nil

-- Team state (only active during 2v2/3v3)
local teamAssignments: { [Player]: number } = {} -- player → team number (1 or 2)
local teamScores: { [number]: number } = {}      -- team number → total kills

------------------------------------------------------------------------
-- Team helpers
------------------------------------------------------------------------

local TEAM_NAMES: { [number]: string } = {
	[1] = "Blue",
	[2] = "Red",
}

local function isTeamMode(): boolean
	return currentGameMode == "2v2" or currentGameMode == "3v3"
end

local function getPlayerTeam(player: Player): number
	return teamAssignments[player] or 0
end

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

	-- Assign alternating teams: first half team 1, second half team 2
	local teamSize = config.teamSize
	for i, player in shuffled do
		if i <= teamSize then
			teamAssignments[player] = 1
		else
			teamAssignments[player] = 2
		end
	end

	-- Notify each player of their team assignment
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

--- Build a map of all player team assignments for broadcasting.
local function getTeamMap(): { [string]: number }
	local map: { [string]: number } = {}
	for player, team in teamAssignments do
		if player.Parent then
			map[player.Name] = team
		end
	end
	return map
end

------------------------------------------------------------------------
-- Mode selection
------------------------------------------------------------------------

--- Pick the next viable game mode based on player count.
local function selectNextMode(): GameMode
	local playerCount = #Players:GetPlayers()

	-- Try modes in rotation order starting from current index
	for offset = 0, #MODE_ROTATION - 1 do
		local idx = ((currentModeIndex - 1 + offset) % #MODE_ROTATION) + 1
		local mode = MODE_ROTATION[idx]
		local config = MODE_CONFIG[mode]
		if playerCount >= config.minPlayers then
			currentModeIndex = (idx % #MODE_ROTATION) + 1 -- advance for next time
			return mode
		end
	end

	-- Fallback to FFA (lowest player requirement)
	return "FFA"
end

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function broadcastState(data: { [string]: any })
	data.state = currentState
	data.gameMode = currentGameMode

	-- Include team data during team matches
	if isTeamMode() then
		data.teamScores = teamScores
		data.teamMap = getTeamMap()
	end

	Remotes.MatchStateChange:FireAllClients(data)
end

local function getStandings(): { { name: string, kills: number, deaths: number, team: number? } }
	local standings: { { name: string, kills: number, deaths: number, team: number? } } = {}
	for _, player in matchPlayers do
		if player.Parent then
			local stats = playerStats[player]
			if stats then
				table.insert(standings, {
					name = player.Name,
					kills = stats.kills,
					deaths = stats.deaths,
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

local function spawnPlayer(player: Player)
	if player.Parent then
		player:LoadCharacter()
	end
end

local function respawnAfterDelay(player: Player)
	local config = MODE_CONFIG[currentGameMode]
	local respawnTime = if config then config.respawnTime else GameConfig.RESPAWN_TIME_FFA

	task.delay(respawnTime, function()
		if currentState == "InProgress" and player.Parent then
			spawnPlayer(player)
		end
	end)
end

------------------------------------------------------------------------
-- State transitions
------------------------------------------------------------------------

local function setState(newState: MatchState)
	currentState = newState
	print(string.format("[GameManager] State → %s (mode: %s)", newState, currentGameMode))
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

		-- Winner gets bonus
		if isTeamMode() then
			-- Entire winning team gets the bonus
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
-- Match phases
------------------------------------------------------------------------

local function runResults()
	setState("Results")

	local standings = getStandings()
	local resultData: { [string]: any } = {
		standings = standings,
	}

	if isTeamMode() then
		-- Determine winning team
		local score1 = teamScores[1] or 0
		local score2 = teamScores[2] or 0
		local winningTeam: number? = nil
		if score1 > score2 then
			winningTeam = 1
		elseif score2 > score1 then
			winningTeam = 2
		end
		-- nil means draw

		resultData.winningTeam = winningTeam
		resultData.winner = if winningTeam then ("Team " .. TEAM_NAMES[winningTeam]) else "Draw"
		resultData.teamScores = teamScores

		awardEndOfMatchCoins(nil, winningTeam)
	else
		local winnerName = if #standings > 0 then standings[1].name else "Nobody"
		resultData.winner = winnerName

		-- Find winner Player object for coin reward
		local winner: Player? = nil
		for _, player in matchPlayers do
			if player.Parent and player.Name == winnerName then
				winner = player
				break
			end
		end

		awardEndOfMatchCoins(winner, nil)
	end

	broadcastState(resultData)

	task.wait(RESULTS_DURATION)

	-- Clean up match data
	matchPlayers = {}
	playerStats = {}
	teamAssignments = {}
	teamScores = {}

	-- Respawn everyone for lobby
	for _, player in Players:GetPlayers() do
		spawnPlayer(player)
	end

	setState("WaitingForPlayers")
	checkPlayerCount()
end

local function onKillDuringMatch(killer: Player, victim: Player)
	if currentState ~= "InProgress" then
		return
	end

	-- Update killer stats
	local killerStats = playerStats[killer]
	if killerStats then
		killerStats.kills += 1
	end

	-- Update victim stats
	local victimStats = playerStats[victim]
	if victimStats then
		victimStats.deaths += 1
	end

	-- Update team scores
	if isTeamMode() then
		local killerTeam = teamAssignments[killer]
		if killerTeam then
			teamScores[killerTeam] = (teamScores[killerTeam] or 0) + 1
		end
	end

	-- Broadcast updated scores
	broadcastState({
		timeRemaining = matchTimeRemaining,
		standings = getStandings(),
	})

	-- Check kill threshold for early win
	local config = MODE_CONFIG[currentGameMode]
	local threshold = if config then config.killThreshold else GameConfig.KILL_THRESHOLD_FFA

	if isTeamMode() then
		-- Check if any team reached the threshold
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

local function runMatch()
	setState("InProgress")

	local config = MODE_CONFIG[currentGameMode]
	matchTimeRemaining = if config then config.matchDuration else GameConfig.MATCH_DURATION_FFA

	-- Snapshot current players into the match
	matchPlayers = {}
	playerStats = {}
	for _, player in Players:GetPlayers() do
		table.insert(matchPlayers, player)
		playerStats[player] = {
			kills = 0,
			deaths = 0,
			coinsEarned = 0,
		}
	end

	-- Assign teams for team modes
	if isTeamMode() then
		assignTeams()
	end

	-- Spawn all players fresh
	for _, player in matchPlayers do
		spawnPlayer(player)
	end

	broadcastState({
		timeRemaining = matchTimeRemaining,
		standings = getStandings(),
	})

	-- Hook up death events for respawning
	for _, player in matchPlayers do
		task.spawn(function()
			while currentState == "InProgress" and player.Parent do
				local character = player.Character or player.CharacterAdded:Wait()
				local humanoid = character:WaitForChild("Humanoid") :: Humanoid
				humanoid.Died:Wait()
				respawnAfterDelay(player)

				if currentState == "InProgress" and player.Parent then
					player.CharacterAdded:Wait()
				end
			end
		end)
	end

	-- Match timer loop
	matchLoopThread = task.spawn(function()
		while matchTimeRemaining > 0 and currentState == "InProgress" do
			task.wait(TIMER_TICK)
			matchTimeRemaining -= TIMER_TICK

			broadcastState({
				timeRemaining = matchTimeRemaining,
				standings = getStandings(),
			})
		end

		if currentState == "InProgress" then
			runResults()
		end
	end)
end

local function runCountdown()
	setState("Countdown")
	countdownRemaining = COUNTDOWN_DURATION

	while countdownRemaining > 0 do
		broadcastState({
			countdown = countdownRemaining,
		})

		task.wait(1)
		countdownRemaining -= 1

		-- If players leave during countdown and we drop below minimum, abort
		local minNeeded = MODE_CONFIG[currentGameMode].minPlayers
		if #Players:GetPlayers() < minNeeded then
			print("[GameManager] Not enough players, countdown aborted")
			setState("WaitingForPlayers")
			broadcastState({})
			return
		end
	end

	runMatch()
end

function checkPlayerCount()
	if currentState ~= "WaitingForPlayers" then
		return
	end

	-- Select the next viable game mode
	currentGameMode = selectNextMode()
	local config = MODE_CONFIG[currentGameMode]

	local playerCount = #Players:GetPlayers()
	local playersNeeded = config.minPlayers - playerCount

	broadcastState({
		playersNeeded = playersNeeded,
		currentPlayers = playerCount,
	})

	if playerCount >= config.minPlayers then
		task.spawn(runCountdown)
	end
end

------------------------------------------------------------------------
-- GetPlayerTeam BindableFunction (CombatHandler queries this)
------------------------------------------------------------------------

getPlayerTeamFunc.OnInvoke = function(player: Player): number
	return getPlayerTeam(player)
end

------------------------------------------------------------------------
-- Player lifecycle
------------------------------------------------------------------------

Players.CharacterAutoLoads = false

local function onPlayerAdded(player: Player)
	-- Spawn them immediately if we're in lobby/countdown
	if currentState == "WaitingForPlayers" or currentState == "Countdown" then
		spawnPlayer(player)
	end

	-- Notify the new player of current match state
	local stateData: { [string]: any } = {
		state = currentState,
		gameMode = currentGameMode,
		timeRemaining = if currentState == "InProgress" then matchTimeRemaining else nil,
		countdown = if currentState == "Countdown" then countdownRemaining else nil,
		standings = if currentState == "InProgress" then getStandings() else nil,
	}

	if isTeamMode() then
		stateData.teamScores = teamScores
		stateData.teamMap = getTeamMap()
	end

	Remotes.MatchStateChange:FireClient(player, stateData)

	-- If they're in a team match, tell them their team
	if isTeamMode() and teamAssignments[player] then
		Remotes.TeamAssignment:FireClient(player, {
			team = teamAssignments[player],
			teamName = TEAM_NAMES[teamAssignments[player]],
			gameMode = currentGameMode,
		})
	end

	checkPlayerCount()
end

local function onPlayerRemoving(player: Player)
	-- Remove from match tracking
	local idx = table.find(matchPlayers, player)
	if idx then
		table.remove(matchPlayers, idx)
	end
	playerStats[player] = nil
	teamAssignments[player] = nil

	-- If mid-match and not enough players remain, end early
	if currentState == "InProgress" then
		local alivePlayers = 0
		for _, p in matchPlayers do
			if p.Parent then
				alivePlayers += 1
			end
		end
		if alivePlayers < 2 then
			if matchLoopThread then
				task.cancel(matchLoopThread)
				matchLoopThread = nil
			end
			runResults()
		end
	end
end

------------------------------------------------------------------------
-- Init
------------------------------------------------------------------------

-- Listen for kills from CombatHandler via BindableEvent
onPlayerKill.Event:Connect(function(killer: Player, victim: Player)
	onKillDuringMatch(killer, victim)
end)

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- Handle players already in the server
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[GameManager] Initialized")
