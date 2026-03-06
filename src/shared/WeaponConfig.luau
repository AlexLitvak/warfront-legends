--!strict

export type PerkConfig = {
	name: string,
	-- Sword: Blade Rush
	comboHitsRequired: number?,
	comboDamageMultiplier: number?,
	comboStunDuration: number?,
	comboResetTime: number?,
	-- Axe: Earthshaker
	aoeDamage: number?,
	aoeRadius: number?,
	chargeTime: number?,
	cooldown: number?,
	knockbackForce: number?,
	-- Bow: Hunter's Mark
	markDuration: number?,
	headshotDamage: number?,
	markBonusDamagePercent: number?,
	-- Scythe: Soul Harvest
	healAmount: number?,
	speedBoostPercent: number?,
	speedBoostDuration: number?,
	maxSpeedStacks: number?,
}

export type WeaponStats = {
	name: string,
	weaponType: string,       -- "Melee" or "Ranged"
	damage: number,
	attackSpeed: number,      -- seconds between swings/shots
	range: number,            -- studs
	price: number,            -- 0 = free starter
	perk: PerkConfig?,
}

local WeaponConfig: { [string]: WeaponStats } = {
	Sword = {
		name = "Sword",
		weaponType = "Melee",
		damage = 20,
		attackSpeed = 0.5,
		range = 5,
		price = 0,
		perk = {
			name = "BladeRush",
			comboHitsRequired = 4,       -- 4th consecutive hit triggers perk
			comboDamageMultiplier = 2,    -- double damage on perk hit
			comboStunDuration = 0.5,      -- seconds
			comboResetTime = 2,           -- combo resets if no hit within this time
		},
	},

	Axe = {
		name = "Axe",
		weaponType = "Melee",
		damage = 35,
		attackSpeed = 1.2,
		range = 6,
		price = 200,
		perk = {
			name = "Earthshaker",
			aoeDamage = 40,
			aoeRadius = 8,               -- studs
			chargeTime = 1.5,            -- seconds to hold
			cooldown = 8,                -- seconds
			knockbackForce = 50,
		},
	},

	Bow = {
		name = "Bow",
		weaponType = "Ranged",
		damage = 25,
		attackSpeed = 0.8,               -- draw time
		range = 60,                      -- studs
		price = 200,
		perk = {
			name = "HuntersMark",
			markDuration = 5,            -- seconds
			headshotDamage = 40,
		},
	},

	Scythe = {
		name = "Scythe",
		weaponType = "Melee",
		damage = 28,
		attackSpeed = 0.7,
		range = 7,
		price = 300,
		perk = {
			name = "SoulHarvest",
			healAmount = 30,
			speedBoostPercent = 0.1,     -- 10%
			speedBoostDuration = 4,      -- seconds
			maxSpeedStacks = 2,
		},
	},
}

return table.freeze(WeaponConfig)
