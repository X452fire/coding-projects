--!strict
-- BufferNetwork ▸ cursor-based writer/reader over the Luau `buffer` library.
-- Shared by server and client so every new packet is defined once. Writers
-- are preallocated and reset per send (zero allocation on the hot path);
-- `finish` trims to the written length only when the payload is variable.

local BufferNetwork = {}

export type Cursor = { Buf: buffer, Pos: number }

function BufferNetwork.writer(capacity: number): Cursor
	return { Buf = buffer.create(capacity), Pos = 0 }
end

function BufferNetwork.reader(b: buffer): Cursor
	return { Buf = b, Pos = 0 }
end

function BufferNetwork.reset(c: Cursor): ()
	c.Pos = 0
end

-- Bytes left to read — validate BEFORE reading; never trust packet length.
function BufferNetwork.remaining(c: Cursor): number
	return buffer.len(c.Buf) - c.Pos
end

-- ── writes ────────────────────────────────────────────────────────────────

function BufferNetwork.writeU8(c: Cursor, value: number): ()
	buffer.writeu8(c.Buf, c.Pos, value)
	c.Pos += 1
end

function BufferNetwork.writeU16(c: Cursor, value: number): ()
	buffer.writeu16(c.Buf, c.Pos, value)
	c.Pos += 2
end

function BufferNetwork.writeU32(c: Cursor, value: number): ()
	buffer.writeu32(c.Buf, c.Pos, value)
	c.Pos += 4
end

function BufferNetwork.writeF64(c: Cursor, value: number): ()
	buffer.writef64(c.Buf, c.Pos, value)
	c.Pos += 8
end

-- Length-prefixed string (u8 length, ≤255 bytes).
function BufferNetwork.writeString(c: Cursor, value: string): ()
	local len = math.min(#value, 255)
	buffer.writeu8(c.Buf, c.Pos, len)
	buffer.writestring(c.Buf, c.Pos + 1, value, len)
	c.Pos += 1 + len
end

-- Trimmed copy for variable-length payloads (FireServer copies anyway, but
-- trimming avoids shipping stale tail bytes).
function BufferNetwork.finish(c: Cursor): buffer
	if c.Pos == buffer.len(c.Buf) then
		return c.Buf
	end
	local out = buffer.create(c.Pos)
	buffer.copy(out, 0, c.Buf, 0, c.Pos)
	return out
end

-- ── reads (caller checks `remaining` first; these do not throw) ──────────

function BufferNetwork.readU8(c: Cursor): number
	local v = buffer.readu8(c.Buf, c.Pos)
	c.Pos += 1
	return v
end

function BufferNetwork.readU16(c: Cursor): number
	local v = buffer.readu16(c.Buf, c.Pos)
	c.Pos += 2
	return v
end

function BufferNetwork.readU32(c: Cursor): number
	local v = buffer.readu32(c.Buf, c.Pos)
	c.Pos += 4
	return v
end

function BufferNetwork.readF64(c: Cursor): number
	local v = buffer.readf64(c.Buf, c.Pos)
	c.Pos += 8
	return v
end

-- Returns nil on malformed length instead of throwing.
function BufferNetwork.readString(c: Cursor): string?
	if BufferNetwork.remaining(c) < 1 then
		return nil
	end
	local len = buffer.readu8(c.Buf, c.Pos)
	c.Pos += 1
	if BufferNetwork.remaining(c) < len then
		return nil
	end
	local s = buffer.readstring(c.Buf, c.Pos, len)
	c.Pos += len
	return s
end

return BufferNetwork
