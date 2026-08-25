-- -----------------------------------------------------------------------
-- What a pack is, and which ones are on show
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local FEAT  = CB.FEAT
local ROWS  = CB.ROWS
local state = CB.state

local function TotalPages()
	if state.filtered <= 0 then return 1 end
	return math.max(1, math.ceil(state.filtered / ROWS))
end

-- The featured cursor is really a (page, row, column).  A page is the whole
-- grid, so Left/Right walk a row and carry to the next page rather than
-- wrapping into the row below; Up/Down are the only way between the two rows.
-- cards actually on offer.  #cards can run past the target because of the
-- BUILD surplus, and the surplus must not be reachable.
function FEAT.Count()
	return math.min(#state.featured.cards, FEAT.TARGET)
end

function FEAT.Page()
	return math.floor(state.featWindow / FEAT.VISIBLE)
end

function FEAT.RowCol()
	local slot = state.featCursor - state.featWindow   -- 1 .. FEAT.VISIBLE
	return math.floor((slot - 1) / FEAT.COLS), (slot - 1) % FEAT.COLS
end

-- move to an absolute (page, row, column); false when nothing is there, which
-- is what makes the edges of the grid feel solid
function FEAT.Goto(page, row, col)
	if page < 0 or row < 0 or row >= FEAT.ROWS then return false end
	if col < 0 or col >= FEAT.COLS then return false end
	local index = page * FEAT.VISIBLE + row * FEAT.COLS + col + 1
	if index < 1 or index > FEAT.Count() then return false end
	state.featWindow = page * FEAT.VISIBLE
	state.featCursor = index
	return true
end

local function CurrentPack()
	-- Detail/confirm views pin the pack that opened them, so an in-flight
	-- page fetch replacing the list can't swap the pack mid-view.
	if (state.mode == "detail" or state.mode == "confirm") and state.selected then
		return state.selected
	end
	-- the doubles view draws two columns of its own instead of a page of the
	-- list, so its focus is wherever its own cursor is
	if state.mode == "doubles" then
		local d = state.doubles
		local list = (d.col == 2) and d.right or d.left
		return list[d.win[d.col] + d.row]
	end
	-- otherwise: a featured card when the cursor is in the featured grid,
	-- else the selected list row
	if state.zone == "featured" then
		local card = state.featured.cards[state.featCursor]
		return card and card.pack
	end
	return state.packs[state.cursor]
end

-- pack type helpers (pad/keyboard filter) --------------------------------

local function PackTypeOf(id)
	return state.packTypes and state.packTypes[tostring(id)]
end

-- This browser is for dance packs. The pack list only reports the GAME a pack
-- targets ("dance", "pump", "kb7"), so that is what can be filtered there; the
-- finer chart types live on the pack page and are checked by DanceChartsOnly
-- wherever a detail page has been loaded anyway. A pack the site reported
-- nothing for is kept: absent data is not evidence of a foreign game.
local function DanceOnly(pack)
	local types = pack.types
	if not types or #types == 0 then return true end
	for kind in ivalues(types) do
		if tostring(kind):lower() ~= "dance" then return false end
	end
	return true
end

-- the only chart types this browser shows
local DanceChartTypes = {
	["dance-single"] = true,
	["dance-double"] = true,
}

-- true when every chart in the pack is dance single or double
local function DanceChartsOnly(det)
	if not det or not det.chartTypes then return true end
	local seen = false
	for kind in pairs(det.chartTypes) do
		seen = true
		if not DanceChartTypes[kind] then return false end
	end
	return seen or true
end

-- Banners are meant to be roughly 256x80.  Some packs ship something far
-- wider, which blows the row and card layouts apart, so those are dropped once
-- the image has actually been measured.  A pack with no banner at all is kept:
-- it may simply be missing one.
local BANNER_MIN_ASPECT = 2.40
local BANNER_MAX_ASPECT = 3.40

local function BannerShapeOk(pack)
	-- CSV-sourced rows (keyboard mode, search results) carry no banner in the
	-- row data at all; their art arrives with the detail page, so they are
	-- judged once it has
	if pack.csvOnly then return true end
	local url = pack.banner
	if not url then return false end           -- no banner: not in the listing
	local aspect = state.bannerAspect[url]
	if not aspect then return true end         -- not measured yet
	return aspect >= BANNER_MIN_ASPECT and aspect <= BANNER_MAX_ASPECT
end

local function PassesFilter(pack)
	if not DanceOnly(pack) then return false end
	if not BannerShapeOk(pack) then return false end
	local ptype = PackTypeOf(pack.id)
	if state.filterMode == "pad" then
		return ptype ~= "keyboard"
	elseif state.filterMode == "keyboard" then
		return ptype == "keyboard"
	end
	return true
end

local FilterLabels = {
	pad      = "Pad packs",
	keyboard = "Keyboard packs",
}

-- date helpers for the featured window -----------------------------------

local function CurrentYear()
	local ok, y = pcall(function() return Year() end)
	if ok and type(y) == "number" and y > 2000 then return y end
	return 2026
end

-- 1-based month number (MonthOfYear() is 0-based)
local function CurrentMonth()
	local ok, mm = pcall(function() return MonthOfYear() end)
	if ok and type(mm) == "number" then return mm + 1 end
	return 1
end

local function CurrentDay()
	local ok, d = pcall(function() return DayOfMonth() end)
	if ok and type(d) == "number" and d >= 1 then return d end
	return 1
end

-- n months back, as a sortable "YYYY-MM-DD".  The day is clamped to 28 so a
-- window that lands on the 31st cannot roll into the wrong month.
local function MonthsAgoStr(n)
	local y, m = CurrentYear(), CurrentMonth() - n
	while m < 1 do
		m = m + 12
		y = y - 1
	end
	return string.format("%04d-%02d-%02d", y, m, math.min(CurrentDay(), 28))
end

local MonthAbbrevIndex = {
	jan = 1, feb = 2, mar = 3, apr = 4,  may = 5,  jun = 6,
	jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12,
}

-- "Mar. 14, 2026", the format the pack page prints, -> sortable "2026-03-14"
local function IsoFromLongDate(text)
	if not text or text == "" then return "" end
	local mon, day, year = text:match("^(%a+)%.?%s+(%d+),%s*(%d%d%d%d)")
	if not mon then return "" end
	local m = MonthAbbrevIndex[mon:sub(1, 3):lower()]
	if not m then return "" end
	return string.format("%04d-%02d-%02d", tonumber(year), m, tonumber(day))
end

local function AccentColor()
	return GetCurrentColor and GetCurrentColor() or Color.White
end

local function PlaySfx(what)
	local path
	if what == "change" then path = THEME:GetPathS("ScreenSelectMaster", "change")
	-- the title menu has its own cursor sound (Sounds/ScreenTitleMenu change.redir
	-- -> "_next row"), so our entry clicks like the native choices do
	elseif what == "titlechange" then path = THEME:GetPathS("ScreenTitleMenu", "change")
	elseif what == "start" then path = THEME:GetPathS("Common", "Start")
	elseif what == "cancel" then path = THEME:GetPathS("Common", "Cancel")
	elseif what == "invalid" then path = THEME:GetPathS("Common", "invalid")
	end
	if path then SOUND:PlayOnce(path) end
end

-- ------------------------------------------------------------ download queue
--
-- Nothing about a download was ever tied to the screen that started it: each
-- pack has its own request and its own progress callback, and the engine runs
-- them side by side. What was missing was somewhere to watch them from once you
-- had navigated away, which needs a stable order -- pairs() over the downloads
-- table would deal the queue a new order every frame.
-- Declared here rather than where its contents are, because Lua binds a name
-- when it compiles the line that mentions it: a local declared further down the
-- file is not the same name to the code above it, it is a global, and a global
-- nobody sets is nil. The download prompt asks LO whether there is disk room
-- for a pack, and that call sits well above where the layout table is filled
-- in, so the name has to be in scope from up here.

-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.AccentColor       = AccentColor
CB.BANNER_MAX_ASPECT = BANNER_MAX_ASPECT
CB.BANNER_MIN_ASPECT = BANNER_MIN_ASPECT
CB.BannerShapeOk     = BannerShapeOk
CB.CurrentDay        = CurrentDay
CB.CurrentMonth      = CurrentMonth
CB.CurrentPack       = CurrentPack
CB.CurrentYear       = CurrentYear
CB.DanceChartsOnly   = DanceChartsOnly
CB.DanceOnly         = DanceOnly
CB.FilterLabels      = FilterLabels
CB.IsoFromLongDate   = IsoFromLongDate
CB.MonthsAgoStr      = MonthsAgoStr
CB.PackTypeOf        = PackTypeOf
CB.PassesFilter      = PassesFilter
CB.PlaySfx           = PlaySfx
CB.TotalPages        = TotalPages
