--!strict

local WeaponConfig = require(script.Parent:WaitForChild("WeaponConfig"))

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

export type ShopItem = {
	id: string,
	category: string,          -- "Weapons" | "Upgrades" | "Skins" | "Emotes"
	displayName: string,
	description: string,
	price: number,
	weaponName: string?,       -- which weapon this relates to (upgrades, skins)
	tier: number?,             -- upgrade tier (2 or 3)
	rarity: string?,           -- "Common" | "Rare" | "Epic" | "Legendary"
}

------------------------------------------------------------------------
-- All purchasable items
------------------------------------------------------------------------

local Items: { [string]: ShopItem } = {
	-- Weapons
	Weapon_Sword = {
		id = "Weapon_Sword",
		category = "Weapons",
		displayName = "Sword",
		description = "Balanced melee weapon. Blade Rush combo stuns enemies.",
		price = 0,
	},
	Weapon_Axe = {
		id = "Weapon_Axe",
		category = "Weapons",
		displayName = "Axe",
		description = "Heavy melee weapon. Earthshaker deals AoE damage and knockback.",
		price = 200,
	},
	Weapon_Bow = {
		id = "Weapon_Bow",
		category = "Weapons",
		displayName = "Bow",
		description = "Ranged weapon. Hunter's Mark reveals enemies through walls.",
		price = 200,
	},
	Weapon_Scythe = {
		id = "Weapon_Scythe",
		category = "Weapons",
		displayName = "Scythe",
		description = "Swift melee weapon. Soul Harvest heals and speeds you on kills.",
		price = 300,
	},

	-- Upgrades: Sword
	Upgrade_Sword_T2 = {
		id = "Upgrade_Sword_T2",
		category = "Upgrades",
		displayName = "Sword Tier 2",
		description = "Blade Rush triggers on 3rd hit instead of 4th.",
		price = 500,
		weaponName = "Sword",
		tier = 2,
	},
	Upgrade_Sword_T3 = {
		id = "Upgrade_Sword_T3",
		category = "Upgrades",
		displayName = "Sword Tier 3",
		description = "Blade Rush stun lasts 0.8s (up from 0.5s).",
		price = 1000,
		weaponName = "Sword",
		tier = 3,
	},

	-- Upgrades: Axe
	Upgrade_Axe_T2 = {
		id = "Upgrade_Axe_T2",
		category = "Upgrades",
		displayName = "Axe Tier 2",
		description = "Earthshaker radius increased to 10 studs.",
		price = 500,
		weaponName = "Axe",
		tier = 2,
	},
	Upgrade_Axe_T3 = {
		id = "Upgrade_Axe_T3",
		category = "Upgrades",
		displayName = "Axe Tier 3",
		description = "Earthshaker cooldown reduced to 6 seconds.",
		price = 1000,
		weaponName = "Axe",
		tier = 3,
	},

	-- Upgrades: Bow
	Upgrade_Bow_T2 = {
		id = "Upgrade_Bow_T2",
		category = "Upgrades",
		displayName = "Bow Tier 2",
		description = "Hunter's Mark lasts 8 seconds (up from 5).",
		price = 500,
		weaponName = "Bow",
		tier = 2,
	},
	Upgrade_Bow_T3 = {
		id = "Upgrade_Bow_T3",
		category = "Upgrades",
		displayName = "Bow Tier 3",
		description = "Marked targets take 10% bonus damage.",
		price = 1000,
		weaponName = "Bow",
		tier = 3,
	},

	-- Upgrades: Scythe
	Upgrade_Scythe_T2 = {
		id = "Upgrade_Scythe_T2",
		category = "Upgrades",
		displayName = "Scythe Tier 2",
		description = "Soul Harvest heals 45 HP on kill (up from 30).",
		price = 500,
		weaponName = "Scythe",
		tier = 2,
	},
	Upgrade_Scythe_T3 = {
		id = "Upgrade_Scythe_T3",
		category = "Upgrades",
		displayName = "Scythe Tier 3",
		description = "Speed boost lasts 6s and stacks up to 3 times.",
		price = 1000,
		weaponName = "Scythe",
		tier = 3,
	},

	-- Skins: Sword
	Skin_Sword_IronEdge = {
		id = "Skin_Sword_IronEdge",
		category = "Skins",
		displayName = "Iron Edge",
		description = "A weathered iron blade.",
		price = 150,
		weaponName = "Sword",
		rarity = "Common",
	},
	Skin_Sword_CrimsonFang = {
		id = "Skin_Sword_CrimsonFang",
		category = "Skins",
		displayName = "Crimson Fang",
		description = "Dripping with crimson energy.",
		price = 400,
		weaponName = "Sword",
		rarity = "Rare",
	},
	Skin_Sword_VoidBlade = {
		id = "Skin_Sword_VoidBlade",
		category = "Skins",
		displayName = "Void Blade",
		description = "Forged in the abyss.",
		price = 800,
		weaponName = "Sword",
		rarity = "Epic",
	},
	Skin_Sword_SolarFlare = {
		id = "Skin_Sword_SolarFlare",
		category = "Skins",
		displayName = "Solar Flare",
		description = "Burns with the power of a star.",
		price = 1500,
		weaponName = "Sword",
		rarity = "Legendary",
	},

	-- Skins: Axe
	Skin_Axe_Woodsman = {
		id = "Skin_Axe_Woodsman",
		category = "Skins",
		displayName = "Woodsman",
		description = "A trusty lumberjack's axe.",
		price = 150,
		weaponName = "Axe",
		rarity = "Common",
	},
	Skin_Axe_FrostCleaver = {
		id = "Skin_Axe_FrostCleaver",
		category = "Skins",
		displayName = "Frost Cleaver",
		description = "Encased in eternal ice.",
		price = 400,
		weaponName = "Axe",
		rarity = "Rare",
	},
	Skin_Axe_MoltenSplitter = {
		id = "Skin_Axe_MoltenSplitter",
		category = "Skins",
		displayName = "Molten Splitter",
		description = "Dripping with molten metal.",
		price = 800,
		weaponName = "Axe",
		rarity = "Epic",
	},
	Skin_Axe_Doomcleaver = {
		id = "Skin_Axe_Doomcleaver",
		category = "Skins",
		displayName = "Doomcleaver",
		description = "An axe that splits reality itself.",
		price = 1500,
		weaponName = "Axe",
		rarity = "Legendary",
	},

	-- Skins: Bow
	Skin_Bow_HuntersCurve = {
		id = "Skin_Bow_HuntersCurve",
		category = "Skins",
		displayName = "Hunter's Curve",
		description = "A simple hunting bow.",
		price = 150,
		weaponName = "Bow",
		rarity = "Common",
	},
	Skin_Bow_StormString = {
		id = "Skin_Bow_StormString",
		category = "Skins",
		displayName = "Storm String",
		description = "Arrows crackle with lightning.",
		price = 400,
		weaponName = "Bow",
		rarity = "Rare",
	},
	Skin_Bow_PhantomShot = {
		id = "Skin_Bow_PhantomShot",
		category = "Skins",
		displayName = "Phantom Shot",
		description = "Arrows phase through shadows.",
		price = 800,
		weaponName = "Bow",
		rarity = "Epic",
	},
	Skin_Bow_CelestialArc = {
		id = "Skin_Bow_CelestialArc",
		category = "Skins",
		displayName = "Celestial Arc",
		description = "Woven from starlight.",
		price = 1500,
		weaponName = "Bow",
		rarity = "Legendary",
	},

	-- Skins: Scythe
	Skin_Scythe_Harvester = {
		id = "Skin_Scythe_Harvester",
		category = "Skins",
		displayName = "Harvester",
		description = "A humble farming scythe.",
		price = 150,
		weaponName = "Scythe",
		rarity = "Common",
	},
	Skin_Scythe_BoneReaper = {
		id = "Skin_Scythe_BoneReaper",
		category = "Skins",
		displayName = "Bone Reaper",
		description = "Carved from ancient bones.",
		price = 400,
		weaponName = "Scythe",
		rarity = "Rare",
	},
	Skin_Scythe_NightmareEdge = {
		id = "Skin_Scythe_NightmareEdge",
		category = "Skins",
		displayName = "Nightmare Edge",
		description = "Feeds on fear.",
		price = 800,
		weaponName = "Scythe",
		rarity = "Epic",
	},
	Skin_Scythe_DeathBlossom = {
		id = "Skin_Scythe_DeathBlossom",
		category = "Skins",
		displayName = "Death Blossom",
		description = "Where it swings, flowers of darkness bloom.",
		price = 1500,
		weaponName = "Scythe",
		rarity = "Legendary",
	},

	-- Emotes
	Emote_Wave = {
		id = "Emote_Wave",
		category = "Emotes",
		displayName = "Wave",
		description = "A friendly wave.",
		price = 100,
		rarity = "Common",
	},
	Emote_Salute = {
		id = "Emote_Salute",
		category = "Emotes",
		displayName = "Salute",
		description = "A respectful salute.",
		price = 100,
		rarity = "Common",
	},
	Emote_Flex = {
		id = "Emote_Flex",
		category = "Emotes",
		displayName = "Flex",
		description = "Show off those muscles.",
		price = 300,
		rarity = "Rare",
	},
	Emote_Taunt = {
		id = "Emote_Taunt",
		category = "Emotes",
		displayName = "Taunt",
		description = "Come at me!",
		price = 300,
		rarity = "Rare",
	},
	Emote_VictoryDance = {
		id = "Emote_VictoryDance",
		category = "Emotes",
		displayName = "Victory Dance",
		description = "Celebrate in style.",
		price = 600,
		rarity = "Epic",
	},
	Emote_ShadowStep = {
		id = "Emote_ShadowStep",
		category = "Emotes",
		displayName = "Shadow Step",
		description = "Vanish and reappear dramatically.",
		price = 600,
		rarity = "Epic",
	},
	Emote_WarCry = {
		id = "Emote_WarCry",
		category = "Emotes",
		displayName = "War Cry",
		description = "Let out a fearsome battle cry.",
		price = 1200,
		rarity = "Legendary",
	},
	Emote_ThunderClap = {
		id = "Emote_ThunderClap",
		category = "Emotes",
		displayName = "Thunder Clap",
		description = "Clap with the force of thunder.",
		price = 1200,
		rarity = "Legendary",
	},
}

------------------------------------------------------------------------
-- Upgrade tier perk overrides
------------------------------------------------------------------------

type PerkOverrides = { [string]: any }

local UpgradeTiers: { [string]: { [number]: PerkOverrides } } = {
	Sword = {
		[2] = { comboHitsRequired = 3 },
		[3] = { comboHitsRequired = 3, comboStunDuration = 0.8 },
	},
	Axe = {
		[2] = { aoeRadius = 10 },
		[3] = { aoeRadius = 10, cooldown = 6 },
	},
	Bow = {
		[2] = { markDuration = 8 },
		[3] = { markDuration = 8, markBonusDamagePercent = 0.10 },
	},
	Scythe = {
		[2] = { healAmount = 45 },
		[3] = { healAmount = 45, speedBoostDuration = 6, maxSpeedStacks = 3 },
	},
}

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local ShopConfig = {}
ShopConfig.Items = Items
ShopConfig.UpgradeTiers = UpgradeTiers

function ShopConfig.GetItemsByCategory(category: string): { ShopItem }
	local result: { ShopItem } = {}
	for _, item in Items do
		if item.category == category then
			table.insert(result, item)
		end
	end
	-- Sort by price, then by display name
	table.sort(result, function(a, b)
		if a.price ~= b.price then
			return a.price < b.price
		end
		return a.displayName < b.displayName
	end)
	return result
end

function ShopConfig.GetPerkOverrides(weaponName: string, tier: number): PerkOverrides?
	local weaponTiers = UpgradeTiers[weaponName]
	if not weaponTiers then
		return nil
	end
	return weaponTiers[tier]
end

return table.freeze(ShopConfig)
