# Warfront Legends — Game Specification Document

## 1. Overview

**Game Name:** Warfront Legends
**Platform:** Roblox
**Genre:** PvP Arena Combat
**Target Players per Match:** 8–10
**Match Duration:** 8–10 minutes per round

Warfront Legends is a multiplayer PvP arena game where players battle across diverse arenas, each with unique environmental mechanics. Players earn coins through kills, spend them in the shop on weapons, upgrades, and cosmetics, and climb the global leaderboard to prove their dominance.

---

## 2. Core Game Loop

```
Join Match → Choose Arena/Mode → Fight & Earn Coins → Spend in Shop → Climb Leaderboard → Repeat
```

1. Player opens the game and sees the **Main Menu UI**
2. Player selects a **Game Mode** (Free-for-All or Team Battle)
3. Player is placed into a **Matchmaking Queue**
4. Match begins in a randomly selected (or voted) **Arena**
5. Players fight using their equipped weapons; each **kill awards coins**
6. Match ends when the timer runs out or win condition is met
7. **Results screen** shows kills, deaths, coins earned, and leaderboard position
8. Player returns to menu and can visit the **Shop** to spend coins

---

## 3. Game Modes

### 3.1 Free-for-All (FFA)
- **Players:** 8–10
- **Objective:** Get the most kills before the timer ends, OR be the last player standing
- **Respawn:** Yes — players respawn after a short delay (3 seconds) at a random spawn point
- **Win Condition:** Player with the most kills when the 8-minute timer expires wins. If a player reaches a kill threshold (e.g., 25 kills), the match ends early.
- **Scoring:** +1 point per kill, -0 for deaths (deaths don't subtract but are tracked for K/D ratio)

### 3.2 Team Battles
- **Team Sizes:** 2v2 or 3v3 (selected before queueing)
- **Players:** 4 (2v2) or 6 (3v3)
- **Objective:** Team with the most combined kills wins
- **Respawn:** Yes — 5-second respawn delay
- **Win Condition:** First team to reach the kill threshold (e.g., 40 kills for 2v2, 50 for 3v3) or highest kills when the 10-minute timer expires
- **Team Assignment:** Random or party-based (players can invite friends)

---

## 4. Arenas

Each arena has a distinct theme, visual style, and unique environmental mechanics that affect gameplay.

### 4.1 Classic Colosseum
- **Theme:** Roman gladiator arena, open and symmetrical
- **Layout:** Circular arena with a flat ground floor, a few low walls for cover, and elevated platforms around the edges
- **Environmental Mechanics:** None — this is the "pure skill" arena with no gimmicks
- **Lighting:** Bright, clear daylight
- **Best For:** Straightforward combat, good for learning the game
- **Spawn Points:** Evenly distributed around the arena perimeter

### 4.2 Lava Forge
- **Theme:** Volcanic forge/factory with rivers of lava and molten metal
- **Layout:** Multi-level platforms connected by bridges over lava. Central forge area with an anvil platform.
- **Environmental Mechanics:**
  - **Lava Floor:** Lava pools deal continuous damage (10 HP/sec) to players who fall in
  - **Shrinking Safe Zone:** Every 2 minutes, lava rises and covers the lowest platforms, forcing players upward and into tighter spaces
  - **Eruption Events:** Every 90 seconds, random geysers erupt from the lava, launching players upward (can be used strategically)
- **Lighting:** Orange/red glow, embers floating in the air
- **Best For:** Environmental awareness, high-stakes positioning

### 4.3 Shadow Maze
- **Theme:** Dark, ancient dungeon labyrinth
- **Layout:** Network of tight corridors, dead ends, open rooms, and hidden passages. Multiple levels connected by staircases.
- **Environmental Mechanics:**
  - **Low Visibility:** Player vision range is limited to a short radius (~20 studs). Beyond that, darkness.
  - **Torches:** Scattered wall torches provide small pools of light. Players near torches are more visible.
  - **Ambush Corners:** Plenty of corners and blind spots encourage stealth gameplay
  - **Shifting Walls:** Every 3 minutes, some walls rotate or slide, changing available paths
- **Lighting:** Very dark with localized torch light
- **Best For:** Stealth, ambush tactics, close-quarters combat

### 4.4 Jungle Ruins
- **Theme:** Overgrown ancient temple ruins in a dense jungle
- **Layout:** Large area with ruined buildings, stone pillars, vine-covered walls, elevated temple platforms, and dense vegetation on the ground level.
- **Environmental Mechanics:**
  - **Traps:** Pressure plates trigger dart traps (deal 15 damage), swinging log traps (deal 25 damage + knockback), and pit traps (fall into a pit, take fall damage, must climb out)
  - **Verticality:** Vines on walls that players can climb. Zip lines between elevated ruins. High ground provides ranged advantage.
  - **Dense Foliage:** Ground-level bushes and tall grass can partially conceal players
- **Lighting:** Dappled sunlight through jungle canopy
- **Best For:** Trap-aware gameplay, vertical combat, mixed melee/ranged engagements

---

## 5. Combat System

### 5.1 Health & Respawn
- **Base Health:** 100 HP
- **Health Regeneration:** Slow passive regen (2 HP/sec) begins 5 seconds after last taking damage
- **Respawn Timer:** 3 seconds (FFA), 5 seconds (Team Battles)
- **Spawn Protection:** 2 seconds of invulnerability after respawning
- **Death:** On death, player drops no items (loadout is persistent)

### 5.2 Movement
- **Base Movement Speed:** Standard Roblox humanoid speed (16 studs/sec)
- **Sprint:** Hold Shift to sprint at 1.5x speed. Sprinting drains a stamina bar.
- **Dodge/Roll:** Press Q to perform a quick dodge roll with brief invincibility frames (0.3 sec). 3-second cooldown.
- **Jump:** Standard jump + double jump ability

### 5.3 Stamina System
- **Max Stamina:** 100
- **Sprint Cost:** -10 stamina/sec while sprinting
- **Dodge Cost:** -25 stamina per dodge roll
- **Regen:** +15 stamina/sec when not sprinting or dodging (begins after 1 second)

---

## 6. Weapons

All weapons are purchased from the shop with coins. Each weapon type has a unique perk/special ability. Players equip one primary weapon before entering a match.

### 6.1 Weapon Types

#### Sword / Katana
- **Type:** Melee
- **Damage:** 20 per swing
- **Attack Speed:** Fast (0.5 sec between swings)
- **Range:** Short (5 studs)
- **Unique Perk — Blade Rush:** After 3 consecutive hits on the same target, the 4th hit deals double damage and briefly stuns the target (0.5 sec). Encourages aggressive combo play.

#### Axe / Hammer
- **Type:** Melee
- **Damage:** 35 per swing
- **Attack Speed:** Slow (1.2 sec between swings)
- **Range:** Short-Medium (6 studs)
- **Unique Perk — Earthshaker:** Charged heavy attack (hold click for 1.5 sec) slams the ground, dealing 40 damage in an AoE (8-stud radius) and knocking back all nearby enemies. 8-second cooldown.

#### Bow
- **Type:** Ranged
- **Damage:** 25 per arrow (headshot: 40)
- **Attack Speed:** Medium (draw time 0.8 sec)
- **Range:** Long (60 studs)
- **Ammo:** Unlimited arrows, but must draw each shot
- **Unique Perk — Hunter's Mark:** Hitting an enemy marks them for 5 seconds. Marked enemies are visible through walls (highlighted outline) to the bow user only. Encourages tracking and follow-up shots.

#### Scythe
- **Type:** Melee
- **Damage:** 28 per swing
- **Attack Speed:** Medium (0.7 sec between swings)
- **Range:** Medium (7 studs — widest melee arc)
- **Unique Perk — Soul Harvest:** Each kill with the Scythe restores 30 HP and grants a 10% movement speed boost for 4 seconds. Stacks up to 2 times. Encourages aggressive, kill-chasing playstyle.

### 6.2 Weapon Balance Notes
- Sword excels at 1v1 duels with its combo stun
- Axe/Hammer is powerful in group fights with AoE
- Bow controls space and provides intel with Hunter's Mark
- Scythe rewards aggressive players who can chain kills
- All weapons should feel viable; balance through playtesting

### 6.3 Weapon Upgrades
Each weapon has 3 upgrade tiers purchased with coins. Upgrades enhance the weapon's unique perk, not raw damage (to avoid pay-to-win feel).

| Weapon | Tier 1 (Base) | Tier 2 Upgrade | Tier 3 Upgrade |
|--------|---------------|----------------|----------------|
| Sword | Blade Rush at 4 hits | Blade Rush at 3 hits | Stun duration increased to 0.8 sec |
| Axe | Earthshaker 8-stud AoE | AoE increased to 10 studs | Cooldown reduced to 6 sec |
| Bow | Hunter's Mark 5 sec | Mark duration 8 sec | Marked enemies take 10% bonus damage |
| Scythe | Soul Harvest 30 HP | Heal increased to 45 HP | Speed boost lasts 6 sec, stacks 3x |

---

## 7. Economy & Shop

### 7.1 Coin Earning
- **Kill Reward:** +10 coins per kill
- **Assist Reward:** +5 coins (dealt 30%+ damage to a player killed by someone else)
- **Match Win Bonus:** +25 coins
- **Match Completion:** +10 coins (even for losing, to prevent rage-quit)

### 7.2 Shop Categories

#### Weapons
| Item | Price |
|------|-------|
| Sword / Katana | Free (starter weapon) |
| Axe / Hammer | 200 coins |
| Bow | 200 coins |
| Scythe | 300 coins |

#### Weapon Upgrades
| Upgrade | Price |
|---------|-------|
| Tier 2 (any weapon) | 500 coins |
| Tier 3 (any weapon) | 1,000 coins |

#### Weapon Skins
Purely cosmetic. Change the visual appearance and effects of weapons.

| Skin Tier | Price | Examples |
|-----------|-------|----------|
| Common | 150 coins | Recolor (red, blue, gold) |
| Rare | 400 coins | Glowing edges, frost effect |
| Epic | 800 coins | Flame trail, lightning crackle, shadow aura |
| Legendary | 1,500 coins | Full visual overhaul + unique particle effects |

#### Victory Emotes
Played automatically when a player gets the final kill or wins a match.

| Emote Tier | Price | Examples |
|------------|-------|----------|
| Common | 100 coins | Fist pump, thumbs up |
| Rare | 300 coins | Weapon spin flourish, battle cry |
| Epic | 600 coins | Ground slam + shockwave, lightning strike pose |
| Legendary | 1,200 coins | Full cinematic (throne appears, crowd cheers, etc.) |

---

## 8. Leaderboard & Progression

### 8.1 Global Leaderboard
Persistent leaderboard visible from the main menu. Tracks:

- **Total Kills** (all-time)
- **Win Rate** (wins / matches played, minimum 10 matches)
- **Kill/Death Ratio**
- **Current Win Streak**

### 8.2 Display
- Top 100 players shown on the leaderboard
- Players can see their own rank even if outside top 100
- Leaderboard updates in real-time after each match

### 8.3 Rank Titles
Based on total kills, players earn visible rank titles displayed next to their name:

| Kills | Rank Title |
|-------|------------|
| 0–49 | Recruit |
| 50–199 | Fighter |
| 200–499 | Warrior |
| 500–999 | Veteran |
| 1,000–2,499 | Champion |
| 2,500–4,999 | Legend |
| 5,000+ | Warfront Legend |

---

## 9. User Interface

### 9.1 Main Menu
- **Play Button** → Opens mode selection (FFA / Team 2v2 / Team 3v3)
- **Shop Button** → Opens the shop (weapons, upgrades, skins, emotes)
- **Leaderboard Button** → Opens global leaderboard
- **Settings Button** → Audio, controls, graphics
- **Coin Display** → Always visible in the top-right corner showing current coin balance
- **Player Info** → Shows current rank title, total kills, K/D ratio

### 9.2 In-Match HUD
- **Health Bar** — Top-left, with numerical HP display
- **Stamina Bar** — Below health bar
- **Weapon Icon** — Bottom-center, shows equipped weapon and perk cooldown
- **Kill Feed** — Top-right, shows recent kills ("Player A eliminated Player B")
- **Scoreboard** — Hold Tab to view all players' kill counts
- **Timer** — Top-center, shows remaining match time
- **Coin Counter** — Shows coins earned this match (with +10 popup on kills)

### 9.3 Results Screen
Shown after each match:
- **Final Standings** (ranked by kills)
- **Personal Stats:** Kills, Deaths, K/D, Damage Dealt
- **Coins Earned** (broken down: kills, assists, win bonus, completion)
- **Play Again / Return to Menu** buttons

---

## 10. Data Persistence

All player data must be saved server-side using Roblox DataStore:

- **Coins** (currency balance)
- **Owned Weapons** (which weapons purchased)
- **Weapon Upgrade Tiers** (per weapon)
- **Owned Skins** (per weapon)
- **Equipped Loadout** (current weapon, skin, emote)
- **Owned Emotes**
- **Stats** (total kills, deaths, wins, losses)
- **Leaderboard Data** (derived from stats)

---

## 11. Technical Architecture

### 11.1 Roblox Project Structure (Rojo)
```
src/
├── server/           -- ServerScriptService
│   ├── GameManager.lua        -- Match lifecycle (queue, start, end)
│   ├── CombatHandler.lua      -- Damage, kills, hit detection (server-authoritative)
│   ├── CoinManager.lua        -- Coin rewards and transactions
│   ├── DataManager.lua        -- DataStore save/load
│   ├── LeaderboardManager.lua -- Leaderboard updates
│   ├── ShopHandler.lua        -- Purchase validation
│   ├── ArenaManager.lua       -- Arena loading, hazards, events
│   ├── AdminManager.lua       -- Admin whitelist, template loading, ability handling
│   └── MatchmakingService.lua -- Queue and team assignment
├── client/           -- StarterPlayerScripts
│   ├── UIController.lua       -- All UI screens and HUD
│   ├── CombatClient.lua       -- Input handling, attack animations
│   ├── CameraController.lua   -- Combat camera
│   └── SoundManager.lua       -- SFX and music
├── shared/           -- ReplicatedStorage
│   ├── WeaponConfig.lua       -- Weapon stats, perk definitions
│   ├── ArenaConfig.lua        -- Arena metadata and settings
│   ├── GameConfig.lua         -- Global constants (match time, coin rewards, etc.)
│   └── Remotes.lua            -- RemoteEvent/RemoteFunction definitions
└── assets/           -- Workspace / ReplicatedStorage
    ├── Arenas/                -- Arena map models
    ├── Weapons/               -- Weapon models and animations
    └── UI/                    -- UI assets and icons
```

### 11.2 Networking Model
- **Server-authoritative combat:** All damage calculations happen on the server. Clients send attack inputs; server validates hit detection and applies damage.
- **RemoteEvents** for: attack input, damage dealt, kill notification, coin updates, match state changes
- **RemoteFunctions** for: shop purchases, data loading

### 11.3 Key Technical Considerations
- **Anti-cheat:** Server validates all combat actions. Never trust client damage values.
- **DataStore throttling:** Use session-locking and auto-save every 60 seconds. Save on player leave.
- **Arena instancing:** Use TeleportService or arena loading within the same server depending on player count needs.
- **Hit detection:** Use raycasting for ranged weapons. Use hitbox/region checking for melee weapons.

---

## 12. Audio & Visual Polish

### 12.1 Sound Effects
- Weapon swing/hit sounds (unique per weapon type)
- Kill confirmation sound
- Coin pickup sound
- UI click/hover sounds
- Arena-specific ambient sounds (lava bubbling, jungle birds, maze echoes)
- Victory emote sounds

### 12.2 Visual Effects
- Hit particles (blood-free: sparks, energy flashes)
- Weapon trail effects on swings
- Kill effect (enemy fades/dissolves)
- Coin popup (+10 floating text)
- Arena-specific particles (embers in Lava Forge, fireflies in Jungle Ruins)

---

## 13. Admin System

Admins are special players with overpowered abilities who play in normal matches alongside regular players. Admin status is defined by a server-side whitelist of UserIds. Admins select a **template** when joining, which grants them a unique weapon loadout and exclusive abilities.

### 13.1 Admin Detection & Setup
- Admin UserIds are stored in a server-side whitelist table (not accessible to clients)
- On join, server checks if the player's UserId is in the whitelist
- If admin, a **template selection UI** appears before entering matchmaking
- Admins are visually distinguished (e.g., name tag color, subtle aura) so players know they're fighting an admin
- Admin kills do **not** count toward the global leaderboard (to keep it fair)
- Admin abilities are **unlimited use, no cooldowns, no restrictions**

### 13.2 Template: Ethan

**Weapon:** Scythe (enhanced admin variant — retains all base Scythe stats + Soul Harvest perk at max tier, plus 4 exclusive abilities)

#### Ability 1 — Frost Strike
- **Input:** Press 1 (or ability slot keybind)
- **Effect:** The next scythe hit freezes the target in place for 10 seconds
- **Frozen State:** Target cannot move, attack, or use abilities. They can still take damage from other sources. A visible ice crystal effect encases them.
- **Restrictions:** None — unlimited use, no cooldown
- **Notes:** Frost effect is removed early if the frozen player dies

#### Ability 2 — Reverse Gravity
- **Input:** Press 2
- **Effect:** Gravity is reversed for the admin only, allowing them to float and walk on ceilings/in the air for 3 minutes
- **Movement:** Admin can freely move in all directions while floating (flight-like controls). Normal movement speed applies.
- **Combat:** Admin can still attack with the scythe while floating
- **Visual:** Purple/dark energy aura around the admin while gravity is reversed
- **End Condition:** After 3 minutes, gravity returns to normal. Admin can also press 2 again to cancel early.
- **Restrictions:** None — can be reactivated immediately after ending

#### Ability 3 — Meteorite
- **Input:** Press 3, then click on a target player or location
- **Effect:** A massive flaming meteorite falls from the sky and strikes the targeted area
- **Damage:** 80 damage on direct hit, 40 damage in splash radius (12 studs)
- **Impact Effects:** Screen shake for all nearby players. Leaves a burning crater that deals 5 damage/sec for 10 seconds to anyone standing in it.
- **Travel Time:** 1.5 seconds from activation to impact (target can try to dodge)
- **Visual:** Fiery trail across the sky, explosion on impact with debris particles
- **Restrictions:** None — unlimited use, no cooldown

#### Ability 4 — Shapeshift
- **Input:** Press 4 to open the Shapeshift selection menu
- **Menu:** Radial or grid menu showing all 5 animal forms. Click to transform. Press 4 again or select "Human" to revert.
- **General Rules:**
  - Admin retains the scythe in all animal forms (adjusted animation per form)
  - Transformation is instant with a burst particle effect
  - Admin can switch between forms freely at any time
  - Each form changes the character model, size, speed, damage, and grants a unique attack

#### Animal Forms

**Lion**
- Speed: +20% movement speed
- Damage: +30% scythe damage (36 per swing)
- Size: 1.3x scale (larger, more imposing)
- Unique Attack: **Pounce** — lunge forward 15 studs and deal 45 damage to the first enemy hit. Brief animation lock on landing.

**Tiger**
- Speed: +35% movement speed
- Damage: +20% scythe damage (34 per swing)
- Size: 1.2x scale
- Unique Attack: **Double Claw Swipe** — two rapid claw slashes dealing 20 damage each (40 total). Faster than a normal scythe swing. Short range (4 studs).

**Wolf**
- Speed: +50% movement speed
- Damage: +10% scythe damage (31 per swing)
- Size: 0.9x scale (slightly smaller, harder to hit)
- Unique Attack: **Howl** — AoE howl in a 15-stud radius. All enemies in range are slowed by 40% for 4 seconds. Visual sound wave effect.

**Leopard**
- Speed: +60% movement speed (fastest form)
- Damage: +15% scythe damage (32 per swing)
- Size: 0.8x scale (smallest form, hardest to hit)
- Unique Attack: **Stealth** — become semi-invisible (80% transparency) for 6 seconds. Attacking breaks stealth early.

**Gorilla**
- Speed: +5% movement speed (slowest form)
- Damage: +50% scythe damage (42 per swing)
- Size: 1.8x scale (massive, intimidating)
- Unique Attack: **Ground Pound** — leap into the air and slam down, dealing 50 damage in a 10-stud AoE radius and knocking all hit enemies into the air.

### 13.3 Admin HUD Additions
- **Ability Bar:** 4 ability slots shown at the bottom of the screen (keys 1–4) with icons for Frost Strike, Reverse Gravity, Meteorite, and Shapeshift
- **Current Form Indicator:** When shapeshifted, shows the current animal form icon and name
- **Admin Badge:** Small badge/icon next to the admin's name in the kill feed and scoreboard

### 13.4 Future Admin Templates
The admin system is designed to support multiple templates. Each template has a unique weapon and ability set. Additional templates (beyond Ethan) can be added by creating new entries in the admin configuration. Template structure:
```lua
AdminTemplates = {
    Ethan = {
        weapon = "Scythe",
        abilities = { "FrostStrike", "ReverseGravity", "Meteorite", "Shapeshift" },
        shapeshiftForms = { "Lion", "Tiger", "Wolf", "Leopard", "Gorilla" }
    },
    -- Future templates go here
}
```

---

## 14. MVP Scope & Development Priorities

### Phase 1 — Core Playable (MVP)
1. One arena (Classic Colosseum)
2. One game mode (Free-for-All)
3. One weapon (Sword — free starter)
4. Basic combat (swing, damage, kill, respawn)
5. Coin system (earn on kill)
6. Basic HUD (health, timer, kill feed)
7. Match flow (queue → fight → results)
8. DataStore (save coins and stats)

### Phase 2 — Progression & Content
1. Shop UI with all weapons (Axe, Bow, Scythe)
2. Weapon perks implemented
3. Weapon upgrades (Tier 2, Tier 3)
4. Second arena (Lava Forge)
5. Third arena (Shadow Maze)
6. Team Battles mode (2v2, 3v3)

### Phase 3 — Polish & Full Content
1. Fourth arena (Jungle Ruins)
2. Weapon skins shop
3. Victory emotes shop
4. Global leaderboard with rank titles
5. Admin system — Ethan template (Frost Strike, Reverse Gravity, Meteorite, Shapeshift)
6. Admin shapeshift animal forms (Lion, Tiger, Wolf, Leopard, Gorilla)
7. Audio & visual polish pass
8. Stamina system and dodge roll
9. Balancing and playtesting

---

## 15. Game Settings & Constants

```lua
-- Match Settings
MATCH_DURATION_FFA = 480           -- 8 minutes (seconds)
MATCH_DURATION_TEAM = 600          -- 10 minutes (seconds)
MAX_PLAYERS_FFA = 10
MAX_PLAYERS_2V2 = 4
MAX_PLAYERS_3V3 = 6
KILL_THRESHOLD_FFA = 25
KILL_THRESHOLD_2V2 = 40
KILL_THRESHOLD_3V3 = 50
RESPAWN_TIME_FFA = 3
RESPAWN_TIME_TEAM = 5
SPAWN_PROTECTION = 2               -- seconds of invulnerability

-- Player Stats
BASE_HEALTH = 100
HEALTH_REGEN_RATE = 2               -- HP per second
HEALTH_REGEN_DELAY = 5              -- seconds after last damage
BASE_WALK_SPEED = 16
SPRINT_MULTIPLIER = 1.5
MAX_STAMINA = 100
SPRINT_STAMINA_COST = 10            -- per second
DODGE_STAMINA_COST = 25
STAMINA_REGEN_RATE = 15             -- per second
DODGE_COOLDOWN = 3                  -- seconds
DODGE_INVINCIBILITY = 0.3           -- seconds

-- Economy
COINS_PER_KILL = 10
COINS_PER_ASSIST = 5
COINS_WIN_BONUS = 25
COINS_MATCH_COMPLETE = 10
ASSIST_DAMAGE_THRESHOLD = 0.3       -- 30% of max HP

-- Arena Events
LAVA_DAMAGE_PER_SEC = 10
LAVA_SHRINK_INTERVAL = 120          -- seconds
SHADOW_MAZE_VISION_RANGE = 20       -- studs
SHADOW_MAZE_WALL_SHIFT = 180        -- seconds
JUNGLE_DART_DAMAGE = 15
JUNGLE_LOG_DAMAGE = 25

-- Admin: Ethan Template
ADMIN_FROST_DURATION = 10            -- seconds
ADMIN_REVERSE_GRAVITY_DURATION = 180 -- 3 minutes (seconds)
ADMIN_METEORITE_DIRECT_DAMAGE = 80
ADMIN_METEORITE_SPLASH_DAMAGE = 40
ADMIN_METEORITE_SPLASH_RADIUS = 12   -- studs
ADMIN_METEORITE_TRAVEL_TIME = 1.5    -- seconds
ADMIN_METEORITE_CRATER_DPS = 5       -- damage per second
ADMIN_METEORITE_CRATER_DURATION = 10  -- seconds
ADMIN_STEALTH_DURATION = 6           -- seconds (Leopard)
ADMIN_STEALTH_TRANSPARENCY = 0.8
ADMIN_HOWL_SLOW_PERCENT = 0.4        -- 40% slow (Wolf)
ADMIN_HOWL_SLOW_DURATION = 4          -- seconds
ADMIN_HOWL_RADIUS = 15                -- studs

-- Admin: Shapeshift Form Stats (multipliers)
FORM_LION =    { speed = 1.2, damage = 1.3, scale = 1.3 }
FORM_TIGER =   { speed = 1.35, damage = 1.2, scale = 1.2 }
FORM_WOLF =    { speed = 1.5, damage = 1.1, scale = 0.9 }
FORM_LEOPARD = { speed = 1.6, damage = 1.15, scale = 0.8 }
FORM_GORILLA = { speed = 1.05, damage = 1.5, scale = 1.8 }
```

---

*This document serves as the complete specification for Warfront Legends. Use it as the reference for all implementation work in Roblox Studio with Claude Code.*
