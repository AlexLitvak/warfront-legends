--!strict
--[[
	ArenaHazards (Server Script)
	Runs all environmental hazards and timed events during matches.

	Controlled via BindableEvents in ServerEvents:
	  StartHazards — fire with (arenaType: string) to activate hazards
	  StopHazards  — fire to deactivate all hazards and clean up

	Hazards by arena:
	  Lava Forge:   lava damage, lava rising, geyser eruptions
	  Shadow Maze:  shifting walls, breakable walls
	  Jungle Ruins: dart traps, swing log traps, pit traps, foliage concealment
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("GameConfig"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
local WeaponConfig: { [string]: { damage: number, [string]: any } } =
	require(ReplicatedStorage:WaitForChild("WeaponConfig")) :: any

------------------------------------------------------------------------
-- ServerEvents (shared BindableEvent/Function folder)
------------------------------------------------------------------------

local serverEvents = ServerScriptService:FindFirstChild("ServerEvents")
if not serverEvents then
	serverEvents = Instance.new("Folder")
	serverEvents.Name = "ServerEvents"
	serverEvents.Parent = ServerScriptService
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

local StartHazardsEvent = getOrCreateBindable("BindableEvent", "StartHazards") :: BindableEvent
local StopHazardsEvent = getOrCreateBindable("BindableEvent", "StopHazards") :: BindableEvent

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------

local running = false
local currentArenaType = ""
local connections: { RBXScriptConnection } = {}
local activeTweens: { Tween } = {}

-- Lava Forge
local lavaLevel = 0

-- Shadow Maze: shifting wall toggle (true = at shifted position)
local shiftedState: { [Instance]: boolean } = {}

-- Shadow Maze: breakable wall health
local wallHealth: { [Instance]: number } = {}

-- Jungle Ruins: dart trap cooldowns (os.clock of last trigger)
local dartCooldowns: { [Instance]: number } = {}

-- Jungle Ruins: pit trap active flag (prevents re-trigger while open)
local pitActive: { [Instance]: boolean } = {}

-- Jungle Ruins: swing log per-player damage cooldown
local logDamageCooldowns: { [Player]: number } = {}

-- Jungle Ruins: foliage concealment state per player
local foliageState: { [Player]: boolean } = {}

-- Player equipped weapons (tracked for breakable wall damage)
local playerWeapons: { [Player]: string } = {}

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function getHumanoidRootPart(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

local function isAlive(player: Player): boolean
	local humanoid = getHumanoid(player)
	return humanoid ~= nil and humanoid.Health > 0
end

local function getPlayerFromPart(part: BasePart): Player?
	local character = part:FindFirstAncestorOfClass("Model")
	if not character then
		return nil
	end
	return Players:GetPlayerFromCharacter(character)
end

local function trackConnection(conn: RBXScriptConnection)
	table.insert(connections, conn)
end

local function trackTween(tween: Tween)
	table.insert(activeTweens, tween)
end

--- Apply knockback using BodyVelocity (matches CombatHandler pattern).
local function applyKnockback(rootPart: BasePart, direction: Vector3, force: number)
	local knockVelocity = direction.Unit * force + Vector3.new(0, force * 0.5, 0)
	local bodyVelocity = Instance.new("BodyVelocity")
	bodyVelocity.Velocity = knockVelocity
	bodyVelocity.MaxForce = Vector3.new(1e5, 1e5, 1e5)
	bodyVelocity.Parent = rootPart
	task.delay(0.3, function()
		bodyVelocity:Destroy()
	end)
end

--- AABB proximity check: is rootPart within margin studs of part's bounding box?
local function isNearPart(rootPart: BasePart, part: BasePart, margin: number): boolean
	local diff = rootPart.Position - part.Position
	local halfSize = part.Size / 2
	return math.abs(diff.X) <= halfSize.X + margin
		and math.abs(diff.Z) <= halfSize.Z + margin
		and math.abs(diff.Y) <= halfSize.Y + margin
end

--- Interruptible wait: sleeps in 1-second increments, returns false if stopped.
local function hazardWait(seconds: number): boolean
	local elapsed = 0
	while running and elapsed < seconds do
		task.wait(1)
		elapsed += 1
	end
	return running
end

------------------------------------------------------------------------
-- LAVA FORGE — Lava Damage
-- Every 0.5s, check players against LavaZone parts. Deal 5 HP/tick
-- (10 HP/sec from GameConfig). Fire red flash to affected clients.
------------------------------------------------------------------------

local function startLavaDamage()
	task.spawn(function()
		local damagePerTick = GameConfig.LAVA_DAMAGE_PER_SEC / 2

		while running do
			task.wait(0.5)
			if not running then break end

			local lavaZones = CollectionService:GetTagged("LavaZone")
			if #lavaZones == 0 then continue end

			for _, player in Players:GetPlayers() do
				if not isAlive(player) then continue end
				local rootPart = getHumanoidRootPart(player)
				if not rootPart then continue end

				local inLava = false
				for _, zone in lavaZones do
					if not zone:IsA("BasePart") then continue end
					if isNearPart(rootPart, zone, 2) then
						inLava = true
						break
					end
				end

				if inLava then
					local humanoid = getHumanoid(player)
					if humanoid then
						humanoid:TakeDamage(damagePerTick)
						Remotes.ArenaEvent:FireClient(player, {
							event = "LavaDamage",
							damage = damagePerTick,
						})
					end
				end
			end
		end
	end)
end

------------------------------------------------------------------------
-- LAVA FORGE — Lava Rising
-- Every LAVA_SHRINK_INTERVAL (120s), raise lava by 10 studs.
-- Warning 10s before. Tween lava tiles upward over 5s. Submerge
-- Level1 platforms. Destroy bridges below the new lava level.
------------------------------------------------------------------------

local function startLavaRising()
	task.spawn(function()
		local WARNING_LEAD = 10
		local RISE_AMOUNT = 10
		local TWEEN_DURATION = 5

		while running do
			-- Wait for interval minus warning lead
			if not hazardWait(GameConfig.LAVA_SHRINK_INTERVAL - WARNING_LEAD) then break end

			-- Fire warning to all clients
			Remotes.ArenaEvent:FireAllClients({
				event = "LavaWarning",
				message = "LAVA RISING IN 10 SECONDS",
				countdown = WARNING_LEAD,
			})

			if not hazardWait(WARNING_LEAD) then break end

			-- Raise lava level
			lavaLevel += RISE_AMOUNT

			-- Tween all lava floor tiles upward
			local tweenInfo = TweenInfo.new(TWEEN_DURATION, Enum.EasingStyle.Linear)
			for _, zone in CollectionService:GetTagged("LavaZone") do
				if not zone:IsA("BasePart") then continue end
				-- Only tween original lava floor tiles, not newly-tagged platforms
				if string.find(zone.Name, "LavaFloorTile") or zone.Name == "LavaFloorTile_Placeholder" then
					local tween = TweenService:Create(zone, tweenInfo, {
						Position = zone.Position + Vector3.new(0, RISE_AMOUNT, 0),
					})
					trackTween(tween)
					tween:Play()
				end
			end

			-- Wait for tween to finish
			task.wait(TWEEN_DURATION)
			if not running then break end

			-- Tag Level1 platforms as LavaZone if their top is at or below lava level
			for _, part in CollectionService:GetTagged("LavaForge_Level1") do
				if not part:IsA("BasePart") then continue end
				local topY = part.Position.Y + part.Size.Y / 2
				if topY <= lavaLevel then
					CollectionService:AddTag(part, "LavaZone")
				end
			end

			-- Destroy bridges whose Y is below the new lava level
			for _, bridge in CollectionService:GetTagged("LavaForge_Bridge") do
				local bridgeY = bridge:GetAttribute("BridgeY")
				if bridgeY and bridgeY <= lavaLevel then
					bridge:Destroy()
				end
			end

			Remotes.ArenaEvent:FireAllClients({
				event = "LavaRisen",
				newLevel = lavaLevel,
			})
		end
	end)
end

------------------------------------------------------------------------
-- LAVA FORGE — Geyser Eruptions
-- Every LAVA_ERUPTION_INTERVAL (90s), erupt 2-3 random geysers.
-- Visual column + launch nearby players upward + 10 damage.
------------------------------------------------------------------------

local function startGeyserEruptions()
	task.spawn(function()
		while running do
			if not hazardWait(GameConfig.LAVA_ERUPTION_INTERVAL) then break end

			local geysers = CollectionService:GetTagged("Geyser")
			if #geysers == 0 then continue end

			-- Pick 2-3 random geysers
			local count = math.min(math.random(2, 3), #geysers)
			local shuffled = table.clone(geysers)
			for i = #shuffled, 2, -1 do
				local j = math.random(1, i)
				shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
			end

			for idx = 1, count do
				local geyser = shuffled[idx]
				if not geyser:IsA("BasePart") then continue end

				local origin = geyser.Position

				-- Visual eruption column
				local column = Instance.new("Part")
				column.Name = "GeyserColumn"
				column.Size = Vector3.new(4, 1, 4)
				column.Position = origin
				column.Anchored = true
				column.CanCollide = false
				column.Material = Enum.Material.Neon
				column.Color = Color3.fromRGB(255, 160, 40)
				column.Transparency = 0.3
				column.Parent = Workspace

				local riseTween = TweenService:Create(
					column,
					TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Size = Vector3.new(4, 30, 4), Position = origin + Vector3.new(0, 15, 0) }
				)
				trackTween(riseTween)
				riseTween:Play()

				-- Damage and launch nearby players
				for _, player in Players:GetPlayers() do
					if not isAlive(player) then continue end
					local rootPart = getHumanoidRootPart(player)
					if not rootPart then continue end

					if (rootPart.Position - origin).Magnitude <= 8 then
						local humanoid = getHumanoid(player)
						if humanoid then
							humanoid:TakeDamage(10)
						end

						-- Launch upward (strategic — reach higher platforms)
						local bodyVelocity = Instance.new("BodyVelocity")
						bodyVelocity.Velocity = Vector3.new(0, 80, 0)
						bodyVelocity.MaxForce = Vector3.new(0, 1e5, 0)
						bodyVelocity.Parent = rootPart
						task.delay(0.5, function()
							bodyVelocity:Destroy()
						end)

						Remotes.ArenaEvent:FireClient(player, {
							event = "GeyserLaunch",
						})
					end
				end

				-- Notify clients for VFX
				Remotes.ArenaEvent:FireAllClients({
					event = "GeyserEruption",
					position = origin,
				})

				-- Clean up column after 2 seconds
				task.delay(2, function()
					local fadeTween = TweenService:Create(
						column,
						TweenInfo.new(0.5),
						{ Transparency = 1 }
					)
					fadeTween:Play()
					fadeTween.Completed:Once(function()
						column:Destroy()
					end)
				end)
			end
		end
	end)
end

------------------------------------------------------------------------
-- SHADOW MAZE — Shifting Walls
-- Every SHADOW_MAZE_WALL_SHIFT (180s), tween ShiftingWall parts between
-- their original and shifted CFrame positions over 3 seconds.
-- Rumble warning 5s before. Screen shake event to clients.
------------------------------------------------------------------------

local function startShiftingWalls()
	task.spawn(function()
		-- Initialize all walls to "original" position
		for _, wall in CollectionService:GetTagged("ShiftingWall") do
			shiftedState[wall] = false
		end

		local WARNING_LEAD = 5
		local TWEEN_DURATION = 3

		while running do
			if not hazardWait(GameConfig.SHADOW_MAZE_WALL_SHIFT - WARNING_LEAD) then break end

			-- Rumbling sound cue warning
			Remotes.ArenaEvent:FireAllClients({
				event = "WallShiftWarning",
				message = "The walls are rumbling...",
			})

			if not hazardWait(WARNING_LEAD) then break end

			-- Tween each shifting wall
			local tweenInfo = TweenInfo.new(TWEEN_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)

			for _, wall in CollectionService:GetTagged("ShiftingWall") do
				if not wall:IsA("BasePart") then continue end

				local isShifted = shiftedState[wall] or false
				local targetPos: Vector3

				if isShifted then
					-- Move back to original
					targetPos = Vector3.new(
						wall:GetAttribute("OriginalCFrameX") or wall.Position.X,
						wall:GetAttribute("OriginalCFrameY") or wall.Position.Y,
						wall:GetAttribute("OriginalCFrameZ") or wall.Position.Z
					)
				else
					-- Move to shifted position
					targetPos = Vector3.new(
						wall:GetAttribute("ShiftedCFrameX") or wall.Position.X,
						wall:GetAttribute("ShiftedCFrameY") or wall.Position.Y,
						wall:GetAttribute("ShiftedCFrameZ") or wall.Position.Z
					)
				end

				local tween = TweenService:Create(wall, tweenInfo, {
					Position = targetPos,
				})
				trackTween(tween)
				tween:Play()

				shiftedState[wall] = not isShifted
			end

			-- Screen shake on clients
			Remotes.ArenaEvent:FireAllClients({
				event = "WallShiftShake",
			})
		end
	end)
end

------------------------------------------------------------------------
-- SHADOW MAZE — Breakable Walls
-- Parts tagged "BreakableWall" have 50 HP. When a player attacks within
-- melee range and facing one, reduce health by weapon damage. At 0 HP
-- the wall is destroyed (debris VFX via RemoteEvent).
------------------------------------------------------------------------

local function startBreakableWalls()
	-- Initialize health for each breakable wall
	for _, wall in CollectionService:GetTagged("BreakableWall") do
		wallHealth[wall] = wall:GetAttribute("Health") or 50
	end

	-- Track equipped weapons via the EquipWeapon BindableEvent
	local equipEvent = serverEvents:FindFirstChild("EquipWeapon")
	if equipEvent and equipEvent:IsA("BindableEvent") then
		trackConnection(equipEvent.Event:Connect(function(player: Player, weaponName: string)
			playerWeapons[player] = weaponName
		end))
	end

	-- Listen to AttackInput to detect attacks on breakable walls
	trackConnection(Remotes.AttackInput.OnServerEvent:Connect(function(player: Player, ...)
		if not running then return end
		if not isAlive(player) then return end

		local rootPart = getHumanoidRootPart(player)
		if not rootPart then return end

		local lookDir = rootPart.CFrame.LookVector

		for wall, health in wallHealth do
			if health <= 0 then continue end
			if not wall:IsA("BasePart") or not wall.Parent then continue end

			local toWall = wall.Position - rootPart.Position
			local dist = toWall.Magnitude
			if dist > 8 then continue end

			-- Facing check: player must be roughly looking at the wall
			local flatDir = Vector3.new(toWall.X, 0, toWall.Z)
			if flatDir.Magnitude < 0.01 then continue end
			if lookDir:Dot(flatDir.Unit) < 0.3 then continue end

			-- Get weapon damage
			local weaponName = playerWeapons[player] or "Sword"
			local weaponData = WeaponConfig[weaponName]
			local damage = if weaponData then weaponData.damage else 25

			wallHealth[wall] = math.max(0, health - damage)

			-- Visual feedback
			Remotes.ArenaEvent:FireAllClients({
				event = "WallDamaged",
				position = wall.Position,
				health = wallHealth[wall],
				maxHealth = 50,
			})

			-- Destroy if depleted
			if wallHealth[wall] <= 0 then
				Remotes.ArenaEvent:FireAllClients({
					event = "WallDestroyed",
					position = wall.Position,
				})
				wallHealth[wall] = nil :: any
				wall:Destroy()
			end

			break -- one wall per attack
		end
	end))
end

------------------------------------------------------------------------
-- JUNGLE RUINS — Dart Traps
-- TrapTrigger_Dart plates fire a dart projectile from the linked DartTrap
-- when a player steps on them. 4-second cooldown. Dart despawns after
-- 2 seconds or on hit. Deals JUNGLE_DART_DAMAGE (15).
------------------------------------------------------------------------

local function startDartTraps()
	for _, plate in CollectionService:GetTagged("TrapTrigger_Dart") do
		if not plate:IsA("BasePart") then continue end

		dartCooldowns[plate] = 0

		trackConnection(plate.Touched:Connect(function(hit: BasePart)
			if not running then return end

			local player = getPlayerFromPart(hit)
			if not player or not isAlive(player) then return end

			-- 4-second cooldown
			local now = os.clock()
			if now - (dartCooldowns[plate] or 0) < 4 then return end
			dartCooldowns[plate] = now

			-- Find linked dart trap via ObjectValue
			local linkValue = plate:FindFirstChild("LinkedDartTrap")
			if not linkValue or not linkValue:IsA("ObjectValue") or not linkValue.Value then
				return
			end
			local dartTrap = linkValue.Value

			-- Dart origin
			local dartOrigin: Vector3
			if dartTrap:IsA("Model") then
				dartOrigin = dartTrap:GetPivot().Position
			elseif dartTrap:IsA("BasePart") then
				dartOrigin = dartTrap.Position
			else
				return
			end

			-- Aim toward the player's current position (horizontal)
			local rootPart = getHumanoidRootPart(player)
			local aimTarget = if rootPart then rootPart.Position else plate.Position
			local direction = Vector3.new(aimTarget.X - dartOrigin.X, 0, aimTarget.Z - dartOrigin.Z)
			if direction.Magnitude < 0.01 then
				direction = Vector3.new(1, 0, 0)
			end
			direction = direction.Unit

			-- Spawn dart projectile
			local dart = Instance.new("Part")
			dart.Name = "DartProjectile"
			dart.Size = Vector3.new(0.3, 0.3, 1.5)
			dart.Color = Color3.fromRGB(60, 40, 20)
			dart.Material = Enum.Material.Metal
			dart.Anchored = false
			dart.CanCollide = false
			dart.CFrame = CFrame.new(dartOrigin, dartOrigin + direction)

			-- Projectile velocity
			local velocity = Instance.new("BodyVelocity")
			velocity.Velocity = direction * 60
			velocity.MaxForce = Vector3.new(1e5, 1e5, 1e5)
			velocity.Parent = dart

			-- Counteract gravity
			local antigrav = Instance.new("BodyForce")
			antigrav.Force = Vector3.new(0, dart:GetMass() * Workspace.Gravity, 0)
			antigrav.Parent = dart

			dart.Parent = Workspace

			-- Hit detection
			local hitConn: RBXScriptConnection
			hitConn = dart.Touched:Connect(function(hitPart: BasePart)
				local hitPlayer = getPlayerFromPart(hitPart)
				if not hitPlayer or not isAlive(hitPlayer) then return end

				local humanoid = getHumanoid(hitPlayer)
				if humanoid then
					humanoid:TakeDamage(GameConfig.JUNGLE_DART_DAMAGE)
					Remotes.ArenaEvent:FireClient(hitPlayer, {
						event = "DartHit",
						damage = GameConfig.JUNGLE_DART_DAMAGE,
					})
				end

				hitConn:Disconnect()
				dart:Destroy()
			end)

			-- Auto-despawn after 2 seconds
			task.delay(2, function()
				if dart.Parent then
					hitConn:Disconnect()
					dart:Destroy()
				end
			end)

			-- Client VFX/SFX notification
			Remotes.ArenaEvent:FireAllClients({
				event = "DartFired",
				origin = dartOrigin,
				direction = direction,
			})
		end))
	end
end

------------------------------------------------------------------------
-- JUNGLE RUINS — Swing Log Traps
-- Parts tagged "SwingLogTrap" swing continuously in a pendulum arc
-- (4-second period). Players hit take JUNGLE_LOG_DAMAGE (25) + knockback.
------------------------------------------------------------------------

local function startSwingLogTraps()
	for _, log in CollectionService:GetTagged("SwingLogTrap") do
		if not log:IsA("BasePart") then continue end

		local originalCF = log.CFrame
		local halfSwing = 8 -- studs of side-to-side travel

		-- Swing between two CFrame endpoints using the log's right axis
		local leftCF = originalCF * CFrame.new(-halfSwing, 0, 0)
		local rightCF = originalCF * CFrame.new(halfSwing, 0, 0)

		-- Start at the left endpoint
		log.CFrame = leftCF

		-- Infinite reversing tween: 2 seconds each way = 4 second period
		local tweenInfo = TweenInfo.new(
			2,
			Enum.EasingStyle.Sine,
			Enum.EasingDirection.InOut,
			-1, -- repeat forever
			true -- reverse
		)
		local tween = TweenService:Create(log, tweenInfo, { CFrame = rightCF })
		trackTween(tween)
		tween:Play()

		-- Damage on touch (per-player 2-second cooldown)
		trackConnection(log.Touched:Connect(function(hit: BasePart)
			if not running then return end

			local player = getPlayerFromPart(hit)
			if not player or not isAlive(player) then return end

			local now = os.clock()
			if now - (logDamageCooldowns[player] or 0) < 2 then return end
			logDamageCooldowns[player] = now

			local humanoid = getHumanoid(player)
			if humanoid then
				humanoid:TakeDamage(GameConfig.JUNGLE_LOG_DAMAGE)
			end

			local rootPart = getHumanoidRootPart(player)
			if rootPart then
				local knockDir = (rootPart.Position - log.Position).Unit
				applyKnockback(rootPart, knockDir, 40)
			end

			Remotes.ArenaEvent:FireClient(player, {
				event = "LogTrapHit",
				damage = GameConfig.JUNGLE_LOG_DAMAGE,
			})
		end))
	end
end

------------------------------------------------------------------------
-- JUNGLE RUINS — Pit Traps
-- Parts tagged "PitTrap" drop players into an 8-stud pit when stepped on.
-- CanCollide toggles off for 0.5s, then restores. Player takes fall damage.
------------------------------------------------------------------------

local function startPitTraps()
	for _, pit in CollectionService:GetTagged("PitTrap") do
		if not pit:IsA("BasePart") then continue end

		pitActive[pit] = false
		local pitDepth = pit:GetAttribute("PitDepth") or 8

		trackConnection(pit.Touched:Connect(function(hit: BasePart)
			if not running then return end
			if pitActive[pit] then return end

			local player = getPlayerFromPart(hit)
			if not player or not isAlive(player) then return end

			-- Activate trap
			pitActive[pit] = true
			pit.CanCollide = false

			-- Player falls through
			task.wait(0.5)

			-- Restore for other players
			pit.CanCollide = true
			pitActive[pit] = false

			-- Apply fall damage based on pit depth (2 HP per stud)
			if isAlive(player) then
				local humanoid = getHumanoid(player)
				if humanoid then
					local fallDamage = pitDepth * 2
					humanoid:TakeDamage(fallDamage)
					Remotes.ArenaEvent:FireClient(player, {
						event = "PitTrapFall",
						damage = fallDamage,
						depth = pitDepth,
					})
				end
			end
		end))
	end
end

------------------------------------------------------------------------
-- JUNGLE RUINS — Foliage Concealment
-- Every 1s, check which players are near "Foliage" parts. Fire events
-- to other clients to reduce nametag visibility for concealed players.
------------------------------------------------------------------------

local function startFoliageConcealment()
	task.spawn(function()
		while running do
			task.wait(1)
			if not running then break end

			local foliageParts = CollectionService:GetTagged("Foliage")
			if #foliageParts == 0 then continue end

			for _, player in Players:GetPlayers() do
				if not isAlive(player) then continue end
				local rootPart = getHumanoidRootPart(player)
				if not rootPart then continue end

				local inFoliage = false
				for _, foliage in foliageParts do
					if not foliage:IsA("BasePart") then continue end
					-- Check if player overlaps with the foliage bounding box
					if isNearPart(rootPart, foliage, 1) then
						inFoliage = true
						break
					end
				end

				local wasConcealed = foliageState[player] or false
				foliageState[player] = inFoliage

				-- Only fire events on state change
				if inFoliage ~= wasConcealed then
					for _, otherPlayer in Players:GetPlayers() do
						if otherPlayer ~= player then
							Remotes.ArenaEvent:FireClient(otherPlayer, {
								event = "FoliageConcealment",
								targetPlayer = player.Name,
								concealed = inFoliage,
							})
						end
					end
				end
			end
		end
	end)
end

------------------------------------------------------------------------
-- Master Control
------------------------------------------------------------------------

local function stopHazards()
	running = false
	currentArenaType = ""

	-- Disconnect all event connections
	for _, conn in connections do
		conn:Disconnect()
	end
	table.clear(connections)

	-- Cancel all active tweens
	for _, tween in activeTweens do
		tween:Cancel()
	end
	table.clear(activeTweens)

	-- Reset state tables
	lavaLevel = 0
	table.clear(shiftedState)
	table.clear(wallHealth)
	table.clear(dartCooldowns)
	table.clear(pitActive)
	table.clear(logDamageCooldowns)
	table.clear(foliageState)
	table.clear(playerWeapons)

	-- Clear concealment for all players
	for _, player in Players:GetPlayers() do
		for _, otherPlayer in Players:GetPlayers() do
			if otherPlayer ~= player then
				Remotes.ArenaEvent:FireClient(otherPlayer, {
					event = "FoliageConcealment",
					targetPlayer = player.Name,
					concealed = false,
				})
			end
		end
	end

	-- Clean up any leftover dart projectiles
	for _, child in Workspace:GetChildren() do
		if child.Name == "DartProjectile" or child.Name == "GeyserColumn" then
			child:Destroy()
		end
	end

	print("[ArenaHazards] All hazards stopped")
end

local function startHazards(arenaType: string)
	-- Stop any existing hazards first
	if running then
		stopHazards()
	end

	running = true
	currentArenaType = arenaType
	print("[ArenaHazards] Starting hazards for: " .. arenaType)

	-- Player cleanup on leave
	trackConnection(Players.PlayerRemoving:Connect(function(player: Player)
		playerWeapons[player] = nil
		foliageState[player] = nil
		logDamageCooldowns[player] = nil
	end))

	if arenaType == "LavaForge" then
		startLavaDamage()
		startLavaRising()
		startGeyserEruptions()
	elseif arenaType == "ShadowMaze" then
		startShiftingWalls()
		startBreakableWalls()
	elseif arenaType == "JungleRuins" then
		startDartTraps()
		startSwingLogTraps()
		startPitTraps()
		startFoliageConcealment()
	end
	-- Colosseum: no hazards (pure skill arena)
end

------------------------------------------------------------------------
-- BindableEvent Listeners
------------------------------------------------------------------------

StartHazardsEvent.Event:Connect(function(arenaType: string)
	startHazards(arenaType)
end)

StopHazardsEvent.Event:Connect(function()
	stopHazards()
end)

print("[ArenaHazards] Loaded — awaiting StartHazards event")
