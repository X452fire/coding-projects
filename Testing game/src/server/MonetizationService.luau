--!strict
-- MonetizationService ▸ the ProcessReceipt fortress.
--
-- Invariants:
--  1. IDEMPOTENT — a PurchaseId is granted at most once. Roblox retries
--     receipts aggressively (rejoin, server crash, network flake); the
--     history gate answers Granted instantly on redelivery.
--  2. NEVER burn Robux — Granted is returned ONLY after the grant
--     provably succeeded. Every failure path is NotProcessedYet or an
--     error() (both cause Roblox to redeliver later).
--  3. RACE-SAFE — Board Veto bought on the exact tick the Auction flips to
--     Simulating hits StateController's transition lock and comes back
--     "Locked" → NotProcessedYet. The receipt retries; the player's veto is
--     honored in a later auction instead of vanishing.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.GameConfig)
local StateController = require(script.Parent.StateController)
local EconomyService = require(script.Parent.EconomyService)
local RewardRollService = require(script.Parent.RewardRollService)
local TelemetryService = require(script.Parent.TelemetryService)

-- Free-grant item ids for the FreePurchases test mode (mirrored in Shop.luau).
local ITEM_PARACHUTE = 1
local ITEM_VETO = 2
local ITEM_BRIBE_SMALL = 3
local ITEM_BRIBE_LARGE = 4
local ITEM_VIP = 5
local ITEM_SUPER_SPIN = 6

local MonetizationService = {}

-- L1 idempotency cache: PurchaseId → granted this session.
-- NOTE: a production deployment additionally persists recent PurchaseIds in
-- the player profile (ProfileService pattern) to dedupe across servers.
-- Within one server this cache is airtight because Luau is single-VM: no
-- two receipts can interleave between the check and the grant.
local purchaseHistory: { [string]: boolean } = {}

local function grantGoldenParachute(player: Player): ()
	local character = player.Character
	if character == nil then
		error("no character to shield") -- caught by pcall → receipt retries
	end
	local shield = Instance.new("ForceField")
	shield.Name = "GoldenParachute"
	shield.Visible = true
	shield.Parent = character
	-- Debris (not task.delay) so the timer survives this script erroring.
	Debris:AddItem(shield, Config.GoldenParachuteDuration)
end

-- TESTING ONLY ▸ FreePurchases mode. The "HT_DevShop" remote exists ONLY
-- while Config.FreePurchases is true — with the flag off (production) there
-- is nothing for an exploiter to fire. Grants reuse the exact same code
-- paths as real receipts, so testing exercises the real logic (the veto,
-- for example, still respects the auction race lock).
local function initFreeShop(): ()
	warn("[Monetization] FreePurchases is ON — shop grants are FREE. Disable before shipping!")

	local lastGrant: { [number]: number } = {} -- per-player debounce

	local devRemote = Instance.new("RemoteEvent")
	devRemote.Name = "HT_DevShop"
	devRemote.Parent = ReplicatedStorage

	devRemote.OnServerEvent:Connect(function(player: Player, data: unknown)
		local now = os.clock()
		if now - (lastGrant[player.UserId] or 0) < 0.5 then
			return
		end
		lastGrant[player.UserId] = now

		if typeof(data) ~= "buffer" then
			return
		end
		local b = data :: buffer
		if buffer.len(b) ~= 1 then
			return
		end
		local itemId = buffer.readu8(b, 0)

		local ok, err = pcall(function()
			if itemId == ITEM_PARACHUTE then
				grantGoldenParachute(player)
			elseif itemId == ITEM_VETO then
				StateController.TryVeto(player) -- "Locked" outside auctions, same as live
			elseif itemId == ITEM_BRIBE_SMALL then
				EconomyService.Deposit(player.UserId, Config.BribeAmounts.Small)
			elseif itemId == ITEM_BRIBE_LARGE then
				EconomyService.Deposit(player.UserId, Config.BribeAmounts.Large)
			elseif itemId == ITEM_VIP then
				EconomyService.SetVIPPass(player.UserId, true)
			elseif itemId == ITEM_SUPER_SPIN then
				RewardRollService.RollSuper(player)
			end
		end)
		if not ok then
			warn(`[Monetization] free grant {itemId} failed: {err}`)
		end
	end)
end

function MonetizationService.Init(): ()
	if Config.FreePurchases then
		initFreeShop()
	end

	MarketplaceService.ProcessReceipt = function(receiptInfo): Enum.ProductPurchaseDecision
		local purchaseId = receiptInfo.PurchaseId :: string

		-- ── Gate 1: already granted? Answer instantly, grant nothing twice. ──
		if purchaseHistory[purchaseId] then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end

		-- ── Gate 2: buyer must be present to receive anything. ──
		local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
		if player == nil then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		-- ── Gate 3: the grant itself, armored in pcall. ──
		local productId = receiptInfo.ProductId :: number
		local ok, decision = pcall(function(): Enum.ProductPurchaseDecision
			if productId == Config.Products.GoldenParachute then
				grantGoldenParachute(player)
				return Enum.ProductPurchaseDecision.PurchaseGranted
			elseif productId == Config.Products.BoardVeto then
				local verdict = StateController.TryVeto(player)
				if verdict == "Locked" then
					-- Race-condition lock: auction is mid-transition, closed,
					-- or inside the final safety window. Retry later rather
					-- than eat the veto.
					return Enum.ProductPurchaseDecision.NotProcessedYet
				end
				return Enum.ProductPurchaseDecision.PurchaseGranted
			elseif productId == Config.Products.BribeSmall then
				EconomyService.Deposit(player.UserId, Config.BribeAmounts.Small)
				return Enum.ProductPurchaseDecision.PurchaseGranted
			elseif productId == Config.Products.BribeLarge then
				EconomyService.Deposit(player.UserId, Config.BribeAmounts.Large)
				return Enum.ProductPurchaseDecision.PurchaseGranted
			elseif productId == Config.Products.SuperSpin then
				-- policy-gated paid random roll (restricted players receive
				-- a fixed-value bundle inside RollSuper — never a roll)
				RewardRollService.RollSuper(player)
				return Enum.ProductPurchaseDecision.PurchaseGranted
			end
			-- Unknown product id: never Granted (that would burn the receipt).
			warn(`[Monetization] unknown product {productId}`)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end)

		if not ok then
			-- Throwing out of ProcessReceipt makes Roblox redeliver the
			-- receipt later — exactly what we want on a failed grant.
			error(`[Monetization] grant failed for {purchaseId}: {tostring(decision)}`)
		end

		local finalDecision = decision :: Enum.ProductPurchaseDecision
		if finalDecision == Enum.ProductPurchaseDecision.PurchaseGranted then
			purchaseHistory[purchaseId] = true -- mark ONLY after success
			TelemetryService.Log("receipt", receiptInfo.PlayerId :: number, productId)
		end
		return finalDecision
	end
end

return MonetizationService
