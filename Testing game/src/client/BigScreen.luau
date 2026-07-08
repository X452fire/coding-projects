--!strict
-- BigScreen ▸ the giant auction display above the north wall.
-- Rendered client-side: a SurfaceGui lives in PlayerGui and adorns the
-- server-built "AuctionScreen" part (PlayerGui adornment is the recommended
-- pattern — it keeps all UI ownership on the client and replicates nothing).

local Players = game:GetService("Players")

local Theme = require(script.Parent.Theme)

local BigScreen = {}

local mk = Theme.mk

local ROW_COUNT = 3

local phaseLabel: TextLabel? = nil
local timerLabel: TextLabel? = nil
local winnerLabel: TextLabel? = nil
local rowNames: { TextLabel } = table.create(ROW_COUNT)
local rowTotals: { TextLabel } = table.create(ROW_COUNT)
local rowFrames: { Frame } = table.create(ROW_COUNT)
local totals: { number } = table.create(ROW_COUNT, 0)

local function highlightLeader(): ()
	local best, bestIndex = 0, 0
	for i = 1, ROW_COUNT do
		if totals[i] > best then
			best = totals[i]
			bestIndex = i
		end
	end
	for i = 1, ROW_COUNT do
		local frame = rowFrames[i]
		frame.BackgroundColor3 = if i == bestIndex then Theme.PanelLight else Theme.Panel
	end
end

-- Yields on WaitForChild — call via task.spawn from the bootstrap.
function BigScreen.Build(): ()
	local map = workspace:WaitForChild("Map", 30)
	if map == nil then
		return
	end
	local screenPart = map:WaitForChild("AuctionScreen", 30)
	if screenPart == nil or not screenPart:IsA("BasePart") then
		return
	end

	local surface = mk("SurfaceGui", {
		Name = "AuctionScreenGui",
		Adornee = screenPart,
		Face = Enum.NormalId.Front, -- part is rotated to face the room
		SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
		PixelsPerStud = 20, -- 44×16 studs → 880×320 px canvas
		LightInfluence = 0,
		Brightness = 1.5,
	}, Players.LocalPlayer:WaitForChild("PlayerGui")) :: SurfaceGui

	local root = mk("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(8, 10, 9),
	}, surface) :: Frame

	phaseLabel = mk("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(30, 14),
		Size = UDim2.fromOffset(560, 44),
		Font = Theme.SerifBold,
		Text = "HOSTILE TAKEOVER",
		TextColor3 = Theme.Gold,
		TextSize = 38,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, root) :: TextLabel

	timerLabel = mk("TextLabel", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -30, 0, 14),
		Size = UDim2.fromOffset(240, 44),
		Font = Theme.SerifBold,
		Text = "",
		TextColor3 = Theme.Ivory,
		TextSize = 40,
		TextXAlignment = Enum.TextXAlignment.Right,
	}, root) :: TextLabel

	for i = 1, ROW_COUNT do
		local row = mk("Frame", {
			Position = UDim2.fromOffset(30, 30 + i * 56),
			Size = UDim2.new(1, -60, 0, 46),
			BackgroundColor3 = Theme.Panel,
		}, root) :: Frame
		rowFrames[i] = row
		Theme.corner(6, row)
		Theme.stroke(Theme.Gold, 1, row)

		rowNames[i] = mk("TextLabel", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(16, 0),
			Size = UDim2.new(0.6, 0, 1, 0),
			Font = Theme.SerifBold,
			Text = "",
			TextColor3 = Theme.Ivory,
			TextSize = 26,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, row) :: TextLabel
		rowTotals[i] = mk("TextLabel", {
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -16, 0, 0),
			Size = UDim2.new(0.35, 0, 1, 0),
			Font = Theme.SerifBold,
			Text = "$0",
			TextColor3 = Theme.Gold,
			TextSize = 26,
			TextXAlignment = Enum.TextXAlignment.Right,
		}, row) :: TextLabel
	end

	winnerLabel = mk("TextLabel", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -8),
		Size = UDim2.new(1, -60, 0, 34),
		Font = Theme.SerifBold,
		Text = "",
		TextColor3 = Theme.Danger,
		TextSize = 28,
	}, root) :: TextLabel
end

-- All setters are no-ops until Build finishes (labels still nil) — the next
-- state broadcast repopulates everything, so no state is ever lost.

function BigScreen.SetPhase(text: string): ()
	local label = phaseLabel
	if label ~= nil then
		label.Text = text
	end
end

function BigScreen.SetTimer(text: string): ()
	local label = timerLabel
	if label ~= nil then
		label.Text = text
	end
end

function BigScreen.SetOptions(names: { string }): ()
	for i = 1, ROW_COUNT do
		local label = rowNames[i]
		if label ~= nil then
			label.Text = `{i}.  {names[i] or "?"}`
		end
	end
end

function BigScreen.SetTotal(optionIndex: number, total: number): ()
	totals[optionIndex] = total
	local label = rowTotals[optionIndex]
	if label ~= nil then
		label.Text = Theme.money(total)
		highlightLeader()
	end
end

function BigScreen.ResetTotals(): ()
	for i = 1, ROW_COUNT do
		totals[i] = 0
		local label = rowTotals[i]
		if label ~= nil then
			label.Text = "$0"
		end
	end
	if rowFrames[1] ~= nil then
		highlightLeader()
	end
end

function BigScreen.SetWinner(text: string): ()
	local label = winnerLabel
	if label ~= nil then
		label.Text = text
	end
end

return BigScreen
