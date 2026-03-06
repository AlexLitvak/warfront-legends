--!strict
--[[
	UIController (Client)
	Builds and updates the in-match HUD:
	  • Health bar       — top-left, with numerical HP
	  • Team indicator   — below health bar, shows team color/name in team modes
	  • Match timer      — top-center
	  • Team score bar   — top-center (team modes), shows Blue vs Red scores
	  • Kill feed        — top-right, recent kill entries that fade out
	  • Coin counter     — top-right below timer, with floating +N popup
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("GameConfig"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local player = Players.LocalPlayer

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

local KILL_FEED_MAX_ENTRIES = 5
local KILL_FEED_DISPLAY_TIME = 4  -- seconds before fade-out starts
local KILL_FEED_FADE_TIME = 1     -- seconds to fade out

local HEALTH_BAR_COLOR = Color3.fromRGB(80, 200, 80)
local HEALTH_BAR_LOW_COLOR = Color3.fromRGB(200, 60, 60)
local HEALTH_LOW_THRESHOLD = 0.3

local COIN_POPUP_RISE = 40   -- pixels the popup floats upward
local COIN_POPUP_DURATION = 1 -- seconds

-- Team colors
local TEAM_BLUE_COLOR = Color3.fromRGB(80, 140, 255)
local TEAM_RED_COLOR = Color3.fromRGB(255, 80, 80)
local TEAM_COLORS: { [number]: Color3 } = {
	[1] = TEAM_BLUE_COLOR,
	[2] = TEAM_RED_COLOR,
}
local TEAM_HEX: { [number]: string } = {
	[1] = "#508CFF",
	[2] = "#FF5050",
}

------------------------------------------------------------------------
-- Team state
------------------------------------------------------------------------

local currentGameMode: string = "FFA"
local myTeam: number = 0              -- 0 = FFA / unassigned
local teamMap: { [string]: number } = {} -- playerName → team number

------------------------------------------------------------------------
-- ScreenGui setup
------------------------------------------------------------------------

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "HUD"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = player:WaitForChild("PlayerGui")

------------------------------------------------------------------------
-- Health bar (top-left)
------------------------------------------------------------------------

local healthFrame = Instance.new("Frame")
healthFrame.Name = "HealthFrame"
healthFrame.AnchorPoint = Vector2.new(0, 0)
healthFrame.Position = UDim2.new(0, 20, 0, 20)
healthFrame.Size = UDim2.new(0, 220, 0, 28)
healthFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
healthFrame.BorderSizePixel = 0
healthFrame.Parent = screenGui

local healthCorner = Instance.new("UICorner")
healthCorner.CornerRadius = UDim.new(0, 6)
healthCorner.Parent = healthFrame

local healthFill = Instance.new("Frame")
healthFill.Name = "Fill"
healthFill.AnchorPoint = Vector2.new(0, 0.5)
healthFill.Position = UDim2.new(0, 3, 0.5, 0)
healthFill.Size = UDim2.new(1, -6, 1, -6)
healthFill.BackgroundColor3 = HEALTH_BAR_COLOR
healthFill.BorderSizePixel = 0
healthFill.Parent = healthFrame

local healthFillCorner = Instance.new("UICorner")
healthFillCorner.CornerRadius = UDim.new(0, 4)
healthFillCorner.Parent = healthFill

local healthText = Instance.new("TextLabel")
healthText.Name = "HPText"
healthText.Size = UDim2.new(1, 0, 1, 0)
healthText.BackgroundTransparency = 1
healthText.Text = "100 / 100"
healthText.TextColor3 = Color3.fromRGB(255, 255, 255)
healthText.TextSize = 14
healthText.Font = Enum.Font.GothamBold
healthText.TextStrokeTransparency = 0.5
healthText.Parent = healthFrame

------------------------------------------------------------------------
-- Team indicator (below health bar, hidden in FFA)
------------------------------------------------------------------------

local teamIndicator = Instance.new("Frame")
teamIndicator.Name = "TeamIndicator"
teamIndicator.Position = UDim2.new(0, 20, 0, 52)
teamIndicator.Size = UDim2.new(0, 120, 0, 24)
teamIndicator.BackgroundColor3 = TEAM_BLUE_COLOR
teamIndicator.BorderSizePixel = 0
teamIndicator.Visible = false
teamIndicator.Parent = screenGui

local teamIndicatorCorner = Instance.new("UICorner")
teamIndicatorCorner.CornerRadius = UDim.new(0, 6)
teamIndicatorCorner.Parent = teamIndicator

local teamIndicatorLabel = Instance.new("TextLabel")
teamIndicatorLabel.Name = "TeamName"
teamIndicatorLabel.Size = UDim2.new(1, 0, 1, 0)
teamIndicatorLabel.BackgroundTransparency = 1
teamIndicatorLabel.Text = "Team Blue"
teamIndicatorLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
teamIndicatorLabel.TextSize = 13
teamIndicatorLabel.Font = Enum.Font.GothamBold
teamIndicatorLabel.TextStrokeTransparency = 0.4
teamIndicatorLabel.Parent = teamIndicator

------------------------------------------------------------------------
-- Match timer (top-center)
------------------------------------------------------------------------

local timerLabel = Instance.new("TextLabel")
timerLabel.Name = "MatchTimer"
timerLabel.AnchorPoint = Vector2.new(0.5, 0)
timerLabel.Position = UDim2.new(0.5, 0, 0, 16)
timerLabel.Size = UDim2.new(0, 140, 0, 40)
timerLabel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
timerLabel.BackgroundTransparency = 0.3
timerLabel.BorderSizePixel = 0
timerLabel.Text = "8:00"
timerLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
timerLabel.TextSize = 28
timerLabel.Font = Enum.Font.GothamBold
timerLabel.TextStrokeTransparency = 0.4
timerLabel.Parent = screenGui

local timerCorner = Instance.new("UICorner")
timerCorner.CornerRadius = UDim.new(0, 8)
timerCorner.Parent = timerLabel

------------------------------------------------------------------------
-- Team score bar (top-center, below timer — visible only in team modes)
------------------------------------------------------------------------

local teamScoreBar = Instance.new("Frame")
teamScoreBar.Name = "TeamScoreBar"
teamScoreBar.AnchorPoint = Vector2.new(0.5, 0)
teamScoreBar.Position = UDim2.new(0.5, 0, 0, 60)
teamScoreBar.Size = UDim2.new(0, 260, 0, 36)
teamScoreBar.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
teamScoreBar.BackgroundTransparency = 0.3
teamScoreBar.BorderSizePixel = 0
teamScoreBar.Visible = false
teamScoreBar.Parent = screenGui

local teamScoreBarCorner = Instance.new("UICorner")
teamScoreBarCorner.CornerRadius = UDim.new(0, 8)
teamScoreBarCorner.Parent = teamScoreBar

-- Blue team score (left side)
local blueScoreLabel = Instance.new("TextLabel")
blueScoreLabel.Name = "BlueScore"
blueScoreLabel.AnchorPoint = Vector2.new(0, 0.5)
blueScoreLabel.Position = UDim2.new(0, 12, 0.5, 0)
blueScoreLabel.Size = UDim2.new(0, 70, 0, 28)
blueScoreLabel.BackgroundTransparency = 1
blueScoreLabel.Text = "Blue: 0"
blueScoreLabel.TextColor3 = TEAM_BLUE_COLOR
blueScoreLabel.TextSize = 16
blueScoreLabel.Font = Enum.Font.GothamBold
blueScoreLabel.TextXAlignment = Enum.TextXAlignment.Left
blueScoreLabel.TextStrokeTransparency = 0.4
blueScoreLabel.Parent = teamScoreBar

-- "VS" separator
local vsLabel = Instance.new("TextLabel")
vsLabel.Name = "VS"
vsLabel.AnchorPoint = Vector2.new(0.5, 0.5)
vsLabel.Position = UDim2.new(0.5, 0, 0.5, 0)
vsLabel.Size = UDim2.new(0, 40, 0, 28)
vsLabel.BackgroundTransparency = 1
vsLabel.Text = "VS"
vsLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
vsLabel.TextSize = 14
vsLabel.Font = Enum.Font.GothamBold
vsLabel.TextStrokeTransparency = 0.5
vsLabel.Parent = teamScoreBar

-- Red team score (right side)
local redScoreLabel = Instance.new("TextLabel")
redScoreLabel.Name = "RedScore"
redScoreLabel.AnchorPoint = Vector2.new(1, 0.5)
redScoreLabel.Position = UDim2.new(1, -12, 0.5, 0)
redScoreLabel.Size = UDim2.new(0, 70, 0, 28)
redScoreLabel.BackgroundTransparency = 1
redScoreLabel.Text = "Red: 0"
redScoreLabel.TextColor3 = TEAM_RED_COLOR
redScoreLabel.TextSize = 16
redScoreLabel.Font = Enum.Font.GothamBold
redScoreLabel.TextXAlignment = Enum.TextXAlignment.Right
redScoreLabel.TextStrokeTransparency = 0.4
redScoreLabel.Parent = teamScoreBar

-- Game mode label (above the score bar)
local modeLabel = Instance.new("TextLabel")
modeLabel.Name = "ModeLabel"
modeLabel.AnchorPoint = Vector2.new(0.5, 0)
modeLabel.Position = UDim2.new(0.5, 0, 0, 98)
modeLabel.Size = UDim2.new(0, 100, 0, 18)
modeLabel.BackgroundTransparency = 1
modeLabel.Text = ""
modeLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
modeLabel.TextSize = 12
modeLabel.Font = Enum.Font.GothamMedium
modeLabel.TextStrokeTransparency = 0.6
modeLabel.Visible = false
modeLabel.Parent = screenGui

------------------------------------------------------------------------
-- Coin counter (top-right)
------------------------------------------------------------------------

local coinFrame = Instance.new("Frame")
coinFrame.Name = "CoinFrame"
coinFrame.AnchorPoint = Vector2.new(1, 0)
coinFrame.Position = UDim2.new(1, -20, 0, 16)
coinFrame.Size = UDim2.new(0, 140, 0, 36)
coinFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
coinFrame.BackgroundTransparency = 0.3
coinFrame.BorderSizePixel = 0
coinFrame.Parent = screenGui

local coinCorner = Instance.new("UICorner")
coinCorner.CornerRadius = UDim.new(0, 8)
coinCorner.Parent = coinFrame

local coinIcon = Instance.new("TextLabel")
coinIcon.Name = "Icon"
coinIcon.AnchorPoint = Vector2.new(0, 0.5)
coinIcon.Position = UDim2.new(0, 10, 0.5, 0)
coinIcon.Size = UDim2.new(0, 22, 0, 22)
coinIcon.BackgroundColor3 = Color3.fromRGB(255, 200, 50)
coinIcon.BorderSizePixel = 0
coinIcon.Text = ""
coinIcon.Parent = coinFrame

local coinIconCorner = Instance.new("UICorner")
coinIconCorner.CornerRadius = UDim.new(1, 0)
coinIconCorner.Parent = coinIcon

local coinText = Instance.new("TextLabel")
coinText.Name = "Amount"
coinText.AnchorPoint = Vector2.new(0, 0.5)
coinText.Position = UDim2.new(0, 40, 0.5, 0)
coinText.Size = UDim2.new(1, -50, 1, 0)
coinText.BackgroundTransparency = 1
coinText.Text = "0"
coinText.TextColor3 = Color3.fromRGB(255, 215, 0)
coinText.TextXAlignment = Enum.TextXAlignment.Left
coinText.TextSize = 20
coinText.Font = Enum.Font.GothamBold
coinText.TextStrokeTransparency = 0.5
coinText.Parent = coinFrame

------------------------------------------------------------------------
-- Kill feed (top-right, below coin counter)
------------------------------------------------------------------------

local killFeedFrame = Instance.new("Frame")
killFeedFrame.Name = "KillFeed"
killFeedFrame.AnchorPoint = Vector2.new(1, 0)
killFeedFrame.Position = UDim2.new(1, -20, 0, 60)
killFeedFrame.Size = UDim2.new(0, 280, 0, KILL_FEED_MAX_ENTRIES * 26)
killFeedFrame.BackgroundTransparency = 1
killFeedFrame.BorderSizePixel = 0
killFeedFrame.Parent = screenGui

local killFeedLayout = Instance.new("UIListLayout")
killFeedLayout.SortOrder = Enum.SortOrder.LayoutOrder
killFeedLayout.VerticalAlignment = Enum.VerticalAlignment.Top
killFeedLayout.Padding = UDim.new(0, 4)
killFeedLayout.Parent = killFeedFrame

------------------------------------------------------------------------
-- Countdown overlay (center screen)
------------------------------------------------------------------------

local countdownLabel = Instance.new("TextLabel")
countdownLabel.Name = "Countdown"
countdownLabel.AnchorPoint = Vector2.new(0.5, 0.5)
countdownLabel.Position = UDim2.new(0.5, 0, 0.4, 0)
countdownLabel.Size = UDim2.new(0, 300, 0, 100)
countdownLabel.BackgroundTransparency = 1
countdownLabel.Text = ""
countdownLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
countdownLabel.TextSize = 72
countdownLabel.Font = Enum.Font.GothamBold
countdownLabel.TextStrokeTransparency = 0.3
countdownLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
countdownLabel.Visible = false
countdownLabel.Parent = screenGui

------------------------------------------------------------------------
-- Status label (center, for "Waiting for players", etc.)
------------------------------------------------------------------------

local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "StatusLabel"
statusLabel.AnchorPoint = Vector2.new(0.5, 0.5)
statusLabel.Position = UDim2.new(0.5, 0, 0.35, 0)
statusLabel.Size = UDim2.new(0, 400, 0, 50)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = ""
statusLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
statusLabel.TextSize = 24
statusLabel.Font = Enum.Font.GothamMedium
statusLabel.TextStrokeTransparency = 0.5
statusLabel.Visible = false
statusLabel.Parent = screenGui

------------------------------------------------------------------------
-- Team assignment notification (center, brief flash)
------------------------------------------------------------------------

local teamNotifyLabel = Instance.new("TextLabel")
teamNotifyLabel.Name = "TeamNotify"
teamNotifyLabel.AnchorPoint = Vector2.new(0.5, 0.5)
teamNotifyLabel.Position = UDim2.new(0.5, 0, 0.25, 0)
teamNotifyLabel.Size = UDim2.new(0, 400, 0, 50)
teamNotifyLabel.BackgroundTransparency = 1
teamNotifyLabel.Text = ""
teamNotifyLabel.TextColor3 = TEAM_BLUE_COLOR
teamNotifyLabel.TextSize = 30
teamNotifyLabel.Font = Enum.Font.GothamBold
teamNotifyLabel.TextStrokeTransparency = 0.3
teamNotifyLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
teamNotifyLabel.Visible = false
teamNotifyLabel.Parent = screenGui

------------------------------------------------------------------------
-- Health bar updates
------------------------------------------------------------------------

local function formatTime(seconds: number): string
	local mins = math.floor(seconds / 60)
	local secs = seconds % 60
	return string.format("%d:%02d", mins, secs)
end

local function updateHealthBar()
	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local health = humanoid.Health
	local maxHealth = humanoid.MaxHealth
	local fraction = math.clamp(health / maxHealth, 0, 1)

	-- Tween the fill width
	TweenService:Create(healthFill, TweenInfo.new(0.2), {
		Size = UDim2.new(fraction, -6, 1, -6),
	}):Play()

	-- Color: green → red when low
	local barColor = if fraction <= HEALTH_LOW_THRESHOLD then HEALTH_BAR_LOW_COLOR else HEALTH_BAR_COLOR
	TweenService:Create(healthFill, TweenInfo.new(0.3), {
		BackgroundColor3 = barColor,
	}):Play()

	healthText.Text = string.format("%d / %d", math.ceil(health), maxHealth)
end

-- Reconnect health listener each time the character spawns
local healthConnection: RBXScriptConnection? = nil

local function onCharacterAdded(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid

	if healthConnection then
		healthConnection:Disconnect()
	end
	healthConnection = humanoid.HealthChanged:Connect(updateHealthBar)
	updateHealthBar()
end

if player.Character then
	task.spawn(onCharacterAdded, player.Character)
end
player.CharacterAdded:Connect(onCharacterAdded)

------------------------------------------------------------------------
-- Team UI helpers
------------------------------------------------------------------------

local function isTeamMode(): boolean
	return currentGameMode == "2v2" or currentGameMode == "3v3"
end

local function updateTeamScores(scores: { [string]: any }?)
	if not scores then
		return
	end
	local blueScore = 0
	local redScore = 0
	-- scores might be keyed by number or string depending on serialization
	for k, v in scores :: any do
		local teamNum = tonumber(k)
		if teamNum == 1 then
			blueScore = v
		elseif teamNum == 2 then
			redScore = v
		end
	end
	blueScoreLabel.Text = "Blue: " .. tostring(blueScore)
	redScoreLabel.Text = "Red: " .. tostring(redScore)
end

local function showTeamUI()
	teamScoreBar.Visible = true
	modeLabel.Visible = true
	modeLabel.Text = currentGameMode

	if myTeam > 0 then
		teamIndicator.Visible = true
		local teamColor = TEAM_COLORS[myTeam] or TEAM_BLUE_COLOR
		teamIndicator.BackgroundColor3 = teamColor
		teamIndicatorLabel.Text = if myTeam == 1 then "Team Blue" else "Team Red"
	end
end

local function hideTeamUI()
	teamScoreBar.Visible = false
	teamIndicator.Visible = false
	modeLabel.Visible = false
end

------------------------------------------------------------------------
-- Kill feed
------------------------------------------------------------------------

local killFeedOrder = 0

local function addKillFeedEntry(killerName: string, victimName: string, weapon: string)
	killFeedOrder += 1

	local entry = Instance.new("TextLabel")
	entry.Name = "KillEntry"
	entry.LayoutOrder = killFeedOrder
	entry.Size = UDim2.new(1, 0, 0, 22)
	entry.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	entry.BackgroundTransparency = 0.5
	entry.BorderSizePixel = 0
	entry.TextSize = 13
	entry.Font = Enum.Font.GothamMedium
	entry.TextStrokeTransparency = 0.6
	entry.TextXAlignment = Enum.TextXAlignment.Right
	entry.RichText = true
	entry.Parent = killFeedFrame

	local entryCorner = Instance.new("UICorner")
	entryCorner.CornerRadius = UDim.new(0, 4)
	entryCorner.Parent = entry

	-- Color names: gold for local player, team color in team mode, white otherwise
	local function styleName(name: string): string
		if name == player.Name then
			return string.format('<font color="#FFD700"><b>%s</b></font>', name)
		end
		if isTeamMode() then
			local nameTeam = teamMap[name]
			if nameTeam and TEAM_HEX[nameTeam] then
				return string.format('<font color="%s">%s</font>', TEAM_HEX[nameTeam], name)
			end
		end
		return string.format('<font color="#FFFFFF">%s</font>', name)
	end

	entry.Text = string.format(
		'%s <font color="#FF4444">eliminated</font> %s  ',
		styleName(killerName),
		styleName(victimName)
	)
	entry.TextColor3 = Color3.fromRGB(200, 200, 200)

	-- Pad right
	local padding = Instance.new("UIPadding")
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = entry

	-- Fade out after delay
	task.delay(KILL_FEED_DISPLAY_TIME, function()
		local fadeOut = TweenService:Create(entry, TweenInfo.new(KILL_FEED_FADE_TIME), {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
			BackgroundTransparency = 1,
		})
		fadeOut:Play()
		fadeOut.Completed:Wait()
		entry:Destroy()
	end)

	-- Trim old entries if over max
	local children = killFeedFrame:GetChildren()
	local entries = {}
	for _, child in children do
		if child:IsA("TextLabel") then
			table.insert(entries, child)
		end
	end
	if #entries > KILL_FEED_MAX_ENTRIES then
		table.sort(entries, function(a, b)
			return a.LayoutOrder < b.LayoutOrder
		end)
		entries[1]:Destroy()
	end
end

------------------------------------------------------------------------
-- Coin popup animation
------------------------------------------------------------------------

local function playCoinPopup(amount: number, reason: string)
	local popup = Instance.new("TextLabel")
	popup.Name = "CoinPopup"
	popup.AnchorPoint = Vector2.new(1, 0)
	popup.Position = UDim2.new(1, -20, 0, 52)
	popup.Size = UDim2.new(0, 100, 0, 24)
	popup.BackgroundTransparency = 1
	popup.TextColor3 = Color3.fromRGB(255, 220, 50)
	popup.TextSize = 18
	popup.Font = Enum.Font.GothamBold
	popup.TextStrokeTransparency = 0.4
	popup.TextXAlignment = Enum.TextXAlignment.Right
	popup.Text = string.format("+%d", amount)
	popup.Parent = screenGui

	-- Float up and fade out
	local targetPos = UDim2.new(1, -20, 0, 52 - COIN_POPUP_RISE)
	local tweenInfo = TweenInfo.new(COIN_POPUP_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	local moveTween = TweenService:Create(popup, tweenInfo, { Position = targetPos })
	local fadeTween = TweenService:Create(popup, TweenInfo.new(COIN_POPUP_DURATION * 0.6, Enum.EasingStyle.Linear, Enum.EasingDirection.In, 0, false, COIN_POPUP_DURATION * 0.4), {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	})

	moveTween:Play()
	fadeTween:Play()

	fadeTween.Completed:Once(function()
		popup:Destroy()
	end)
end

------------------------------------------------------------------------
-- Match state handling
------------------------------------------------------------------------

local currentMatchState = "WaitingForPlayers"

local function onMatchStateChange(data: { [string]: any })
	local state = data.state :: string?
	if state then
		currentMatchState = state
	end

	-- Track game mode
	local mode = data.gameMode :: string?
	if mode then
		currentGameMode = mode
	end

	-- Track team map for kill feed coloring
	if data.teamMap ~= nil then
		-- Rebuild teamMap from the data (keys might be strings)
		teamMap = {}
		for name, teamNum in data.teamMap :: any do
			teamMap[name] = teamNum
		end
	end

	-- Update team scores
	if data.teamScores ~= nil then
		updateTeamScores(data.teamScores)
	end

	-- Timer
	if data.timeRemaining ~= nil then
		local t = math.max(0, math.floor(data.timeRemaining :: number))
		timerLabel.Text = formatTime(t)
		timerLabel.Visible = true

		-- Flash red in final 30 seconds
		if t <= 30 then
			timerLabel.TextColor3 = Color3.fromRGB(255, 80, 80)
		else
			timerLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		end
	end

	-- Countdown
	if currentMatchState == "Countdown" then
		countdownLabel.Visible = true
		statusLabel.Visible = false
		if data.countdown ~= nil then
			countdownLabel.Text = tostring(math.ceil(data.countdown :: number))
		end
		timerLabel.Visible = false
		hideTeamUI()

		-- Show mode during countdown
		if isTeamMode() then
			modeLabel.Visible = true
			modeLabel.Text = currentGameMode
		end
	elseif currentMatchState == "InProgress" then
		countdownLabel.Visible = false
		statusLabel.Visible = false
		timerLabel.Visible = true

		if isTeamMode() then
			showTeamUI()
		else
			hideTeamUI()
		end
	elseif currentMatchState == "WaitingForPlayers" then
		countdownLabel.Visible = false
		timerLabel.Visible = false
		statusLabel.Visible = true
		hideTeamUI()
		myTeam = 0
		teamMap = {}

		if data.playersNeeded ~= nil and (data.playersNeeded :: number) > 0 then
			local modeStr = if isTeamMode() then string.format(" (%s)", currentGameMode) else ""
			statusLabel.Text = string.format("Waiting for %d more player%s%s...",
				data.playersNeeded :: number,
				if (data.playersNeeded :: number) == 1 then "" else "s",
				modeStr
			)
		else
			statusLabel.Text = "Starting soon..."
		end
		statusLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
	elseif currentMatchState == "Results" then
		countdownLabel.Visible = false
		timerLabel.Visible = false
		statusLabel.Visible = true

		if data.winner then
			local winnerStr = data.winner :: string
			statusLabel.Text = string.format("%s wins!", winnerStr)

			-- Color the result text by winning team
			if isTeamMode() and data.winningTeam ~= nil then
				local wt = data.winningTeam :: number
				statusLabel.TextColor3 = TEAM_COLORS[wt] or Color3.fromRGB(255, 215, 0)
			else
				statusLabel.TextColor3 = Color3.fromRGB(255, 215, 0)
			end
		end

		-- Keep team score bar visible during results
		if isTeamMode() then
			teamScoreBar.Visible = true
			if data.teamScores then
				updateTeamScores(data.teamScores)
			end
		end
	end
end

------------------------------------------------------------------------
-- Team assignment handler
------------------------------------------------------------------------

Remotes.TeamAssignment.OnClientEvent:Connect(function(data: { [string]: any })
	local team = data.team :: number?
	local teamName = data.teamName :: string?

	if team then
		myTeam = team
	end

	-- Show team notification briefly
	if team and teamName then
		local teamColor = TEAM_COLORS[team] or TEAM_BLUE_COLOR
		teamNotifyLabel.TextColor3 = teamColor
		teamNotifyLabel.Text = string.format("You are on Team %s!", teamName)
		teamNotifyLabel.TextTransparency = 0
		teamNotifyLabel.TextStrokeTransparency = 0.3
		teamNotifyLabel.Visible = true

		-- Update team indicator
		teamIndicator.BackgroundColor3 = teamColor
		teamIndicatorLabel.Text = "Team " .. teamName
		teamIndicator.Visible = true

		-- Fade out the notification after a delay
		task.delay(3, function()
			local fadeOut = TweenService:Create(teamNotifyLabel, TweenInfo.new(1), {
				TextTransparency = 1,
				TextStrokeTransparency = 1,
			})
			fadeOut:Play()
			fadeOut.Completed:Once(function()
				teamNotifyLabel.Visible = false
			end)
		end)
	end
end)

------------------------------------------------------------------------
-- Coin balance tracking
------------------------------------------------------------------------

local coinBalance = 0

local function onCoinUpdate(data: { [string]: any })
	local amount = (data.amount :: number?) or 0
	local reason = (data.reason :: string?) or ""
	local newBalance = data.newBalance :: number?

	if newBalance ~= nil then
		coinBalance = newBalance
	else
		coinBalance += amount
	end

	coinText.Text = tostring(coinBalance)

	-- Show popup for actual coin gains (not the initial load)
	if amount > 0 and reason ~= "Init" then
		playCoinPopup(amount, reason)
	end
end

------------------------------------------------------------------------
-- Connect remote events
------------------------------------------------------------------------

Remotes.MatchStateChange.OnClientEvent:Connect(onMatchStateChange)

Remotes.KillNotification.OnClientEvent:Connect(function(data: { [string]: any })
	addKillFeedEntry(
		(data.killerName :: string?) or "???",
		(data.victimName :: string?) or "???",
		(data.weapon :: string?) or "Sword"
	)
end)

Remotes.CoinUpdate.OnClientEvent:Connect(onCoinUpdate)

print("[UIController] Initialized")
