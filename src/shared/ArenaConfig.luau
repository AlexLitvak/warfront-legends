--!strict
--[[
	ArenaConfig (Shared)
	Defines metadata for all 4 arena types used by the procedural
	generation system. Includes layout bounds, spawn settings, lighting,
	hazards, environmental events, and music placeholders.
]]

local GameConfig = require(script.Parent:WaitForChild("GameConfig"))

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

export type LightingConfig = {
	Brightness: number,
	Ambient: Color3,
	OutdoorAmbient: Color3,
	FogEnd: number,
	FogColor: Color3,
	ClockTime: number,
}

export type HazardConfig = {
	name: string,
	enabled: boolean,
	damagePerSecond: number?,
	damage: number?,
	knockbackForce: number?,
	radius: number?,
	visionRange: number?,
}

export type EnvironmentalEvent = {
	name: string,
	enabled: boolean,
	interval: number,       -- seconds between occurrences
	description: string,
}

export type ArenaBounds = {
	shape: string,          -- "Circle" or "Rectangle"
	diameter: number?,      -- for circular arenas
	width: number?,         -- for rectangular arenas
	depth: number?,         -- for rectangular arenas
}

export type AtmosphereConfig = {
	Density: number,
	Offset: number,
	Color: Color3,
	Decay: Color3,
	Glare: number,
	Haze: number,
}

export type GroundFogConfig = {
	emitterCount: number,      -- number of fog emitter parts to scatter
	patchSize: Vector3,        -- size of each invisible emitter part
	particleLifetime: NumberRange,
	particleSize: NumberSequence,
	particleTransparency: NumberSequence,
	particleColor: Color3,
	particleRate: number,
	particleSpeed: NumberRange,
	particleSpread: Vector2,   -- X = horizontal angle, Y = vertical angle
	particleTexture: string,   -- rbxassetid for a soft cloud/smoke texture
}

export type ArenaData = {
	name: string,
	displayName: string,
	prefabFolder: string,
	gridSize: number,
	bounds: ArenaBounds,
	minSpawnDistance: number,
	spawnCount: number,
	lightingConfig: LightingConfig,
	atmosphereConfig: AtmosphereConfig?,
	groundFogConfig: GroundFogConfig?,
	hazards: { HazardConfig },
	environmentalEvents: { EnvironmentalEvent },
	music: string,
}

------------------------------------------------------------------------
-- Arena definitions
------------------------------------------------------------------------

local Arenas: { [string]: ArenaData } = {

	------------------------------------------------------------------------
	-- Classic Colosseum
	-- Roman gladiator arena, open and symmetrical. Pure skill, no gimmicks.
	------------------------------------------------------------------------
	Colosseum = {
		name = "Colosseum",
		displayName = "Classic Colosseum",
		prefabFolder = "Colosseum",
		gridSize = 12,
		bounds = {
			shape = "Circle",
			diameter = 200,
		},
		minSpawnDistance = 30,
		spawnCount = 10,
		lightingConfig = {
			Brightness = 2,
			Ambient = Color3.fromRGB(140, 140, 140),
			OutdoorAmbient = Color3.fromRGB(180, 180, 180),
			FogEnd = 10000,
			FogColor = Color3.fromRGB(192, 216, 240),
			ClockTime = 14,
		},
		hazards = {},
		environmentalEvents = {},
		music = "",
	},

	------------------------------------------------------------------------
	-- Lava Forge
	-- Volcanic forge with rivers of lava and molten metal. Multi-level
	-- platforms connected by bridges. Lava rises over time.
	------------------------------------------------------------------------
	LavaForge = {
		name = "LavaForge",
		displayName = "Lava Forge",
		prefabFolder = "LavaForge",
		gridSize = 12,
		bounds = {
			shape = "Rectangle",
			width = 160,
			depth = 160,
		},
		minSpawnDistance = 25,
		spawnCount = 10,
		lightingConfig = {
			Brightness = 1,
			Ambient = Color3.fromRGB(120, 50, 20),
			OutdoorAmbient = Color3.fromRGB(180, 80, 30),
			FogEnd = 400,
			FogColor = Color3.fromRGB(80, 30, 10),
			ClockTime = 18,
		},
		hazards = {
			{
				name = "LavaFloor",
				enabled = true,
				damagePerSecond = GameConfig.LAVA_DAMAGE_PER_SEC,
			},
		},
		environmentalEvents = {
			{
				name = "LavaShrink",
				enabled = true,
				interval = GameConfig.LAVA_SHRINK_INTERVAL,
				description = "Lava rises and covers lowest platforms, forcing players upward.",
			},
			{
				name = "LavaEruption",
				enabled = true,
				interval = GameConfig.LAVA_ERUPTION_INTERVAL,
				description = "Random geysers erupt from lava, launching nearby players upward.",
			},
		},
		music = "",
	},

	------------------------------------------------------------------------
	-- Shadow Maze
	-- Dark ancient dungeon labyrinth. Tight corridors, dead ends, limited
	-- visibility. Walls shift periodically to change available paths.
	------------------------------------------------------------------------
	ShadowMaze = {
		name = "ShadowMaze",
		displayName = "Shadow Maze",
		prefabFolder = "ShadowMaze",
		gridSize = 12,
		bounds = {
			shape = "Rectangle",
			width = 180,
			depth = 180,
		},
		minSpawnDistance = 20,
		spawnCount = 10,
		lightingConfig = {
			Brightness = 0.2,
			Ambient = Color3.fromRGB(20, 20, 30),
			OutdoorAmbient = Color3.fromRGB(10, 10, 15),
			FogEnd = 80,
			FogColor = Color3.fromRGB(10, 10, 15),
			ClockTime = 0,
		},
		hazards = {
			{
				name = "LowVisibility",
				enabled = true,
				visionRange = GameConfig.SHADOW_MAZE_VISION_RANGE,
			},
		},
		environmentalEvents = {
			{
				name = "WallShift",
				enabled = true,
				interval = GameConfig.SHADOW_MAZE_WALL_SHIFT,
				description = "Some walls rotate or slide, changing available paths.",
			},
		},
		music = "",
	},

	------------------------------------------------------------------------
	-- Jungle Ruins
	-- Overgrown ancient temple ruins in dense jungle. Ruined buildings,
	-- stone pillars, vine-covered walls, traps, and dense vegetation.
	------------------------------------------------------------------------
	JungleRuins = {
		name = "JungleRuins",
		displayName = "Jungle Ruins",
		prefabFolder = "JungleRuins",
		gridSize = 24,
		bounds = {
			shape = "Rectangle",
			width = 1000,
			depth = 1000,
		},
		minSpawnDistance = 50,
		spawnCount = 20,
		lightingConfig = {
			Brightness = 0.8,
			Ambient = Color3.fromRGB(30, 30, 45),
			OutdoorAmbient = Color3.fromRGB(60, 50, 40),
			FogEnd = 500,
			FogColor = Color3.fromRGB(50, 45, 55),
			ClockTime = 6.5,
		},
		atmosphereConfig = {
			Density = 0.45,
			Offset = 0.1,
			Color = Color3.fromRGB(120, 140, 130),
			Decay = Color3.fromRGB(80, 100, 90),
			Glare = 0.15,
			Haze = 3.5,
		},
		groundFogConfig = {
			emitterCount = 35,
			patchSize = Vector3.new(60, 1, 60),
			particleLifetime = NumberRange.new(8, 16),
			particleSize = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 25),
				NumberSequenceKeypoint.new(0.5, 55),
				NumberSequenceKeypoint.new(1, 30),
			}),
			particleTransparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.15, 0.5),
				NumberSequenceKeypoint.new(0.8, 0.55),
				NumberSequenceKeypoint.new(1, 1),
			}),
			particleColor = Color3.fromRGB(180, 185, 175),
			particleRate = 5,
			particleSpeed = NumberRange.new(0.3, 1.5),
			particleSpread = Vector2.new(180, 8),
			particleTexture = "rbxasset://textures/particles/smoke_main.dds",
		},
		hazards = {
			{
				name = "DartTrap",
				enabled = true,
				damage = GameConfig.JUNGLE_DART_DAMAGE,
			},
			{
				name = "LogTrap",
				enabled = true,
				damage = GameConfig.JUNGLE_LOG_DAMAGE,
				knockbackForce = 40,
			},
			{
				name = "PitTrap",
				enabled = true,
			},
		},
		environmentalEvents = {},
		music = "",
	},
}

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local ArenaConfig = {}
ArenaConfig.Arenas = Arenas

--- Return an ordered list of all arena names.
function ArenaConfig.GetArenaNames(): { string }
	local names: { string } = {}
	for name in Arenas do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

--- Get arena data by name, or nil if not found.
function ArenaConfig.GetArena(name: string): ArenaData?
	return Arenas[name]
end

--- Pick a random arena.
function ArenaConfig.GetRandomArena(): ArenaData
	local names = ArenaConfig.GetArenaNames()
	return Arenas[names[math.random(1, #names)]]
end

return table.freeze(ArenaConfig)
