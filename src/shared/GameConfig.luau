--!strict

local GameConfig = {}

-- Match Settings
GameConfig.MATCH_DURATION_FFA = 1800            -- 30 minutes (seconds)
GameConfig.MATCH_DURATION_TEAM = 1800           -- 30 minutes (seconds)
GameConfig.MAX_PLAYERS_FFA = 10
GameConfig.MAX_PLAYERS_2V2 = 4
GameConfig.MAX_PLAYERS_3V3 = 6
GameConfig.KILL_THRESHOLD_FFA = 25
GameConfig.KILL_THRESHOLD_2V2 = 40
GameConfig.KILL_THRESHOLD_3V3 = 50
GameConfig.RESPAWN_TIME_FFA = 3
GameConfig.RESPAWN_TIME_TEAM = 5
GameConfig.SPAWN_PROTECTION = 2                -- seconds of invulnerability

-- Player Stats
GameConfig.BASE_HEALTH = 100
GameConfig.HEALTH_REGEN_RATE = 2               -- HP per second
GameConfig.HEALTH_REGEN_DELAY = 5              -- seconds after last damage
GameConfig.BASE_WALK_SPEED = 16
GameConfig.SPRINT_MULTIPLIER = 1.5
GameConfig.MAX_STAMINA = 100
GameConfig.SPRINT_STAMINA_COST = 10            -- per second
GameConfig.DODGE_STAMINA_COST = 25
GameConfig.STAMINA_REGEN_RATE = 15             -- per second
GameConfig.STAMINA_REGEN_DELAY = 1             -- seconds before regen starts
GameConfig.DODGE_COOLDOWN = 3                  -- seconds
GameConfig.DODGE_INVINCIBILITY = 0.3           -- seconds

-- Economy
GameConfig.COINS_PER_KILL = 10
GameConfig.COINS_PER_ASSIST = 5
GameConfig.COINS_WIN_BONUS = 25
GameConfig.COINS_MATCH_COMPLETE = 10
GameConfig.ASSIST_DAMAGE_THRESHOLD = 0.3       -- 30% of max HP

-- Arena Events
GameConfig.LAVA_DAMAGE_PER_SEC = 10
GameConfig.LAVA_SHRINK_INTERVAL = 120          -- seconds
GameConfig.LAVA_ERUPTION_INTERVAL = 90         -- seconds
GameConfig.SHADOW_MAZE_VISION_RANGE = 20       -- studs
GameConfig.SHADOW_MAZE_WALL_SHIFT = 180        -- seconds
GameConfig.JUNGLE_DART_DAMAGE = 15
GameConfig.JUNGLE_LOG_DAMAGE = 25

-- Bear NPCs (Jungle Ruins)
GameConfig.BEAR_HEALTH = 200
GameConfig.BEAR_ATTACK_DAMAGE = 30
GameConfig.BEAR_ATTACK_COOLDOWN = 1.5
GameConfig.BEAR_DETECTION_RANGE = 40
GameConfig.BEAR_AGGRO_RANGE = 25
GameConfig.BEAR_CHASE_RANGE = 80
GameConfig.BEAR_ATTACK_RANGE = 8
GameConfig.BEAR_WALK_SPEED = 6
GameConfig.BEAR_CHARGE_SPEED = 20
GameConfig.BEAR_RESPAWN_DELAY = 45
GameConfig.COINS_PER_BEAR_KILL = 15
GameConfig.BEAR_FIGHT_RANGE = 15
GameConfig.BEAR_FIGHT_DAMAGE = 20
GameConfig.BEAR_FLEE_THRESHOLD = 0.3

-- Admin: Ethan Template
GameConfig.ADMIN_FROST_DURATION = 10            -- seconds
GameConfig.ADMIN_REVERSE_GRAVITY_DURATION = 180 -- 3 minutes (seconds)
GameConfig.ADMIN_METEORITE_DIRECT_DAMAGE = 80
GameConfig.ADMIN_METEORITE_SPLASH_DAMAGE = 40
GameConfig.ADMIN_METEORITE_SPLASH_RADIUS = 12   -- studs
GameConfig.ADMIN_METEORITE_TRAVEL_TIME = 1.5    -- seconds
GameConfig.ADMIN_METEORITE_CRATER_DPS = 5       -- damage per second
GameConfig.ADMIN_METEORITE_CRATER_DURATION = 10  -- seconds
GameConfig.ADMIN_STEALTH_DURATION = 6           -- seconds (Leopard)
GameConfig.ADMIN_STEALTH_TRANSPARENCY = 0.8
GameConfig.ADMIN_HOWL_SLOW_PERCENT = 0.4        -- 40% slow (Wolf)
GameConfig.ADMIN_HOWL_SLOW_DURATION = 4          -- seconds
GameConfig.ADMIN_HOWL_RADIUS = 15                -- studs

-- Admin: Shapeshift Form Stats (multipliers)
export type ShapeshiftForm = {
	speed: number,
	damage: number,
	scale: number,
}

GameConfig.FORM_LION = { speed = 1.2, damage = 1.3, scale = 1.3 } :: ShapeshiftForm
GameConfig.FORM_TIGER = { speed = 1.35, damage = 1.2, scale = 1.2 } :: ShapeshiftForm
GameConfig.FORM_WOLF = { speed = 1.5, damage = 1.1, scale = 0.9 } :: ShapeshiftForm
GameConfig.FORM_LEOPARD = { speed = 1.6, damage = 1.15, scale = 0.8 } :: ShapeshiftForm
GameConfig.FORM_GORILLA = { speed = 1.05, damage = 1.5, scale = 1.8 } :: ShapeshiftForm

return table.freeze(GameConfig)
