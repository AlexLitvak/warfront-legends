--!strict
--[[
	CombatClient
	Handles player input for attacks per weapon type:
	  • Sword / Scythe — click to swing
	  • Axe — click to swing, hold to charge Earthshaker
	  • Bow — click to fire (sends mouse target position for raycasting)
	Also handles perk feedback: Hunter's Mark highlights, Soul Harvest
	VFX, Blade Rush stun indicator, and Earthshaker screen shake.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local WeaponConfig = require(ReplicatedStorage:WaitForChild("WeaponConfig"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------

local player = Players.LocalPlayer
local mouse = player:GetMouse()
local equippedWeapon = "Sword"
local lastAttackTime = 0
local isAttacking = false

-- Axe charge state
local isCharging = false
local chargeStartTime = 0

-- Hunter's Mark state
local markHighlight: Highlight? = nil
local markCleanupThread: thread? = nil

------------------------------------------------------------------------
-- Animation
------------------------------------------------------------------------

local SWING_ANIM_IDS: { [string]: string } = {
	Sword = "rbxassetid://522635514",
	Axe = "",     -- placeholder
	Bow = "",     -- placeholder
	Scythe = "",  -- placeholder
}

local LUNGE_ANIM_ID = "rbxassetid://522638767"

local function getAnimator(): Animator?
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end
	return humanoid:FindFirstChildOfClass("Animator")
end

local function playAttackAnimation()
	local animId = SWING_ANIM_IDS[equippedWeapon] or ""
	if animId == "" then
		return
	end

	local animator = getAnimator()
	if not animator then
		return
	end

	local anim = Instance.new("Animation")
	anim.AnimationId = animId

	local track = animator:LoadAnimation(anim)
	track.Priority = Enum.AnimationPriority.Action
	track:Play()

	anim:Destroy()
end

------------------------------------------------------------------------
-- Tool sounds
------------------------------------------------------------------------

local function getToolHandle(): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local tool = character:FindFirstChildOfClass("Tool")
	if not tool then
		return nil
	end
	return tool:FindFirstChild("Handle") :: BasePart?
end

local function playToolSound(soundName: string)
	local handle = getToolHandle()
	if not handle then
		return
	end
	local sound = handle:FindFirstChild(soundName) :: Sound?
	if sound then
		sound:Play()
	end
end

------------------------------------------------------------------------
-- Mouse target (for Bow raycasting)
------------------------------------------------------------------------

local function getMouseTargetPosition(): Vector3
	local mouseRay = mouse.UnitRay
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { player.Character :: Instance }

	local result = workspace:Raycast(mouseRay.Origin, mouseRay.Direction * 1000, rayParams)
	if result then
		return result.Position
	end
	return mouseRay.Origin + mouseRay.Direction * 1000
end

------------------------------------------------------------------------
-- Attack logic
------------------------------------------------------------------------

local function tryAttack()
	local weaponStats = WeaponConfig[equippedWeapon]
	if not weaponStats then
		return
	end

	-- Client-side cooldown to avoid flooding the server
	local now = os.clock()
	if now - lastAttackTime < weaponStats.attackSpeed then
		return
	end

	-- Must be alive
	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	lastAttackTime = now
	isAttacking = true

	playAttackAnimation()
	playToolSound("SwordSlash")

	-- Build attack data based on weapon type
	local attackData: { [string]: any } = {
		weapon = equippedWeapon,
		timestamp = now,
	}

	if weaponStats.weaponType == "Ranged" then
		attackData.targetPosition = getMouseTargetPosition()
	end

	Remotes.AttackInput:FireServer(attackData)

	task.delay(weaponStats.attackSpeed, function()
		isAttacking = false
	end)
end

local function tryEarthshaker()
	local weaponStats = WeaponConfig[equippedWeapon]
	if not weaponStats or not weaponStats.perk or weaponStats.perk.name ~= "Earthshaker" then
		return
	end

	-- Must be alive
	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	playAttackAnimation()
	playToolSound("SwordLunge")

	Remotes.AttackInput:FireServer({
		weapon = equippedWeapon,
		action = "special",
		timestamp = os.clock(),
	})
end

------------------------------------------------------------------------
-- Input binding
------------------------------------------------------------------------

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if equippedWeapon == "Axe" then
			-- Start charge tracking for Earthshaker
			isCharging = true
			chargeStartTime = os.clock()
			-- Still do a normal swing immediately
			tryAttack()
		else
			tryAttack()
		end
	end
end)

UserInputService.InputEnded:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if isCharging and equippedWeapon == "Axe" then
			local chargeTime = os.clock() - chargeStartTime
			local perk = WeaponConfig.Axe.perk
			local requiredCharge = if perk then (perk.chargeTime or 1.5) else 1.5

			if chargeTime >= requiredCharge then
				tryEarthshaker()
			end

			isCharging = false
			chargeStartTime = 0
		end
	end
end)

-- Touch tap to attack (mobile)
UserInputService.TouchTapInWorld:Connect(function(_position: Vector2, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	tryAttack()
end)

------------------------------------------------------------------------
-- Perk effect handlers
------------------------------------------------------------------------

local function clearMark()
	if markHighlight then
		markHighlight:Destroy()
		markHighlight = nil
	end
	if markCleanupThread then
		task.cancel(markCleanupThread)
		markCleanupThread = nil
	end
end

local function applyHuntersMark(targetUserId: number, duration: number)
	clearMark()

	-- Find the target player's character
	local targetPlayer = Players:GetPlayerByUserId(targetUserId)
	if not targetPlayer or not targetPlayer.Character then
		return
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "HuntersMark"
	highlight.FillColor = Color3.fromRGB(255, 100, 0)
	highlight.FillTransparency = 0.7
	highlight.OutlineColor = Color3.fromRGB(255, 50, 0)
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop -- visible through walls
	highlight.Adornee = targetPlayer.Character
	highlight.Parent = player:WaitForChild("PlayerGui")
	markHighlight = highlight

	-- Auto-remove after duration
	markCleanupThread = task.delay(duration, function()
		clearMark()
	end)
end

local function shakeCamera(intensity: number, duration: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local originalCFrame = camera.CFrame
	local elapsed = 0
	local shakeConnection: RBXScriptConnection? = nil

	shakeConnection = game:GetService("RunService").RenderStepped:Connect(function(dt: number)
		elapsed += dt
		if elapsed >= duration then
			if shakeConnection then
				shakeConnection:Disconnect()
			end
			return
		end

		local progress = elapsed / duration
		local decay = 1 - progress -- shake weakens over time
		local offsetX = (math.random() - 0.5) * intensity * decay
		local offsetY = (math.random() - 0.5) * intensity * decay
		camera.CFrame = camera.CFrame * CFrame.new(offsetX, offsetY, 0)
	end)
end

Remotes.PerkEffect.OnClientEvent:Connect(function(data: { [string]: any })
	local perkName = data.perk :: string?
	if not perkName then
		return
	end

	if perkName == "HuntersMark" then
		local targetUserId = data.targetUserId :: number?
		local duration = (data.duration :: number?) or 5
		if targetUserId then
			applyHuntersMark(targetUserId, duration)
		end

	elseif perkName == "Earthshaker" then
		-- Screen shake for all players near the slam
		local position = data.position :: Vector3?
		local radius = (data.radius :: number?) or 8
		if position then
			local rootPart = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if rootPart then
				local distance = (rootPart.Position - position).Magnitude
				if distance <= radius * 2 then -- shake range is 2x the damage radius
					local intensity = math.clamp(1 - (distance / (radius * 2)), 0.1, 1) * 0.8
					shakeCamera(intensity, 0.4)
				end
			end
		end

	elseif perkName == "BladeRush" then
		if data.stunned then
			-- We got stunned — could show a stun indicator on the HUD
		end

	elseif perkName == "SoulHarvest" then
		-- Speed boost activated — could show a VFX aura
		-- data.stacks, data.duration, data.healAmount available

	elseif perkName == "Headshot" then
		-- Headshot hit — could play a special hit marker sound
	end
end)

------------------------------------------------------------------------
-- Tool activation (weapon Tool in character triggers this on click)
------------------------------------------------------------------------

local function connectToolActivated(tool: Tool)
	tool.Activated:Connect(function()
		if equippedWeapon == "Axe" and not isCharging then
			isCharging = true
			chargeStartTime = os.clock()
		end
		tryAttack()
	end)

	tool.Deactivated:Connect(function()
		if isCharging and equippedWeapon == "Axe" then
			local chargeTime = os.clock() - chargeStartTime
			local perk = WeaponConfig.Axe.perk
			local requiredCharge = if perk then (perk.chargeTime or 1.5) else 1.5

			if chargeTime >= requiredCharge then
				tryEarthshaker()
			end

			isCharging = false
			chargeStartTime = 0
		end
	end)

	tool.Equipped:Connect(function()
		local handle = tool:FindFirstChild("Handle") :: BasePart?
		if handle then
			local unsheath = handle:FindFirstChild("Unsheath") :: Sound?
			if unsheath then
				unsheath:Play()
			end
		end
	end)
end

local function onCharacterAdded(character: Model)
	-- Connect to any Tool already in the character
	for _, child in character:GetChildren() do
		if child:IsA("Tool") then
			connectToolActivated(child)
		end
	end

	-- Connect to Tools added later (e.g. weapon swap)
	character.ChildAdded:Connect(function(child: Instance)
		if child:IsA("Tool") then
			connectToolActivated(child :: Tool)
		end
	end)

	-- Also check Backpack for Tools that get equipped into character
	local backpack = player:WaitForChild("Backpack", 5)
	if backpack then
		for _, child in backpack:GetChildren() do
			if child:IsA("Tool") then
				connectToolActivated(child)
			end
		end
		backpack.ChildAdded:Connect(function(child: Instance)
			if child:IsA("Tool") then
				connectToolActivated(child :: Tool)
			end
		end)
	end
end

player.CharacterAdded:Connect(onCharacterAdded)
if player.Character then
	onCharacterAdded(player.Character)
end

------------------------------------------------------------------------
-- Weapon equip handling (from ShopHandler via server)
------------------------------------------------------------------------

Remotes.WeaponEquipped.OnClientEvent:Connect(function(data: { [string]: any })
	local weapon = data.weapon :: string?
	if weapon and WeaponConfig[weapon] then
		equippedWeapon = weapon
	end
end)

------------------------------------------------------------------------
-- Server feedback handlers
------------------------------------------------------------------------

Remotes.DamageDealt.OnClientEvent:Connect(function(data: { [string]: any })
	if data.isHit then
		-- We hit someone — hit marker VFX
	else
		-- We took damage — damage direction indicator
	end
end)

Remotes.KillNotification.OnClientEvent:Connect(function(data: { [string]: any })
	-- Kill feed entry — handled by UIController
end)

print("[CombatClient] Initialized")
