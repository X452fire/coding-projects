--!strict
-- Theme ▸ the "Old Money" visual language + tiny instance factory.
-- Every UI module pulls colors/fonts from here so the whole interface can be
-- re-skinned from one file.

local Theme = {}

Theme.Bg = Color3.fromRGB(18, 24, 20) -- deep green-black
Theme.Panel = Color3.fromRGB(38, 28, 22) -- dark mahogany
Theme.PanelLight = Color3.fromRGB(54, 40, 30)
Theme.Gold = Color3.fromRGB(212, 175, 55)
Theme.Ivory = Color3.fromRGB(236, 229, 211)
Theme.Muted = Color3.fromRGB(150, 138, 118)
Theme.Danger = Color3.fromRGB(178, 52, 44)
Theme.Green = Color3.fromRGB(64, 106, 74)

Theme.Serif = Enum.Font.Garamond
Theme.SerifBold = Enum.Font.Bodoni

-- Generic instance factory: builds, assigns props, parents. UI construction
-- is cold-path code, so the (string-keyed) prop loop is a fine trade for
-- one-liner readability below.
function Theme.mk(className: string, props: { [string]: any }, parent: Instance?): Instance
	local inst = Instance.new(className)
	local target = inst :: any
	for key, value in props do
		target[key] = value
	end
	if parent ~= nil then
		inst.Parent = parent
	end
	return inst
end

function Theme.corner(radius: number, parent: Instance): UICorner
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
	return c
end

function Theme.stroke(color: Color3, thickness: number, parent: Instance): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Parent = parent
	return s
end

-- "$1,234,567" formatting for the HUD and auction totals.
function Theme.money(amount: number): string
	local out = tostring(math.floor(math.max(0, amount)))
	local count = 1
	repeat
		out, count = out:gsub("^(%d+)(%d%d%d)", "%1,%2")
	until count == 0
	return "$" .. out
end

return Theme
