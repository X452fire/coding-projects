--!strict
-- GameConfig ▸ Single source of truth for every tunable constant.
-- The entire tree is deep-frozen at require time: any accidental write from
-- anywhere in the codebase throws immediately instead of silently corrupting
-- live state. Types are exported so every consumer gets full inference.
-- Lives in ReplicatedStorage: the client renders spin odds and shop catalogs
-- straight from here, so what's disclosed is exactly what the server rolls.

export type MinigameDef = {
	Id: number,
	Name: string,
	Multiplier: number, -- payout multiplier for surviving backers
	Duration: number, -- Simulating phase length for this game (dynamic)
}

export type StateDurations = {
	Lobby: number,
	Teleporting: number,
	Simulating: number, -- fallback only; the winning minigame's Duration rules
	Payout: number,
	Revert: number,
}

export type ProductIds = {
	GoldenParachute: number,
	BoardVeto: number,
	BribeSmall: number,
	BribeLarge: number,
	SuperSpin: number,
}

export type ShopItemDef = {
	Name: string,
	Blurb: string,
	Cost: number,
	Kind: "Tool" | "Speed",
	Amount: number?, -- Speed: WalkSpeed added per tier
	MaxTier: number?, -- Speed: purchase cap
}

export type ItemDef = {
	Name: string,
	Kind: "Buff" | "Tool",
	Blurb: string,
	Tier: string,
}

export type SpinOutcome = {
	Name: string,
	Weight: number, -- weights sum to 100 ⇒ Weight IS the disclosed percent
	Kind: "Cash" | "Item",
	Amount: number?, -- Cash: payout
	ItemId: string?, -- Item: catalog key
	Tier: string,
}

local Config = {
	-- ── State machine (seconds). Simulating stretches per minigame. ──────
	StateDurations = {
		Lobby = 30,
		Teleporting = 2,
		Simulating = 20, -- fallback if a minigame def is missing
		Payout = 3,
		Revert = 3,
	} :: StateDurations,

	-- ── Economy ──────────────────────────────────────────────────────────
	StartingCash = 25,
	PassiveIncomePerSecond = 1,
	VIPIncomeMultiplier = 2,
	VIPLoungeTag = "VIPLounge",
	FlatSurvivalBonus = 50, -- survivors who did NOT back the winning game
	MaxStreak = 250,
	BaseWalkSpeed = 16, -- server-authoritative movement baseline
	SwiftnessBonus = 6, -- buff_swift WalkSpeed bonus for one round

	-- ── Networking (binary protocol) ─────────────────────────────────────
	BidPacketSize = 5, -- [u8 optionIndex][u32 amount]
	RateLimitPerSecond = 4,

	-- ── Monetization (replace with live DeveloperProduct ids) ────────────
	Products = {
		GoldenParachute = 1234561, -- 49 R$: 15s ForceField
		BoardVeto = 1234562, -- 99 R$: force the round's minigame
		BribeSmall = 1234563, -- Bribe Funds: +1,000 Cash
		BribeLarge = 1234564, -- Bribe Funds: +10,000 Cash
		SuperSpin = 1234565, -- premium Mystery Spin (policy-gated)
	} :: ProductIds,
	BribeAmounts = { Small = 1000, Large = 10000 },
	GoldenParachuteDuration = 15,
	VIPGamePassId = 123456789,
	StudioFreeVIP = true,
	-- TESTING ONLY: shop buttons grant instantly for free, no Robux prompt.
	-- ⚠ MUST be false before shipping.
	FreePurchases = true,

	-- ── Minigames (index == Id; MinigameService registry order matches) ──
	Minigames = {
		{ Id = 1, Name = "Rising Lava", Multiplier = 2.0, Duration = 30 },
		{ Id = 2, Name = "Security Laser Grid", Multiplier = 2.5, Duration = 40 },
		{ Id = 3, Name = "Falling Vaults", Multiplier = 3.0, Duration = 30 },
		{ Id = 4, Name = "Bomb Tag", Multiplier = 2.5, Duration = 45 },
		{ Id = 5, Name = "Market Crash", Multiplier = 2.0, Duration = 60 },
		{ Id = 6, Name = "Bull & Bear", Multiplier = 2.5, Duration = 50 },
		{ Id = 7, Name = "Golden Parachute", Multiplier = 3.0, Duration = 60 },
		{ Id = 8, Name = "Asset Freeze", Multiplier = 2.0, Duration = 50 },
	} :: { MinigameDef },

	-- ── In-game cash shop (non-Robux; server-authoritative) ──────────────
	ShopItems = {
		knockback_baton = {
			Name = "Executive Baton",
			Blurb = "Shove rivals into danger",
			Cost = 400,
			Kind = "Tool",
		} :: ShopItemDef,
		gravity_coil = {
			Name = "Anti-Grav Coil",
			Blurb = "Low gravity while equipped",
			Cost = 650,
			Kind = "Tool",
		} :: ShopItemDef,
		speed_boost = {
			Name = "Italian Loafers",
			Blurb = "+4 WalkSpeed, permanent",
			Cost = 1000,
			Kind = "Speed",
			Amount = 4,
			MaxTier = 3,
		} :: ShopItemDef,
	} :: { [string]: ShopItemDef },
	ShopOrder = { "knockback_baton", "gravity_coil", "speed_boost" },

	-- ── Inventory catalog (persisted; ItemOrder is the serialization order:
	--    NEVER reorder existing entries, only append) ──────────────────────
	Items = {
		buff_swift = { Name = "Swiftness Serum", Kind = "Buff", Blurb = "+6 WalkSpeed for one round", Tier = "Common" } :: ItemDef,
		buff_shield = { Name = "Legal Shield", Kind = "Buff", Blurb = "ForceField at round start", Tier = "Common" } :: ItemDef,
		sword_common = { Name = "Letter Opener", Kind = "Tool", Blurb = "A pointed negotiation aid", Tier = "Common" } :: ItemDef,
		sword_rare = { Name = "Gilded Saber", Kind = "Tool", Blurb = "Boardroom dueling, refined", Tier = "Rare" } :: ItemDef,
		sword_epic = { Name = "Chairman's Greatsword", Kind = "Tool", Blurb = "The final word in negotiations", Tier = "Epic" } :: ItemDef,
	} :: { [string]: ItemDef },
	ItemOrder = { "buff_swift", "buff_shield", "sword_common", "sword_rare", "sword_epic" },

	-- ── Mystery Spin (all rolls server-side; weights sum 100 = percent) ──
	StandardSpinCost = 100,
	StandardSpin = {
		{ Name = "Market Correction", Weight = 30, Kind = "Cash", Amount = 0, Tier = "Loss" },
		{ Name = "Partial Refund", Weight = 30, Kind = "Cash", Amount = 90, Tier = "Loss" },
		{ Name = "Insider Tip", Weight = 15, Kind = "Cash", Amount = 150, Tier = "Common" },
		{ Name = "Swiftness Serum", Weight = 12, Kind = "Item", ItemId = "buff_swift", Tier = "Common" },
		{ Name = "Legal Shield", Weight = 8, Kind = "Item", ItemId = "buff_shield", Tier = "Common" },
		{ Name = "Letter Opener", Weight = 4, Kind = "Item", ItemId = "sword_common", Tier = "Common" },
		{ Name = "Gilded Saber", Weight = 1, Kind = "Item", ItemId = "sword_rare", Tier = "Rare" },
	} :: { SpinOutcome },
	SuperSpin = {
		{ Name = "Golden Handshake", Weight = 40, Kind = "Cash", Amount = 500, Tier = "Good" },
		{ Name = "Gilded Saber", Weight = 30, Kind = "Item", ItemId = "sword_rare", Tier = "Good" },
		{ Name = "Chairman's Greatsword", Weight = 22, Kind = "Item", ItemId = "sword_epic", Tier = "Great" },
		{ Name = "HOSTILE TAKEOVER", Weight = 8, Kind = "Cash", Amount = 5000, Tier = "Super" },
	} :: { SpinOutcome },
	SuperPityThreshold = 5, -- Nth super spin without a "Super" tier forces one

	-- ── Persistence ───────────────────────────────────────────────────────
	DataStoreName = "HostileTakeover_Profiles_v1",
	SessionLockTTL = 90,
}

-- Recursively freeze every sub-table so the whole config is immutable.
local function deepFreeze(t: { [any]: any }): ()
	for _, value in t do
		if type(value) == "table" and not table.isfrozen(value) then
			deepFreeze(value)
		end
	end
	table.freeze(t)
end
deepFreeze(Config)

export type Config = typeof(Config)
return Config
