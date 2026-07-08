--!strict
-- Hostile Takeover ▸ client bootstrap.
-- Builds the HUD, bidding console, both shops, and the big wall screen,
-- then binds them to the binary state/feed channels and replicated
-- attributes. Five-phase mirror of the server machine:
--   1 Lobby (bids live) · 2 Teleporting · 3 Simulating · 4 Payout · 5 Revert

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local Net = require(script.Net)
local Theme = require(script.Theme)
local Hud = require(script.Hud)
local AuctionPanel = require(script.AuctionPanel)
local BigScreen = require(script.BigScreen)
local Shop = require(script.Shop)
local CashShop = require(script.CashShop)
local SpinShop = require(script.SpinShop)
local InventoryPanel = require(script.InventoryPanel)

local player = Players.LocalPlayer

local gui = Hud.Build()

-- Left rail: SpinShop and CashShop stack inside one UIListLayout container
-- so they can never overlap, whatever the viewport height.
local leftRail = Instance.new("Frame")
leftRail.Name = "LeftRail"
leftRail.Position = UDim2.fromOffset(16, 16)
leftRail.Size = UDim2.new(0, 212, 1, -32)
leftRail.BackgroundTransparency = 1
leftRail.Parent = gui
local leftLayout = Instance.new("UIListLayout")
leftLayout.FillDirection = Enum.FillDirection.Vertical
leftLayout.Padding = UDim.new(0, 10)
leftLayout.SortOrder = Enum.SortOrder.LayoutOrder
leftLayout.Parent = leftRail

-- Right rail: Robux shop + inventory stack below the cash plaque.
local rightRail = Instance.new("Frame")
rightRail.Name = "RightRail"
rightRail.AnchorPoint = Vector2.new(1, 0)
rightRail.Position = UDim2.new(1, -16, 0, 100) -- clears the cash plaque
rightRail.Size = UDim2.new(0, 212, 1, -116)
rightRail.BackgroundTransparency = 1
rightRail.Parent = gui
local rightLayout = Instance.new("UIListLayout")
rightLayout.FillDirection = Enum.FillDirection.Vertical
rightLayout.Padding = UDim.new(0, 10)
rightLayout.SortOrder = Enum.SortOrder.LayoutOrder
rightLayout.Parent = rightRail

AuctionPanel.Build(gui, leftRail) -- bid console + feed (feed rides the rail)
Shop.Build(rightRail) -- Robux column (right rail, slot 1)
CashShop.Build(leftRail) -- in-game cash column (left rail, slot 2)
task.spawn(SpinShop.Build, leftRail) -- Mystery Spin kiosk (left rail, slot 1)
task.spawn(InventoryPanel.Build, rightRail) -- items + buffs (right rail, slot 2)
task.spawn(BigScreen.Build) -- yields on the hub map part; UI works meanwhile

-- ── Wallet HUD ← replicated attributes ────────────────────────────────────
local function refreshCash(): ()
	local cash = player:GetAttribute("Cash")
	Hud.SetCash(if type(cash) == "number" then cash else 0)
end
local function refreshStreak(): ()
	local streak = player:GetAttribute("Streak")
	Hud.SetStreak(if type(streak) == "number" then streak else 0)
end
player:GetAttributeChangedSignal("Cash"):Connect(refreshCash)
player:GetAttributeChangedSignal("Streak"):Connect(refreshStreak)
refreshCash()
refreshStreak()

-- ── Bidding ────────────────────────────────────────────────────────────────
AuctionPanel.OnBid = function(optionIndex: number, amount: number)
	Net.SendBid(optionIndex, amount)
end

-- ── State machine mirror ──────────────────────────────────────────────────
local LOBBY, TELEPORTING, SIMULATING = 1, 2, 3

type PhaseInfo = { Text: string, Color: Color3 }
local PHASES: { PhaseInfo } = {
	{ Text = "OPEN FLOOR — BIDS LIVE", Color = Theme.Gold },
	{ Text = "TELEPORTING", Color = Theme.Ivory },
	{ Text = "MINIGAME LIVE", Color = Theme.Danger },
	{ Text = "PAYOUT", Color = Theme.Green },
	{ Text = "RESET", Color = Theme.Muted },
}

local currentEndsAt = 0
local lastTotals: { number } = table.create(3, 0) -- feed deltas (totals only on wire)

Net.OnState(function(stateIndex: number, endsAt: number, offered: { number }, winningId: number)
	currentEndsAt = endsAt

	local phase = PHASES[stateIndex]
	if phase ~= nil then
		Hud.SetPhase(phase.Text, phase.Color)
		BigScreen.SetPhase(phase.Text)
	end

	local names = table.create(3, "?")
	for i = 1, 3 do
		local def = Config.Minigames[offered[i]]
		names[i] = if def ~= nil then def.Name else "?"
	end

	if stateIndex == LOBBY then -- bids open with the fresh slate
		for i = 1, 3 do
			lastTotals[i] = 0
		end
		AuctionPanel.SetOptions(names)
		AuctionPanel.ResetTotals()
		AuctionPanel.SetVisible(true)
		BigScreen.SetOptions(names)
		BigScreen.ResetTotals()
		BigScreen.SetWinner("")
	else
		AuctionPanel.SetVisible(false)
	end

	-- winner resolves at Teleporting; keep it on screen through the game
	if (stateIndex == TELEPORTING or stateIndex == SIMULATING) and winningId ~= 0 then
		local def = Config.Minigames[winningId]
		local minigameName = if def ~= nil then def.Name else "?"
		BigScreen.SetWinner(`⚠ {string.upper(minigameName)} ⚠`)
		if stateIndex == SIMULATING then
			Hud.SetPhase(string.upper(minigameName), Theme.Danger)
		end
	end
end)

-- ── Live bid feed ─────────────────────────────────────────────────────────
Net.OnFeed(function(optionIndex: number, newTotal: number, bidderName: string)
	AuctionPanel.SetTotal(optionIndex, newTotal)
	BigScreen.SetTotal(optionIndex, newTotal)
	local delta = newTotal - (lastTotals[optionIndex] or 0)
	lastTotals[optionIndex] = newTotal
	if delta > 0 then
		AuctionPanel.AddFeed(`{bidderName}  ·  {Theme.money(delta)}`)
	end
end)

-- ── Countdown (shares the server's GetServerTimeNow clock: sub-ms sync) ──
RunService.RenderStepped:Connect(function()
	local remaining = math.max(0, currentEndsAt - workspace:GetServerTimeNow())
	local text = if remaining > 0 then string.format("%.1fs", remaining) else ""
	Hud.SetTimer(text)
	BigScreen.SetTimer(text)
end)
