--!strict
--[[
	AmbientWildlife (Server ModuleScript)
	Spawns interactive GrizzlyBear NPCs in the Jungle Ruins arena.

	Bears have a full behavior state machine:
	  • idle / eating / wandering  — peaceful cycle
	  • alert / charging / attacking — player aggro
	  • fighting / fleeing — bear-vs-bear territorial combat
	  • dead — ragdoll → respawn

	Rigging: HumanoidRootPart + Humanoid, BodyRoot (terrain tilt),
	4 leg Motor6Ds (walk cycle), NeckJoint (head dip), JawJoint (mouth).

	Single RunService.Heartbeat drives all animation (legs, tilt, head/jaw).
	Per-bear coroutines handle behavior timing with 0.5s threat checks.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("GameConfig"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

------------------------------------------------------------------------
-- Server-side BindableEvents (for coin rewards)
------------------------------------------------------------------------

local serverEvents = ServerScriptService:FindFirstChild("ServerEvents") :: Folder
local addPlayerCoins: BindableEvent? = if serverEvents
	then serverEvents:FindFirstChild("AddPlayerCoins") :: BindableEvent?
	else nil

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

type BearConfig = {
	countMin: number,
	countMax: number,
	pauseMin: number,
	pauseMax: number,
	moveDistMin: number,
	moveDistMax: number,
	preferredZones: { string },
	walkAmplitude: number,
	walkFrequency: number,
}

type BearRig = {
	legMotors: { Motor6D },
	bodyTilt: Motor6D,
	neckMotor: Motor6D?,
	jawMotor: Motor6D?,
}

type BearRecord = {
	model: Model,
	rig: BearRig,
	humanoid: Humanoid,
	state: string,
	aggroTarget: Player?,
	bearTarget: BearRecord?,
	spawnPos: Vector3,
	alive: boolean,
	lastAttackTime: number,
	lastBearFightTime: number,
	thread: thread?,
}

------------------------------------------------------------------------
-- Module
------------------------------------------------------------------------

local AmbientWildlife = {}

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------

local active: boolean = false
local npcFolder: Folder? = nil
local activeBears: { BearRecord } = {}
local heartbeatConnection: RBXScriptConnection? = nil
local getTerrainHeightRef: ((number, number) -> number)? = nil
local rngRef: Random? = nil

------------------------------------------------------------------------
-- Configuration
------------------------------------------------------------------------

local PLACEHOLDER_COLOR = Color3.fromRGB(255, 105, 180)
local PLACEHOLDER_MATERIAL = Enum.Material.SmoothPlastic
local PLACEHOLDER_SIZE = Vector3.new(2.5, 3, 4)

local BEAR_HIP_HEIGHT = 3.5
local BEAR_HALF_LENGTH = 3.5
local MAX_TILT = math.rad(25)
local ARENA_BOUND = 450

local BEAR_CONFIG: BearConfig = {
	countMin = 10, countMax = 12,
	pauseMin = 2, pauseMax = 4,
	moveDistMin = 20, moveDistMax = 60,
	preferredZones = { "forest" },
	walkAmplitude = 0.4,
	walkFrequency = 1.2,
}

-- Eating cycle timing
local EATING_MIN = 5
local EATING_MAX = 12

-- Threat check interval (seconds)
local THREAT_CHECK_INTERVAL = 0.5

-- Alert pause before charging
local ALERT_PAUSE_MIN = 1
local ALERT_PAUSE_MAX = 2

-- Bear fight cooldown
local BEAR_FIGHT_COOLDOWN = 2

-- Death ragdoll visible time
local DEATH_LINGER = 3

-- Forward declaration for mutual recursion (onBearDied → spawnBearAt)
local spawnBearAt: (pos: Vector3) -> ()

------------------------------------------------------------------------
-- Utility
------------------------------------------------------------------------

local function collectParts(inst: Instance): { BasePart }
	local parts: { BasePart } = {}
	for _, desc in inst:GetDescendants() do
		if desc:IsA("BasePart") then
			table.insert(parts, desc :: BasePart)
		end
	end
	return parts
end

------------------------------------------------------------------------
-- GrizzlyBear Rigging
------------------------------------------------------------------------

local function rigGrizzlyBear(model: Model): BearRig
	-- 1. Remove all Sound instances (asset IDs inaccessible)
	for _, desc in model:GetDescendants() do
		if desc:IsA("Sound") then
			desc:Destroy()
		end
	end

	-- 2. Create invisible HumanoidRootPart
	local pivot = model:GetPivot()
	local rootPart = Instance.new("Part")
	rootPart.Name = "HumanoidRootPart"
	rootPart.Size = Vector3.new(2, 2, 1)
	rootPart.Transparency = 1
	rootPart.CanCollide = false
	rootPart.Anchored = false
	rootPart.CFrame = pivot
	rootPart.Parent = model
	model.PrimaryPart = rootPart

	-- 2b. Create invisible BodyRoot for terrain tilt
	local bodyRoot = Instance.new("Part")
	bodyRoot.Name = "BodyRoot"
	bodyRoot.Size = Vector3.new(2, 2, 1)
	bodyRoot.Transparency = 1
	bodyRoot.CanCollide = false
	bodyRoot.Anchored = false
	bodyRoot.CFrame = pivot
	bodyRoot.Parent = model

	-- 2c. Motor6D: HumanoidRootPart → BodyRoot (terrain tilt)
	local bodyTilt = Instance.new("Motor6D")
	bodyTilt.Name = "BodyTilt"
	bodyTilt.Part0 = rootPart
	bodyTilt.Part1 = bodyRoot
	bodyTilt.C0 = CFrame.new()
	bodyTilt.C1 = CFrame.new()
	bodyTilt.MaxVelocity = 1
	bodyTilt.Parent = rootPart

	-- 3. Add Humanoid with health
	local humanoid = Instance.new("Humanoid")
	humanoid.WalkSpeed = GameConfig.BEAR_WALK_SPEED
	humanoid.MaxSlopeAngle = 50
	humanoid.HipHeight = BEAR_HIP_HEIGHT
	humanoid.MaxHealth = GameConfig.BEAR_HEALTH
	humanoid.Health = GameConfig.BEAR_HEALTH
	humanoid.Parent = model

	-- 4. Find sub-models and key parts
	local armsModel: Model? = model:FindFirstChild("arms") :: Model?
	local legsModel: Model? = model:FindFirstChild("Legs") :: Model?
	local bearFootModel: Model? = model:FindFirstChild("bear foot") :: Model?

	local handModels: { Model } = {}
	local footModel: Model? = nil

	for _, child in model:GetChildren() do
		if child.Name == "Hand" and child:IsA("Model") then
			table.insert(handModels, child :: Model)
		end
		if child.Name == "Foot" and child:IsA("Model") then
			footModel = child :: Model
		end
	end

	-- 5. Find shoulder/thigh unions, sort by X
	local shoulders: { BasePart } = {}
	local thighs: { BasePart } = {}

	if armsModel then
		for _, child in armsModel:GetChildren() do
			if child.Name == "Union" and child:IsA("BasePart") then
				table.insert(shoulders, child :: BasePart)
			end
		end
	end

	if legsModel then
		for _, child in legsModel:GetChildren() do
			if child.Name == "Union" and child:IsA("BasePart") then
				table.insert(thighs, child :: BasePart)
			end
		end
	end

	table.sort(shoulders, function(a, b) return a.Position.X < b.Position.X end)
	table.sort(thighs, function(a, b) return a.Position.X < b.Position.X end)
	table.sort(handModels, function(a, b)
		return a:GetPivot().Position.X < b:GetPivot().Position.X
	end)

	-- 6. Build leg assemblies
	type LegAssembly = { root: BasePart, parts: { BasePart }, name: string }
	local legAssemblies: { LegAssembly } = {}

	local function findChild(parent: Instance, name: string): BasePart?
		local child = parent:FindFirstChild(name)
		if child and child:IsA("BasePart") then
			return child :: BasePart
		end
		return nil
	end

	if #shoulders >= 2 and armsModel then
		local leftParts: { BasePart } = { shoulders[1] }
		local lowerArm01 = findChild(armsModel, "LowerArm01")
		if lowerArm01 then table.insert(leftParts, lowerArm01) end
		if #handModels >= 2 then
			for _, p in collectParts(handModels[1]) do
				table.insert(leftParts, p)
			end
		end
		table.insert(legAssemblies, { root = shoulders[1], parts = leftParts, name = "FrontLeft" })

		local rightParts: { BasePart } = { shoulders[2] }
		local lowerArm02 = findChild(armsModel, "LowerArm02")
		if lowerArm02 then table.insert(rightParts, lowerArm02) end
		if #handModels >= 2 then
			for _, p in collectParts(handModels[2]) do
				table.insert(rightParts, p)
			end
		end
		table.insert(legAssemblies, { root = shoulders[2], parts = rightParts, name = "FrontRight" })
	end

	if #thighs >= 2 and legsModel then
		local leftParts: { BasePart } = { thighs[1] }
		local calf01 = findChild(legsModel, "Calf01")
		if calf01 then table.insert(leftParts, calf01) end
		if footModel then
			for _, p in collectParts(footModel) do
				table.insert(leftParts, p)
			end
		end
		table.insert(legAssemblies, { root = thighs[1], parts = leftParts, name = "RearLeft" })

		local rightParts: { BasePart } = { thighs[2] }
		local calf02 = findChild(legsModel, "Calf02")
		if calf02 then table.insert(rightParts, calf02) end
		if bearFootModel then
			for _, p in collectParts(bearFootModel) do
				table.insert(rightParts, p)
			end
		end
		table.insert(legAssemblies, { root = thighs[2], parts = rightParts, name = "RearRight" })
	end

	-- 7. Set of all leg parts (exclude from body welding)
	local legPartSet: { [BasePart]: boolean } = {}
	for _, assembly in legAssemblies do
		for _, part in assembly.parts do
			legPartSet[part] = true
		end
	end

	-- 8. Find Head sub-model for neck/jaw rigging
	local headModel: Model? = model:FindFirstChild("Head") :: Model?
	local headPartSet: { [BasePart]: boolean } = {}
	if headModel and headModel:IsA("Model") then
		for _, desc in headModel:GetDescendants() do
			if desc:IsA("BasePart") then
				headPartSet[desc :: BasePart] = true
			end
		end
		-- Include the head model's primary part if it is a BasePart
		if headModel:IsA("BasePart") then
			headPartSet[headModel :: any] = true
		end
	end

	-- Identify neck root (Neck01) and jaw for Motor6D rigging
	local neckRoot: BasePart? = nil
	local jawPart: BasePart? = nil

	if headModel then
		-- Look for Neck01 in the head model or as a sibling
		local neck01 = headModel:FindFirstChild("Neck01")
		if not neck01 then
			neck01 = model:FindFirstChild("Neck01")
		end
		if neck01 and neck01:IsA("BasePart") then
			neckRoot = neck01 :: BasePart
			headPartSet[neck01 :: BasePart] = true
		end

		-- Look for Jaw part
		local jaw = headModel:FindFirstChild("Jaw")
		if not jaw then
			jaw = model:FindFirstChild("Jaw")
		end
		if jaw and jaw:IsA("BasePart") then
			jawPart = jaw :: BasePart
			headPartSet[jaw :: BasePart] = true
		end
	end

	-- 9. Remove existing Belly2Joint Motor6D
	local belly1 = model:FindFirstChild("Belly1")
	if belly1 then
		local belly2Joint = belly1:FindFirstChild("Belly2Joint")
		if belly2Joint then
			belly2Joint:Destroy()
		end
	end

	-- 10. Unanchor everything and disable collision
	for _, desc in model:GetDescendants() do
		if desc:IsA("BasePart") then
			(desc :: BasePart).Anchored = false
			(desc :: BasePart).CanCollide = false
		end
	end

	-- 11. Weld all non-leg, non-head parts to BodyRoot (rigid body)
	for _, desc in model:GetDescendants() do
		if desc:IsA("BasePart")
			and desc ~= rootPart
			and desc ~= bodyRoot
			and not legPartSet[desc :: BasePart]
			and not headPartSet[desc :: BasePart]
		then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = bodyRoot
			weld.Part1 = desc :: BasePart
			weld.Parent = bodyRoot
		end
	end

	-- 12. Rig neck and jaw Motor6Ds
	local neckMotor: Motor6D? = nil
	local jawMotor: Motor6D? = nil

	if neckRoot then
		-- Create NeckJoint: bodyRoot → neckRoot
		local motor = Instance.new("Motor6D")
		motor.Name = "NeckJoint"
		motor.Part0 = bodyRoot
		motor.Part1 = neckRoot

		-- Place joint at base of neck (where neck meets body)
		local neckBase = neckRoot.CFrame * CFrame.new(0, -neckRoot.Size.Y * 0.4, 0)
		motor.C0 = bodyRoot.CFrame:ToObjectSpace(neckBase)
		motor.C1 = neckRoot.CFrame:ToObjectSpace(neckBase)
		motor.MaxVelocity = 0.1
		motor.Parent = bodyRoot
		neckMotor = motor

		-- Weld all head parts (except neckRoot and jawPart) to neckRoot
		for part, _ in headPartSet do
			if part ~= neckRoot and part ~= jawPart then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = neckRoot
				weld.Part1 = part
				weld.Parent = neckRoot
			end
		end

		-- Create JawJoint if jaw exists
		if jawPart then
			-- Find the main "Head" BasePart inside the Head model to attach jaw to
			local headBone: BasePart = neckRoot -- fallback
			if headModel then
				-- Look for a part named "Head" or "SecHead" inside the Head model
				for _, child in headModel:GetChildren() do
					if child:IsA("BasePart") and (child.Name == "Head" or child.Name == "SecHead") then
						headBone = child :: BasePart
						break
					end
				end
			end

			local jMotor = Instance.new("Motor6D")
			jMotor.Name = "JawJoint"
			jMotor.Part0 = headBone
			jMotor.Part1 = jawPart

			-- Place at hinge point (top-back of jaw)
			local jawHinge = jawPart.CFrame * CFrame.new(0, jawPart.Size.Y * 0.4, -jawPart.Size.Z * 0.3)
			jMotor.C0 = headBone.CFrame:ToObjectSpace(jawHinge)
			jMotor.C1 = jawPart.CFrame:ToObjectSpace(jawHinge)
			jMotor.MaxVelocity = 0.1
			jMotor.Parent = headBone
			jawMotor = jMotor
		end
	else
		-- No neck found — weld all head parts directly to bodyRoot
		for part, _ in headPartSet do
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = bodyRoot
			weld.Part1 = part
			weld.Parent = bodyRoot
		end
	end

	-- 13. Create leg Motor6Ds from BodyRoot
	local motors: { Motor6D } = {}

	for _, assembly in legAssemblies do
		for _, part in assembly.parts do
			if part ~= assembly.root then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = assembly.root
				weld.Part1 = part
				weld.Parent = assembly.root
			end
		end

		local jointY = assembly.root.Size.Y * 0.4
		local jointWorldCF = assembly.root.CFrame * CFrame.new(0, jointY, 0)
		jointWorldCF = jointWorldCF * CFrame.Angles(0, -math.pi / 2, 0)

		local motor = Instance.new("Motor6D")
		motor.Name = assembly.name .. "Hip"
		motor.Part0 = bodyRoot
		motor.Part1 = assembly.root
		motor.C0 = bodyRoot.CFrame:ToObjectSpace(jointWorldCF)
		motor.C1 = assembly.root.CFrame:ToObjectSpace(jointWorldCF)
		motor.MaxVelocity = 0.15
		motor.Parent = bodyRoot

		table.insert(motors, motor)
	end

	print("[AmbientWildlife] Rigged GrizzlyBear: " .. #motors .. " leg motors"
		.. (if neckMotor then ", neck" else "")
		.. (if jawMotor then ", jaw" else ""))

	return {
		legMotors = motors,
		bodyTilt = bodyTilt,
		neckMotor = neckMotor,
		jawMotor = jawMotor,
	}
end

------------------------------------------------------------------------
-- Prefab Loading
------------------------------------------------------------------------

local function loadBearModel(position: Vector3): (Model, BearRig?)
	local npcsFolder = ServerStorage:FindFirstChild("ArenaPrefabs")
	if npcsFolder then
		npcsFolder = npcsFolder:FindFirstChild("JungleRuins")
	end
	if npcsFolder then
		npcsFolder = npcsFolder:FindFirstChild("NPCs")
	end

	if npcsFolder then
		local prefab = npcsFolder:FindFirstChild("Bear")
		if prefab and prefab:IsA("Model") then
			local clone = prefab:Clone()

			-- Scale bear to half size
			clone:ScaleTo(0.5)

			for _, scriptName in { "Move", "Respawn", "Animation" } do
				local s = clone:FindFirstChild(scriptName)
				if s then s:Destroy() end
			end

			clone:PivotTo(CFrame.new(position.X, position.Y + 5, position.Z))

			local rig = rigGrizzlyBear(clone)
			return clone, rig
		end
	end

	-- Placeholder fallback
	print("[AmbientWildlife] Using placeholder for Bear")

	local part = Instance.new("Part")
	part.Name = "Bear"
	part.Size = PLACEHOLDER_SIZE
	part.Color = PLACEHOLDER_COLOR
	part.Material = PLACEHOLDER_MATERIAL
	part.Anchored = true
	part.CanCollide = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.new(0, 200, 0, 50)
	billboard.StudsOffset = Vector3.new(0, 3, 0)
	billboard.AlwaysOnTop = true

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = "NPC: Bear"
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Parent = billboard

	billboard.Parent = part

	local bearModel = Instance.new("Model")
	bearModel.Name = "Bear"
	part.Parent = bearModel
	bearModel.PrimaryPart = part
	bearModel:PivotTo(CFrame.new(position + Vector3.new(0, PLACEHOLDER_SIZE.Y / 2, 0)))

	return bearModel, nil
end

------------------------------------------------------------------------
-- Spawn Position Finder
------------------------------------------------------------------------

local function findSpawnPositions(
	zoneTypes: { { string } },
	zoneBoundsFunc: (number, number) -> (number, number, number, number),
	getTerrainHeight: (number, number) -> number,
	rng: Random
): { Vector3 }
	local candidates: { { number } } = {}

	for i = 1, #zoneTypes do
		for j = 1, #zoneTypes[i] do
			local zt = zoneTypes[i][j]
			for _, preferred in BEAR_CONFIG.preferredZones do
				if zt == preferred then
					table.insert(candidates, { i, j })
					break
				end
			end
		end
	end

	if #candidates == 0 then
		return {}
	end

	local positions: { Vector3 } = {}
	local count = rng:NextInteger(BEAR_CONFIG.countMin, BEAR_CONFIG.countMax)

	for _ = 1, count do
		local zone = candidates[rng:NextInteger(1, #candidates)]
		local minX, maxX, minZ, maxZ = zoneBoundsFunc(zone[1], zone[2])
		local margin = 8
		local x = rng:NextNumber(minX + margin, maxX - margin)
		local z = rng:NextNumber(minZ + margin, maxZ - margin)
		local y = getTerrainHeight(x, z)

		if y >= -2 and y <= 40 then
			table.insert(positions, Vector3.new(x, y, z))
		end
	end

	return positions
end

------------------------------------------------------------------------
-- Threat Scanning
------------------------------------------------------------------------

local function getBearRootPart(bear: BearRecord): BasePart?
	return bear.model:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function scanForNearestPlayer(bear: BearRecord, range: number): (Player?, number)
	local root = getBearRootPart(bear)
	if not root then return nil, math.huge end

	local bearPos = root.Position
	local nearest: Player? = nil
	local nearestDist = math.huge

	for _, player in Players:GetPlayers() do
		local character = player.Character
		if not character then continue end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then continue end
		local playerRoot = character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not playerRoot then continue end

		local dist = (playerRoot.Position - bearPos).Magnitude
		if dist <= range and dist < nearestDist then
			nearest = player
			nearestDist = dist
		end
	end

	return nearest, nearestDist
end

local function scanForNearestBear(bear: BearRecord, range: number): BearRecord?
	local root = getBearRootPart(bear)
	if not root then return nil end

	local pos = root.Position
	local nearest: BearRecord? = nil
	local nearestDist = math.huge

	for _, other in activeBears do
		if other == bear or not other.alive then continue end
		local otherRoot = getBearRootPart(other)
		if not otherRoot then continue end

		local dist = (otherRoot.Position - pos).Magnitude
		if dist <= range and dist < nearestDist then
			nearest = other
			nearestDist = dist
		end
	end

	return nearest
end

--- Check if a player target is still valid for chasing.
local function isValidAggroTarget(bear: BearRecord): boolean
	local player = bear.aggroTarget
	if not player or not player.Parent then return false end
	local character = player.Character
	if not character then return false end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return false end
	local playerRoot = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not playerRoot then return false end
	local bearRoot = getBearRootPart(bear)
	if not bearRoot then return false end

	local dist = (playerRoot.Position - bearRoot.Position).Magnitude
	return dist <= GameConfig.BEAR_CHASE_RANGE
end

------------------------------------------------------------------------
-- Bear Actions
------------------------------------------------------------------------

--- Face the bear toward a world position.
local function facePosition(bear: BearRecord, targetPos: Vector3)
	local root = getBearRootPart(bear)
	if not root then return end
	local pos = root.Position
	local dir = (targetPos - pos) * Vector3.new(1, 0, 1) -- flatten Y
	if dir.Magnitude > 0.1 then
		root.CFrame = CFrame.lookAt(pos, pos + dir)
	end
end

--- Deal damage to a player (hazard-style, bypasses PvP tracking).
local function attackPlayer(bear: BearRecord, player: Player)
	local character = player.Character
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return end

	-- Respect spawn protection
	if character:FindFirstChild("SpawnProtection") then return end

	humanoid:TakeDamage(GameConfig.BEAR_ATTACK_DAMAGE)
	Remotes.DamageDealt:FireClient(player, {
		attackerName = "Grizzly Bear",
		damage = GameConfig.BEAR_ATTACK_DAMAGE,
	})
end

--- Deal damage in a bear-vs-bear fight.
local function attackBear(attacker: BearRecord, target: BearRecord)
	if not target.alive then return end
	target.humanoid:TakeDamage(GameConfig.BEAR_FIGHT_DAMAGE)
end

--- Wait in small increments. Player attacks are disabled so no threat scanning.
local function waitWithThreatCheck(bear: BearRecord, duration: number): boolean
	local waited = 0
	while active and bear.alive and waited < duration do
		task.wait(THREAT_CHECK_INTERVAL)
		waited += THREAT_CHECK_INTERVAL
	end
	return false
end

------------------------------------------------------------------------
-- Behavior State Machine (per-bear coroutine)
------------------------------------------------------------------------

local function runBearBehavior(bear: BearRecord)
	while active and bear.alive do
		-- Player attacks are disabled — bears are passive toward players.
		-- Clear any lingering aggro target.
		if bear.aggroTarget then
			bear.aggroTarget = nil
			bear.state = "idle"
			bear.humanoid.WalkSpeed = GameConfig.BEAR_WALK_SPEED
		end

		-- PRIORITY 1: Territorial — bear-vs-bear fight
		local nearbyBear = scanForNearestBear(bear, GameConfig.BEAR_FIGHT_RANGE)
		if nearbyBear and not nearbyBear.bearTarget and bear.state ~= "fleeing" then
			bear.state = "fighting"
			bear.bearTarget = nearbyBear
			nearbyBear.bearTarget = bear
			nearbyBear.state = "fighting"

			bear.humanoid.WalkSpeed = 0
			nearbyBear.humanoid.WalkSpeed = 0

			-- Fight loop
			while active and bear.alive and nearbyBear.alive
				and bear.state == "fighting" and nearbyBear.state == "fighting" do

				local now = os.clock()

				-- Both bears exchange hits
				if now - bear.lastBearFightTime >= BEAR_FIGHT_COOLDOWN then
					bear.lastBearFightTime = now
					attackBear(bear, nearbyBear)
				end
				if now - nearbyBear.lastBearFightTime >= BEAR_FIGHT_COOLDOWN then
					nearbyBear.lastBearFightTime = now
					attackBear(nearbyBear, bear)
				end

				-- Face each other
				local bearRoot = getBearRootPart(bear)
				local otherRoot = getBearRootPart(nearbyBear)
				if bearRoot and otherRoot then
					facePosition(bear, otherRoot.Position)
					facePosition(nearbyBear, bearRoot.Position)
				end

				-- Check flee threshold
				local bearHpPct = bear.humanoid.Health / bear.humanoid.MaxHealth
				local otherHpPct = nearbyBear.humanoid.Health / nearbyBear.humanoid.MaxHealth

				if bearHpPct <= GameConfig.BEAR_FLEE_THRESHOLD then
					bear.state = "fleeing"
					bear.bearTarget = nil
					nearbyBear.bearTarget = nil
					nearbyBear.state = "idle"
					nearbyBear.humanoid.WalkSpeed = GameConfig.BEAR_WALK_SPEED
					break
				elseif otherHpPct <= GameConfig.BEAR_FLEE_THRESHOLD then
					nearbyBear.state = "fleeing"
					nearbyBear.bearTarget = nil
					bear.bearTarget = nil
					bear.state = "idle"
					bear.humanoid.WalkSpeed = GameConfig.BEAR_WALK_SPEED
					break
				end

				task.wait(0.5)
			end

			-- If we're fleeing, run away
			if bear.state == "fleeing" then
				bear.humanoid.WalkSpeed = GameConfig.BEAR_CHARGE_SPEED
				local root = getBearRootPart(bear)
				if root then
					local rng2 = rngRef or Random.new()
					local angle = rng2:NextNumber(0, math.pi * 2)
					local fleeTarget = root.Position + Vector3.new(math.cos(angle) * 50, 0, math.sin(angle) * 50)
					bear.humanoid:MoveTo(fleeTarget)
				end
				task.wait(3)
				bear.state = "idle"
				bear.humanoid.WalkSpeed = GameConfig.BEAR_WALK_SPEED
			end

			continue
		end

		-- PRIORITY 4: Normal behavior cycle (eating → wandering → idle)
		local rng = rngRef or Random.new()

		-- Eating
		bear.state = "eating"
		bear.humanoid.WalkSpeed = 0
		local eatDuration = rng:NextNumber(EATING_MIN, EATING_MAX)
		if waitWithThreatCheck(bear, eatDuration) then
			continue
		end
		if not active or not bear.alive then break end

		-- Wandering
		bear.state = "wandering"
		bear.humanoid.WalkSpeed = GameConfig.BEAR_WALK_SPEED

		local root = getBearRootPart(bear)
		if root then
			local angle = rng:NextNumber(0, math.pi * 2)
			local dist = rng:NextNumber(BEAR_CONFIG.moveDistMin, BEAR_CONFIG.moveDistMax)
			local targetX = math.clamp(root.Position.X + math.cos(angle) * dist, -ARENA_BOUND, ARENA_BOUND)
			local targetZ = math.clamp(root.Position.Z + math.sin(angle) * dist, -ARENA_BOUND, ARENA_BOUND)

			local getHeight = getTerrainHeightRef
			if getHeight then
				local targetY = getHeight(targetX, targetZ)
				if targetY >= -2 and targetY <= 40 then
					bear.humanoid:MoveTo(Vector3.new(targetX, targetY, targetZ))

					local moveFinished = false
					local conn = bear.humanoid.MoveToFinished:Once(function()
						moveFinished = true
					end)

					-- Wait for move to finish
					local moveWaited = 0
					local maxMoveTime = dist / GameConfig.BEAR_WALK_SPEED + 5
					while active and bear.alive and not moveFinished and moveWaited < maxMoveTime do
						task.wait(THREAT_CHECK_INTERVAL)
						moveWaited += THREAT_CHECK_INTERVAL
					end

					if not moveFinished then
						conn:Disconnect()
					end
				end
			end
		end

		if not active or not bear.alive then break end

		-- Idle pause
		bear.state = "idle"
		bear.humanoid.WalkSpeed = 0
		local pauseDuration = rng:NextNumber(BEAR_CONFIG.pauseMin, BEAR_CONFIG.pauseMax)
		if waitWithThreatCheck(bear, pauseDuration) then
			continue
		end
	end
end

------------------------------------------------------------------------
-- Bear Death + Respawn
------------------------------------------------------------------------

local function onBearDied(bear: BearRecord)
	bear.alive = false
	bear.state = "dead"
	bear.aggroTarget = nil
	bear.bearTarget = nil

	-- Cancel behavior coroutine
	if bear.thread then
		task.cancel(bear.thread)
		bear.thread = nil
	end

	-- Award coins to last attacker
	local lastAttackerId = bear.model:GetAttribute("LastAttacker")
	if typeof(lastAttackerId) == "number" and addPlayerCoins then
		for _, player in Players:GetPlayers() do
			if player.UserId == lastAttackerId then
				addPlayerCoins:Fire(player, GameConfig.COINS_PER_BEAR_KILL, "Bear Kill")
				break
			end
		end
	end

	-- Wait for ragdoll to be visible, then clean up
	task.wait(DEATH_LINGER)

	if not active then return end

	-- Remove from activeBears
	for i, b in activeBears do
		if b == bear then
			table.remove(activeBears, i)
			break
		end
	end

	bear.model:Destroy()

	-- Respawn after delay
	task.wait(GameConfig.BEAR_RESPAWN_DELAY)

	if not active or not npcFolder then return end

	-- Pick a respawn position near original spawn
	local rng = rngRef or Random.new()
	local getHeight = getTerrainHeightRef
	local respawnPos = bear.spawnPos

	if getHeight then
		-- Try to find a nearby valid position
		for _ = 1, 5 do
			local angle = rng:NextNumber(0, math.pi * 2)
			local dist = rng:NextNumber(10, 30)
			local x = math.clamp(bear.spawnPos.X + math.cos(angle) * dist, -ARENA_BOUND, ARENA_BOUND)
			local z = math.clamp(bear.spawnPos.Z + math.sin(angle) * dist, -ARENA_BOUND, ARENA_BOUND)
			local y = getHeight(x, z)
			if y >= -2 and y <= 40 then
				respawnPos = Vector3.new(x, y, z)
				break
			end
		end
	end

	spawnBearAt(respawnPos)
end

------------------------------------------------------------------------
-- Bear Spawning
------------------------------------------------------------------------

spawnBearAt = function(pos: Vector3)
	if not active or not npcFolder then return end

	local model, rig = loadBearModel(pos)
	model.Parent = npcFolder

	if not rig then return end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	local bear: BearRecord = {
		model = model,
		rig = rig,
		humanoid = humanoid,
		state = "idle",
		aggroTarget = nil,
		bearTarget = nil,
		spawnPos = pos,
		alive = true,
		lastAttackTime = 0,
		lastBearFightTime = 0,
		thread = nil,
	}

	table.insert(activeBears, bear)

	-- Listen for death
	humanoid.Died:Once(function()
		task.spawn(onBearDied, bear)
	end)

	-- Start behavior coroutine
	bear.thread = task.spawn(function()
		runBearBehavior(bear)
	end)
end

------------------------------------------------------------------------
-- Heartbeat Animation (single connection for ALL bears)
------------------------------------------------------------------------

local function startHeartbeat()
	local elapsed = 0
	local currentPitches: { [Model]: number } = {}

	-- Raycast params per bear (exclude all bear models)
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude

	heartbeatConnection = RunService.Heartbeat:Connect(function(dt: number)
		if not active then return end

		elapsed += dt

		-- Update filter list for raycasts (all bear models)
		local filterList: { Instance } = {}
		for _, bear in activeBears do
			table.insert(filterList, bear.model)
		end
		rayParams.FilterDescendantsInstances = filterList

		for _, bear in activeBears do
			if not bear.alive then continue end

			local rootPart = getBearRootPart(bear)
			if not rootPart then continue end

			local rig = bear.rig

			-- === Leg animation ===
			local speed = rootPart.AssemblyLinearVelocity.Magnitude
			local isMoving = speed > 1

			if #rig.legMotors >= 4 then
				if isMoving then
					local phase = elapsed * BEAR_CONFIG.walkFrequency * math.pi * 2
					local swing = math.sin(phase) * BEAR_CONFIG.walkAmplitude

					-- Diagonal pair 1: FrontLeft (1) + RearRight (4)
					rig.legMotors[1].DesiredAngle = swing
					rig.legMotors[4].DesiredAngle = swing

					-- Diagonal pair 2: FrontRight (2) + RearLeft (3)
					rig.legMotors[2].DesiredAngle = -swing
					rig.legMotors[3].DesiredAngle = -swing
				else
					for _, motor in rig.legMotors do
						motor.DesiredAngle = 0
					end
				end
			end

			-- === Terrain slope alignment ===
			local rootCF = rootPart.CFrame
			local pos = rootCF.Position
			local lookDir = rootCF.LookVector

			local rayDown = Vector3.new(0, -30, 0)
			local rayUp = Vector3.new(0, 15, 0)

			local frontOrigin = pos + lookDir * BEAR_HALF_LENGTH + rayUp
			local backOrigin = pos - lookDir * BEAR_HALF_LENGTH + rayUp

			local frontHit = workspace:Raycast(frontOrigin, rayDown, rayParams)
			local backHit = workspace:Raycast(backOrigin, rayDown, rayParams)

			local currentPitch = currentPitches[bear.model] or 0

			if frontHit and backHit then
				local dy = frontHit.Position.Y - backHit.Position.Y
				local targetPitch = math.atan2(dy, BEAR_HALF_LENGTH * 2)
				targetPitch = math.clamp(targetPitch, -MAX_TILT, MAX_TILT)
				currentPitch = currentPitch + (targetPitch - currentPitch) * math.min(dt * 4, 1)
				rig.bodyTilt.C0 = CFrame.Angles(currentPitch, 0, 0)
			end
			currentPitches[bear.model] = currentPitch

			-- === Head/jaw animation (eating state) ===
			if rig.neckMotor then
				if bear.state == "eating" then
					rig.neckMotor.DesiredAngle = 0.5 -- head dips ~28 degrees
				else
					rig.neckMotor.DesiredAngle = 0
				end
			end

			if rig.jawMotor then
				if bear.state == "eating" then
					rig.jawMotor.DesiredAngle = 0.25 -- mouth opens slightly
				else
					rig.jawMotor.DesiredAngle = 0
				end
			end

			-- === WalkSpeed management ===
			-- (Handled by the behavior coroutine, but ensure dead bears stop)
			if not bear.alive then
				bear.humanoid.WalkSpeed = 0
			end
		end
	end)
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

function AmbientWildlife.start(
	arenaFolder: Folder,
	zoneTypes: { { string } },
	zoneBoundsFunc: (number, number) -> (number, number, number, number),
	getTerrainHeight: (number, number) -> number,
	rng: Random
)
	AmbientWildlife.stop()
	active = true
	getTerrainHeightRef = getTerrainHeight
	rngRef = rng

	local folder = Instance.new("Folder")
	folder.Name = "AmbientWildlife"
	folder.Parent = arenaFolder
	npcFolder = folder

	-- Start the single heartbeat connection for all bears
	startHeartbeat()

	-- Spawn bears
	local positions = findSpawnPositions(zoneTypes, zoneBoundsFunc, getTerrainHeight, rng)
	for _, pos in positions do
		spawnBearAt(pos)
	end

	print("[AmbientWildlife] Started — " .. #activeBears .. " bears spawned")
end

function AmbientWildlife.stop()
	active = false

	-- Disconnect heartbeat
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end

	-- Cancel all behavior threads
	for _, bear in activeBears do
		if bear.thread then
			task.cancel(bear.thread)
			bear.thread = nil
		end
	end
	table.clear(activeBears)

	-- Destroy NPC folder
	if npcFolder then
		npcFolder:Destroy()
		npcFolder = nil
	end

	getTerrainHeightRef = nil
	rngRef = nil
end

return AmbientWildlife
