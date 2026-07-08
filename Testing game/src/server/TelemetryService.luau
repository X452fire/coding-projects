--!strict
-- TelemetryService ▸ centralized economy/event logging.
--
-- Two tiers, both allocation-free after startup:
--  * Count(name, delta)  — hot-path aggregate counters (called every income
--    tick, every payout). Just dictionary adds.
--  * Log(event, userId, value) — discrete events (purchases, spins, wins)
--    recorded into a preallocated 512-slot ring buffer whose entry tables
--    are reused, never reallocated.
--
-- Every 60s an economy report prints minted vs sunk cash — the inflation
-- dashboard. GetCounters/GetRecent exist so an ops panel (or an external
-- sink like MessagingService/HttpService) can drain the same data later.

local RunService = game:GetService("RunService")

local TelemetryService = {}

export type LogEntry = {
	Event: string,
	UserId: number,
	Value: number,
	Time: number,
}

local RING_SIZE = 512
local REPORT_INTERVAL = 60

local counters: { [string]: number } = {}
local ring: { LogEntry } = table.create(RING_SIZE)
local ringCursor = 0 -- last written slot (1..RING_SIZE)
local ringCount = 0

-- Preallocate every ring slot once; Log() only mutates fields.
for i = 1, RING_SIZE do
	ring[i] = { Event = "", UserId = 0, Value = 0, Time = 0 }
end

-- Hot-path aggregate. Safe to call every frame.
function TelemetryService.Count(name: string, delta: number): ()
	counters[name] = (counters[name] or 0) + delta
end

-- Discrete event: counted AND ring-logged (reused slot, zero alloc).
function TelemetryService.Log(event: string, userId: number, value: number): ()
	TelemetryService.Count(event, value)
	ringCursor = ringCursor % RING_SIZE + 1
	ringCount = math.min(ringCount + 1, RING_SIZE)
	local slot = ring[ringCursor]
	slot.Event = event
	slot.UserId = userId
	slot.Value = value
	slot.Time = os.time()
end

function TelemetryService.GetCounter(name: string): number
	return counters[name] or 0
end

-- Visit the newest `limit` entries, newest first (no copies handed out).
function TelemetryService.GetRecent(limit: number, visit: (LogEntry) -> ()): ()
	local n = math.min(limit, ringCount)
	for i = 0, n - 1 do
		local index = (ringCursor - 1 - i) % RING_SIZE + 1
		visit(ring[index])
	end
end

function TelemetryService.Init(): ()
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < REPORT_INTERVAL then
			return
		end
		acc = 0
		local minted = (counters.income or 0)
			+ (counters.payout or 0)
			+ (counters.spin_award or 0)
			+ (counters.bribe or 0)
		local sunk = (counters.bids or 0) + (counters.shop_spend or 0) + (counters.spin_spend or 0)
		print(
			`[Telemetry] minted={minted} sunk={sunk} net={minted - sunk}`
				.. ` | spins std={counters.spin_standard or 0} super={counters.spin_super or 0}`
				.. ` | shop buys={counters.shop_buy or 0} | receipts={counters.receipt or 0}`
		)
	end)
end

return TelemetryService
