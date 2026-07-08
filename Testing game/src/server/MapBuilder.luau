--!strict
-- MapBuilder ▸ procedurally assembles the "Old Money" boardroom at startup.
-- Everything is anchored primitives — zero physics cost, zero asset loads.
--
-- Layout (top-down, 130×130 studs, walls 26 high):
--   * White marble floor ("Arena" — LavaFloor sizes itself to this part)
--   * Mahogany walls with a gold wainscoting trim line
--   * Giant "AuctionScreen" part on the north wall (client adorns SurfaceGui)
--   * Marble columns, gold chandeliers (warm PointLights), statue pedestals
--   * VIP Lounge in the NE corner: raised marble platform (survives lava),
--     glass walls, a gold "VIPDoor" (VIPService gates entry), and an
--     invisible zone part tagged for the 2x income scan.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.GameConfig)

local MapBuilder = {}

local ROOM = 130
local HALF = ROOM / 2 -- 65
local WALL_H = 26
local FLOOR_TOP = 1 -- above the template Baseplate's top (y = 0): no z-fighting

local MAHOGANY = Color3.fromRGB(64, 34, 22)
local DARK_WOOD = Color3.fromRGB(44, 25, 17)
local MARBLE = Color3.fromRGB(238, 234, 224)
local GOLD = Color3.fromRGB(212, 175, 55)
local VELVET = Color3.fromRGB(74, 24, 28)

local function part(props: { [string]: any }, parent: Instance): Part
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

function MapBuilder.Build(): ()
	if workspace:FindFirstChild("Map") ~= nil then
		return -- idempotent: hot-reconnecting Rojo shouldn't double-build
	end
	local map = Instance.new("Folder")
	map.Name = "Map"

	-- ── Shell ──────────────────────────────────────────────────────────────
	part({
		Name = "Arena",
		Size = Vector3.new(ROOM, 2, ROOM),
		Position = Vector3.new(0, FLOOR_TOP - 1, 0),
		Material = Enum.Material.Marble,
		Color = MARBLE,
	}, map)
	part({
		Name = "Ceiling",
		Size = Vector3.new(ROOM, 1, ROOM),
		Position = Vector3.new(0, FLOOR_TOP + WALL_H + 0.5, 0),
		Material = Enum.Material.Wood,
		Color = DARK_WOOD,
	}, map)

	local wallY = FLOOR_TOP + WALL_H / 2
	part({ Name = "WallN", Size = Vector3.new(ROOM, WALL_H, 2), Position = Vector3.new(0, wallY, -HALF), Material = Enum.Material.Wood, Color = MAHOGANY }, map)
	part({ Name = "WallS", Size = Vector3.new(ROOM, WALL_H, 2), Position = Vector3.new(0, wallY, HALF), Material = Enum.Material.Wood, Color = MAHOGANY }, map)
	part({ Name = "WallE", Size = Vector3.new(2, WALL_H, ROOM), Position = Vector3.new(HALF, wallY, 0), Material = Enum.Material.Wood, Color = MAHOGANY }, map)
	part({ Name = "WallW", Size = Vector3.new(2, WALL_H, ROOM), Position = Vector3.new(-HALF, wallY, 0), Material = Enum.Material.Wood, Color = MAHOGANY }, map)

	-- gold wainscoting line around the room
	local trimY = FLOOR_TOP + 8
	part({ Size = Vector3.new(ROOM, 0.6, 0.4), Position = Vector3.new(0, trimY, -HALF + 1.2), Material = Enum.Material.Metal, Color = GOLD }, map)
	part({ Size = Vector3.new(ROOM, 0.6, 0.4), Position = Vector3.new(0, trimY, HALF - 1.2), Material = Enum.Material.Metal, Color = GOLD }, map)
	part({ Size = Vector3.new(0.4, 0.6, ROOM), Position = Vector3.new(HALF - 1.2, trimY, 0), Material = Enum.Material.Metal, Color = GOLD }, map)
	part({ Size = Vector3.new(0.4, 0.6, ROOM), Position = Vector3.new(-HALF + 1.2, trimY, 0), Material = Enum.Material.Metal, Color = GOLD }, map)

	-- ── Columns & decor ────────────────────────────────────────────────────
	for _, corner in { Vector3.new(-45, 0, -45), Vector3.new(45, 0, -45), Vector3.new(-45, 0, 45) } do
		-- (NE corner omitted — that's the VIP lounge)
		part({
			Name = "Column",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(WALL_H, 5, 5),
			CFrame = CFrame.new(corner.X, FLOOR_TOP + WALL_H / 2, corner.Z) * CFrame.Angles(0, 0, math.rad(90)),
			Material = Enum.Material.Marble,
			Color = MARBLE,
		}, map)
	end

	for _, x in { -38, 0, 38 } do
		local fixture = part({
			Name = "Chandelier",
			Size = Vector3.new(4, 1.2, 4),
			Position = Vector3.new(x, FLOOR_TOP + 20, 0),
			Material = Enum.Material.Metal,
			Color = GOLD,
		}, map)
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 214, 165) -- warm incandescent
		light.Range = 48
		light.Brightness = 0.9
		light.Parent = fixture
	end

	-- statue pedestals flanking the auction screen
	for _, x in { -30, 30 } do
		part({
			Name = "Pedestal",
			Size = Vector3.new(4, 6, 4),
			Position = Vector3.new(x, FLOOR_TOP + 3, -58),
			Material = Enum.Material.Marble,
			Color = MARBLE,
		}, map)
		part({
			Name = "Bust",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(3, 3, 3),
			Position = Vector3.new(x, FLOOR_TOP + 7.5, -58),
			Material = Enum.Material.Metal,
			Color = GOLD,
		}, map)
	end

	-- ── The auction screen (north wall) ────────────────────────────────────
	-- Rotated 180° so the part's FRONT face looks into the room — the client
	-- adorns its SurfaceGui to Enum.NormalId.Front.
	part({
		Name = "ScreenFrame",
		Size = Vector3.new(46, 18, 0.6),
		Position = Vector3.new(0, FLOOR_TOP + 14, -HALF + 1.2),
		Material = Enum.Material.Metal,
		Color = GOLD,
	}, map)
	part({
		Name = "AuctionScreen",
		Size = Vector3.new(44, 16, 0.8),
		CFrame = CFrame.new(0, FLOOR_TOP + 14, -HALF + 1.6) * CFrame.Angles(0, math.pi, 0),
		Material = Enum.Material.SmoothPlastic,
		Color = Color3.fromRGB(12, 12, 14),
	}, map)

	-- ── VIP Lounge (NE corner, x/z ∈ [33, 63]) ─────────────────────────────
	local LC = 48 -- lounge center on both axes
	part({
		Name = "VIPFloor",
		Size = Vector3.new(30, 4, 30), -- raised 4: high ground when lava rises
		Position = Vector3.new(LC, FLOOR_TOP + 2, LC),
		Material = Enum.Material.Marble,
		Color = Color3.fromRGB(244, 236, 214), -- gold-veined marble
	}, map)

	local glassY = FLOOR_TOP + 10 -- glass spans platform top (5) → 17
	local GLASS = Color3.fromRGB(180, 200, 190)
	part({ Name = "VIPGlassW", Size = Vector3.new(0.8, 12, 30), Position = Vector3.new(33, glassY, LC), Material = Enum.Material.Glass, Transparency = 0.55, Color = GLASS }, map)
	part({ Name = "VIPGlassSL", Size = Vector3.new(12, 12, 0.8), Position = Vector3.new(39, glassY, 33), Material = Enum.Material.Glass, Transparency = 0.55, Color = GLASS }, map)
	part({ Name = "VIPGlassSR", Size = Vector3.new(12, 12, 0.8), Position = Vector3.new(57, glassY, 33), Material = Enum.Material.Glass, Transparency = 0.55, Color = GLASS }, map)
	-- the door: solid gold-tinted glass; VIPService teleports owners through
	part({
		Name = "VIPDoor",
		Size = Vector3.new(6, 12, 0.8),
		Position = Vector3.new(LC, glassY, 33),
		Material = Enum.Material.Glass,
		Transparency = 0.35,
		Color = GOLD,
	}, map)

	-- marble steps up to the door
	part({ Size = Vector3.new(8, 1.4, 3), Position = Vector3.new(LC, FLOOR_TOP + 0.7, 28.5), Material = Enum.Material.Marble, Color = MARBLE }, map)
	part({ Size = Vector3.new(8, 2.8, 3), Position = Vector3.new(LC, FLOOR_TOP + 1.4, 31.2), Material = Enum.Material.Marble, Color = MARBLE }, map)

	-- velvet seating
	part({ Size = Vector3.new(10, 2.4, 3), Position = Vector3.new(LC, FLOOR_TOP + 5.2, 60), Material = Enum.Material.Fabric, Color = VELVET }, map)
	part({ Size = Vector3.new(3, 2.4, 10), Position = Vector3.new(61, FLOOR_TOP + 5.2, LC), Material = Enum.Material.Fabric, Color = VELVET }, map)

	-- invisible marker whose bounds EconomyService scans for 2x income
	local zone = part({
		Name = "VIPZone",
		Size = Vector3.new(30, 10, 30),
		Position = Vector3.new(LC, FLOOR_TOP + 9, LC),
		Transparency = 1,
		CanCollide = false,
		CanTouch = false,
	}, map)
	CollectionService:AddTag(zone, Config.VIPLoungeTag)

	-- ── Spawn ──────────────────────────────────────────────────────────────
	local spawnLocation = Instance.new("SpawnLocation")
	spawnLocation.Name = "Spawn"
	spawnLocation.Size = Vector3.new(12, 1, 12)
	spawnLocation.Position = Vector3.new(0, FLOOR_TOP - 0.4, 8) -- 0.1 marble lip
	spawnLocation.Anchored = true
	spawnLocation.Duration = 0 -- no spawn forcefield: parachutes stay premium
	spawnLocation.Material = Enum.Material.Marble
	spawnLocation.Color = Color3.fromRGB(210, 202, 184)
	spawnLocation.TopSurface = Enum.SurfaceType.Smooth
	spawnLocation.Parent = map

	map.Parent = workspace

	-- ── Warm "old money" lighting ──────────────────────────────────────────
	-- Night-time clock, but a BRIGHT orangish-white ambient so the hub and
	-- (fixture-lit) arenas both read clearly — candlelit gala, not cellar.
	Lighting.Ambient = Color3.fromRGB(168, 142, 110)
	Lighting.OutdoorAmbient = Color3.fromRGB(120, 100, 78)
	Lighting.Brightness = 2
	Lighting.ClockTime = 20 -- still evening: the warm grade carries the scene
	local grade = Instance.new("ColorCorrectionEffect")
	grade.TintColor = Color3.fromRGB(255, 240, 218)
	grade.Brightness = 0.03
	grade.Contrast = 0.05
	grade.Saturation = -0.04
	grade.Parent = Lighting
end

return MapBuilder
