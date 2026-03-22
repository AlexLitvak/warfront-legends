--!strict
--[[
	ArenaGenerator (Server ModuleScript)
	Procedural arena generation system. Other server scripts require this
	module and call ArenaGenerator.generate(arenaType, seed?) to build
	an arena in the Workspace.

	Features:
	- Seeded random for deterministic, reproducible layouts
	- Prefab system with automatic placeholder fallbacks
	- Grid-snapped placement
	- Spawn point generation with minimum-distance rejection sampling
	- Lighting configuration per arena
	- Full cleanup between matches
]]

local ServerStorage = game:GetService("ServerStorage")
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ArenaConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("ArenaConfig"))
local AmbientWildlife = require(game:GetService("ServerScriptService"):WaitForChild("AmbientWildlife"))

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

type ArenaData = ArenaConfig.ArenaData

export type GenerationResult = {
	seed: number,
	arenaName: string,
	arenaFolder: Folder,
	spawnPoints: { BasePart },
}

------------------------------------------------------------------------
-- Module
------------------------------------------------------------------------

local ArenaGenerator = {}

-- Active Jungle Ruins sunlight animation connection (disconnected on clearArena)
local jungleSunConnection: RBXScriptConnection? = nil

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

local PLACEHOLDER_COLOR = Color3.fromRGB(255, 105, 180) -- hot pink
local PLACEHOLDER_MATERIAL = Enum.Material.SmoothPlastic
local ARENA_FOLDER_NAME = "Arena"

-- Sound asset IDs — upload your own audio via Roblox Studio Asset Manager,
-- then paste the rbxassetid:// URLs here. Leave "" to disable.
local FOREST_SOUND_ID = "rbxassetid://9113444290"
local WATER_SOUND_ID = ""  -- e.g. "rbxassetid://YOUR_WATER_AMBIENT_ID"

-- Placeholder sizes by name pattern (studs)
-- Order matters: more specific patterns checked first via string.find
local PLACEHOLDER_SIZES: { [string]: Vector3 } = {
	-- Colosseum
	FloorTile        = Vector3.new(12, 1, 12),
	WallSegment      = Vector3.new(12, 20, 2),
	ElevatedPlatform = Vector3.new(24, 2, 24),
	CoverWall        = Vector3.new(8, 5, 2),
	-- Lava Forge
	LavaFloorTile    = Vector3.new(12, 1, 12),
	MetalPlatformLarge  = Vector3.new(36, 2, 36),
	MetalPlatformMedium = Vector3.new(24, 2, 24),
	MetalPlatformSmall  = Vector3.new(16, 2, 16),
	AnvilPlatform    = Vector3.new(40, 2, 40),
	MetalRamp        = Vector3.new(12, 6, 12),
	GeyserBase       = Vector3.new(4, 2, 4),
	ForgePipe        = Vector3.new(2, 8, 2),
	LavaBubble       = Vector3.new(2, 1, 2),
	Chain            = Vector3.new(1, 12, 1),
	-- Shadow Maze
	MazeWallSegment  = Vector3.new(12, 12, 2),
	MazeWallCorner   = Vector3.new(2, 12, 2),
	CrackedWall      = Vector3.new(12, 12, 2),
	DoorwayArch      = Vector3.new(12, 14, 4),
	TorchSconce      = Vector3.new(2, 3, 1),
	RoomFloorTile    = Vector3.new(12, 1, 12),
	CeilingTile      = Vector3.new(12, 1, 12),
	-- Jungle Ruins
	TempleFloorTile  = Vector3.new(12, 1, 12),
	ForestFloorTile  = Vector3.new(12, 1, 12),
	StoneWall        = Vector3.new(12, 10, 2),
	RuinedPillar     = Vector3.new(4, 12, 4),
	StoneStaircase   = Vector3.new(12, 8, 6),
	StoneBoulder     = Vector3.new(4, 3, 4),
	BrokenStatue     = Vector3.new(4, 6, 3),
	ClimbableVine    = Vector3.new(2, 12, 1),
	PressurePlate    = Vector3.new(4, 0.5, 4),
	DartTrap         = Vector3.new(2, 2, 2),
	SwingLog         = Vector3.new(2, 2, 10),
	PitTrap          = Vector3.new(8, 1, 8),
	RopeBridge       = Vector3.new(24, 1, 4),
	TempleBase       = Vector3.new(36, 15, 36),
	Firefly          = Vector3.new(1, 1, 1),
	-- Wildlife NPCs
	Bear             = Vector3.new(5, 6, 8),
	-- Generic
	Floor            = Vector3.new(12, 1, 12),
	Wall             = Vector3.new(12, 12, 2),
	Platform         = Vector3.new(24, 2, 24),
	Cover            = Vector3.new(6, 6, 6),
	Pillar           = Vector3.new(4, 16, 4),
	Bridge           = Vector3.new(24, 1, 6),
	Ramp             = Vector3.new(12, 6, 12),
	Trap             = Vector3.new(6, 1, 6),
	Torch            = Vector3.new(2, 6, 2),
	Hazard           = Vector3.new(12, 1, 12),
}
local DEFAULT_PLACEHOLDER_SIZE = Vector3.new(12, 12, 12)

------------------------------------------------------------------------
-- Seeded Random
------------------------------------------------------------------------

local rng: Random = Random.new()

--- Generate a seed from the current time + a random component.
local function generateSeed(): number
	return math.floor(os.clock() * 1000) + math.random(1, 999999)
end

--- Initialize the RNG with a specific seed.
local function setSeed(seed: number)
	rng = Random.new(seed)
end

------------------------------------------------------------------------
-- Grid Utilities
------------------------------------------------------------------------

--- Snap a value to the nearest grid multiple.
local function snapToGrid(value: number, gridSize: number): number
	return math.round(value / gridSize) * gridSize
end

--- Convert grid coordinates (integers) to world position (centered on grid cell).
local function gridToWorld(gridX: number, gridZ: number, gridSize: number): Vector3
	return Vector3.new(gridX * gridSize, 0, gridZ * gridSize)
end

--- Convert a world position to grid coordinates.
local function worldToGrid(position: Vector3, gridSize: number): (number, number)
	return math.round(position.X / gridSize), math.round(position.Z / gridSize)
end

------------------------------------------------------------------------
-- Prefab System
------------------------------------------------------------------------

--- Get the prefab folder for a given arena type from ServerStorage.
local function getPrefabFolder(arenaType: string): Folder?
	local arenaPrefabs = ServerStorage:FindFirstChild("ArenaPrefabs")
	if not arenaPrefabs then
		return nil
	end
	return arenaPrefabs:FindFirstChild(arenaType) :: Folder?
end

--- Create a BillboardGui label for placeholder parts.
local function createPlaceholderLabel(parent: BasePart, prefabName: string)
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.new(0, 200, 0, 50)
	billboard.StudsOffset = Vector3.new(0, 3, 0)
	billboard.AlwaysOnTop = true

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = "MISSING: " .. prefabName
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Parent = billboard

	billboard.Parent = parent
end

--- Determine placeholder size based on the prefab name pattern.
local function getPlaceholderSize(prefabName: string): Vector3
	for pattern, size in PLACEHOLDER_SIZES do
		if string.find(prefabName, pattern) then
			return size
		end
	end
	return DEFAULT_PLACEHOLDER_SIZE
end

--- Create a placeholder part when a prefab is missing.
local function createPlaceholder(prefabName: string, position: Vector3): BasePart
	local size = getPlaceholderSize(prefabName)

	local part = Instance.new("Part")
	part.Name = prefabName .. "_Placeholder"
	part.Size = size
	part.Position = position + Vector3.new(0, size.Y / 2, 0) -- sit on ground
	part.Color = PLACEHOLDER_COLOR
	part.Material = PLACEHOLDER_MATERIAL
	part.Anchored = true
	part.CanCollide = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	createPlaceholderLabel(part, prefabName)

	return part
end

--- Clone a specific prefab by name from the prefab folder. Falls back to placeholder.
local function clonePrefab(prefabFolder: Folder?, prefabName: string, position: Vector3): Instance
	if prefabFolder then
		local prefab = prefabFolder:FindFirstChild(prefabName)
		if prefab then
			local clone = prefab:Clone()
			if clone:IsA("Model") then
				clone:PivotTo(CFrame.new(position))
			elseif clone:IsA("BasePart") then
				clone.Position = position
			end
			return clone
		end
	end

	-- Fallback to placeholder
	warn("[ArenaGenerator] Prefab not found: " .. prefabName .. " — using placeholder")
	return createPlaceholder(prefabName, position)
end

--- Clone a random variant of a prefab. Looks for PrefabName, PrefabName_1,
--- PrefabName_2, etc. in the folder. Falls back to placeholder.
local function cloneRandomVariant(prefabFolder: Folder?, baseName: string, position: Vector3): Instance
	if prefabFolder then
		local variants: { Instance } = {}

		-- Collect the base name and all numbered variants
		for _, child in prefabFolder:GetChildren() do
			if child.Name == baseName or string.match(child.Name, "^" .. baseName .. "_%d+$") then
				table.insert(variants, child)
			end
		end

		if #variants > 0 then
			local chosen = variants[rng:NextInteger(1, #variants)]
			local clone = chosen:Clone()
			if clone:IsA("Model") then
				clone:PivotTo(CFrame.new(position))
			elseif clone:IsA("BasePart") then
				clone.Position = position
			end
			return clone
		end
	end

	-- Fallback to placeholder
	warn("[ArenaGenerator] No variants found for: " .. baseName .. " — using placeholder")
	return createPlaceholder(baseName, position)
end

------------------------------------------------------------------------
-- Spawn Point Placement
------------------------------------------------------------------------

--- Check whether a position is within the arena bounds.
local function isWithinBounds(position: Vector3, bounds: ArenaConfig.ArenaBounds): boolean
	if bounds.shape == "Circle" then
		local radius = (bounds.diameter or 200) / 2
		return (position.X ^ 2 + position.Z ^ 2) <= radius ^ 2
	else
		local halfW = (bounds.width or 200) / 2
		local halfD = (bounds.depth or 200) / 2
		return math.abs(position.X) <= halfW and math.abs(position.Z) <= halfD
	end
end

--- Generate spawn positions using rejection sampling.
--- Ensures all spawns are within bounds and at least minDistance apart.
local function generateSpawnPositions(
	count: number,
	bounds: ArenaConfig.ArenaBounds,
	minDistance: number,
	gridSize: number
): { Vector3 }
	local positions: { Vector3 } = {}
	local maxAttempts = count * 100 -- prevent infinite loop

	local halfExtent: number
	if bounds.shape == "Circle" then
		halfExtent = (bounds.diameter or 200) / 2
	else
		halfExtent = math.max(bounds.width or 200, bounds.depth or 200) / 2
	end

	local attempts = 0
	while #positions < count and attempts < maxAttempts do
		attempts += 1

		-- Generate a random grid-snapped candidate
		local rawX = rng:NextNumber(-halfExtent, halfExtent)
		local rawZ = rng:NextNumber(-halfExtent, halfExtent)
		local candidate = Vector3.new(
			snapToGrid(rawX, gridSize),
			0,
			snapToGrid(rawZ, gridSize)
		)

		-- Check bounds
		if not isWithinBounds(candidate, bounds) then
			continue
		end

		-- Check minimum distance from all existing positions
		local tooClose = false
		for _, existing in positions do
			if (candidate - existing).Magnitude < minDistance then
				tooClose = true
				break
			end
		end

		if not tooClose then
			table.insert(positions, candidate)
		end
	end

	if #positions < count then
		warn(
			"[ArenaGenerator] Could only place "
				.. #positions
				.. " of "
				.. count
				.. " spawn points (minDistance="
				.. minDistance
				.. ")"
		)
	end

	return positions
end

--- Create SpawnLocation parts at the given positions inside the arena folder.
local function placeSpawnPoints(positions: { Vector3 }, parentFolder: Folder): { BasePart }
	local spawns: { BasePart } = {}

	for i, pos in positions do
		local spawn = Instance.new("SpawnLocation")
		spawn.Name = "Spawn_" .. i
		spawn.Size = Vector3.new(6, 1, 6)
		spawn.Position = pos + Vector3.new(0, 0.5, 0) -- sit on ground level
		spawn.Anchored = true
		spawn.CanCollide = true
		spawn.Neutral = true -- any team can use
		spawn.TopSurface = Enum.SurfaceType.Smooth
		spawn.BottomSurface = Enum.SurfaceType.Smooth
		spawn.Transparency = 1 -- invisible during gameplay
		spawn.Parent = parentFolder
		table.insert(spawns, spawn)
	end

	return spawns
end

------------------------------------------------------------------------
-- Lighting
------------------------------------------------------------------------

local defaultLighting = {
	Brightness = 2,
	Ambient = Color3.fromRGB(128, 128, 128),
	OutdoorAmbient = Color3.fromRGB(128, 128, 128),
	FogEnd = 100000,
	FogColor = Color3.fromRGB(192, 192, 192),
	ClockTime = 14,
}

--- Apply the arena's lighting configuration to the Lighting service.
local function applyLighting(config: ArenaConfig.LightingConfig)
	Lighting.Brightness = config.Brightness
	Lighting.Ambient = config.Ambient
	Lighting.OutdoorAmbient = config.OutdoorAmbient
	Lighting.FogEnd = config.FogEnd
	Lighting.FogColor = config.FogColor
	Lighting.ClockTime = config.ClockTime
end

--- Reset lighting to safe defaults.
local function resetLighting()
	Lighting.Brightness = defaultLighting.Brightness
	Lighting.Ambient = defaultLighting.Ambient
	Lighting.OutdoorAmbient = defaultLighting.OutdoorAmbient
	Lighting.FogEnd = defaultLighting.FogEnd
	Lighting.FogColor = defaultLighting.FogColor
	Lighting.ClockTime = defaultLighting.ClockTime
end

------------------------------------------------------------------------
-- Arena Layout Generation (per arena type)
------------------------------------------------------------------------

--- Generate Colosseum layout: circular gladiator arena (200 stud diameter).
--- Open, fair, symmetrical. Floor tiles, perimeter walls with 4 gaps,
--- scattered cover walls, 4 elevated platforms with ramps, decorative pillars,
--- and evenly-distributed spawn points at ~70% radius.
local function generateColosseum(arenaFolder: Folder, arenaData: ArenaData, prefabFolder: Folder?)
	local gridSize = arenaData.gridSize
	local radius = (arenaData.bounds.diameter or 200) / 2

	local WALL_HEIGHT = 20
	local PLATFORM_HEIGHT = 8
	local COVER_MIN_SPACING = 24
	local COVER_MIN_FROM_CENTER = 30
	local COVER_MIN_FROM_PERIMETER = 20
	local SPAWN_RADIUS_FRACTION = 0.7
	local SPAWN_MIN_DISTANCE = 20

	-- 90-degree rotation increments for visual variety
	local ROTATIONS = { 0, math.pi / 2, math.pi, 3 * math.pi / 2 }

	--------------------------------------------------------------------
	-- Helper: position and rotate a cloned instance
	--------------------------------------------------------------------
	local function positionInstance(inst: Instance, cframe: CFrame)
		if inst:IsA("Model") then
			inst:PivotTo(cframe)
		elseif inst:IsA("BasePart") then
			inst.CFrame = cframe
		end
	end

	--------------------------------------------------------------------
	-- FLOOR: circular grid of FloorTile prefabs
	--------------------------------------------------------------------
	local floorGridRadius = math.floor(radius / gridSize)
	for gx = -floorGridRadius, floorGridRadius do
		for gz = -floorGridRadius, floorGridRadius do
			local worldPos = gridToWorld(gx, gz, gridSize)
			-- Only place tiles whose center falls within the circle
			if worldPos.X ^ 2 + worldPos.Z ^ 2 <= radius ^ 2 then
				local tile = cloneRandomVariant(prefabFolder, "FloorTile", worldPos)
				-- Random 90-degree rotation for visual variety
				local rot = ROTATIONS[rng:NextInteger(1, #ROTATIONS)]
				positionInstance(tile, CFrame.new(worldPos) * CFrame.Angles(0, rot, 0))
				tile.Parent = arenaFolder
			end
		end
	end

	--------------------------------------------------------------------
	-- PERIMETER WALLS: WallSegment prefabs around circumference with
	-- 4 evenly-spaced gaps as entry points
	--------------------------------------------------------------------
	local wallSpacing = gridSize -- one wall segment per gridSize along circumference
	local circumference = 2 * math.pi * radius
	local wallCount = math.floor(circumference / wallSpacing)

	-- 4 gap angles at 45°, 135°, 225°, 315° (between the platform positions)
	local gapAngles = { math.pi / 4, 3 * math.pi / 4, 5 * math.pi / 4, 7 * math.pi / 4 }
	local GAP_HALF_WIDTH = gridSize * 1.2 -- angular width of each gap in studs along the arc

	for i = 0, wallCount - 1 do
		local angle = (i / wallCount) * 2 * math.pi

		-- Check if this wall position falls within a gap
		local inGap = false
		for _, gapAngle in gapAngles do
			-- Arc distance between this angle and the gap center
			local diff = math.abs(angle - gapAngle)
			if diff > math.pi then diff = 2 * math.pi - diff end
			local arcDist = diff * radius
			if arcDist < GAP_HALF_WIDTH then
				inGap = true
				break
			end
		end

		if not inGap then
			local wx = math.cos(angle) * (radius - 1)
			local wz = math.sin(angle) * (radius - 1)
			local wallBase = Vector3.new(wx, WALL_HEIGHT / 2, wz)

			local wall = cloneRandomVariant(prefabFolder, "WallSegment", Vector3.new(wx, 0, wz))
			-- Rotate wall to face inward (tangent to the circle)
			local facingAngle = angle + math.pi / 2
			positionInstance(wall, CFrame.new(wallBase) * CFrame.Angles(0, facingAngle, 0))
			wall.Parent = arenaFolder
		end
	end

	--------------------------------------------------------------------
	-- COVER WALLS: 6-8 low CoverWall prefabs scattered in the mid-zone
	-- (at least 30 studs from center, 20 studs from perimeter,
	--  24 studs apart from each other)
	--------------------------------------------------------------------
	local coverCount = rng:NextInteger(6, 8)
	local coverPositions: { Vector3 } = {}
	local coverAttempts = 0
	local maxCoverAttempts = coverCount * 80

	while #coverPositions < coverCount and coverAttempts < maxCoverAttempts do
		coverAttempts += 1

		local cx = rng:NextNumber(-radius, radius)
		local cz = rng:NextNumber(-radius, radius)
		local candidatePos = Vector3.new(snapToGrid(cx, gridSize), 0, snapToGrid(cz, gridSize))
		local distFromCenter = math.sqrt(candidatePos.X ^ 2 + candidatePos.Z ^ 2)

		-- Must be within the circle
		if distFromCenter > radius then continue end
		-- Must be at least 30 studs from center
		if distFromCenter < COVER_MIN_FROM_CENTER then continue end
		-- Must be at least 20 studs from perimeter
		if (radius - distFromCenter) < COVER_MIN_FROM_PERIMETER then continue end

		-- Must be at least 24 studs from all other covers
		local tooClose = false
		for _, existing in coverPositions do
			if (candidatePos - existing).Magnitude < COVER_MIN_SPACING then
				tooClose = true
				break
			end
		end
		if tooClose then continue end

		table.insert(coverPositions, candidatePos)
	end

	for _, coverPos in coverPositions do
		local cover = clonePrefab(prefabFolder, "CoverWall", coverPos)
		local rot = ROTATIONS[rng:NextInteger(1, #ROTATIONS)]
		positionInstance(cover, CFrame.new(coverPos + Vector3.new(0, 2.5, 0)) * CFrame.Angles(0, rot, 0))
		cover.Parent = arenaFolder
	end

	--------------------------------------------------------------------
	-- ELEVATED PLATFORMS: 4 ElevatedPlatform prefabs at 0°, 90°, 180°,
	-- 270° near the perimeter (~75% radius), raised 8 studs, with Ramp
	-- connecting to ground level
	--------------------------------------------------------------------
	local platformAngles = { 0, math.pi / 2, math.pi, 3 * math.pi / 2 }
	local platformRadius = radius * 0.75

	for _, angle in platformAngles do
		local px = math.cos(angle) * platformRadius
		local pz = math.sin(angle) * platformRadius
		local platWorldPos = Vector3.new(snapToGrid(px, gridSize), PLATFORM_HEIGHT, snapToGrid(pz, gridSize))

		local platform = clonePrefab(prefabFolder, "ElevatedPlatform", platWorldPos)
		positionInstance(platform, CFrame.new(platWorldPos))
		platform.Parent = arenaFolder

		-- Ramp connecting platform to ground, positioned inward from platform
		local rampPx = math.cos(angle) * (platformRadius * 0.8)
		local rampPz = math.sin(angle) * (platformRadius * 0.8)
		local rampPos = Vector3.new(snapToGrid(rampPx, gridSize), 0, snapToGrid(rampPz, gridSize))

		local ramp = clonePrefab(prefabFolder, "Ramp", rampPos)
		-- Rotate ramp to face from ground toward the platform (outward)
		positionInstance(ramp, CFrame.new(rampPos + Vector3.new(0, PLATFORM_HEIGHT / 2, 0)) * CFrame.Angles(0, angle, 0))
		ramp.Parent = arenaFolder
	end

	--------------------------------------------------------------------
	-- PILLARS: 4-6 decorative Pillar prefabs scattered for visual
	-- interest and light cover. Uses cloneRandomVariant for variety.
	--------------------------------------------------------------------
	local pillarCount = rng:NextInteger(4, 6)
	local pillarPositions: { Vector3 } = {}
	local pillarAttempts = 0
	local maxPillarAttempts = pillarCount * 50

	while #pillarPositions < pillarCount and pillarAttempts < maxPillarAttempts do
		pillarAttempts += 1

		local ppx = rng:NextNumber(-radius * 0.7, radius * 0.7)
		local ppz = rng:NextNumber(-radius * 0.7, radius * 0.7)
		local candidatePos = Vector3.new(snapToGrid(ppx, gridSize), 0, snapToGrid(ppz, gridSize))
		local distFromCenter = math.sqrt(candidatePos.X ^ 2 + candidatePos.Z ^ 2)

		-- Must be inside the arena
		if distFromCenter > radius * 0.85 then continue end
		-- Minimum spacing from covers and other pillars (use gridSize * 2)
		local tooClose = false
		for _, existing in pillarPositions do
			if (candidatePos - existing).Magnitude < gridSize * 2 then
				tooClose = true
				break
			end
		end
		if tooClose then continue end

		for _, coverPos in coverPositions do
			if (candidatePos - coverPos).Magnitude < gridSize * 2 then
				tooClose = true
				break
			end
		end
		if tooClose then continue end

		table.insert(pillarPositions, candidatePos)
	end

	for _, pillarPos in pillarPositions do
		local pillar = cloneRandomVariant(prefabFolder, "Pillar", pillarPos)
		positionInstance(pillar, CFrame.new(pillarPos))
		pillar.Parent = arenaFolder
	end

	--------------------------------------------------------------------
	-- SPAWN POINTS: 10 spawns evenly distributed around a ring at 70%
	-- of the arena radius, with 20 stud minimum spacing.
	-- Uses the core placeSpawnPoints function.
	--------------------------------------------------------------------
	local spawnCount = arenaData.spawnCount
	local spawnRadius = radius * SPAWN_RADIUS_FRACTION
	local spawnPositions: { Vector3 } = {}

	for i = 0, spawnCount - 1 do
		local angle = (i / spawnCount) * 2 * math.pi
		-- Add slight radial jitter for variety (±1 grid cell)
		local jitter = rng:NextNumber(-gridSize, gridSize)
		local r = spawnRadius + jitter
		local sx = math.cos(angle) * r
		local sz = math.sin(angle) * r
		local candidate = Vector3.new(snapToGrid(sx, gridSize), 0, snapToGrid(sz, gridSize))

		-- Verify minimum spacing (shouldn't fail for evenly distributed spawns, but be safe)
		local valid = true
		for _, existing in spawnPositions do
			if (candidate - existing).Magnitude < SPAWN_MIN_DISTANCE then
				valid = false
				break
			end
		end

		if valid then
			table.insert(spawnPositions, candidate)
		else
			-- Fall back to the exact ring position without jitter
			local fallback = Vector3.new(
				snapToGrid(math.cos(angle) * spawnRadius, gridSize),
				0,
				snapToGrid(math.sin(angle) * spawnRadius, gridSize)
			)
			table.insert(spawnPositions, fallback)
		end
	end

	-- Place spawn points using the core function
	placeSpawnPoints(spawnPositions, arenaFolder)
end

--- Generate Lava Forge layout: volcanic multi-level arena over lava (160x160).
--- Lava floor at Y=0 with CollectionService tags, Level 1 platforms at Y=10
--- connected by MST bridges, Level 2 platforms at Y=22, central AnvilPlatform,
--- geysers, decorative chains/pipes, and platform-only spawn points.
local function generateLavaForge(arenaFolder: Folder, arenaData: ArenaData, prefabFolder: Folder?)
	local gridSize = arenaData.gridSize
	local halfW = (arenaData.bounds.width or 160) / 2
	local halfD = (arenaData.bounds.depth or 160) / 2

	local LEVEL_1_Y = 10
	local LEVEL_2_Y = 22
	local LAVA_COLOR = Color3.fromRGB(255, 80, 20)
	local LAVA_GLOW_COLOR = Color3.fromRGB(255, 140, 40)
	local MIN_PLATFORM_SPACING = 30
	local BUBBLE_COUNT_MIN = 15
	local BUBBLE_COUNT_MAX = 25
	local GEYSER_COUNT_MIN = 5
	local GEYSER_COUNT_MAX = 7
	local CHAIN_COUNT = 8
	local PIPE_COUNT = 6

	--------------------------------------------------------------------
	-- Helper: position and rotate a cloned instance
	--------------------------------------------------------------------
	local function positionInstance(inst: Instance, cframe: CFrame)
		if inst:IsA("Model") then
			inst:PivotTo(cframe)
		elseif inst:IsA("BasePart") then
			inst.CFrame = cframe
		end
	end

	--- Tag all BaseParts in an instance with a CollectionService tag.
	local function tagInstance(inst: Instance, tag: string)
		if inst:IsA("BasePart") then
			CollectionService:AddTag(inst, tag)
		end
		for _, child in inst:GetDescendants() do
			if child:IsA("BasePart") then
				CollectionService:AddTag(child, tag)
			end
		end
	end

	--------------------------------------------------------------------
	-- LAVA FLOOR (Y = 0): fill entire bounds with LavaFloorTile,
	-- tagged "LavaZone", Neon material, orange/red color
	--------------------------------------------------------------------
	local gridW = math.floor(halfW / gridSize)
	local gridD = math.floor(halfD / gridSize)
	for gx = -gridW, gridW do
		for gz = -gridD, gridD do
			local worldPos = gridToWorld(gx, gz, gridSize)
			local tile = cloneRandomVariant(prefabFolder, "LavaFloorTile", worldPos)

			-- Force lava appearance on placeholder parts
			if tile:IsA("BasePart") then
				tile.Material = Enum.Material.Neon
				tile.Color = LAVA_COLOR
			end
			for _, child in tile:GetDescendants() do
				if child:IsA("BasePart") then
					child.Material = Enum.Material.Neon
					child.Color = LAVA_COLOR
				end
			end

			tagInstance(tile, "LavaZone")
			tile.Parent = arenaFolder
		end
	end

	-- Scatter LavaBubble particle prefabs on the lava surface
	local bubbleCount = rng:NextInteger(BUBBLE_COUNT_MIN, BUBBLE_COUNT_MAX)
	for _ = 1, bubbleCount do
		local bx = rng:NextNumber(-halfW * 0.9, halfW * 0.9)
		local bz = rng:NextNumber(-halfD * 0.9, halfD * 0.9)
		local bubblePos = Vector3.new(bx, 0.5, bz)
		local bubble = clonePrefab(prefabFolder, "LavaBubble", bubblePos)

		-- Add a subtle glow PointLight if it's a placeholder
		if bubble:IsA("BasePart") then
			bubble.Material = Enum.Material.Neon
			bubble.Color = LAVA_GLOW_COLOR
			local glow = Instance.new("PointLight")
			glow.Color = LAVA_GLOW_COLOR
			glow.Brightness = 0.3
			glow.Range = 8
			glow.Parent = bubble
		end

		bubble.Parent = arenaFolder
	end

	--------------------------------------------------------------------
	-- CENTRAL FORGE PLATFORM (AnvilPlatform) at Level 1
	--------------------------------------------------------------------
	local anvilPos = Vector3.new(0, LEVEL_1_Y, 0)
	local anvil = clonePrefab(prefabFolder, "AnvilPlatform", anvilPos)
	positionInstance(anvil, CFrame.new(anvilPos))
	tagInstance(anvil, "LavaForge_Level1")
	anvil.Parent = arenaFolder

	-- Decorative ForgePipe and Chain around the anvil
	local forgePipeAngles = { 0, math.pi / 2, math.pi, 3 * math.pi / 2 }
	for _, angle in forgePipeAngles do
		local pipeX = math.cos(angle) * 18
		local pipeZ = math.sin(angle) * 18
		local pipePos = Vector3.new(pipeX, LEVEL_1_Y, pipeZ)
		local pipe = clonePrefab(prefabFolder, "ForgePipe", pipePos)
		positionInstance(pipe, CFrame.new(pipePos + Vector3.new(0, 4, 0)))
		pipe.Parent = arenaFolder
	end

	--------------------------------------------------------------------
	-- LEVEL 1 PLATFORMS (Y = 10): 8-10 MetalPlatformMedium + 2-3
	-- MetalPlatformLarge, connected by MST bridges
	--------------------------------------------------------------------

	-- Generate random platform positions via rejection sampling
	type PlatformInfo = { pos: Vector3, prefabName: string, index: number }
	local platforms: { PlatformInfo } = {}

	-- The anvil is platform index 1 (already placed)
	table.insert(platforms, { pos = anvilPos, prefabName = "AnvilPlatform", index = 1 })

	-- Large platforms (2-3)
	local largeCount = rng:NextInteger(2, 3)
	-- Medium platforms (enough to reach 8-10 total, minus anvil, minus large)
	local totalL1 = rng:NextInteger(8, 10)
	local mediumCount = totalL1 - largeCount -- anvil is separate

	local allPlatformPositions: { Vector3 } = { anvilPos }
	local attempts = 0
	local maxAttempts = (largeCount + mediumCount) * 60

	-- Place large platforms first
	local largePlaced = 0
	while largePlaced < largeCount and attempts < maxAttempts do
		attempts += 1
		local px = rng:NextNumber(-halfW * 0.7, halfW * 0.7)
		local pz = rng:NextNumber(-halfD * 0.7, halfD * 0.7)
		local candidate = Vector3.new(snapToGrid(px, gridSize), LEVEL_1_Y, snapToGrid(pz, gridSize))

		local tooClose = false
		for _, existing in allPlatformPositions do
			if (Vector3.new(candidate.X, 0, candidate.Z) - Vector3.new(existing.X, 0, existing.Z)).Magnitude < MIN_PLATFORM_SPACING then
				tooClose = true
				break
			end
		end
		if tooClose then continue end

		table.insert(allPlatformPositions, candidate)
		largePlaced += 1
		table.insert(platforms, {
			pos = candidate,
			prefabName = "MetalPlatformLarge",
			index = #platforms + 1,
		})
	end

	-- Place medium platforms
	local mediumPlaced = 0
	while mediumPlaced < mediumCount and attempts < maxAttempts do
		attempts += 1
		local px = rng:NextNumber(-halfW * 0.75, halfW * 0.75)
		local pz = rng:NextNumber(-halfD * 0.75, halfD * 0.75)
		local candidate = Vector3.new(snapToGrid(px, gridSize), LEVEL_1_Y, snapToGrid(pz, gridSize))

		local tooClose = false
		for _, existing in allPlatformPositions do
			if (Vector3.new(candidate.X, 0, candidate.Z) - Vector3.new(existing.X, 0, existing.Z)).Magnitude < MIN_PLATFORM_SPACING then
				tooClose = true
				break
			end
		end
		if tooClose then continue end

		table.insert(allPlatformPositions, candidate)
		mediumPlaced += 1
		table.insert(platforms, {
			pos = candidate,
			prefabName = "MetalPlatformMedium",
			index = #platforms + 1,
		})
	end

	-- Place the Level 1 platform instances (skip anvil at index 1, already placed)
	for i = 2, #platforms do
		local info = platforms[i]
		local plat = clonePrefab(prefabFolder, info.prefabName, info.pos)
		positionInstance(plat, CFrame.new(info.pos))
		tagInstance(plat, "LavaForge_Level1")
		plat.Parent = arenaFolder
	end

	--------------------------------------------------------------------
	-- MST BRIDGE CONNECTIONS: Prim's algorithm to connect all Level 1
	-- platforms, then add 2-3 extra random bridges for alternate routes
	--------------------------------------------------------------------

	-- Build distance matrix (XZ plane only)
	local platCount = #platforms
	local dist: { { number } } = {}
	for i = 1, platCount do
		dist[i] = {}
		for j = 1, platCount do
			local pi = platforms[i].pos
			local pj = platforms[j].pos
			dist[i][j] = (Vector3.new(pi.X, 0, pi.Z) - Vector3.new(pj.X, 0, pj.Z)).Magnitude
		end
	end

	-- Prim's MST
	local inMST: { [number]: boolean } = { [1] = true }
	local mstEdges: { { from: number, to: number } } = {}
	local edgeSet: { [string]: boolean } = {} -- track "i-j" pairs to avoid duplicates

	for _ = 1, platCount - 1 do
		local bestDist = math.huge
		local bestFrom = 0
		local bestTo = 0

		for i = 1, platCount do
			if not inMST[i] then continue end
			for j = 1, platCount do
				if inMST[j] then continue end
				if dist[i][j] < bestDist then
					bestDist = dist[i][j]
					bestFrom = i
					bestTo = j
				end
			end
		end

		if bestFrom > 0 and bestTo > 0 then
			inMST[bestTo] = true
			table.insert(mstEdges, { from = bestFrom, to = bestTo })
			local minIdx = math.min(bestFrom, bestTo)
			local maxIdx = math.max(bestFrom, bestTo)
			edgeSet[minIdx .. "-" .. maxIdx] = true
		end
	end

	-- Add 2-3 extra random bridges beyond the MST
	local extraBridgeCount = rng:NextInteger(2, 3)
	local extraAdded = 0
	local extraAttempts = 0
	while extraAdded < extraBridgeCount and extraAttempts < extraBridgeCount * 20 do
		extraAttempts += 1
		local a = rng:NextInteger(1, platCount)
		local b = rng:NextInteger(1, platCount)
		if a == b then continue end
		local minIdx = math.min(a, b)
		local maxIdx = math.max(a, b)
		local key = minIdx .. "-" .. maxIdx
		if edgeSet[key] then continue end
		-- Don't bridge extremely distant platforms
		if dist[a][b] > halfW then continue end

		edgeSet[key] = true
		table.insert(mstEdges, { from = a, to = b })
		extraAdded += 1
	end

	-- Place Bridge prefabs along all edges
	for _, edge in mstEdges do
		local fromPos = platforms[edge.from].pos
		local toPos = platforms[edge.to].pos
		local midpoint = (fromPos + toPos) / 2
		local direction = toPos - fromPos
		local angle = math.atan2(direction.X, direction.Z)
		local bridgeY = math.min(fromPos.Y, toPos.Y)

		local bridgePos = Vector3.new(midpoint.X, bridgeY, midpoint.Z)
		local bridge = clonePrefab(prefabFolder, "Bridge", bridgePos)
		positionInstance(bridge, CFrame.new(bridgePos + Vector3.new(0, 0.5, 0)) * CFrame.Angles(0, angle, 0))

		-- Tag bridges with level info for the lava rising system
		tagInstance(bridge, "LavaForge_Bridge")
		-- Store approximate Y as an attribute for the hazard system
		if bridge:IsA("BasePart") then
			bridge:SetAttribute("BridgeY", bridgeY)
		elseif bridge:IsA("Model") then
			bridge:SetAttribute("BridgeY", bridgeY)
		end

		bridge.Parent = arenaFolder
	end

	--------------------------------------------------------------------
	-- LEVEL 2 PLATFORMS (Y = 22): 3-4 MetalPlatformSmall above Level 1,
	-- connected down by MetalRamp prefabs
	--------------------------------------------------------------------
	local level2Count = rng:NextInteger(3, 4)
	local level2Platforms: { Vector3 } = {}
	local l2Attempts = 0

	while #level2Platforms < level2Count and l2Attempts < level2Count * 40 do
		l2Attempts += 1

		-- Pick a random Level 1 platform to build above (not the anvil for variety)
		local baseIdx = rng:NextInteger(2, #platforms)
		local basePos = platforms[baseIdx].pos

		-- Offset slightly so it's not directly stacked
		local offsetX = rng:NextNumber(-gridSize, gridSize)
		local offsetZ = rng:NextNumber(-gridSize, gridSize)
		local candidate = Vector3.new(
			snapToGrid(basePos.X + offsetX, gridSize),
			LEVEL_2_Y,
			snapToGrid(basePos.Z + offsetZ, gridSize)
		)

		-- Check spacing from other Level 2 platforms
		local tooClose = false
		for _, existing in level2Platforms do
			if (Vector3.new(candidate.X, 0, candidate.Z) - Vector3.new(existing.X, 0, existing.Z)).Magnitude < MIN_PLATFORM_SPACING then
				tooClose = true
				break
			end
		end
		if tooClose then continue end

		table.insert(level2Platforms, candidate)

		-- Place the small platform
		local l2Plat = clonePrefab(prefabFolder, "MetalPlatformSmall", candidate)
		positionInstance(l2Plat, CFrame.new(candidate))
		tagInstance(l2Plat, "LavaForge_Level2")
		l2Plat.Parent = arenaFolder

		-- Place a MetalRamp connecting down to the base Level 1 platform
		local rampMid = (candidate + basePos) / 2
		local rampDir = basePos - candidate
		local rampAngle = math.atan2(rampDir.X, rampDir.Z)
		local rampPos = Vector3.new(rampMid.X, (LEVEL_1_Y + LEVEL_2_Y) / 2, rampMid.Z)

		local ramp = clonePrefab(prefabFolder, "MetalRamp", rampPos)
		positionInstance(ramp, CFrame.new(rampPos) * CFrame.Angles(0, rampAngle, 0))
		ramp.Parent = arenaFolder
	end

	--------------------------------------------------------------------
	-- GEYSER POSITIONS: 5-7 GeyserBase prefabs on the lava floor,
	-- tagged "Geyser" for the eruption hazard system
	--------------------------------------------------------------------
	local geyserCount = rng:NextInteger(GEYSER_COUNT_MIN, GEYSER_COUNT_MAX)
	local geyserPositions: { Vector3 } = {}
	local geyserAttempts = 0

	while #geyserPositions < geyserCount and geyserAttempts < geyserCount * 40 do
		geyserAttempts += 1
		local gx = rng:NextNumber(-halfW * 0.8, halfW * 0.8)
		local gz = rng:NextNumber(-halfD * 0.8, halfD * 0.8)
		local candidate = Vector3.new(snapToGrid(gx, gridSize), 0, snapToGrid(gz, gridSize))

		-- Must not overlap with any platform (check XZ distance)
		local overlaps = false
		for _, pInfo in platforms do
			if (Vector3.new(candidate.X, 0, candidate.Z) - Vector3.new(pInfo.pos.X, 0, pInfo.pos.Z)).Magnitude < 20 then
				overlaps = true
				break
			end
		end
		if overlaps then continue end

		-- Min spacing between geysers
		local tooClose = false
		for _, existing in geyserPositions do
			if (candidate - existing).Magnitude < 20 then
				tooClose = true
				break
			end
		end
		if tooClose then continue end

		table.insert(geyserPositions, candidate)
	end

	for _, geyserPos in geyserPositions do
		local geyser = clonePrefab(prefabFolder, "GeyserBase", geyserPos)
		positionInstance(geyser, CFrame.new(geyserPos + Vector3.new(0, 1, 0)))
		tagInstance(geyser, "Geyser")

		-- Add an upward-pointing orange PointLight for visual cue
		if geyser:IsA("BasePart") then
			local light = Instance.new("PointLight")
			light.Color = LAVA_GLOW_COLOR
			light.Brightness = 0.6
			light.Range = 12
			light.Parent = geyser
		end

		geyser.Parent = arenaFolder
	end

	--------------------------------------------------------------------
	-- DECORATIVE: Chain prefabs hanging from above, ForgePipe prefabs
	-- along platform edges, ember PointLights near forge
	--------------------------------------------------------------------

	-- Chains hanging from above at random positions
	for _ = 1, CHAIN_COUNT do
		local cx = rng:NextNumber(-halfW * 0.6, halfW * 0.6)
		local cz = rng:NextNumber(-halfD * 0.6, halfD * 0.6)
		local chainY = LEVEL_2_Y + rng:NextNumber(4, 10)
		local chainPos = Vector3.new(cx, chainY, cz)
		local chain = cloneRandomVariant(prefabFolder, "Chain", chainPos)
		positionInstance(chain, CFrame.new(chainPos))
		chain.Parent = arenaFolder
	end

	-- ForgePipes along random platform edges
	for _ = 1, PIPE_COUNT do
		-- Pick a random Level 1 platform to attach a pipe to
		local platIdx = rng:NextInteger(1, #platforms)
		local platPos = platforms[platIdx].pos
		local pipeAngle = rng:NextNumber(0, 2 * math.pi)
		local pipeOffset = 14
		local pipeX = platPos.X + math.cos(pipeAngle) * pipeOffset
		local pipeZ = platPos.Z + math.sin(pipeAngle) * pipeOffset
		local pipePos = Vector3.new(pipeX, LEVEL_1_Y, pipeZ)
		local pipe = cloneRandomVariant(prefabFolder, "ForgePipe", pipePos)
		positionInstance(pipe, CFrame.new(pipePos + Vector3.new(0, 4, 0)))
		pipe.Parent = arenaFolder
	end

	-- Ember PointLights near the forge area for atmosphere
	local emberAngles = { math.pi / 6, math.pi / 3, 2 * math.pi / 3, 5 * math.pi / 6,
		7 * math.pi / 6, 4 * math.pi / 3, 5 * math.pi / 3, 11 * math.pi / 6 }
	for _, angle in emberAngles do
		local ex = math.cos(angle) * 24
		local ez = math.sin(angle) * 24
		local emberPart = Instance.new("Part")
		emberPart.Name = "EmberLight"
		emberPart.Size = Vector3.new(1, 1, 1)
		emberPart.Transparency = 1
		emberPart.Anchored = true
		emberPart.CanCollide = false
		emberPart.Position = Vector3.new(ex, LEVEL_1_Y + 3, ez)

		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 120, 30)
		light.Brightness = 0.4
		light.Range = 14
		light.Parent = emberPart

		emberPart.Parent = arenaFolder
	end

	--------------------------------------------------------------------
	-- SPAWN POINTS: only on platforms, at least 2 on the AnvilPlatform,
	-- remaining distributed across Level 1 and Level 2 platforms
	--------------------------------------------------------------------
	local spawnCount = arenaData.spawnCount
	local minSpawnDist = arenaData.minSpawnDistance
	local spawnPositions: { Vector3 } = {}

	-- 2 spawns on the anvil platform (center area with slight offset)
	local anvilSpawnOffsets = {
		Vector3.new(-8, 0, 0),
		Vector3.new(8, 0, 0),
	}
	for _, offset in anvilSpawnOffsets do
		table.insert(spawnPositions, anvilPos + offset + Vector3.new(0, 1, 0))
	end

	-- Collect all available platform surfaces for remaining spawns
	-- (Level 1 platforms excluding anvil, plus Level 2 platforms)
	local spawnableSurfaces: { Vector3 } = {}
	for i = 2, #platforms do
		table.insert(spawnableSurfaces, platforms[i].pos + Vector3.new(0, 1, 0))
	end
	for _, l2Pos in level2Platforms do
		table.insert(spawnableSurfaces, l2Pos + Vector3.new(0, 1, 0))
	end

	-- Distribute remaining spawns across platforms with jitter
	local remaining = spawnCount - #spawnPositions
	local surfIdx = 0
	local spawnAttempts = 0
	local maxSpawnAttempts = remaining * 40

	while #spawnPositions < spawnCount and spawnAttempts < maxSpawnAttempts do
		spawnAttempts += 1
		surfIdx = (surfIdx % #spawnableSurfaces) + 1
		local basePos = spawnableSurfaces[surfIdx]

		-- Add slight jitter on the platform surface
		local jx = rng:NextNumber(-6, 6)
		local jz = rng:NextNumber(-6, 6)
		local candidate = Vector3.new(basePos.X + jx, basePos.Y, basePos.Z + jz)

		-- Check minimum spacing
		local tooClose = false
		for _, existing in spawnPositions do
			if (candidate - existing).Magnitude < minSpawnDist then
				tooClose = true
				break
			end
		end
		if tooClose then continue end

		table.insert(spawnPositions, candidate)
	end

	-- Place spawn points using the core function
	placeSpawnPoints(spawnPositions, arenaFolder)
end

--- Generate Shadow Maze layout: dark dungeon labyrinth (180x180 studs).
--- 15x15 cell grid with recursive backtracking maze, 5 open rooms (3x3 cells),
--- hidden passages (CrackedWall), shifting walls, torches with PointLights,
--- ceiling with room cutouts, and room-only spawn points.
local function generateShadowMaze(arenaFolder: Folder, arenaData: ArenaData, prefabFolder: Folder?)
	local gridSize = arenaData.gridSize -- 12
	local halfW = (arenaData.bounds.width or 180) / 2 -- 90
	local halfD = (arenaData.bounds.depth or 180) / 2 -- 90

	local CELLS = 15
	local WALL_HEIGHT = 12
	local CEILING_Y = WALL_HEIGHT
	local ROOM_COUNT = 5
	local ROOM_SIZE = 3 -- 3x3 cells per room
	local ROOM_MIN_SPACING = 4 -- min Chebyshev distance between room origins
	local HIDDEN_PASSAGE_MIN = 6
	local HIDDEN_PASSAGE_MAX = 8
	local SHIFTING_WALL_MIN = 6
	local SHIFTING_WALL_MAX = 8
	local TORCH_CORRIDOR_CHANCE = 0.20
	local TORCH_ROOM_MIN = 2
	local TORCH_ROOM_MAX = 4
	local TORCH_LIGHT_RANGE = 15
	local TORCH_LIGHT_BRIGHTNESS = 0.8
	local TORCH_LIGHT_COLOR = Color3.fromRGB(255, 160, 60)

	local originX = -halfW -- -90
	local originZ = -halfD -- -90

	--------------------------------------------------------------------
	-- Helpers
	--------------------------------------------------------------------
	local function positionInstance(inst: Instance, cframe: CFrame)
		if inst:IsA("Model") then
			inst:PivotTo(cframe)
		elseif inst:IsA("BasePart") then
			inst.CFrame = cframe
		end
	end

	local function tagInstance(inst: Instance, tag: string)
		if inst:IsA("BasePart") then
			CollectionService:AddTag(inst, tag)
		end
		for _, child in inst:GetDescendants() do
			if child:IsA("BasePart") then
				CollectionService:AddTag(child, tag)
			end
		end
	end

	local function addTorchLight(inst: Instance)
		local light = Instance.new("PointLight")
		light.Color = TORCH_LIGHT_COLOR
		light.Brightness = TORCH_LIGHT_BRIGHTNESS
		light.Range = TORCH_LIGHT_RANGE
		if inst:IsA("BasePart") then
			light.Parent = inst
		elseif inst:IsA("Model") then
			local primary = inst:FindFirstChildWhichIsA("BasePart")
			light.Parent = primary or inst
		end
	end

	--- Cell center world position for cell (ci, cj), 1-indexed.
	local function cellCenter(ci: number, cj: number): Vector3
		return Vector3.new(
			originX + (ci - 1) * gridSize + gridSize / 2,
			0,
			originZ + (cj - 1) * gridSize + gridSize / 2
		)
	end

	--- CFrame for a vertical wall between cell (ci,cj) and cell (ci+1,cj).
	--- Thin in X, runs along Z. Rotated 90° so the 12-stud width faces Z.
	local function vWallCFrame(ci: number, cj: number): CFrame
		return CFrame.new(
			originX + ci * gridSize,
			WALL_HEIGHT / 2,
			originZ + (cj - 1) * gridSize + gridSize / 2
		) * CFrame.Angles(0, math.pi / 2, 0)
	end

	--- CFrame for a horizontal wall between cell (ci,cj) and cell (ci,cj+1).
	--- Thin in Z, runs along X. Default orientation (no rotation).
	local function hWallCFrame(ci: number, cj: number): CFrame
		return CFrame.new(
			originX + (ci - 1) * gridSize + gridSize / 2,
			WALL_HEIGHT / 2,
			originZ + cj * gridSize
		)
	end

	--------------------------------------------------------------------
	-- MAZE GENERATION: recursive backtracking
	--------------------------------------------------------------------

	-- wallV[i][j] = vertical wall between cell(i,j) and cell(i+1,j)
	local wallV: { { boolean } } = {}
	for i = 1, CELLS - 1 do
		wallV[i] = {}
		for j = 1, CELLS do
			wallV[i][j] = true
		end
	end

	-- wallH[i][j] = horizontal wall between cell(i,j) and cell(i,j+1)
	local wallH: { { boolean } } = {}
	for i = 1, CELLS do
		wallH[i] = {}
		for j = 1, CELLS - 1 do
			wallH[i][j] = true
		end
	end

	local mazeVisited: { { boolean } } = {}
	for i = 1, CELLS do
		mazeVisited[i] = {}
		for j = 1, CELLS do
			mazeVisited[i][j] = false
		end
	end

	local startI = rng:NextInteger(1, CELLS)
	local startJ = rng:NextInteger(1, CELLS)
	mazeVisited[startI][startJ] = true
	local stack: { { number } } = { { startI, startJ } }

	while #stack > 0 do
		local current = stack[#stack]
		local ci, cj = current[1], current[2]

		local neighbors: { { number } } = {}
		if ci > 1 and not mazeVisited[ci - 1][cj] then
			table.insert(neighbors, { ci - 1, cj, 1 }) -- left
		end
		if ci < CELLS and not mazeVisited[ci + 1][cj] then
			table.insert(neighbors, { ci + 1, cj, 2 }) -- right
		end
		if cj > 1 and not mazeVisited[ci][cj - 1] then
			table.insert(neighbors, { ci, cj - 1, 3 }) -- up
		end
		if cj < CELLS and not mazeVisited[ci][cj + 1] then
			table.insert(neighbors, { ci, cj + 1, 4 }) -- down
		end

		if #neighbors > 0 then
			local chosen = neighbors[rng:NextInteger(1, #neighbors)]
			local ni, nj, dir = chosen[1], chosen[2], chosen[3]

			if dir == 1 then     wallV[ni][cj] = false
			elseif dir == 2 then wallV[ci][cj] = false
			elseif dir == 3 then wallH[ci][nj] = false
			elseif dir == 4 then wallH[ci][cj] = false
			end

			mazeVisited[ni][nj] = true
			table.insert(stack, { ni, nj })
		else
			table.remove(stack)
		end
	end

	--------------------------------------------------------------------
	-- OPEN ROOMS: carve 5 rooms (3x3 cells each)
	--------------------------------------------------------------------

	type RoomData = { ci: number, cj: number, tag: string }
	local rooms: { RoomData } = {}

	-- Room 1: near center
	local centerI = math.floor((CELLS - ROOM_SIZE) / 2) + 1
	local centerJ = math.floor((CELLS - ROOM_SIZE) / 2) + 1
	table.insert(rooms, { ci = centerI, cj = centerJ, tag = "MazeRoom_1" })

	-- Rooms 2-5: random positions with minimum spacing
	local roomAttempts = 0
	while #rooms < ROOM_COUNT and roomAttempts < 300 do
		roomAttempts += 1
		local ri = rng:NextInteger(1, CELLS - ROOM_SIZE + 1)
		local rj = rng:NextInteger(1, CELLS - ROOM_SIZE + 1)

		local valid = true
		for _, room in rooms do
			if math.max(math.abs(ri - room.ci), math.abs(rj - room.cj)) < ROOM_MIN_SPACING then
				valid = false
				break
			end
		end

		if valid then
			table.insert(rooms, { ci = ri, cj = rj, tag = "MazeRoom_" .. (#rooms + 1) })
		end
	end

	-- Track which cells are in rooms
	local inRoom: { { boolean } } = {}
	for i = 1, CELLS do
		inRoom[i] = {}
		for j = 1, CELLS do
			inRoom[i][j] = false
		end
	end

	-- Carve rooms: remove all internal walls within each 3x3 room
	for _, room in rooms do
		for i = room.ci, room.ci + ROOM_SIZE - 1 do
			for j = room.cj, room.cj + ROOM_SIZE - 1 do
				inRoom[i][j] = true
				if i < room.ci + ROOM_SIZE - 1 and i <= CELLS - 1 then
					wallV[i][j] = false
				end
				if j < room.cj + ROOM_SIZE - 1 and j <= CELLS - 1 then
					wallH[i][j] = false
				end
			end
		end
	end

	--------------------------------------------------------------------
	-- FLOOR: FloorTile for corridors, RoomFloorTile for rooms
	--------------------------------------------------------------------
	for ci = 1, CELLS do
		for cj = 1, CELLS do
			local pos = cellCenter(ci, cj)
			local prefabName = if inRoom[ci][cj] then "RoomFloorTile" else "FloorTile"
			local tile = cloneRandomVariant(prefabFolder, prefabName, pos)

			if inRoom[ci][cj] then
				for _, room in rooms do
					if ci >= room.ci and ci <= room.ci + ROOM_SIZE - 1
						and cj >= room.cj and cj <= room.cj + ROOM_SIZE - 1 then
						tagInstance(tile, room.tag)
						break
					end
				end
			end

			tile.Parent = arenaFolder
		end
	end

	--------------------------------------------------------------------
	-- WALL CONSTRUCTION: internal walls, boundary walls, corner pieces
	--------------------------------------------------------------------

	type WallEntry = { inst: Instance, cf: CFrame, isVertical: boolean }
	local interiorWalls: { WallEntry } = {}

	-- Internal vertical walls
	for i = 1, CELLS - 1 do
		for j = 1, CELLS do
			if wallV[i][j] then
				local cf = vWallCFrame(i, j)
				local wall = cloneRandomVariant(prefabFolder, "MazeWallSegment", cf.Position)
				positionInstance(wall, cf)
				wall.Parent = arenaFolder

				if not inRoom[i][j] and not inRoom[i + 1][j] then
					table.insert(interiorWalls, { inst = wall, cf = cf, isVertical = true })
				end
			end
		end
	end

	-- Internal horizontal walls
	for i = 1, CELLS do
		for j = 1, CELLS - 1 do
			if wallH[i][j] then
				local cf = hWallCFrame(i, j)
				local wall = cloneRandomVariant(prefabFolder, "MazeWallSegment", cf.Position)
				positionInstance(wall, cf)
				wall.Parent = arenaFolder

				if not inRoom[i][j] and not inRoom[i][j + 1] then
					table.insert(interiorWalls, { inst = wall, cf = cf, isVertical = false })
				end
			end
		end
	end

	-- Boundary walls (outer perimeter)
	-- Top (Z = originZ) and bottom (Z = originZ + CELLS*gridSize)
	for i = 1, CELLS do
		local x = originX + (i - 1) * gridSize + gridSize / 2
		for _, z in { originZ, originZ + CELLS * gridSize } do
			local cf = CFrame.new(x, WALL_HEIGHT / 2, z)
			local wall = clonePrefab(prefabFolder, "MazeWallSegment", cf.Position)
			positionInstance(wall, cf)
			wall.Parent = arenaFolder
		end
	end
	-- Left (X = originX) and right (X = originX + CELLS*gridSize)
	for j = 1, CELLS do
		local z = originZ + (j - 1) * gridSize + gridSize / 2
		for _, x in { originX, originX + CELLS * gridSize } do
			local cf = CFrame.new(x, WALL_HEIGHT / 2, z) * CFrame.Angles(0, math.pi / 2, 0)
			local wall = clonePrefab(prefabFolder, "MazeWallSegment", cf.Position)
			positionInstance(wall, cf)
			wall.Parent = arenaFolder
		end
	end

	-- Corner pieces at interior intersections where walls meet
	for i = 1, CELLS - 1 do
		for j = 1, CELLS - 1 do
			local hasWall = wallV[i][j] or wallV[i][j + 1] or wallH[i][j] or wallH[i + 1][j]
			if hasWall then
				local pos = Vector3.new(originX + i * gridSize, WALL_HEIGHT / 2, originZ + j * gridSize)
				local corner = cloneRandomVariant(prefabFolder, "MazeWallCorner", pos)
				positionInstance(corner, CFrame.new(pos))
				corner.Parent = arenaFolder
			end
		end
	end

	--------------------------------------------------------------------
	-- HIDDEN PASSAGES: replace 6-8 interior walls with CrackedWall,
	-- tagged "BreakableWall" for the combat system
	--------------------------------------------------------------------

	-- Shuffle interior walls
	local shuffledWalls = table.clone(interiorWalls)
	for i = #shuffledWalls, 2, -1 do
		local j = rng:NextInteger(1, i)
		shuffledWalls[i], shuffledWalls[j] = shuffledWalls[j], shuffledWalls[i]
	end

	local hiddenCount = math.min(rng:NextInteger(HIDDEN_PASSAGE_MIN, HIDDEN_PASSAGE_MAX), #shuffledWalls)
	local hiddenSet: { [Instance]: boolean } = {}

	for idx = 1, hiddenCount do
		local entry = shuffledWalls[idx]
		local oldInst = entry.inst
		hiddenSet[oldInst] = true
		oldInst:Destroy()

		local cracked = clonePrefab(prefabFolder, "CrackedWall", entry.cf.Position)
		positionInstance(cracked, entry.cf)
		tagInstance(cracked, "BreakableWall")

		-- Subtle glow hint for observant players
		if cracked:IsA("BasePart") then
			local glow = Instance.new("PointLight")
			glow.Color = Color3.fromRGB(180, 160, 255)
			glow.Brightness = 0.15
			glow.Range = 6
			glow.Parent = cracked
		end

		cracked.Parent = arenaFolder
	end

	--------------------------------------------------------------------
	-- DOORWAY ARCHES: at every entrance to an open room
	--------------------------------------------------------------------
	for _, room in rooms do
		local ri, rj = room.ci, room.cj
		local endI = ri + ROOM_SIZE - 1
		local endJ = rj + ROOM_SIZE - 1

		-- Top doorways (between row rj-1 and rj)
		if rj > 1 then
			for i = ri, endI do
				if not wallH[i][rj - 1] then
					local wCf = hWallCFrame(i, rj - 1)
					local archCf = CFrame.new(wCf.Position.X, 7, wCf.Position.Z) * wCf.Rotation
					local arch = clonePrefab(prefabFolder, "DoorwayArch", archCf.Position)
					positionInstance(arch, archCf)
					arch.Parent = arenaFolder
				end
			end
		end

		-- Bottom doorways (between row endJ and endJ+1)
		if endJ < CELLS then
			for i = ri, endI do
				if not wallH[i][endJ] then
					local wCf = hWallCFrame(i, endJ)
					local archCf = CFrame.new(wCf.Position.X, 7, wCf.Position.Z) * wCf.Rotation
					local arch = clonePrefab(prefabFolder, "DoorwayArch", archCf.Position)
					positionInstance(arch, archCf)
					arch.Parent = arenaFolder
				end
			end
		end

		-- Left doorways (between col ri-1 and ri)
		if ri > 1 then
			for j = rj, endJ do
				if not wallV[ri - 1][j] then
					local wCf = vWallCFrame(ri - 1, j)
					local archCf = CFrame.new(wCf.Position.X, 7, wCf.Position.Z) * wCf.Rotation
					local arch = clonePrefab(prefabFolder, "DoorwayArch", archCf.Position)
					positionInstance(arch, archCf)
					arch.Parent = arenaFolder
				end
			end
		end

		-- Right doorways (between col endI and endI+1)
		if endI < CELLS then
			for j = rj, endJ do
				if not wallV[endI][j] then
					local wCf = vWallCFrame(endI, j)
					local archCf = CFrame.new(wCf.Position.X, 7, wCf.Position.Z) * wCf.Rotation
					local arch = clonePrefab(prefabFolder, "DoorwayArch", archCf.Position)
					positionInstance(arch, archCf)
					arch.Parent = arenaFolder
				end
			end
		end
	end

	--------------------------------------------------------------------
	-- SHIFTING WALLS: 6-8 interior walls (not hidden, not room walls)
	-- tagged "ShiftingWall" with original/shifted CFrame attributes
	--------------------------------------------------------------------
	local shiftCandidates: { WallEntry } = {}
	for idx = hiddenCount + 1, #shuffledWalls do
		local entry = shuffledWalls[idx]
		if not hiddenSet[entry.inst] then
			table.insert(shiftCandidates, entry)
		end
	end

	local shiftCount = math.min(rng:NextInteger(SHIFTING_WALL_MIN, SHIFTING_WALL_MAX), #shiftCandidates)
	for idx = 1, shiftCount do
		local entry = shiftCandidates[idx]
		local inst = entry.inst
		tagInstance(inst, "ShiftingWall")

		-- Store original CFrame
		local originalCf = entry.cf
		-- Shifted CFrame: slide one grid unit perpendicular to the wall
		local shiftOffset: Vector3
		if entry.isVertical then
			shiftOffset = Vector3.new(0, 0, gridSize) -- slide along Z
		else
			shiftOffset = Vector3.new(gridSize, 0, 0) -- slide along X
		end
		local shiftedCf = CFrame.new(originalCf.Position + shiftOffset) * originalCf.Rotation

		if inst:IsA("BasePart") then
			inst:SetAttribute("OriginalCFrameX", originalCf.Position.X)
			inst:SetAttribute("OriginalCFrameY", originalCf.Position.Y)
			inst:SetAttribute("OriginalCFrameZ", originalCf.Position.Z)
			inst:SetAttribute("ShiftedCFrameX", shiftedCf.Position.X)
			inst:SetAttribute("ShiftedCFrameY", shiftedCf.Position.Y)
			inst:SetAttribute("ShiftedCFrameZ", shiftedCf.Position.Z)
			inst:SetAttribute("IsVertical", entry.isVertical)
		elseif inst:IsA("Model") then
			inst:SetAttribute("OriginalCFrameX", originalCf.Position.X)
			inst:SetAttribute("OriginalCFrameY", originalCf.Position.Y)
			inst:SetAttribute("OriginalCFrameZ", originalCf.Position.Z)
			inst:SetAttribute("ShiftedCFrameX", shiftedCf.Position.X)
			inst:SetAttribute("ShiftedCFrameY", shiftedCf.Position.Y)
			inst:SetAttribute("ShiftedCFrameZ", shiftedCf.Position.Z)
			inst:SetAttribute("IsVertical", entry.isVertical)
		end
	end

	--------------------------------------------------------------------
	-- TORCHES: TorchSconce with PointLight
	-- 2-4 per room, 20% chance per corridor wall segment
	--------------------------------------------------------------------

	-- Room torches: place on room perimeter walls that still exist
	for _, room in rooms do
		local ri, rj = room.ci, room.cj
		local endI = ri + ROOM_SIZE - 1
		local endJ = rj + ROOM_SIZE - 1
		local roomTorchTarget = rng:NextInteger(TORCH_ROOM_MIN, TORCH_ROOM_MAX)
		local roomTorchPlaced = 0

		-- Collect existing walls on the room perimeter for torch placement
		local perimeterPositions: { CFrame } = {}

		-- Top perimeter
		if rj > 1 then
			for i = ri, endI do
				if wallH[i][rj - 1] then
					table.insert(perimeterPositions, hWallCFrame(i, rj - 1))
				end
			end
		end
		-- Bottom perimeter
		if endJ < CELLS then
			for i = ri, endI do
				if wallH[i][endJ] then
					table.insert(perimeterPositions, hWallCFrame(i, endJ))
				end
			end
		end
		-- Left perimeter
		if ri > 1 then
			for j = rj, endJ do
				if wallV[ri - 1][j] then
					table.insert(perimeterPositions, vWallCFrame(ri - 1, j))
				end
			end
		end
		-- Right perimeter
		if endI < CELLS then
			for j = rj, endJ do
				if wallV[endI][j] then
					table.insert(perimeterPositions, vWallCFrame(endI, j))
				end
			end
		end

		-- Shuffle and pick up to roomTorchTarget positions
		for i = #perimeterPositions, 2, -1 do
			local j = rng:NextInteger(1, i)
			perimeterPositions[i], perimeterPositions[j] = perimeterPositions[j], perimeterPositions[i]
		end
		for _, wallCf in perimeterPositions do
			if roomTorchPlaced >= roomTorchTarget then break end
			local torchPos = Vector3.new(wallCf.Position.X, 5, wallCf.Position.Z)
			local torch = clonePrefab(prefabFolder, "TorchSconce", torchPos)
			positionInstance(torch, CFrame.new(torchPos))
			addTorchLight(torch)
			torch.Parent = arenaFolder
			roomTorchPlaced += 1
		end
	end

	-- Corridor torches: 20% chance per existing interior wall (not hidden, not in rooms)
	for idx = hiddenCount + 1, #shuffledWalls do
		local entry = shuffledWalls[idx]
		if not hiddenSet[entry.inst] and rng:NextNumber() < TORCH_CORRIDOR_CHANCE then
			local torchPos = Vector3.new(entry.cf.Position.X, 5, entry.cf.Position.Z)
			local torch = clonePrefab(prefabFolder, "TorchSconce", torchPos)
			positionInstance(torch, CFrame.new(torchPos))
			addTorchLight(torch)
			torch.Parent = arenaFolder
		end
	end

	--------------------------------------------------------------------
	-- CEILING: CeilingTile at Y = 12 over all cells, with holes over rooms
	--------------------------------------------------------------------
	for ci = 1, CELLS do
		for cj = 1, CELLS do
			if not inRoom[ci][cj] then
				local pos = cellCenter(ci, cj)
				local ceilingPos = Vector3.new(pos.X, CEILING_Y, pos.Z)
				local ceiling = cloneRandomVariant(prefabFolder, "CeilingTile", ceilingPos)
				positionInstance(ceiling, CFrame.new(ceilingPos))

				-- Make ceiling dark
				if ceiling:IsA("BasePart") then
					ceiling.Color = Color3.fromRGB(30, 30, 40)
				end

				ceiling.Parent = arenaFolder
			end
		end
	end

	--------------------------------------------------------------------
	-- SPAWN POINTS: 2 per room (10 total), only inside open rooms
	--------------------------------------------------------------------
	local spawnPositions: { Vector3 } = {}
	local minSpawnDist = arenaData.minSpawnDistance

	for _, room in rooms do
		local roomCenterI = room.ci + 1 -- center cell of 3x3
		local roomCenterJ = room.cj + 1
		local center = cellCenter(roomCenterI, roomCenterJ)

		-- Two spawns per room, offset from center
		local offsets = {
			Vector3.new(-gridSize * 0.5, 0, 0),
			Vector3.new(gridSize * 0.5, 0, 0),
		}
		for _, offset in offsets do
			local candidate = center + offset + Vector3.new(0, 1, 0)
			-- Check spacing against existing spawns
			local valid = true
			for _, existing in spawnPositions do
				if (candidate - existing).Magnitude < minSpawnDist then
					valid = false
					break
				end
			end
			if valid then
				table.insert(spawnPositions, candidate)
			else
				-- Fallback: use center with small random jitter
				local jitter = Vector3.new(rng:NextNumber(-3, 3), 0, rng:NextNumber(-3, 3))
				table.insert(spawnPositions, center + jitter + Vector3.new(0, 1, 0))
			end
		end
	end

	placeSpawnPoints(spawnPositions, arenaFolder)
end

--- Generate Jungle Ruins layout: overgrown ancient temple ruins using a
--- zone-based approach. The 200×200 arena is divided into a 5×5 grid of
--- 40×40 zones, each assigned a type: temple, forest, trap_corridor,
--- courtyard, or elevated_ruins. Includes traps, dense vegetation, rope
--- bridges between elevated areas, and ambient environmental details.
local function generateJungleRuins(arenaFolder: Folder, arenaData: ArenaData, prefabFolder: Folder?)
	print("[JungleRuins v5] === GENERATING JUNGLE RUINS (LATEST VERSION) ===")
	print("[JungleRuins v5] FillCylinder water (no FillBall), visible ground fog, 2x tree density")
	local halfW = (arenaData.bounds.width or 2000) / 2
	local halfD = (arenaData.bounds.depth or 2000) / 2
	local terrain = Workspace.Terrain
	print("[JungleRuins v5] halfW=" .. halfW .. " halfD=" .. halfD)

	local ZONE_SIZE = 100
	local ZONE_COUNT = 10
	local ELEVATED_Y = 30

	--------------------------------------------------------------------
	-- Utility helpers
	--------------------------------------------------------------------

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { arenaFolder }

	--- Raycast downward to find actual terrain surface height at (x, z).
	--- Returns the Y position of the surface, or 0 if no hit.
	local function getTerrainHeight(x: number, z: number): number
		local origin = Vector3.new(x, 500, z)
		local direction = Vector3.new(0, -1000, 0)
		local result = Workspace:Raycast(origin, direction, rayParams)
		if result then
			return result.Position.Y
		end
		return 0
	end

	local function positionInstance(inst: Instance, cframe: CFrame)
		if inst:IsA("Model") then
			inst:PivotTo(cframe)
		elseif inst:IsA("BasePart") then
			inst.CFrame = cframe
		end
	end

	local function cloneWithCFrame(baseName: string, cf: CFrame): Instance
		if prefabFolder then
			local variants: { Instance } = {}
			for _, child in prefabFolder:GetChildren() do
				if child.Name == baseName or string.match(child.Name, "^" .. baseName .. "_%d+$") then
					table.insert(variants, child)
				end
			end
			if #variants > 0 then
				local clone = variants[rng:NextInteger(1, #variants)]:Clone()
				positionInstance(clone, cf)
				return clone
			end
		end
		local placeholder = createPlaceholder(baseName, cf.Position)
		positionInstance(placeholder, cf)
		return placeholder
	end

	local function zoneCenter(i: number, j: number): Vector3
		return Vector3.new(
			-halfW + (i - 0.5) * ZONE_SIZE,
			0,
			-halfD + (j - 0.5) * ZONE_SIZE
		)
	end

	local function zoneBounds(i: number, j: number): (number, number, number, number)
		local minX = -halfW + (i - 1) * ZONE_SIZE
		local maxX = -halfW + i * ZONE_SIZE
		local minZ = -halfD + (j - 1) * ZONE_SIZE
		local maxZ = -halfD + j * ZONE_SIZE
		return minX, maxX, minZ, maxZ
	end

	local function randomInZone(i: number, j: number, margin: number?): Vector3
		local m = margin or 4
		local minX, maxX, minZ, maxZ = zoneBounds(i, j)
		local x = rng:NextNumber(minX + m, maxX - m)
		local z = rng:NextNumber(minZ + m, maxZ - m)
		return Vector3.new(x, getTerrainHeight(x, z), z)
	end

	local function zoneCenterDist(i: number, j: number): number
		local c = zoneCenter(i, j)
		return math.sqrt(c.X ^ 2 + c.Z ^ 2)
	end

	local function shuffle(t: { any })
		for idx = #t, 2, -1 do
			local k = rng:NextInteger(1, idx)
			t[idx], t[k] = t[k], t[idx]
		end
	end

	local function getAdjacent(i: number, j: number): { { number } }
		local adj: { { number } } = {}
		for _, d in { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } } do
			local ni, nj = i + d[1], j + d[2]
			if ni >= 1 and ni <= ZONE_COUNT and nj >= 1 and nj <= ZONE_COUNT then
				table.insert(adj, { ni, nj })
			end
		end
		return adj
	end

	local function checkSpacing(pos: Vector3, existing: { Vector3 }, minDist: number): boolean
		for _, e in existing do
			local dx = pos.X - e.X
			local dz = pos.Z - e.Z
			if math.sqrt(dx * dx + dz * dz) < minDist then
				return false
			end
		end
		return true
	end

	--------------------------------------------------------------------
	-- PROCEDURAL TREE BUILDER
	-- Builds tree models with brown trunk + lush green canopy clusters.
	-- treeType: "large" (40-55 tall), "small" (18-28 tall),
	--           "mountain" (25-40 tall, for mountain slopes)
	--------------------------------------------------------------------

	local TRUNK_COLORS = {
		Color3.fromRGB(101, 67, 33),
		Color3.fromRGB(92, 64, 38),
		Color3.fromRGB(110, 72, 30),
		Color3.fromRGB(85, 58, 35),
	}

	local CANOPY_COLORS = {
		Color3.fromRGB(34, 120, 34),
		Color3.fromRGB(28, 105, 28),
		Color3.fromRGB(40, 130, 40),
		Color3.fromRGB(20, 100, 30),
		Color3.fromRGB(50, 140, 35),
		Color3.fromRGB(30, 110, 20),
		Color3.fromRGB(45, 125, 30),
		Color3.fromRGB(25, 95, 25),
	}

	local STONE_COLORS = {
		Color3.fromRGB(120, 115, 100),
		Color3.fromRGB(100, 95, 85),
		Color3.fromRGB(135, 128, 110),
		Color3.fromRGB(90, 88, 78),
	}

	--- Build a procedural tall grass cluster at the given position.
	local grassPrefabs: { Instance } = {}
	if prefabFolder then
		local grassFolder = prefabFolder:FindFirstChild("Grass")
		if grassFolder then
			grassPrefabs = grassFolder:GetChildren()
		end
	end
	if #grassPrefabs == 0 then
		warn("[ArenaGenerator] No grass prefabs found in ArenaPrefabs/" .. arenaData.prefabFolder .. "/Grass")
	end

	local function buildGrassCluster(position: Vector3)
		if #grassPrefabs == 0 then
			return
		end

		-- Place 2-4 small grass prefabs near the position
		for _ = 1, rng:NextInteger(2, 4) do
			local prefab = grassPrefabs[rng:NextInteger(1, #grassPrefabs)]
			local clone = prefab:Clone()
			local offsetX = rng:NextNumber(-2, 2)
			local offsetZ = rng:NextNumber(-2, 2)
			local clonePos = position + Vector3.new(offsetX, 0, offsetZ)
			local randomRotation = CFrame.Angles(0, rng:NextNumber(0, 2 * math.pi), 0)
			local randomScale = rng:NextNumber(0.03, 0.07)

			if clone:IsA("Model") then
				clone:ScaleTo(randomScale)
				-- After scaling, place base on terrain
				local _, size = clone:GetBoundingBox()
				clone:PivotTo(CFrame.new(clonePos + Vector3.new(0, size.Y / 2, 0)) * randomRotation)
			elseif clone:IsA("BasePart") then
				clone.Size = clone.Size * randomScale
				clone.CFrame = CFrame.new(clonePos + Vector3.new(0, clone.Size.Y / 2, 0)) * randomRotation
			end

			-- Enable any scripts inside (e.g. moving_grass sway script)
			for _, desc in clone:GetDescendants() do
				if desc:IsA("Script") then
					desc.Disabled = false
				end
			end

			clone.Parent = arenaFolder
		end
	end

	--- Build a procedural stone wall at the given CFrame.
	local function buildStoneWall(cf: CFrame)
		local wall = Instance.new("Part")
		wall.Name = "StoneWall"
		local h = rng:NextNumber(8, 16)
		local w = rng:NextNumber(10, 20)
		wall.Size = Vector3.new(w, h, rng:NextNumber(2, 4))
		wall.CFrame = cf * CFrame.new(0, h / 2, 0)
		wall.Color = STONE_COLORS[rng:NextInteger(1, #STONE_COLORS)]
		wall.Material = Enum.Material.Slate
		wall.Anchored = true
		wall.CanCollide = true
		wall.Parent = arenaFolder
	end

	--- Build a procedural stone pillar at the given position.
	local function buildPillar(position: Vector3)
		local h = rng:NextNumber(10, 25)
		local r = rng:NextNumber(1.5, 3)
		local pillar = Instance.new("Part")
		pillar.Name = "RuinedPillar"
		pillar.Shape = Enum.PartType.Cylinder
		pillar.Size = Vector3.new(h, r * 2, r * 2)
		pillar.CFrame = CFrame.new(position + Vector3.new(0, h / 2, 0))
			* CFrame.Angles(0, 0, math.pi / 2)
		pillar.Color = STONE_COLORS[rng:NextInteger(1, #STONE_COLORS)]
		pillar.Material = Enum.Material.Slate
		pillar.Anchored = true
		pillar.CanCollide = true
		pillar.Parent = arenaFolder
	end

	--- Build a procedural boulder at the given position.
	local function buildBoulder(position: Vector3)
		local boulder = Instance.new("Part")
		boulder.Name = "StoneBoulder"
		boulder.Shape = Enum.PartType.Block
		local sizeX = rng:NextNumber(3, 8)
		local sizeY = sizeX * rng:NextNumber(0.4, 0.7)
		local sizeZ = sizeX * rng:NextNumber(0.6, 1.1)
		boulder.Size = Vector3.new(sizeX, sizeY, sizeZ)
		boulder.CFrame = CFrame.new(position + Vector3.new(0, sizeY * 0.3, 0))
			* CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
		boulder.Color = STONE_COLORS[rng:NextInteger(1, #STONE_COLORS)]
		boulder.Material = Enum.Material.Slate
		boulder.Anchored = true
		boulder.CanCollide = true
		boulder.Parent = arenaFolder
	end

	local treePrefabs: { Instance } = {}
	if prefabFolder then
		local treesFolder = prefabFolder:FindFirstChild("Trees")
		if treesFolder then
			treePrefabs = treesFolder:GetChildren()
		end
	end
	if #treePrefabs == 0 then
		warn("[ArenaGenerator] No tree prefabs found in ArenaPrefabs/" .. arenaData.prefabFolder .. "/Trees")
	end

	local bushPrefabs: { Instance } = {}
	if prefabFolder then
		local bushesFolder = prefabFolder:FindFirstChild("Bushes")
		if bushesFolder then
			bushPrefabs = bushesFolder:GetChildren()
		end
	end
	if #bushPrefabs == 0 then
		warn("[ArenaGenerator] No bush prefabs found in ArenaPrefabs/" .. arenaData.prefabFolder .. "/Bushes")
	end

	-- Forward declaration: populated later during lake/river generation
	local waterRegions: { { x: number, z: number, radius: number } } = {}

	local function buildBush(position: Vector3)
		if #bushPrefabs == 0 then
			return
		end

		-- Skip if position is inside a water region (lake or river)
		for _, wr in waterRegions do
			local dx = position.X - wr.x
			local dz = position.Z - wr.z
			if dx * dx + dz * dz < wr.radius * wr.radius then
				return
			end
		end

		local prefab = bushPrefabs[rng:NextInteger(1, #bushPrefabs)]
		local clone = prefab:Clone()
		local randomRotation = CFrame.Angles(0, rng:NextNumber(0, 2 * math.pi), 0)
		local randomScale = rng:NextNumber(0.7, 1.3)

		if clone:IsA("Model") then
			local cf, size = clone:GetBoundingBox()
			local bottomY = cf.Position.Y - size.Y / 2
			local pivotY = clone:GetPivot().Position.Y
			local yOffset = pivotY - bottomY

			clone:PivotTo(CFrame.new(position + Vector3.new(0, yOffset, 0)) * randomRotation)

			-- Apply random scale
			if randomScale ~= 1 then
				clone:ScaleTo(randomScale)
			end
		elseif clone:IsA("BasePart") then
			local yOffset = clone.Size.Y / 2
			clone.CFrame = CFrame.new(position + Vector3.new(0, yOffset, 0)) * randomRotation
			clone.Size = clone.Size * randomScale
		end
		clone.Parent = arenaFolder
	end

	local function buildTree(position: Vector3, treeType: string): Model?
		if #treePrefabs == 0 then
			return nil
		end

		-- On flat/gentle slopes, sink to lowest nearby height to embed trunk.
		-- On mountain slopes, just use the given position to avoid burying
		-- trees underground due to large elevation differences.
		local plantPos
		if treeType == "mountain" then
			-- Mountain slopes are steep; use position directly
			plantPos = position
		else
			local slopeDist = 6
			local lowestY = position.Y
			for _, offset in {
				Vector3.new(slopeDist, 0, 0),
				Vector3.new(-slopeDist, 0, 0),
				Vector3.new(0, 0, slopeDist),
				Vector3.new(0, 0, -slopeDist),
			} do
				local hSample = getTerrainHeight(position.X + offset.X, position.Z + offset.Z)
				lowestY = math.min(lowestY, hSample)
			end
			plantPos = Vector3.new(position.X, lowestY, position.Z)
		end

		local prefab = treePrefabs[rng:NextInteger(1, #treePrefabs)]

		local clone = prefab:Clone()
		local randomRotation = CFrame.Angles(0, rng:NextNumber(0, 2 * math.pi), 0)

		-- Calculate how far below the pivot the model extends,
		-- so we can offset upward and sit the base on the terrain surface
		local yOffset = 0
		if clone:IsA("Model") then
			local _, size = clone:GetBoundingBox()
			local pivot = clone:GetPivot()
			-- Assume the pivot is near center; offset up by half the model height
			-- so the bottom rests on the ground
			local cf, _ = clone:GetBoundingBox()
			local bottomY = cf.Position.Y - size.Y / 2
			local pivotY = pivot.Position.Y
			yOffset = pivotY - bottomY
			clone:PivotTo(CFrame.new(plantPos + Vector3.new(0, yOffset, 0)) * randomRotation)
		elseif clone:IsA("BasePart") then
			yOffset = clone.Size.Y / 2
			clone.CFrame = CFrame.new(plantPos + Vector3.new(0, yOffset, 0)) * randomRotation
		end
		clone.Parent = arenaFolder
		return clone :: Model
	end

	--------------------------------------------------------------------
	-- 1. BASE TERRAIN
	--------------------------------------------------------------------
	print("[JungleRuins v5] Step 1: Filling base terrain slab...")

	terrain:FillBlock(
		CFrame.new(0, -10, 0),
		Vector3.new(halfW * 2 + 100, 20, halfD * 2 + 100),
		Enum.Material.Grass
	)

	--------------------------------------------------------------------
	-- 2. MOUNTAIN BORDERS (Perlin noise heightmap)
	--------------------------------------------------------------------
	print("[JungleRuins v5] Step 2: Generating noise-based mountain borders...")

	local mThick = 150
	local noiseSeed = rng:NextNumber(0, 10000)

	-- Mountain height for any point in the border zone
	local function getMountainHeight(x: number, z: number): number
		-- Distance into the border from the arena edge
		local distBeyondX = math.abs(x) - halfW
		local distBeyondZ = math.abs(z) - halfD
		local distBeyondEdge = math.max(distBeyondX, distBeyondZ)

		if distBeyondEdge <= 0 then
			return 0
		end

		-- Two layers of domain warping to thoroughly break up all banding.
		-- Layer 1: large-scale warp
		local warp1 = 90
		local wx = x + math.noise(x / 130 + noiseSeed + 900, z / 130 + noiseSeed + 900) * warp1
		local wz = z + math.noise(x / 130 + noiseSeed + 950, z / 130 + noiseSeed + 950) * warp1
		-- Layer 2: medium-scale warp on top of layer 1
		local warp2 = 35
		wx = wx + math.noise(wx / 50 + noiseSeed + 960, wz / 50 + noiseSeed + 960) * warp2
		wz = wz + math.noise(wx / 50 + noiseSeed + 970, wz / 50 + noiseSeed + 970) * warp2

		-- Exponential ramp: gentle at base, steepening further out
		-- This avoids the linear "wall" look
		local rampT = math.clamp(distBeyondEdge / mThick, 0, 1)
		local baseRamp = (rampT ^ 1.8) * 80

		-- Primary mountain shape: large-scale noise as the DOMINANT height driver
		-- Using warped coordinates so ridgelines aren't parallel to arena edges
		local n1 = math.noise(wx / 200 + noiseSeed + 500, wz / 200 + noiseSeed + 500)
		local peak1 = (n1 * 0.5 + 0.5) ^ 0.4 * 160 -- broad peaks, range ~0-160

		-- Ridged noise for sharp ridgelines and valleys
		local ridge = math.noise(wx / 90 + noiseSeed + 600, wz / 90 + noiseSeed + 600)
		local ridgeHeight = (1 - math.abs(ridge)) ^ 2 * 70

		-- Medium detail: foothills and spurs
		local mid = math.noise(wx / 45 + noiseSeed + 700, wz / 45 + noiseSeed + 700) * 30

		-- Fine detail: rocky surface texture (unwarped for variety)
		local fine = math.noise(x / 18 + noiseSeed + 800, z / 18 + noiseSeed + 800) * 12
		fine += math.noise(x / 8 + noiseSeed + 850, z / 8 + noiseSeed + 850) * 4

		-- Depth scaling: near the edge, features are smaller; deeper = taller
		-- Use a curve so features grow quickly at first then plateau
		local depthScale = math.clamp(distBeyondEdge / 30, 0, 1) ^ 0.7

		-- Combine everything
		local totalHeight = baseRamp + (peak1 + ridgeHeight + mid + fine) * depthScale

		-- Soft minimum: ensure impassable but blend smoothly instead of hard floor
		local minHeight = 30 + distBeyondEdge * 0.3
		if totalHeight < minHeight and distBeyondEdge > 15 then
			-- Blend toward minimum rather than snapping to it
			totalHeight = minHeight + (totalHeight - minHeight) * 0.3
		end

		return math.clamp(totalHeight, 0, 280)
	end

	-- Material selection for mountain voxels
	-- Elevation bands: Mud/Ground → Grass → Rock/Slate → Snow/Ice
	-- Noise offsets the thresholds so transitions are jagged and natural
	local function selectMountainMaterial(worldY: number, surfaceY: number, worldX: number, worldZ: number): Enum.Material
		-- Noise to jitter elevation thresholds (±15 studs) so bands aren't flat lines
		local matNoise = math.noise(worldX / 40 + noiseSeed + 1100, worldZ / 40 + noiseSeed + 1100) * 15

		local effectiveElev = surfaceY + matNoise
		local isNearSurface = worldY > surfaceY - 3

		if effectiveElev > 200 then
			-- Snow cap with occasional ice
			local iceNoise = math.noise(worldX / 20 + noiseSeed + 1200, worldZ / 20 + noiseSeed + 1200)
			if iceNoise > 0.3 then
				return Enum.Material.Glacier
			end
			return Enum.Material.Snow
		elseif effectiveElev > 130 then
			-- Rocky zone: exposed rock on surface, slate underneath
			if isNearSurface then
				return Enum.Material.Rock
			end
			return Enum.Material.Slate
		elseif effectiveElev > 60 then
			-- Grass zone: grass on surface, ground underneath
			if isNearSurface then
				return Enum.Material.Grass
			end
			return Enum.Material.Ground
		else
			-- Low slopes: dirt/mud
			if isNearSurface then
				return Enum.Material.Ground
			end
			return Enum.Material.Mud
		end
	end

	-- WriteVoxels for mountain border terrain
	local MTN_VOXEL_SIZE = 4
	local MTN_CHUNK_VOXELS = 16
	local MTN_CHUNK_SIZE = MTN_CHUNK_VOXELS * MTN_VOXEL_SIZE
	local MTN_Y_MIN = -8
	local MTN_Y_MAX = 288

	local mtnChunkCount = 0

	-- Generate border strips: iterate over the full extended region, only process border chunks
	local extentW = halfW + mThick
	local extentD = halfD + mThick

	for cx = -extentW, extentW - 1, MTN_CHUNK_SIZE do
		for cz = -extentD, extentD - 1, MTN_CHUNK_SIZE do
			-- Skip chunks entirely inside the arena (no mountain terrain)
			local chunkMaxX = cx + MTN_CHUNK_SIZE
			local chunkMaxZ = cz + MTN_CHUNK_SIZE
			if cx > -halfW and chunkMaxX < halfW and cz > -halfD and chunkMaxZ < halfD then
				continue
			end
			-- Skip chunks entirely inside the arena interior (with margin)
			local margin = 10
			if cx > -halfW + margin and chunkMaxX < halfW - margin and cz > -halfD + margin and chunkMaxZ < halfD - margin then
				continue
			end

			local regionStart = Vector3.new(cx, MTN_Y_MIN, cz)
			local regionEnd = Vector3.new(cx + MTN_CHUNK_SIZE, MTN_Y_MAX, cz + MTN_CHUNK_SIZE)
			local region = Region3.new(regionStart, regionEnd):ExpandToGrid(MTN_VOXEL_SIZE)

			local regionSize = region.Size
			local xVoxels = math.round(regionSize.X / MTN_VOXEL_SIZE)
			local yVoxels = math.round(regionSize.Y / MTN_VOXEL_SIZE)
			local zVoxels = math.round(regionSize.Z / MTN_VOXEL_SIZE)

			local materials = {}
			local occupancy = {}

			for ix = 1, xVoxels do
				materials[ix] = {}
				occupancy[ix] = {}
				local worldX = region.CFrame.Position.X - regionSize.X / 2 + (ix - 0.5) * MTN_VOXEL_SIZE

				for iy = 1, yVoxels do
					materials[ix][iy] = {}
					occupancy[ix][iy] = {}
					local worldY = region.CFrame.Position.Y - regionSize.Y / 2 + (iy - 0.5) * MTN_VOXEL_SIZE

					for iz = 1, zVoxels do
						local worldZ = region.CFrame.Position.Z - regionSize.Z / 2 + (iz - 0.5) * MTN_VOXEL_SIZE
						local surfaceY = getMountainHeight(worldX, worldZ)

						if surfaceY <= 0 then
							occupancy[ix][iy][iz] = 0
							materials[ix][iy][iz] = Enum.Material.Air
						else
							local diff = surfaceY - worldY
							if diff > MTN_VOXEL_SIZE / 2 then
								occupancy[ix][iy][iz] = 1.0
								materials[ix][iy][iz] = selectMountainMaterial(worldY, surfaceY, worldX, worldZ)
							elseif diff > -MTN_VOXEL_SIZE / 2 then
								local frac = (diff + MTN_VOXEL_SIZE / 2) / MTN_VOXEL_SIZE
								occupancy[ix][iy][iz] = math.clamp(frac, 0, 1)
								materials[ix][iy][iz] = selectMountainMaterial(worldY, surfaceY, worldX, worldZ)
							else
								occupancy[ix][iy][iz] = 0
								materials[ix][iy][iz] = Enum.Material.Air
							end
						end
					end
				end
			end

			terrain:WriteVoxels(region, MTN_VOXEL_SIZE, materials, occupancy)
			mtnChunkCount += 1
			if mtnChunkCount % 50 == 0 then
				task.wait()
			end
		end
	end
	print("[JungleRuins v5] Step 2: Wrote " .. mtnChunkCount .. " mountain chunks")

	-- Invisible border walls (safety net)
	local wallHeight = 290
	local borderWalls = {
		{ CFrame.new(0, wallHeight / 2, -halfD), Vector3.new(halfW * 2, wallHeight, 5) },
		{ CFrame.new(0, wallHeight / 2, halfD), Vector3.new(halfW * 2, wallHeight, 5) },
		{ CFrame.new(-halfW, wallHeight / 2, 0), Vector3.new(5, wallHeight, halfD * 2) },
		{ CFrame.new(halfW, wallHeight / 2, 0), Vector3.new(5, wallHeight, halfD * 2) },
	}
	for _, w in borderWalls do
		local wall = Instance.new("Part")
		wall.Name = "BorderWall"
		wall.Size = w[2]
		wall.CFrame = w[1]
		wall.Anchored = true
		wall.CanCollide = true
		wall.Transparency = 1
		wall.Parent = arenaFolder
	end

	-- Trees on mountain slopes
	-- Use getMountainHeight directly (no raycast needed — we know the exact surface)
	print("[JungleRuins v5] Step 2b: Placing trees on mountain slopes...")
	local mountainTreesPlaced = 0
	for _ = 1, 300 do
		local side = rng:NextInteger(1, 4)
		local x, z
		-- Distribute from near the edge into the mountains
		local depthRaw = rng:NextNumber(0, 1)
		local depth = depthRaw ^ 0.5 * (mThick - 10) + 3
		if side == 1 then
			x = rng:NextNumber(-halfW - 30, halfW + 30)
			z = -halfD - depth
		elseif side == 2 then
			x = rng:NextNumber(-halfW - 30, halfW + 30)
			z = halfD + depth
		elseif side == 3 then
			x = -halfW - depth
			z = rng:NextNumber(-halfD - 30, halfD + 30)
		else
			x = halfW + depth
			z = rng:NextNumber(-halfD - 30, halfD + 30)
		end

		-- Get surface height directly from the height function
		local surfaceY = getMountainHeight(x, z)

		-- Skip above tree line or at ground level
		if surfaceY > 220 then continue end
		if surfaceY < 5 then continue end

		-- Check slope by sampling nearby heights
		local nearbyY = getMountainHeight(x + 8, z)
		local nearbyZ = getMountainHeight(x, z + 8)
		local maxSlope = math.max(math.abs(nearbyY - surfaceY), math.abs(nearbyZ - surfaceY))
		if maxSlope > 25 then continue end -- skip vertical cliffs

		buildTree(Vector3.new(x, surfaceY, z), "mountain")
		mountainTreesPlaced += 1
	end
	print("[JungleRuins v5] Step 2b: Placed " .. mountainTreesPlaced .. " trees on mountain slopes")

	--------------------------------------------------------------------
	-- 3. ROLLING HILLS (Perlin noise heightmap via WriteVoxels)
	--------------------------------------------------------------------
	print("[JungleRuins v5] Step 3: Generating Perlin noise terrain...")

	-- Multi-octave Perlin noise heightmap
	local function getNoiseHeight(x: number, z: number): number
		local h = 0
		-- Octave 1: large rolling hills
		h += math.noise(x / 200 + noiseSeed, z / 200 + noiseSeed) * 50
		-- Octave 2: medium undulations
		h += math.noise(x / 80 + noiseSeed + 100, z / 80 + noiseSeed + 100) * 20
		-- Octave 3: small terrain detail
		h += math.noise(x / 30 + noiseSeed + 200, z / 30 + noiseSeed + 200) * 6
		-- Octave 4: micro bumps
		h += math.noise(x / 12 + noiseSeed + 300, z / 12 + noiseSeed + 300) * 2
		-- Ridged noise: occasional sharp ridgelines
		local ridge = math.noise(x / 120 + noiseSeed + 400, z / 120 + noiseSeed + 400)
		h += (1 - math.abs(ridge)) ^ 2 * 8

		-- Edge falloff: blend arena terrain into mountain base
		local edgeFade = 60
		local distToEdgeX = halfW - math.abs(x)
		local distToEdgeZ = halfD - math.abs(z)
		local distToEdge = math.min(distToEdgeX, distToEdgeZ)
		if distToEdge < edgeFade then
			local t = math.max(distToEdge / edgeFade, 0)
			-- Blend arena noise toward mountain base height
			local mountainBase = getMountainHeight(x, z)
			h = h * t + mountainBase * (1 - t)
		end

		return math.clamp(h, -4, 45)
	end

	-- Material selection by elevation
	local function selectMaterial(worldY: number, surfaceY: number): Enum.Material
		if surfaceY > 25 then
			if worldY > surfaceY - 3 then
				return Enum.Material.Rock
			end
			return Enum.Material.Slate
		elseif surfaceY < -1 then
			return Enum.Material.Mud
		else
			if worldY > surfaceY - 3 then
				return Enum.Material.Grass
			end
			return Enum.Material.Ground
		end
	end

	-- WriteVoxels chunk loop (terrain only — water is added in Step 4)
	local VOXEL_SIZE = 4
	local CHUNK_VOXELS = 16 -- 16 voxels per chunk axis = 64 studs
	local CHUNK_SIZE = CHUNK_VOXELS * VOXEL_SIZE
	local Y_MIN = -8
	local Y_MAX = 52

	local chunkCount = 0
	for cx = -halfW, halfW - 1, CHUNK_SIZE do
		for cz = -halfD, halfD - 1, CHUNK_SIZE do
			local regionStart = Vector3.new(cx, Y_MIN, cz)
			local regionEnd = Vector3.new(cx + CHUNK_SIZE, Y_MAX, cz + CHUNK_SIZE)
			local region = Region3.new(regionStart, regionEnd):ExpandToGrid(VOXEL_SIZE)

			local regionSize = region.Size
			local xVoxels = math.round(regionSize.X / VOXEL_SIZE)
			local yVoxels = math.round(regionSize.Y / VOXEL_SIZE)
			local zVoxels = math.round(regionSize.Z / VOXEL_SIZE)

			local materials = {}
			local occupancy = {}

			for ix = 1, xVoxels do
				materials[ix] = {}
				occupancy[ix] = {}
				local worldX = region.CFrame.Position.X - regionSize.X / 2 + (ix - 0.5) * VOXEL_SIZE

				for iy = 1, yVoxels do
					materials[ix][iy] = {}
					occupancy[ix][iy] = {}
					local worldY = region.CFrame.Position.Y - regionSize.Y / 2 + (iy - 0.5) * VOXEL_SIZE

					for iz = 1, zVoxels do
						local worldZ = region.CFrame.Position.Z - regionSize.Z / 2 + (iz - 0.5) * VOXEL_SIZE
						local surfaceY = getNoiseHeight(worldX, worldZ)

						local diff = surfaceY - worldY
						if diff > VOXEL_SIZE / 2 then
							occupancy[ix][iy][iz] = 1.0
							materials[ix][iy][iz] = selectMaterial(worldY, surfaceY)
						elseif diff > -VOXEL_SIZE / 2 then
							local frac = (diff + VOXEL_SIZE / 2) / VOXEL_SIZE
							occupancy[ix][iy][iz] = math.clamp(frac, 0, 1)
							materials[ix][iy][iz] = selectMaterial(worldY, surfaceY)
						else
							occupancy[ix][iy][iz] = 0
							materials[ix][iy][iz] = Enum.Material.Air
						end
					end
				end
			end

			terrain:WriteVoxels(region, VOXEL_SIZE, materials, occupancy)
			chunkCount += 1
			if chunkCount % 50 == 0 then
				task.wait()
			end
		end
	end
	print("[JungleRuins v5] Step 3: Wrote " .. chunkCount .. " terrain chunks")

	--------------------------------------------------------------------
	-- 4. LAKES (FillCylinder for clean, flat-topped basins)
	--------------------------------------------------------------------
	print("[JungleRuins v5] Step 4: Creating lakes...")

	local targetLakes = rng:NextInteger(2, 3)
	local lakeAttempts = 0
	while #waterRegions < targetLakes and lakeAttempts < targetLakes * 15 do
		lakeAttempts += 1
		local lx = rng:NextNumber(-halfW * 0.45, halfW * 0.45)
		local lz = rng:NextNumber(-halfD * 0.45, halfD * 0.45)
		local lr = rng:NextNumber(55, 90)
		local ld = rng:NextNumber(10, 16)

		local tooClose = false
		for _, existing in waterRegions do
			local dx = lx - existing.x
			local dz = lz - existing.z
			if math.sqrt(dx * dx + dz * dz) < lr + existing.radius + 80 then
				tooClose = true
				break
			end
		end
		if tooClose then continue end

		-- Water level: sample perimeter for the LOWEST surrounding terrain
		-- Water surface must sit below ALL perimeter points so it never floats
		local minPerimH = math.huge
		for angle = 0, 2 * math.pi - 0.01, math.pi / 16 do
			local px = lx + math.cos(angle) * lr
			local pz = lz + math.sin(angle) * lr
			minPerimH = math.min(minPerimH, getNoiseHeight(px, pz))
		end
		local waterY = minPerimH - 2

		-- Carve basin (single cylinder — clean round shape)
		terrain:FillCylinder(
			CFrame.new(lx, waterY - ld / 2 - 1, lz),
			ld + 2, lr,
			Enum.Material.Air
		)

		-- Mud floor
		terrain:FillCylinder(
			CFrame.new(lx, waterY - ld - 1.5, lz),
			3, lr + 3,
			Enum.Material.Mud
		)

		-- Fill with water
		terrain:FillCylinder(
			CFrame.new(lx, waterY - ld / 2, lz),
			ld, lr,
			Enum.Material.Water
		)

		table.insert(waterRegions, { x = lx, z = lz, radius = lr })
		print("[JungleRuins v5] Lake at (" .. math.floor(lx) .. ", " .. math.floor(lz) .. ") r=" .. math.floor(lr) .. " waterY=" .. math.floor(waterY))
	end
	print("[JungleRuins v5] Step 4: " .. #waterRegions .. " lakes placed")

	-- Let terrain voxels settle so raycasts can find the surface
	task.wait()

	--------------------------------------------------------------------
	-- 5. ZONE ASSIGNMENT
	--------------------------------------------------------------------
	print("[JungleRuins v5] Step 5: Assigning 10x10 zone grid (200 stud zones)...")

	local zoneTypes: { { string } } = {}
	for i = 1, ZONE_COUNT do
		zoneTypes[i] = {}
		for j = 1, ZONE_COUNT do
			zoneTypes[i][j] = ""
		end
	end

	local function getUnassigned(): { { number } }
		local result: { { number } } = {}
		for i = 1, ZONE_COUNT do
			for j = 1, ZONE_COUNT do
				if zoneTypes[i][j] == "" then
					table.insert(result, { i, j })
				end
			end
		end
		return result
	end

	-- elevated_ruins → forest (podiums disabled, will be reimplemented later)
	local elevatedCount = rng:NextInteger(4, 6)
	local centerZones = { { 4, 4 }, { 4, 5 }, { 5, 4 }, { 5, 5 }, { 4, 6 }, { 5, 6 }, { 6, 4 }, { 6, 5 } }
	shuffle(centerZones)
	zoneTypes[centerZones[1][1]][centerZones[1][2]] = "forest"
	zoneTypes[centerZones[2][1]][centerZones[2][2]] = "forest"
	local remainElevated = elevatedCount - 2
	if remainElevated > 0 then
		local cands = getUnassigned()
		shuffle(cands)
		local placed = 0
		for _, c in cands do
			if placed >= remainElevated then break end
			zoneTypes[c[1]][c[2]] = "forest"
			placed += 1
		end
	end

	-- temple (8-12)
	local templeCount = rng:NextInteger(8, 12)
	local templeCands = getUnassigned()
	table.sort(templeCands, function(a, b)
		return zoneCenterDist(a[1], a[2]) < zoneCenterDist(b[1], b[2])
	end)
	local topN = math.ceil(#templeCands * 0.5)
	local templePool: { { number } } = {}
	for idx = 1, topN do
		table.insert(templePool, templeCands[idx])
	end
	shuffle(templePool)
	for idx = 1, math.min(templeCount, #templePool) do
		zoneTypes[templePool[idx][1]][templePool[idx][2]] = "temple"
	end

	-- trap_corridor (6-8)
	local trapCorridorCount = rng:NextInteger(6, 8)
	local trapCands = getUnassigned()
	shuffle(trapCands)
	local trapsPlaced = 0
	for _, c in trapCands do
		if trapsPlaced >= trapCorridorCount then break end
		local hasAdjTrap = false
		for _, adj in getAdjacent(c[1], c[2]) do
			if zoneTypes[adj[1]][adj[2]] == "trap_corridor" then
				hasAdjTrap = true
				break
			end
		end
		if not hasAdjTrap then
			zoneTypes[c[1]][c[2]] = "trap_corridor"
			trapsPlaced += 1
		end
	end

	-- courtyard (6-8)
	local courtyardCount = rng:NextInteger(6, 8)
	local courtCands = getUnassigned()
	shuffle(courtCands)
	for idx = 1, math.min(courtyardCount, #courtCands) do
		zoneTypes[courtCands[idx][1]][courtCands[idx][2]] = "courtyard"
	end

	-- remaining -> forest
	for i = 1, ZONE_COUNT do
		for j = 1, ZONE_COUNT do
			if zoneTypes[i][j] == "" then
				zoneTypes[i][j] = "forest"
			end
		end
	end

	local coverPositions: { Vector3 } = {}

	--------------------------------------------------------------------
	-- TEMPLE ZONE GENERATOR
	--------------------------------------------------------------------

	local function generateTempleZone(zi: number, zj: number)
		-- Trees in temple zones (3-5)
		local treePositions: { Vector3 } = {}
		for _ = 1, rng:NextInteger(3, 5) do
			local pos: Vector3
			local att = 0
			repeat att += 1; pos = randomInZone(zi, zj, 12)
			until checkSpacing(pos, treePositions, 20) or att > 25
			table.insert(treePositions, pos)
			buildTree(pos, if rng:NextNumber() < 0.4 then "large" else "small")
		end

		-- Bush clusters: 6-10
		for _ = 1, rng:NextInteger(6, 10) do
			local pos = randomInZone(zi, zj, 4)
			buildBush(pos)
		end

		-- Tall grass clusters: 8-14
		for _ = 1, rng:NextInteger(8, 14) do
			local pos = randomInZone(zi, zj, 4)
			buildGrassCluster(pos)
		end
	end

	--------------------------------------------------------------------
	-- FOREST ZONE GENERATOR
	--------------------------------------------------------------------

	local function generateForestZone(zi: number, zj: number)
		local treePositions: { Vector3 } = {}

		-- Large trees: 3-5
		for _ = 1, rng:NextInteger(3, 5) do
			local pos: Vector3
			local attempts = 0
			repeat attempts += 1; pos = randomInZone(zi, zj, 8)
			until checkSpacing(pos, treePositions, 16) or attempts > 50
			table.insert(treePositions, pos)
			buildTree(pos, "large")
		end

		-- Small trees: 4-8
		for _ = 1, rng:NextInteger(4, 8) do
			local pos: Vector3
			local attempts = 0
			repeat attempts += 1; pos = randomInZone(zi, zj, 5)
			until checkSpacing(pos, treePositions, 10) or attempts > 35
			table.insert(treePositions, pos)
			buildTree(pos, "small")
		end

		-- Bush clusters: 8-14
		for _ = 1, rng:NextInteger(8, 14) do
			local pos = randomInZone(zi, zj, 4)
			buildBush(pos)
			table.insert(coverPositions, pos)
		end

		-- Tall grass clusters: 10-18
		for _ = 1, rng:NextInteger(10, 18) do
			local pos = randomInZone(zi, zj, 4)
			buildGrassCluster(pos)
		end

		-- Bird sounds
		local soundPart = Instance.new("Part")
		soundPart.Name = "AmbientSound_Birds"
		soundPart.Size = Vector3.new(1, 1, 1)
		soundPart.Position = zoneCenter(zi, zj) + Vector3.new(0, 8, 0)
		soundPart.Anchored = true
		soundPart.CanCollide = false
		soundPart.Transparency = 1
		CollectionService:AddTag(soundPart, "AmbientSound_Birds")
		soundPart.Parent = arenaFolder
	end

	--------------------------------------------------------------------
	-- TRAP CORRIDOR ZONE GENERATOR
	--------------------------------------------------------------------

	local function generateTrapCorridorZone(zi: number, zj: number)
		-- Trees (3-5)
		local treePositions: { Vector3 } = {}
		for _ = 1, rng:NextInteger(3, 5) do
			local pos: Vector3
			local att = 0
			repeat att += 1; pos = randomInZone(zi, zj, 6)
			until checkSpacing(pos, treePositions, 14) or att > 20
			table.insert(treePositions, pos)
			buildTree(pos, if rng:NextNumber() < 0.5 then "large" else "small")
		end

		-- Bush clusters: 6-10
		for _ = 1, rng:NextInteger(6, 10) do
			local pos = randomInZone(zi, zj, 4)
			buildBush(pos)
		end

		-- Tall grass clusters: 8-14
		for _ = 1, rng:NextInteger(8, 14) do
			local pos = randomInZone(zi, zj, 4)
			buildGrassCluster(pos)
		end
	end

	--------------------------------------------------------------------
	-- COURTYARD ZONE GENERATOR
	--------------------------------------------------------------------

	local function generateCourtyardZone(zi: number, zj: number)
		-- Dense ring of trees (4-6)
		local treePositions: { Vector3 } = {}
		for _ = 1, rng:NextInteger(4, 6) do
			local angle = rng:NextNumber(0, 2 * math.pi)
			local radius = ZONE_SIZE * rng:NextNumber(0.32, 0.48)
			local c = zoneCenter(zi, zj)
			local px = c.X + math.cos(angle) * radius
			local pz = c.Z + math.sin(angle) * radius
			local pos = Vector3.new(px, getTerrainHeight(px, pz), pz)
			if checkSpacing(pos, treePositions, 14) then
				table.insert(treePositions, pos)
				buildTree(pos, "large")
			end
		end

		-- Bush clusters: 6-10
		for _ = 1, rng:NextInteger(6, 10) do
			local pos = randomInZone(zi, zj, 4)
			buildBush(pos)
		end

		-- Tall grass clusters: 8-14
		for _ = 1, rng:NextInteger(8, 14) do
			local pos = randomInZone(zi, zj, 4)
			buildGrassCluster(pos)
		end
	end

	--------------------------------------------------------------------
	-- ELEVATED RUINS ZONE GENERATOR
	--------------------------------------------------------------------

	local function generateElevatedRuinsZone(zi: number, zj: number)
		-- Elevated ruins zone now just generates as forest (no elevated terrain)
		generateForestZone(zi, zj)
	end

	--------------------------------------------------------------------
	-- GENERATE ALL ZONES
	--------------------------------------------------------------------

	for zi = 1, ZONE_COUNT do
		for zj = 1, ZONE_COUNT do
			local zt = zoneTypes[zi][zj]
			if zt == "temple" then
				generateTempleZone(zi, zj)
			elseif zt == "forest" then
				generateForestZone(zi, zj)
			elseif zt == "trap_corridor" then
				generateTrapCorridorZone(zi, zj)
			elseif zt == "courtyard" then
				generateCourtyardZone(zi, zj)
			elseif zt == "elevated_ruins" then
				generateElevatedRuinsZone(zi, zj)
			end
		end
	end


	--------------------------------------------------------------------
	-- SPAWN POINTS
	--------------------------------------------------------------------

	local spawnPositions: { Vector3 } = {}
	local minSpawnDist = arenaData.minSpawnDistance
	local spawnCount = arenaData.spawnCount

	local spawnableZones: { { number } } = {}
	local elevatedSpawnZones: { { number } } = {}
	for zi = 1, ZONE_COUNT do
		for zj = 1, ZONE_COUNT do
			local zt = zoneTypes[zi][zj]
			if zt == "courtyard" or zt == "temple" or zt == "forest" then
				table.insert(spawnableZones, { zi, zj })
			elseif zt == "elevated_ruins" then
				table.insert(elevatedSpawnZones, { zi, zj })
			end
		end
	end

	if #elevatedSpawnZones > 0 then
		for spIdx = 1, math.min(2, #elevatedSpawnZones) do
			local ez2 = elevatedSpawnZones[spIdx]
			local pos = zoneCenter(ez2[1], ez2[2])
				+ Vector3.new(rng:NextNumber(-20, 20), ELEVATED_Y + 2, rng:NextNumber(-20, 20))
			table.insert(spawnPositions, pos)
		end
		for _, ez2 in elevatedSpawnZones do
			table.insert(spawnableZones, ez2)
		end
	end

	-- Wait for terrain to settle so raycasts reflect final terrain state
	task.wait()

	local maxAttempts = spawnCount * 80
	local attempts = 0
	while #spawnPositions < spawnCount and attempts < maxAttempts do
		attempts += 1
		local zone = spawnableZones[rng:NextInteger(1, #spawnableZones)]
		local zt = zoneTypes[zone[1]][zone[2]]

		local minX2, maxX2, minZ2, maxZ2 = zoneBounds(zone[1], zone[2])
		local sx = rng:NextNumber(minX2 + 15, maxX2 - 15)
		local sz = rng:NextNumber(minZ2 + 15, maxZ2 - 15)
		-- Raycast now to get the final terrain surface (after all carving/banking)
		local sy = getTerrainHeight(sx, sz)
		if zt == "elevated_ruins" then sy = ELEVATED_Y + 2 end

		-- Skip spawns that landed in water regions
		local inWater = false
		for _, wr in waterRegions do
			local dx = sx - wr.x
			local dz = sz - wr.z
			if dx * dx + dz * dz < wr.radius * wr.radius then
				inWater = true
				break
			end
		end
		if inWater then continue end

		local candidate = Vector3.new(sx, sy + 1, sz)
		if checkSpacing(candidate, spawnPositions, minSpawnDist) then
			table.insert(spawnPositions, candidate)
		end
	end

	placeSpawnPoints(spawnPositions, arenaFolder)

	AmbientWildlife.start(arenaFolder, zoneTypes, zoneBounds, getTerrainHeight, rng)

	-- Spatial water sounds at each lake center
	-- NOTE: Replace WATER_SOUND_ID and FOREST_SOUND_ID at the top of this file
	-- with asset IDs you upload via Roblox Studio Asset Manager
	for _, wr in waterRegions do
		if WATER_SOUND_ID ~= "" then
			local soundPart = Instance.new("Part")
			soundPart.Name = "WaterSoundEmitter"
			soundPart.Size = Vector3.new(1, 1, 1)
			soundPart.Anchored = true
			soundPart.CanCollide = false
			soundPart.CanTouch = false
			soundPart.CanQuery = false
			soundPart.Transparency = 1
			soundPart.Position = Vector3.new(wr.x, getTerrainHeight(wr.x, wr.z), wr.z)

			local sound = Instance.new("Sound")
			sound.Name = "WaterAmbient"
			sound.SoundId = WATER_SOUND_ID
			sound.Volume = 0.5
			sound.Looped = true
			sound.RollOffMode = Enum.RollOffMode.InverseTapered
			sound.RollOffMinDistance = 30
			sound.RollOffMaxDistance = 150
			sound.Parent = soundPart
			sound:Play()

			soundPart.Parent = arenaFolder
		end
	end
	print("[JungleRuins v5] Placed " .. #waterRegions .. " lake sound emitters")

	print("[JungleRuins v5] === JUNGLE RUINS GENERATION COMPLETE ===")
end

------------------------------------------------------------------------
-- Layout Dispatch
------------------------------------------------------------------------

local layoutGenerators: { [string]: (Folder, ArenaData, Folder?) -> () } = {
	Colosseum = generateColosseum,
	LavaForge = generateLavaForge,
	ShadowMaze = generateShadowMaze,
	JungleRuins = generateJungleRuins,
}

------------------------------------------------------------------------
-- Arena Cleanup
------------------------------------------------------------------------

--- Remove the current arena from Workspace and reset lighting.
function ArenaGenerator.clearArena()
	AmbientWildlife.stop()

	local existing = Workspace:FindFirstChild(ARENA_FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
	-- Clear procedural terrain (hills, mountains, ponds)
	Workspace.Terrain:Clear()

	-- Disconnect Jungle Ruins sun animation if active
	if jungleSunConnection then
		jungleSunConnection:Disconnect()
		jungleSunConnection = nil
	end

	-- Remove Jungle Ruins global ambient sound
	local forestSound = Workspace:FindFirstChild("JungleRuins_ForestAmbient")
	if forestSound then
		forestSound:Destroy()
	end

	-- Remove all Jungle Ruins lighting objects (Atmosphere, SunRays, Bloom, ColorCorrection)
	for _, child in Lighting:GetChildren() do
		if child.Name:sub(1, 12) == "JungleRuins_" then
			child:Destroy()
		end
	end

	-- Reset extended lighting properties to defaults
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = 0.2
	Lighting.EnvironmentDiffuseScale = 0
	Lighting.EnvironmentSpecularScale = 0
	Lighting.GeographicLatitude = 41.733

	resetLighting()
end

------------------------------------------------------------------------
-- Main Generation
------------------------------------------------------------------------

--- Generate an arena of the given type.
--- @param arenaType string — key from ArenaConfig.Arenas (e.g. "Colosseum")
--- @param seed number? — optional seed; auto-generated if omitted
--- @return GenerationResult
function ArenaGenerator.generate(arenaType: string, seed: number?): GenerationResult
	-- Resolve arena data
	local arenaData = ArenaConfig.GetArena(arenaType)
	assert(arenaData, "[ArenaGenerator] Unknown arena type: " .. tostring(arenaType))

	-- Clean up any previous arena
	ArenaGenerator.clearArena()

	-- Seed the RNG
	local actualSeed = seed or generateSeed()
	setSeed(actualSeed)
	print("[ArenaGenerator] Generating " .. arenaData.displayName .. " (seed=" .. actualSeed .. ")")

	-- Create arena container folder
	local arenaFolder = Instance.new("Folder")
	arenaFolder.Name = ARENA_FOLDER_NAME

	-- Load prefab folder (may be nil → placeholders will be used)
	local prefabFolder = getPrefabFolder(arenaData.prefabFolder)
	if not prefabFolder then
		warn("[ArenaGenerator] No prefab folder found at ServerStorage/ArenaPrefabs/" .. arenaData.prefabFolder .. " — using placeholders")
	end

	-- Generate layout
	local generator = layoutGenerators[arenaType]
	if generator then
		generator(arenaFolder, arenaData, prefabFolder)
	else
		warn("[ArenaGenerator] No layout generator for arena type: " .. arenaType .. " — placing floor only")
		-- Fallback: just a flat floor within bounds
		local gridSize = arenaData.gridSize
		local extent = 50
		for gx = -extent / gridSize, extent / gridSize do
			for gz = -extent / gridSize, extent / gridSize do
				local worldPos = gridToWorld(gx, gz, gridSize)
				if isWithinBounds(worldPos, arenaData.bounds) then
					local floor = createPlaceholder("Floor", worldPos)
					floor.Parent = arenaFolder
				end
			end
		end
	end

	-- Generate and place spawn points (skip if the layout generator already placed them)
	local spawnParts: { BasePart } = {}
	local existingSpawn = arenaFolder:FindFirstChildWhichIsA("SpawnLocation", true)
	if existingSpawn then
		-- Layout generator already placed spawns — collect them
		for _, child in arenaFolder:GetDescendants() do
			if child:IsA("SpawnLocation") then
				table.insert(spawnParts, child)
			end
		end
	else
		-- Generic spawn placement via rejection sampling
		local spawnPositions = generateSpawnPositions(
			arenaData.spawnCount,
			arenaData.bounds,
			arenaData.minSpawnDistance,
			arenaData.gridSize
		)
		spawnParts = placeSpawnPoints(spawnPositions, arenaFolder)
	end

	-- Apply lighting
	applyLighting(arenaData.lightingConfig)

	-- Jungle Ruins: add atmospheric effects (atmosphere, post-processing, fog)
	if arenaType == "JungleRuins" then
		-- Keep the moody twilight ClockTime from lightingConfig (6.5)
		Lighting.GlobalShadows = true
		Lighting.ShadowSoftness = 0.15
		Lighting.EnvironmentDiffuseScale = 0.5
		Lighting.EnvironmentSpecularScale = 0.3
		Lighting.GeographicLatitude = 20

		-- Atmosphere — mysterious fog and aerial perspective
		local atmoConfig = arenaData.atmosphereConfig
		local atmosphere = Instance.new("Atmosphere")
		atmosphere.Name = "JungleRuins_Atmosphere"
		if atmoConfig then
			atmosphere.Density = atmoConfig.Density
			atmosphere.Offset = atmoConfig.Offset
			atmosphere.Color = atmoConfig.Color
			atmosphere.Decay = atmoConfig.Decay
			atmosphere.Glare = atmoConfig.Glare
			atmosphere.Haze = atmoConfig.Haze
		else
			atmosphere.Density = 0.3
			atmosphere.Offset = 0.25
			atmosphere.Color = Color3.fromRGB(160, 190, 140)
			atmosphere.Decay = Color3.fromRGB(120, 140, 100)
			atmosphere.Glare = 0.4
			atmosphere.Haze = 1.5
		end
		atmosphere.Parent = Lighting

		-- SunRays — god rays breaking through tree canopy
		local sunRays = Instance.new("SunRaysEffect")
		sunRays.Name = "JungleRuins_SunRays"
		sunRays.Intensity = 0.08
		sunRays.Spread = 0.6
		sunRays.Parent = Lighting

		-- Bloom — soft warm glow on highlights
		local bloom = Instance.new("BloomEffect")
		bloom.Name = "JungleRuins_Bloom"
		bloom.Intensity = 0.3
		bloom.Size = 30
		bloom.Threshold = 1.5
		bloom.Parent = Lighting

		-- ColorCorrection — warm jungle tint
		local colorCorrection = Instance.new("ColorCorrectionEffect")
		colorCorrection.Name = "JungleRuins_ColorCorrection"
		colorCorrection.Brightness = 0.02
		colorCorrection.Contrast = 0.08
		colorCorrection.Saturation = 0.15
		colorCorrection.TintColor = Color3.fromRGB(255, 248, 235)
		colorCorrection.Parent = Lighting

		-- Animate ClockTime: slow drift within twilight range (6.5 → 7.5)
		-- Keeps the moody atmosphere while adding subtle sky movement
		jungleSunConnection = RunService.Heartbeat:Connect(function(dt: number)
			local current = Lighting.ClockTime
			if current < 7.5 then
				Lighting.ClockTime = math.min(current + dt * 0.003, 7.5)
			end
		end)

		-- Ground fog emitter patches scattered across the arena floor
		local fogConfig = arenaData.groundFogConfig
		if fogConfig then
			local boundsW = arenaData.bounds.width or arenaData.bounds.diameter or 200
			local boundsD = arenaData.bounds.depth or arenaData.bounds.diameter or 200
			local halfW = boundsW / 2
			local halfD = boundsD / 2
			-- Keep fog within 80% of the arena to avoid edges
			local spreadW = halfW * 0.8
			local spreadD = halfD * 0.8

			local fogFolder = Instance.new("Folder")
			fogFolder.Name = "JungleRuins_GroundFog"

			for i = 1, fogConfig.emitterCount do
				local fogPart = Instance.new("Part")
				fogPart.Name = "FogEmitter_" .. i
				fogPart.Size = fogConfig.patchSize
				fogPart.Anchored = true
				fogPart.CanCollide = false
				fogPart.CanTouch = false
				fogPart.CanQuery = false
				fogPart.Transparency = 1
				-- Position at actual terrain height using raycast
				local fx = math.random() * spreadW * 2 - spreadW
				local fz = math.random() * spreadD * 2 - spreadD
				local fogRay = Workspace:Raycast(Vector3.new(fx, 500, fz), Vector3.new(0, -1000, 0))
				local fy = if fogRay then fogRay.Position.Y + 2 else 2
				fogPart.Position = Vector3.new(fx, fy, fz)

				local emitter = Instance.new("ParticleEmitter")
				emitter.Name = "FogParticles"
				emitter.Texture = fogConfig.particleTexture
				emitter.Color = ColorSequence.new(fogConfig.particleColor)
				emitter.Size = fogConfig.particleSize
				emitter.Transparency = fogConfig.particleTransparency
				emitter.Lifetime = fogConfig.particleLifetime
				emitter.Rate = fogConfig.particleRate
				emitter.Speed = fogConfig.particleSpeed
				emitter.SpreadAngle = fogConfig.particleSpread
				emitter.RotSpeed = NumberRange.new(-15, 15)
				emitter.Rotation = NumberRange.new(0, 360)
				emitter.EmissionDirection = Enum.NormalId.Top
				emitter.LightEmission = 0.35
				emitter.LightInfluence = 0.6
				emitter.Drag = 0.5
				emitter.VelocityInheritance = 0
				emitter.LockedToPart = false
				emitter.Parent = fogPart

				fogPart.Parent = fogFolder
			end

			fogFolder.Parent = arenaFolder
			print("[ArenaGenerator] Placed " .. fogConfig.emitterCount .. " ground fog emitters for Jungle Ruins")
		end

		-- Global forest ambient sound (birds, insects, wind)
		if FOREST_SOUND_ID ~= "" then
			local forestAmbient = Instance.new("Sound")
			forestAmbient.Name = "JungleRuins_ForestAmbient"
			forestAmbient.SoundId = FOREST_SOUND_ID
			forestAmbient.Volume = 0.3
			forestAmbient.Looped = true
			forestAmbient.PlayOnRemove = false
			forestAmbient.Parent = Workspace
			forestAmbient:Play()
			print("[ArenaGenerator] Started global forest ambient sound for Jungle Ruins")
		end
	end

	-- Parent the arena folder last (Roblox best practice)
	arenaFolder.Parent = Workspace

	print("[ArenaGenerator] Arena ready: " .. arenaData.displayName .. " (" .. #spawnParts .. " spawns)")

	return {
		seed = actualSeed,
		arenaName = arenaData.name,
		arenaFolder = arenaFolder,
		spawnPoints = spawnParts,
	}
end

return ArenaGenerator
