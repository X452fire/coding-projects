--!strict
-- BombTag ▸ hot-potato with a briefcase bomb. A random player in the arena
-- receives the "Toxic Asset"; passing is a SERVER-side proximity check
-- (distance + facing every tick — never client .Touched). When the fuse
-- hits zero the carrier is eliminated and a fresh bomb is issued while
-- round time remains.

local Players = game:GetService("Players")

local Builder = require(script.Parent.Parent.Builder)
local Janitor = require(script.Parent.Parent.Parent.Janitor)

local BombTag = {}

local PASS_RANGE = 6 -- studs: touch-passing distance
local PASS_COOLDOWN = 1.5 -- no instant pass-backs
local TICK = 0.1
local FUSE_MIN, FUSE_MAX = 8, 14

-- A few marble pillars to juke around.
local PILLARS: { { number } } = table.freeze({
	{ -25, -25 }, { 25, -25 }, { -25, 25 }, { 25, 25 }, { 0, 0 },
})

function BombTag.BuildMap(map: Model): ()
	local center = Builder.ARENA_CENTER
	for _, offset in PILLARS do
		Builder.part({
			Name = "Pillar",
			Size = Vector3.new(5, 10, 5),
			Position = Vector3.new(center.X + offset[1], Builder.FLOOR_TOP + 5, center.Z + offset[2]),
			Material = Enum.Material.Marble,
			Color = Color3.fromRGB(238, 234, 224),
		}, map)
	end
end

-- Everyone alive and inside the arena, written into `out`. Returns count.
local function arenaPlayers(out: { Player }): number
	local n = 0
	local list = Players:GetPlayers()
	for i = 1, #list do
		local player = list[i]
		if Builder.isInArena(player) then
			local character = player.Character :: Model
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid ~= nil and humanoid.Health > 0 then
				n += 1
				out[n] = player
			end
		end
	end
	return n
end

function BombTag.Run(janitor: Janitor.Janitor, _arena: Model, duration: number): ()
	local rng = Random.new()
	local candidates: { Player } = table.create(32)

	-- The bomb marker follows whoever is holding it.
	local marker = Instance.new("BillboardGui")
	marker.Name = "ToxicAsset"
	marker.Size = UDim2.fromOffset(64, 64)
	marker.StudsOffset = Vector3.new(0, 3.2, 0)
	marker.AlwaysOnTop = true
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Text = "💣"
	label.TextColor3 = Color3.fromRGB(255, 80, 60)
	label.Parent = marker
	janitor:Add(marker)

	local deadline = os.clock() + duration
	while os.clock() < deadline do -- bounded by the round deadline
		-- ── issue a bomb ──
		local count = arenaPlayers(candidates)
		if count < 2 then
			task.wait(1) -- not enough targets to pass between; idle politely
		else
			local carrier = candidates[rng:NextInteger(1, count)]
			local fuse = math.min(rng:NextNumber(FUSE_MIN, FUSE_MAX), deadline - os.clock())
			local carrierChar = carrier.Character :: Model
			marker.Parent = carrierChar:FindFirstChild("Head") or carrierChar.PrimaryPart
			carrier:SetAttribute("HasBomb", true)

			local lastPass = os.clock()
			local fuseEnd = os.clock() + fuse
			while os.clock() < fuseEnd do -- bounded by the fuse
				task.wait(TICK)
				local character = carrier.Character
				local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
				if root == nil or not root:IsA("BasePart") or not Builder.isInArena(carrier) then
					break -- carrier died/left: bomb dissipates, issue a new one
				end
				-- server-side pass check: nearest other player in range
				if os.clock() - lastPass >= PASS_COOLDOWN then
					local n = arenaPlayers(candidates)
					for i = 1, n do
						local target = candidates[i]
						if target ~= carrier then
							local targetRoot = (target.Character :: Model):FindFirstChild("HumanoidRootPart")
							if
								targetRoot ~= nil
								and targetRoot:IsA("BasePart")
								and (targetRoot.Position - root.Position).Magnitude <= PASS_RANGE
							then
								carrier:SetAttribute("HasBomb", nil)
								carrier = target
								carrier:SetAttribute("HasBomb", true)
								local newChar = carrier.Character :: Model
								marker.Parent = newChar:FindFirstChild("Head") or newChar.PrimaryPart
								lastPass = os.clock()
								break
							end
						end
					end
				end
			end

			-- ── detonation (if the carrier is still standing) ──
			carrier:SetAttribute("HasBomb", nil)
			marker.Parent = nil
			local character = carrier.Character
			if character ~= nil and Builder.isInArena(carrier) then
				local humanoid = character:FindFirstChildOfClass("Humanoid")
				local root = character:FindFirstChild("HumanoidRootPart")
				if root ~= nil and root:IsA("BasePart") then
					-- brief blast visual, janitor-swept
					local blast = Builder.part({
						Name = "Blast",
						Shape = Enum.PartType.Ball,
						Size = Vector3.new(10, 10, 10),
						Position = root.Position,
						Material = Enum.Material.Neon,
						Color = Color3.fromRGB(255, 120, 40),
						Transparency = 0.3,
						CanCollide = false,
						CanTouch = false,
					}, workspace)
					janitor:Add(blast)
					janitor:Add(task.delay(0.4, function()
						blast:Destroy()
					end))
				end
				if humanoid ~= nil and humanoid.Health > 0 then
					humanoid:TakeDamage(math.huge) -- fuse expired: eliminated
				end
			end
			task.wait(0.6) -- beat before the next bomb
		end
	end
end

return BombTag
