--!strict
-- InventoryService ▸ persistent item inventory + round buff consumption.
--
-- Storage: item counts live inside the bit-packed profile (DataService
-- schema v3), keyed by Config.Items / serialized via Config.ItemOrder.
-- Counts replicate to the client as "Inv_<itemId>" attributes — no
-- dedicated inventory remote traffic at all.
--
-- Buffs: the client fires "ConsumeBuff" (BufferNetwork string payload).
-- The server validates ownership + kind, decrements the persistent count,
-- and raises a SESSION flag. Flags are read during the round (Swiftness →
-- EconomyService's allowed WalkSpeed; Legal Shield → ForceField applied by
-- StateController at Simulating) and wiped in the Revert phase.
--
-- Swords: permanent Tool items. The best owned tier is granted on every
-- spawn; behavior is connected server-side (no scripts inside the Tool).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.GameConfig)
local BufferNetwork = require(ReplicatedStorage.Shared.BufferNetwork)
local DataService = require(script.Parent.DataService)
local TelemetryService = require(script.Parent.TelemetryService)

local InventoryService = {}

-- session flags: userId → itemId → active this round
local activeBuffs: { [number]: { [string]: boolean } } = {}
local consumeDebounce: { [number]: number } = {}

-- sword tiers, weakest → strongest (grant logic picks the best owned)
type SwordStats = { Damage: number, Range: number, Cooldown: number }
local SWORD_ORDER = table.freeze({ "sword_epic", "sword_rare", "sword_common" })
local SWORD_STATS: { [string]: SwordStats } = table.freeze({
	sword_common = { Damage = 10, Range = 9, Cooldown = 1.2 } :: SwordStats,
	sword_rare = { Damage = 16, Range = 10, Cooldown = 1.0 } :: SwordStats,
	sword_epic = { Damage = 25, Range = 11, Cooldown = 0.9 } :: SwordStats,
})
local SWORD_COLORS: { [string]: Color3 } = table.freeze({
	sword_common = Color3.fromRGB(190, 190, 195),
	sword_rare = Color3.fromRGB(212, 175, 55),
	sword_epic = Color3.fromRGB(150, 80, 220),
})

local function syncItemAttribute(player: Player, itemId: string): ()
	local profile = DataService.GetProfile(player.UserId)
	if profile ~= nil then
		player:SetAttribute(`Inv_{itemId}`, profile.Inventory[itemId] or 0)
	end
end

-- ── Public inventory API ──────────────────────────────────────────────────

function InventoryService.GetCount(userId: number, itemId: string): number
	local profile = DataService.GetProfile(userId)
	return if profile ~= nil then profile.Inventory[itemId] or 0 else 0
end

function InventoryService.AddItem(userId: number, itemId: string, count: number): ()
	if Config.Items[itemId] == nil or count <= 0 then
		return
	end
	local profile = DataService.GetProfile(userId)
	if profile == nil then
		return
	end
	profile.Inventory[itemId] = (profile.Inventory[itemId] or 0) + count
	local player = Players:GetPlayerByUserId(userId)
	if player ~= nil then
		syncItemAttribute(player, itemId)
	end
	TelemetryService.Log("item_granted", userId, count)
end

function InventoryService.HasActiveBuff(userId: number, itemId: string): boolean
	local flags = activeBuffs[userId]
	return flags ~= nil and flags[itemId] == true
end

-- ── Round lifecycle (driven by StateController) ──────────────────────────

-- Simulating entry: materialize consumed buffs that need a physical effect.
-- Swiftness needs nothing here — EconomyService reads the flag every stat
-- re-assertion tick.
function InventoryService.ApplyRoundBuffs(players: { Player }, count: number): ()
	for i = 1, count do
		local player = players[i]
		if InventoryService.HasActiveBuff(player.UserId, "buff_shield") then
			local character = player.Character
			if character ~= nil then
				local shield = Instance.new("ForceField")
				shield.Name = "LegalShield"
				shield.Visible = true
				shield.Parent = character
				game:GetService("Debris"):AddItem(shield, 10)
			end
		end
	end
end

-- Revert phase: every session buff expires, spent or not.
function InventoryService.ClearRoundBuffs(): ()
	for userId, flags in activeBuffs do
		local player = Players:GetPlayerByUserId(userId)
		for itemId in flags do
			if player ~= nil then
				player:SetAttribute(`Buff_{itemId}`, nil) -- disarm the UI pip
			end
		end
		table.clear(flags)
	end
end

-- ── Sword tools ───────────────────────────────────────────────────────────

local function buildSword(itemId: string): Tool
	local stats = SWORD_STATS[itemId]
	local def = Config.Items[itemId]
	local tool = Instance.new("Tool")
	tool.Name = def.Name
	tool.CanBeDropped = false

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.5, 5, 0.5)
	handle.Material = Enum.Material.Metal
	handle.Color = SWORD_COLORS[itemId]
	handle.Parent = tool

	local lastSwing = 0
	tool.Activated:Connect(function()
		local now = os.clock()
		if now - lastSwing < stats.Cooldown then
			return
		end
		lastSwing = now
		local character = tool.Parent
		if character == nil or not character:IsA("Model") then
			return
		end
		local root = character:FindFirstChild("HumanoidRootPart")
		if root == nil or not root:IsA("BasePart") then
			return
		end
		local origin = root.Position
		local look = root.CFrame.LookVector
		-- server-side frontal arc: distance + facing, no client Touched
		for _, other in Players:GetPlayers() do
			local otherCharacter = other.Character
			if otherCharacter ~= nil and otherCharacter ~= character then
				local otherRoot = otherCharacter:FindFirstChild("HumanoidRootPart")
				if otherRoot ~= nil and otherRoot:IsA("BasePart") then
					local delta = otherRoot.Position - origin
					if delta.Magnitude < stats.Range and delta.Unit:Dot(look) > 0.35 then
						local humanoid = otherCharacter:FindFirstChildOfClass("Humanoid")
						if humanoid ~= nil and humanoid.Health > 0 then
							humanoid:TakeDamage(stats.Damage)
							otherRoot:ApplyImpulse(delta.Unit * otherRoot.AssemblyMass * 18)
						end
					end
				end
			end
		end
	end)
	return tool
end

-- Grant the strongest owned sword on spawn (called from EconomyService's
-- CharacterAdded hook). Idempotent: skips if the tool already exists.
function InventoryService.EquipBest(player: Player): ()
	local profile = DataService.GetProfile(player.UserId)
	if profile == nil then
		return
	end
	for _, itemId in SWORD_ORDER do
		if (profile.Inventory[itemId] or 0) > 0 then
			local def = Config.Items[itemId]
			local backpack = player:FindFirstChildOfClass("Backpack")
			if backpack == nil then
				return
			end
			local character = player.Character
			if backpack:FindFirstChild(def.Name) ~= nil
				or (character ~= nil and character:FindFirstChild(def.Name) ~= nil)
			then
				return -- already holding it
			end
			buildSword(itemId).Parent = backpack
			return
		end
	end
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────

function InventoryService.Register(player: Player): ()
	activeBuffs[player.UserId] = {}
	for _, itemId in Config.ItemOrder do
		syncItemAttribute(player, itemId)
	end
end

function InventoryService.Unregister(player: Player): ()
	activeBuffs[player.UserId] = nil
	consumeDebounce[player.UserId] = nil
end

function InventoryService.Init(): ()
	-- "ConsumeBuff" ▸ client → server, BufferNetwork string payload.
	local consumeRemote = Instance.new("RemoteEvent")
	consumeRemote.Name = "ConsumeBuff"
	consumeRemote.Parent = ReplicatedStorage

	consumeRemote.OnServerEvent:Connect(function(player: Player, data: unknown)
		local userId = player.UserId
		local now = os.clock()
		if now - (consumeDebounce[userId] or 0) < 0.5 then
			return
		end
		consumeDebounce[userId] = now

		if typeof(data) ~= "buffer" then
			return
		end
		local cursor = BufferNetwork.reader(data :: buffer)
		local itemId = BufferNetwork.readString(cursor)
		if itemId == nil then
			return
		end

		-- validate: real item, buff kind, owned, not already active
		local def = Config.Items[itemId :: string]
		if def == nil or def.Kind ~= "Buff" then
			return
		end
		local profile = DataService.GetProfile(userId)
		if profile == nil or (profile.Inventory[itemId :: string] or 0) < 1 then
			return
		end
		local flags = activeBuffs[userId]
		if flags == nil or flags[itemId :: string] then
			return -- one of each buff per round
		end

		profile.Inventory[itemId :: string] = (profile.Inventory[itemId :: string] or 0) - 1
		flags[itemId :: string] = true
		syncItemAttribute(player, itemId :: string)
		player:SetAttribute(`Buff_{itemId}`, true) -- UI shows it armed
		TelemetryService.Log("buff_consumed", userId, 1)
	end)
end

return InventoryService
