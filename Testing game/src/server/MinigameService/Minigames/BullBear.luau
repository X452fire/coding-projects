--!strict
-- BullBear ▸ musical platforms, stock-market edition. Eight ticker
-- platforms hover over a trading-floor hazard. Every cycle each platform
-- randomly turns BULL (green — rises to safety) or BEAR (red — sinks into
-- the hazard zone). Read the board, hop to a bull, don't get caught long
-- on a bear. Hazard is progressive damage, not instant death.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Builder = require(script.Parent.Parent.Builder)
local Janitor = require(script.Parent.Parent.Parent.Janitor)

local BullBear = {}

local PLATFORM_COUNT = 8
local BASE_HEIGHT = 8 -- resting platform height above the floor
local BULL_HEIGHT = 14 -- safe altitude
local BEAR_HEIGHT = 2.5 -- inside the hazard band
local CYCLE_TIME = 5
local SWAP_TWEEN = 1.2
local HAZARD_DAMAGE = 25 -- per half-second in the low band
local HAZARD_TICK = 0.5
local HAZARD_CEILING = 4 -- root below floor+4 ⇒ taking damage

local BULL_GREEN = Color3.fromRGB(50, 160, 80)
local BEAR_RED = Color3.fromRGB(190, 45, 45)

-- Two rows of four, well spaced.
local SLOTS: { { number } } = table.freeze({
	{ -33, -15 }, { -11, -15 }, { 11, -15 }, { 33, -15 },
	{ -33, 15 }, { -11, 15 }, { 11, 15 }, { 33, 15 },
})

function BullBear.BuildMap(map: Model): ()
	local center = Builder.ARENA_CENTER
	-- the "trading floor" hazard visual
	Builder.part({
		Name = "TradingFloorHazard",
		Size = Vector3.new(Builder.ARENA_SIZE, 2, Builder.ARENA_SIZE),
		Position = Vector3.new(center.X, Builder.FLOOR_TOP + 1, center.Z),
		Material = Enum.Material.Neon,
		Color = Color3.fromRGB(160, 30, 30),
		Transparency = 0.4,
		CanCollide = false,
		CanTouch = false,
	}, map)
	for i, slot in SLOTS do
		Builder.part({
			Name = `Ticker{i}`,
			Size = Vector3.new(12, 2, 12),
			Position = Vector3.new(center.X + slot[1], Builder.FLOOR_TOP + BASE_HEIGHT, center.Z + slot[2]),
			Material = Enum.Material.SmoothPlastic,
			Color = Color3.fromRGB(120, 120, 124),
		}, map)
	end
end

function BullBear.Run(janitor: Janitor.Janitor, arena: Model, duration: number): ()
	local rng = Random.new()
	local center = Builder.ARENA_CENTER
	local floorTop = Builder.FLOOR_TOP

	-- collect this arena's platforms
	local platforms: { BasePart } = table.create(PLATFORM_COUNT)
	for i = 1, PLATFORM_COUNT do
		local ticker = arena:FindFirstChild(`Ticker{i}`)
		if ticker ~= nil and ticker:IsA("BasePart") then
			platforms[#platforms + 1] = ticker
		end
	end

	-- hoist players onto random platforms to start
	local list = Players:GetPlayers()
	for i = 1, #list do
		local player = list[i]
		if Builder.isInArena(player) and #platforms > 0 then
			local perch = platforms[rng:NextInteger(1, #platforms)]
			local character = player.Character :: Model
			character:PivotTo(CFrame.new(perch.Position + Vector3.new(0, 4, 0)))
		end
	end

	-- hazard tick on its own janitor-tracked thread
	janitor:Add(task.spawn(function()
		local ticks = math.floor((duration + 6) / HAZARD_TICK)
		for _ = 1, ticks do
			task.wait(HAZARD_TICK)
			local playerList = Players:GetPlayers()
			for i = 1, #playerList do
				local player = playerList[i]
				if Builder.isInArena(player) then
					local character = player.Character :: Model
					local root = character:FindFirstChild("HumanoidRootPart")
					local humanoid = character:FindFirstChildOfClass("Humanoid")
					if
						root ~= nil
						and root:IsA("BasePart")
						and humanoid ~= nil
						and humanoid.Health > 0
						and root.Position.Y < floorTop + HAZARD_CEILING
					then
						humanoid:TakeDamage(HAZARD_DAMAGE)
					end
				end
			end
		end
	end))

	-- the market cycle: reassign every platform each round
	local cycles = math.floor(duration / CYCLE_TIME)
	for _ = 1, cycles do -- bounded by the round length
		-- guarantee at least 2 bulls so the game is always survivable
		local bullA = rng:NextInteger(1, #platforms)
		local bullB = (bullA + rng:NextInteger(1, #platforms - 1) - 1) % #platforms + 1
		for i, platform in platforms do
			local isBull = i == bullA or i == bullB or rng:NextNumber() < 0.4
			platform.Color = if isBull then BULL_GREEN else BEAR_RED
			local targetY = floorTop + (if isBull then BULL_HEIGHT else BEAR_HEIGHT)
			local slide = TweenService:Create(
				platform,
				TweenInfo.new(SWAP_TWEEN, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
				{ Position = Vector3.new(platform.Position.X, targetY, platform.Position.Z) }
			)
			janitor:Add(slide)
			slide:Play()
		end
		task.wait(CYCLE_TIME)
	end
end

return BullBear
