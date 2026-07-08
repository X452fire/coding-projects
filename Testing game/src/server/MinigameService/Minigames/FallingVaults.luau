--!strict
-- FallingVaults ▸ dodge mechanics. Heavy vault safes drop from the sky onto
-- telegraphed spots: a neon warning circle appears on the floor 1.5 seconds
-- before each impact. A direct hit from a falling vault deals 100 damage;
-- landed vaults stay behind as physical obstacles until Revert.

local Players = game:GetService("Players")

local Builder = require(script.Parent.Parent.Builder)
local Janitor = require(script.Parent.Parent.Parent.Janitor)

local FallingVaults = {}

local DIRECT_HIT_DAMAGE = 100
local WARNING_LEAD = 1.5 -- seconds between telegraph and impact
local DROP_INTERVAL = 1.4 -- seconds between successive telegraphs
local DROP_HEIGHT = 55
local VAULT_SIZE = 6

-- The open floor IS the game — no extra props needed on the shell.
function FallingVaults.BuildMap(_map: Model): ()
end

-- One full telegraph→drop cycle. Runs on its own janitor-tracked thread so
-- drops overlap (a new telegraph appears while the last vault is falling)
-- and Revert can cancel any of them mid-flight.
local function scheduleDrop(janitor: Janitor.Janitor, arena: Model, targetX: number, targetZ: number): ()
	local thread = task.spawn(function()
		local floorTop = Builder.FLOOR_TOP

		-- 1) Telegraph: flat neon disc on the floor.
		local warning = Builder.part({
			Name = "WarningCircle",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.2, VAULT_SIZE + 4, VAULT_SIZE + 4),
			CFrame = CFrame.new(targetX, floorTop + 0.15, targetZ) * CFrame.Angles(0, 0, math.rad(90)),
			Material = Enum.Material.Neon,
			Color = Color3.fromRGB(255, 60, 50),
			Transparency = 0.35,
			CanCollide = false,
			CanTouch = false,
		}, arena)
		janitor:Add(warning)

		task.wait(WARNING_LEAD)

		-- 2) The vault: a heavy physical part released from the sky.
		local vault = Builder.part({
			Name = "Vault",
			Size = Vector3.new(VAULT_SIZE, VAULT_SIZE, VAULT_SIZE),
			CFrame = CFrame.new(targetX, floorTop + DROP_HEIGHT, targetZ),
			Material = Enum.Material.Metal,
			Color = Color3.fromRGB(52, 60, 70),
			Anchored = false, -- physics takes it down
		}, arena)
		janitor:Add(vault)
		vault.AssemblyLinearVelocity = Vector3.new(0, -40, 0)

		-- Direct-hit detection: only while genuinely falling, once per victim.
		local struck: { [Instance]: boolean } = {}
		janitor:Add(vault.Touched:Connect(function(hit: BasePart)
			if vault.AssemblyLinearVelocity.Y > -10 then
				return -- settled/landed: it's an obstacle now, not a hazard
			end
			local model = hit.Parent
			if model == nil or struck[model] then
				return
			end
			local victim = Players:GetPlayerFromCharacter(model :: Model)
			if victim == nil then
				return
			end
			local humanoid = (model :: Model):FindFirstChildOfClass("Humanoid")
			if humanoid ~= nil and humanoid.Health > 0 then
				struck[model] = true
				humanoid:TakeDamage(DIRECT_HIT_DAMAGE) -- ForceField-aware
			end
		end))

		-- 3) Telegraph served its purpose once the vault lands (~1s).
		task.wait(1.2)
		warning:Destroy() -- Janitor tolerates double-destroy on Revert
	end)
	janitor:Add(thread)
end

function FallingVaults.Run(janitor: Janitor.Janitor, arena: Model, duration: number): ()
	local rng = Random.new()
	local center = Builder.ARENA_CENTER
	local spread = Builder.ARENA_HALF - 8

	-- Drop count derives from the shared timer: the last telegraph lands
	-- just before the round ends. Bounded scheduler loop on this
	-- (cancellable) thread; each drop runs on its own janitor-tracked
	-- sub-thread so they overlap.
	local dropCount = math.max(1, math.floor((duration - WARNING_LEAD) / DROP_INTERVAL))
	for _ = 1, dropCount do
		scheduleDrop(
			janitor,
			arena,
			center.X + rng:NextNumber(-spread, spread),
			center.Z + rng:NextNumber(-spread, spread)
		)
		task.wait(DROP_INTERVAL)
	end
end

return FallingVaults
