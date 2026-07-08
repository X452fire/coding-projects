--!strict
-- CashShop ▸ the in-game cash equipment shop (left edge). Non-Robux: every
-- button invokes the server-authoritative "RequestPurchase" RemoteFunction
-- and displays the verdict the server returns. All validation (catalog,
-- balance, deduction, granting) happens server-side — this file is pixels.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local Theme = require(script.Parent.Theme)

local CashShop = {}

local mk = Theme.mk

-- `parent` is the left-rail stack container (UIListLayout drives placement).
function CashShop.Build(parent: GuiObject): ()
	local requestPurchase = ReplicatedStorage:WaitForChild("RequestPurchase") :: RemoteFunction

	local order = Config.ShopOrder
	local column = mk("Frame", {
		Name = "CashShop",
		LayoutOrder = 2,
		Size = UDim2.fromOffset(212, 66 + #order * 62),
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
		Text = "EQUIPMENT — CASH",
		TextColor3 = Theme.Gold,
		TextSize = 14,
	}, column)

	-- verdict line ("Executive Baton acquired" / "Insufficient funds")
	local status = mk("TextLabel", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, -6),
		Size = UDim2.new(1, 0, 0, 18),
		Font = Theme.Serif,
		Text = "",
		TextColor3 = Theme.Muted,
		TextSize = 13,
	}, column) :: TextLabel

	local busy = false
	for i, itemId in order do
		local item = Config.ShopItems[itemId]
		local button = mk("TextButton", {
			Name = itemId,
			Position = UDim2.fromOffset(10, 26 + (i - 1) * 62),
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
			Text = `{item.Name}  ·  {Theme.money(item.Cost)}`,
			TextColor3 = Theme.Ivory,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, button)
		mk("TextLabel", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(10, 28),
			Size = UDim2.new(1, -20, 0, 18),
			Font = Theme.Serif,
			Text = item.Blurb,
			TextColor3 = Theme.Muted,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, button)

		button.Activated:Connect(function()
			if busy then
				return -- one purchase in flight at a time
			end
			busy = true
			task.spawn(function()
				-- pcall passes through the server's (granted, verdict) tuple
				local ok, granted, verdict = pcall(function(): (boolean, string)
					return requestPurchase:InvokeServer(itemId)
				end)
				if ok then
					status.Text = tostring(verdict)
					status.TextColor3 = if granted == true then Theme.Green else Theme.Danger
				else
					status.Text = "Request failed"
					status.TextColor3 = Theme.Danger
				end
				busy = false
			end)
		end)
	end
end

return CashShop
