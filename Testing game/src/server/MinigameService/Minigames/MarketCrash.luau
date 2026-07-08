--!strict
-- MarketCrash ▸ luxury spleef. Players stand on a suspended marble trading
-- floor; every 2 seconds a batch of random tiles flashes red and drops.
-- The void below deals heavy progressive damage. Tiles carry a
-- CollectionService tag ("HT_BreakableTile") for lifecycle management —
-- the intact set is discovered from the tag, not hand-tracked wiring.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local Builder = require(script.Parent.Parent.Builder)
local Janitor = require(script.Parent.Parent.Parent.Janitor)

local MarketCrash = {}

local TILE_TAG = "HT_BreakableTile"
local GRID = 10 -- 10×10 tiles
local TILE_SIZE = 8
local PLATFORM_HEIGHT = 10 -- tiles float this far above the void floor
local CRASH_INTERVAL = 2
local FLASH_TIME = 0.6
local VOID_DAMAGE = 50 -- per half-second below the platform
local VOID_TICK = 0.5

function MarketCrash.BuildMap(map: Model): ()
	local center = Builder.ARENA_CENTER
	local tileY = Builder.FLOOR_TOP + PLATFORM_HEIGHT
	local origin = -(GRID * TILE_SIZE) / 2 + TILE_SIZE / 2
	for gx = 1, GRID do
		for gz = 1, GRID do
			local tile = Builder.part({
				Name = "Tile",
				Size = Vector3.new(TILE_SIZE - 0.2, 1, TILE_SIZE - 0.2),
				Position = Vector3.new(
					center.X + origin + (gx - 1) * TILE_SIZE,
					tileY,
					center.Z + origin + (gz - 1) * TILE_SIZE
				),
				Material = Enum.Material.Marble,
				-- subtle checkerboard so depth reads at a glance
				Color = if (gx + gz) % 2 == 0
					then Color3.fromRGB(238, 234, 224)
					else Color3.fromRGB(210, 202, 186),
			}, map)
			CollectionService:AddTag(tile, TILE_TAG)
		end
	end
end

function MarketCrash.Run(janitor: Janitor.Janitor, arena: Model, duration: number): ()
	local rng = Random.new()
	local center = Builder.ARENA_CENTER
	local tileY = Builder.FLOOR_TOP + PLATFORM_HEIGHT

	-- Hoist everyone onto the platform (they teleported in at floor level).
	local list = Players:GetPlayers()
	for i = 1, #list do
		local player = list[i]
		if Builder.isInArena(player) then
			local character = player.Character :: Model
			character:PivotTo(CFrame.new(
				center.X + rng:NextNumber(-20, 20),
				tileY + 4,
				center.Z + rng:NextNumber(-20, 20)
			))
		end
	end

	-- Void hazard: heavy progressive damage below the platform, on its own
	-- janitor-tracked thread (parallel to the crash schedule).
	janitor:Add(task.spawn(function()
		local ticks = math.floor((duration + 6) / VOID_TICK)
		for _ = 1, ticks do
			task.wait(VOID_TICK)
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
						and root.Position.Y < tileY - 4
					then
						humanoid:TakeDamage(VOID_DAMAGE)
					end
				end
			end
		end
	end))

	-- The crash schedule: discover THIS arena's intact tiles from the tag,
	-- then drop escalating batches every 2 seconds.
	local intact: { BasePart } = table.create(GRID * GRID)
	local intactCount = 0
	for _, tagged in CollectionService:GetTagged(TILE_TAG) do
		if tagged:IsA("BasePart") and tagged:IsDescendantOf(arena) then
			intactCount += 1
			intact[intactCount] = tagged
		end
	end

	local wave = 0
	local crashes = math.floor(duration / CRASH_INTERVAL) - 1
	for _ = 1, crashes do -- bounded by the round length
		task.wait(CRASH_INTERVAL)
		wave += 1
		local batch = math.min(2 + wave, intactCount) -- escalate the panic
		for _ = 1, batch do
			if intactCount == 0 then
				break
			end
			-- swap-remove a random intact tile
			local index = rng:NextInteger(1, intactCount)
			local tile = intact[index]
			intact[index] = intact[intactCount]
			intact[intactCount] = nil
			intactCount -= 1

			-- flash red, then release to physics; gone for good shortly after
			tile.Color = Color3.fromRGB(200, 40, 40)
			tile.Material = Enum.Material.Neon
			janitor:Add(task.delay(FLASH_TIME, function()
				CollectionService:RemoveTag(tile, TILE_TAG)
				tile.Anchored = false
				tile.CanCollide = false -- players fall THROUGH crashing tiles
				task.wait(2)
				tile:Destroy()
			end))
		end
	end
end

return MarketCrash
