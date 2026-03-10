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
local Workspace = game:GetService("Workspace")

local ArenaConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("ArenaConfig"))

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

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

local PLACEHOLDER_COLOR = Color3.fromRGB(255, 105, 180) -- hot pink
local PLACEHOLDER_MATERIAL = Enum.Material.SmoothPlastic
local ARENA_FOLDER_NAME = "Arena"

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
	TreeLarge        = Vector3.new(8, 20, 8),
	TreeSmall        = Vector3.new(4, 12, 4),
	BushCluster      = Vector3.new(5, 3, 5),
	TallGrass        = Vector3.new(6, 2, 6),
	ClimbableVine    = Vector3.new(2, 12, 1),
	PressurePlate    = Vector3.new(4, 0.5, 4),
	DartTrap         = Vector3.new(2, 2, 2),
	SwingLog         = Vector3.new(2, 2, 10),
	PitTrap          = Vector3.new(8, 1, 8),
	RopeBridge       = Vector3.new(24, 1, 4),
	TempleBase       = Vector3.new(36, 15, 36),
	Firefly          = Vector3.new(1, 1, 1),
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
	print("[JungleRuins v4] === GENERATING JUNGLE RUINS (LATEST VERSION) ===")
	print("[JungleRuins v4] General Sherman trees, solid lakes, no waterfalls, 2x tree density")
	local halfW = (arenaData.bounds.width or 2000) / 2
	local halfD = (arenaData.bounds.depth or 2000) / 2
	local terrain = Workspace.Terrain
	print("[JungleRuins v4] halfW=" .. halfW .. " halfD=" .. halfD)

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
	local function buildGrassCluster(position: Vector3)
		for _ = 1, rng:NextInteger(3, 6) do
			local blade = Instance.new("Part")
			blade.Name = "TallGrass"
			blade.Size = Vector3.new(
				rng:NextNumber(0.3, 0.8),
				rng:NextNumber(3, 7),
				rng:NextNumber(0.3, 0.8)
			)
			local offsetX = rng:NextNumber(-2, 2)
			local offsetZ = rng:NextNumber(-2, 2)
			blade.Position = position + Vector3.new(offsetX, blade.Size.Y / 2, offsetZ)
			blade.Color = CANOPY_COLORS[rng:NextInteger(1, #CANOPY_COLORS)]
			blade.Material = Enum.Material.Grass
			blade.Anchored = true
			blade.CanCollide = false
			blade.CastShadow = false
			blade.Parent = arenaFolder
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
		boulder.Shape = Enum.PartType.Ball
		local size = rng:NextNumber(3, 8)
		boulder.Size = Vector3.new(size, size * 0.7, size)
		boulder.Position = position + Vector3.new(0, size * 0.3, 0)
		boulder.Color = STONE_COLORS[rng:NextInteger(1, #STONE_COLORS)]
		boulder.Material = Enum.Material.Slate
		boulder.Anchored = true
		boulder.CanCollide = true
		boulder.Parent = arenaFolder
	end

	local function buildTree(position: Vector3, treeType: string): Model
		local model = Instance.new("Model")
		model.Name = "JungleTree"

		local height, trunkRadius, canopyRadius, canopyCount
		if treeType == "large" then
			height = rng:NextNumber(75, 125)
			trunkRadius = rng:NextNumber(4, 7)
			canopyRadius = rng:NextNumber(20, 30)
			canopyCount = rng:NextInteger(8, 14)
		elseif treeType == "small" then
			height = rng:NextNumber(30, 55)
			trunkRadius = rng:NextNumber(2, 3.5)
			canopyRadius = rng:NextNumber(10, 18)
			canopyCount = rng:NextInteger(5, 8)
		else -- "mountain"
			height = rng:NextNumber(40, 75)
			trunkRadius = rng:NextNumber(2.5, 5)
			canopyRadius = rng:NextNumber(12, 22)
			canopyCount = rng:NextInteger(6, 10)
		end

		local trunkColor = TRUNK_COLORS[rng:NextInteger(1, #TRUNK_COLORS)]

		-- Trunk (cylinder standing vertical)
		local trunkHeight = height * 0.65
		local trunk = Instance.new("Part")
		trunk.Name = "Trunk"
		trunk.Shape = Enum.PartType.Cylinder
		trunk.Size = Vector3.new(trunkHeight, trunkRadius * 2, trunkRadius * 2)
		trunk.CFrame = CFrame.new(position + Vector3.new(0, trunkHeight / 2, 0))
			* CFrame.Angles(0, 0, math.pi / 2)
		trunk.Color = trunkColor
		trunk.Material = Enum.Material.Wood
		trunk.Anchored = true
		trunk.CanCollide = true
		trunk.Parent = model

		-- Main canopy sphere
		local canopyY = position.Y + height * 0.6
		local canopyCenter = Vector3.new(position.X, canopyY, position.Z)

		local mainCanopy = Instance.new("Part")
		mainCanopy.Name = "Canopy"
		mainCanopy.Shape = Enum.PartType.Ball
		mainCanopy.Size = Vector3.new(canopyRadius * 2, canopyRadius * 1.6, canopyRadius * 2)
		mainCanopy.Position = canopyCenter
		mainCanopy.Color = CANOPY_COLORS[rng:NextInteger(1, #CANOPY_COLORS)]
		mainCanopy.Material = Enum.Material.Grass
		mainCanopy.Anchored = true
		mainCanopy.CanCollide = false
		mainCanopy.CastShadow = true
		mainCanopy.Parent = model

		-- Additional canopy clusters for lush look
		for _ = 1, canopyCount do
			local offsetX = rng:NextNumber(-canopyRadius * 0.7, canopyRadius * 0.7)
			local offsetY = rng:NextNumber(-canopyRadius * 0.4, canopyRadius * 0.5)
			local offsetZ = rng:NextNumber(-canopyRadius * 0.7, canopyRadius * 0.7)
			local subRadius = canopyRadius * rng:NextNumber(0.4, 0.75)

			local sub = Instance.new("Part")
			sub.Name = "Canopy"
			sub.Shape = Enum.PartType.Ball
			sub.Size = Vector3.new(subRadius * 2, subRadius * 1.5, subRadius * 2)
			sub.Position = canopyCenter + Vector3.new(offsetX, offsetY, offsetZ)
			sub.Color = CANOPY_COLORS[rng:NextInteger(1, #CANOPY_COLORS)]
			sub.Material = Enum.Material.Grass
			sub.Anchored = true
			sub.CanCollide = false
			sub.CastShadow = true
			sub.Parent = model
		end

		-- Branch stubs connecting trunk to canopy
		local branchCount = rng:NextInteger(2, 4)
		for _ = 1, branchCount do
			local branchAngle = rng:NextNumber(0, 2 * math.pi)
			local branchY = position.Y + trunkHeight * rng:NextNumber(0.6, 0.95)
			local branchLen = canopyRadius * rng:NextNumber(0.5, 0.9)
			local branchRadius = trunkRadius * rng:NextNumber(0.3, 0.6)
			local branchDir = Vector3.new(math.cos(branchAngle), 0.3, math.sin(branchAngle)).Unit

			local branch = Instance.new("Part")
			branch.Name = "Branch"
			branch.Shape = Enum.PartType.Cylinder
			branch.Size = Vector3.new(branchLen, branchRadius * 2, branchRadius * 2)
			local branchStart = Vector3.new(position.X, branchY, position.Z)
			local branchMid = branchStart + branchDir * (branchLen / 2)
			local lookCF = CFrame.lookAt(branchStart, branchStart + branchDir)
			branch.CFrame = CFrame.new(branchMid) * lookCF.Rotation * CFrame.Angles(0, 0, math.pi / 2)
			branch.Color = trunkColor
			branch.Material = Enum.Material.Wood
			branch.Anchored = true
			branch.CanCollide = false
			branch.Parent = model
		end

		model.Parent = arenaFolder
		return model
	end

	--------------------------------------------------------------------
	-- 1. BASE TERRAIN
	--------------------------------------------------------------------
	print("[JungleRuins v4] Step 1: Filling base terrain slab...")

	terrain:FillBlock(
		CFrame.new(0, -10, 0),
		Vector3.new(halfW * 2 + 100, 20, halfD * 2 + 100),
		Enum.Material.Grass
	)

	--------------------------------------------------------------------
	-- 2. MOUNTAIN BORDERS
	--------------------------------------------------------------------
	print("[JungleRuins v4] Step 2: Building mountain borders (200 studs tall)...")

	local mHeight = 200
	local mThick = 150

	terrain:FillBlock(
		CFrame.new(0, mHeight / 2, -halfD - mThick / 2),
		Vector3.new(halfW * 2 + mThick * 2, mHeight, mThick),
		Enum.Material.Grass
	)
	terrain:FillBlock(
		CFrame.new(0, mHeight / 2, halfD + mThick / 2),
		Vector3.new(halfW * 2 + mThick * 2, mHeight, mThick),
		Enum.Material.Grass
	)
	terrain:FillBlock(
		CFrame.new(-halfW - mThick / 2, mHeight / 2, 0),
		Vector3.new(mThick, mHeight, halfD * 2 + mThick * 2),
		Enum.Material.Grass
	)
	terrain:FillBlock(
		CFrame.new(halfW + mThick / 2, mHeight / 2, 0),
		Vector3.new(mThick, mHeight, halfD * 2 + mThick * 2),
		Enum.Material.Grass
	)

	-- Irregular mountain peaks
	for _ = 1, 80 do
		local side = rng:NextInteger(1, 4)
		local x, z
		if side == 1 then
			x = rng:NextNumber(-halfW - 50, halfW + 50)
			z = -halfD - rng:NextNumber(10, mThick - 10)
		elseif side == 2 then
			x = rng:NextNumber(-halfW - 50, halfW + 50)
			z = halfD + rng:NextNumber(10, mThick - 10)
		elseif side == 3 then
			x = -halfW - rng:NextNumber(10, mThick - 10)
			z = rng:NextNumber(-halfD - 50, halfD + 50)
		else
			x = halfW + rng:NextNumber(10, mThick - 10)
			z = rng:NextNumber(-halfD - 50, halfD + 50)
		end
		local radius = rng:NextNumber(30, 80)
		local y = mHeight + rng:NextNumber(-20, 60)
		terrain:FillBall(Vector3.new(x, y, z), radius, Enum.Material.Grass)
	end

	-- Invisible border walls
	local borderWalls = {
		{ CFrame.new(0, mHeight / 2, -halfD), Vector3.new(halfW * 2, mHeight, 5) },
		{ CFrame.new(0, mHeight / 2, halfD), Vector3.new(halfW * 2, mHeight, 5) },
		{ CFrame.new(-halfW, mHeight / 2, 0), Vector3.new(5, mHeight, halfD * 2) },
		{ CFrame.new(halfW, mHeight / 2, 0), Vector3.new(5, mHeight, halfD * 2) },
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

	-- Trees on mountain slopes (visible from inside)
	print("[JungleRuins v4] Step 2b: Placing 80 trees on mountain slopes...")
	for _ = 1, 80 do
		local side = rng:NextInteger(1, 4)
		local x, z
		if side == 1 then
			x = rng:NextNumber(-halfW + 20, halfW - 20)
			z = -halfD - rng:NextNumber(5, 60)
		elseif side == 2 then
			x = rng:NextNumber(-halfW + 20, halfW - 20)
			z = halfD + rng:NextNumber(5, 60)
		elseif side == 3 then
			x = -halfW - rng:NextNumber(5, 60)
			z = rng:NextNumber(-halfD + 20, halfD - 20)
		else
			x = halfW + rng:NextNumber(5, 60)
			z = rng:NextNumber(-halfD + 20, halfD - 20)
		end
		local distFromEdge
		if side <= 2 then
			distFromEdge = math.abs(z) - halfD
		else
			distFromEdge = math.abs(x) - halfW
		end
		local slopeY = (distFromEdge / mThick) * mHeight * 0.6
		buildTree(Vector3.new(x, math.max(slopeY, 0), z), "mountain")
	end

	--------------------------------------------------------------------
	-- 3. ROLLING HILLS (dense, varied sizes)
	--------------------------------------------------------------------
	print("[JungleRuins v4] Step 3: Generating 340 rolling hills (60 large + 80 medium + 200 small)...")

	local hillPositions: { Vector3 } = {}

	-- Large hills
	for _ = 1, 60 do
		local x = rng:NextNumber(-halfW * 0.85, halfW * 0.85)
		local z = rng:NextNumber(-halfD * 0.85, halfD * 0.85)
		local radius = rng:NextNumber(40, 100)
		local peakY = rng:NextNumber(12, 45)
		terrain:FillBall(Vector3.new(x, peakY - radius * 0.5, z), radius, Enum.Material.Grass)
		table.insert(hillPositions, Vector3.new(x, peakY, z))
	end

	-- Medium hills
	for _ = 1, 80 do
		local x = rng:NextNumber(-halfW * 0.9, halfW * 0.9)
		local z = rng:NextNumber(-halfD * 0.9, halfD * 0.9)
		local radius = rng:NextNumber(15, 40)
		local peakY = rng:NextNumber(4, 18)
		terrain:FillBall(Vector3.new(x, peakY - radius * 0.55, z), radius, Enum.Material.Grass)
	end

	-- Small bumps for ground texture
	for _ = 1, 200 do
		local x = rng:NextNumber(-halfW * 0.95, halfW * 0.95)
		local z = rng:NextNumber(-halfD * 0.95, halfD * 0.95)
		local radius = rng:NextNumber(5, 15)
		terrain:FillBall(Vector3.new(x, -radius * 0.7, z), radius, Enum.Material.Grass)
	end

	--------------------------------------------------------------------
	-- 4. LAKES (visible water pools)
	--------------------------------------------------------------------
	print("[JungleRuins v4] Step 4: Creating lakes (carve + fill)...")

	local pondPositions: { Vector3 } = {}
	local pondCount = rng:NextInteger(35, 50)
	for _ = 1, pondCount do
		local x = rng:NextNumber(-halfW * 0.75, halfW * 0.75)
		local z = rng:NextNumber(-halfD * 0.75, halfD * 0.75)
		local pondRadius = rng:NextNumber(20, 70)
		local pondDepth = rng:NextNumber(4, 8)

		-- 1. Carve out the grass/terrain with Air to make a visible depression
		terrain:FillBlock(
			CFrame.new(x, 0, z),
			Vector3.new(pondRadius * 2, pondDepth * 2 + 4, pondRadius * 2),
			Enum.Material.Air
		)
		-- 2. Solid mud floor at the bottom so players can't fall through
		terrain:FillBlock(
			CFrame.new(x, -pondDepth - 1, z),
			Vector3.new(pondRadius * 2 + 4, 3, pondRadius * 2 + 4),
			Enum.Material.Mud
		)
		-- 3. Fill with water from mud floor up to just below ground level
		terrain:FillBlock(
			CFrame.new(x, -pondDepth / 2, z),
			Vector3.new(pondRadius * 2, pondDepth, pondRadius * 2),
			Enum.Material.Water
		)

		table.insert(pondPositions, Vector3.new(x, 0, z))
	end

	-- Let terrain voxels settle so raycasts can find the surface
	task.wait()

	--------------------------------------------------------------------
	-- 5. ZONE ASSIGNMENT
	--------------------------------------------------------------------
	print("[JungleRuins v4] Step 5: Assigning 10x10 zone grid (200 stud zones)...")

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

	-- elevated_ruins (4-6)
	local elevatedCount = rng:NextInteger(4, 6)
	local centerZones = { { 4, 4 }, { 4, 5 }, { 5, 4 }, { 5, 5 }, { 4, 6 }, { 5, 6 }, { 6, 4 }, { 6, 5 } }
	shuffle(centerZones)
	zoneTypes[centerZones[1][1]][centerZones[1][2]] = "elevated_ruins"
	zoneTypes[centerZones[2][1]][centerZones[2][2]] = "elevated_ruins"
	local remainElevated = elevatedCount - 2
	if remainElevated > 0 then
		local cands = getUnassigned()
		shuffle(cands)
		local placed = 0
		for _, c in cands do
			if placed >= remainElevated then break end
			zoneTypes[c[1]][c[2]] = "elevated_ruins"
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
		local center = zoneCenter(zi, zj)

		local structCount = rng:NextInteger(4, 6)
		local structPositions: { Vector3 } = {}
		for _ = 1, structCount do
			local pos: Vector3
			local attempts = 0
			repeat
				attempts += 1
				pos = randomInZone(zi, zj, 20)
			until checkSpacing(pos, structPositions, 30) or attempts > 30
			table.insert(structPositions, pos)
			table.insert(coverPositions, pos)
			local baseAngle = rng:NextNumber(0, 2 * math.pi)
			local baseCF = CFrame.new(pos) * CFrame.Angles(0, baseAngle, 0)
			if rng:NextInteger(1, 2) == 1 then
				buildStoneWall(baseCF)
				local w2CF = baseCF * CFrame.new(8, 0, 8) * CFrame.Angles(0, math.pi / 2, 0)
				buildStoneWall(w2CF)
			else
				buildStoneWall(baseCF)
				local w2CF = baseCF * CFrame.new(0, 0, 14)
				buildStoneWall(w2CF)
				local w3CF = baseCF * CFrame.new(8, 0, 7) * CFrame.Angles(0, math.pi / 2, 0)
				buildStoneWall(w3CF)
			end
		end

		local pillarCount = rng:NextInteger(4, 8)
		for _ = 1, pillarCount do
			local pos = randomInZone(zi, zj, 10)
			buildPillar(pos)
			table.insert(coverPositions, pos)
		end

		for _, adj in getAdjacent(zi, zj) do
			if zoneTypes[adj[1]][adj[2]] == "elevated_ruins" then
				local adjCenter = zoneCenter(adj[1], adj[2])
				local dir = (adjCenter - center).Unit
				local stairPos = center + dir * (ZONE_SIZE * 0.4)
				local angle = math.atan2(dir.X, dir.Z)
				-- Procedural staircase
				for step = 0, 5 do
					local stepPart = Instance.new("Part")
					stepPart.Name = "Stair"
					stepPart.Size = Vector3.new(8, 2, 4)
					stepPart.CFrame = CFrame.new(stairPos + Vector3.new(0, step * 2, 0))
						* CFrame.Angles(0, angle, 0)
						* CFrame.new(0, 0, step * 3)
					stepPart.Color = STONE_COLORS[rng:NextInteger(1, #STONE_COLORS)]
					stepPart.Material = Enum.Material.Slate
					stepPart.Anchored = true
					stepPart.CanCollide = true
					stepPart.Parent = arenaFolder
				end
				break
			end
		end

		local propCount = rng:NextInteger(5, 10)
		for _ = 1, propCount do
			local pos = randomInZone(zi, zj, 8)
			buildBoulder(pos)
			table.insert(coverPositions, pos)
		end

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

			if rng:NextNumber() < 0.4 then
				local vinePos = pos + Vector3.new(rng:NextNumber(-2, 2), 8, rng:NextNumber(-2, 2))
				local vine = clonePrefab(prefabFolder, "ClimbableVine", vinePos)
				CollectionService:AddTag(vine, "Climbable")
				vine.Parent = arenaFolder
			end
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

		-- Bush clusters (procedural): 8-14
		for _ = 1, rng:NextInteger(8, 14) do
			local pos = randomInZone(zi, zj, 4)
			local bush = Instance.new("Part")
			bush.Name = "Bush"
			bush.Shape = Enum.PartType.Ball
			local size = rng:NextNumber(3, 6)
			bush.Size = Vector3.new(size, size * 0.6, size)
			bush.Position = pos + Vector3.new(0, size * 0.2, 0)
			bush.Color = CANOPY_COLORS[rng:NextInteger(1, #CANOPY_COLORS)]
			bush.Material = Enum.Material.Grass
			bush.Anchored = true
			bush.CanCollide = false
			bush.CastShadow = true
			bush.Parent = arenaFolder
			table.insert(coverPositions, pos)
		end

		-- Tall grass clusters: 10-18
		for _ = 1, rng:NextInteger(10, 18) do
			local pos = randomInZone(zi, zj, 4)
			buildGrassCluster(pos)
		end

		-- Fireflies: 4-8
		for _ = 1, rng:NextInteger(4, 8) do
			local pos = randomInZone(zi, zj, 6) + Vector3.new(0, rng:NextNumber(4, 12), 0)
			local firefly = clonePrefab(prefabFolder, "Firefly", pos)
			firefly.Parent = arenaFolder
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
		local minX, maxX, minZ, maxZ = zoneBounds(zi, zj)
		local center = zoneCenter(zi, zj)
		local corridorHalfWidth = 8

		local horizontal = rng:NextInteger(1, 2) == 1
		local waypoints: { Vector3 } = {}
		local numMidpoints = rng:NextInteger(3, 5)

		if horizontal then
			table.insert(waypoints, Vector3.new(minX, 0, center.Z + rng:NextNumber(-20, 20)))
			for w = 1, numMidpoints do
				local wx = minX + (maxX - minX) * (w / (numMidpoints + 1))
				local wz = math.clamp(center.Z + rng:NextNumber(-40, 40), minZ + 15, maxZ - 15)
				table.insert(waypoints, Vector3.new(wx, 0, wz))
			end
			table.insert(waypoints, Vector3.new(maxX, 0, center.Z + rng:NextNumber(-20, 20)))
		else
			table.insert(waypoints, Vector3.new(center.X + rng:NextNumber(-20, 20), 0, minZ))
			for w = 1, numMidpoints do
				local wz = minZ + (maxZ - minZ) * (w / (numMidpoints + 1))
				local wx = math.clamp(center.X + rng:NextNumber(-40, 40), minX + 15, maxX - 15)
				table.insert(waypoints, Vector3.new(wx, 0, wz))
			end
			table.insert(waypoints, Vector3.new(center.X + rng:NextNumber(-20, 20), 0, maxZ))
		end

		local totalLength = 0
		for idx = 1, #waypoints - 1 do
			totalLength += (waypoints[idx + 1] - waypoints[idx]).Magnitude
		end

		local function posAlongPath(t: number): (Vector3, Vector3)
			local targetDist = math.clamp(t, 0, 1) * totalLength
			local accumulated = 0
			for idx = 1, #waypoints - 1 do
				local seg = waypoints[idx + 1] - waypoints[idx]
				local segLen = seg.Magnitude
				if accumulated + segLen >= targetDist then
					local segT = (targetDist - accumulated) / math.max(segLen, 0.01)
					local pos = waypoints[idx]:Lerp(waypoints[idx + 1], segT)
					local dir = segLen > 0.01 and seg.Unit or Vector3.new(1, 0, 0)
					return pos, dir
				end
				accumulated += segLen
			end
			local lastSeg = waypoints[#waypoints] - waypoints[#waypoints - 1]
			local dir = lastSeg.Magnitude > 0.01 and lastSeg.Unit or Vector3.new(1, 0, 0)
			return waypoints[#waypoints], dir
		end

		local gridSize = arenaData.gridSize
		for segIdx = 1, #waypoints - 1 do
			local from = waypoints[segIdx]
			local to = waypoints[segIdx + 1]
			local seg = to - from
			local segLen = seg.Magnitude
			local dir = segLen > 0.01 and seg.Unit or Vector3.new(1, 0, 0)
			local perp = Vector3.new(-dir.Z, 0, dir.X)
			local wallAngle = math.atan2(dir.X, dir.Z)
			local steps = math.ceil(segLen / gridSize)
			for step = 0, steps do
				local t = steps > 0 and (step / steps) or 0
				local pos = from + seg * t
				local leftWall = cloneWithCFrame("StoneWall",
					CFrame.new(pos + perp * (corridorHalfWidth + 2)) * CFrame.Angles(0, wallAngle, 0))
				leftWall.Parent = arenaFolder
				local rightWall = cloneWithCFrame("StoneWall",
					CFrame.new(pos - perp * (corridorHalfWidth + 2)) * CFrame.Angles(0, wallAngle, 0))
				rightWall.Parent = arenaFolder
			end
		end

		for d = 1, rng:NextInteger(3, 5) do
			local t = d / (rng:NextInteger(3, 5) + 2) + rng:NextNumber(-0.04, 0.04)
			local pos, pathDir = posAlongPath(t)
			local perp = Vector3.new(-pathDir.Z, 0, pathDir.X)
			local side = rng:NextInteger(1, 2) == 1 and 1 or -1
			local dartPos = pos + perp * (corridorHalfWidth * 0.8 * side) + Vector3.new(0, 3, 0)
			local dartAngle = math.atan2(-perp.X * side, -perp.Z * side)
			local dart = cloneWithCFrame("DartTrap",
				CFrame.new(dartPos) * CFrame.Angles(0, dartAngle, 0))
			CollectionService:AddTag(dart, "DartTrap")
			dart.Parent = arenaFolder
			local plate = clonePrefab(prefabFolder, "PressurePlate", pos + Vector3.new(0, 0.25, 0))
			CollectionService:AddTag(plate, "TrapTrigger_Dart")
			local link = Instance.new("ObjectValue")
			link.Name = "LinkedDartTrap"
			link.Value = dart
			link.Parent = plate
			plate.Parent = arenaFolder
		end

		for s = 1, rng:NextInteger(2, 3) do
			local t = 0.2 + (s - 1) * 0.3 + rng:NextNumber(-0.04, 0.04)
			local pos, pathDir = posAlongPath(t)
			local perp = Vector3.new(-pathDir.Z, 0, pathDir.X)
			local logAngle = math.atan2(perp.X, perp.Z)
			local log = cloneWithCFrame("SwingLog",
				CFrame.new(pos + Vector3.new(0, 5, 0)) * CFrame.Angles(0, logAngle, 0))
			CollectionService:AddTag(log, "SwingLogTrap")
			log.Parent = arenaFolder
		end

		local pitPos = posAlongPath(rng:NextNumber(0.35, 0.65))
		local pit = clonePrefab(prefabFolder, "PitTrap", pitPos)
		CollectionService:AddTag(pit, "PitTrap")
		if pit:IsA("BasePart") then pit:SetAttribute("PitDepth", 10) end
		pit.Parent = arenaFolder

		-- Trees flanking corridor (3-5)
		local treePositions: { Vector3 } = {}
		for _ = 1, rng:NextInteger(3, 5) do
			local pos: Vector3
			local att = 0
			repeat att += 1; pos = randomInZone(zi, zj, 6)
			until checkSpacing(pos, treePositions, 14) or att > 20
			table.insert(treePositions, pos)
			buildTree(pos, if rng:NextNumber() < 0.5 then "large" else "small")
		end
	end

	--------------------------------------------------------------------
	-- COURTYARD ZONE GENERATOR
	--------------------------------------------------------------------

	local function generateCourtyardZone(zi: number, zj: number)
		for _ = 1, rng:NextInteger(2, 4) do
			local pos = randomInZone(zi, zj, 15)
			buildPillar(pos)
		end

		for _ = 1, rng:NextInteger(4, 7) do
			local pos = randomInZone(zi, zj, 10)
			buildBoulder(pos)
			table.insert(coverPositions, pos)
		end

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
	end

	--------------------------------------------------------------------
	-- ELEVATED RUINS ZONE GENERATOR
	--------------------------------------------------------------------

	local function generateElevatedRuinsZone(zi: number, zj: number)
		local center = zoneCenter(zi, zj)
		local minX, maxX, minZ, maxZ = zoneBounds(zi, zj)

		terrain:FillBlock(
			CFrame.new(center.X, ELEVATED_Y / 2, center.Z),
			Vector3.new(ZONE_SIZE * 0.85, ELEVATED_Y, ZONE_SIZE * 0.85),
			Enum.Material.Ground
		)
		terrain:FillBlock(
			CFrame.new(center.X, ELEVATED_Y, center.Z),
			Vector3.new(ZONE_SIZE * 0.85, 4, ZONE_SIZE * 0.85),
			Enum.Material.Grass
		)

		local basePos = center + Vector3.new(0, ELEVATED_Y + 1, 0)
		local base = clonePrefab(prefabFolder, "TempleBase", basePos)
		base.Parent = arenaFolder

		for _ = 1, rng:NextInteger(3, 5) do
			local pos = Vector3.new(
				rng:NextNumber(minX + 20, maxX - 20), ELEVATED_Y + 1,
				rng:NextNumber(minZ + 20, maxZ - 20))
			local angle = rng:NextNumber(0, 2 * math.pi)
			local wall = cloneWithCFrame("StoneWall",
				CFrame.new(pos) * CFrame.Angles(0, angle, 0))
			wall.Parent = arenaFolder
			table.insert(coverPositions, pos)
		end

		for _ = 1, rng:NextInteger(4, 6) do
			local pos = Vector3.new(
				rng:NextNumber(minX + 15, maxX - 15), ELEVATED_Y + 1,
				rng:NextNumber(minZ + 15, maxZ - 15))
			local pillar = cloneRandomVariant(prefabFolder, "RuinedPillar", pos)
			pillar.Parent = arenaFolder
		end

		local sides = {
			{ dir = Vector3.new(-1, 0, 0), angle = math.pi / 2 },
			{ dir = Vector3.new(1, 0, 0), angle = -math.pi / 2 },
			{ dir = Vector3.new(0, 0, -1), angle = 0 },
			{ dir = Vector3.new(0, 0, 1), angle = math.pi },
		}
		shuffle(sides)
		for idx = 1, math.min(rng:NextInteger(2, 3), #sides) do
			local side = sides[idx]
			local edgePos = center + side.dir * (ZONE_SIZE * 0.4)
			if rng:NextNumber() < 0.6 then
				local stair = cloneWithCFrame("StoneStaircase",
					CFrame.new(edgePos) * CFrame.Angles(0, side.angle, 0))
				stair.Parent = arenaFolder
			else
				local vinePos = edgePos + Vector3.new(0, ELEVATED_Y * 0.5, 0)
				local vine = clonePrefab(prefabFolder, "ClimbableVine", vinePos)
				CollectionService:AddTag(vine, "Climbable")
				vine.Parent = arenaFolder
			end
		end

		-- Trees on elevated platform (2-3)
		local treePositions: { Vector3 } = {}
		for _ = 1, rng:NextInteger(2, 3) do
			local pos = Vector3.new(
				rng:NextNumber(minX + 15, maxX - 15), ELEVATED_Y + 1,
				rng:NextNumber(minZ + 15, maxZ - 15))
			if checkSpacing(pos, treePositions, 18) then
				table.insert(treePositions, pos)
				buildTree(pos, if rng:NextNumber() < 0.3 then "large" else "small")
			end
		end

		local soundPart = Instance.new("Part")
		soundPart.Name = "AmbientSound_Wind"
		soundPart.Size = Vector3.new(1, 1, 1)
		soundPart.Position = center + Vector3.new(0, ELEVATED_Y + 8, 0)
		soundPart.Anchored = true
		soundPart.CanCollide = false
		soundPart.Transparency = 1
		CollectionService:AddTag(soundPart, "AmbientSound_Wind")
		soundPart.Parent = arenaFolder
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
	-- ROPE BRIDGES between elevated zones
	--------------------------------------------------------------------

	local elevatedZones: { { number } } = {}
	for zi = 1, ZONE_COUNT do
		for zj = 1, ZONE_COUNT do
			if zoneTypes[zi][zj] == "elevated_ruins" then
				table.insert(elevatedZones, { zi, zj })
			end
		end
	end

	for a = 1, #elevatedZones do
		for b = a + 1, #elevatedZones do
			local cA = zoneCenter(elevatedZones[a][1], elevatedZones[a][2])
			local cB = zoneCenter(elevatedZones[b][1], elevatedZones[b][2])
			local dist = (cA - cB).Magnitude
			if dist <= ZONE_SIZE * 2.5 then
				local midpoint = (cA + cB) / 2
				midpoint = Vector3.new(midpoint.X, ELEVATED_Y + 1, midpoint.Z)
				local bridgeDir = cB - cA
				local bridgeAngle = math.atan2(bridgeDir.X, bridgeDir.Z)
				local bridge = cloneWithCFrame("RopeBridge",
					CFrame.new(midpoint) * CFrame.Angles(0, bridgeAngle, 0))
				bridge.Parent = arenaFolder
			end
		end
	end

	--------------------------------------------------------------------
	-- TRANSITION RUBBLE
	--------------------------------------------------------------------

	for zi = 1, ZONE_COUNT do
		for zj = 1, ZONE_COUNT do
			if zoneTypes[zi][zj] == "forest" then
				for _, adj in getAdjacent(zi, zj) do
					local adjType = zoneTypes[adj[1]][adj[2]]
					if adjType == "temple" or adjType == "elevated_ruins" then
						local borderCenter = (zoneCenter(zi, zj) + zoneCenter(adj[1], adj[2])) / 2
						for _ = 1, rng:NextInteger(3, 6) do
							local rubblePos = borderCenter + Vector3.new(
								rng:NextNumber(-15, 15), 0, rng:NextNumber(-15, 15))
							local rubble = cloneRandomVariant(prefabFolder, "StoneBoulder", rubblePos)
							rubble.Parent = arenaFolder
						end
					end
				end
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

	local maxAttempts = spawnCount * 80
	local attempts = 0
	while #spawnPositions < spawnCount and attempts < maxAttempts do
		attempts += 1
		local zone = spawnableZones[rng:NextInteger(1, #spawnableZones)]
		local zt = zoneTypes[zone[1]][zone[2]]
		local y = 1
		if zt == "elevated_ruins" then y = ELEVATED_Y + 2 end
		local candidate = randomInZone(zone[1], zone[2], 15) + Vector3.new(0, y, 0)
		if checkSpacing(candidate, spawnPositions, minSpawnDist) then
			table.insert(spawnPositions, candidate)
		end
	end

	local coveredCount = 0
	for _, sp in spawnPositions do
		for _, cv in coverPositions do
			local dx = sp.X - cv.X
			local dz = sp.Z - cv.Z
			if math.sqrt(dx * dx + dz * dz) <= 12 then
				coveredCount += 1
				break
			end
		end
	end
	if coveredCount < 5 then
		for _, sp in spawnPositions do
			if coveredCount >= 5 then break end
			local hasCover = false
			for _, cv in coverPositions do
				local dx = sp.X - cv.X
				local dz = sp.Z - cv.Z
				if math.sqrt(dx * dx + dz * dz) <= 12 then
					hasCover = true
					break
				end
			end
			if not hasCover then
				local boulderPos = Vector3.new(sp.X, 0, sp.Z)
					+ Vector3.new(rng:NextNumber(-6, 6), 0, rng:NextNumber(-6, 6))
				local boulder = cloneRandomVariant(prefabFolder, "StoneBoulder", boulderPos)
				boulder.Parent = arenaFolder
				table.insert(coverPositions, boulderPos)
				coveredCount += 1
			end
		end
	end

	placeSpawnPoints(spawnPositions, arenaFolder)
	print("[JungleRuins v4] === JUNGLE RUINS GENERATION COMPLETE ===")
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
	local existing = Workspace:FindFirstChild(ARENA_FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
	-- Clear procedural terrain (hills, mountains, ponds)
	Workspace.Terrain:Clear()
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
