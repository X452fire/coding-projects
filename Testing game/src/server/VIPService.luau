--!strict
-- VIPService ▸ VIP Lounge access control (the 399 R$ gamepass).
--
-- Mechanics: the lounge is sealed in glass. Touching the gold door either
-- teleports you through (owners — direction inferred from which side you're
-- standing on) or prompts the gamepass purchase (everyone else). Ownership
-- is resolved once on join (async, pcall-armored) and updated live when a
-- purchase completes; EconomyService gates the 2x income on the same flag.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.GameConfig)
local EconomyService = require(script.Parent.EconomyService)

local VIPService = {}

-- Must match MapBuilder's lounge geometry.
local INSIDE_POS = Vector3.new(48, 9, 44)
local OUTSIDE_POS = Vector3.new(48, 4, 26)
local LOUNGE_EDGE = 34 -- x AND z beyond this ⇒ standing inside the lounge
local TOUCH_DEBOUNCE = 1.5

local lastTouch: { [number]: number } = {}

local function onDoorTouched(hit: BasePart): ()
	local character = hit.Parent
	if character == nil then
		return
	end
	local player = Players:GetPlayerFromCharacter(character :: Model)
	if player == nil then
		return
	end

	local now = os.clock()
	if now - (lastTouch[player.UserId] or 0) < TOUCH_DEBOUNCE then
		return -- Touched spams while walking into the door
	end
	lastTouch[player.UserId] = now

	if EconomyService.HasVIPPass(player.UserId) then
		local model = character :: Model
		local root = model:FindFirstChild("HumanoidRootPart")
		if root ~= nil and root:IsA("BasePart") then
			local pos = root.Position
			local inside = pos.X > LOUNGE_EDGE and pos.Z > LOUNGE_EDGE
			model:PivotTo(CFrame.new(if inside then OUTSIDE_POS else INSIDE_POS))
		end
	else
		MarketplaceService:PromptGamePassPurchase(player, Config.VIPGamePassId)
	end
end

-- Resolve ownership on join. Runs on the join thread (already spawned).
function VIPService.OnJoin(player: Player): ()
	local owns = false
	if Config.VIPGamePassId > 0 then
		local ok, result = pcall(function(): boolean
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, Config.VIPGamePassId)
		end)
		owns = ok and result == true
	end
	if not owns and Config.StudioFreeVIP and RunService:IsStudio() then
		owns = true -- playtest convenience: the lounge is reachable in Studio
	end
	if player.Parent ~= nil then
		EconomyService.SetVIPPass(player.UserId, owns)
	end
end

function VIPService.Init(): ()
	-- MapBuilder.Build() runs before Init, so the door exists synchronously.
	local map = workspace:FindFirstChild("Map")
	local door = if map ~= nil then map:FindFirstChild("VIPDoor") else nil
	if door ~= nil and door:IsA("BasePart") then
		door.Touched:Connect(onDoorTouched)
	else
		warn("[VIP] VIPDoor not found — lounge access disabled")
	end

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(player: Player, passId: number, purchased: boolean)
			if purchased and passId == Config.VIPGamePassId then
				EconomyService.SetVIPPass(player.UserId, true)
			end
		end
	)

	Players.PlayerRemoving:Connect(function(player: Player)
		lastTouch[player.UserId] = nil
	end)
end

return VIPService
