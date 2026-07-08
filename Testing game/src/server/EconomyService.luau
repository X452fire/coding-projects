--!strict
-- EconomyService ▸ wallets, passive income, the round payout ledger, the
-- server-authoritative in-game cash shop, and movement-stat enforcement.
--
-- Hot-path design:
--  * ONE centralized Heartbeat accumulator drives income for the whole
--    server. No per-player loops, no per-player threads, ever.
--  * Alive players live in a DENSE array maintained with swap-remove, so
--    the income tick is a straight numeric `for` — zero hashing, zero
--    allocation per frame.
--  * Wallets are the live Profile references from DataService, so every
--    Cash mutation is automatically captured by the autosave cycle.
--
-- Payout ledger: every escrowed bid is recorded per-user, per-option.
-- SettleRound applies the strict formula for surviving backers:
--     (PersonalBid × MinigameMultiplier) + (TotalServerLossPool ÷ Survivors)
-- Survivors who didn't back the winner get the flat survival bonus.
--
-- Cash shop: the "RequestPurchase" RemoteFunction validates the item id
-- against the frozen catalog, checks the balance, deducts BEFORE granting,
-- and refunds if the grant throws. Movement stats bought here are re-
-- asserted server-side every second so client-side speed hacks are undone.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.GameConfig)
local DataService = require(script.Parent.DataService)
local InventoryService = require(script.Parent.InventoryService)
local TelemetryService = require(script.Parent.TelemetryService)

local EconomyService = {}

export type Wallet = DataService.Profile

local wallets: { [number]: Wallet } = {} -- userId → live profile ref
local vipZone: { [number]: boolean } = {} -- userId → inside a VIP lounge
local charConns: { [number]: { RBXScriptConnection } } = {}

-- Dense alive-player cache (swap-remove keeps it hole-free).
local alive: { Player? } = table.create(64)
local aliveSlot: { [number]: number } = {} -- userId → index in `alive`
local aliveCount = 0

local playersById: { [number]: Player } = {}
local passOwners: { [number]: boolean } = {} -- VIP Lounge gamepass owners

-- Round payout ledger: userId → per-option escrowed amounts [o1, o2, o3].
local roundBids: { [number]: { number } } = {}

local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude
overlapParams.FilterDescendantsInstances = {}

-- Push wallet state to replicated attributes — the client HUD reads these,
-- so the server never needs a dedicated "update my money" remote.
local function syncAttributes(userId: number): ()
	local player = playersById[userId]
	local w = wallets[userId]
	if player ~= nil and w ~= nil then
		player:SetAttribute("Cash", w.Cash)
		player:SetAttribute("Streak", w.Streak)
	end
end

-- ── Server-authoritative movement stats ──────────────────────────────────

local SPEED_PER_TIER = Config.ShopItems.speed_boost.Amount or 4

local function allowedWalkSpeed(userId: number): number
	local w = wallets[userId]
	local tier = if w ~= nil then w.SpeedTier else 0
	local speed = Config.BaseWalkSpeed + tier * SPEED_PER_TIER
	-- consumed Swiftness Serum: one-round bonus, cleared at Revert
	if InventoryService.HasActiveBuff(userId, "buff_swift") then
		speed += Config.SwiftnessBonus
	end
	return speed
end

-- Applied on spawn AND re-asserted every second (see the income tick): any
-- client-side WalkSpeed/jump tampering the server can see is stomped flat.
local function enforceMovementStats(player: Player): ()
	local character = player.Character
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid == nil then
		return
	end
	local allowed = allowedWalkSpeed(player.UserId)
	if humanoid.WalkSpeed ~= allowed then
		humanoid.WalkSpeed = allowed
	end
	if humanoid.UseJumpPower then
		if humanoid.JumpPower > 50 then
			humanoid.JumpPower = 50
		end
	elseif humanoid.JumpHeight > 7.2 then
		humanoid.JumpHeight = 7.2
	end
end

-- ── Alive cache ───────────────────────────────────────────────────────────

local function markAlive(player: Player): ()
	local userId = player.UserId
	if aliveSlot[userId] ~= nil or wallets[userId] == nil then
		return
	end
	aliveCount += 1
	alive[aliveCount] = player
	aliveSlot[userId] = aliveCount
end

local function markDead(player: Player): ()
	local userId = player.UserId
	local slot = aliveSlot[userId]
	if slot == nil then
		return
	end
	-- swap-remove: move the tail into the vacated slot
	local tail = alive[aliveCount] :: Player
	if tail ~= player then
		alive[slot] = tail
		aliveSlot[tail.UserId] = slot
	end
	alive[aliveCount] = nil -- release the ref so the Player object can GC
	aliveCount -= 1
	aliveSlot[userId] = nil

	local w = wallets[userId]
	if w ~= nil then
		w.Streak = 0 -- death breaks the survival streak
		syncAttributes(userId)
	end
end

-- Copy the alive list into a caller-owned buffer (StateController reuses
-- one preallocated array). Returns the count.
function EconomyService.GetAliveSnapshot(out: { Player }): number
	for i = 1, aliveCount do
		out[i] = alive[i] :: Player
	end
	return aliveCount
end

-- ── Public wallet API (single-VM Luau ⇒ these are atomic by construction:
--    nothing can interleave between the balance check and the debit) ──────

function EconomyService.GetCash(userId: number): number
	local w = wallets[userId]
	return if w ~= nil then w.Cash else 0
end

-- Escrow a bid. Returns false (no partial debit) on insufficient funds.
function EconomyService.TryWithdraw(userId: number, amount: number): boolean
	local w = wallets[userId]
	if w == nil or amount <= 0 or w.Cash < amount then
		return false
	end
	w.Cash -= amount
	syncAttributes(userId)
	return true
end

function EconomyService.Deposit(userId: number, amount: number): ()
	local w = wallets[userId]
	if w ~= nil and amount > 0 then
		w.Cash += amount
		w.TotalEarned += amount
		syncAttributes(userId)
	end
end

-- ── High-stakes payout ledger ─────────────────────────────────────────────

-- Called by StateController AFTER TryWithdraw succeeds: the escrowed stake
-- enters the round ledger.
function EconomyService.RecordBid(userId: number, optionIndex: number, amount: number): ()
	local options = roundBids[userId]
	if options == nil then
		options = table.create(3, 0)
		roundBids[userId] = options
	end
	options[optionIndex] += amount
	TelemetryService.Count("bids", amount)
end

function EconomyService.ResetRound(): ()
	table.clear(roundBids)
end

-- Payout state. `survivors[1..survivorCount]` were verified alive AND
-- inside the arena by StateController.
--
--   winning backer : floor(PersonalBid × Multiplier) + floor(LossPool ÷ Survivors)
--   other survivor : FlatSurvivalBonus
--   the dead       : their escrow stays in the pool (that's the loss pool)
--
-- LossPool = every escrowed coin this round MINUS the winning survivors'
-- own stakes (those are returned inside the multiplied payout, not lost).
function EconomyService.SettleRound(
	winningOption: number,
	multiplier: number,
	survivors: { Player },
	survivorCount: number
): ()
	if winningOption < 1 or winningOption > 3 then
		table.clear(roundBids)
		return
	end

	local totalPool = 0
	for _, options in roundBids do
		totalPool += options[1] + options[2] + options[3]
	end

	local backersStakeSum = 0
	for i = 1, survivorCount do
		local options = roundBids[survivors[i].UserId]
		if options ~= nil then
			backersStakeSum += options[winningOption]
		end
	end

	local lossPool = totalPool - backersStakeSum
	local share = if survivorCount > 0 then lossPool // survivorCount else 0

	for i = 1, survivorCount do
		local player = survivors[i]
		local userId = player.UserId
		local options = roundBids[userId]
		local stake = if options ~= nil then options[winningOption] else 0
		local payout = if stake > 0
			then (stake * multiplier) // 1 + share
			else Config.FlatSurvivalBonus

		local w = wallets[userId]
		if w ~= nil then
			w.Streak = math.min(w.Streak + 1, Config.MaxStreak)
			w.Cash += payout
			w.TotalEarned += payout
			syncAttributes(userId)
			TelemetryService.Log("payout", userId, payout)
		end
	end

	table.clear(roundBids)
end

-- ── VIP Lounge gamepass (set by VIPService; gates the 2x zone) ───────────

function EconomyService.SetVIPPass(userId: number, owned: boolean): ()
	passOwners[userId] = if owned then true else nil
	local player = playersById[userId] or Players:GetPlayerByUserId(userId)
	if player ~= nil then
		player:SetAttribute("VIP", owned) -- client shop hides the buy button
	end
end

function EconomyService.HasVIPPass(userId: number): boolean
	return passOwners[userId] == true
end

-- ── In-game cash shop: tool builders ─────────────────────────────────────
-- Tools are built server-side with their behavior connected server-side —
-- no scripts inside the tool, nothing for a client to tamper with.

local function buildKnockbackBaton(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "Executive Baton"
	tool.CanBeDropped = false

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.6, 4, 0.6)
	handle.Material = Enum.Material.Metal
	handle.Color = Color3.fromRGB(212, 175, 55)
	handle.Parent = tool

	local lastSwing = 0
	tool.Activated:Connect(function()
		local now = os.clock()
		if now - lastSwing < 2 then
			return -- swing cooldown
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
		-- shove everyone in a short frontal cone
		for _, other in Players:GetPlayers() do
			local otherCharacter = other.Character
			if otherCharacter ~= nil and otherCharacter ~= character then
				local otherRoot = otherCharacter:FindFirstChild("HumanoidRootPart")
				if otherRoot ~= nil and otherRoot:IsA("BasePart") then
					local delta = otherRoot.Position - origin
					local distance = delta.Magnitude
					if distance > 0.1 and distance < 12 and delta.Unit:Dot(look) > 0.25 then
						local shove = (delta.Unit + Vector3.yAxis).Unit
						otherRoot:ApplyImpulse(shove * otherRoot.AssemblyMass * 45)
					end
				end
			end
		end
	end)
	return tool
end

local function buildGravityCoil(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "Anti-Grav Coil"
	tool.CanBeDropped = false

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(1, 3, 1)
	handle.Material = Enum.Material.Neon
	handle.Color = Color3.fromRGB(80, 200, 220)
	handle.Parent = tool

	-- while equipped: counteract 55% of gravity on the whole assembly
	local force: VectorForce? = nil
	local attachment: Attachment? = nil

	local function clearForce(): ()
		if force ~= nil then
			force:Destroy()
			force = nil
		end
		if attachment ~= nil then
			attachment:Destroy()
			attachment = nil
		end
	end

	tool.Equipped:Connect(function()
		clearForce()
		local character = tool.Parent
		if character == nil or not character:IsA("Model") then
			return
		end
		local root = character:FindFirstChild("HumanoidRootPart")
		if root == nil or not root:IsA("BasePart") then
			return
		end
		local att = Instance.new("Attachment")
		att.Parent = root
		local vf = Instance.new("VectorForce")
		vf.Attachment0 = att
		vf.RelativeTo = Enum.ActuatorRelativeTo.World
		vf.Force = Vector3.new(0, root.AssemblyMass * workspace.Gravity * 0.55, 0)
		vf.Parent = root
		attachment = att
		force = vf
	end)
	tool.Unequipped:Connect(clearForce)
	tool.Destroying:Connect(clearForce)
	return tool
end

local function grantTool(player: Player, tool: Tool): ()
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack == nil then
		tool:Destroy()
		error("no backpack to receive the tool")
	end
	tool.Parent = backpack
end

local function grantItem(player: Player, itemId: string, item: Config.ShopItemDef): ()
	if itemId == "knockback_baton" then
		grantTool(player, buildKnockbackBaton())
	elseif itemId == "gravity_coil" then
		grantTool(player, buildGravityCoil())
	elseif item.Kind == "Speed" then
		local w = wallets[player.UserId]
		if w == nil then
			error("wallet vanished mid-purchase")
		end
		w.SpeedTier += 1 -- persisted via the profile (survives rejoins)
		player:SetAttribute("SpeedTier", w.SpeedTier)
		enforceMovementStats(player) -- apply immediately
	else
		error(`no grant path for item '{itemId}'`)
	end
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────

function EconomyService.Register(player: Player, profile: DataService.Profile): ()
	local userId = player.UserId
	wallets[userId] = profile
	playersById[userId] = player
	syncAttributes(userId)
	player:SetAttribute("SpeedTier", profile.SpeedTier)

	local conns = table.create(1) :: { RBXScriptConnection }
	conns[1] = player.CharacterAdded:Connect(function(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid ~= nil and humanoid:IsA("Humanoid") then
			markAlive(player)
			enforceMovementStats(player) -- purchased speed applies on spawn
			InventoryService.EquipBest(player) -- best owned sword on spawn
			humanoid.Died:Once(function()
				markDead(player)
			end)
		end
	end)
	charConns[userId] = conns

	-- character may already exist by the time the profile lock resolves
	local existing = player.Character
	if existing ~= nil then
		local humanoid = existing:FindFirstChildOfClass("Humanoid")
		if humanoid ~= nil and humanoid.Health > 0 then
			markAlive(player)
			enforceMovementStats(player)
			humanoid.Died:Once(function()
				markDead(player)
			end)
		end
	end
end

function EconomyService.Unregister(player: Player): ()
	local userId = player.UserId
	markDead(player)
	local conns = charConns[userId]
	if conns ~= nil then
		for i = 1, #conns do
			conns[i]:Disconnect()
		end
		charConns[userId] = nil
	end
	wallets[userId] = nil
	vipZone[userId] = nil
	playersById[userId] = nil
	passOwners[userId] = nil
	roundBids[userId] = nil
end

-- 1 Hz spatial scan of tagged lounge volumes. Overlap queries are cheap at
-- this cadence and avoid per-player Touched bookkeeping entirely.
local function updateVIPZones(): ()
	table.clear(vipZone)
	local lounges = CollectionService:GetTagged(Config.VIPLoungeTag)
	for i = 1, #lounges do
		local lounge = lounges[i]
		if lounge:IsA("BasePart") then
			local hits = workspace:GetPartBoundsInBox(lounge.CFrame, lounge.Size, overlapParams)
			for j = 1, #hits do
				local model = hits[j].Parent
				if model ~= nil then
					local occupant = Players:GetPlayerFromCharacter(model :: Model)
					if occupant ~= nil then
						vipZone[occupant.UserId] = true
					end
				end
			end
		end
	end
end

function EconomyService.Init(): ()
	-- ── The cash shop RemoteFunction ("RequestPurchase") ──────────────────
	local shopDebounce: { [number]: number } = {}
	local requestPurchase = Instance.new("RemoteFunction")
	requestPurchase.Name = "RequestPurchase"
	requestPurchase.Parent = ReplicatedStorage
	requestPurchase.OnServerInvoke = function(player: Player, itemId: unknown): (boolean, string)
		-- a) id must be a string AND exist in the frozen catalog
		if type(itemId) ~= "string" then
			return false, "Invalid request"
		end
		local item = Config.ShopItems[itemId]
		if item == nil then
			return false, "Unknown item"
		end

		local now = os.clock()
		if now - (shopDebounce[player.UserId] or 0) < 0.5 then
			return false, "Slow down"
		end
		shopDebounce[player.UserId] = now

		local w = wallets[player.UserId]
		if w == nil then
			return false, "Profile still loading"
		end
		if item.Kind == "Speed" and w.SpeedTier >= (item.MaxTier or 1) then
			return false, "Already at max tier"
		end

		-- b) balance check  c) deduct BEFORE granting (single-VM: atomic)
		if w.Cash < item.Cost then
			return false, "Insufficient funds"
		end
		w.Cash -= item.Cost
		syncAttributes(player.UserId)

		-- d) grant; refund the deduction if anything throws
		local ok, err = pcall(grantItem, player, itemId, item)
		if not ok then
			w.Cash += item.Cost
			syncAttributes(player.UserId)
			warn(`[Shop] grant '{itemId}' failed: {err}`)
			return false, "Purchase failed — refunded"
		end
		TelemetryService.Count("shop_spend", item.Cost)
		TelemetryService.Log("shop_buy", player.UserId, item.Cost)
		return true, `{item.Name} acquired`
	end

	-- ── The income + enforcement tick ─────────────────────────────────────
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < 1 then
			return
		end
		acc -= 1 -- carry the remainder: no drift over long sessions
		updateVIPZones()
		local base = Config.PassiveIncomePerSecond
		local vipMult = Config.VIPIncomeMultiplier
		for i = 1, aliveCount do
			local player = alive[i] :: Player
			local userId = player.UserId
			local w = wallets[userId]
			if w ~= nil then
				-- 2x requires BOTH the gamepass and standing in the lounge
				local gain = if vipZone[userId] and passOwners[userId] then base * vipMult else base
				w.Cash += gain
				w.TotalEarned += gain
				syncAttributes(userId)
				TelemetryService.Count("income", gain)
			end
			-- anti-exploit: re-assert movement stats every second, always —
			-- including during minigame execution
			enforceMovementStats(player)
		end
	end)
end

return EconomyService
