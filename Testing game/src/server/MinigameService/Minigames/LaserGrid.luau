--!strict
-- LaserGrid ▸ dodge mechanics. Four neon beams sweep the arena — two span
-- the X axis and sweep along Z, two span Z and sweep along X, each on its
-- own sinusoidal phase. Detection is RAYCAST-based (not Touched): every
-- frame each beam casts along its length; the first thing the ray hits
-- takes 40 damage (per-player cooldown stops frame-stacking). Cover blocks
-- in the arena genuinely block the ray, so hiding behind them works.

local Players = game:GetService("Players")

local Builder = require(script.Parent.Parent.Builder)
local Janitor = require(script.Parent.Parent.Parent.Janitor)

local LaserGrid = {}

local BEAM_DAMAGE = 40
local HIT_COOLDOWN = 0.8 -- seconds of immunity per player after a hit
local BEAM_HEIGHT = 2.5 -- above the floor: torso height, jumpable
local SWEEP_SPEED = 0.55 -- radians/sec base

-- {axis ("X" beams are long in X and sweep along Z), phase offset, speed mult}
type BeamDef = { Axis: string, Phase: number, Speed: number }
local BEAM_DEFS: { BeamDef } = table.freeze({
	{ Axis = "X", Phase = 0, Speed = 1.0 },
	{ Axis = "X", Phase = math.pi, Speed = 0.8 },
	{ Axis = "Z", Phase = math.pi / 2, Speed = 1.1 },
	{ Axis = "Z", Phase = 3 * math.pi / 2, Speed = 0.7 },
} :: { BeamDef })

-- Cover blocks: tall enough to break the beam's line of sight.
local COVER: { { number } } = table.freeze({
	{ -22, -22 }, { 22, -22 }, { -22, 22 }, { 22, 22 },
})

function LaserGrid.BuildMap(map: Model): ()
	local center = Builder.ARENA_CENTER
	for _, offset in COVER do
		Builder.part({
			Name = "Cover",
			Size = Vector3.new(6, 5, 6),
			Position = Vector3.new(center.X + offset[1], Builder.FLOOR_TOP + 2.5, center.Z + offset[2]),
			Material = Enum.Material.DiamondPlate,
			Color = Color3.fromRGB(70, 70, 74),
		}, map)
	end
end

function LaserGrid.Run(janitor: Janitor.Janitor, arena: Model, duration: number): ()
	local center = Builder.ARENA_CENTER
	local size = Builder.ARENA_SIZE
	local half = Builder.ARENA_HALF
	local beamY = Builder.FLOOR_TOP + BEAM_HEIGHT

	-- Build the beam parts (visual) once; they sweep by CFrame writes.
	local beams: { Part } = table.create(#BEAM_DEFS)
	for i, def in BEAM_DEFS do
		local longX = def.Axis == "X"
		local beam = Builder.part({
			Name = "Laser",
			Size = if longX then Vector3.new(size, 0.4, 0.4) else Vector3.new(0.4, 0.4, size),
			Position = Vector3.new(center.X, beamY, center.Z),
			Material = Enum.Material.Neon,
			Color = Color3.fromRGB(255, 40, 40),
			CanCollide = false,
			CanQuery = false, -- rays must pass THROUGH the beam visuals
			CanTouch = false,
		}, arena)
		beams[i] = beam
		janitor:Add(beam)
	end

	-- Empty exclusion list: cover blocks and walls SHOULD stop the ray
	-- (that's what makes hiding work), the beam visuals are CanQuery=false,
	-- and the ray runs above the floor — nothing needs filtering out.
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = {}

	local lastHit: { [number]: number } = {} -- userId → last damage stamp

	local start = os.clock()
	local deadline = start + duration + 6 -- spillover into Payout; Revert cancels
	while os.clock() < deadline do -- bounded by the deadline, not `true`
		task.wait()
		local t = os.clock() - start
		for i, def in BEAM_DEFS do
			local sweep = math.sin(t * SWEEP_SPEED * def.Speed + def.Phase) * (half - 6)
			local beam = beams[i]
			local origin: Vector3
			local direction: Vector3
			if def.Axis == "X" then
				-- long in X, sweeping along Z
				beam.Position = Vector3.new(center.X, beamY, center.Z + sweep)
				origin = Vector3.new(center.X - half + 1, beamY, center.Z + sweep)
				direction = Vector3.new(size - 2, 0, 0)
			else
				beam.Position = Vector3.new(center.X + sweep, beamY, center.Z)
				origin = Vector3.new(center.X + sweep, beamY, center.Z - half + 1)
				direction = Vector3.new(0, 0, size - 2)
			end

			local result = workspace:Raycast(origin, direction, rayParams)
			if result ~= nil then
				local model = result.Instance.Parent
				if model ~= nil then
					local victim = Players:GetPlayerFromCharacter(model :: Model)
					if victim ~= nil then
						local now = os.clock()
						if now - (lastHit[victim.UserId] or 0) >= HIT_COOLDOWN then
							local humanoid = (model :: Model):FindFirstChildOfClass("Humanoid")
							if humanoid ~= nil and humanoid.Health > 0 then
								lastHit[victim.UserId] = now
								humanoid:TakeDamage(BEAM_DAMAGE) -- ForceField-aware
							end
						end
					end
				end
			end
		end
	end
end

return LaserGrid
