--!strict
-- Hud ▸ persistent overlay: cash counter, streak, phase banner + countdown.

local Players = game:GetService("Players")

local Theme = require(script.Parent.Theme)

local Hud = {}

local mk = Theme.mk

local gui: ScreenGui? = nil
local cashLabel: TextLabel? = nil
local streakLabel: TextLabel? = nil
local phaseLabel: TextLabel? = nil
local timerLabel: TextLabel? = nil

function Hud.Build(): ScreenGui
	local screen = mk("ScreenGui", {
		Name = "HostileTakeoverHUD",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 10,
	}, Players.LocalPlayer:WaitForChild("PlayerGui")) :: ScreenGui
	gui = screen

	-- ── Cash plaque (top right) ────────────────────────────────────────────
	local plaque = mk("Frame", {
		Name = "CashPlaque",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 16),
		Size = UDim2.fromOffset(210, 74),
		BackgroundColor3 = Theme.Panel,
	}, screen) :: Frame
	Theme.corner(8, plaque)
	Theme.stroke(Theme.Gold, 1.6, plaque)

	mk("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.new(1, -24, 0, 16),
		Font = Theme.SerifBold,
		Text = "PERSONAL FUNDS",
		TextColor3 = Theme.Muted,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, plaque)
	cashLabel = mk("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, 22),
		Size = UDim2.new(1, -24, 0, 30),
		Font = Theme.SerifBold,
		Text = "$0",
		TextColor3 = Theme.Gold,
		TextSize = 28,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, plaque) :: TextLabel
	streakLabel = mk("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, 52),
		Size = UDim2.new(1, -24, 0, 16),
		Font = Theme.Serif,
		Text = "Survival streak: 0",
		TextColor3 = Theme.Ivory,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, plaque) :: TextLabel

	-- ── Phase banner (top center) ─────────────────────────────────────────
	local banner = mk("Frame", {
		Name = "PhaseBanner",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 16),
		Size = UDim2.fromOffset(340, 58),
		BackgroundColor3 = Theme.Panel,
	}, screen) :: Frame
	Theme.corner(8, banner)
	Theme.stroke(Theme.Gold, 1.6, banner)

	phaseLabel = mk("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 6),
		Size = UDim2.new(1, 0, 0, 26),
		Font = Theme.SerifBold,
		Text = "INTERMISSION",
		TextColor3 = Theme.Ivory,
		TextSize = 22,
	}, banner) :: TextLabel
	timerLabel = mk("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 32),
		Size = UDim2.new(1, 0, 0, 20),
		Font = Theme.Serif,
		Text = "",
		TextColor3 = Theme.Muted,
		TextSize = 16,
	}, banner) :: TextLabel

	return screen
end

function Hud.GetGui(): ScreenGui
	return assert(gui, "Hud.Build() must run first")
end

function Hud.SetCash(amount: number): ()
	local label = cashLabel
	if label ~= nil then
		label.Text = Theme.money(amount)
	end
end

function Hud.SetStreak(streak: number): ()
	local label = streakLabel
	if label ~= nil then
		label.Text = `Survival streak: {streak}`
	end
end

function Hud.SetPhase(text: string, color: Color3): ()
	local label = phaseLabel
	if label ~= nil then
		label.Text = text
		label.TextColor3 = color
	end
end

function Hud.SetTimer(text: string): ()
	local label = timerLabel
	if label ~= nil then
		label.Text = text
	end
end

return Hud
