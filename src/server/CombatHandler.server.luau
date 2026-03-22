--!strict
--[[
	CombatHandler (Server)
	Server-authoritative combat: validates attack inputs, performs hit
	detection (region check for melee, raycasting for ranged), applies
	damage, tracks kills/assists, and handles weapon perks:
	  • Sword  — Blade Rush (combo stun)
	  • Axe    — Earthshaker (charged AoE + knockback)
	  • Bow    — Hunter's Mark (highlight through walls)
	  • Scythe — Soul Harvest (heal + speed boost on kill)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage:WaitForChild("GameConfig"))
local WeaponConfig = require(ReplicatedStorage:WaitForChild("WeaponConfig"))
local ShopConfig = require(ReplicatedStorage:WaitForChild("ShopConfig"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

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

local getPlayerTeamFunc = serverEvents:FindFirstChild("GetPlayerTeam") :: BindableFunction
if not getPlayerTeamFunc then
	local func = Instance.new("BindableFunction")
	func.Name = "GetPlayerTeam"
	func.Parent = serverEvents
	getPlayerTeamFunc = func
end

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

type PlayerCombatState = {
	lastAttackTime: number,
	equippedWeapon: string,
	spawnProtectionEnd: number,
	damageContributors: { [Player]: number },
	-- Sword: Blade Rush
	comboTarget: Player?,
	comboCount: number,
	lastComboHitTime: number,
	-- Axe: Earthshaker
	lastEarthshakerTime: number,
	-- Bow: Hunter's Mark
	markedTarget: Player?,
	markExpireTime: number,
	-- Scythe: Soul Harvest
	soulHarvestStacks: number,
	soulHarvestExpireTime: number,
}

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------

local combatStates: { [Player]: PlayerCombatState } = {}

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

local function getRootPart(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function isAlive(player: Player): boolean
	local humanoid = getHumanoid(player)
	return humanoid ~= nil and humanoid.Health > 0
end

local function isSpawnProtected(state: PlayerCombatState): boolean
	return os.clock() < state.spawnProtectionEnd
end

--- Check if two players are on the same team (returns false in FFA).
local function isSameTeam(playerA: Player, playerB: Player): boolean
	local ok1, teamA = pcall(function()
		return getPlayerTeamFunc:Invoke(playerA)
	end)
	if not ok1 or typeof(teamA) ~= "number" or teamA == 0 then
		return false -- FFA or error: no friendly fire
	end
	local ok2, teamB = pcall(function()
		return getPlayerTeamFunc:Invoke(playerB)
	end)
	if not ok2 or typeof(teamB) ~= "number" or teamB == 0 then
		return false
	end
	return teamA == teamB
end

--- Returns the effective perk for a player's equipped weapon, merging upgrade overrides.
local function getEffectivePerk(player: Player, weaponName: string): typeof(WeaponConfig.Sword.perk)
	local weaponStats = WeaponConfig[weaponName]
	if not weaponStats or not weaponStats.perk then
		return nil
	end

	-- Clone base perk
	local perk: { [string]: any } = {}
	for k, v in weaponStats.perk :: any do
		perk[k] = v
	end

	-- Query player's upgrade tier and merge overrides
	local tier: number = 1
	local ok, result = pcall(function()
		return getWeaponTierFunc:Invoke(player, weaponName)
	end)
	if ok and typeof(result) == "number" then
		tier = result
	end

	if tier >= 2 then
		local overrides = ShopConfig.GetPerkOverrides(weaponName, tier)
		if overrides then
			for k, v in overrides do
				perk[k] = v
			end
		end
	end

	return perk :: any
end

------------------------------------------------------------------------
-- Melee hit detection (distance + frontal arc)
------------------------------------------------------------------------

local function getMeleeTargets(attacker: Player, range: number): { Player }
	local rootPart = getRootPart(attacker)
	if not rootPart then
		return {}
	end

	local origin = rootPart.Position
	local lookDirection = rootPart.CFrame.LookVector
	local halfArc = math.rad(70) -- ~140 degree frontal arc

	local hits: { Player } = {}

	for _, otherPlayer in Players:GetPlayers() do
		if otherPlayer == attacker then
			continue
		end
		if not isAlive(otherPlayer) then
			continue
		end
		if isSameTeam(attacker, otherPlayer) then
			continue
		end

		local targetRoot = getRootPart(otherPlayer)
		if not targetRoot then
			continue
		end

		local toTarget = targetRoot.Position - origin
		local distance = toTarget.Magnitude

		if distance > range then
			continue
		end

		-- Check frontal arc
		local directionFlat = Vector3.new(lookDirection.X, 0, lookDirection.Z).Unit
		local toTargetFlat = Vector3.new(toTarget.X, 0, toTarget.Z)
		if toTargetFlat.Magnitude > 0 then
			toTargetFlat = toTargetFlat.Unit
			local angle = math.acos(math.clamp(directionFlat:Dot(toTargetFlat), -1, 1))
			if angle <= halfArc then
				table.insert(hits, otherPlayer)
			end
		end
	end

	return hits
end

------------------------------------------------------------------------
-- NPC (Bear) melee hit detection
------------------------------------------------------------------------

local function getMeleeNPCTargets(attacker: Player, range: number): { Humanoid }
	local rootPart = getRootPart(attacker)
	if not rootPart then return {} end

	local origin = rootPart.Position
	local lookDir = rootPart.CFrame.LookVector
	local halfArc = math.rad(70)
	local hits: { Humanoid } = {}

	local arenaFolder = workspace:FindFirstChild("Arena")
	local wildlifeFolder = arenaFolder and arenaFolder:FindFirstChild("AmbientWildlife")
	if not wildlifeFolder then return {} end

	for _, npc in wildlifeFolder:GetChildren() do
		if not npc:IsA("Model") then continue end
		local npcHumanoid = npc:FindFirstChildOfClass("Humanoid")
		local npcRoot = npc:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not npcHumanoid or not npcRoot or npcHumanoid.Health <= 0 then continue end

		local toNPC = npcRoot.Position - origin
		if toNPC.Magnitude > range then continue end

		local flat = Vector3.new(toNPC.X, 0, toNPC.Z)
		if flat.Magnitude > 0 then
			local lookFlat = Vector3.new(lookDir.X, 0, lookDir.Z).Unit
			local angle = math.acos(math.clamp(lookFlat:Dot(flat.Unit), -1, 1))
			if angle <= halfArc then
				table.insert(hits, npcHumanoid)
			end
		end
	end
	return hits
end

------------------------------------------------------------------------
-- NPC (Bear) AoE hit detection
------------------------------------------------------------------------

local function getAoENPCTargets(attacker: Player, radius: number): { Humanoid }
	local rootPart = getRootPart(attacker)
	if not rootPart then return {} end

	local origin = rootPart.Position
	local hits: { Humanoid } = {}

	local arenaFolder = workspace:FindFirstChild("Arena")
	local wildlifeFolder = arenaFolder and arenaFolder:FindFirstChild("AmbientWildlife")
	if not wildlifeFolder then return {} end

	for _, npc in wildlifeFolder:GetChildren() do
		if not npc:IsA("Model") then continue end
		local npcHumanoid = npc:FindFirstChildOfClass("Humanoid")
		local npcRoot = npc:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not npcHumanoid or not npcRoot or npcHumanoid.Health <= 0 then continue end

		if (npcRoot.Position - origin).Magnitude <= radius then
			table.insert(hits, npcHumanoid)
		end
	end
	return hits
end

------------------------------------------------------------------------
-- AoE hit detection (360 degree radius, used by Earthshaker)
------------------------------------------------------------------------

local function getAoETargets(attacker: Player, radius: number): { Player }
	local rootPart = getRootPart(attacker)
	if not rootPart then
		return {}
	end

	local origin = rootPart.Position
	local hits: { Player } = {}

	for _, otherPlayer in Players:GetPlayers() do
		if otherPlayer == attacker then
			continue
		end
		if not isAlive(otherPlayer) then
			continue
		end
		if isSameTeam(attacker, otherPlayer) then
			continue
		end

		local targetRoot = getRootPart(otherPlayer)
		if not targetRoot then
			continue
		end

		if (targetRoot.Position - origin).Magnitude <= radius then
			table.insert(hits, otherPlayer)
		end
	end

	return hits
end

------------------------------------------------------------------------
-- Ranged hit detection (raycasting, used by Bow)
------------------------------------------------------------------------

local function getRangedTarget(attacker: Player, targetPosition: Vector3, maxRange: number): (Player?, boolean, Model?)
	local character = attacker.Character
	if not character then
		return nil, false
	end

	local head = character:FindFirstChild("Head") :: BasePart?
	if not head then
		return nil, false
	end

	local origin = head.Position
	local direction = (targetPosition - origin)
	local distance = direction.Magnitude

	-- Clamp direction to max range
	if distance > maxRange then
		direction = direction.Unit * maxRange
	end

	-- Build ignore list (attacker's character)
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }

	local result = workspace:Raycast(origin, direction, rayParams)
	if not result then
		return nil, false
	end

	-- Find which player (if any) owns the hit part
	local hitPart = result.Instance
	local hitModel = hitPart:FindFirstAncestorOfClass("Model")
	if not hitModel then
		return nil, false
	end

	local hitPlayer: Player? = nil
	for _, otherPlayer in Players:GetPlayers() do
		if otherPlayer.Character == hitModel and otherPlayer ~= attacker then
			hitPlayer = otherPlayer
			break
		end
	end

	if not hitPlayer then
		return nil, false, hitModel
	end

	if not isAlive(hitPlayer) then
		return nil, false
	end

	-- Prevent friendly fire in team modes
	if isSameTeam(attacker, hitPlayer) then
		return nil, false
	end

	-- Check headshot
	local isHeadshot = hitPart.Name == "Head"

	return hitPlayer, isHeadshot
end

------------------------------------------------------------------------
-- Perk: Sword — Blade Rush
------------------------------------------------------------------------

local function handleBladeRush(attacker: Player, victim: Player, state: PlayerCombatState, perk: typeof(WeaponConfig.Sword.perk))
	if not perk then
		return false, 1 -- no perk, normal damage multiplier
	end

	local now = os.clock()
	local comboResetTime = perk.comboResetTime or 2
	local comboRequired = perk.comboHitsRequired or 4

	-- Reset combo if target changed or too much time passed
	if state.comboTarget ~= victim or (now - state.lastComboHitTime) > comboResetTime then
		state.comboTarget = victim
		state.comboCount = 0
	end

	state.comboCount += 1
	state.lastComboHitTime = now

	-- Check if this hit triggers the perk
	if state.comboCount >= comboRequired then
		state.comboCount = 0 -- reset for next combo

		-- Stun the target
		local stunDuration = perk.comboStunDuration or 0.5
		local victimHumanoid = getHumanoid(victim)
		if victimHumanoid then
			local originalSpeed = victimHumanoid.WalkSpeed
			victimHumanoid.WalkSpeed = 0
			task.delay(stunDuration, function()
				local hum = getHumanoid(victim)
				if hum and hum.WalkSpeed == 0 then
					hum.WalkSpeed = originalSpeed
				end
			end)
		end

		-- Notify both players of the stun
		Remotes.PerkEffect:FireClient(attacker, {
			perk = "BladeRush",
			targetName = victim.Name,
			stunDuration = stunDuration,
		})
		Remotes.PerkEffect:FireClient(victim, {
			perk = "BladeRush",
			stunned = true,
			stunDuration = stunDuration,
		})

		return true, perk.comboDamageMultiplier or 2
	end

	return false, 1
end

------------------------------------------------------------------------
-- Perk: Axe — Earthshaker (special attack)
------------------------------------------------------------------------

local function handleEarthshaker(attacker: Player, state: PlayerCombatState)
	local weaponStats = WeaponConfig[state.equippedWeapon]
	if not weaponStats or not weaponStats.perk or weaponStats.perk.name ~= "Earthshaker" then
		return
	end

	local perk = getEffectivePerk(attacker, state.equippedWeapon)
	if not perk then
		return
	end
	local now = os.clock()
	local cooldown = perk.cooldown or 8

	-- Check cooldown
	if (now - state.lastEarthshakerTime) < cooldown then
		return
	end
	state.lastEarthshakerTime = now

	local radius = perk.aoeRadius or 8
	local aoeDamage = perk.aoeDamage or 40
	local knockbackForce = perk.knockbackForce or 50

	local targets = getAoETargets(attacker, radius)
	local attackerRoot = getRootPart(attacker)
	if not attackerRoot then
		return
	end

	for _, victim in targets do
		applyDamage(attacker, victim, aoeDamage)

		-- Apply knockback
		local victimRoot = getRootPart(victim)
		if victimRoot then
			local knockDirection = (victimRoot.Position - attackerRoot.Position).Unit
			-- Add upward component for a slam feel
			local knockVelocity = knockDirection * knockbackForce + Vector3.new(0, knockbackForce * 0.5, 0)

			local bodyVelocity = Instance.new("BodyVelocity")
			bodyVelocity.Velocity = knockVelocity
			bodyVelocity.MaxForce = Vector3.new(1e5, 1e5, 1e5)
			bodyVelocity.Parent = victimRoot

			-- Remove after a short time
			task.delay(0.3, function()
				bodyVelocity:Destroy()
			end)
		end
	end

	-- Also damage NPC bears in the AoE
	local npcAoETargets = getAoENPCTargets(attacker, radius)
	for _, npcHumanoid in npcAoETargets do
		npcHumanoid:TakeDamage(aoeDamage)
		if npcHumanoid.Parent then
			npcHumanoid.Parent:SetAttribute("LastAttacker", attacker.UserId)
		end
		Remotes.DamageDealt:FireClient(attacker, {
			targetName = "Bear",
			damage = aoeDamage,
			isHit = true,
		})
	end

	-- Notify all nearby players of the slam effect
	Remotes.PerkEffect:FireAllClients({
		perk = "Earthshaker",
		attackerName = attacker.Name,
		position = attackerRoot.Position,
		radius = radius,
	})
end

------------------------------------------------------------------------
-- Perk: Bow — Hunter's Mark
------------------------------------------------------------------------

local function handleHuntersMark(attacker: Player, victim: Player, state: PlayerCombatState, perk: typeof(WeaponConfig.Bow.perk))
	if not perk then
		return
	end

	local markDuration = perk.markDuration or 5

	state.markedTarget = victim
	state.markExpireTime = os.clock() + markDuration

	-- Tell the bow user who is marked so they can render the highlight
	Remotes.PerkEffect:FireClient(attacker, {
		perk = "HuntersMark",
		targetName = victim.Name,
		targetUserId = victim.UserId,
		duration = markDuration,
	})
end

------------------------------------------------------------------------
-- Perk: Scythe — Soul Harvest (triggered on kill)
------------------------------------------------------------------------

local function handleSoulHarvest(killer: Player, state: PlayerCombatState)
	local weaponStats = WeaponConfig[state.equippedWeapon]
	if not weaponStats or not weaponStats.perk or weaponStats.perk.name ~= "SoulHarvest" then
		return
	end

	local perk = getEffectivePerk(killer, state.equippedWeapon)
	if not perk then
		return
	end
	local healAmount = perk.healAmount or 30
	local speedPercent = perk.speedBoostPercent or 0.1
	local boostDuration = perk.speedBoostDuration or 4
	local maxStacks = perk.maxSpeedStacks or 2

	-- Heal the killer
	local humanoid = getHumanoid(killer)
	if humanoid then
		humanoid.Health = math.min(humanoid.Health + healAmount, humanoid.MaxHealth)
	end

	-- Speed boost stacking
	local now = os.clock()
	if now < state.soulHarvestExpireTime then
		-- Existing boost still active — add stack
		state.soulHarvestStacks = math.min(state.soulHarvestStacks + 1, maxStacks)
	else
		state.soulHarvestStacks = 1
	end
	state.soulHarvestExpireTime = now + boostDuration

	-- Apply speed boost
	if humanoid then
		local baseSpeed = GameConfig.BASE_WALK_SPEED
		local totalBoost = 1 + (speedPercent * state.soulHarvestStacks)
		humanoid.WalkSpeed = baseSpeed * totalBoost
	end

	-- Schedule speed reset
	local expireTime = state.soulHarvestExpireTime
	task.delay(boostDuration, function()
		-- Only reset if no new stacks were added
		if state.soulHarvestExpireTime == expireTime then
			state.soulHarvestStacks = 0
			local hum = getHumanoid(killer)
			if hum then
				hum.WalkSpeed = GameConfig.BASE_WALK_SPEED
			end
		end
	end)

	-- Notify the killer of the perk activation
	Remotes.PerkEffect:FireClient(killer, {
		perk = "SoulHarvest",
		healAmount = healAmount,
		stacks = state.soulHarvestStacks,
		duration = boostDuration,
	})
end

------------------------------------------------------------------------
-- Damage application
------------------------------------------------------------------------

function applyDamage(attacker: Player, victim: Player, damage: number)
	local victimState = combatStates[victim]
	if victimState and isSpawnProtected(victimState) then
		return
	end

	local humanoid = getHumanoid(victim)
	if not humanoid then
		return
	end

	-- Track damage contributor for assist credit
	if victimState then
		local current = victimState.damageContributors[attacker] or 0
		victimState.damageContributors[attacker] = current + damage
	end

	humanoid:TakeDamage(damage)

	-- Notify victim of damage for UI
	Remotes.DamageDealt:FireClient(victim, {
		attackerName = attacker.Name,
		damage = damage,
	})

	-- Notify attacker of successful hit
	Remotes.DamageDealt:FireClient(attacker, {
		targetName = victim.Name,
		damage = damage,
		isHit = true,
	})

	-- Check for kill
	if humanoid.Health <= 0 then
		handleKill(attacker, victim)
	end
end

------------------------------------------------------------------------
-- Kill & assist handling
------------------------------------------------------------------------

function handleKill(killer: Player, victim: Player)
	local killerState = combatStates[killer]

	-- Broadcast kill notification to all players
	Remotes.KillNotification:FireAllClients({
		killerName = killer.Name,
		victimName = victim.Name,
		weapon = if killerState then killerState.equippedWeapon else "Sword",
	})

	-- Notify GameManager of the kill for score tracking / win condition
	onPlayerKill:Fire(killer, victim)

	-- Award coins to killer via CoinManager
	addPlayerCoins:Fire(killer, GameConfig.COINS_PER_KILL, "Kill")

	-- Trigger Soul Harvest perk if using Scythe
	if killerState then
		handleSoulHarvest(killer, killerState)
	end

	-- Check for assists
	local victimState = combatStates[victim]
	if victimState then
		local assistThreshold = GameConfig.BASE_HEALTH * GameConfig.ASSIST_DAMAGE_THRESHOLD

		for contributor, totalDamage in victimState.damageContributors do
			if contributor ~= killer and contributor.Parent and totalDamage >= assistThreshold then
				addPlayerCoins:Fire(contributor, GameConfig.COINS_PER_ASSIST, "Assist")
			end
		end

		-- Reset damage tracking for this victim
		victimState.damageContributors = {}
	end
end

------------------------------------------------------------------------
-- Attack input handler
------------------------------------------------------------------------

local function onAttackInput(player: Player, attackData: { [string]: any })
	-- Validate player is alive
	if not isAlive(player) then
		return
	end

	local state = combatStates[player]
	if not state then
		return
	end

	-- Validate weapon exists
	local weaponStats = WeaponConfig[state.equippedWeapon]
	if not weaponStats then
		return
	end

	local actionType = (attackData.action :: string?) or "attack"

	-- Earthshaker special attack (separate cooldown from normal attack)
	if actionType == "special" then
		handleEarthshaker(player, state)
		return
	end

	-- Enforce attack speed cooldown for normal attacks
	local now = os.clock()
	if now - state.lastAttackTime < weaponStats.attackSpeed then
		return
	end
	state.lastAttackTime = now

	-- Perform hit detection based on weapon type
	if weaponStats.weaponType == "Melee" then
		local targets = getMeleeTargets(player, weaponStats.range)
		for _, target in targets do
			local damage = weaponStats.damage

			-- Handle Blade Rush perk for Sword
			if weaponStats.perk and weaponStats.perk.name == "BladeRush" then
				local effectivePerk = getEffectivePerk(player, state.equippedWeapon)
				local _triggered, multiplier = handleBladeRush(player, target, state, effectivePerk)
				damage = math.floor(damage * multiplier)
			end

			applyDamage(player, target, damage)
		end

		-- Also check NPC targets (bears)
		local npcTargets = getMeleeNPCTargets(player, weaponStats.range)
		for _, npcHumanoid in npcTargets do
			npcHumanoid:TakeDamage(weaponStats.damage)
			if npcHumanoid.Parent then
				npcHumanoid.Parent:SetAttribute("LastAttacker", player.UserId)
			end
			Remotes.DamageDealt:FireClient(player, {
				targetName = "Bear",
				damage = weaponStats.damage,
				isHit = true,
			})
		end

	elseif weaponStats.weaponType == "Ranged" then
		-- Bow: raycast from head toward target position
		local targetPos = attackData.targetPosition :: Vector3?
		if not targetPos then
			return
		end

		-- Validate targetPosition is a Vector3 (anti-cheat)
		if typeof(targetPos) ~= "Vector3" then
			return
		end

		local hitPlayer, isHeadshot, hitModel = getRangedTarget(player, targetPos, weaponStats.range)
		if hitPlayer then
			local damage = weaponStats.damage
			local effectivePerk = getEffectivePerk(player, state.equippedWeapon)

			if isHeadshot and effectivePerk and effectivePerk.headshotDamage then
				damage = effectivePerk.headshotDamage
			end

			-- Bow T3: bonus damage if target is marked
			if effectivePerk and effectivePerk.markBonusDamagePercent then
				if state.markedTarget == hitPlayer and os.clock() < state.markExpireTime then
					damage = math.floor(damage * (1 + effectivePerk.markBonusDamagePercent))
				end
			end

			applyDamage(player, hitPlayer, damage)

			-- Hunter's Mark: mark the target on hit
			if effectivePerk and effectivePerk.name == "HuntersMark" then
				handleHuntersMark(player, hitPlayer, state, effectivePerk)
			end

			-- Tell attacker about headshot for VFX
			if isHeadshot then
				Remotes.PerkEffect:FireClient(player, {
					perk = "Headshot",
					targetName = hitPlayer.Name,
				})
			end
		elseif hitModel then
			-- Check if we hit an NPC bear
			local npcHumanoid = hitModel:FindFirstChildOfClass("Humanoid")
			if npcHumanoid and npcHumanoid.Health > 0 then
				local wildlifeFolder = hitModel:FindFirstAncestorOfClass("Folder")
				if wildlifeFolder and wildlifeFolder.Name == "AmbientWildlife" then
					npcHumanoid:TakeDamage(weaponStats.damage)
					hitModel:SetAttribute("LastAttacker", player.UserId)
					Remotes.DamageDealt:FireClient(player, {
						targetName = "Bear",
						damage = weaponStats.damage,
						isHit = true,
					})
				end
			end
		end
	end
end

------------------------------------------------------------------------
-- Player lifecycle
------------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	combatStates[player] = {
		lastAttackTime = 0,
		equippedWeapon = "Sword",
		spawnProtectionEnd = 0,
		damageContributors = {},
		-- Blade Rush
		comboTarget = nil,
		comboCount = 0,
		lastComboHitTime = 0,
		-- Earthshaker
		lastEarthshakerTime = 0,
		-- Hunter's Mark
		markedTarget = nil,
		markExpireTime = 0,
		-- Soul Harvest
		soulHarvestStacks = 0,
		soulHarvestExpireTime = 0,
	}

	player.CharacterAdded:Connect(function(_character: Model)
		local state = combatStates[player]
		if state then
			state.spawnProtectionEnd = os.clock() + GameConfig.SPAWN_PROTECTION
			state.damageContributors = {}
		end
	end)
end

local function onPlayerRemoving(player: Player)
	combatStates[player] = nil
end

------------------------------------------------------------------------
-- Init
------------------------------------------------------------------------

Remotes.AttackInput.OnServerEvent:Connect(onAttackInput)

-- Listen for weapon equips from ShopHandler
equipWeaponEvent.Event:Connect(function(player: Player, weaponName: string)
	local state = combatStates[player]
	if not state then
		return
	end
	state.equippedWeapon = weaponName
	-- Reset perk state when switching weapons
	state.comboTarget = nil
	state.comboCount = 0
	state.lastComboHitTime = 0
	state.lastEarthshakerTime = 0
	state.markedTarget = nil
	state.markExpireTime = 0
	state.soulHarvestStacks = 0
	state.soulHarvestExpireTime = 0
end)

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- Handle players who joined before this script ran
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[CombatHandler] Initialized")
