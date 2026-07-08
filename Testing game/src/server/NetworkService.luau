--!strict
-- NetworkService ▸ binary wire protocol + token-bucket rate limiting.
--
-- No JSON, no raw tables. Every packet is a `buffer`:
--
--   Client → Server  "HT_Bid"   (5 bytes)
--     [0]    u8   optionIndex (1..3)
--     [1..4] u32  bid amount
--
--   Server → Client  "HT_State" (13 bytes, FireAllClients)
--     [0]     u8   state index (1=Lobby 2=Teleporting 3=Simulating 4=Payout 5=Revert)
--     [1..8]  f64  stateEndsAt (workspace:GetServerTimeNow() timebase —
--                  clients share this clock, so countdowns are sub-ms exact)
--     [9..11] u8×3 offered disaster ids
--     [12]    u8   winning disaster id (0 = none yet)
--
--   Server → Client  "HT_BidFeed" (30 bytes, FireAllClients)
--     [0]    u8   optionIndex
--     [1..4] u32  new running total for that option
--     [5]    u8   bidder name length N
--     [6..]  raw  name bytes (≤24; bytes past N are stale padding — the
--                 length prefix is authoritative, never trust the tail)
--
-- Example client sender (NOT shipped — no UI code on the server):
--   local b = buffer.create(5)
--   buffer.writeu8(b, 0, optionIndex)
--   buffer.writeu32(b, 1, amount)
--   bidRemote:FireServer(b)
--
-- Rate limiting: strict token bucket, capacity 4, refill 4/s. Continuous
-- refill (not fixed windows) means a ping spike that delivers two packets
-- back-to-back does NOT trip the limiter — only sustained spam drains it.
-- Violations are dropped SILENTLY: no kick, no reply, no false positives.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.GameConfig)

local NetworkService = {}

export type BidHandler = (player: Player, optionIndex: number, amount: number) -> ()

type Bucket = { Tokens: number, Stamp: number }

local RATE_CAP = Config.RateLimitPerSecond
local RATE_REFILL = Config.RateLimitPerSecond
local U32_MAX = 4294967295
local MAX_NAME = 24

local buckets: { [Player]: Bucket } = {}
local bidHandler: BidHandler? = nil

local bidRemote: RemoteEvent? = nil
local stateRemote: RemoteEvent? = nil
local feedRemote: RemoteEvent? = nil

-- Scratch buffers reused for every broadcast. FireAllClients serializes the
-- contents at call time, so immediate reuse is safe — zero allocation per
-- broadcast.
local statePacket = buffer.create(13)
local feedPacket = buffer.create(6 + MAX_NAME)

function NetworkService.Register(player: Player): ()
	buckets[player] = { Tokens = RATE_CAP, Stamp = os.clock() }
end

function NetworkService.Unregister(player: Player): ()
	buckets[player] = nil
end

local function writeStatePacket(stateIndex: number, endsAt: number, offered: { number }, winningId: number): ()
	buffer.writeu8(statePacket, 0, stateIndex)
	buffer.writef64(statePacket, 1, endsAt)
	buffer.writeu8(statePacket, 9, offered[1])
	buffer.writeu8(statePacket, 10, offered[2])
	buffer.writeu8(statePacket, 11, offered[3])
	buffer.writeu8(statePacket, 12, winningId)
end

function NetworkService.BroadcastState(
	stateIndex: number,
	endsAt: number,
	offered: { number },
	winningId: number
): ()
	local remote = stateRemote
	if remote == nil then
		return
	end
	writeStatePacket(stateIndex, endsAt, offered, winningId)
	remote:FireAllClients(statePacket)
end

-- Late-joiner sync: one targeted packet so a fresh client doesn't sit blind
-- until the next transition broadcast (up to 33s away).
function NetworkService.SendStateTo(
	player: Player,
	stateIndex: number,
	endsAt: number,
	offered: { number },
	winningId: number
): ()
	local remote = stateRemote
	if remote == nil then
		return
	end
	writeStatePacket(stateIndex, endsAt, offered, winningId)
	remote:FireClient(player, statePacket)
end

function NetworkService.BroadcastBid(optionIndex: number, newTotal: number, bidderName: string): ()
	local remote = feedRemote
	if remote == nil then
		return
	end
	local nameLen = math.min(#bidderName, MAX_NAME)
	buffer.writeu8(feedPacket, 0, optionIndex)
	buffer.writeu32(feedPacket, 1, math.min(newTotal, U32_MAX))
	buffer.writeu8(feedPacket, 5, nameLen)
	buffer.writestring(feedPacket, 6, bidderName, nameLen)
	remote:FireAllClients(feedPacket)
end

function NetworkService.Init(handler: BidHandler): ()
	bidHandler = handler

	local bid = Instance.new("RemoteEvent")
	bid.Name = "HT_Bid"
	bid.Parent = ReplicatedStorage
	bidRemote = bid

	local state = Instance.new("RemoteEvent")
	state.Name = "HT_State"
	state.Parent = ReplicatedStorage
	stateRemote = state

	local feed = Instance.new("RemoteEvent")
	feed.Name = "HT_BidFeed"
	feed.Parent = ReplicatedStorage
	feedRemote = feed

	bid.OnServerEvent:Connect(function(player: Player, data: unknown)
		-- ── 1) Token bucket (runs BEFORE any parsing: spam costs us nothing) ──
		local bucket = buckets[player]
		if bucket == nil then
			return -- fired before registration finished: drop
		end
		local now = os.clock()
		local tokens = math.min(RATE_CAP, bucket.Tokens + (now - bucket.Stamp) * RATE_REFILL)
		bucket.Stamp = now
		if tokens < 1 then
			bucket.Tokens = tokens
			return -- silent drop: violator learns nothing
		end
		bucket.Tokens = tokens - 1

		-- ── 2) Binary validation: exact type, exact size, exact ranges ──
		if typeof(data) ~= "buffer" then
			return
		end
		local b = data :: buffer
		if buffer.len(b) ~= Config.BidPacketSize then
			return
		end
		local optionIndex = buffer.readu8(b, 0)
		local amount = buffer.readu32(b, 1)
		if optionIndex < 1 or optionIndex > 3 or amount == 0 then
			return
		end

		-- ── 3) Hand off to the game layer (wallet check happens there) ──
		local h = bidHandler
		if h ~= nil then
			h(player, optionIndex, amount)
		end
	end)
end

return NetworkService
