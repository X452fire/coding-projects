--!strict
-- GoldenParachute ▸ the freefall. Players are lifted to the top of a tall
-- wind-tunnel shaft and drift down under reduced gravity, weaving through
-- mahogany debris beams and grabbing gold bars on the way. Near the floor
-- the "parachute deploys" (anti-grav strengthens) for a soft landing on
-- the bullseye. All collision/pickup detection is server-side spatial math
-- against known geometry — zero .Touched.

local Players = game:GetService("Players")

local Builder = require(script.Parent.Parent.Builder)
local Janitor = require(script.Parent.Parent.Parent.Janitor)
local EconomyService = require(script.Parent.Parent.Parent.EconomyService)

local GoldenParachute = {}

local SHAFT_HEIGHT = 240
local DEBRIS_DAMAGE = 40
local DEBRIS_COOLDOWN = 1
local GOLD_VALUE = 100
local GOLD_RANGE = 5
local FALL_ANTIGRAV = 0.75 -- cancel 75% of gravity: a drifting fall
local CHUTE_ANTIGRAV = 0.94 -- "deployed": near-hover
local CHUTE_ALTITUDE = 40 -- deploy below this height
local TICK = 0.15

-- {x, y, z, sizeX, sizeZ, yaw} — anchored mahogany beams to weave through
local DEBRIS: { { number } } = table.freeze({
	{ 0, 200, 0, 60, 8, 0.4 }, { -15, 170, 10, 50, 8, 1.2 }, { 20, 145, -15, 55, 8, 2.1 },
	{ -10, 120, -5, 65, 8, 0.9 }, { 15, 95, 15, 50, 8, 2.8 }, { -20, 70, 0, 60, 8, 1.7 },
	{ 5, 45, -10, 55, 8, 0.2 }, { 0, 25, 8, 45, 8, 2.4 },
})

-- {x, y, z} gold bar pickups scattered through the fall line
local GOLD: { { number } } = table.freeze({
	{ 12, 185, -8 }, { -18, 158, 12 }, { 6, 132, 18 }, { -8, 108, -14 },
	{ 18, 82, 4 }, { -14, 58, -6 }, { 0, 34, 12 }, { 10, 15, 0 },
})

function GoldenParachute.BuildMap(map: Model): ()
	local center = Builder.ARENA_CENTER
	local floorTop = Builder.FLOOR_TOP

	-- shaft walls: tall translucent panels above the arena walls
	local shaftY = floorTop + SHAFT_HEIGHT / 2
	local half = Builder.ARENA_HALF
	local size = Builder.ARENA_SIZE
	local SHAFT_COLOR = Color3.fromRGB(120, 140, 135)
	Builder.part({ Name = "ShaftN", Size = Vector3.new(size, SHAFT_HEIGHT, 2), Position = Vector3.new(center.X, shaftY, center.Z - half), Material = Enum.Material.Glass, Transparency = 0.6, Color = SHAFT_COLOR }, map)
	Builder.part({ Name = "ShaftS", Size = Vector3.new(size, SHAFT_HEIGHT, 2), Position = Vector3.new(center.X, shaftY, center.Z + half), Material = Enum.Material.Glass, Transparency = 0.6, Color = SHAFT_COLOR }, map)
	Builder.part({ Name = "ShaftE", Size = Vector3.new(2, SHAFT_HEIGHT, size), Position = Vector3.new(center.X + half, shaftY, center.Z), Material = Enum.Material.Glass, Transparency = 0.6, Color = SHAFT_COLOR }, map)
	Builder.part({ Name = "ShaftW", Size = Vector3.new(2, SHAFT_HEIGHT, size), Position = Vector3.new(center.X - half, shaftY, center.Z), Material = Enum.Material.Glass, Transparency = 0.6, Color = SHAFT_COLOR }, map)

	-- bullseye landing rings
	for ring, spec in { { 24, Color3.fromRGB(212, 175, 55) }, { 14, Color3.fromRGB(238, 234, 224) }, { 6, Color3.fromRGB(190, 45, 45) } } do
		Builder.part({
			Name = `Bullseye{ring}`,
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.2 + ring * 0.05, spec[1] :: any, spec[1] :: any),
			CFrame = CFrame.new(center.X, floorTop + 0.1 + ring * 0.05, center.Z) * CFrame.Angles(0, 0, math.rad(90)),
			Material = Enum.Material.Marble,
			Color = spec[2] :: any,
			CanCollide = false,
			CanTouch = false,
		}, map)
	end

	-- debris beams
	for _, d in DEBRIS do
		Builder.part({
			Name = "Debris",
			Size = Vector3.new(d[4], 3, d[5]),
			CFrame = CFrame.new(center.X + d[1], floorTop + d[2], center.Z + d[3]) * CFrame.Angles(0, d[6], 0),
			Material = Enum.Material.Wood,
			Color = Color3.fromRGB(64, 34, 22),
		}, map)
	end

	-- gold bars
	for i, g in GOLD do
		Builder.part({
			Name = `Gold{i}`,
			Size = Vector3.new(3, 1.2, 1.6),
			Position = Vector3.new(center.X + g[1], floorTop + g[2], center.Z + g[3]),
			Material = Enum.Material.Metal,
			Color = Color3.fromRGB(240, 200, 70),
			CanCollide = false,
			CanTouch = false,
		}, map)
	end

	-- shaft lighting: warm ring lamps every 50 studs so the whole descent
	-- is lit (the shared shell floodlights only cover the bottom)
	local LAMP_COLOR = Color3.fromRGB(255, 214, 165)
	for height = 50, SHAFT_HEIGHT, 50 do
		local lamp = Builder.part({
			Name = "ShaftLamp",
			Size = Vector3.new(2, 2, 2),
			Position = Vector3.new(center.X + half - 4, floorTop + height, center.Z),
			Material = Enum.Material.Neon,
			Color = LAMP_COLOR,
			CanCollide = false,
			CanTouch = false,
		}, map)
		local light = Instance.new("PointLight")
		light.Color = LAMP_COLOR
		light.Range = 60
		light.Brightness = 1.4
		light.Parent = lamp
	end
end

function GoldenParachute.Run(janitor: Janitor.Janitor, arena: Model, duration: number): ()
	local rng = Random.new()
	local center = Builder.ARENA_CENTER
	local floorTop = Builder.FLOOR_TOP

	-- gather this arena's debris beams and gold bars once
	local debris: { BasePart } = table.create(#DEBRIS)
	local gold: { BasePart } = table.create(#GOLD)
	for _, child in arena:GetChildren() do
		if child:IsA("BasePart") then
			if child.Name == "Debris" then
				debris[#debris + 1] = child
			elseif child.Name:sub(1, 4) == "Gold" and child.Name ~= "Gold" then
				gold[#gold + 1] = child
			end
		end
	end
	local goldTaken: { boolean } = table.create(#gold, false)

	-- lift everyone to the top and hang the anti-grav "wind" on their root
	type Faller = { Player: Player, Force: VectorForce, Landed: boolean }
	local fallers: { Faller } = table.create(24)
	local list = Players:GetPlayers()
	for i = 1, #list do
		local player = list[i]
		if Builder.isInArena(player) then
			local character = player.Character :: Model
			local root = character:FindFirstChild("HumanoidRootPart")
			if root ~= nil and root:IsA("BasePart") then
				character:PivotTo(CFrame.new(
					center.X + rng:NextNumber(-15, 15),
					floorTop + SHAFT_HEIGHT - 10,
					center.Z + rng:NextNumber(-15, 15)
				))
				local attachment = Instance.new("Attachment")
				attachment.Parent = root
				local wind = Instance.new("VectorForce")
				wind.Attachment0 = attachment
				wind.RelativeTo = Enum.ActuatorRelativeTo.World
				wind.Force = Vector3.new(0, root.AssemblyMass * workspace.Gravity * FALL_ANTIGRAV, 0)
				wind.Parent = root
				janitor:Add(wind)
				janitor:Add(attachment)
				fallers[#fallers + 1] = { Player = player, Force = wind, Landed = false }
			end
		end
	end

	local hitCooldown: { [number]: number } = {}

	-- the descent loop: spatial checks only, bounded by the round deadline
	local deadline = os.clock() + duration + 4
	while os.clock() < deadline do
		task.wait(TICK)
		for i = 1, #fallers do
			local faller = fallers[i]
			local player = faller.Player
			local character = player.Character
			local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
			if root ~= nil and root:IsA("BasePart") and Builder.isInArena(player) then
				local pos = root.Position
				local altitude = pos.Y - floorTop

				-- parachute deploys near the floor; cut the wind once landed
				if not faller.Landed then
					if altitude < 6 then
						faller.Landed = true
						faller.Force.Force = Vector3.zero
					elseif altitude < CHUTE_ALTITUDE then
						faller.Force.Force = Vector3.new(
							0,
							root.AssemblyMass * workspace.Gravity * CHUTE_ANTIGRAV,
							0
						)
					end
				end

				-- debris: point-in-box against each beam's object space
				local now = os.clock()
				if now - (hitCooldown[player.UserId] or 0) >= DEBRIS_COOLDOWN then
					for d = 1, #debris do
						local beam = debris[d]
						local localPos = beam.CFrame:PointToObjectSpace(pos)
						local halfSize = beam.Size / 2
						if
							math.abs(localPos.X) < halfSize.X + 1
							and math.abs(localPos.Y) < halfSize.Y + 2
							and math.abs(localPos.Z) < halfSize.Z + 1
						then
							local humanoid = (character :: Model):FindFirstChildOfClass("Humanoid")
							if humanoid ~= nil and humanoid.Health > 0 then
								hitCooldown[player.UserId] = now
								humanoid:TakeDamage(DEBRIS_DAMAGE)
							end
							break
						end
					end
				end

				-- gold bars: proximity pickup
				for g = 1, #gold do
					if not goldTaken[g] and (gold[g].Position - pos).Magnitude <= GOLD_RANGE then
						goldTaken[g] = true
						gold[g].Transparency = 1
						EconomyService.Deposit(player.UserId, GOLD_VALUE)
					end
				end
			end
		end
	end
end

return GoldenParachute
