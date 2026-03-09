--!strict
--[[
	MainMenuUI (Client)
	Full player-facing menu flow:
	  • Main Menu — title, Play / Shop / Leaderboard buttons, coin balance
	  • Mode Selection — FFA / 2v2 / 3v3 with live queue counts
	  • Queue Screen — "Searching..." with cancel button
	  • Countdown Screen — 5, 4, 3, 2, 1, FIGHT! + arena name
	  • Results Screen — standings, personal stats, coin breakdown, play again

	All screens are Frames inside one ScreenGui. TweenService handles
	smooth fade transitions between screens.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local player = Players.LocalPlayer

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

local BG_COLOR = Color3.fromRGB(18, 18, 24)
local CARD_COLOR = Color3.fromRGB(28, 28, 38)
local GOLD = Color3.fromRGB(255, 215, 0)
local WHITE = Color3.fromRGB(255, 255, 255)
local GREY = Color3.fromRGB(160, 160, 170)
local RED = Color3.fromRGB(255, 80, 80)
local GREEN = Color3.fromRGB(80, 200, 80)
local BLUE = Color3.fromRGB(80, 140, 255)
local DARK_OVERLAY = Color3.fromRGB(0, 0, 0)

local TEAM_BLUE = Color3.fromRGB(80, 140, 255)
local TEAM_RED = Color3.fromRGB(255, 80, 80)

local FADE_TIME = 0.3
local DOTS_INTERVAL = 0.5

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------

local currentScreen = "None"
local coinBalance = 0
local queuedMode: string? = nil
local queueCount = 0
local queueNeeded = 0
local lastMode: string? = nil
local dotsThread: thread? = nil

------------------------------------------------------------------------
-- ScreenGui
------------------------------------------------------------------------

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "MainMenuUI"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.DisplayOrder = 5
screenGui.Parent = player:WaitForChild("PlayerGui")

------------------------------------------------------------------------
-- Utility: create common UI elements
------------------------------------------------------------------------

local function makeCorner(parent: GuiObject, radius: number?)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or 8)
	corner.Parent = parent
end

local function makeStroke(parent: GuiObject, color: Color3?, thickness: number?)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color or GOLD
	stroke.Thickness = thickness or 1.5
	stroke.Parent = parent
end

local function makeButton(props: {
	name: string,
	text: string,
	size: UDim2,
	position: UDim2,
	bgColor: Color3?,
	textColor: Color3?,
	textSize: number?,
	parent: GuiObject,
	anchorPoint: Vector2?,
}): TextButton
	local btn = Instance.new("TextButton")
	btn.Name = props.name
	btn.AnchorPoint = props.anchorPoint or Vector2.new(0.5, 0.5)
	btn.Position = props.position
	btn.Size = props.size
	btn.BackgroundColor3 = props.bgColor or GOLD
	btn.BorderSizePixel = 0
	btn.Text = props.text
	btn.TextColor3 = props.textColor or Color3.fromRGB(20, 20, 20)
	btn.TextSize = props.textSize or 20
	btn.Font = Enum.Font.GothamBold
	btn.AutoButtonColor = true
	btn.Parent = props.parent
	makeCorner(btn, 10)
	return btn
end

local function makeLabel(props: {
	name: string,
	text: string,
	size: UDim2,
	position: UDim2,
	textColor: Color3?,
	textSize: number?,
	font: Enum.Font?,
	parent: GuiObject,
	anchorPoint: Vector2?,
	xAlign: Enum.TextXAlignment?,
}): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = props.name
	label.AnchorPoint = props.anchorPoint or Vector2.new(0.5, 0.5)
	label.Position = props.position
	label.Size = props.size
	label.BackgroundTransparency = 1
	label.Text = props.text
	label.TextColor3 = props.textColor or WHITE
	label.TextSize = props.textSize or 18
	label.Font = props.font or Enum.Font.GothamBold
	label.TextXAlignment = props.xAlign or Enum.TextXAlignment.Center
	label.Parent = props.parent
	return label
end

------------------------------------------------------------------------
-- Screen container (holds all screens as children)
------------------------------------------------------------------------

local container = Instance.new("Frame")
container.Name = "Container"
container.Size = UDim2.new(1, 0, 1, 0)
container.BackgroundTransparency = 1
container.Parent = screenGui

------------------------------------------------------------------------
-- Transition helpers
------------------------------------------------------------------------

local screens: { [string]: Frame } = {}

-- Forward declarations for dots animation (defined after Queue screen UI)
local startDots: () -> ()
local stopDots: () -> ()

local function hideAllScreens()
	for _, frame in screens do
		frame.Visible = false
		frame.BackgroundTransparency = 1
	end
end

local function showScreen(name: string)
	if currentScreen == name then
		return
	end

	-- Fade out current
	local current = screens[currentScreen]
	if current then
		local fadeOut = TweenService:Create(current, TweenInfo.new(FADE_TIME), {
			BackgroundTransparency = 1,
		})
		fadeOut:Play()
		fadeOut.Completed:Once(function()
			current.Visible = false
		end)
	end

	-- Fade in new
	local target = screens[name]
	if target then
		target.Visible = true
		target.BackgroundTransparency = 1

		-- Make children visible with slight delay for polish
		TweenService:Create(target, TweenInfo.new(FADE_TIME), {
			BackgroundTransparency = 0,
		}):Play()
	end

	currentScreen = name

	-- Screen-specific side effects
	if name == "Queue" then
		startDots()
	else
		stopDots()
	end
end

------------------------------------------------------------------------
-- SCREEN: Main Menu
------------------------------------------------------------------------

local mainMenu = Instance.new("Frame")
mainMenu.Name = "MainMenu"
mainMenu.Size = UDim2.new(1, 0, 1, 0)
mainMenu.BackgroundColor3 = BG_COLOR
mainMenu.BackgroundTransparency = 0
mainMenu.BorderSizePixel = 0
mainMenu.Visible = false
mainMenu.Parent = container
screens["MainMenu"] = mainMenu

-- Dark gradient overlay for depth
local gradient = Instance.new("UIGradient")
gradient.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(30, 25, 40)),
	ColorSequenceKeypoint.new(0.5, Color3.fromRGB(18, 18, 24)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(12, 12, 18)),
})
gradient.Rotation = 160
gradient.Parent = mainMenu

-- Title
local titleLabel = makeLabel({
	name = "Title",
	text = "WARFRONT LEGENDS",
	size = UDim2.new(0, 600, 0, 80),
	position = UDim2.new(0.5, 0, 0.18, 0),
	textColor = GOLD,
	textSize = 48,
	font = Enum.Font.GothamBlack,
	parent = mainMenu,
})
titleLabel.TextStrokeTransparency = 0.5
titleLabel.TextStrokeColor3 = Color3.fromRGB(80, 60, 0)

-- Subtitle
makeLabel({
	name = "Subtitle",
	text = "Arena Combat",
	size = UDim2.new(0, 300, 0, 30),
	position = UDim2.new(0.5, 0, 0.24, 0),
	textColor = GREY,
	textSize = 16,
	font = Enum.Font.GothamMedium,
	parent = mainMenu,
})

-- Play button (large, centered)
local playBtn = makeButton({
	name = "PlayBtn",
	text = "PLAY",
	size = UDim2.new(0, 280, 0, 60),
	position = UDim2.new(0.5, 0, 0.45, 0),
	bgColor = GOLD,
	textSize = 28,
	parent = mainMenu,
})
makeStroke(playBtn, Color3.fromRGB(200, 170, 0), 2)

-- Shop button
local shopBtn = makeButton({
	name = "ShopBtn",
	text = "SHOP",
	size = UDim2.new(0, 280, 0, 48),
	position = UDim2.new(0.5, 0, 0.56, 0),
	bgColor = CARD_COLOR,
	textColor = WHITE,
	textSize = 20,
	parent = mainMenu,
})
makeStroke(shopBtn, GREY, 1)

-- Leaderboard button
local leaderboardBtn = makeButton({
	name = "LeaderboardBtn",
	text = "LEADERBOARD",
	size = UDim2.new(0, 280, 0, 48),
	position = UDim2.new(0.5, 0, 0.65, 0),
	bgColor = CARD_COLOR,
	textColor = WHITE,
	textSize = 20,
	parent = mainMenu,
})
makeStroke(leaderboardBtn, GREY, 1)

-- Coin display (top-right)
local menuCoinFrame = Instance.new("Frame")
menuCoinFrame.Name = "CoinDisplay"
menuCoinFrame.AnchorPoint = Vector2.new(1, 0)
menuCoinFrame.Position = UDim2.new(1, -24, 0, 24)
menuCoinFrame.Size = UDim2.new(0, 150, 0, 36)
menuCoinFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
menuCoinFrame.BorderSizePixel = 0
menuCoinFrame.Parent = mainMenu
makeCorner(menuCoinFrame, 8)
makeStroke(menuCoinFrame, GOLD, 1)

local menuCoinIcon = Instance.new("Frame")
menuCoinIcon.Name = "Icon"
menuCoinIcon.AnchorPoint = Vector2.new(0, 0.5)
menuCoinIcon.Position = UDim2.new(0, 10, 0.5, 0)
menuCoinIcon.Size = UDim2.new(0, 18, 0, 18)
menuCoinIcon.BackgroundColor3 = Color3.fromRGB(255, 200, 50)
menuCoinIcon.BorderSizePixel = 0
menuCoinIcon.Parent = menuCoinFrame
makeCorner(menuCoinIcon, 9)

local menuCoinLabel = makeLabel({
	name = "Amount",
	text = "0",
	size = UDim2.new(1, -40, 1, 0),
	position = UDim2.new(0, 36, 0.5, 0),
	textColor = GOLD,
	textSize = 18,
	font = Enum.Font.GothamBold,
	parent = menuCoinFrame,
	anchorPoint = Vector2.new(0, 0.5),
	xAlign = Enum.TextXAlignment.Left,
})

-- Version label (bottom)
makeLabel({
	name = "Version",
	text = "MVP v1.0",
	size = UDim2.new(0, 200, 0, 20),
	position = UDim2.new(0.5, 0, 0.95, 0),
	textColor = Color3.fromRGB(80, 80, 90),
	textSize = 12,
	font = Enum.Font.Gotham,
	parent = mainMenu,
})

------------------------------------------------------------------------
-- SCREEN: Mode Selection
------------------------------------------------------------------------

local modeSelect = Instance.new("Frame")
modeSelect.Name = "ModeSelect"
modeSelect.Size = UDim2.new(1, 0, 1, 0)
modeSelect.BackgroundColor3 = BG_COLOR
modeSelect.BackgroundTransparency = 1
modeSelect.BorderSizePixel = 0
modeSelect.Visible = false
modeSelect.Parent = container
screens["ModeSelect"] = modeSelect

-- Semi-transparent overlay
local modeOverlay = Instance.new("Frame")
modeOverlay.Name = "Overlay"
modeOverlay.Size = UDim2.new(1, 0, 1, 0)
modeOverlay.BackgroundColor3 = DARK_OVERLAY
modeOverlay.BackgroundTransparency = 0.4
modeOverlay.BorderSizePixel = 0
modeOverlay.Parent = modeSelect

-- Selection panel
local modePanel = Instance.new("Frame")
modePanel.Name = "Panel"
modePanel.AnchorPoint = Vector2.new(0.5, 0.5)
modePanel.Position = UDim2.new(0.5, 0, 0.45, 0)
modePanel.Size = UDim2.new(0, 500, 0, 360)
modePanel.BackgroundColor3 = CARD_COLOR
modePanel.BorderSizePixel = 0
modePanel.Parent = modeSelect
makeCorner(modePanel, 14)
makeStroke(modePanel, GOLD, 2)

makeLabel({
	name = "Title",
	text = "SELECT MODE",
	size = UDim2.new(1, 0, 0, 40),
	position = UDim2.new(0.5, 0, 0, 28),
	textColor = GOLD,
	textSize = 26,
	font = Enum.Font.GothamBold,
	parent = modePanel,
})

-- Mode data for buttons
local MODES = {
	{ id = "FFA", label = "Free-for-All", desc = "8 players, last one standing", needed = 8, color = GOLD },
	{ id = "2v2", label = "Team 2v2", desc = "2 vs 2, team kills win", needed = 4, color = BLUE },
	{ id = "3v3", label = "Team 3v3", desc = "3 vs 3, team kills win", needed = 6, color = RED },
}

-- Store references for live queue count updates
local modeQueueLabels: { [string]: TextLabel } = {}

for i, mode in MODES do
	local yPos = 70 + (i - 1) * 90

	local modeCard = Instance.new("Frame")
	modeCard.Name = mode.id .. "Card"
	modeCard.AnchorPoint = Vector2.new(0.5, 0)
	modeCard.Position = UDim2.new(0.5, 0, 0, yPos)
	modeCard.Size = UDim2.new(0.85, 0, 0, 76)
	modeCard.BackgroundColor3 = Color3.fromRGB(38, 38, 50)
	modeCard.BorderSizePixel = 0
	modeCard.Parent = modePanel
	makeCorner(modeCard, 10)

	-- Left color bar
	local colorBar = Instance.new("Frame")
	colorBar.Name = "ColorBar"
	colorBar.Size = UDim2.new(0, 5, 1, -8)
	colorBar.Position = UDim2.new(0, 4, 0, 4)
	colorBar.BackgroundColor3 = mode.color
	colorBar.BorderSizePixel = 0
	colorBar.Parent = modeCard
	makeCorner(colorBar, 3)

	-- Mode name
	makeLabel({
		name = "Name",
		text = mode.label,
		size = UDim2.new(0.6, 0, 0, 24),
		position = UDim2.new(0, 24, 0, 18),
		textColor = WHITE,
		textSize = 18,
		font = Enum.Font.GothamBold,
		parent = modeCard,
		anchorPoint = Vector2.new(0, 0),
		xAlign = Enum.TextXAlignment.Left,
	})

	-- Description
	makeLabel({
		name = "Desc",
		text = mode.desc,
		size = UDim2.new(0.6, 0, 0, 18),
		position = UDim2.new(0, 24, 0, 44),
		textColor = GREY,
		textSize = 13,
		font = Enum.Font.Gotham,
		parent = modeCard,
		anchorPoint = Vector2.new(0, 0),
		xAlign = Enum.TextXAlignment.Left,
	})

	-- Queue count label (right side)
	local queueLabel = makeLabel({
		name = "QueueCount",
		text = "0/" .. mode.needed .. " players",
		size = UDim2.new(0, 120, 0, 20),
		position = UDim2.new(1, -16, 0.5, 0),
		textColor = GREY,
		textSize = 13,
		font = Enum.Font.GothamMedium,
		parent = modeCard,
		anchorPoint = Vector2.new(1, 0.5),
		xAlign = Enum.TextXAlignment.Right,
	})
	modeQueueLabels[mode.id] = queueLabel

	-- Click handler (whole card is clickable via invisible button)
	local modeBtn = Instance.new("TextButton")
	modeBtn.Name = "ClickArea"
	modeBtn.Size = UDim2.new(1, 0, 1, 0)
	modeBtn.BackgroundTransparency = 1
	modeBtn.Text = ""
	modeBtn.Parent = modeCard

	-- Hover effect
	modeCard.MouseEnter:Connect(function()
		TweenService:Create(modeCard, TweenInfo.new(0.15), {
			BackgroundColor3 = Color3.fromRGB(50, 50, 65),
		}):Play()
	end)
	modeCard.MouseLeave:Connect(function()
		TweenService:Create(modeCard, TweenInfo.new(0.15), {
			BackgroundColor3 = Color3.fromRGB(38, 38, 50),
		}):Play()
	end)

	modeBtn.MouseButton1Click:Connect(function()
		queuedMode = mode.id
		Remotes.JoinQueue:FireServer({ mode = mode.id })
		showScreen("Queue")
	end)
end

-- Back button
local modeBackBtn = makeButton({
	name = "BackBtn",
	text = "BACK",
	size = UDim2.new(0, 120, 0, 38),
	position = UDim2.new(0.5, 0, 1, -20),
	bgColor = Color3.fromRGB(60, 60, 70),
	textColor = WHITE,
	textSize = 16,
	parent = modePanel,
})

modeBackBtn.MouseButton1Click:Connect(function()
	showScreen("MainMenu")
end)

------------------------------------------------------------------------
-- SCREEN: Queue (Searching for match)
------------------------------------------------------------------------

local queueScreen = Instance.new("Frame")
queueScreen.Name = "QueueScreen"
queueScreen.Size = UDim2.new(1, 0, 1, 0)
queueScreen.BackgroundColor3 = BG_COLOR
queueScreen.BackgroundTransparency = 1
queueScreen.BorderSizePixel = 0
queueScreen.Visible = false
queueScreen.Parent = container
screens["Queue"] = queueScreen

local queuePanel = Instance.new("Frame")
queuePanel.Name = "Panel"
queuePanel.AnchorPoint = Vector2.new(0.5, 0.5)
queuePanel.Position = UDim2.new(0.5, 0, 0.45, 0)
queuePanel.Size = UDim2.new(0, 400, 0, 240)
queuePanel.BackgroundColor3 = CARD_COLOR
queuePanel.BorderSizePixel = 0
queuePanel.Parent = queueScreen
makeCorner(queuePanel, 14)
makeStroke(queuePanel, GOLD, 2)

local searchLabel = makeLabel({
	name = "SearchText",
	text = "Searching for match",
	size = UDim2.new(0.9, 0, 0, 36),
	position = UDim2.new(0.5, 0, 0.25, 0),
	textColor = WHITE,
	textSize = 24,
	font = Enum.Font.GothamBold,
	parent = queuePanel,
})

local queueModeLabel = makeLabel({
	name = "ModeLabel",
	text = "Free-for-All",
	size = UDim2.new(0.9, 0, 0, 24),
	position = UDim2.new(0.5, 0, 0.45, 0),
	textColor = GOLD,
	textSize = 16,
	font = Enum.Font.GothamMedium,
	parent = queuePanel,
})

local queueCountLabel = makeLabel({
	name = "QueueCount",
	text = "0/8 players in queue",
	size = UDim2.new(0.9, 0, 0, 22),
	position = UDim2.new(0.5, 0, 0.58, 0),
	textColor = GREY,
	textSize = 14,
	font = Enum.Font.Gotham,
	parent = queuePanel,
})

local cancelBtn = makeButton({
	name = "CancelBtn",
	text = "CANCEL",
	size = UDim2.new(0, 160, 0, 42),
	position = UDim2.new(0.5, 0, 0.82, 0),
	bgColor = Color3.fromRGB(180, 50, 50),
	textColor = WHITE,
	textSize = 18,
	parent = queuePanel,
})

cancelBtn.MouseButton1Click:Connect(function()
	Remotes.LeaveQueue:FireServer()
	queuedMode = nil
	showScreen("MainMenu")
end)

-- Animated dots
startDots = function()
	if dotsThread then
		task.cancel(dotsThread)
	end
	dotsThread = task.spawn(function()
		local dots = 0
		while true do
			dots = (dots % 3) + 1
			searchLabel.Text = "Searching for match" .. string.rep(".", dots)
			task.wait(DOTS_INTERVAL)
		end
	end)
end

stopDots = function()
	if dotsThread then
		task.cancel(dotsThread)
		dotsThread = nil
	end
end

------------------------------------------------------------------------
-- SCREEN: Countdown
------------------------------------------------------------------------

local countdownScreen = Instance.new("Frame")
countdownScreen.Name = "CountdownScreen"
countdownScreen.Size = UDim2.new(1, 0, 1, 0)
countdownScreen.BackgroundColor3 = DARK_OVERLAY
countdownScreen.BackgroundTransparency = 1
countdownScreen.BorderSizePixel = 0
countdownScreen.Visible = false
countdownScreen.Parent = container
screens["Countdown"] = countdownScreen

local countdownNumber = makeLabel({
	name = "Number",
	text = "5",
	size = UDim2.new(0, 300, 0, 150),
	position = UDim2.new(0.5, 0, 0.38, 0),
	textColor = WHITE,
	textSize = 120,
	font = Enum.Font.GothamBlack,
	parent = countdownScreen,
})
countdownNumber.TextStrokeTransparency = 0.3
countdownNumber.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)

local countdownArena = makeLabel({
	name = "ArenaName",
	text = "",
	size = UDim2.new(0, 400, 0, 30),
	position = UDim2.new(0.5, 0, 0.55, 0),
	textColor = GOLD,
	textSize = 20,
	font = Enum.Font.GothamMedium,
	parent = countdownScreen,
})

------------------------------------------------------------------------
-- SCREEN: Results
------------------------------------------------------------------------

local resultsScreen = Instance.new("Frame")
resultsScreen.Name = "ResultsScreen"
resultsScreen.Size = UDim2.new(1, 0, 1, 0)
resultsScreen.BackgroundColor3 = BG_COLOR
resultsScreen.BackgroundTransparency = 1
resultsScreen.BorderSizePixel = 0
resultsScreen.Visible = false
resultsScreen.Parent = container
screens["Results"] = resultsScreen

-- Results panel
local resultsPanel = Instance.new("Frame")
resultsPanel.Name = "Panel"
resultsPanel.AnchorPoint = Vector2.new(0.5, 0.5)
resultsPanel.Position = UDim2.new(0.5, 0, 0.45, 0)
resultsPanel.Size = UDim2.new(0, 600, 0, 520)
resultsPanel.BackgroundColor3 = CARD_COLOR
resultsPanel.BorderSizePixel = 0
resultsPanel.Parent = resultsScreen
makeCorner(resultsPanel, 14)
makeStroke(resultsPanel, GOLD, 2)

local resultsTitle = makeLabel({
	name = "Title",
	text = "MATCH RESULTS",
	size = UDim2.new(1, 0, 0, 40),
	position = UDim2.new(0.5, 0, 0, 24),
	textColor = GOLD,
	textSize = 26,
	font = Enum.Font.GothamBold,
	parent = resultsPanel,
})

local winnerLabel = makeLabel({
	name = "Winner",
	text = "",
	size = UDim2.new(1, 0, 0, 30),
	position = UDim2.new(0.5, 0, 0, 56),
	textColor = WHITE,
	textSize = 20,
	font = Enum.Font.GothamBold,
	parent = resultsPanel,
})

-- Standings list container
local standingsFrame = Instance.new("ScrollingFrame")
standingsFrame.Name = "Standings"
standingsFrame.AnchorPoint = Vector2.new(0.5, 0)
standingsFrame.Position = UDim2.new(0.5, 0, 0, 90)
standingsFrame.Size = UDim2.new(0.9, 0, 0, 180)
standingsFrame.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
standingsFrame.BorderSizePixel = 0
standingsFrame.ScrollBarThickness = 4
standingsFrame.ScrollBarImageColor3 = GOLD
standingsFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
standingsFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
standingsFrame.Parent = resultsPanel
makeCorner(standingsFrame, 8)

local standingsLayout = Instance.new("UIListLayout")
standingsLayout.SortOrder = Enum.SortOrder.LayoutOrder
standingsLayout.Padding = UDim.new(0, 2)
standingsLayout.Parent = standingsFrame

-- Personal stats area
local personalFrame = Instance.new("Frame")
personalFrame.Name = "PersonalStats"
personalFrame.AnchorPoint = Vector2.new(0.5, 0)
personalFrame.Position = UDim2.new(0.5, 0, 0, 280)
personalFrame.Size = UDim2.new(0.9, 0, 0, 80)
personalFrame.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
personalFrame.BorderSizePixel = 0
personalFrame.Parent = resultsPanel
makeCorner(personalFrame, 8)

makeLabel({
	name = "Header",
	text = "YOUR STATS",
	size = UDim2.new(1, 0, 0, 20),
	position = UDim2.new(0.5, 0, 0, 8),
	textColor = GOLD,
	textSize = 12,
	font = Enum.Font.GothamBold,
	parent = personalFrame,
	anchorPoint = Vector2.new(0.5, 0),
})

local personalStatsLabel = makeLabel({
	name = "Stats",
	text = "",
	size = UDim2.new(1, -20, 0, 44),
	position = UDim2.new(0.5, 0, 0, 30),
	textColor = WHITE,
	textSize = 14,
	font = Enum.Font.GothamMedium,
	parent = personalFrame,
	anchorPoint = Vector2.new(0.5, 0),
})

-- Coin breakdown area
local coinBreakdownFrame = Instance.new("Frame")
coinBreakdownFrame.Name = "CoinBreakdown"
coinBreakdownFrame.AnchorPoint = Vector2.new(0.5, 0)
coinBreakdownFrame.Position = UDim2.new(0.5, 0, 0, 370)
coinBreakdownFrame.Size = UDim2.new(0.9, 0, 0, 60)
coinBreakdownFrame.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
coinBreakdownFrame.BorderSizePixel = 0
coinBreakdownFrame.Parent = resultsPanel
makeCorner(coinBreakdownFrame, 8)

makeLabel({
	name = "Header",
	text = "COINS EARNED",
	size = UDim2.new(1, 0, 0, 20),
	position = UDim2.new(0.5, 0, 0, 8),
	textColor = GOLD,
	textSize = 12,
	font = Enum.Font.GothamBold,
	parent = coinBreakdownFrame,
	anchorPoint = Vector2.new(0.5, 0),
})

local coinBreakdownLabel = makeLabel({
	name = "Breakdown",
	text = "",
	size = UDim2.new(1, -20, 0, 28),
	position = UDim2.new(0.5, 0, 0, 28),
	textColor = GOLD,
	textSize = 16,
	font = Enum.Font.GothamBold,
	parent = coinBreakdownFrame,
	anchorPoint = Vector2.new(0.5, 0),
})

-- Action buttons
local playAgainBtn = makeButton({
	name = "PlayAgainBtn",
	text = "PLAY AGAIN",
	size = UDim2.new(0, 180, 0, 44),
	position = UDim2.new(0.3, 0, 0, 486),
	bgColor = GOLD,
	textSize = 18,
	parent = resultsPanel,
	anchorPoint = Vector2.new(0.5, 0),
})

local menuBtn = makeButton({
	name = "MenuBtn",
	text = "MENU",
	size = UDim2.new(0, 180, 0, 44),
	position = UDim2.new(0.7, 0, 0, 486),
	bgColor = Color3.fromRGB(60, 60, 70),
	textColor = WHITE,
	textSize = 18,
	parent = resultsPanel,
	anchorPoint = Vector2.new(0.5, 0),
})

------------------------------------------------------------------------
-- Results screen population
------------------------------------------------------------------------

local function populateResults(data: { [string]: any })
	-- Winner
	local winner = (data.winner :: string?) or "Nobody"
	winnerLabel.Text = winner .. " wins!"

	if data.winningTeam then
		local wt = data.winningTeam :: number
		winnerLabel.TextColor3 = if wt == 1 then TEAM_BLUE else TEAM_RED
	else
		winnerLabel.TextColor3 = GOLD
	end

	-- Clear old standings
	for _, child in standingsFrame:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	-- Populate standings
	local standings = data.standings :: { any }?
	if standings then
		for rank, entry in standings :: { any } do
			local row = Instance.new("Frame")
			row.Name = "Row_" .. rank
			row.Size = UDim2.new(1, 0, 0, 28)
			row.BackgroundColor3 = if rank % 2 == 0
				then Color3.fromRGB(28, 28, 36)
				else Color3.fromRGB(22, 22, 30)
			row.BackgroundTransparency = 0
			row.BorderSizePixel = 0
			row.LayoutOrder = rank
			row.Parent = standingsFrame

			local isMe = entry.name == player.Name
			local nameColor = if isMe then GOLD else WHITE

			-- Team color indicator
			if entry.team then
				local teamColor = if entry.team == 1 then TEAM_BLUE else TEAM_RED
				local teamDot = Instance.new("Frame")
				teamDot.Size = UDim2.new(0, 4, 0, 20)
				teamDot.Position = UDim2.new(0, 2, 0.5, 0)
				teamDot.AnchorPoint = Vector2.new(0, 0.5)
				teamDot.BackgroundColor3 = teamColor
				teamDot.BorderSizePixel = 0
				teamDot.Parent = row
				makeCorner(teamDot, 2)
			end

			-- Rank
			makeLabel({
				name = "Rank",
				text = "#" .. rank,
				size = UDim2.new(0, 30, 1, 0),
				position = UDim2.new(0, 14, 0.5, 0),
				textColor = GREY,
				textSize = 13,
				font = Enum.Font.GothamMedium,
				parent = row,
				anchorPoint = Vector2.new(0, 0.5),
				xAlign = Enum.TextXAlignment.Left,
			})

			-- Player name
			makeLabel({
				name = "Name",
				text = entry.name,
				size = UDim2.new(0, 200, 1, 0),
				position = UDim2.new(0, 50, 0.5, 0),
				textColor = nameColor,
				textSize = 14,
				font = if isMe then Enum.Font.GothamBold else Enum.Font.GothamMedium,
				parent = row,
				anchorPoint = Vector2.new(0, 0.5),
				xAlign = Enum.TextXAlignment.Left,
			})

			-- Kills
			makeLabel({
				name = "Kills",
				text = tostring(entry.kills) .. " K",
				size = UDim2.new(0, 50, 1, 0),
				position = UDim2.new(1, -120, 0.5, 0),
				textColor = GREEN,
				textSize = 13,
				font = Enum.Font.GothamMedium,
				parent = row,
				anchorPoint = Vector2.new(0, 0.5),
				xAlign = Enum.TextXAlignment.Right,
			})

			-- Deaths
			makeLabel({
				name = "Deaths",
				text = tostring(entry.deaths) .. " D",
				size = UDim2.new(0, 50, 1, 0),
				position = UDim2.new(1, -60, 0.5, 0),
				textColor = RED,
				textSize = 13,
				font = Enum.Font.GothamMedium,
				parent = row,
				anchorPoint = Vector2.new(0, 0.5),
				xAlign = Enum.TextXAlignment.Right,
			})
		end
	end

	-- Personal stats
	local ps = data.personalStats :: { [string]: any }?
	if ps then
		local kills = (ps.kills :: number?) or 0
		local deaths = (ps.deaths :: number?) or 0
		local assists = (ps.assists :: number?) or 0
		local dmg = (ps.damageDealt :: number?) or 0
		local kd = if deaths > 0 then string.format("%.1f", kills / deaths) else tostring(kills)

		personalStatsLabel.Text = string.format(
			"Kills: %d    Deaths: %d    K/D: %s    Assists: %d    Damage: %d",
			kills, deaths, kd, assists, math.floor(dmg)
		)

		-- Coin breakdown
		local totalCoins = (ps.coinsEarned :: number?) or 0
		coinBreakdownLabel.Text = string.format("+ %d coins", totalCoins)
	else
		personalStatsLabel.Text = ""
		coinBreakdownLabel.Text = ""
	end

	-- Store last mode for Play Again
	lastMode = data.lastMode :: string?
end

------------------------------------------------------------------------
-- Button handlers
------------------------------------------------------------------------

playBtn.MouseButton1Click:Connect(function()
	showScreen("ModeSelect")
end)

shopBtn.MouseButton1Click:Connect(function()
	-- Toggle ShopUI via B key simulation (ShopUI listens for B key)
	-- We fire the shop open by toggling the existing ShopUI
	local shopGui = player:FindFirstChild("PlayerGui") and (player.PlayerGui :: PlayerGui):FindFirstChild("ShopUI")
	if shopGui then
		(shopGui :: ScreenGui).Enabled = not (shopGui :: ScreenGui).Enabled
	end
end)

playAgainBtn.MouseButton1Click:Connect(function()
	local mode = lastMode or "FFA"
	queuedMode = mode
	Remotes.JoinQueue:FireServer({ mode = mode })
	showScreen("Queue")
end)

menuBtn.MouseButton1Click:Connect(function()
	showScreen("MainMenu")
end)

------------------------------------------------------------------------
-- Remote event handlers
------------------------------------------------------------------------

-- Queue updates from server
Remotes.QueueUpdate.OnClientEvent:Connect(function(data: { [string]: any })
	local mode = data.mode :: string?
	local count = (data.count :: number?) or 0
	local needed = (data.needed :: number?) or 8

	-- Update mode selection screen labels
	if mode and modeQueueLabels[mode] then
		modeQueueLabels[mode].Text = count .. "/" .. needed .. " players"
	end

	-- Update queue screen if we're queued for this mode
	if queuedMode == mode and currentScreen == "Queue" then
		queueCount = count
		queueNeeded = needed

		local modeNames: { [string]: string } = {
			FFA = "Free-for-All",
			["2v2"] = "Team 2v2",
			["3v3"] = "Team 3v3",
		}
		queueModeLabel.Text = modeNames[mode :: string] or mode :: string
		queueCountLabel.Text = count .. "/" .. needed .. " players in queue"
	end
end)

-- Match state changes from server
Remotes.MatchStateChange.OnClientEvent:Connect(function(data: { [string]: any })
	local state = data.state :: string?
	if not state then
		return
	end

	if state == "Lobby" then
		-- Only go to main menu if we're not already there
		if currentScreen ~= "MainMenu" and currentScreen ~= "Results" then
			stopDots()
			queuedMode = nil
			showScreen("MainMenu")
		end

	elseif state == "Generating" then
		stopDots()
		-- Brief transition — stay on queue screen, update text
		if currentScreen == "Queue" then
			searchLabel.Text = "Generating arena..."
			queueCountLabel.Text = "Get ready!"
		end

	elseif state == "Countdown" then
		stopDots()
		showScreen("Countdown")

		local countdown = data.countdown :: number?
		if countdown then
			local num = math.ceil(countdown)
			if num > 0 then
				countdownNumber.Text = tostring(num)
				countdownNumber.TextColor3 = WHITE
			else
				countdownNumber.Text = "FIGHT!"
				countdownNumber.TextColor3 = GOLD
			end

			-- Pulse animation
			countdownNumber.TextSize = 80
			TweenService:Create(countdownNumber, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
				TextSize = 120,
			}):Play()
		end

		local arenaName = data.arenaName :: string?
		countdownArena.Text = if arenaName then arenaName else ""

	elseif state == "InProgress" then
		-- Hide menu UI — the HUD (UIController) takes over
		stopDots()
		hideAllScreens()
		currentScreen = "None"

	elseif state == "Results" then
		-- Results screen will be populated by MatchResults event
		-- but show the screen transition
	end
end)

-- Detailed match results
Remotes.MatchResults.OnClientEvent:Connect(function(data: { [string]: any })
	populateResults(data)
	showScreen("Results")
end)

-- Coin balance sync
Remotes.CoinUpdate.OnClientEvent:Connect(function(data: { [string]: any })
	local newBalance = data.newBalance :: number?
	if newBalance ~= nil then
		coinBalance = newBalance
	else
		local amount = (data.amount :: number?) or 0
		coinBalance += amount
	end
	menuCoinLabel.Text = tostring(coinBalance)
end)

------------------------------------------------------------------------
-- Init: start on main menu
------------------------------------------------------------------------

showScreen("MainMenu")
print("[MainMenuUI] Initialized")
