--!strict
-- Shop ▸ the Robux column (right edge).
--
-- Two modes, selected by Config.FreePurchases:
--  * LIVE — every button routes through MarketplaceService prompts; the
--    server's ProcessReceipt fortress does the actual granting.
--  * FREE (testing) — buttons fire a 1-byte item id at the dev-only
--    "HT_DevShop" remote, which only exists while the flag is on.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local Theme = require(script.Parent.Theme)

local Shop = {}

local mk = Theme.mk

-- Item ids for FREE mode (mirrored in MonetizationService).
local ITEM_PARACHUTE = 1
local ITEM_VETO = 2
local ITEM_BRIBE_SMALL = 3
local ITEM_BRIBE_LARGE = 4
local ITEM_VIP = 5

type Entry = {
	Title: string,
	Blurb: string,
	ItemId: number, -- FREE-mode id
	ProductId: number, -- LIVE-mode DevProduct id (0 = gamepass instead)
	IsVIP: boolean,
}

-- `parent` is the right-rail stack container (UIListLayout drives placement).
function Shop.Build(parent: GuiObject): ()
	local player = Players.LocalPlayer
	local freeMode = Config.FreePurchases == true

	local devRemote: RemoteEvent? = nil
	local freeBuf = buffer.create(1)
	if freeMode then
		devRemote = ReplicatedStorage:WaitForChild("HT_DevShop") :: RemoteEvent
	end

	local function purchase(entry: Entry): ()
		if freeMode and devRemote ~= nil then
			buffer.writeu8(freeBuf, 0, entry.ItemId)
			devRemote:FireServer(freeBuf)
		elseif entry.IsVIP then
			MarketplaceService:PromptGamePassPurchase(player, Config.VIPGamePassId)
		else
			MarketplaceService:PromptProductPurchase(player, entry.ProductId)
		end
	end

	local entries: { Entry } = {
		{
			Title = "🪂 Golden Parachute",
			Blurb = "Survive one lethal event",
			ItemId = ITEM_PARACHUTE,
			ProductId = Config.Products.GoldenParachute,
			IsVIP = false,
		},
		{
			Title = "⚖ Board Veto",
			Blurb = "Force your event. No vote.",
			ItemId = ITEM_VETO,
			ProductId = Config.Products.BoardVeto,
			IsVIP = false,
		},
		{
			Title = "💰 Bribe Fund",
			Blurb = `+{Theme.money(Config.BribeAmounts.Small)} Cash`,
			ItemId = ITEM_BRIBE_SMALL,
			ProductId = Config.Products.BribeSmall,
			IsVIP = false,
		},
		{
			Title = "💎 War Chest",
			Blurb = `+{Theme.money(Config.BribeAmounts.Large)} Cash`,
			ItemId = ITEM_BRIBE_LARGE,
			ProductId = Config.Products.BribeLarge,
			IsVIP = false,
		},
		{
			Title = "⭐ VIP Lounge",
			Blurb = "2x earnings, high ground",
			ItemId = ITEM_VIP,
			ProductId = 0,
			IsVIP = true,
		},
	}

	local column = mk("Frame", {
		Name = "Shop",
		LayoutOrder = 1,
		Size = UDim2.fromOffset(212, 44 + #entries * 62),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.15,
	}, parent) :: Frame
	Theme.corner(10, column)
	Theme.stroke(Theme.Gold, 1.4, column)

	mk("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 4),
		Size = UDim2.new(1, 0, 0, 20),
		Font = Theme.SerifBold,
		Text = "BOARDROOM SHOP",
		TextColor3 = Theme.Gold,
		TextSize = 14,
	}, column)
	mk("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 22),
		Size = UDim2.new(1, 0, 0, 16),
		Font = Theme.Serif,
		Text = if freeMode then "· TEST MODE — ALL FREE ·" else "",
		TextColor3 = Theme.Danger,
		TextSize = 12,
	}, column)

	for i, entry in entries do
		local button = mk("TextButton", {
			Name = entry.Title,
			Position = UDim2.fromOffset(10, 44 + (i - 1) * 62),
			Size = UDim2.new(1, -20, 0, 54),
			BackgroundColor3 = Theme.PanelLight,
			Text = "",
			AutoButtonColor = true,
		}, column) :: TextButton
		Theme.corner(8, button)

		mk("TextLabel", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(10, 6),
			Size = UDim2.new(1, -20, 0, 20),
			Font = Theme.SerifBold,
			Text = entry.Title,
			TextColor3 = Theme.Ivory,
			TextSize = 15,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, button)
		mk("TextLabel", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(10, 28),
			Size = UDim2.new(1, -20, 0, 18),
			Font = Theme.Serif,
			Text = if freeMode then entry.Blurb .. "  (FREE)" else entry.Blurb,
			TextColor3 = Theme.Muted,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, button)

		button.Activated:Connect(function()
			purchase(entry)
		end)

		if entry.IsVIP then
			-- hide the VIP pitch once it's owned (server sets the attribute)
			local function refresh(): ()
				button.Visible = player:GetAttribute("VIP") ~= true
			end
			player:GetAttributeChangedSignal("VIP"):Connect(refresh)
			refresh()
		end
	end
end

return Shop
