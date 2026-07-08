--!strict
-- Net (client) ▸ the other half of NetworkService's binary protocol.
-- Encodes outgoing bids and decodes incoming state/feed buffers. All packet
-- layouts are documented in src/server/NetworkService.luau.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = {}

export type StateCallback = (stateIndex: number, endsAt: number, offered: { number }, winningId: number) -> ()
export type FeedCallback = (optionIndex: number, newTotal: number, bidderName: string) -> ()

local bidRemote = ReplicatedStorage:WaitForChild("HT_Bid") :: RemoteEvent
local stateRemote = ReplicatedStorage:WaitForChild("HT_State") :: RemoteEvent
local feedRemote = ReplicatedStorage:WaitForChild("HT_BidFeed") :: RemoteEvent

-- One reusable 5-byte scratch buffer; FireServer copies at call time.
local sendBuf = buffer.create(5)

function Net.SendBid(optionIndex: number, amount: number): ()
	buffer.writeu8(sendBuf, 0, optionIndex)
	buffer.writeu32(sendBuf, 1, math.clamp(math.floor(amount), 1, 4294967295))
	bidRemote:FireServer(sendBuf)
end

function Net.OnState(callback: StateCallback): ()
	stateRemote.OnClientEvent:Connect(function(data: unknown)
		if typeof(data) ~= "buffer" then
			return
		end
		local b = data :: buffer
		if buffer.len(b) < 13 then
			return
		end
		callback(
			buffer.readu8(b, 0),
			buffer.readf64(b, 1),
			{ buffer.readu8(b, 9), buffer.readu8(b, 10), buffer.readu8(b, 11) },
			buffer.readu8(b, 12)
		)
	end)
end

function Net.OnFeed(callback: FeedCallback): ()
	feedRemote.OnClientEvent:Connect(function(data: unknown)
		if typeof(data) ~= "buffer" then
			return
		end
		local b = data :: buffer
		if buffer.len(b) < 6 then
			return
		end
		local nameLen = buffer.readu8(b, 5)
		if buffer.len(b) < 6 + nameLen then
			return
		end
		callback(buffer.readu8(b, 0), buffer.readu32(b, 1), buffer.readstring(b, 6, nameLen))
	end)
end

return Net
