--!strict
-- RisingLava ▸ progressive-damage climb. Stone pillars stud the arena; lava
-- rises via TweenService over the round. Standing in lava costs 25 HP per
-- half-second tick — a Golden Parachute (ForceField) blocks it, because all
-- damage flows through Humanoid:TakeDamage.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Builder = require(script.Parent.Parent.Builder)
local Janitor = require(script.Parent.Parent.Parent.Janitor)

local RisingLava = {}

local DAMAGE_PER_TICK = 25
local TICK_INTERVAL = 0.5
local RISE_HEIGHT = 8 -- final lava surface above the floor

-- Deterministic pillar layout: {xOffset, zOffset, height}. Heights step up
-- toward the center so there is always dry ground — but less of it.
local PILLARS: { { number } } = table.freeze({
	{ -32, -30, 5 }, { 30, -34, 6 }, { -14, -18, 7 }, { 18, -12, 9 },
	{ -34, 14, 6 }, { 34, 18, 8 }, { -18, 30, 10 }, { 12, 32, 7 },
	{ 0, 0, 12 }, { -4, 14, 11 },
})

-- Called once at startup: adds this game's props to the shared shell.
function RisingLava.BuildMap(map: Model): ()
	local center = Builder.ARENA_CENTER
	for _, def in PILLARS do
		local height = def[3]
		Builder.part({
			Name = "Pillar",
			Size = Vector3.new(6, height, 6),
			Position = Vector3.new(center.X + def[1], Builder.FLOOR_TOP + height / 2, center.Z + def[2]),
			Material = Enum.Material.Slate,
			Color = Color3.fromRGB(120, 112, 104),
		}, map)
	end
end

function RisingLava.Run(janitor: Janitor.Janitor, arena: Model, duration: number): ()
	local center = Builder.ARENA_CENTER
	local floorTop = Builder.FLOOR_TOP
	local riseTime = duration * 0.8 -- lava peaks with 20% of the round left

	-- Lava slab: starts submerged, tweens up through the pillar field.
	local lava = Builder.part({
		Name = "Lava",
		Size = Vector3.new(Builder.ARENA_SIZE, 2, Builder.ARENA_SIZE),
		Position = Vector3.new(center.X, floorTop - 2, center.Z),
		Material = Enum.Material.Neon,
		Color = Color3.fromRGB(255, 64, 0),
		CanCollide = false,
		CanTouch = false, -- damage is a spatial tick, not Touched spam
	}, arena)
	janitor:Add(lava)

	local rise = TweenService:Create(
		lava,
		TweenInfo.new(riseTime, Enum.EasingStyle.Linear),
		{ Position = Vector3.new(center.X, floorTop + RISE_HEIGHT, center.Z) }
	)
	janitor:Add(rise)
	rise:Play()

	-- Progressive damage tick: 25 HP per half-second while your feet are
	-- below the lava surface. Bounded loop on this (cancellable) thread;
	-- +6s spillover covers the Payout phase, Revert cancels us regardless.
	local ticks = math.floor((duration + 6) / TICK_INTERVAL)
	for _ = 1, ticks do
		task.wait(TICK_INTERVAL)
		local lavaSurface = lava.Position.Y + 1
		local playerList = Players:GetPlayers()
		for i = 1, #playerList do
			local player = playerList[i]
			if Builder.isInArena(player) then
				local character = player.Character :: Model
				local root = character:FindFirstChild("HumanoidRootPart")
				local humanoid = character:FindFirstChildOfClass("Humanoid")
				-- root sits ~2.5 studs above the feet
				if
					root ~= nil
					and root:IsA("BasePart")
					and humanoid ~= nil
					and humanoid.Health > 0
					and root.Position.Y - 2.5 < lavaSurface
				then
					humanoid:TakeDamage(DAMAGE_PER_TICK) -- ForceField-aware
				end
			end
		end
	end
end

return RisingLava
