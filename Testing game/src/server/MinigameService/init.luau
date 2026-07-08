--!strict
-- MinigameService ▸ owns minigame map templates, arena lifecycle, execution,
-- and teardown. Replaces the old DisasterService.
--
-- Lifecycle contract with StateController:
--   Teleporting → LoadMap(id)  : clone the template from ServerStorage into
--                                Workspace (players are PivotTo'd in next).
--   Simulating  → Execute(id)  : run the minigame mechanics on a dedicated
--                                cancellable thread with a fresh Janitor.
--   Revert      → Revert()     : watchdog-cancel the thread, Janitor:Cleanup()
--                                every connection/tween/part/thread the game
--                                created, then destroy the cloned map.
--
-- Map templates are BUILT ONCE at Init into ServerStorage.MinigameMaps —
-- the shared arena shell (floor/walls/spawn zone) plus each game's
-- BuildMap() props (pillars, cover blocks, …). Cloning a prebuilt model is
-- far cheaper than rebuilding geometry every round.

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.GameConfig)
local Janitor = require(script.Parent.Janitor)
local Builder = require(script.Builder)

local RisingLava = require(script.Minigames.RisingLava)
local LaserGrid = require(script.Minigames.LaserGrid)
local FallingVaults = require(script.Minigames.FallingVaults)
local BombTag = require(script.Minigames.BombTag)
local MarketCrash = require(script.Minigames.MarketCrash)
local BullBear = require(script.Minigames.BullBear)
local GoldenParachute = require(script.Minigames.GoldenParachute)
local AssetFreeze = require(script.Minigames.AssetFreeze)

local MinigameService = {}

export type MinigameModule = {
	BuildMap: (map: Model) -> (), -- add game-specific props to the shell
	Run: (janitor: Janitor.Janitor, arena: Model, duration: number) -> (), -- the mechanics
}

-- Index == minigame Id (matches Config.Minigames).
local REGISTRY = table.freeze({
	RisingLava,
	LaserGrid,
	FallingVaults,
	BombTag,
	MarketCrash,
	BullBear,
	GoldenParachute,
	AssetFreeze,
} :: { MinigameModule })

local templates: { Model } = table.create(#Config.Minigames)
local activeMap: Model? = nil
local activeJanitor: Janitor.Janitor? = nil
local activeThread: thread? = nil

-- Shared arena shell: slate floor, containment walls, spawn zone marker.
local function buildShell(name: string): Model
	local map = Instance.new("Model")
	map.Name = name

	local center = Builder.ARENA_CENTER
	local size = Builder.ARENA_SIZE
	local half = Builder.ARENA_HALF
	local wallH = Builder.WALL_HEIGHT
	local floorY = Builder.FLOOR_TOP

	local floor = Builder.part({
		Name = "ArenaFloor",
		Size = Vector3.new(size, 2, size),
		Position = Vector3.new(center.X, floorY - 1, center.Z),
		Material = Enum.Material.Slate,
		Color = Color3.fromRGB(88, 84, 80),
	}, map)
	map.PrimaryPart = floor

	local wallY = floorY + wallH / 2
	Builder.part({ Name = "WallN", Size = Vector3.new(size, wallH, 2), Position = Vector3.new(center.X, wallY, center.Z - half), Material = Enum.Material.Concrete, Color = Color3.fromRGB(60, 58, 56) }, map)
	Builder.part({ Name = "WallS", Size = Vector3.new(size, wallH, 2), Position = Vector3.new(center.X, wallY, center.Z + half), Material = Enum.Material.Concrete, Color = Color3.fromRGB(60, 58, 56) }, map)
	Builder.part({ Name = "WallE", Size = Vector3.new(2, wallH, size), Position = Vector3.new(center.X + half, wallY, center.Z), Material = Enum.Material.Concrete, Color = Color3.fromRGB(60, 58, 56) }, map)
	Builder.part({ Name = "WallW", Size = Vector3.new(2, wallH, size), Position = Vector3.new(center.X - half, wallY, center.Z), Material = Enum.Material.Concrete, Color = Color3.fromRGB(60, 58, 56) }, map)

	-- invisible spawn zone marker (teleport target for the batch PivotTo)
	Builder.part({
		Name = "SpawnZone",
		Size = Vector3.new(24, 1, 24),
		Position = Vector3.new(center.X, floorY + 0.5, center.Z),
		Transparency = 1,
		CanCollide = false,
		CanTouch = false,
	}, map)

	-- Stadium floodlights: four warm corner posts + one high center lamp.
	-- Every arena clones these, so no minigame is ever played in the dark.
	local LAMP_COLOR = Color3.fromRGB(255, 214, 165) -- orangish-white
	local inset = half - 8
	for _, corner in { Vector3.new(-inset, 0, -inset), Vector3.new(inset, 0, -inset), Vector3.new(-inset, 0, inset), Vector3.new(inset, 0, inset) } do
		local lamp = Builder.part({
			Name = "Floodlight",
			Size = Vector3.new(2, 2, 2),
			Position = Vector3.new(center.X + corner.X, floorY + wallH - 1, center.Z + corner.Z),
			Material = Enum.Material.Neon,
			Color = LAMP_COLOR,
			CanCollide = false,
			CanTouch = false,
		}, map)
		local light = Instance.new("PointLight")
		light.Color = LAMP_COLOR
		light.Range = 60
		light.Brightness = 1.5
		light.Parent = lamp
	end
	local centerLamp = Builder.part({
		Name = "CenterLamp",
		Size = Vector3.new(3, 1.5, 3),
		Position = Vector3.new(center.X, floorY + 26, center.Z),
		Material = Enum.Material.Neon,
		Color = LAMP_COLOR,
		CanCollide = false,
		CanTouch = false,
	}, map)
	local centerLight = Instance.new("PointLight")
	centerLight.Color = LAMP_COLOR
	centerLight.Range = 60
	centerLight.Brightness = 1.2
	centerLight.Parent = centerLamp

	return map
end

function MinigameService.Init(): ()
	local folder = Instance.new("Folder")
	folder.Name = "MinigameMaps"
	for id = 1, #REGISTRY do
		local map = buildShell(Config.Minigames[id].Name)
		REGISTRY[id].BuildMap(map) -- game-specific props
		map.Parent = folder
		templates[id] = map
	end
	folder.Parent = ServerStorage
end

-- Teleporting phase: clone the winning game's map into Workspace.
function MinigameService.LoadMap(minigameId: number): Model?
	MinigameService.Revert() -- defensive: never two live arenas
	local template = templates[minigameId]
	if template == nil then
		warn(`[Minigame] unknown id {minigameId}`)
		return nil
	end
	local clone = template:Clone()
	clone.Parent = workspace
	activeMap = clone
	return clone
end

-- Where the batch teleport lands (StateController fans players in a ring).
function MinigameService.GetSpawnCFrame(): CFrame
	local center = Builder.ARENA_CENTER
	return CFrame.new(center.X, Builder.FLOOR_TOP + 3.5, center.Z)
end

function MinigameService.IsInArena(player: Player): boolean
	return Builder.isInArena(player)
end

-- Simulating phase: run the mechanics on a dedicated cancellable thread.
-- `duration` is the shared MinigameTimer value — StateController's deadline
-- and the game's internal loops both derive from the same config number.
function MinigameService.Execute(minigameId: number, duration: number): ()
	local module = REGISTRY[minigameId]
	local arena = activeMap
	if module == nil or arena == nil then
		return
	end
	local janitor = Janitor.new(64)
	activeJanitor = janitor
	activeThread = task.spawn(function()
		local ok, err = pcall(module.Run, janitor, arena, duration)
		if not ok then
			warn(`[Minigame] {Config.Minigames[minigameId].Name} failed: {err}`)
			-- partial state stays registered in the Janitor; Revert sweeps it
		end
	end)
end

-- Revert phase: watchdog + scorched earth + arena demolition.
function MinigameService.Revert(): ()
	local thread = activeThread
	if thread ~= nil and coroutine.status(thread) ~= "dead" then
		task.cancel(thread) -- a hung Run() dies here
	end
	activeThread = nil

	local janitor = activeJanitor
	activeJanitor = nil
	if janitor ~= nil then
		janitor:Cleanup() -- LIFO-destroy every connection/tween/part/thread
	end

	local map = activeMap
	activeMap = nil
	if map ~= nil then
		map:Destroy()
	end
end

return MinigameService
