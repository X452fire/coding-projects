--!strict
-- DataService ▸ mock-ProfileService persistence with SESSION LOCKING.
--
-- Why session locking: if a player server-hops rapidly, two servers can hold
-- the same profile at once — the classic dupe exploit. Every record carries
-- the owning server's JobId + a timestamp. A new server must either see the
-- lock released (L == "") or expired (older than SessionLockTTL) before it
-- may claim the profile; until then LoadProfile *yields and polls*.
--
-- Why bit-packing: the payload is serialized into a 12-byte binary buffer
-- (vs ~90 bytes of JSON for the same table). DataStores accept buffers
-- natively, so we store the buffer directly inside the lock record.
--
-- No raw SetAsync anywhere: every mutation goes through UpdateAsync so the
-- lock check and the write are one atomic transaction.

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.GameConfig)

local DataService = {}

export type Profile = {
	Cash: number,
	Streak: number,
	Flags: number, -- bitfield (bit 1 reserved: VIP pass owned)
	TotalEarned: number,
	SpeedTier: number, -- permanent shop speed boosts (0..MaxTier)
	Pity: number, -- super spins since the last "Super"-tier outcome
	Inventory: { [string]: number }, -- itemId → owned count (Config.Items)
}

type LockRecord = {
	L: string, -- owning JobId; "" = unlocked
	T: number, -- os.time() when the lock was stamped/renewed
	D: buffer?, -- bit-packed profile payload
}

type Session = { Profile: Profile, Key: string }

-- ── Binary schema ─────────────────────────────────────────────────────────
-- [0]      u8   schema version (migration hook)
-- [1..4]   u32  Cash
-- [5..6]   u16  Streak
-- [7]      u8   Flags bitfield
-- [8..11]  u32  TotalEarned
-- [12]     u8   SpeedTier (v2+)
-- [13]     u8   Pity counter (v3+)
-- [14..]   u16  × #ItemOrder inventory counts, in Config.ItemOrder order
--               (v3+; the order is append-only — see GameConfig)
local SCHEMA_VERSION = 3
local ITEM_COUNT = #Config.ItemOrder
local PACKED_SIZE = 14 + ITEM_COUNT * 2
local U32_MAX = 4294967295

local LOCK_TTL = Config.SessionLockTTL
local ACQUIRE_ATTEMPTS = 40 -- x 1.5s poll ≈ 60s worst-case wait
local ACQUIRE_POLL = 1.5
local AUTOSAVE_INTERVAL = 30 -- also renews the lock stamp

local JOB_ID = if game.JobId ~= "" then game.JobId else `STUDIO_{game.PlaceId}`

local sessions: { [number]: Session } = {}

local function pack(profile: Profile): buffer
	local b = buffer.create(PACKED_SIZE)
	buffer.writeu8(b, 0, SCHEMA_VERSION)
	buffer.writeu32(b, 1, math.clamp(math.floor(profile.Cash), 0, U32_MAX))
	buffer.writeu16(b, 5, math.clamp(math.floor(profile.Streak), 0, 65535))
	buffer.writeu8(b, 7, profile.Flags % 256)
	buffer.writeu32(b, 8, math.clamp(math.floor(profile.TotalEarned), 0, U32_MAX))
	buffer.writeu8(b, 12, math.clamp(math.floor(profile.SpeedTier), 0, 255))
	buffer.writeu8(b, 13, math.clamp(math.floor(profile.Pity), 0, 255))
	for i = 1, ITEM_COUNT do
		local count = profile.Inventory[Config.ItemOrder[i]] or 0
		buffer.writeu16(b, 14 + (i - 1) * 2, math.clamp(math.floor(count), 0, 65535))
	end
	return b
end

local function unpack_(b: buffer): Profile?
	if buffer.len(b) < 12 then
		return nil
	end
	local version = buffer.readu8(b, 0)
	if version < 1 or version > SCHEMA_VERSION then
		return nil -- unknown schema: treat as fresh
	end
	-- older versions simply lack the trailing fields: migrate with defaults
	local inventory: { [string]: number } = {}
	if version >= 3 and buffer.len(b) >= PACKED_SIZE then
		for i = 1, ITEM_COUNT do
			local count = buffer.readu16(b, 14 + (i - 1) * 2)
			if count > 0 then
				inventory[Config.ItemOrder[i]] = count
			end
		end
	end
	return {
		Cash = buffer.readu32(b, 1),
		Streak = buffer.readu16(b, 5),
		Flags = buffer.readu8(b, 7),
		TotalEarned = buffer.readu32(b, 8),
		SpeedTier = if version >= 2 and buffer.len(b) >= 13 then buffer.readu8(b, 12) else 0,
		Pity = if version >= 3 and buffer.len(b) >= 14 then buffer.readu8(b, 13) else 0,
		Inventory = inventory,
	}
end

local function newProfile(): Profile
	return {
		Cash = Config.StartingCash,
		Streak = 0,
		Flags = 0,
		TotalEarned = 0,
		SpeedTier = 0,
		Pity = 0,
		Inventory = {},
	}
end

-- ── Store access with an in-memory Studio fallback ───────────────────────
-- GetDataStore throws in Studio when API access is off; the mock keeps the
-- whole game bootable offline with identical UpdateAsync semantics.
local liveStore: DataStore? = nil
do
	local ok, store = pcall(function(): DataStore
		return DataStoreService:GetDataStore(Config.DataStoreName)
	end)
	if ok then
		liveStore = store
	else
		warn("[Data] DataStore unavailable — using in-memory mock store")
	end
end
local mockStore: { [string]: LockRecord } = {}

-- Atomic read-modify-write. Returning nil from `transform` aborts the write
-- (this is how we refuse to steal a live foreign lock).
local function updateRecord(key: string, transform: (LockRecord?) -> LockRecord?): boolean
	local store = liveStore
	if store == nil then
		local result = transform(mockStore[key])
		if result ~= nil then
			mockStore[key] = result
		end
		return true
	end
	local ok, err = pcall(function()
		store:UpdateAsync(key, transform)
	end)
	if not ok then
		warn(`[Data] UpdateAsync failed for {key}: {err}`)
	end
	return ok
end

-- Claim the profile. YIELDS while another server's lock is alive — this is
-- the anti-duplication guarantee. Returns nil only if the lock never drains.
function DataService.LoadProfile(userId: number): Profile?
	local key = `p_{userId}`
	for _ = 1, ACQUIRE_ATTEMPTS do
		local acquired: Profile? = nil
		local okCall = updateRecord(key, function(old: LockRecord?): LockRecord?
			local now = os.time()
			if old ~= nil and old.L ~= "" and old.L ~= JOB_ID and (now - old.T) < LOCK_TTL then
				return nil -- live foreign lock: abort, poll again
			end
			local profile = if old ~= nil and old.D ~= nil then unpack_(old.D :: buffer) else nil
			if profile == nil then
				profile = newProfile()
			end
			acquired = profile
			return { L = JOB_ID, T = now, D = pack(profile :: Profile) }
		end)
		if okCall and acquired ~= nil then
			sessions[userId] = { Profile = acquired :: Profile, Key = key }
			return acquired
		end
		task.wait(ACQUIRE_POLL)
	end
	return nil
end

local function saveSession(userId: number, releasing: boolean): ()
	local session = sessions[userId]
	if session == nil then
		return
	end
	local packed = pack(session.Profile) -- snapshot BEFORE yielding
	updateRecord(session.Key, function(old: LockRecord?): LockRecord?
		if old ~= nil and old.L ~= "" and old.L ~= JOB_ID then
			return nil -- another server claimed it (our lock expired): never clobber
		end
		return { L = if releasing then "" else JOB_ID, T = os.time(), D = packed }
	end)
	if releasing then
		sessions[userId] = nil
	end
end

-- Final save + lock release on leave.
function DataService.Release(userId: number): ()
	saveSession(userId, true)
end

-- Live profile handle for services beyond EconomyService (InventoryService,
-- RewardRollService). Mutations are captured by the autosave cycle.
function DataService.GetProfile(userId: number): Profile?
	local session = sessions[userId]
	return if session ~= nil then session.Profile else nil
end

function DataService.Init(): ()
	-- One centralized autosave/lock-renewal accumulator. Renewing T every
	-- 30s keeps our lock alive (TTL 90s) even across long sessions.
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < AUTOSAVE_INTERVAL then
			return
		end
		acc = 0
		for userId in sessions do
			task.spawn(saveSession, userId, false)
		end
	end)

	-- Server shutdown: flush and release every live session (BindToClose
	-- gives us up to 30s; these saves run serially and each yields).
	game:BindToClose(function()
		for userId in sessions do
			saveSession(userId, true)
		end
	end)
end

return DataService
