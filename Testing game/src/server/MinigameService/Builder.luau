--!strict
-- Builder ▸ shared arena constants + part factory for MinigameService.
-- Lives in its own module so both the service core and the individual
-- minigame modules can require it without a dependency cycle.

local Builder = {}

-- The arena sits 1200 studs from the hub: both exist in Workspace at once,
-- far outside each other's streaming/render range.
Builder.ARENA_CENTER = Vector3.new(0, 0, 1200)
Builder.ARENA_SIZE = 100
Builder.ARENA_HALF = 50
Builder.FLOOR_TOP = 1 -- arena floor's top surface Y
Builder.WALL_HEIGHT = 14

function Builder.part(props: { [string]: any }, parent: Instance): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	local target = p :: any
	for key, value in props do
		target[key] = value
	end
	p.Parent = parent
	return p
end

-- Is this player's character currently standing inside the arena bounds?
-- Used for payout eligibility and the Revert return-teleport.
function Builder.isInArena(player: Player): boolean
	local character = player.Character
	if character == nil then
		return false
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return false
	end
	local center = Builder.ARENA_CENTER
	local margin = Builder.ARENA_HALF + 15
	local pos = root.Position
	return math.abs(pos.X - center.X) <= margin
		and math.abs(pos.Z - center.Z) <= margin
		and pos.Y > center.Y - 20
end

return Builder
