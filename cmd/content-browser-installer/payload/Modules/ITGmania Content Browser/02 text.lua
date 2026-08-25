-- -----------------------------------------------------------------------
-- Text, numbers, dates and colours
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

local function Clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

-- encode a unicode codepoint as a utf-8 string (Lua 5.1, no utf8 lib)
local function CodepointToUtf8(n)
	if n < 0x80 then
		return string.char(n)
	elseif n < 0x800 then
		return string.char(0xC0 + math.floor(n/0x40), 0x80 + n%0x40)
	elseif n < 0x10000 then
		return string.char(0xE0 + math.floor(n/0x1000), 0x80 + math.floor(n/0x40)%0x40, 0x80 + n%0x40)
	else
		return string.char(0xF0 + math.floor(n/0x40000), 0x80 + math.floor(n/0x1000)%0x40, 0x80 + math.floor(n/0x40)%0x40, 0x80 + n%0x40)
	end
end

local function DecodeEntities(s)
	if not s then return "" end
	s = s:gsub("&#x(%x+);", function(h) return CodepointToUtf8(tonumber(h, 16)) end)
	s = s:gsub("&#(%d+);",  function(d) return CodepointToUtf8(tonumber(d)) end)
	s = s:gsub("&quot;", "\""):gsub("&apos;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&nbsp;", " ")
	s = s:gsub("&amp;", "&")
	return s
end

local function StripTags(s)
	if not s then return "" end
	return (s:gsub("<[bB][rR]%s*/?>", ", "):gsub("<[^>]*>", ""))
end

-- percent-encode a string so it can ride inside a URL query value
local function UrlEncode(s)
	return (tostring(s):gsub("[^%w%.%-_~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function Trim(s)
	if not s then return "" end
	return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local METER_MAX = 30   -- anything above this is a joke chart, not a difficulty

-- folder names and SMO pack names disagree about case and punctuation far
-- more often than they disagree about the actual pack
local function NormalizeName(s)
	local name = tostring(s or ""):lower():gsub("&", " and ")
	return (name:gsub("[^%w]", ""))
end

local function LooksLikeCredit(name)
	if #name < 2 or #name > 32 then return false end
	local lower = name:lower()
	if lower == "various" or lower == "unknown" or lower == "n/a" or lower == "none" then
		return false
	end
	-- Sentence punctuation, or more words than a handle would have. A full stop
	-- is NOT disqualifying: "G. Rosewood" is an initial and a surname, and
	-- rejecting it dropped the actual author of every song in a pack.
	if name:find("[!?]") then return false end
	local words = 0
	for _ in name:gmatch("%S+") do words = words + 1 end
	return words <= 4
end

local function CleanText(s)
	return Trim(DecodeEntities(StripTags(s)))
end

local function FormatBytes(n)
	n = tonumber(n) or 0
	if n >= 1024*1024*1024 then
		return string.format("%.2f GB", n/1024/1024/1024)
	elseif n >= 1024*1024 then
		return string.format("%.1f MB", n/1024/1024)
	elseif n > 0 then
		return string.format("%.0f KB", n/1024)
	end
	return ""
end

local MonthNames = {
	"January", "February", "March", "April", "May", "June",
	"July", "August", "September", "October", "November", "December",
}

-- "2026-03-14" -> "March 14, 2026" (or "Mar 14, 2026" when short).
-- Anything that isn't an ISO date is passed through untouched, which covers
-- the detail page's already-formatted "Mar. 14, 2026".
local function FormatDate(iso, short)
	if not iso or iso == "" then return "" end
	local y, m, d = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
	if not y then return iso end
	local name = MonthNames[tonumber(m)]
	if not name then return iso end
	if short then name = name:sub(1, 3) end
	return string.format("%s %d, %s", name, tonumber(d), y)
end

-- Green through yellow to red across the meter range, so the shape of a
-- pack's difficulty spread reads at a glance instead of being one flat colour.
local MeterColors = {
	{0.28, 0.76, 0.45},   -- 1-4    green
	{0.40, 0.84, 0.38},   -- 5-8    green
	{0.62, 0.88, 0.32},   -- 9-11   light green
	{0.94, 0.84, 0.28},   -- 12-13  yellow
	{0.97, 0.60, 0.24},   -- 14-15  orange
	{0.95, 0.34, 0.30},   -- 16-17  red
	{0.85, 0.20, 0.44},   -- 18+    deep red
}

local function MeterColor(meter, alpha)
	meter = tonumber(meter) or 0
	local i
	if     meter <= 4  then i = 1
	elseif meter <= 8  then i = 2
	elseif meter <= 11 then i = 3
	elseif meter <= 13 then i = 4
	elseif meter <= 15 then i = 5
	elseif meter <= 17 then i = 6
	else                    i = 7
	end
	local c = MeterColors[i]
	return c[1], c[2], c[3], alpha or 1
end

local function Commify(n)
	local s = tostring(n)
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.Clamp           = Clamp
CB.CleanText       = CleanText
CB.Commify         = Commify
CB.FormatBytes     = FormatBytes
CB.FormatDate      = FormatDate
CB.LooksLikeCredit = LooksLikeCredit
CB.METER_MAX       = METER_MAX
CB.MeterColor      = MeterColor
CB.NormalizeName   = NormalizeName
CB.StripTags       = StripTags
CB.Trim            = Trim
CB.UrlEncode       = UrlEncode
