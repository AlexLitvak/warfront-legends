--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = {}

-- Container folder for all remotes
local remoteFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not remoteFolder then
	remoteFolder = Instance.new("Folder")
	remoteFolder.Name = "Remotes"
	remoteFolder.Parent = ReplicatedStorage
end

local function getOrCreate(className: string, name: string): Instance
	local existing = remoteFolder:FindFirstChild(name)
	if existing then
		return existing
	end
	local instance = Instance.new(className)
	instance.Name = name
	instance.Parent = remoteFolder
	return instance
end

-- RemoteEvents (client <-> server one-way communication)
Remotes.AttackInput = getOrCreate("RemoteEvent", "AttackInput") :: RemoteEvent
Remotes.DamageDealt = getOrCreate("RemoteEvent", "DamageDealt") :: RemoteEvent
Remotes.KillNotification = getOrCreate("RemoteEvent", "KillNotification") :: RemoteEvent
Remotes.CoinUpdate = getOrCreate("RemoteEvent", "CoinUpdate") :: RemoteEvent
Remotes.MatchStateChange = getOrCreate("RemoteEvent", "MatchStateChange") :: RemoteEvent
Remotes.PerkEffect = getOrCreate("RemoteEvent", "PerkEffect") :: RemoteEvent

Remotes.WeaponEquipped = getOrCreate("RemoteEvent", "WeaponEquipped") :: RemoteEvent
Remotes.TeamAssignment = getOrCreate("RemoteEvent", "TeamAssignment") :: RemoteEvent

-- RemoteFunctions (client -> server request/response)
Remotes.ShopPurchase = getOrCreate("RemoteFunction", "ShopPurchase") :: RemoteFunction
Remotes.LoadData = getOrCreate("RemoteFunction", "LoadData") :: RemoteFunction

return table.freeze(Remotes)
