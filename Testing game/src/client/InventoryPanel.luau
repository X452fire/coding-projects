--!strict
-- InventoryPanel ▸ owned items (bottom right). Counts arrive as
-- "Inv_<itemId>" attributes, armed buffs as "Buff_<itemId>" — no remote
-- traffic to render the panel at all. USE buttons fire the "ConsumeBuff"
-- BufferNetwork string packet; swords list as passives (auto-equipped by
-- the server on spawn).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local BufferNetwork = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BufferNetwork"))
local Theme = require(script.Parent.Theme)

local InventoryPanel = {}

local mk = Theme.mk

-- `parent` is the right-rail stack container (UIListLayout drives placement).
function InventoryPanel.Build(parent: GuiObject): ()
	local player = Players.LocalPlayer
	local consumeRemote = ReplicatedStorage:WaitForChild("ConsumeBuff") :: RemoteEvent
	local order = Config.ItemOrder

	local column = mk("Frame", {
		Name = "InventoryPanel",
		LayoutOrder = 2,
		Size = UDim2.fromOffset(212, 30 + #order * 34),
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
		Text = "PORTFOLIO",
		TextColor3 = Theme.Gold,
		TextSize = 14,
	}, column)

	local writer = BufferNetwork.writer(64)

	for i, itemId in order do
		local def = Config.Items[itemId]
		local row = mk("Frame", {
			Name = itemId,
			Position = UDim2.fromOffset(10, 26 + (i - 1) * 34),
			Size = UDim2.new(1, -20, 0, 30),
			BackgroundColor3 = Theme.PanelLight,
		}, column) :: Frame
		Theme.corner(6, row)

		local nameLabel = mk("TextLabel", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(8, 0),
			Size = UDim2.new(1, -70, 1, 0),
			Font = Theme.Serif,
			Text = def.Name,
			TextColor3 = Theme.Muted,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, row) :: TextLabel

		local action: TextButton? = nil
		if def.Kind == "Buff" then
			action = mk("TextButton", {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -6, 0.5, 0),
				Size = UDim2.fromOffset(52, 22),
				BackgroundColor3 = Theme.Green,
				Font = Theme.SerifBold,
				Text = "USE",
				TextColor3 = Theme.Ivory,
				TextSize = 12,
				AutoButtonColor = true,
			}, row) :: TextButton
			Theme.corner(5, action :: TextButton);
			(action :: TextButton).Activated:Connect(function()
				BufferNetwork.reset(writer)
				BufferNetwork.writeString(writer, itemId)
				consumeRemote:FireServer(BufferNetwork.finish(writer))
			end)
		end

		-- live refresh from replicated attributes
		local function refresh(): ()
			local count = player:GetAttribute(`Inv_{itemId}`)
			local owned = if type(count) == "number" then count else 0
			local armed = player:GetAttribute(`Buff_{itemId}`) == true
			nameLabel.Text = if owned > 0 then `{def.Name} ×{owned}` else def.Name
			nameLabel.TextColor3 = if owned > 0 then Theme.Ivory else Theme.Muted
			local button = action
			if button ~= nil then
				button.Visible = owned > 0 and not armed
				row.BackgroundColor3 = if armed then Theme.Green else Theme.PanelLight
			end
		end
		player:GetAttributeChangedSignal(`Inv_{itemId}`):Connect(refresh)
		player:GetAttributeChangedSignal(`Buff_{itemId}`):Connect(refresh)
		refresh()
	end
end

return InventoryPanel
