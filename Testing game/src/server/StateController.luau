--!strict
-- StateController ▸ the deterministic five-phase state machine.
--
--   Lobby (30s)       bids live in the boardroom
--   → Teleporting (2s) winner resolved, arena cloned from ServerStorage,
--                      every active player batch-PivotTo'd into the spawn
--                      zone (hub positions cached for the return trip)
--   → Simulating (20s) the minigame runs
--   → Payout (3s)      surviving-bidder ledger settles (EconomyService)
--   → Revert (3s)      minigame wiped, arena destroyed, survivors returned
--   → Lobby …          (58s full cycle)
--
-- Scheduling: NO `while true do` anywhere. A single RunService.Heartbeat
-- connection is the scheduler; every frame it compares
-- workspace:GetServerTimeNow() — the sub-millisecond, client/server
-- synchronized clock — against a precomputed deadline.
--
-- Yielding safety / watchdog: the scheduler OWNS the clock. A minigame that
-- hangs cannot stall the machine because Simulating's deadline fires
-- regardless, and Revert force-cancels the minigame thread (see
-- MinigameService.Revert). Transitions run through task.defer so a slow
-- enter-handler can never wedge the Heartbeat callback.
--
-- Memory: all round data is preallocated once and wiped in place with
-- numeric loops each round — the Heartbeat path performs zero allocations.
-- `0` is the sentinel for "no veto" / "no winner".

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.GameConfig)
local EconomyService = require(script.Parent.EconomyService)
local MinigameService = require(script.Parent.MinigameService)
local NetworkService = require(script.Parent.NetworkService)
local InventoryService = require(script.Parent.InventoryService)

local StateController = {}

export type StateName = "Lobby" | "Teleporting" | "Simulating" | "Payout" | "Revert"
export type VetoVerdict = "Granted" | "Locked"

local STATE_ORDER = table.freeze({ "Lobby", "Teleporting", "Simulating", "Payout", "Revert" } :: { StateName })
local LOBBY, TELEPORTING, SIMULATING, PAYOUT, REVERT = 1, 2, 3, 4, 5
local STATE_COUNT = 5
local DURATIONS: { number } = table.freeze({
	Config.StateDurations.Lobby,
	Config.StateDurations.Teleporting,
	Config.StateDurations.Simulating,
	Config.StateDurations.Payout,
	Config.StateDurations.Revert,
})

local OPTION_COUNT = 3
local MINIGAME_COUNT = #Config.Minigames
-- Board Veto race lock: purchases landing inside this window (or mid-
-- transition) are refused with NotProcessedYet — see TryVeto.
local VETO_SAFETY_WINDOW = 0.25

-- ── Hot state: flat locals, no table indirection in the Heartbeat path ──
local stateIndex = LOBBY
local stateEndsAt = 0
local transitioning = false

-- ── Round data: preallocated once, wiped in place per round ──
local offered: { number } = table.create(OPTION_COUNT, 0)
local bidTotals: { number } = table.create(OPTION_COUNT, 0)
local idDeck: { number } = table.create(MINIGAME_COUNT, 0)
local lastBidOption: { [number]: number } = {} -- userId → option they backed
local vetoOption = 0 -- 0 = sentinel: no veto this round
local winnerIndex = 0 -- resolved option index (1..3)
local winningId = 0 -- resolved minigame id; 0 = nothing yet
local roundRng = Random.new(0)

-- ── Teleportation framework ──
-- Hub positions cached at Teleporting, restored for survivors at Revert.
local lobbyReturns: { [number]: CFrame } = {}
local scratchPlayers: { Player } = table.create(64) -- reused snapshot buffer

-- ── Enter handlers (must not yield; heavy work is spawned, never inlined) ──

local function enterLobby(): ()
	EconomyService.ResetRound() -- wipe the payout ledger
	roundRng = Random.new(math.floor(workspace:GetServerTimeNow() * 1000) % 2147483647)

	for i = 1, OPTION_COUNT do
		bidTotals[i] = 0
	end
	table.clear(lastBidOption)
	vetoOption = 0
	winnerIndex = 0
	winningId = 0

	-- Partial Fisher–Yates over the id deck → distinct minigames, no
	-- rejection sampling, no allocation.
	for i = 1, MINIGAME_COUNT do
		idDeck[i] = i
	end
	for i = 1, OPTION_COUNT do
		local j = roundRng:NextInteger(i, MINIGAME_COUNT)
		idDeck[i], idDeck[j] = idDeck[j], idDeck[i]
		offered[i] = idDeck[i]
	end
end

local function enterTeleporting(): ()
	-- 1) Resolve the winning option: veto beats cash, cash beats apathy.
	if vetoOption ~= 0 then
		winnerIndex = vetoOption
	else
		winnerIndex = 1
		local best = bidTotals[1]
		for i = 2, OPTION_COUNT do
			if bidTotals[i] > best then
				best = bidTotals[i]
				winnerIndex = i
			end
		end
		if best == 0 then
			winnerIndex = roundRng:NextInteger(1, OPTION_COUNT) -- dead lobby: house picks
		end
	end
	winningId = offered[winnerIndex]

	-- 2) Clone the arena from ServerStorage into Workspace.
	if MinigameService.LoadMap(winningId) == nil then
		return -- broken template: skip the round gracefully
	end

	-- 3) Batch-teleport every active player into the spawn zone, caching
	--    their hub position for the Revert return trip.
	table.clear(lobbyReturns)
	local spawnCF = MinigameService.GetSpawnCFrame()
	local count = EconomyService.GetAliveSnapshot(scratchPlayers)
	for i = 1, count do
		local player = scratchPlayers[i]
		local character = player.Character
		if character ~= nil and character.Parent ~= nil then
			lobbyReturns[player.UserId] = character:GetPivot()
			-- fan players out in a ring so nobody spawns inside anybody
			local angle = (i / count) * 2 * math.pi
			character:PivotTo(spawnCF * CFrame.new(math.cos(angle) * 9, 0, math.sin(angle) * 9))
		end
	end
end

local function enterSimulating(): ()
	local duration = if winningId ~= 0
		then Config.Minigames[winningId].Duration
		else Config.StateDurations.Simulating
	MinigameService.Execute(winningId, duration) -- own (cancellable) thread

	-- materialize consumed round buffs (Legal Shield etc.) for everyone who
	-- made it into the arena
	local count = EconomyService.GetAliveSnapshot(scratchPlayers)
	local inArena = 0
	for i = 1, count do
		if MinigameService.IsInArena(scratchPlayers[i]) then
			inArena += 1
			scratchPlayers[inArena] = scratchPlayers[i]
		end
	end
	InventoryService.ApplyRoundBuffs(scratchPlayers, inArena)
end

local function enterPayout(): ()
	-- Survivors = alive AND still standing inside the arena (players who
	-- died and respawned are back at the hub, so the bounds check drops
	-- them). Compacted in place into the front of the scratch buffer.
	local count = EconomyService.GetAliveSnapshot(scratchPlayers)
	local survivorCount = 0
	for i = 1, count do
		local player = scratchPlayers[i]
		if MinigameService.IsInArena(player) then
			survivorCount += 1
			scratchPlayers[survivorCount] = player
		end
	end
	local multiplier = if winningId ~= 0 then Config.Minigames[winningId].Multiplier else 1
	EconomyService.SettleRound(winnerIndex, multiplier, scratchPlayers, survivorCount)
end

local function enterRevert(): ()
	-- 1) Watchdog-cancel the minigame + Janitor sweep + arena demolition.
	MinigameService.Revert()
	InventoryService.ClearRoundBuffs() -- every session buff expires here

	-- 2) Return everyone still in the arena to their cached hub position.
	--    (Dead players already respawned at the hub SpawnLocation.)
	for userId, returnCFrame in lobbyReturns do
		local player = Players:GetPlayerByUserId(userId)
		if player ~= nil and MinigameService.IsInArena(player) then
			local character = player.Character
			if character ~= nil then
				character:PivotTo(returnCFrame)
			end
		end
	end
	table.clear(lobbyReturns)
end

local ENTER = table.freeze({ enterLobby, enterTeleporting, enterSimulating, enterPayout, enterRevert })

-- Deferred transition: the Heartbeat callback never executes handler code
-- directly, and a throwing handler can't break the cycle (pcall + the
-- deadline is stamped AFTER the handler either way).
local function advance(): ()
	transitioning = true
	task.defer(function()
		stateIndex = stateIndex % STATE_COUNT + 1
		local ok, err = pcall(ENTER[stateIndex])
		if not ok then
			warn(`[State] enter {STATE_ORDER[stateIndex]} failed: {err}`)
		end
		-- dynamic Simulating: the winning minigame's own Duration rules
		local phaseLength = DURATIONS[stateIndex]
		if stateIndex == SIMULATING and winningId ~= 0 then
			phaseLength = Config.Minigames[winningId].Duration
		end
		stateEndsAt = workspace:GetServerTimeNow() + phaseLength
		transitioning = false
		NetworkService.BroadcastState(stateIndex, stateEndsAt, offered, winningId)
	end)
end

function StateController.Init(): ()
	enterLobby() -- seed the first round's options before anyone bids
	stateEndsAt = workspace:GetServerTimeNow() + DURATIONS[LOBBY]
	RunService.Heartbeat:Connect(function()
		if transitioning then
			return -- a deferred transition is in flight
		end
		if workspace:GetServerTimeNow() >= stateEndsAt then
			advance()
		end
	end)
end

-- Real player bid (already type/range-validated by NetworkService). Bidding
-- is open during LOBBY. Bids are ESCROWED: cash leaves the wallet the
-- moment the bid lands, and the payout ledger records the stake.
function StateController.PlaceBid(player: Player, optionIndex: number, amount: number): ()
	if transitioning or stateIndex ~= LOBBY then
		return
	end
	if optionIndex < 1 or optionIndex > OPTION_COUNT then
		return
	end
	local userId = player.UserId
	if not EconomyService.TryWithdraw(userId, amount) then
		return -- insufficient funds: silently ignored (client shows balance)
	end
	EconomyService.RecordBid(userId, optionIndex, amount)
	bidTotals[optionIndex] += amount
	lastBidOption[userId] = optionIndex
	NetworkService.BroadcastBid(optionIndex, bidTotals[optionIndex], player.Name)
end

-- Board Veto (called from ProcessReceipt). RACE-CONDITION LOCK: if the
-- purchase lands mid-transition, outside the Lobby, or inside the final
-- 250ms (where the scheduler may flip states before this call takes
-- effect), we return "Locked" and Monetization answers NotProcessedYet so
-- Roblox redelivers the receipt instead of eating the player's Robux.
function StateController.TryVeto(player: Player): VetoVerdict
	if transitioning or stateIndex ~= LOBBY then
		return "Locked"
	end
	local now = workspace:GetServerTimeNow()
	if stateEndsAt - now < VETO_SAFETY_WINDOW then
		return "Locked"
	end
	-- The veto forces the option the buyer last backed (default: option 1).
	vetoOption = lastBidOption[player.UserId] or 1
	stateEndsAt = now -- fast-forward: the lobby resolves on the next frame
	return "Granted"
end

function StateController.GetState(): StateName
	return STATE_ORDER[stateIndex]
end

-- Push the current machine state to one (late-joining) client.
function StateController.SyncPlayer(player: Player): ()
	NetworkService.SendStateTo(player, stateIndex, stateEndsAt, offered, winningId)
end

return StateController
