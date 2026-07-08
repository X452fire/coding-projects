--!strict
-- RewardRollService ▸ the "Mystery Spin" — standard (in-game cash) and
-- Super (Robux) rolls.
--
-- Compliance & security posture:
--  * ALL probabilities live in the shared, frozen GameConfig — the client
--    renders its odds table from the exact weights the server rolls with.
--    Weights sum to 100, so a weight IS the disclosed percent.
--  * Super Spins are paid random items: on join we ask PolicyService
--    whether ArePaidRandomItemsRestricted for this player, cache it, and
--    replicate it ("PaidRandomRestricted" attribute) so the client hides
--    the button. If a restricted player's receipt somehow arrives anyway,
--    they get a fixed NON-RANDOM cash bundle of honest value — never a roll.
--  * Robux flows through MarketplaceService:ProcessReceipt (Monetization's
--    fortress) which calls RollSuper here; a thrown error = receipt retry.
--  * Pity system: profile.Pity counts Super Spins since the last
--    "Super"-tier outcome; hitting SuperPityThreshold forces one.

local Players = game:GetService("Players")
local PolicyService = game:GetService("PolicyService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.GameConfig)
local BufferNetwork = require(ReplicatedStorage.Shared.BufferNetwork)
local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local InventoryService = require(script.Parent.InventoryService)
local TelemetryService = require(script.Parent.TelemetryService)

local RewardRollService = {}

local SPIN_STANDARD = 1
local SPIN_SUPER = 2
-- fixed-value fallback for policy-restricted players (never randomized)
local RESTRICTED_FALLBACK_CASH = 750

local rng = Random.new()
local spinDebounce: { [number]: number } = {}
local resultRemote: RemoteEvent? = nil

-- result packet: [u8 spinType][u8 outcomeIndex][u32 cashAwarded]
local resultWriter = BufferNetwork.writer(6)

local function fireResult(player: Player, spinType: number, outcomeIndex: number, cash: number): ()
	local remote = resultRemote
	if remote == nil then
		return
	end
	BufferNetwork.reset(resultWriter)
	BufferNetwork.writeU8(resultWriter, spinType)
	BufferNetwork.writeU8(resultWriter, outcomeIndex)
	BufferNetwork.writeU32(resultWriter, math.clamp(cash, 0, 4294967295))
	remote:FireClient(player, resultWriter.Buf)
end

-- Server-authoritative weighted pick. Weights sum to 100 by construction
-- (the same numbers the client displays), so one roll in [0, 100) walks
-- the cumulative table.
local function weightedPick(outcomes: { Config.SpinOutcome }): number
	local roll = rng:NextNumber(0, 100)
	local cumulative = 0
	for i = 1, #outcomes do
		cumulative += outcomes[i].Weight
		if roll < cumulative then
			return i
		end
	end
	return #outcomes -- float-edge fallback
end

local function grantOutcome(player: Player, outcome: Config.SpinOutcome): number
	if outcome.Kind == "Cash" then
		local amount = outcome.Amount or 0
		if amount > 0 then
			EconomyService.Deposit(player.UserId, amount)
			TelemetryService.Count("spin_award", amount)
		end
		return amount
	end
	local itemId = outcome.ItemId
	if itemId ~= nil then
		InventoryService.AddItem(player.UserId, itemId, 1)
	end
	return 0
end

-- ── Standard spin (100 in-game cash) ─────────────────────────────────────

local function rollStandard(player: Player): ()
	local userId = player.UserId
	if not EconomyService.TryWithdraw(userId, Config.StandardSpinCost) then
		return -- can't afford: client shows balance, no feedback needed
	end
	TelemetryService.Count("spin_spend", Config.StandardSpinCost)
	local index = weightedPick(Config.StandardSpin)
	local cash = grantOutcome(player, Config.StandardSpin[index])
	TelemetryService.Log("spin_standard", userId, cash)
	fireResult(player, SPIN_STANDARD, index, cash)
end

-- ── Super spin (Robux — invoked by MonetizationService's ProcessReceipt) ──
-- Throwing here bubbles into ProcessReceipt's pcall → receipt retries.

function RewardRollService.RollSuper(player: Player): ()
	local userId = player.UserId

	-- Restricted player paid anyway (should be unreachable — the client
	-- hides the button): grant a FIXED cash bundle, never a random roll.
	if player:GetAttribute("PaidRandomRestricted") == true then
		EconomyService.Deposit(userId, RESTRICTED_FALLBACK_CASH)
		TelemetryService.Log("spin_super_fallback", userId, RESTRICTED_FALLBACK_CASH)
		return
	end

	local profile = DataService.GetProfile(userId)
	if profile == nil then
		error("profile not loaded for super spin") -- receipt retries
	end

	local outcomes = Config.SuperSpin
	local index = weightedPick(outcomes)

	-- Pity system: force the first "Super"-tier outcome when the counter
	-- hits the threshold; any natural Super also resets it.
	if outcomes[index].Tier ~= "Super" then
		profile.Pity += 1
		if profile.Pity >= Config.SuperPityThreshold then
			for i = 1, #outcomes do
				if outcomes[i].Tier == "Super" then
					index = i
					break
				end
			end
		end
	end
	if outcomes[index].Tier == "Super" then
		profile.Pity = 0
	end

	local cash = grantOutcome(player, outcomes[index])
	TelemetryService.Log("spin_super", userId, cash)
	fireResult(player, SPIN_SUPER, index, cash)
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────

-- Resolve the paid-random-items policy once per player (yields; pcall'd).
-- Fail CLOSED: if the lookup errors, treat the player as restricted.
function RewardRollService.OnJoin(player: Player): ()
	local restricted = true
	local ok, policy = pcall(function()
		return PolicyService:GetPolicyInfoForPlayerAsync(player)
	end)
	if ok and type(policy) == "table" then
		restricted = (policy :: { [string]: any }).ArePaidRandomItemsRestricted == true
	end
	if player.Parent ~= nil then
		player:SetAttribute("PaidRandomRestricted", restricted)
	end
end

function RewardRollService.Init(): ()
	local result = Instance.new("RemoteEvent")
	result.Name = "HT_SpinResult"
	result.Parent = ReplicatedStorage
	resultRemote = result

	-- "HT_Spin" ▸ client → server: [u8 spinType]. Only STANDARD is accepted
	-- here — Super arrives exclusively through ProcessReceipt.
	local spin = Instance.new("RemoteEvent")
	spin.Name = "HT_Spin"
	spin.Parent = ReplicatedStorage
	spin.OnServerEvent:Connect(function(player: Player, data: unknown)
		local now = os.clock()
		if now - (spinDebounce[player.UserId] or 0) < 1 then
			return -- one spin per second, silently
		end
		spinDebounce[player.UserId] = now

		if typeof(data) ~= "buffer" or buffer.len(data :: buffer) ~= 1 then
			return
		end
		if buffer.readu8(data :: buffer, 0) == SPIN_STANDARD then
			rollStandard(player)
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		spinDebounce[player.UserId] = nil
	end)
end

return RewardRollService
