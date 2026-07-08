--!strict
-- Janitor ▸ deterministic cleanup container (Maid pattern).
-- Every disaster run gets its own Janitor. Connections, instances, tweens,
-- and threads are appended during execution; Cleanup() obliterates all of
-- them in LIFO order during the Revert state, guaranteeing zero leaked
-- references between rounds.
--
-- Memory notes:
--  * The item array is preallocated (table.create) and slots are recycled
--    with a `false` sentinel instead of nil, keeping the array dense and
--    avoiding rehash churn in the GC.
--  * Cleanup never allocates; it walks the array with a numeric for loop.

local Janitor = {}
Janitor.__index = Janitor

export type CleanupItem = RBXScriptConnection | Instance | thread | () -> ()

type Fields = {
	_items: { CleanupItem | false },
	_count: number,
}
export type Janitor = typeof(setmetatable({} :: Fields, Janitor))

function Janitor.new(capacity: number?): Janitor
	return setmetatable({
		_items = table.create(capacity or 16, false) :: { CleanupItem | false },
		_count = 0,
	}, Janitor)
end

-- Append a resource for later destruction. Returns nothing on purpose:
-- callers keep their own reference; the Janitor only owns teardown.
function Janitor.Add(self: Janitor, item: CleanupItem): ()
	local n = self._count + 1
	self._count = n
	self._items[n] = item
end

-- Destroy everything in reverse (LIFO) order: connections created on top of
-- instances die before the instances they observe.
function Janitor.Cleanup(self: Janitor): ()
	local items = self._items
	for i = self._count, 1, -1 do
		local item = items[i]
		items[i] = false -- sentinel: slot stays allocated, ref is released

		if item == false then
			-- already-recycled slot, nothing to do
		elseif typeof(item) == "RBXScriptConnection" then
			item:Disconnect()
		elseif typeof(item) == "Instance" then
			if item:IsA("Tween") then
				item:Cancel() -- stop playback before the handle dies
			end
			item:Destroy()
		elseif typeof(item) == "thread" then
			if coroutine.status(item) ~= "dead" then
				task.cancel(item)
			end
		elseif type(item) == "function" then
			local ok, err = pcall(item)
			if not ok then
				warn(`[Janitor] cleanup callback failed: {err}`)
			end
		end
	end
	self._count = 0
end

return Janitor
