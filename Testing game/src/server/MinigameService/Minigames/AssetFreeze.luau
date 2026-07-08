--!strict
-- AssetFreeze ▸ "Red Light, Green Light" with an Auditor. While the market
-- light is GREEN the Auditor statue faces the wall and players may move.
-- When it snaps RED, the server watches every character's ACTUAL velocity
-- (AssemblyLinearVelocity — pure server physics, nothing client-reported):
-- anyone moving after the grace window is encased in ice and eliminated.

local Players = game:GetService("Players")

local Builder = require(script.Parent.Parent.Builder)
local Janitor = require(script.Parent.Parent.Parent.Janitor)

local AssetFreeze = {}

local GREEN_MIN, GREEN_MAX = 2.5, 4.5
local RED_MIN, RED_MAX = 2, 3
local GRACE = 0.4 -- reaction window after the snap to RED
local SPEED_TOLERANCE = 3 -- studs/s of allowed drift (physics jitter)
local CHECK_TICK = 0.1

function AssetFreeze.BuildMap(map: Model): ()
	local center = Builder.ARENA_CENTER
	local floorTop = Builder.FLOOR_TOP

	-- The Auditor: a stern marble bust on a plinth at the north end.
	Builder.part({
		Name = "AuditorPlinth",
		Size = Vector3.new(8, 6, 8),
		Position = Vector3.new(center.X, floorTop + 3, center.Z - Builder.ARENA_HALF + 8),
		Material = Enum.Material.Marble,
		Color = Color3.fromRGB(238, 234, 224),
	}, map)
	Builder.part({
		Name = "AuditorHead",
		Size = Vector3.new(5, 6, 5),
		-- starts facing the wall (GREEN); Run() spins it around for RED
		CFrame = CFrame.new(center.X, floorTop + 9, center.Z - Builder.ARENA_HALF + 8)
			* CFrame.Angles(0, math.pi, 0),
		Material = Enum.Material.Marble,
		Color = Color3.fromRGB(220, 214, 200),
	}, map)
	-- the market light: a wide status bar above the Auditor
	Builder.part({
		Name = "MarketLight",
		Size = Vector3.new(20, 2, 1),
		Position = Vector3.new(center.X, floorTop + 15, center.Z - Builder.ARENA_HALF + 8),
		Material = Enum.Material.Neon,
		Color = Color3.fromRGB(50, 160, 80),
	}, map)
end

function AssetFreeze.Run(janitor: Janitor.Janitor, arena: Model, duration: number): ()
	local rng = Random.new()
	local floorTop = Builder.FLOOR_TOP

	local head = arena:FindFirstChild("AuditorHead")
	local light = arena:FindFirstChild("MarketLight")
	if head == nil or not head:IsA("BasePart") or light == nil or not light:IsA("BasePart") then
		return
	end
	local facingWall = head.CFrame -- GREEN pose (built facing the wall)
	local facingFloor = head.CFrame * CFrame.Angles(0, math.pi, 0) -- RED pose

	local deadline = os.clock() + duration
	while os.clock() < deadline do -- bounded by the round deadline
		-- ── GREEN: move freely ──
		light.Color = Color3.fromRGB(50, 160, 80)
		head.CFrame = facingWall
		task.wait(math.min(rng:NextNumber(GREEN_MIN, GREEN_MAX), math.max(deadline - os.clock(), 0.1)))
		if os.clock() >= deadline then
			break
		end

		-- ── RED: the Auditor turns; grace, then velocity audits ──
		light.Color = Color3.fromRGB(190, 45, 45)
		head.CFrame = facingFloor
		task.wait(GRACE)

		local redEnd = math.min(os.clock() + rng:NextNumber(RED_MIN, RED_MAX), deadline)
		while os.clock() < redEnd do -- bounded by the red window
			task.wait(CHECK_TICK)
			local list = Players:GetPlayers()
			for i = 1, #list do
				local player = list[i]
				if Builder.isInArena(player) then
					local character = player.Character :: Model
					local root = character:FindFirstChild("HumanoidRootPart")
					local humanoid = character:FindFirstChildOfClass("Humanoid")
					if
						root ~= nil
						and root:IsA("BasePart")
						and humanoid ~= nil
						and humanoid.Health > 0
						and root.AssemblyLinearVelocity.Magnitude > SPEED_TOLERANCE
					then
						-- caught moving: encased in ice, eliminated
						local ice = Builder.part({
							Name = "IceBlock",
							Size = Vector3.new(4.5, 7, 4.5),
							Position = Vector3.new(root.Position.X, math.max(root.Position.Y, floorTop + 3.5), root.Position.Z),
							Material = Enum.Material.Ice,
							Color = Color3.fromRGB(170, 215, 230),
							Transparency = 0.35,
						}, arena)
						janitor:Add(ice)
						humanoid:TakeDamage(math.huge)
					end
				end
			end
		end
	end
end

return AssetFreeze
