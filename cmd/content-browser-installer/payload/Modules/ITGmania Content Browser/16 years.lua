-- -----------------------------------------------------------------------
-- Browsing by year
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local BannerShapeOk     = CB.BannerShapeOk
local Clamp             = CB.Clamp
local CurrentYear       = CB.CurrentYear
local DanceOnly         = CB.DanceOnly
local EnsureRecentIndex = CB.EnsureRecentIndex
local FetchPacks        = CB.FetchPacks
local PackTypeOf        = CB.PackTypeOf
local RecentIndexStep   = CB.RecentIndexStep
local AbandonSearch     = CB.AbandonSearch
local Refresh           = CB.Refresh
local YEAR_SPAN         = CB.YEAR_SPAN
local state             = CB.state

-- Declared here and filled in below. Other parts reach these through the
-- shared table, so they see the finished thing rather than this nil.
local RefreshYearView

-- ---------------------------------------------------------------
-- year summaries.
--
-- The site has no date filter at all -- search[value] matches pack names and
-- the column-search parameters are ignored -- but the date-sorted list is a
-- strictly non-increasing run, so each calendar year is one contiguous slice
-- of it.  The recency index above already walks that list, so keeping the rows
-- it passes over costs nothing extra and gives every year page for free.
--
-- The date is when SMO listed the pack, not when the pack was released, so the
-- UI says "added in", never "released in".

local function YearList()
	local years = {}
	local now = CurrentYear()
	for i = 0, YEAR_SPAN - 1 do years[#years+1] = now - i end
	years[#years+1] = "older"   -- everything before the oldest year with a page
	return years
end

local function YearRows(year)
	local older  = (year == "older")
	local prefix = older
		and string.format("%04d", CurrentYear() - (YEAR_SPAN - 1))
		or tostring(year)
	local out = {}
	for pack in ivalues(state.recentIndex.rows) do
		local hit
		if older then
			-- dates are "YYYY-MM-DD", so a 4-char compare is a year compare
			hit = pack.date ~= "" and pack.date:sub(1, 4) < prefix
		else
			hit = pack.date:sub(1, 4) == prefix
		end
		-- the year picker is a view, not a filter tab: it must not inherit
		-- whichever of pad/keyboard was last touched on the way here
		if hit and DanceOnly(pack) and BannerShapeOk(pack)
		   and PackTypeOf(pack.id) ~= "keyboard" then
			out[#out+1] = pack
		end
	end
	return out
end

local function SelectYear(year)
	state.viewYear = year
	-- OLDER is everything before the year pages, so this is where the walk is
	-- told to go all the way. Landing on the page starts it; the header says
	-- "building index..." with a running count while it does.
	if year == "older" then
		local idx = state.recentIndex
		if not idx.deep then
			idx.deep = true
			idx.stopAt = "0000-01-01"
			if idx.status == "ready" then
				idx.status = "loading"
				RecentIndexStep()
			end
		end
	end
	AbandonSearch()
	state.search = ""
	state.localRows = YearRows(year)
	state.page = 1
	state.cursor = 1
	FetchPacks(1, false)
	Refresh()
end

-- re-slice once the background index finishes, so the page fills itself in
RefreshYearView = function()
	if state.mode ~= "year" or not state.viewYear then return end
	local rows = YearRows(state.viewYear)
	if #rows == #(state.localRows or {}) then return end
	state.localRows = rows
	state.cursor = Clamp(state.cursor, 1, math.max(1, #rows))
	FetchPacks(state.page, true)
end

local function EnterYearView()
	state.mode = "year"
	state.zone = "years"
	AbandonSearch()
	state.search = ""
	state.yearFloor = CurrentYear() - (YEAR_SPAN - 1)
	EnsureRecentIndex()
	-- The year pages need the index back as far as they list, and no further.
	-- The whole catalogue is the OLDER page's bill, and it is not paid until
	-- somebody opens it.  idx.page is preserved, so deepening resumes the walk
	-- where the shallower pass stopped rather than starting it over.
	local idx = state.recentIndex
	local floor = string.format("%04d-01-01", state.yearFloor)
	if (idx.stopAt or "9999-12-31") > floor then
		idx.stopAt = floor
		if idx.status == "ready" then
			idx.status = "loading"
			RecentIndexStep()
		end
	end
	local years = YearList()
	state.yearCursor = Clamp(state.yearCursor or 1, 1, #years)
	SelectYear(years[state.yearCursor])
end


-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.EnterYearView   = EnterYearView
CB.RefreshYearView = RefreshYearView
CB.SelectYear      = SelectYear
CB.YearList        = YearList
