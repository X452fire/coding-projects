--!strict
-- SpinShop ▸ the Mystery Spin kiosk (top left). Standard spins fire the
-- binary "HT_Spin" remote; Super spins go through the Robux product prompt
-- (or the dev free-shop in test mode). The odds table is rendered from the
-- SAME frozen config weights the server rolls with — numeric disclosure by
-- construction. The Super button hides itself for players whose policy
-- restricts paid random items.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local BufferNetwork = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BufferNetwork"))
local Theme = require(script.Parent.Theme)

local SpinShop = {}

local mk = Theme.mk

local SPIN_STANDARD = 1
local ITEM_SUPER_SPIN = 6 -- dev free-shop id (test mode)

-- `parent` is the left-rail stack container (UIListLayout drives placement).
function SpinShop.Build(parent: GuiObject): ()
	local player = Players.LocalPlayer
	local spinRemote = ReplicatedStorage:WaitForChild("HT_Spin") :: RemoteEvent
	local resultRemote = ReplicatedStorage:WaitForChild("HT_SpinResult") :: RemoteEvent
	local freeMode = Config.FreePurchases == true
	local devRemote: RemoteEvent? = if freeMode
		then ReplicatedStorage:WaitForChild("HT_DevShop") :: RemoteEvent
		else nil

	local column = mk("Frame", {
		Name = "SpinShop",
		LayoutOrder = 1,
		Size = UDim2.fromOffset(212, 236),
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
		Text = "MYSTERY SPIN",
		TextColor3 = Theme.Gold,
		TextSize = 15,
	}, column)

	-- ── numeric odds disclosure (straight from the frozen server table) ──
	local oddsText = table.create(#Config.StandardSpin)
	for i, outcome in Config.StandardSpin do
		oddsText[i] = `{outcome.Name} — {outcome.Weight}%`
	end
	mk("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, 26),
		Size = UDim2.new(1, -24, 0, 100),
		Font = Theme.Serif,
		Text = table.concat(oddsText, "\n"),
		TextColor3 = Theme.Muted,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
	}, column)

	local spinPacket = buffer.create(1)
	local standardButton = mk("TextButton", {
		Position = UDim2.fromOffset(10, 130),
		Size = UDim2.new(1, -20, 0, 32),
		BackgroundColor3 = Theme.Green,
		Font = Theme.SerifBold,
		Text = `SPIN — {Theme.money(Config.StandardSpinCost)}`,
		TextColor3 = Theme.Ivory,
		TextSize = 15,
		AutoButtonColor = true,
	}, column) :: TextButton
	Theme.corner(6, standardButton)
	standardButton.Activated:Connect(function()
		buffer.writeu8(spinPacket, 0, SPIN_STANDARD)
		spinRemote:FireServer(spinPacket)
	end)

	local superButton = mk("TextButton", {
		Position = UDim2.fromOffset(10, 168),
		Size = UDim2.new(1, -20, 0, 32),
		BackgroundColor3 = Theme.PanelLight,
		Font = Theme.SerifBold,
		Text = if freeMode then "SUPER SPIN (FREE)" else "SUPER SPIN (R$)",
		TextColor3 = Theme.Gold,
		TextSize = 15,
		AutoButtonColor = true,
	}, column) :: TextButton
	Theme.corner(6, superButton)
	Theme.stroke(Theme.Gold, 1, superButton)
	superButton.Activated:Connect(function()
		if freeMode and devRemote ~= nil then
			local packet = buffer.create(1)
			buffer.writeu8(packet, 0, ITEM_SUPER_SPIN)
			devRemote:FireServer(packet)
		else
			MarketplaceService:PromptProductPurchase(player, Config.Products.SuperSpin)
		end
	end)

	-- paid random items: hide Super entirely for restricted players
	local function refreshPolicy(): ()
		superButton.Visible = player:GetAttribute("PaidRandomRestricted") ~= true
	end
	player:GetAttributeChangedSignal("PaidRandomRestricted"):Connect(refreshPolicy)
	refreshPolicy()

	-- ── result line ───────────────────────────────────────────────────────
	local resultLabel = mk("TextLabel", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, -8),
		Size = UDim2.new(1, 0, 0, 20),
		Font = Theme.SerifBold,
		Text = "",
		TextColor3 = Theme.Ivory,
		TextSize = 14,
	}, column) :: TextLabel

	resultRemote.OnClientEvent:Connect(function(data: unknown)
		if typeof(data) ~= "buffer" then
			return
		end
		local cursor = BufferNetwork.reader(data :: buffer)
		if BufferNetwork.remaining(cursor) < 6 then
			return
		end
		local spinType = BufferNetwork.readU8(cursor)
		local outcomeIndex = BufferNetwork.readU8(cursor)
		local cash = BufferNetwork.readU32(cursor)

		local outcomes = if spinType == SPIN_STANDARD then Config.StandardSpin else Config.SuperSpin
		local outcome = outcomes[outcomeIndex]
		if outcome == nil then
			return
		end
		resultLabel.Text = if cash > 0 then `{outcome.Name}  +{Theme.money(cash)}` else outcome.Name
		resultLabel.TextColor3 = if outcome.Tier == "Loss" then Theme.Muted
			elseif outcome.Tier == "Super" then Theme.Gold
			else Theme.Green
	end)
end

return SpinShop
