--!strict
--[[
	ShopUI (Client)
	Full-screen shop overlay. Press B to toggle (only outside of matches).
	Tabs: Weapons | Upgrades | Skins | Emotes.
	Calls ShopPurchase RemoteFunction for purchases and equips.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ShopConfig = require(ReplicatedStorage:WaitForChild("ShopConfig"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local player = Players.LocalPlayer

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

local BACKGROUND_COLOR = Color3.fromRGB(30, 30, 30)
local CARD_COLOR = Color3.fromRGB(40, 40, 40)
local CARD_HOVER_COLOR = Color3.fromRGB(55, 55, 55)
local GOLD_COLOR = Color3.fromRGB(255, 215, 0)
local TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local TAB_INACTIVE_COLOR = Color3.fromRGB(50, 50, 50)
local OWNED_COLOR = Color3.fromRGB(80, 200, 80)
local EQUIPPED_COLOR = Color3.fromRGB(100, 180, 255)
local ERROR_COLOR = Color3.fromRGB(255, 80, 80)

local RARITY_COLORS: { [string]: Color3 } = {
	Common = Color3.fromRGB(180, 180, 180),
	Rare = Color3.fromRGB(80, 140, 255),
	Epic = Color3.fromRGB(180, 60, 255),
	Legendary = Color3.fromRGB(255, 165, 0),
}

local CATEGORIES = { "Weapons", "Upgrades", "Skins", "Emotes" }

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------

local shopOpen = false
local activeTab = "Weapons"
local coinBalance = 0
local inventory: { [string]: any } = {
	ownedWeapons = { Sword = true },
	weaponTiers = { Sword = 1 },
	ownedSkins = {},
	ownedEmotes = {},
	equippedWeapon = "Sword",
	equippedSkins = {},
	equippedEmote = "",
}

------------------------------------------------------------------------
-- ScreenGui
------------------------------------------------------------------------

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "ShopUI"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.DisplayOrder = 10
screenGui.Enabled = false
screenGui.Parent = player:WaitForChild("PlayerGui")

------------------------------------------------------------------------
-- Dark overlay (full screen)
------------------------------------------------------------------------

local overlay = Instance.new("Frame")
overlay.Name = "Overlay"
overlay.Size = UDim2.new(1, 0, 1, 0)
overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
overlay.BackgroundTransparency = 0.4
overlay.BorderSizePixel = 0
overlay.Parent = screenGui

------------------------------------------------------------------------
-- Main shop frame (centered)
------------------------------------------------------------------------

local shopFrame = Instance.new("Frame")
shopFrame.Name = "ShopFrame"
shopFrame.AnchorPoint = Vector2.new(0.5, 0.5)
shopFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
shopFrame.Size = UDim2.new(0.7, 0, 0.8, 0)
shopFrame.BackgroundColor3 = BACKGROUND_COLOR
shopFrame.BorderSizePixel = 0
shopFrame.Parent = overlay

local shopCorner = Instance.new("UICorner")
shopCorner.CornerRadius = UDim.new(0, 12)
shopCorner.Parent = shopFrame

local shopStroke = Instance.new("UIStroke")
shopStroke.Color = GOLD_COLOR
shopStroke.Thickness = 2
shopStroke.Parent = shopFrame

------------------------------------------------------------------------
-- Header
------------------------------------------------------------------------

local header = Instance.new("Frame")
header.Name = "Header"
header.Size = UDim2.new(1, 0, 0, 50)
header.BackgroundTransparency = 1
header.Parent = shopFrame

local titleLabel = Instance.new("TextLabel")
titleLabel.Name = "Title"
titleLabel.AnchorPoint = Vector2.new(0, 0.5)
titleLabel.Position = UDim2.new(0, 20, 0.5, 0)
titleLabel.Size = UDim2.new(0, 120, 0, 36)
titleLabel.BackgroundTransparency = 1
titleLabel.Text = "SHOP"
titleLabel.TextColor3 = GOLD_COLOR
titleLabel.TextSize = 28
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Parent = header

-- Coin display in header
local coinDisplay = Instance.new("Frame")
coinDisplay.Name = "CoinDisplay"
coinDisplay.AnchorPoint = Vector2.new(0.5, 0.5)
coinDisplay.Position = UDim2.new(0.5, 0, 0.5, 0)
coinDisplay.Size = UDim2.new(0, 160, 0, 32)
coinDisplay.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
coinDisplay.BorderSizePixel = 0
coinDisplay.Parent = header

local coinDisplayCorner = Instance.new("UICorner")
coinDisplayCorner.CornerRadius = UDim.new(0, 8)
coinDisplayCorner.Parent = coinDisplay

local coinIcon = Instance.new("Frame")
coinIcon.Name = "Icon"
coinIcon.AnchorPoint = Vector2.new(0, 0.5)
coinIcon.Position = UDim2.new(0, 10, 0.5, 0)
coinIcon.Size = UDim2.new(0, 18, 0, 18)
coinIcon.BackgroundColor3 = Color3.fromRGB(255, 200, 50)
coinIcon.BorderSizePixel = 0
coinIcon.Parent = coinDisplay

local coinIconCorner = Instance.new("UICorner")
coinIconCorner.CornerRadius = UDim.new(1, 0)
coinIconCorner.Parent = coinIcon

local coinLabel = Instance.new("TextLabel")
coinLabel.Name = "Amount"
coinLabel.AnchorPoint = Vector2.new(0, 0.5)
coinLabel.Position = UDim2.new(0, 36, 0.5, 0)
coinLabel.Size = UDim2.new(1, -46, 1, 0)
coinLabel.BackgroundTransparency = 1
coinLabel.Text = "0"
coinLabel.TextColor3 = GOLD_COLOR
coinLabel.TextSize = 18
coinLabel.Font = Enum.Font.GothamBold
coinLabel.TextXAlignment = Enum.TextXAlignment.Left
coinLabel.Parent = coinDisplay

-- Close button
local closeBtn = Instance.new("TextButton")
closeBtn.Name = "CloseBtn"
closeBtn.AnchorPoint = Vector2.new(1, 0.5)
closeBtn.Position = UDim2.new(1, -12, 0.5, 0)
closeBtn.Size = UDim2.new(0, 32, 0, 32)
closeBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
closeBtn.BorderSizePixel = 0
closeBtn.Text = "X"
closeBtn.TextColor3 = TEXT_COLOR
closeBtn.TextSize = 18
closeBtn.Font = Enum.Font.GothamBold
closeBtn.Parent = header

local closeBtnCorner = Instance.new("UICorner")
closeBtnCorner.CornerRadius = UDim.new(0, 8)
closeBtnCorner.Parent = closeBtn

------------------------------------------------------------------------
-- Tab bar
------------------------------------------------------------------------

local tabBar = Instance.new("Frame")
tabBar.Name = "TabBar"
tabBar.Position = UDim2.new(0, 0, 0, 50)
tabBar.Size = UDim2.new(1, 0, 0, 36)
tabBar.BackgroundTransparency = 1
tabBar.Parent = shopFrame

local tabLayout = Instance.new("UIListLayout")
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
tabLayout.Padding = UDim.new(0, 8)
tabLayout.Parent = tabBar

local tabButtons: { [string]: TextButton } = {}

------------------------------------------------------------------------
-- Status message (shows purchase results briefly)
------------------------------------------------------------------------

local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "StatusMessage"
statusLabel.AnchorPoint = Vector2.new(0.5, 0)
statusLabel.Position = UDim2.new(0.5, 0, 0, 88)
statusLabel.Size = UDim2.new(0.8, 0, 0, 22)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = ""
statusLabel.TextColor3 = OWNED_COLOR
statusLabel.TextSize = 14
statusLabel.Font = Enum.Font.GothamMedium
statusLabel.Parent = shopFrame

local statusFadeThread: thread? = nil

local function showStatus(message: string, color: Color3?)
	statusLabel.Text = message
	statusLabel.TextColor3 = color or OWNED_COLOR
	statusLabel.TextTransparency = 0
	if statusFadeThread then
		task.cancel(statusFadeThread)
	end
	statusFadeThread = task.delay(2, function()
		TweenService:Create(statusLabel, TweenInfo.new(0.5), { TextTransparency = 1 }):Play()
	end)
end

------------------------------------------------------------------------
-- Item grid (ScrollingFrame)
------------------------------------------------------------------------

local itemGrid = Instance.new("ScrollingFrame")
itemGrid.Name = "ItemGrid"
itemGrid.Position = UDim2.new(0, 12, 0, 114)
itemGrid.Size = UDim2.new(1, -24, 1, -126)
itemGrid.BackgroundTransparency = 1
itemGrid.BorderSizePixel = 0
itemGrid.ScrollBarThickness = 6
itemGrid.ScrollBarImageColor3 = GOLD_COLOR
itemGrid.CanvasSize = UDim2.new(0, 0, 0, 0)
itemGrid.AutomaticCanvasSize = Enum.AutomaticSize.Y
itemGrid.Parent = shopFrame

local gridLayout = Instance.new("UIGridLayout")
gridLayout.CellSize = UDim2.new(0, 170, 0, 130)
gridLayout.CellPadding = UDim2.new(0, 10, 0, 10)
gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
gridLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
gridLayout.Parent = itemGrid

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function isOwned(item: ShopConfig.ShopItem): boolean
	if item.category == "Weapons" then
		return inventory.ownedWeapons[item.displayName] == true
	elseif item.category == "Upgrades" then
		local weaponName = item.weaponName :: string
		local tier = item.tier :: number
		local currentTier = inventory.weaponTiers[weaponName] or 1
		return currentTier >= tier
	elseif item.category == "Skins" then
		return inventory.ownedSkins[item.id] == true
	elseif item.category == "Emotes" then
		return inventory.ownedEmotes[item.id] == true
	end
	return false
end

local function isEquipped(item: ShopConfig.ShopItem): boolean
	if item.category == "Weapons" then
		return inventory.equippedWeapon == item.displayName
	elseif item.category == "Skins" then
		local weaponName = item.weaponName :: string
		return inventory.equippedSkins[weaponName] == item.id
	elseif item.category == "Emotes" then
		return inventory.equippedEmote == item.id
	end
	return false
end

local function canPurchase(item: ShopConfig.ShopItem): boolean
	if isOwned(item) then
		return false
	end
	if item.price > coinBalance then
		return false
	end
	-- Prerequisite checks
	if item.category == "Upgrades" then
		local weaponName = item.weaponName :: string
		if not inventory.ownedWeapons[weaponName] then
			return false
		end
		local tier = item.tier :: number
		local currentTier = inventory.weaponTiers[weaponName] or 1
		if tier == 3 and currentTier < 2 then
			return false
		end
	elseif item.category == "Skins" then
		local weaponName = item.weaponName :: string
		if not inventory.ownedWeapons[weaponName] then
			return false
		end
	end
	return true
end

------------------------------------------------------------------------
-- Purchase / Equip actions
------------------------------------------------------------------------

local processing = false

local function doPurchase(item: ShopConfig.ShopItem)
	if processing then
		return
	end
	processing = true

	local result = Remotes.ShopPurchase:InvokeServer({
		action = "purchase",
		itemId = item.id,
	})

	if typeof(result) == "table" then
		if result.success then
			if result.inventory then
				inventory = result.inventory
			end
			showStatus("Purchased " .. item.displayName .. "!", OWNED_COLOR)
		else
			showStatus(result.message or "Purchase failed.", ERROR_COLOR)
		end
	end

	processing = false
end

local function doEquip(item: ShopConfig.ShopItem)
	if processing then
		return
	end
	processing = true

	local result = Remotes.ShopPurchase:InvokeServer({
		action = "equip",
		itemId = item.id,
	})

	if typeof(result) == "table" then
		if result.success then
			if result.inventory then
				inventory = result.inventory
			end
			showStatus("Equipped " .. item.displayName .. "!", EQUIPPED_COLOR)
		else
			showStatus(result.message or "Equip failed.", ERROR_COLOR)
		end
	end

	processing = false
end

------------------------------------------------------------------------
-- Build item cards
------------------------------------------------------------------------

-- Forward declaration
local refreshGrid: () -> ()

local function createItemCard(item: ShopConfig.ShopItem, order: number): Frame
	local card = Instance.new("Frame")
	card.Name = item.id
	card.BackgroundColor3 = CARD_COLOR
	card.BorderSizePixel = 0
	card.LayoutOrder = order

	local cardCorner = Instance.new("UICorner")
	cardCorner.CornerRadius = UDim.new(0, 8)
	cardCorner.Parent = card

	-- Rarity color bar at top
	local rarityBar = Instance.new("Frame")
	rarityBar.Name = "RarityBar"
	rarityBar.Size = UDim2.new(1, 0, 0, 4)
	rarityBar.BorderSizePixel = 0
	rarityBar.Parent = card

	local rarityCorner = Instance.new("UICorner")
	rarityCorner.CornerRadius = UDim.new(0, 2)
	rarityCorner.Parent = rarityBar

	if item.rarity and RARITY_COLORS[item.rarity] then
		rarityBar.BackgroundColor3 = RARITY_COLORS[item.rarity]
	elseif item.category == "Weapons" then
		rarityBar.BackgroundColor3 = GOLD_COLOR
	elseif item.category == "Upgrades" then
		rarityBar.BackgroundColor3 = Color3.fromRGB(100, 200, 255)
	else
		rarityBar.BackgroundColor3 = Color3.fromRGB(120, 120, 120)
	end

	-- Item name
	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "ItemName"
	nameLabel.Position = UDim2.new(0, 8, 0, 10)
	nameLabel.Size = UDim2.new(1, -16, 0, 20)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = item.displayName
	nameLabel.TextColor3 = TEXT_COLOR
	nameLabel.TextSize = 14
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.Parent = card

	-- Description
	local descLabel = Instance.new("TextLabel")
	descLabel.Name = "Description"
	descLabel.Position = UDim2.new(0, 8, 0, 32)
	descLabel.Size = UDim2.new(1, -16, 0, 36)
	descLabel.BackgroundTransparency = 1
	descLabel.Text = item.description
	descLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
	descLabel.TextSize = 11
	descLabel.Font = Enum.Font.Gotham
	descLabel.TextXAlignment = Enum.TextXAlignment.Left
	descLabel.TextYAlignment = Enum.TextYAlignment.Top
	descLabel.TextWrapped = true
	descLabel.TextTruncate = Enum.TextTruncate.AtEnd
	descLabel.Parent = card

	-- Upgrade tier info (for Upgrades tab)
	if item.category == "Upgrades" and item.weaponName and item.tier then
		local tierLabel = Instance.new("TextLabel")
		tierLabel.Name = "TierInfo"
		tierLabel.Position = UDim2.new(0, 8, 0, 68)
		tierLabel.Size = UDim2.new(1, -16, 0, 16)
		tierLabel.BackgroundTransparency = 1
		tierLabel.Text = item.weaponName .. " - Tier " .. tostring(item.tier)
		tierLabel.TextColor3 = Color3.fromRGB(100, 200, 255)
		tierLabel.TextSize = 11
		tierLabel.Font = Enum.Font.GothamMedium
		tierLabel.TextXAlignment = Enum.TextXAlignment.Left
		tierLabel.Parent = card
	end

	-- Action button (Purchase / Equip / Owned / Equipped)
	local actionBtn = Instance.new("TextButton")
	actionBtn.Name = "ActionBtn"
	actionBtn.AnchorPoint = Vector2.new(0.5, 1)
	actionBtn.Position = UDim2.new(0.5, 0, 1, -8)
	actionBtn.Size = UDim2.new(1, -16, 0, 28)
	actionBtn.BorderSizePixel = 0
	actionBtn.TextSize = 13
	actionBtn.Font = Enum.Font.GothamBold
	actionBtn.Parent = card

	local actionCorner = Instance.new("UICorner")
	actionCorner.CornerRadius = UDim.new(0, 6)
	actionCorner.Parent = actionBtn

	-- Set button state
	local function updateButton()
		if isEquipped(item) then
			actionBtn.Text = "EQUIPPED"
			actionBtn.BackgroundColor3 = EQUIPPED_COLOR
			actionBtn.TextColor3 = Color3.fromRGB(20, 20, 20)
			actionBtn.AutoButtonColor = false
		elseif isOwned(item) then
			if item.category == "Upgrades" then
				actionBtn.Text = "OWNED"
				actionBtn.BackgroundColor3 = OWNED_COLOR
				actionBtn.TextColor3 = Color3.fromRGB(20, 20, 20)
				actionBtn.AutoButtonColor = false
			else
				actionBtn.Text = "EQUIP"
				actionBtn.BackgroundColor3 = OWNED_COLOR
				actionBtn.TextColor3 = Color3.fromRGB(20, 20, 20)
				actionBtn.AutoButtonColor = true
			end
		elseif canPurchase(item) then
			actionBtn.Text = tostring(item.price) .. " Coins"
			actionBtn.BackgroundColor3 = GOLD_COLOR
			actionBtn.TextColor3 = Color3.fromRGB(20, 20, 20)
			actionBtn.AutoButtonColor = true
		else
			actionBtn.Text = tostring(item.price) .. " Coins"
			actionBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
			actionBtn.TextColor3 = Color3.fromRGB(140, 140, 140)
			actionBtn.AutoButtonColor = false
		end
	end

	updateButton()

	-- Click handler
	actionBtn.MouseButton1Click:Connect(function()
		if isEquipped(item) then
			return
		elseif isOwned(item) and item.category ~= "Upgrades" then
			doEquip(item)
			refreshGrid()
		elseif canPurchase(item) then
			doPurchase(item)
			refreshGrid()
		elseif not isOwned(item) and item.price > coinBalance then
			showStatus("Not enough coins!", ERROR_COLOR)
		end
	end)

	-- Hover effect
	local mouseEnterConn = card.MouseEnter:Connect(function()
		TweenService:Create(card, TweenInfo.new(0.15), { BackgroundColor3 = CARD_HOVER_COLOR }):Play()
	end)
	local mouseLeaveConn = card.MouseLeave:Connect(function()
		TweenService:Create(card, TweenInfo.new(0.15), { BackgroundColor3 = CARD_COLOR }):Play()
	end)

	return card
end

------------------------------------------------------------------------
-- Tab switching & grid refresh
------------------------------------------------------------------------

local function clearGrid()
	for _, child in itemGrid:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
end

function refreshGrid()
	clearGrid()

	local items = ShopConfig.GetItemsByCategory(activeTab)
	for i, item in items do
		local card = createItemCard(item, i)
		card.Parent = itemGrid
	end

	-- Update coin display
	coinLabel.Text = tostring(coinBalance)
end

local function switchTab(tabName: string)
	activeTab = tabName
	for name, btn in tabButtons do
		if name == tabName then
			btn.BackgroundColor3 = GOLD_COLOR
			btn.TextColor3 = Color3.fromRGB(20, 20, 20)
		else
			btn.BackgroundColor3 = TAB_INACTIVE_COLOR
			btn.TextColor3 = TEXT_COLOR
		end
	end
	refreshGrid()
end

-- Create tab buttons
for _, category in CATEGORIES do
	local tabBtn = Instance.new("TextButton")
	tabBtn.Name = category .. "Tab"
	tabBtn.Size = UDim2.new(0, 110, 0, 30)
	tabBtn.BackgroundColor3 = TAB_INACTIVE_COLOR
	tabBtn.BorderSizePixel = 0
	tabBtn.Text = category
	tabBtn.TextColor3 = TEXT_COLOR
	tabBtn.TextSize = 14
	tabBtn.Font = Enum.Font.GothamBold
	tabBtn.Parent = tabBar

	local tabCorner = Instance.new("UICorner")
	tabCorner.CornerRadius = UDim.new(0, 6)
	tabCorner.Parent = tabBtn

	tabButtons[category] = tabBtn

	tabBtn.MouseButton1Click:Connect(function()
		switchTab(category)
	end)
end

------------------------------------------------------------------------
-- Toggle shop
------------------------------------------------------------------------

local function openShop()
	if shopOpen then
		return
	end
	shopOpen = true
	screenGui.Enabled = true

	-- Load fresh inventory from server
	local result = Remotes.LoadData:InvokeServer()
	if typeof(result) == "table" and result.success and result.inventory then
		inventory = result.inventory
	end

	switchTab(activeTab)
end

local function closeShop()
	if not shopOpen then
		return
	end
	shopOpen = false
	screenGui.Enabled = false
end

local function toggleShop()
	if shopOpen then
		closeShop()
	else
		openShop()
	end
end

closeBtn.MouseButton1Click:Connect(closeShop)

------------------------------------------------------------------------
-- Input binding: B key to toggle
------------------------------------------------------------------------

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.B then
		toggleShop()
	end
end)

------------------------------------------------------------------------
-- Coin sync: keep balance updated via CoinUpdate remote
------------------------------------------------------------------------

Remotes.CoinUpdate.OnClientEvent:Connect(function(data: { [string]: any })
	local newBalance = data.newBalance :: number?
	if newBalance ~= nil then
		coinBalance = newBalance
	else
		local amount = (data.amount :: number?) or 0
		coinBalance += amount
	end

	if shopOpen then
		coinLabel.Text = tostring(coinBalance)
	end
end)

------------------------------------------------------------------------
-- WeaponEquipped sync: update local inventory when weapon changes
------------------------------------------------------------------------

Remotes.WeaponEquipped.OnClientEvent:Connect(function(data: { [string]: any })
	local weapon = data.weapon :: string?
	if weapon then
		inventory.equippedWeapon = weapon
		if shopOpen and activeTab == "Weapons" then
			refreshGrid()
		end
	end
end)

print("[ShopUI] Initialized")
