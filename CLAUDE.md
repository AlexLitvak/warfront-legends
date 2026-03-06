# Warfront Legends — Roblox Game Project

## Language
This project uses Luau (not Lua 5.1, not JavaScript). Always write Luau code.

## Game Spec
Read `warfront-legends-game-spec.md` for the full game design specification.
Follow it closely for all game mechanics, values, and architecture decisions.

## Project Structure (Rojo)
- src/server/ → ServerScriptService (server-only scripts)
- src/client/ → StarterPlayerScripts (client-only scripts)  
- src/shared/ → ReplicatedStorage (shared modules)

## File Naming Convention
- *.server.luau → Server Script
- *.client.luau → Local Script
- *.luau → ModuleScript
- init.luau → The module becomes its parent folder

## Architecture Rules
- Server-authoritative combat: ALL damage calculations on the server
- Never trust client input — always validate on the server
- Use RemoteEvents for client → server communication
- Use RemoteFunctions only for data retrieval (shop, loadouts)
- Use ModuleScripts in src/shared/ for configs and shared logic

## Key Roblox Services
- Players, ReplicatedStorage, ServerScriptService, ServerStorage
- UserInputService (client only), TweenService, RunService
- DataStoreService (server only, for persistence)

## Luau Best Practices
- Use task.wait() instead of wait()
- Use task.spawn() instead of coroutine.wrap()
- Set Parent LAST when using Instance.new()
- Use typed Luau where possible (type annotations)
- Never store sensitive data in ReplicatedStorage

## Game-Specific Modules
- WeaponConfig.luau: All weapon stats, perks, upgrade tiers
- ArenaConfig.luau: Arena metadata, hazard settings, spawn points
- GameConfig.luau: Global constants (match time, coin rewards, etc.)
- Remotes.luau: All RemoteEvent/RemoteFunction definitions
