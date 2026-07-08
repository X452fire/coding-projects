--!strict
-- Hostile Takeover ▸ server bootstrap.
-- Initialization order is dependency order: telemetry and map first, leaves
-- next, ProcessReceipt installed last.

local Players = game:GetService("Players")

local TelemetryService = require(script.TelemetryService)
local MapBuilder = require(script.MapBuilder)
local DataService = require(script.DataService)
local InventoryService = require(script.InventoryService)
local EconomyService = require(script.EconomyService)
local NetworkService = require(script.NetworkService)
local MinigameService = require(script.MinigameService)
local StateController = require(script.StateController)
local VIPService = require(script.VIPService)
local RewardRollService = require(script.RewardRollService)
local MonetizationService = require(script.MonetizationService)

TelemetryService.Init() -- economy dashboard heartbeat
MapBuilder.Build() -- the "Old Money" hub, VIP lounge, auction screen
DataService.Init() -- autosave/lock-renewal heartbeat + BindToClose flush
InventoryService.Init() -- "ConsumeBuff" remote
EconomyService.Init() -- income heartbeat + "RequestPurchase" cash shop
MinigameService.Init() -- builds the 8 arena templates into ServerStorage
StateController.Init() -- starts the five-phase scheduler
NetworkService.Init(StateController.PlaceBid) -- wire the binary bid channel
VIPService.Init() -- lounge door + gamepass hooks
RewardRollService.Init() -- "HT_Spin"/"HT_SpinResult" remotes
MonetizationService.Init() -- ProcessReceipt fortress, installed LAST

local function onPlayerAdded(player: Player): ()
	NetworkService.Register(player) -- token bucket exists before any packet

	-- YIELDS while a foreign session lock drains (rapid server-hop guard).
	local profile = DataService.LoadProfile(player.UserId)
	if profile == nil then
		player:Kick("Your data is locked by another server. Rejoin in a moment.")
		return
	end
	if player.Parent == nil then
		-- player left while we waited on the lock: release immediately
		DataService.Release(player.UserId)
		return
	end
	EconomyService.Register(player, profile)
	InventoryService.Register(player) -- replicate item counts
	VIPService.OnJoin(player) -- gamepass ownership (yields, pcall'd)
	RewardRollService.OnJoin(player) -- paid-random policy check (yields)
	StateController.SyncPlayer(player) -- late-joiner state packet
end

Players.PlayerAdded:Connect(function(player: Player)
	task.spawn(onPlayerAdded, player)
end)
-- players who joined before this script initialized (edge case, but real)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player: Player)
	NetworkService.Unregister(player)
	InventoryService.Unregister(player)
	EconomyService.Unregister(player)
	task.spawn(DataService.Release, player.UserId) -- final save + lock release
end)

print("[HostileTakeover] server online —", #Players:GetPlayers(), "players present")
