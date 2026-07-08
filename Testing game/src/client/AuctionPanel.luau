--!strict
-- AuctionPanel ▸ the bidding console (bottom center, Auction phase only)
-- plus the live bid feed. Three disaster cards, a bid-amount stepper, and
-- per-card BID buttons that fire the binary protocol via the OnBid callback.

local Theme = require(script.Parent.Theme)

local AuctionPanel = {}

-- assigned by init.client: function(optionIndex, amount)
AuctionPanel.OnBid = nil :: ((optionIndex: number, amount: number) -> ())?

local mk = Theme.mk

local CARD_COUNT = 3
local FEED_LINES = 6
local BID_DEBOUNCE = 0.3 -- client courtesy; the server bucket is authority

local panel: Frame? = nil
local feedFrame: Frame? = nil
local amountLabel: TextLabel? = nil
local cardNames: { TextLabel } = table.create(CARD_COUNT)
local cardTotals: { TextLabel } = table.create(CARD_COUNT)
local feedLabels: { TextLabel } = table.create(FEED_LINES)

local bidAmount = 100
local lastBidAt = 0

local function refreshAmount(): ()
	local label = amountLabel
	if label ~= nil then
		label.Text = `BID AMOUNT  ·  {Theme.money(bidAmount)}`
	end
end

-- `feedParent` is the left-rail stack container: the feed occupies slot 3
-- there and the UIListLayout collapses it while it's hidden.
function AuctionPanel.Build(gui: ScreenGui, feedParent: GuiObject): ()
	local root = mk("Frame", {
		Name = "AuctionPanel",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -18),
		Size = UDim2.fromOffset(660, 210),
		BackgroundColor3 = Theme.Panel,
		Visible = false,
	}, gui) :: Frame
	panel = root
	Theme.corner(10, root)
	Theme.stroke(Theme.Gold, 1.6, root)

	mk("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 8),
		Size = UDim2.new(1, 0, 0, 20),
		Font = Theme.SerifBold,
		Text = "— THE BOARD WILL NOW TAKE BIDS —",
		TextColor3 = Theme.Gold,
		TextSize = 16,
	}, root)

	-- ── Three disaster cards ──────────────────────────────────────────────
	for i = 1, CARD_COUNT do
		local card = mk("Frame", {
			Name = `Card{i}`,
			Position = UDim2.fromOffset(14 + (i - 1) * 214, 34),
			Size = UDim2.fromOffset(202, 118),
			BackgroundColor3 = Theme.PanelLight,
		}, root) :: Frame
		Theme.corner(8, card)
		Theme.stroke(Theme.Muted, 1, card)

		cardNames[i] = mk("TextLabel", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(8, 8),
			Size = UDim2.new(1, -16, 0, 24),
			Font = Theme.SerifBold,
			Text = "…",
			TextColor3 = Theme.Ivory,
			TextSize = 20,
			TextScaled = false,
		}, card) :: TextLabel

		cardTotals[i] = mk("TextLabel", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(8, 36),
			Size = UDim2.new(1, -16, 0, 22),
			Font = Theme.Serif,
			Text = "$0",
			TextColor3 = Theme.Gold,
			TextSize = 18,
		}, card) :: TextLabel

		local bidButton = mk("TextButton", {
			Name = "Bid",
			Position = UDim2.new(0.5, 0, 1, -12),
			AnchorPoint = Vector2.new(0.5, 1),
			Size = UDim2.new(1, -24, 0, 34),
			BackgroundColor3 = Theme.Green,
			Font = Theme.SerifBold,
			Text = "PLACE BID",
			TextColor3 = Theme.Ivory,
			TextSize = 17,
			AutoButtonColor = true,
		}, card) :: TextButton
		Theme.corner(6, bidButton)
		Theme.stroke(Theme.Gold, 1, bidButton)

		bidButton.Activated:Connect(function()
			local now = os.clock()
			if now - lastBidAt < BID_DEBOUNCE then
				return
			end
			lastBidAt = now
			local handler = AuctionPanel.OnBid
			if handler ~= nil then
				handler(i, bidAmount)
			end
		end)
	end

	-- ── Bid amount stepper ────────────────────────────────────────────────
	amountLabel = mk("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(16, 162),
		Size = UDim2.fromOffset(240, 34),
		Font = Theme.SerifBold,
		Text = "",
		TextColor3 = Theme.Ivory,
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, root) :: TextLabel
	refreshAmount()

	local steps: { { number | string } } = { { 50, "+50" }, { 250, "+250" }, { 1000, "+1K" }, { 0, "RESET" } }
	for i, step in steps do
		local delta = step[1] :: number
		local caption = step[2] :: string
		local button = mk("TextButton", {
			Position = UDim2.fromOffset(266 + (i - 1) * 96, 164),
			Size = UDim2.fromOffset(88, 30),
			BackgroundColor3 = if delta == 0 then Theme.Danger else Theme.PanelLight,
			Font = Theme.SerifBold,
			Text = caption,
			TextColor3 = Theme.Ivory,
			TextSize = 15,
			AutoButtonColor = true,
		}, root) :: TextButton
		Theme.corner(6, button)
		button.Activated:Connect(function()
			bidAmount = if delta == 0 then 100 else math.min(bidAmount + delta, 4294967295)
			refreshAmount()
		end)
	end

	-- ── Bid feed (left rail, slot 3) ─────────────────────────────────────
	local feed = mk("Frame", {
		Name = "BidFeed",
		LayoutOrder = 3,
		Size = UDim2.fromOffset(212, 150),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.25,
		Visible = false,
	}, feedParent) :: Frame
	feedFrame = feed
	Theme.corner(8, feed)

	mk("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(10, 4),
		Size = UDim2.new(1, -20, 0, 18),
		Font = Theme.SerifBold,
		Text = "BID LEDGER",
		TextColor3 = Theme.Gold,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, feed)
	for i = 1, FEED_LINES do
		feedLabels[i] = mk("TextLabel", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(10, 6 + i * 20),
			Size = UDim2.new(1, -20, 0, 18),
			Font = Theme.Serif,
			Text = "",
			TextColor3 = Theme.Ivory,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, feed) :: TextLabel
	end
end

function AuctionPanel.SetVisible(visible: boolean): ()
	local root = panel
	if root ~= nil then
		root.Visible = visible
	end
	local feed = feedFrame
	if feed ~= nil then
		feed.Visible = visible
	end
end

function AuctionPanel.SetOptions(names: { string }): ()
	for i = 1, CARD_COUNT do
		cardNames[i].Text = names[i] or "?"
	end
end

function AuctionPanel.SetTotal(optionIndex: number, total: number): ()
	local label = cardTotals[optionIndex]
	if label ~= nil then
		label.Text = Theme.money(total)
	end
end

function AuctionPanel.ResetTotals(): ()
	for i = 1, CARD_COUNT do
		cardTotals[i].Text = "$0"
	end
	for i = 1, FEED_LINES do
		feedLabels[i].Text = ""
	end
end

-- Newest line on top; older lines shift down and fall off.
function AuctionPanel.AddFeed(text: string): ()
	for i = FEED_LINES, 2, -1 do
		feedLabels[i].Text = feedLabels[i - 1].Text
	end
	feedLabels[1].Text = text
end

return AuctionPanel
