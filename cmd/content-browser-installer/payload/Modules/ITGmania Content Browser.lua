-- -----------------------------------------------------------------------
-- ITGMania Content Browser
-- by GregTech
--
-- A drop-in Simply Love module that adds a "Find Content" entry to the
-- title menu (home screen).  It opens an in-game browser for
-- https://stepmaniaonline.net 's pack index, showing banners, pack info,
-- chart details, and difficulty distributions, and lets you download and
-- install packs directly into /Songs without leaving ITGmania.
--
-- Install: place this file in  Themes/Simply Love/Modules/
-- Requires: ITGmania 1.1+ (uses NETWORK:HttpRequest / FILEMAN:Unzip)
--
-- Network access: ITGmania blocks all hosts by default.  The first time the
-- browser is opened, it asks for permission to add stepmaniaonline.net to
-- the HttpAllowHosts preference (and enable HttpEnabled if necessary).
-- Nothing is written until you confirm in-game.
-- -----------------------------------------------------------------------

local SMO_HOST      = "stepmaniaonline.net"
local SMO_BASE      = "https://" .. SMO_HOST
local BROWSER_SCREEN = "ScreenWithMenuElements"
local BANNER_DIR    = "/Save/SMOFindContent/Banners/"
local ROWS          = 7      -- list rows per page (also the server page size)
-- Declared up here rather than beside their definitions: the pack-type fetch
-- is far above the views but has to nudge them when the catalogue lands, and
-- a name that is not in scope there would compile as a nil global.
local RefreshYearView
local RefreshLevelView
local SONG_ROWS     = 8      -- visible song rows in the detail view
-- Featured strip tuning, gathered into one table: Lua 5.1 caps a chunk at 200
-- local variables and this file sits close to that.
local FEAT = {
	COLS = 6,             -- cards per row
	ROWS = 2,             -- rows of cards
	TARGET = 24,          -- two full pages of twelve, so the grid never gaps
	BUILD = 34,           -- built, not shown: cover for banner-shape pruning
	MIN_SCORE = 4,        -- distinct meters in 7..15 required to qualify
	MAX_DETAILS = 400,    -- give up after this many detail fetches
	MIN_SONGS = 15,       -- below this there is not enough pack to feature
	MAX_SONGS = 100,      -- above this it is a megapack, not a recommendation
	PAD_MONTHS = 5,       -- pad packs: how far back the strip looks
	KB_YEARS = 10,        -- keyboard packs release far less often
	AUTHOR_MIN = 2,       -- other recent packs a charter needs to count
	AUTHOR_TOP = 3,       -- credits checked on a multi-author pack
	SPREAD_BONUS = 10,    -- sorts full-spread packs to the front
}
FEAT.VISIBLE = FEAT.COLS * FEAT.ROWS
local REFRESH_SECS  = 300    -- auto-refresh the pack list if older than this

-- -----------------------------------------------------------------------
-- module state; persists for the whole game session

local state = {
	open          = false,   -- browser screen active
	mode          = "list",  -- blocked | list | detail | confirm | reload
	packs         = {},      -- rows on the current page
	page          = 1,
	totalPacks    = 0,       -- recordsTotal from the server
	filtered      = 0,       -- recordsFiltered (differs while searching)
	cursor        = 1,       -- selected row in packs
	search        = "",
	loading       = false,
	loadErr       = nil,
	lastFetch     = nil,     -- GetTimeSinceStart() of last successful fetch
	fetchReq      = nil,     -- in-flight HttpRequestFuture for the list
	fetchGen      = 0,       -- generation counter; stale responses are dropped
	details       = {},      -- packId -> parsed detail table
	detailBusy    = {},      -- packId -> true while its detail page is being fetched
	detailFailed  = {},      -- packId -> GetTimeSinceStart() of last failed fetch
	bannerFailed  = {},      -- url -> GetTimeSinceStart() of last failed fetch
	bannerAspect  = {},      -- url -> width/height, once a sprite has loaded it
	packsSpare    = {},      -- rows fetched past the page, held to backfill it
	selected      = nil,     -- pack captured when entering detail/confirm view
	songCursor    = 0,       -- scroll offset into the detail song list
	songPick      = 1,       -- which song in that list is highlighted
	chooseIdx     = 1,       -- 1 hear a sample, 2 download, on the detail popup
	dlOrder       = {},      -- packIds in the order their downloads were started
	dlRows        = {},      -- the queue as drawn: worked out once per refresh
	downloads     = {},      -- packId -> {status,cur,total,msg,groups}
	banners       = {},      -- url -> local VFS path (once cached)
	bannerBusy    = {},      -- url -> true while downloading
	bannerQueue   = {},      -- urls waiting for a download slot
	bannerQueued  = {},      -- url -> true while it sits in that queue
	bannerInFlight = 0,
	needsReload   = false,   -- something was installed this session
	textEntryOpen = false,
	pendingSearch = nil,
	reloadForUs   = false,   -- we sent the player to ScreenReloadSongsSSM
	blockedReason = nil,     -- why network access is unavailable, if it is

	-- pad/keyboard filtering (pack type metadata from /api/packs)
	filterMode    = "pad",   -- pad | keyboard
	packTypes     = nil,     -- packId(string) -> packtype ("keyboard"/"itg"/...)
	packTypesBusy = false,
	packSync      = nil,     -- packId(string) -> SMO's sync tag, lowercased
	packSubstyle  = nil,     -- packId(string) -> technical|stamina|all around|mods
	syncPack      = nil,     -- the installed pack the sync screen is acting on
	syncChoice    = "NULL",  -- which value that screen would write
	syncNote      = nil,     -- result of the last write, shown on that screen
	syncFrom      = nil,     -- the mode to return to when that screen closes
	autoSync      = {},      -- packs installed here: normalised name -> SMO date
	keyboardPacks = nil,     -- rows built from the CSV for keyboard mode, id desc
	pageOffsets   = {},      -- uiPage -> server row offset (pad mode paging)

	-- arrowcloud.dance's popularity ranking, which gates the featured grid
	arrowcloud    = {
		status  = "idle",   -- settles on page 1: the featured grid waits on this
		deep    = "idle",   -- settles on all three: the beginner view waits on this
		keys    = {},       -- normalised name -> popularity rank, 1-based
		ranked  = {},       -- rank -> normalised name; sparse, walk it numerically
		created = {},       -- normalised name -> release date, YYYY-MM-DD
		packId  = {},       -- normalised name -> arrowcloud's own pack id
		banner  = {},       -- normalised name -> arrowcloud art url
		fresh   = {},       -- normalised names from the newest-first listing
		newStatus = "idle", -- idle | loading | ready | failed
		newPending = 0,
		count   = 0,
		pending = 0,
	},

	-- content level buckets (all-around / stamina)
	level         = { status="idle", bucket=nil, rows={}, pool={}, poolPos=0,
	                  inFlight=0, fetched=0 },

	-- installed packs view
	installed     = { status="idle", packs={}, cursor=1, window=0, scannedAt=nil },
	helper        = { status="idle", config=nil, reason=nil },
	removing      = nil,     -- pack name currently being deleted
	smoByName     = nil,     -- normalized pack name -> {id,name,songs,bytes,sizeStr}
	smoById       = nil,     -- pack id -> the same record, for search results

	-- search / year views: a locally held result set that pages client-side
	localRows     = nil,     -- non-nil = the list reads from here, not the server
	searchGen     = 0,       -- generation counter; stale search responses are dropped
	searchCapped  = false,   -- more matched than SEARCH.MAX_ROWS
	viewYear      = nil,     -- calendar year, or "older", the year view shows
	yearFloor     = 0,       -- oldest year with its own page; "older" is below it
	yearCursor    = 1,       -- selected year in the year picker

	-- charter recency (item: featured packs from charters active in the window)
	recentIndex   = { status="idle", dates={}, rows={}, page=0, cutoff="",
	                  yearCutoff="", deep=false, seen={} },
	authorPacks   = {},      -- charter name -> {status, ids, waiting}

	-- featured section
	zone          = "list",  -- tabs | featured | years | list (cursor zone)
	tabIndex      = 2,       -- cursor position in the tab row
	featCursor    = 1,
	featWindow    = 0,       -- first visible featured card (0-based)
	featured      = { status="idle", cards={}, pool={}, poolPos=0, pending={},
	                  fallback={}, inFlight=0, fetched=0, mode=nil, builtAt=nil },
}

-- refs to live actors, filled in by InitCommands
local refs = { rows = {}, songRows = {}, bars = {} }

-- actors are userdata, so per-sprite bookkeeping lives here instead
local loadedBanner = {}  -- spriteKey -> last path loaded into that sprite
local songArt      = {}  -- detail song row -> the fitted size of its artwork

-- -----------------------------------------------------------------------
-- small helpers

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

-- shown in the FEATURED heading so the strip's scope is never ambiguous
local FeaturedScopeLabels = {
	pad      = "PAD  -  ",
	keyboard = "KEYBOARD  -  ",
}

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

-- n years back, as a sortable "YYYY-MM-DD"
local function YearsAgoStr(n)
	return string.format("%04d-%02d-%02d", CurrentYear() - n, CurrentMonth(),
		math.min(CurrentDay(), 28))
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
local DL = {}

DL.SHOW_DONE = 12   -- seconds a finished row lingers before it drops off

-- The queue as it should be drawn: start order, finished rows ageing out,
-- failures staying put because a failure nobody saw is not worth reporting.
function DL.Rows()
	local rows = {}
	local now = GetTimeSinceStart()
	for id in ivalues(state.dlOrder) do
		local dl = state.downloads[id]
		if dl then
			local keep = (dl.status == "active" or dl.status == "installing"
				or dl.status == "error")
			if dl.status == "done" and dl.finishedAt
			   and (now - dl.finishedAt) < DL.SHOW_DONE then
				keep = true
			end
			if keep then rows[#rows+1] = dl end
		end
	end
	return rows
end

-- What one row says on the right-hand side, and how full its bar is. A
-- negative fraction means there is nothing to measure: unpacking happens in
-- one blocking call that cannot report on itself.
function DL.RowState(dl)
	if dl.status == "installing" then return "unpacking", -1 end
	if dl.status == "done" then return "done", 1 end
	if dl.status == "error" then return "failed", 0 end
	if dl.total and dl.total > 0 then
		local frac = Clamp(dl.cur / dl.total, 0, 1)
		return math.floor(frac * 100 + 0.5) .. "%", frac
	end
	return "", -1
end

local function Refresh()
	-- Worked out once per refresh rather than once per actor: four actors to a
	-- row would otherwise each rebuild the same list, and their answers would
	-- be free to disagree with each other mid-frame.
	local rows = {}
	for dl in ivalues(DL.Rows()) do
		local label, frac = DL.RowState(dl)
		rows[#rows+1] = { name = dl.name or "", status = dl.status,
			label = label, frac = frac }
	end
	state.dlRows = rows

	MESSAGEMAN:Broadcast("SMORefresh")
end

-- pull a pack out of whatever is currently on screen
local function DropPackByBanner(url)
	local function prune(list)
		if not list then return false end
		local changed = false
		for i = #list, 1, -1 do
			if list[i].banner == url then
				table.remove(list, i)
				changed = true
			end
		end
		return changed
	end

	local changed = false
	if not state.localRows then
		changed = prune(state.packs)
		prune(state.packsSpare)

		-- refill from the rows the over-fetch already brought back
		while #state.packs < ROWS and #state.packsSpare > 0 do
			local next = table.remove(state.packsSpare, 1)
			if PassesFilter(next) then
				-- the row actor asks for its own banner on the next refresh
				state.packs[#state.packs+1] = next
			end
		end
	end
	for i = #state.featured.cards, 1, -1 do
		if state.featured.cards[i].pack.banner == url then
			table.remove(state.featured.cards, i)
			changed = true
		end
	end
	if not changed then return end

	state.cursor = Clamp(state.cursor, 1, math.max(1, #state.packs))
	state.featCursor = Clamp(state.featCursor, 1, math.max(1, FEAT.Count()))
	state.featWindow = math.floor(
		Clamp(state.featCursor - 1, 0, math.max(0, FEAT.Count() - 1))
		/ FEAT.VISIBLE) * FEAT.VISIBLE
	Refresh()
end

-- Record a banner's shape the first time its sprite loads. This is the only
-- moment the dimensions are knowable -- nothing in the pack list or the CSV
-- reports them -- so a pack whose banner turns out to be the wrong shape is
-- dropped here rather than lingering until the page is rebuilt.
local function MeasureBanner(sprite, url)
	if not url or state.bannerAspect[url] then return end
	local w, h = sprite:GetWidth(), sprite:GetHeight()
	if not (w and h and w > 0 and h > 0) then return end
	local aspect = w / h
	state.bannerAspect[url] = aspect
	if aspect < BANNER_MIN_ASPECT or aspect > BANNER_MAX_ASPECT then
		DropPackByBanner(url)
	end
end

local function Toast(text)
	MESSAGEMAN:Broadcast("SMOToast", {Text=text})
end

-- Raise (or restore) our position among ScreenSystemLayer's children.  The
-- credits texts are drawn by that layer after the module container, so without
-- this they sit on top of the browser.
local function LiftAboveSystemLayer(actor, lifted)
	local node = actor
	for _ = 1, 3 do
		if not node then return end
		pcall(function() node:draworder(lifted and 200 or 0) end)
		local ok, parent = pcall(function() return node:GetParent() end)
		if not ok then return end
		node = parent
	end
end

local function SetRedirect(on)
	for player in ivalues(PlayerNumber) do
		SCREENMAN:set_input_redirected(player, on)
	end
end

local function UrlAllowed()
	return NETWORK:IsUrlAllowed(SMO_BASE .. "/")
end

-- -----------------------------------------------------------------------
-- parsing

-- one row from /api/packs/datatables ->
--   {id, name, bytes, sizeStr, songs, types, date, banner}
local function ParsePackRow(row)
	local id, rawname = row[2]:match('href="/pack/(%d+)">(.-)</a>')
	if not id then return nil end
	local pack = {}
	pack.id      = id
	pack.name    = CleanText(rawname)
	pack.banner  = row[1]:match('data%-src="([^"]+)"')
	if pack.banner and pack.banner:find("nobanner", 1, true) then pack.banner = nil end
	pack.bytes   = tonumber(row[3]:match('data%-sort="(%d+)"')) or 0
	pack.sizeStr = FormatBytes(pack.bytes)
	pack.songs   = tonumber(StripTags(row[4]):match("%d+")) or 0
	pack.types   = {}
	for alt in row[5]:gmatch('alt="([^"]+)"') do
		pack.types[#pack.types+1] = alt
	end
	pack.date = Trim(StripTags(row[6])):match("[%d%-]+") or ""
	return pack
end

-- the /pack/<id> page ->
--   {stats={songs,size,charts,difficulty}, labels={}, counts={}, songs={}, author}
local function ParsePackDetail(html)
	local det = { stats = {}, labels = {}, counts = {}, songs = {}, chartTypes = {} }

	for _, key in ipairs({"Songs", "Size", "Charts", "Difficulty", "Sync"}) do
		local v = html:match('>' .. key .. '</small>.-text%-white">%s*(.-)%s*</div>')
		det.stats[key:lower()] = v and CleanText(v) or nil
	end

	-- banner and release date (used for packs that came from the CSV, which
	-- has neither, and for the featured-section date window)
	det.banner = html:match('property="og:image" content="https?://[^"]-(/media/images/packs/[^"]+)"')
	if det.banner and det.banner:find("nobanner", 1, true) then det.banner = nil end
	det.date = html:match('<h5 class="card%-title mb%-0">([%a%.]+ %d+, %d%d%d%d)</h5>')
	det.year = det.date and tonumber(det.date:match("(%d%d%d%d)"))

	-- difficulty distribution from the Chart.js block
	local labels = html:match("labels:%s*%[([^%]]*)%]")
	local counts = html:match("data:%s*%[([^%]]*)%]")
	if labels and counts then
		local rawLabels, rawCounts = {}, {}
		for n in labels:gmatch("%-?%d+") do rawLabels[#rawLabels+1] = tonumber(n) end
		for n in counts:gmatch("%-?%d+") do rawCounts[#rawCounts+1] = tonumber(n) end
		for i, meter in ipairs(rawLabels) do
			-- joke charts get meters in the thousands; they would blow out the
			-- histogram scale and print ranges like "1 - 5454"
			if meter >= 1 and meter <= METER_MAX then
				det.labels[#det.labels+1] = meter
				det.counts[#det.counts+1] = rawCounts[i] or 0
			end
		end
	end

	-- per-song rows from the song table
	local credits = {}
	for tr in html:gmatch("<tr>(.-)</tr>") do
		if tr:find("/song/", 1, true) then
			local tds = {}
			for td in tr:gmatch("<td[^>]*>(.-)</td>") do
				tds[#tds+1] = td
			end
			if #tds >= 8 then
				local song = {}
				song.image    = tds[1]:match('src="([^"]+)"')
				-- the site's "no banner available" placeholder carries no
				-- information; a substituted pack banner does, so that one stays
				if song.image and song.image:find("nobanner", 1, true) then
					song.image = nil
				end
				song.title    = CleanText(tds[2]:match('href="/song/%d+">(.-)</a>') or "")
				song.artist   = CleanText(tds[2]:match('<span class="small translatable text%-gray%-400"[^>]*>(.-)</span>') or "")
				song.subtitle = CleanText(tds[3])
				song.length   = CleanText(tds[4])
				song.bpm      = CleanText(tds[5])
				-- credits are separated by <br> as often as by commas, so the
				-- break has to become a separator rather than vanish
				song.credit   = (CleanText((tds[6]:gsub("<[bB][rR]%s*/?>", ", ")))
					:gsub("[,%s]+$", ""))
				song.meters   = CleanText(tds[8])
				-- the styles column names every chart type the song carries
				song.styles = {}
				for kind in tds[7]:gmatch('alt="([^"]+)"') do
					det.chartTypes[kind:lower()] = true
					song.styles[kind:lower()] = true
				end
				if song.title ~= "" then
					det.songs[#det.songs+1] = song
					if song.credit ~= "" then
						for credit in song.credit:gmatch("[^,]+") do
							credit = Trim(credit)
							if LooksLikeCredit(credit) then
								credits[credit] = (credits[credit] or 0) + 1
							end
						end
					end
				end
			end
			if #det.songs >= 400 then break end
		end
	end

	-- summarize the most common chart credits as the pack "author"
	local ranked = {}
	for name, count in pairs(credits) do
		ranked[#ranked+1] = {name=name, count=count}
	end
	table.sort(ranked, function(a, b)
		if a.count ~= b.count then return a.count > b.count end
		return a.name < b.name   -- stable when two charters tie
	end)
	if #ranked > 0 then
		local names = {}
		for i = 1, math.min(3, #ranked) do names[#names+1] = ranked[i].name end
		det.author = table.concat(names, ", ")
		if #ranked > 3 then det.author = det.author .. ", ..." end
		-- LooksLikeCredit already screened these at collection time
		det.credits = names
	end

	return det
end

-- -----------------------------------------------------------------------
-- networking

local BANNER_RETRY_SECS = 600

-- Banner downloads are queued rather than all started at once.
--
-- A page of list rows, a full featured grid and the detail pane between them
-- ask for forty-odd images the moment the browser opens, and SMO's banners
-- average around 350 KB. Firing them together does not make any of them arrive
-- sooner -- it makes every one of them crawl, because they are all sharing the
-- same pipe. A handful at a time finishes the ones on screen far quicker.
local BANNER_MAX_INFLIGHT = 8

local BannerPump   -- forward declaration (the download callback pumps again)

local function BannerBegin(url)
	-- SMO art is a site-relative path; arrowcloud art is an absolute url, and
	-- every pack of theirs is served as ".../<packdir>/pack-banner.png", so the
	-- filename alone would collide across the whole site. Take the directory
	-- with it.
	local absolute = url:match("^https?://") ~= nil
	local file = url:match("([%w%._%-]+)$")
	if not file then return false end
	if absolute then
		local dir = url:match("/([%w%._%-]+)/[%w%._%-]+$")
		file = (dir and (dir .. "_") or "ac_") .. file
	end
	local cachePath = BANNER_DIR .. file

	if FILEMAN:DoesFileExist(cachePath) then
		state.banners[url] = cachePath
		MESSAGEMAN:Broadcast("SMOBannerReady")
		return false          -- took no slot
	end

	state.bannerBusy[url] = true
	state.bannerInFlight = state.bannerInFlight + 1
	NETWORK:HttpRequest{
		url = absolute and url or (SMO_BASE .. url),
		downloadFile = "smo_" .. file,
		connectTimeout = 10,
		transferTimeout = 60,
		onResponse = function(response)
			state.bannerBusy[url] = nil
			state.bannerInFlight = math.max(0, state.bannerInFlight - 1)
			if response.error == nil and response.statusCode == 200
			   and FILEMAN:Copy("/Downloads/smo_" .. file, cachePath) then
				state.banners[url] = cachePath
				state.bannerFailed[url] = nil
				MESSAGEMAN:Broadcast("SMOBannerReady")
			else
				state.bannerFailed[url] = GetTimeSinceStart()
			end
			BannerPump()
		end,
	}
	return true
end

BannerPump = function()
	while state.bannerInFlight < BANNER_MAX_INFLIGHT and #state.bannerQueue > 0 do
		local url = table.remove(state.bannerQueue, 1)
		state.bannerQueued[url] = nil
		-- a cache hit takes no slot, so keep going in that case
		BannerBegin(url)
	end
end

local function RequestBanner(url)
	if not url or state.banners[url] or state.bannerBusy[url] then return end
	if state.bannerQueued[url] then return end
	-- negative cache: don't hammer the server re-requesting failed banners
	-- on every refresh
	local failedAt = state.bannerFailed[url]
	if failedAt and GetTimeSinceStart() - failedAt < BANNER_RETRY_SECS then return end
	if not UrlAllowed() then return end

	state.bannerQueued[url] = true
	state.bannerQueue[#state.bannerQueue+1] = url
	BannerPump()
end

-- a pack's banner url, falling back to the one scraped from its detail page
-- (CSV-sourced keyboard rows have no banner in the row data)
local function BannerUrlFor(pack)
	if not pack then return nil end
	if pack.banner then return pack.banner end
	local det = state.details[pack.id]
	return det and det.banner
end

local function PrefetchBanners()
	for pack in ivalues(state.packs) do
		RequestBanner(BannerUrlFor(pack))
	end
end

-- one page of rows from the datatables endpoint, newest first.
-- cb(rows, recordsFiltered) on success, cb(nil, nil, errmsg) on failure.
local function FetchServerRows(serverStart, length, search, cb)
	local query = NETWORK:EncodeQueryParameters{
		["draw"]   = "1",
		["start"]  = tostring(serverStart),
		["length"] = tostring(length),
		["search[value]"]     = search or "",
		["order[0][column]"]  = "5",     -- date column
		["order[0][dir]"]     = "desc",  -- newest first
	}
	return NETWORK:HttpRequest{
		url = SMO_BASE .. "/api/packs/datatables?" .. query,
		connectTimeout = 10,
		transferTimeout = 30,
		onResponse = function(response)
			if response.error ~= nil then
				if ToEnumShortString(response.error) == "Cancelled" then return end
				cb(nil, nil, response.errorMessage or "network error")
				return
			end
			if response.statusCode ~= 200 then
				cb(nil, nil, "HTTP " .. tostring(response.statusCode))
				return
			end
			local ok, data = pcall(JsonDecode, response.body)
			if not ok or type(data) ~= "table" or type(data.data) ~= "table" then
				cb(nil, nil, "unexpected response from server")
				return
			end
			local rows = {}
			for row in ivalues(data.data) do
				local parsed_ok, pack = pcall(ParsePackRow, row)
				if parsed_ok and pack then rows[#rows+1] = pack end
			end
			cb(rows, tonumber(data.recordsFiltered) or #rows)
		end,
	}
end

-- ---------------------------------------------------------------
-- pack type metadata: /api/packs is a CSV of every pack including its
-- packtype tag ("keyboard", "itg", "pad", "ddr", ... or "None").  Fetched
-- once per session; powers the pad/keyboard filter and keyboard-mode list.

local function ParseCsvLine(line)
	local fields = {}
	local buf = {}
	local inQuote = false
	local i = 1
	local n = #line
	while i <= n do
		local c = line:sub(i, i)
		if inQuote then
			if c == '"' then
				if line:sub(i+1, i+1) == '"' then
					buf[#buf+1] = '"'
					i = i + 1
				else
					inQuote = false
				end
			else
				buf[#buf+1] = c
			end
		elseif c == '"' then
			inQuote = true
		elseif c == ',' then
			fields[#fields+1] = Trim(table.concat(buf))
			buf = {}
		else
			buf[#buf+1] = c
		end
		i = i + 1
	end
	fields[#fields+1] = Trim(table.concat(buf))
	return fields
end

local FetchPackTypes  -- forward declaration; defined below
local ApplyFilterRefetch  -- forward declaration (needs FetchPacks/BuildFeatured)

FetchPackTypes = function()
	if state.packTypes or state.packTypesBusy then return end
	if not UrlAllowed() then return end
	state.packTypesBusy = true
	NETWORK:HttpRequest{
		url = SMO_BASE .. "/api/packs",
		connectTimeout = 10,
		transferTimeout = 60,
		onResponse = function(response)
			state.packTypesBusy = false
			if response.error ~= nil or response.statusCode ~= 200 then
				-- keyboard mode depends entirely on this data; surface the
				-- failure instead of spinning forever
				if state.filterMode == "keyboard" and state.open then
					state.loading = false
					state.loadErr = "could not load pack type data"
					Refresh()
				end
				return
			end

			local types = {}
			local syncs = {}
			local styles = {}
			local keyboard = {}
			local byName = {}
			local byId = {}
			local first = true
			for line in response.body:gmatch("[^\r\n]+") do
				if first then
					first = false  -- header row
				else
					local ok, f = pcall(ParseCsvLine, line)
					-- id, name, song count, size, sync, packtype, substyle, min version
					if ok and f[1] and f[1]:match("^%d+$") and f[6] then
						-- also index by name so the installed view can compare against
						-- SMO without spending another request
						if f[2] and f[2] ~= "" then
							local rec = {
								id      = f[1],
								name    = f[2],
								songs   = tonumber(f[3]) or 0,
								bytes   = tonumber(f[4]) or 0,
								sizeStr = FormatBytes(tonumber(f[4]) or 0),
							}
							byName[NormalizeName(f[2])] = rec
							byId[f[1]] = rec
						end
						if f[5] and f[5] ~= "" then syncs[f[1]] = f[5]:lower() end
						if f[7] and f[7] ~= "" then styles[f[1]] = f[7]:lower() end
						local ptype = f[6]:lower()
						if ptype ~= "none" and ptype ~= "n/a" and ptype ~= "null" and ptype ~= "" then
							types[f[1]] = ptype
						end
						if ptype == "keyboard" then
							keyboard[#keyboard+1] = {
								id      = f[1],
								name    = f[2] or "",
								songs   = tonumber(f[3]) or 0,
								bytes   = tonumber(f[4]) or 0,
								sizeStr = FormatBytes(tonumber(f[4]) or 0),
								types   = {},
								date    = "",
								banner  = nil,
								csvOnly = true,
							}
						end
					end
				end
			end
			-- newest additions first (pack ids are roughly chronological)
			table.sort(keyboard, function(a, b) return tonumber(a.id) > tonumber(b.id) end)

			state.packTypes = types
			state.packSync = syncs
			state.packSubstyle = styles
			state.keyboardPacks = keyboard
			state.smoByName = byName
			state.smoById = byId
			-- the beginner list is a join against this, and may be waiting
			if RefreshLevelView then RefreshLevelView() end

			-- the current view was built unfiltered; rebuild it now that the
			-- filter can actually apply (only if the user is still on page 1)
			-- only the plain list is rebuilt: a year page, a search or the installed
			-- view would be wiped by a refetch that has nothing to do with them
			if state.open and state.mode == "list" and state.search == ""
			   and state.page == 1 and ApplyFilterRefetch then
				ApplyFilterRefetch(true)
			else
				Refresh()
			end
		end,
	}
end

-- ---------------------------------------------------------------
-- pack list fetching (filter-aware)

-- Put one page of an in-memory row list on screen.  Three things page this
-- way: keyboard mode, search results and the year view.
local function PageFromRows(rows, page, keepCursor, total)
	local startIndex = (page-1) * ROWS
	local pagePacks = {}
	for i = startIndex + 1, math.min(startIndex + ROWS, #rows) do
		pagePacks[#pagePacks+1] = rows[i]
	end
	state.packs      = pagePacks
	state.page       = page
	state.totalPacks = total or #rows
	state.filtered   = #rows
	state.cursor     = keepCursor and Clamp(state.cursor, 1, math.max(1, #pagePacks)) or 1
	state.loadErr    = nil
	state.lastFetch  = GetTimeSinceStart()
	Refresh()
	PrefetchBanners()
end

local FetchPacks  -- forward declaration (keyboard branch has no request)

FetchPacks = function(page, keepCursor)
	-- a locally held result set (search results, or one year) needs no request,
	-- but a server page already in flight would overwrite it when it lands
	if state.localRows then
		if state.fetchReq then
			state.fetchReq:Cancel()
			state.fetchReq = nil
		end
		state.fetchGen = state.fetchGen + 1
		PageFromRows(state.localRows, page, keepCursor)
		return
	end

	-- keyboard mode is served locally from the CSV-derived list
	if state.filterMode == "keyboard" then
		local source = state.keyboardPacks
		if not source then
			state.loading = true
			FetchPackTypes()
			Refresh()
			return
		end
		local rows = source
		if state.search ~= "" then
			local needle = state.search:lower()
			rows = {}
			for pack in ivalues(source) do
				if pack.name:lower():find(needle, 1, true) then rows[#rows+1] = pack end
			end
		end
		state.loading = false
		PageFromRows(rows, page, keepCursor, #source)
		return
	end

	if not UrlAllowed() then return end
	if state.fetchReq then state.fetchReq:Cancel() state.fetchReq = nil end

	state.fetchGen = state.fetchGen + 1
	local generation = state.fetchGen

	state.loading = true
	state.loadErr = nil
	Refresh()

	-- In pad mode keyboard-tagged packs are dropped client-side, so fetch a
	-- slightly larger window and track how far into the server's ordering
	-- each UI page reaches.  (Keyboard-tagged packs are ~2% of the index, so
	-- one window nearly always fills a page.)
	local filteringActive = true
	local serverStart, length
	if filteringActive then
		if page <= 1 then state.pageOffsets = { [1] = 0 } end
		serverStart = state.pageOffsets[page] or ((page-1) * ROWS)
		length = ROWS + 20
	else
		serverStart = (page-1) * ROWS
		length = ROWS
	end

	local req
	req = FetchServerRows(serverStart, length, state.search, function(rows, recordsFiltered, err)
		-- only if the handle is still ours: a superseded request must never
		-- nil out the one that replaced it
		if state.fetchReq == req then state.fetchReq = nil end
		if generation ~= state.fetchGen then return end
		if err then
			state.loading = false
			state.loadErr = err
			-- an optimistic cursor move (page crossing) may point past the
			-- end of the still-displayed page; pull it back in bounds
			state.cursor = Clamp(state.cursor, 1, math.max(1, #state.packs))
			if #state.packs > 0 then
				Toast("Could not reach stepmaniaonline.net")
			end
			Refresh()
			return
		end

		local packs = rows
		if filteringActive then
			packs = {}
			local consumed = #rows
			for index, pack in ipairs(rows) do
				if PassesFilter(pack) then
					packs[#packs+1] = pack
					if #packs >= ROWS then
						consumed = index
						break
					end
				end
			end
			state.pageOffsets[page+1] = serverStart + consumed

			-- everything past this page that also passed, kept as backfill
			local spare = {}
			for index = consumed + 1, #rows do
				if PassesFilter(rows[index]) then spare[#spare+1] = rows[index] end
			end
			state.packsSpare = spare
		end

		state.packs      = packs
		state.page       = page
		state.totalPacks = recordsFiltered
		state.filtered   = recordsFiltered
		state.cursor     = keepCursor and Clamp(state.cursor, 1, math.max(1, #packs)) or 1
		state.loading    = false
		state.lastFetch  = GetTimeSinceStart()
		Refresh()
		PrefetchBanners()
	end)
	state.fetchReq = req
end

-- ---------------------------------------------------------------
-- search.
--
-- One text box that has to find a pack by its name, by a chart author, or by a
-- song inside it.  The site cannot do that in one request:
--   * the pack list's search[value] matches the pack NAME only, but the rows it
--     returns are complete (banner, date, size, song count);
--   * /api/search/?type=credit and ?type=title match charters and song titles,
--     but return only pack ids and names -- no date, no banner, no size.
-- So this runs the name search first and paints from it immediately, then fills
-- in the deeper matches by resolving their ids against the pack CSV that the
-- pad/keyboard filter already downloads.  No extra catalogue fetch is needed.

local SEARCH = {
	MIN_CHARS = 2,
	MAX_ROWS  = 200,
	TIER1_LEN = 60,
}

local SearchScores = {
	name_prefix = 100,
	name_match  = 80,
	credit      = 60,
	title       = 40,
	-- A charter who wrote the whole pack is a far better answer than one who
	-- put a single file in a 190-song megapack. The credit search reports both
	-- matching_songs and songs_count, so the score can follow what share of
	-- the pack is actually theirs -- enough of a spread that a pack somebody
	-- authored outranks one they merely appear in.
	credit_share = 100,
}

-- build a browser row for a pack we only know by id, out of the CSV catalogue
local function RowFromCatalog(id, why)
	local rec = state.smoById and state.smoById[id]
	if not rec then return nil end
	return {
		id      = id,
		name    = rec.name,
		songs   = rec.songs,
		bytes   = rec.bytes,
		sizeStr = rec.sizeStr,
		types   = {},
		-- the recency index has dates for everything inside its window; older
		-- packs simply show no date rather than costing a request each
		date    = state.recentIndex.dates[id] or "",
		banner  = nil,   -- filled from the detail page once the row is selected
		csvOnly = true,
		why     = why,
	}
end

local function SearchAddRow(acc, pack, score, why)
	local existing = acc.byId[pack.id]
	if existing then
		-- matched more than one way; keep the best reason and nudge the score
		existing.score = math.max(existing.score, score) + 5
		if why and not existing.pack.why then existing.pack.why = why end
		return
	end
	if why and not pack.why then pack.why = why end
	local entry = { pack = pack, score = score }
	acc.byId[pack.id] = entry
	acc.list[#acc.list+1] = entry
end

local function SearchPublish(acc)
	if state.searchGen ~= acc.gen then return end   -- superseded by a newer query
	table.sort(acc.list, function(a, b)
		if a.score ~= b.score then return a.score > b.score end
		local ad, bd = a.pack.date or "", b.pack.date or ""
		if ad ~= bd then return ad > bd end
		return a.pack.name < b.pack.name
	end)
	local rows = {}
	for entry in ivalues(acc.list) do
		if #rows >= SEARCH.MAX_ROWS then break end
		rows[#rows+1] = entry.pack
	end
	-- a broad query can match thousands of packs; say so rather than passing
	-- the cap off as the true count
	state.searchCapped = (#acc.list > #rows)
	state.localRows = rows
	state.loading = (acc.inFlight > 0)
	FetchPacks(1, false)
end

-- one /api/search/ pass; kind is "credit" or "title"
local function SearchDeep(acc, query, kind, scoreKey)
	acc.inFlight = acc.inFlight + 1
	local url = SMO_BASE .. "/api/search/?" .. NETWORK:EncodeQueryParameters{
		["query"] = query,
		["type"]  = kind,
		["exact"] = "0",
	}
	NETWORK:HttpRequest{
		url = url,
		connectTimeout = 10,
		transferTimeout = 25,
		onResponse = function(response)
			acc.inFlight = acc.inFlight - 1
			if state.searchGen ~= acc.gen then return end

			local ok, data = false, nil
			if response.error == nil and response.statusCode == 200 then
				ok, data = pcall(JsonDecode, response.body)
			end
			if ok and type(data) == "table" and type(data.results) == "table" then
				for result in ivalues(data.results) do
					local id = tonumber(result.id)
					if id then
						id = string.format("%d", id)
						local row = acc.byId[id] and acc.byId[id].pack or RowFromCatalog(id, nil)
						if row and PassesFilter(row) then
							local why, bonus = nil, 0
							if kind == "credit" then
								local matched = (type(result.matching_songs) == "table")
									and #result.matching_songs or 0
								local total = tonumber(result.songs_count) or 0
								if total > 0 and matched > 0 then
									bonus = math.floor(
										math.min(matched / total, 1) * SearchScores.credit_share)
								end
								if total > 0 and matched >= total then
									why = "all charts by " .. query
								elseif matched == 1 then
									why = "1 chart by " .. query
								elseif matched > 0 then
									why = matched .. " of " .. total .. " by " .. query
								else
									why = "charts by " .. query
								end
							elseif type(result.matching_songs) == "table" and #result.matching_songs > 0 then
								local first = tostring(result.matching_songs[1]):gsub("^%[%d+%]%s*", "")
								first = first:gsub("^%[%d+%]%s*", "")
								why = "song: " .. Trim(first)
							else
								why = "matching song"
							end
							SearchAddRow(acc, row, SearchScores[scoreKey] + bonus, why)
						end
					end
				end
			end
			SearchPublish(acc)
		end,
	}
end

local function RunSearch(query)
	query = Trim(query or "")
	state.searchGen = (state.searchGen or 0) + 1
	local acc = { gen = state.searchGen, list = {}, byId = {}, inFlight = 0 }

	if query == "" then
		state.localRows = nil
		state.loading = false
		FetchPacks(1, false)
		return
	end
	if #query < SEARCH.MIN_CHARS then
		state.localRows = {}
		state.loading = false
		Toast("Type at least " .. SEARCH.MIN_CHARS .. " characters")
		FetchPacks(1, false)
		return
	end

	-- Clear the body first. Leaving the previous page up while a search runs
	-- reads as "these are your results", which they are not.
	state.localRows = {}
	state.packs = {}
	state.cursor = 1
	state.page = 1
	state.loading = true
	Refresh()

	local needle = query:lower()
	local function ScoreName(name)
		local lower = name:lower()
		if lower:sub(1, #needle) == needle then return SearchScores.name_prefix end
		if lower:find(needle, 1, true) then return SearchScores.name_match end
		return nil
	end

	-- tier 1: pack names.  Keyboard mode already holds the whole catalogue
	-- locally, so it needs no request at all.
	if state.filterMode == "keyboard" then
		for pack in ivalues(state.keyboardPacks or {}) do
			local score = ScoreName(pack.name)
			if score then SearchAddRow(acc, pack, score, nil) end
		end
		SearchDeep(acc, query, "credit", "credit")
		SearchDeep(acc, query, "title", "title")
		SearchPublish(acc)
		return
	end

	acc.inFlight = acc.inFlight + 1
	FetchServerRows(0, SEARCH.TIER1_LEN, query, function(rows, _, err)
		acc.inFlight = acc.inFlight - 1
		if state.searchGen ~= acc.gen then return end
		if rows and not err then
			for pack in ivalues(rows) do
				if PassesFilter(pack) then
					SearchAddRow(acc, pack, ScoreName(pack.name) or SearchScores.name_match, nil)
				end
			end
		end
		SearchPublish(acc)
	end)

	-- tier 2 runs alongside; results stream in as each lands
	SearchDeep(acc, query, "credit", "credit")
	SearchDeep(acc, query, "title", "title")
end

local DETAIL_RETRY_SECS = 30

-- force=true bypasses the failure cooldown (used for explicit user actions)
local function FetchDetail(pack, cb, force)
	local existing = state.details[pack.id]
	if existing then
		if cb then cb(existing) end
		return
	end
	-- negative cache so a failing detail page isn't refetched in a loop by
	-- every UI refresh
	local failedAt = state.detailFailed[pack.id]
	if failedAt and not force and GetTimeSinceStart() - failedAt < DETAIL_RETRY_SECS then
		if cb then cb(nil) end
		return
	end
	if state.detailBusy[pack.id] or not UrlAllowed() then
		if cb then cb(nil) end
		return
	end

	state.detailBusy[pack.id] = true
	NETWORK:HttpRequest{
		url = SMO_BASE .. "/pack/" .. pack.id,
		connectTimeout = 10,
		transferTimeout = 30,
		onResponse = function(response)
			state.detailBusy[pack.id] = nil
			local det = nil
			if response.error == nil and response.statusCode == 200 then
				local ok, parsed = pcall(ParsePackDetail, response.body)
				if ok and parsed then
					state.details[pack.id] = parsed
					state.detailFailed[pack.id] = nil
					det = parsed
				end
			end
			if det == nil then
				state.detailFailed[pack.id] = GetTimeSinceStart()
			end
			if cb then cb(det) end
			Refresh()
		end,
	}
end

-- ---------------------------------------------------------------
-- installed packs.
--
-- The local library, cross-checked against SMO.  Song counts come from
-- SONGMAN; the SMO side reuses the /api/packs CSV that already backs the
-- pad/keyboard filter, so the comparison costs no extra requests.
--
-- Packs are removed from here without leaving the game; see the helper block
-- below for how, and why it has to work that way.

local BROWSER_DATA_DIR = "/Save/ITGmaniaContentBrowser/"
local SYNC_ASSUME_YEARS = 4   -- older than this and a pack predates null sync
local INST_COLS        = 2
local INST_ROWS        = 22   -- packs visible at once: INST_COLS columns of 11
local RAGEFILE_READ    = 1
-- WRITE|STREAMED rather than plain WRITE. Plain WRITE writes a temp file and
-- renames it into place from the file object's destructor, but Close() tells
-- the filename cache about the final path BEFORE that rename -- so the cache
-- stats a file that is not there yet, gives up, and the directory listing
-- stays stale for thirty seconds. STREAMED opens the real path directly, which
-- is what the engine's own Unzip does. The usual objection to it, that a crash
-- mid-write truncates whatever was there, cannot apply: nothing here writes
-- over an existing file.
local RAGEFILE_WRITE   = 6

-- ---------------------------------------------------------------
-- pack sync.
--
-- ITGmania reads Pack.ini's [Group] SyncOffset. "ITG" says the charts carry
-- the arcade 9ms bias and the engine subtracts it; "NULL" says there is
-- nothing to correct. With no Pack.ini at all the machine's DefaultSyncOffset
-- preference decides, and that ships as ITG -- so a genuinely ITG-synced pack
-- is already right without a file, and only a NULL-synced one is wrong.
--
-- Nothing published will tell you which a pack needs. SMO's Sync field has no
-- value for ITG at all (its whole vocabulary is n/a, null, 0, mixed, other)
-- and it lists In The Groove 2 -- the pack the 9ms offset is named after -- as
-- "null". The community NULL Progress sheet is one-sided in the same way: it
-- records NULL or blank, and blank means "not looked at yet", never "ITG". Of
-- the packs on this machine that ship an author-written Pack.ini, five that
-- the sheet marks NULL declare SyncOffset=ITG.
--
-- So: report what SMO says and attribute it, read the real answer off disk
-- where a pack supplies one, and never write a guess.
local Sync = {}

-- SMO's own tag for a pack, lowercased, or nil when it lists nothing
function Sync.Smo(pack)
	if not pack then return nil end
	local det = state.details[pack.id]
	local raw = det and det.stats and det.stats.sync
	if not raw and state.packSync then raw = state.packSync[tostring(pack.id)] end
	raw = raw and tostring(raw):lower() or nil
	if not raw or raw == "" or raw == "n/a" or raw == "none" then return nil end
	return raw
end

-- one line for the info pane of a pack being browsed
function Sync.Line(pack)
	local smo = Sync.Smo(pack)
	if smo == "null" or smo == "0" then return "sync: NULL, per SMO" end
	if smo then return "sync: " .. smo .. ", per SMO" end
	return "sync: not listed"
end

-- What a pack on disk declares. Returns the value and the filename it came
-- from, or nil when the pack has no Pack.ini. Both spellings occur in the
-- wild, so both are tried.
-- Stamped into any file this module writes, so a value it assumed can still be
-- told apart from one the pack's author declared.
local SYNC_MARK = "Written by the ITGmania Content Browser."

function Sync.OnDisk(dir)
	if not dir then return nil end
	for name in ivalues({"Pack.ini", "pack.ini"}) do
		local path = dir .. name
		if FILEMAN:DoesFileExist(path) then
			local file = RageFileUtil:CreateRageFile()
			local value, ours
			if file:Open(path, RAGEFILE_READ) then
				local body = file:Read()
				file:Close()
				value = body and body:match("[Ss]ync[Oo]ffset%s*=%s*(%w+)")
				ours = body ~= nil and body:find(SYNC_MARK, 1, true) ~= nil
			end
			file:destroy()
			return (value and value:upper() or "?"), name, ours
		end
	end
	return nil
end

-- how a pack's on-disk sync reads in a list
function Sync.DiskLabel(value, ours)
	local suffix = ours and ", assumed" or ""
	if value == "NULL" then return "sync: NULL" .. suffix end
	if value == "ITG" then return "sync: 9ms (ITG)" .. suffix end
	if value then return "sync: " .. value .. suffix end
	return "no Pack.ini"
end

-- Write one. Version is not optional: the engine gates the whole [Group]
-- parse on it and silently discards every other key when it is missing, so a
-- file carrying only SyncOffset does nothing at all. Refuses point blank when
-- the pack already has a file -- that one was written by whoever made the
-- pack, and rewriting it would throw away its title and banner keys too.
function Sync.Write(dir, value)
	if not dir then return false, "this pack's folder could not be found" end
	if value ~= "NULL" and value ~= "ITG" then return false, "invalid sync value" end
	if Sync.OnDisk(dir) then return false, "this pack already has a Pack.ini" end
	local file = RageFileUtil:CreateRageFile()
	local ok = false
	if file:Open(dir .. "Pack.ini", RAGEFILE_WRITE) then
		file:PutLine("[Group]")
		file:PutLine("# " .. SYNC_MARK)
		file:PutLine("# Delete this file to hand the pack back to the machine's")
		file:PutLine("# DefaultSyncOffset preference.")
		file:PutLine("Version=1")
		file:PutLine("SyncOffset=" .. value)
		file:Close()
		ok = true
	end
	file:destroy()
	if not ok then return false, "could not write to the pack folder" end
	return true
end

-- /Songs/<Group>/<Song>/  ->  /Songs/<Group>/
local function GroupDirFor(songs)
	if #songs == 0 then return nil end
	local dir = songs[1]:GetSongDir()
	if not dir or dir == "" then return nil end
	local trimmed = dir:gsub("/+$", "")
	local parent = trimmed:match("^(.*)/[^/]+$")
	return parent and (parent .. "/") or nil
end

-- ---------------------------------------------------------------
-- deleting a pack, from inside the game.
--
-- ITGmania's Lua API cannot delete anything: RageFileManager exposes only
-- Copy, DoesFileExist, GetFileSizeBytes, GetHashForFile, GetDirListing and
-- Unzip, and there is no delete, move or rename anywhere else in the API.
-- (The in-game deletion people remember is the engine's Ctrl+Backspace
-- shortcut on the music wheel; that is C++, unreachable from Lua, and removes
-- a single SONG rather than a pack.)
--
-- What Lua CAN do is make an HTTP request, and the engine's allowlist matches
-- on host alone, so the installer adds 127.0.0.1 to HttpAllowHosts and leaves
-- a small local service running.  Removal is then a normal request and the
-- player never leaves the game.

local HELPER_CONFIG = BROWSER_DATA_DIR .. "helper.json"

local function HelperUrl(path)
	local cfg = state.helper.config
	if not cfg then return nil end
	return "http://127.0.0.1:" .. cfg.port .. path
end

-- read the port and token the running service published for us
local function LoadHelperConfig()
	if not FILEMAN:DoesFileExist(HELPER_CONFIG) then return nil end
	local f = RageFileUtil:CreateRageFile()
	local body
	if f:Open(HELPER_CONFIG, RAGEFILE_READ) then
		body = f:Read()
		f:Close()
	end
	f:destroy()
	if not body or body == "" then return nil end
	local ok, cfg = pcall(JsonDecode, body)
	if not ok or type(cfg) ~= "table" or not cfg.port or not cfg.token then return nil end
	cfg.port = math.floor(tonumber(cfg.port) or 0)
	if cfg.port <= 0 then return nil end
	return cfg
end

-- status: idle | checking | ready | absent
local function CheckHelper(force)
	local h = state.helper
	if h.status == "checking" then return end
	if h.status == "ready" and not force then return end

	h.config = LoadHelperConfig()
	if not h.config then
		h.status = "absent"
		h.reason = "the removal helper is not installed"
		Refresh()
		return
	end

	local url = HelperUrl("/health")
	if not NETWORK:IsUrlAllowed(url) then
		h.status = "absent"
		h.reason = "127.0.0.1 is missing from HttpAllowHosts"
		Refresh()
		return
	end

	h.status = "checking"
	Refresh()
	NETWORK:HttpRequest{
		url = url,
		headers = { ["X-Browser-Token"] = h.config.token },
		connectTimeout = 3,
		transferTimeout = 5,
		onResponse = function(response)
			if response.error == nil and response.statusCode == 200 then
				h.status = "ready"
				h.reason = nil
			else
				h.status = "absent"
				h.reason = "the removal helper is not running"
			end
			Refresh()
		end,
	}
end

-- Sweep the empty probe files the engine leaves behind after an unzip. Best
-- effort and silent: it is tidying, not something the player asked for, and a
-- helper that is not running is not a problem worth reporting.
local function TidyProbeFiles()
	local h = state.helper
	if h.status ~= "ready" or not h.config then return end
	local url = HelperUrl("/tidy")
	if not NETWORK:IsUrlAllowed(url) then return end
	NETWORK:HttpRequest{
		url = url,
		method = "POST",
		body = "{}",
		headers = {
			["X-Browser-Token"] = h.config.token,
			["Content-Type"]    = "application/json",
		},
		connectTimeout = 5,
		transferTimeout = 60,
		onResponse = function() end,
	}
end

-- cb(ok, message)
local function DeletePack(pack, cb)
	local h = state.helper
	if h.status ~= "ready" or not h.config then
		cb(false, h.reason or "pack removal is unavailable")
		return
	end
	local url = HelperUrl("/remove")
	if not NETWORK:IsUrlAllowed(url) then
		cb(false, "127.0.0.1 is missing from HttpAllowHosts")
		return
	end

	state.autoSync[NormalizeName(pack.name)] = nil
	state.removing = pack.name
	Refresh()
	NETWORK:HttpRequest{
		url = url,
		method = "POST",
		body = JsonEncode({ pack = pack.name }),
		headers = {
			["X-Browser-Token"] = h.config.token,
			["Content-Type"]    = "application/json",
		},
		connectTimeout = 5,
		transferTimeout = 120,
		onResponse = function(response)
			state.removing = nil
			if response.error ~= nil then
				h.status = "absent"
				h.reason = "the removal helper stopped responding"
				cb(false, h.reason)
				return
			end
			local ok, data = pcall(JsonDecode, response.body or "")
			if response.statusCode == 200 and ok and type(data) == "table" and data.ok then
				cb(true, nil)
			else
				local why = (ok and type(data) == "table" and data.error) or
					("the helper returned HTTP " .. tostring(response.statusCode))
				cb(false, tostring(why))
			end
		end,
	}
end

-- ------------------------------------------------------------------ previews
--
-- A sample of a song, played from the pack's own audio.
--
-- The audio worth hearing is the audio the pack was charted against, and it is
-- already sitting in the zip on the download server -- which serves ranges, so
-- the helper can read the archive's directory, inflate one entry and drop it
-- next to us without pulling the other hundred megabytes. A representative
-- pack: 100 MB on the server, 4 MB pulled, about a second.
--
-- The window played is the one the pack's author chose: #SAMPLESTART and
-- #SAMPLELENGTH out of the simfile, the same fields the music wheel uses. So
-- this is the author's sample of the author's audio, not a guess at which
-- upload on some other site happens to be the same song.
--
-- The extraction has to live in the helper. There is no inflate anywhere in the
-- engine's Lua bindings, and RageFile:Write stops at the first NUL byte, so a
-- theme could not write an audio file even while holding one.
local Snd = {}

Snd.status  = "idle"  -- idle | loading | playing | failed
Snd.song    = nil     -- the song being previewed
Snd.message = nil     -- why it failed, when it did
Snd.actor   = nil     -- the ActorSound, once the tree exists
Snd.token   = 0       -- generation, so a late reply for an abandoned song is dropped
Snd.bpm     = 0       -- the song's tempo, so something on screen can move with it
Snd.startedAt = 0     -- when playback began, for both the beat and the run-out
Snd.len     = 0       -- how long the sample runs
Snd.prog    = nil     -- {phase, frac} while the helper is still fetching
Snd.index   = nil     -- which song in the list is playing, so the bars stay on it
Snd.bars    = {}      -- the equalizer bars, once the tree exists
Snd.BARS    = 16
Snd.BAR_W   = 3
Snd.BAR_GAP = 2
Snd.BAR_H   = 15
Snd.PROG_W  = 118     -- the loading bar occupies the same corner as the bars

-- How tall bar i stands right now.
--
-- The engine hands Lua no spectrum -- RageSound exposes length, pitch, speed
-- and volume and nothing else, and the stock "visualizer" is a video file. What
-- it does hand over is the tempo out of the simfile, so the bars are driven by
-- the beat instead of by the waveform: the left of the bank lands on each beat
-- the way a low end does, the right flutters faster, and a slow wander keeps
-- neighbours from locking into the same shape. It is honestly a metronome
-- wearing an equalizer's coat, but it is a metronome set to the song.
function Snd.BarHeight(i, now)
	local elapsed = now - Snd.startedAt
	local bpm = Snd.bpm
	if not bpm or bpm <= 0 then bpm = 128 end   -- a pack that never said
	local beat = elapsed * bpm / 60
	local lowness = 1 - (i - 1) / math.max(1, Snd.BARS - 1)

	local hit = 1 - (beat % 1)
	hit = hit * hit                                     -- sharp attack, soft tail
	local flutter = 0.5 + 0.5 * math.sin(beat * 6.28318 * (0.8 + i * 0.45) + i * 1.7)
	local amount = lowness * hit + (1 - lowness) * flutter * 0.75
	amount = amount * (0.75 + 0.25 * math.sin(elapsed * 1.3 + i))

	return math.max(2, Snd.BAR_H * (0.12 + 0.88 * Clamp(amount, 0, 1)))
end

-- What the loading bar says while the helper works. The index read is the
-- indeterminate part -- how much of the archive has to be walked is not known
-- until it has been -- so that phase gets a moving block rather than a lie.
function Snd.ProgLabel()
	local p = Snd.prog
	if not p then return "loading sample...", -1 end
	if p.phase == "audio" then
		return "loading sample  " .. math.floor(Clamp(p.frac, 0, 1) * 100 + 0.5) .. "%", p.frac
	end
	if p.phase == "writing" then return "loading sample  100%", 1 end
	return "loading sample...", -1
end

-- Playing, or on its way to playing.
function Snd.Busy()
	return Snd.status == "playing" or Snd.status == "loading"
end

function Snd.Stop(quiet)
	Snd.token = Snd.token + 1
	if Snd.actor then Snd.actor:stop() end
	local was = Snd.status
	-- stopping early hands the music back early too
	if was == "playing" then SOUND:DimMusic(1, 0) end
	Snd.status, Snd.song, Snd.message = "idle", nil, nil
	Snd.prog, Snd.bpm, Snd.len, Snd.startedAt = nil, 0, 0, 0
	Snd.index = nil
	if was ~= "idle" and not quiet then Refresh() end
end

-- what the song-list header says about the preview, if anything
function Snd.Label()
	if Snd.status == "loading" then return (Snd.ProgLabel()) end
	if Snd.status == "playing" then return "playing a sample" end
	if Snd.status == "failed" then return Snd.message end
	return nil
end

function Snd.Begin(sample)
	local name = type(sample) == "table" and tostring(sample.name or "") or ""
	if not Snd.actor or name == "" then
		Snd.status = "failed"
		Snd.message = Snd.actor and "nothing came back" or "no audio output"
		return
	end
	Snd.actor:stop()
	-- the engine addresses files through its own filesystem, where Save is
	-- mounted at /Save; the helper's absolute path would mean nothing to it
	Snd.actor:load(BROWSER_DATA_DIR .. "previews/" .. name)
	local sound = Snd.actor:get()
	if sound then
		local from = tonumber(sample.start) or 0
		local len  = tonumber(sample.length) or 0
		-- a pack that never declared a sample still gets one: a little way in,
		-- which is where a song has usually started doing something
		if len <= 0 then from, len = math.max(from, 20), 20 end
		Snd.len = len
		sound:SetParam("StartSecond", from)
		sound:SetParam("LengthSeconds", len)
		sound:SetParam("FadeInSeconds", 0.5)
		sound:SetParam("FadeSeconds", 1.5)
		-- take the theme music down for as long as the sample runs; it comes
		-- back on its own, so nothing stays muted if the player wanders off
		SOUND:DimMusic(0, len + 1.5)
	end
	Snd.actor:play()
	Snd.status = "playing"
	Snd.prog = nil
	Snd.bpm = tonumber(sample.bpm) or 0
	Snd.startedAt = GetTimeSinceStart()
end

-- What the helper is doing right now, if anything. Deliberately quiet: a poll
-- that failed is not worth a message, and a poll that lands after the fetch
-- finished must not resurrect a bar over a sample that is already playing.
function Snd.Poll()
	if Snd.status ~= "loading" then return end
	local h = state.helper
	if not h.config then return end
	local url = HelperUrl("/preview/progress")
	if not NETWORK:IsUrlAllowed(url) then return end
	local mine = Snd.token
	NETWORK:HttpRequest{
		url = url,
		headers = { ["X-Browser-Token"] = h.config.token },
		connectTimeout = 2,
		transferTimeout = 4,
		onResponse = function(response)
			if mine ~= Snd.token or Snd.status ~= "loading" then return end
			if response.error ~= nil then return end
			local ok, data = pcall(JsonDecode, response.body or "")
			if not ok or type(data) ~= "table" then return end
			local p = data.progress
			if type(p) == "table" and p.active then
				Snd.prog = { phase = tostring(p.phase or ""), frac = tonumber(p.frac) or -1 }
			end
		end,
	}
end

-- Play a sample of one song. Asking again for the song already playing stops it.
function Snd.Play(pack, song)
	local title = type(song) == "table" and song.title or nil
	local id = pack and tonumber(pack.id)
	if not (id and title and title ~= "") then
		PlaySfx("invalid")
		return
	end
	local h = state.helper
	if not h.config then h.config = LoadHelperConfig() end
	if not h.config then
		PlaySfx("invalid")
		Toast("song samples need the content browser helper installed")
		return
	end
	local url = HelperUrl("/preview")
	if not NETWORK:IsUrlAllowed(url) then
		PlaySfx("invalid")
		Toast("127.0.0.1 is missing from HttpAllowHosts")
		return
	end

	Snd.Stop(true)
	PlaySfx("start")
	Snd.token = Snd.token + 1
	local mine = Snd.token
	Snd.status, Snd.song, Snd.message = "loading", title, nil
	Snd.index = state.songPick
	Snd.prog = nil
	-- leave the fetch a clear run at the network before asking after it
	Snd.pollAt = GetTimeSinceStart() + 0.6
	Refresh()

	NETWORK:HttpRequest{
		url = url,
		method = "POST",
		body = JsonEncode({ pack = id, song = title }),
		headers = {
			["X-Browser-Token"] = h.config.token,
			["Content-Type"]    = "application/json",
		},
		connectTimeout = 5,
		transferTimeout = 90,
		onResponse = function(response)
			-- the player asked for something else, or left
			if mine ~= Snd.token then return end
			if response.error ~= nil then
				Snd.status, Snd.message = "failed", "the helper is not running"
			else
				local ok, data = pcall(JsonDecode, response.body or "")
				if not ok or type(data) ~= "table" then
					Snd.status, Snd.message = "failed", "the helper sent something unreadable"
				elseif not data.ok then
					Snd.status, Snd.message = "failed", tostring(data.error or "no sample for this song")
				else
					Snd.Begin(data.sample)
				end
			end
			Refresh()
		end,
	}
end

local function ScanInstalled()
	local inst = state.installed
	CheckHelper()
	inst.packs = {}
	for name in ivalues(SONGMAN:GetSongGroupNames()) do
		local songs = SONGMAN:GetSongsInGroup(name)
		local dir = GroupDirFor(songs)
		-- SONGMAN gives the real folder, which is why the sync check lives
		-- here: GetDirListing caches for 30 seconds and would miss a pack that
		-- had only just been unzipped
		local sync, syncFile, syncOurs = Sync.OnDisk(dir)
		inst.packs[#inst.packs+1] = {
			name     = name,
			songs    = #songs,
			banner   = SONGMAN:GetSongGroupBannerPath(name),
			dir      = dir,
			sync     = sync,
			syncFile = syncFile,
			syncOurs = syncOurs,
		}
	end
	table.sort(inst.packs, function(a, b) return a.name:lower() < b.name:lower() end)
	inst.status = "ready"
	inst.scannedAt = GetTimeSinceStart()
	inst.cursor = Clamp(inst.cursor, 1, math.max(1, #inst.packs))
	inst.window = 0
	-- the CSV is what powers the SMO comparison
	FetchPackTypes()
end

-- Packs installed through this browser that came without a Pack.ini and are
-- old enough to predate the null-sync convention get one written for them,
-- assuming ITG.
--
-- Assuming ITG is the conservative half of the guess: with no Pack.ini the
-- engine already falls back to DefaultSyncOffset, which ships as ITG, so on a
-- stock machine the written file pins the behaviour the pack already had
-- rather than changing it. What it does cost is that DefaultSyncOffset stops
-- reaching these packs, which is why the file says so in a comment and why
-- this only ever touches packs installed from here -- never the rest of a
-- library.
local function ApplyAssumedSync()
	local cutoff = YearsAgoStr(SYNC_ASSUME_YEARS)
	local wrote = 0
	for pack in ivalues(state.installed.packs) do
		local when = state.autoSync[NormalizeName(pack.name)]
		if when and when < cutoff and pack.sync == nil and pack.dir
		   -- the folder has to still be there: a scan can run while SONGMAN
		   -- still holds a group whose files have just been deleted, and a
		   -- write would recreate the folder around a single file
		   and FILEMAN:DoesFileExist(pack.dir) then
			if Sync.Write(pack.dir, "ITG") then
				state.autoSync[NormalizeName(pack.name)] = nil
				pack.sync, pack.syncOurs = "ITG", true
				wrote = wrote + 1
			end
		end
	end
	if wrote > 0 then
		Toast((wrote == 1 and "Wrote a Pack.ini for 1 older pack"
			or ("Wrote a Pack.ini for " .. wrote .. " older packs"))
			.. " - restart to apply")
		Refresh()
	end
end

local function InstalledPack()
	local inst = state.installed
	return inst.packs[inst.cursor]
end

local function InstalledPages()
	return math.max(1, math.ceil(#state.installed.packs / INST_ROWS))
end

local function InstalledPage()
	return math.floor(state.installed.window / INST_ROWS) + 1
end

-- "unknown" (no SMO data yet) | "absent" | "match" | "differs"
local function InstalledStatus(pack)
	if not state.smoByName then return "unknown", nil end
	local smo = state.smoByName[NormalizeName(pack.name)]
	if not smo then return "absent", nil end
	if smo.songs == pack.songs then return "match", smo end
	return "differs", smo
end

local function InstalledStatusText(pack)
	local status, smo = InstalledStatus(pack)
	if status == "unknown" then return "checking stepmaniaonline...", 0.55, 0.55, 0.55 end
	if status == "absent"  then return "not on SMO", 0.55, 0.55, 0.55 end
	if status == "match"   then return "matches SMO", 0.40, 0.85, 0.45 end
	return "SMO has " .. smo.songs .. " songs", 0.97, 0.78, 0.30
end

-- every mode that keeps the tab row on screen
local BrowsingModes = {
	list = true, confirm = true, installed = true, removeconfirm = true,
	year = true, beginner = true, tech = true, stamina = true,
}

local function InInstalledView()
	return state.mode == "installed" or state.mode == "removeconfirm"
end

local function InYearView()
	return state.mode == "year"
end

local function InLevelView()
	return state.mode == "tech" or state.mode == "stamina"
		or state.mode == "beginner"
end

-- every mode that shows the paged pack list and its info pane; the featured
-- strip is deliberately not part of this
local function InPackList()
	return state.mode == "list" or state.mode == "year" or InLevelView()
end

-- the order the tab row cycles in; index 1 is SEARCH
local TabOrder = { "search", "pad", "keyboard", "beginner", "tech", "stamina", "year", "installed" }

-- which tab the current view corresponds to
local function ActiveTabIndex()
	if InInstalledView() then return 8 end
	if InYearView() then return 7 end
	if state.mode == "stamina" then return 6 end
	if state.mode == "tech" then return 5 end
	if state.mode == "beginner" then return 4 end
	if state.search ~= "" then return 1 end
	for i, name in ipairs(TabOrder) do
		if name == state.filterMode then return i end
	end
	return 2
end

local function TabIsActive(tab)
	-- while the cursor is on the row it leads; otherwise the active view does
	local want = (state.zone == "tabs") and state.tabIndex or ActiveTabIndex()
	return TabOrder[want] == (tab.view or tab.mode)
end

local function EnterInstalled()
	state.mode = "installed"
	state.zone = "list"
	local inst = state.installed
	-- a download during this session changes the library, so rescan on a
	-- revisit rather than trusting the first scan forever
	if inst.status == "idle" or state.needsReload
	   or (inst.scannedAt and GetTimeSinceStart() - inst.scannedAt > 30) then
		ScanInstalled()
	end
	if #inst.packs == 0 then state.zone = "tabs" end
	ApplyAssumedSync()
	Refresh()
end

-- ---------------------------------------------------------------
-- featured packs.
--
-- A pack earns a spot two ways.  Either it has a full difficulty spread, which
-- is worth featuring on its own merits and skips every other check, or it
-- clears the quality bar (banner, 20+ charts, 3+ difficulties, a wide 7-15
-- range) AND one of its top charters is established -- meaning SMO has listed
-- at least two of their other packs inside the recency window.
--
-- Candidates come from one date-sorted page; details, charter lookups and the
-- recency index all load in the background, so the strip fills in as verdicts
-- land rather than blocking on the slowest request.


-- how many of the meters 7..15 have at least one chart
local function FeaturedScore(det)
	local score = 0
	for i, label in ipairs(det.labels) do
		if label >= 7 and label <= 15 and (det.counts[i] or 0) > 0 then
			score = score + 1
		end
	end
	return score
end

-- A genuine beginner-to-expert spread: something easy, something hard, and
-- most of the rungs in between actually populated.
local function FeaturedFullSpread(det)
	local labels = det.labels
	if #labels < 13 then return false end
	if labels[1] > 3 or labels[#labels] < 15 then return false end
	-- every rung between the ends has to be populated; SMO only lists meters
	-- that actually have charts, so a gap shows up as a jump in the labels
	for i = 2, #labels do
		if labels[i] ~= labels[i-1] + 1 then return false end
	end
	return true
end

-- the bar every candidate clears before the charter question is even asked
local function FeaturedQuality(pack, det)
	if not BannerUrlFor(pack) then return nil end
	if not DanceOnly(pack) then return nil end
	if not BannerShapeOk(pack) then return nil end
	if det and not DanceChartsOnly(det) then return nil end
	-- a featured pack should be a sitting worth browsing: not one chart, and
	-- not a 400-song megapack that dwarfs everything beside it
	local songs = tonumber(pack.songs) or 0
	if songs < FEAT.MIN_SONGS or songs > FEAT.MAX_SONGS then return nil end

	-- an untyped pack is a personal simfile dump, not a release
	if not PackTypeOf(pack.id) then return nil end
	local rank = state.arrowcloud.keys[NormalizeName(pack.name)]
	if not rank then
		-- not on the ranking: it has to have been catalogued to qualify
		local sub = state.packSubstyle and state.packSubstyle[tostring(pack.id)]
		if not sub or sub == "mods" then return nil end
	end
	-- Popularity is the ranking, so it is also the score. Packs arrowcloud has
	-- never heard of sort last among equals.
	return rank and (1000 - rank) or 1
end

-- ---------------------------------------------------------------
-- recency index: which pack ids SMO has listed inside the window.
--
-- The charter search returns everything a person is credited on but carries no
-- dates, and the only dated source is the paged pack list.  So walk that list
-- once per session down to the cutoff and keep an id -> date map to join
-- against.  It is about seven requests, gzipped on the wire by the engine's
-- HTTP client, and it runs in the background while the strip fills.

-- the picker runs from the current year back to 2015, plus an "OLDER" chip
-- for everything before that; it widens by one chip each January
local YEAR_SPAN        = CurrentYear() - 2018   -- a page per year back to 2019, then OLDER
local RECENT_YEARS     = 5
local RECENT_PAGE      = 250  -- half the server maximum: first page lands sooner
local RECENT_MAX_PAGES = 40   -- 10,000 rows: the whole list, for the OLDER page

local function RecentCutoff()
	return string.format("%04d-%02d-01", CurrentYear() - RECENT_YEARS, CurrentMonth())
end

local FeaturedStep     -- forward declarations (mutually recursive via callbacks)
local FeaturedResolve
local FetchArrowcloud   -- the beginner view starts it, and is defined first

local function RecentIndexStep()
	local idx = state.recentIndex
	if idx.status ~= "loading" then return end
	if idx.page >= RECENT_MAX_PAGES then
		idx.status = "ready"
		FeaturedResolve()
		return
	end

	FetchServerRows(idx.page * RECENT_PAGE, RECENT_PAGE, "", function(rows, _, err)
		if state.recentIndex ~= idx then return end
		if err or not rows or #rows == 0 then
			-- a partial index still answers most questions; only a completely
			-- empty one counts as a failure
			idx.status = (idx.page > 0) and "ready" or "failed"
			FeaturedResolve()
			return
		end

		idx.page = idx.page + 1
		idx.scanned = idx.page * RECENT_PAGE   -- for anything drawing progress
		local oldest = nil
		for pack in ivalues(rows) do
			if pack.date ~= "" then
				idx.dates[pack.id] = pack.date
				oldest = pack.date          -- rows arrive newest-first
				-- keeping the rows inside the summary window costs nothing here and
				-- saves the year view from walking the list a second time
				if pack.date >= idx.yearCutoff and not idx.seen[pack.id] then
					idx.seen[pack.id] = true
					idx.rows[#idx.rows+1] = pack
				end
			end
		end

		if oldest then
			idx.oldest = oldest
			idx.year = tonumber(oldest:sub(1, 4))
			-- How far back the walk has come, against how far it means to go.
			-- Measured in months rather than pages, because the target is a
			-- date and a page count says nothing about how near it is.
			local nowM = CurrentYear() * 12 + CurrentMonth()
			local atM  = (tonumber(oldest:sub(1, 4)) or 0) * 12
				+ (tonumber(oldest:sub(6, 7)) or 1)
			local tgt  = idx.stopAt or ""
			local tgtM = (tonumber(tgt:sub(1, 4)) or 0) * 12
				+ (tonumber(tgt:sub(6, 7)) or 1)
			if idx.deep or tgtM <= 12 then
				-- OLDER runs until the catalogue does, so the page cap is the
				-- only honest bound there is
				idx.frac = Clamp(idx.page / RECENT_MAX_PAGES, 0, 1)
			elseif nowM > tgtM then
				idx.frac = Clamp((nowM - atM) / (nowM - tgtM), 0, 1)
			else
				idx.frac = 1
			end
		end

		if #rows < RECENT_PAGE or (oldest and idx.stopAt and oldest < idx.stopAt) then
			idx.status = "ready"
			idx.frac = 1
			FeaturedResolve()
			if RefreshYearView then RefreshYearView() end
			if RefreshLevelView then RefreshLevelView() end
		else
			RecentIndexStep()
			if RefreshYearView then RefreshYearView() end
			if RefreshLevelView then RefreshLevelView() end
		end
	end)
end

local function EnsureRecentIndex()
	local idx = state.recentIndex
	if idx.status ~= "idle" then return end
	if not UrlAllowed() then idx.status = "failed" return end
	idx.cutoff = RecentCutoff()
	idx.stopAt = idx.cutoff   -- how far back this walk currently intends to go
	-- keep every dated row the walk passes: the OLDER page needs all of them,
	-- and a narrower cutoff would leave a hole if the walk is later resumed
	-- at a greater depth
	idx.yearCutoff = "0000-01-01"
	idx.deep = false
	idx.status = "loading"
	RecentIndexStep()
end

-- ---------------------------------------------------------------
-- content levels.
--
-- Two broad buckets rather than a difficulty filter: "All Around" is
-- everything that tops out at 18, and "Hard Content / Stamina" is the packs
-- whose bulk sits above it.  A pack with only a chart or two above the line is
-- not a stamina pack, so it stays in the all-around bucket.  The internal key
-- for the first bucket is still `tech`, which is what it was originally called.
--
-- Neither the pack list nor the CSV carries difficulty data, so this can only
-- be decided from a pack's detail page.  That rules out bucketing all 9,000
-- packs; instead the recency index supplies a pool of recent packs and their
-- details are fetched a few at a time, with the list filling in as verdicts
-- land -- the same shape as the featured grid.

local LEVEL = {
	THRESHOLD   = 18,   -- the line between all-around and stamina
	MIN_HARD    = 3,    -- one or two hard charts does not make a stamina pack
	HARD_BULK   = 12,   -- ...but this many is a stamina pack whatever else it has
	MAX_DETAILS = 90,   -- give up after this many detail fetches
	TARGET      = 400,  -- rows per helping; the list extends when it runs out
	-- beginner-friendly: down to the 1s, nothing above 14, and a real easy
	-- ramp rather than one token easy chart.  Measured over arrowcloud's top
	-- 250: 60 of the 244 that resolve to an SMO pack clear the first two
	-- tests, and the third drops exactly the three that pass on a single
	-- easy chart, leaving 57.
	BEG_FLOOR   = 1,    -- the beginner-slot chart is at least this...
	BEG_CEIL    = 4,    -- ...rated no higher than this
	BEG_EASY    = 3,    -- "easy" means meter this or below...
	BEG_MIN_EASY = 3,   -- ...and at least this many of them
	BEG_FIRST   = 7,    -- rows to find before pausing: one page, then on demand
	POP_RANK    = 250,  -- how deep the popularity list is read
	FEAT_RANK   = 250,  -- how deep the featured grid's gate goes: the whole
	                    -- popularity list rather than its first three pages,
	                    -- which was too tight to fill a grid of 24
}

local LevelLabels = {
	beginner = "BEGINNER FRIENDLY",
	tech     = "ALL AROUND",
	stamina  = "HARD CONTENT / STAMINA",
}

local LevelBlurbs = {
	beginner = "Popular packs whose beginner charts are mostly 1s to 4s.",
	tech     = "Packs stepmaniaonline.net lists as technical or all-around.",
	stamina  = "Packs stepmaniaonline.net lists as stamina.",
}

-- A pack worth handing a beginner: it reaches down to the easiest blocks,
-- never goes above 14, and has a real easy ramp rather than one token chart.
-- Measured over arrowcloud's top 250, that last test is what separates a pack
-- a beginner can work through from one with a single easy chart bolted on.
local function BeginnerPack(det)
	if not det or not det.songs then return false end
	local easy, total = 0, 0
	for song in ivalues(det.songs) do
		-- singles only: a doubles chart is not what a beginner is going to
		-- stand on, so a song without one does not count either way
		if song.styles and song.styles["dance-single"] then
			-- "3-11": the low end is the easiest chart the song has, which is
			-- the one sitting in the beginner slot
			local low = tonumber(tostring(song.meters or ""):match("^%s*(%d+)"))
			if low then
				total = total + 1
				if low >= LEVEL.BEG_FLOOR and low <= LEVEL.BEG_CEIL then
					easy = easy + 1
				end
			end
		end
	end
	return total > 0 and easy * 2 > total   -- most of the pack
end

-- The other buckets draw on the recency index. This one is the popularity
-- list joined onto SMO's catalogue by name, so it needs both to have landed.
local function BeginnerPool()
	local pool, seen = {}, {}
	if not state.smoByName then return pool end
	for rank = 1, LEVEL.POP_RANK do
		local key = state.arrowcloud.ranked[rank]
		local rec = key and state.smoByName[key]
		if rec and not seen[rec.id] then
			seen[rec.id] = true
			-- a pack SMO calls stamina cannot top out at block 14, and one it
			-- calls mods is not a difficulty at all: neither is worth a request
			local sub = state.packSubstyle and state.packSubstyle[tostring(rec.id)]
			local row = (sub ~= "stamina" and sub ~= "mods")
				and RowFromCatalog(rec.id, nil) or nil
			if row and DanceOnly(row) and PackTypeOf(row.id) ~= "keyboard" then
				pool[#pool+1] = row
			end
		end
	end
	return pool
end

-- Which bucket a pack belongs in according to SMO's own substyle tag. Free,
-- but only as complete as SMO's tagging, which is recent -- nil means untagged
-- rather than unsuited, and those get looked at properly in the second pass.
local function ContentBucket(pack)
	local sub = state.packSubstyle and state.packSubstyle[tostring(pack.id)]
	if sub == "stamina" then return "stamina" end
	if sub == "technical" or sub == "all around" then return "tech" end
	return nil
end

-- ...and the way it was worked out before there were tags: from the pack's
-- own chart distribution. This needs the pack page, so it only runs over what
-- the tags did not already answer.
local function ChartBucket(det)
	local above, below = 0, 0
	for i, meter in ipairs(det.labels) do
		local n = det.counts[i] or 0
		if meter > LEVEL.THRESHOLD then
			above = above + n
		else
			below = below + n
		end
	end
	if above >= LEVEL.MIN_HARD
	   and (above * 3 >= below or above >= LEVEL.HARD_BULK) then
		return "stamina"
	end
	if below > 0 then return "tech" end
	return nil
end

local function LevelPool(bucket)
	if bucket == "beginner" then return BeginnerPool() end

	-- All Around and Stamina describe pad difficulty, so a keyboard pack has no
	-- business in either -- and unlike the pad/keyboard tabs these are views,
	-- not filters, so they must not inherit whichever filter tab was last
	-- touched on the way here.
	local pool, seen = {}, {}

	-- everything SMO has tagged for this bucket, newest first
	local tagged = {}
	for id, sub in pairs(state.packSubstyle or {}) do
		local bucketFor = (sub == "stamina") and "stamina"
			or ((sub == "technical" or sub == "all around") and "tech")
			or nil
		if bucketFor == bucket and PackTypeOf(id) ~= "keyboard" then
			tagged[#tagged+1] = id
		end
	end
	table.sort(tagged, function(a, b)
		return (tonumber(a) or 0) > (tonumber(b) or 0)
	end)
	for id in ivalues(tagged) do
		local row = RowFromCatalog(id, nil)
		if row then
			seen[id] = true
			pool[#pool+1] = row
		end
	end

	-- then the untagged recent packs, which is what the deep pass looks at
	for pack in ivalues(state.recentIndex.rows) do
		if not seen[pack.id] and DanceOnly(pack) and BannerShapeOk(pack)
		   and PackTypeOf(pack.id) ~= "keyboard" then
			pool[#pool+1] = pack
		end
	end
	return pool
end

local LevelStep  -- forward declaration (recursive via callbacks)

-- Another helping: called when somebody reaches the end of what has been
-- gathered so far. Returns false when there is genuinely nothing more.
function LEVEL.Extend()
	local lv = state.level
	if not lv or lv.status ~= "loading" and lv.status ~= "ready" then return false end
	if not lv.more then return false end
	lv.limit  = lv.limit + ((lv.bucket == "beginner")
		and LEVEL.BEG_FIRST or LEVEL.TARGET)
	lv.budget = lv.budget + LEVEL.MAX_DETAILS
	lv.more   = false
	lv.status = "loading"
	LevelStep()
	return true
end

local function LevelPublish()
	local lv = state.level
	if state.mode ~= lv.bucket then return end
	state.localRows = lv.rows
	FetchPacks(state.page, true)
end

LevelStep = function()
	local lv = state.level
	if lv.status ~= "loading" then return end

	if lv.bucket == "beginner" then
		local ac = state.arrowcloud
		if ac.deep == "idle" or ac.deep == "loading" then return end
		if not state.smoByName then return end
		if #lv.pool == 0 then
			lv.pool = LevelPool("beginner")
		end
	else
		-- the tagged pass reads the catalogue, so that is what it waits for;
		-- finishing before it arrived is what made a freshly opened All Around
		-- report nothing at all
		if not state.packSubstyle then
			FetchPackTypes()
			return
		end
		if #lv.pool == 0 then
			lv.pool = LevelPool(lv.bucket)
			if #lv.pool == 0 then return end
		end

		-- second pass: the packs the tags said nothing about. Those come from
		-- the recency index, so hold on until it has finished arriving.
		if lv.poolPos >= #lv.pool and not lv.deep and lv.inFlight == 0 then
			local idx = state.recentIndex
			if idx.status == "idle" or idx.status == "loading" then return end
			lv.pool = LevelPool(lv.bucket)
			lv.deep = true
			lv.poolPos = 0
		end
	end

	local atOnce = (lv.bucket == "beginner") and 4 or 8
	while lv.inFlight < atOnce and lv.poolPos < #lv.pool
	      and #lv.rows < lv.limit
	      and lv.fetched < lv.budget do
		lv.poolPos = lv.poolPos + 1
		local pack = lv.pool[lv.poolPos]

		-- Pass one is free: SMO's tag answers outright. Pass two reads the pack
		-- page for the ones it did not, which is the only way to place a pack
		-- from before SMO started tagging.
		if lv.bucket ~= "beginner" then
			local tagged = ContentBucket(pack)
			if not lv.deep then
				if tagged == lv.bucket then lv.rows[#lv.rows+1] = pack end
			elseif tagged == nil and lv.fetched < LEVEL.MAX_DETAILS then
				local cached = state.details[pack.id]
				local function place(det)
					if det and #det.labels > 0 and DanceChartsOnly(det)
					   and ChartBucket(det) == lv.bucket then
						lv.rows[#lv.rows+1] = pack
					end
				end
				if cached then
					place(cached)
				else
					lv.inFlight = lv.inFlight + 1
					lv.fetched = lv.fetched + 1
					FetchDetail(pack, function(det)
						if state.level ~= lv then return end
						lv.inFlight = lv.inFlight - 1
						place(det)
						LevelPublish()
						LevelStep()
						Refresh()
					end)
				end
			end
		else
			local cached = state.details[pack.id]
			if cached then
				if BeginnerPack(cached) then lv.rows[#lv.rows+1] = pack end
			else
				lv.inFlight = lv.inFlight + 1
				lv.fetched = lv.fetched + 1
				FetchDetail(pack, function(det)
					if state.level ~= lv then return end
					lv.inFlight = lv.inFlight - 1
					if BeginnerPack(det) then lv.rows[#lv.rows+1] = pack end
					LevelPublish()
					LevelStep()
					Refresh()
				end)
			end
		end
	end

	-- the tagged pass finishing is not the end; the deep pass follows it
	local lastPass = (lv.bucket == "beginner") or lv.deep
	local filled = (#lv.rows >= lv.limit)
	local spent  = (lv.fetched >= lv.budget)
	local exhausted = filled
	                  or (lv.poolPos >= #lv.pool and lastPass)
	                  or (spent and lastPass)
	-- there is more to find if the walk stopped on a limit rather than on the
	-- end of the pool
	if lv.inFlight == 0 and exhausted then
		lv.more = (filled or spent) and (lv.poolPos < #lv.pool or not lv.deep)
	end
	if lv.inFlight == 0 and exhausted then
		lv.status = "ready"
		LevelPublish()
		Refresh()
	end
end

local function EnterLevelView(bucket)
	state.mode = bucket
	state.zone = "list"
	state.search = ""
	state.viewYear = nil
	if bucket == "beginner" then
		-- the popularity ranking and the CSV catalogue, both idempotent
		FetchArrowcloud()
		FetchPackTypes()
	else
		EnsureRecentIndex()
	end

	local pool = LevelPool(bucket)

	state.level = {
		status = "loading", bucket = bucket, rows = {}, pool = pool,
		poolPos = 0, inFlight = 0, fetched = 0,
		deep = false,   -- false while the free pass over SMO's tags is running
		-- the beginner list pays a pack page per candidate, so it stops far
		-- sooner and picks up again if anyone reaches the end
		limit = (bucket == "beginner") and LEVEL.BEG_FIRST or LEVEL.TARGET,
		budget = LEVEL.MAX_DETAILS,  -- pack pages to spend before pausing
		more = false,                -- true when a pause left something behind
	}
	state.page = 1
	state.cursor = 1
	state.localRows = {}
	LevelStep()
	FetchPacks(1, false)
	Refresh()
end

-- the pools load in the background: the recency index for the content levels,
-- the popularity ranking plus the CSV catalogue for the beginner list
RefreshLevelView = function()
	local lv = state.level
	if not lv or lv.status ~= "loading" then return end
	if state.mode ~= lv.bucket then return end
	local pool = LevelPool(lv.bucket)
	if #pool > #lv.pool then
		lv.pool = pool
	end
	LevelStep()
end

-- text for the band that replaces the featured grid in the search and
-- content-level views
local function BandTitle()
	if InLevelView() then return LevelLabels[state.mode] or "" end
	if state.search ~= "" then return "SEARCH RESULTS" end
	if state.mode == "list" and state.filterMode == "keyboard" then
		return "KEYBOARD PACKS"
	end
	return ""
end

local function BandSubtitle()
	if InLevelView() then
		local lv = state.level
		local blurb = LevelBlurbs[state.mode] or ""
		if lv.status == "loading" then
			return blurb .. (lv.deep and "  Checking older packs..."
				or "  Checking packs...")
		end
		-- the beginner list pauses after a page, so any total it could print
		-- would be a statement about the pause rather than about the packs
		if lv.bucket == "beginner" then return blurb end
		return blurb .. string.format("  %d%s found.",
			#lv.rows, lv.more and "+" or "")
	end
	if state.search ~= "" then
		return string.format("\"%s\" in pack names, chart authors and song titles.",
			state.search)
	end
	if state.mode == "list" and state.filterMode == "keyboard" then
		return string.format(
			"Packs stepmaniaonline.net lists as keyboard.  %d found.",
			#(state.keyboardPacks or {}))
	end
	return ""
end

local function BandBusy()
	if InLevelView() then return state.level.status == "loading" end
	return state.search ~= "" and state.loading
end

-- The spinner used to carry a "fetched / budget" counter, which read as a
-- pack count and was wrong about it. It says nothing now; the blurb beside it
-- already says which pass is running.
local function BandBusyText()
	return ""
end

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


-- ---------------------------------------------------------------
-- arrowcloud.dance: what people are actually playing.
--
-- A featured slot is reserved for packs that have earned a place on the first
-- three pages of https://arrowcloud.dance/packs, which is that site's own
-- popularity ranking. Its front end reads a public, keyless JSON API, and
-- since a page is 25 packs and the limit caps at 100, all three pages arrive
-- in a single request.
--
-- The two sites share no identifier, so packs are matched on a normalised
-- name. Measured against SMO's catalogue that resolves 74 of the 75.
--
-- If the host is not on the allowlist (an install that predates this feature)
-- or the site is unreachable, the strip falls back to the difficulty-spread
-- and charter rules and says so in its heading, rather than showing nothing.

-- The API silently clamps limit to 100 -- limit=250 returns 100 records with
-- no error -- so the top 250 is three requests, and a rank has to be derived
-- from its page rather than a running counter, because the three can land in
-- any order.
local ARROWCLOUD_URL = "https://api.arrowcloud.dance/packs"
	.. "?page=%d&limit=100&orderBy=popularity&orderDirection=desc"

-- Two statuses, deliberately. The featured grid blocks on the ranking, and
-- page 1 alone already contains the whole top 75 it gates on, so `status`
-- settles there and the grid starts work a round trip earlier. `deep` is what
-- the beginner category waits on.
-- status: idle | loading | ready | blocked | failed
FetchArrowcloud = function()
	local ac = state.arrowcloud
	if ac.status ~= "idle" then return end
	if not NETWORK:IsUrlAllowed(string.format(ARROWCLOUD_URL, 1)) then
		ac.status = "blocked"
		ac.deep = "failed"
		return
	end

	ac.status = "loading"
	ac.deep = "loading"
	ac.pending = 3

	for page = 1, 3 do
		NETWORK:HttpRequest{
			url = string.format(ARROWCLOUD_URL, page),
			connectTimeout = 10,
			transferTimeout = 30,
			onResponse = function(response)
				local ok, data = false, nil
				if response.error == nil and response.statusCode == 200 then
					ok, data = pcall(JsonDecode, response.body)
				end
				if ok and type(data) == "table" and type(data.data) == "table" then
					local index = 0
					for entry in ivalues(data.data) do
						index = index + 1
						if type(entry.name) == "string" then
							local key = NormalizeName(entry.name)
							-- first mention wins, so a duplicate name keeps its
							-- better rank; that leaves holes in `ranked`
							if key ~= "" and not ac.keys[key] then
								local rank = (page - 1) * 100 + index
								ac.keys[key] = rank
								ac.ranked[rank] = key
								ac.count = ac.count + 1
							end
							if key ~= "" and type(entry.createdAt) == "string" then
								ac.created[key] = entry.createdAt:sub(1, 10)
							end
							if key ~= "" and not ac.banner[key] then
								-- the small and medium variants are usually null
								ac.banner[key] = entry.smBannerUrl or entry.mdBannerUrl
									or entry.bannerUrl
							end
							if key ~= "" and ac.packId[key] == nil then
								ac.packId[key] = entry.id
							end
						end
					end
				end

				if page == 1 then
					ac.status = (ac.count > 0) and "ready" or "failed"
					FeaturedStep()
					FeaturedResolve()
				end

				ac.pending = ac.pending - 1
				if ac.pending <= 0 then
					ac.deep = (ac.count > 0) and "ready" or "failed"
					if RefreshLevelView then RefreshLevelView() end
				end
				Refresh()
			end,
		}
	end
end

-- arrowcloud's newest-first listing: 200 packs, which comfortably covers a
-- five-month window.  Used two ways -- to confirm that a pack SMO lists as
-- recently added really is a recent release, and to find recent releases SMO
-- has filed under an older date.
local function FetchArrowcloudNew()
	local ac = state.arrowcloud
	if ac.newStatus ~= "idle" then return end
	local url = "https://api.arrowcloud.dance/packs"
		.. "?page=%d&limit=100&orderBy=createdAt&orderDirection=desc"
	if not NETWORK:IsUrlAllowed(string.format(url, 1)) then
		ac.newStatus = "failed"
		return
	end

	ac.newStatus = "loading"
	ac.newPending = 3
	for page = 1, 3 do
		NETWORK:HttpRequest{
			url = string.format(url, page),
			connectTimeout = 10,
			transferTimeout = 30,
			onResponse = function(response)
				local ok, data = false, nil
				if response.error == nil and response.statusCode == 200 then
					ok, data = pcall(JsonDecode, response.body)
				end
				if ok and type(data) == "table" and type(data.data) == "table" then
					for entry in ivalues(data.data) do
						if type(entry.name) == "string" then
							local key = NormalizeName(entry.name)
							if key ~= "" then
								ac.fresh[key] = true
								if type(entry.createdAt) == "string" then
									ac.created[key] = entry.createdAt:sub(1, 10)
								end
								if not ac.banner[key] then
									ac.banner[key] = entry.smBannerUrl or entry.mdBannerUrl
										or entry.bannerUrl
								end
							end
						end
					end
				end
				ac.newPending = ac.newPending - 1
				if ac.newPending <= 0 then
					ac.newStatus = "ready"
					FeaturedStep()
					FeaturedResolve()
				end
				Refresh()
			end,
		}
	end
end

-- When a pack was actually released, as opposed to when SMO's row was last
-- touched. nil when arrowcloud has never heard of it.
local function ArrowcloudReleased(pack)
	return state.arrowcloud.created[NormalizeName(pack.name)]
end

-- true / false, or nil while the ranking is still on its way.  Ranks past the
-- featured gate read as false, exactly as an unknown name does.
local function ArrowcloudApproved(pack)
	local ac = state.arrowcloud
	if ac.status ~= "ready" then return nil end
	local rank = ac.keys[NormalizeName(pack.name)]
	return rank ~= nil and rank <= LEVEL.FEAT_RANK
end

-- ---------------------------------------------------------------
-- charter lookups: /api/search/?type=credit returns every pack a person is
-- credited on, as ids that join straight onto the recency index.

local function FetchAuthorPacks(name, cb)
	local entry = state.authorPacks[name]
	if entry then
		if entry.status == "loading" then
			entry.waiting[#entry.waiting+1] = cb
		else
			cb(entry)
		end
		return
	end

	entry = { status = "loading", ids = {}, waiting = { cb } }
	state.authorPacks[name] = entry

	local function finish(status)
		entry.status = status
		local waiting = entry.waiting
		entry.waiting = {}
		for fn in ivalues(waiting) do fn(entry) end
	end

	if not UrlAllowed() then finish("failed") return end

	local query = NETWORK:EncodeQueryParameters{
		["query"] = name,
		["type"]  = "credit",
		["exact"] = "1",
	}
	NETWORK:HttpRequest{
		url = SMO_BASE .. "/api/search/?" .. query,
		connectTimeout = 10,
		transferTimeout = 30,
		onResponse = function(response)
			local ok, data = false, nil
			if response.error == nil and response.statusCode == 200 then
				ok, data = pcall(JsonDecode, response.body)
			end
			if ok and type(data) == "table" and type(data.results) == "table" then
				for result in ivalues(data.results) do
					local id = tonumber(result.id)
					if id then entry.ids[#entry.ids+1] = string.format("%d", id) end
				end
				finish("ready")
			else
				finish("failed")
			end
			Refresh()
		end,
	}
end

-- how many OTHER packs by this charter fall inside the recency window
local function AuthorRecentCount(entry, packId)
	local idx = state.recentIndex
	local n = 0
	for id in ivalues(entry.ids) do
		if id ~= packId then
			local date = idx.dates[id]
			if date and date >= idx.cutoff then n = n + 1 end
		end
	end
	return n
end

-- "accept" / "reject" / "unknown" (nobody identifiable) / "wait" (still loading)
local function CandidateVerdict(cand)
	-- SMO's date is when the row was last touched, and old packs do get
	-- re-added, so a pack arrowcloud knows is checked against its real release
	-- date instead. This applies on every pass: a top-up still has to be new.
	local f = state.featured
	-- Pass 2 only runs when the ranked packs could not fill the grid, and only
	-- over packs that already cleared the quality bar, so the ranking is not
	-- consulted again -- these are the top-up.
	if (cand.tier or 1) >= 2 then return "accept" end

	-- The popularity ranking is the gate whenever it is available. It has
	-- nothing to say about keyboard packs, which are barely represented on
	-- arrowcloud, so those skip straight to the spread and charter rules.
	if f.mode ~= "keyboard" then
		local approved = ArrowcloudApproved(cand.pack)
		if approved ~= nil then
			return approved and "accept" or "reject"
		end
		if state.arrowcloud.status == "loading" then return "wait" end
	end

	-- ranking unreachable: fall back to the spread and charter rules
	if cand.spread then return "accept" end

	local idx = state.recentIndex
	if idx.status == "idle" then
		-- nothing started it, because the ranking was working when this build
		-- began; start it now and come back to this candidate
		EnsureRecentIndex()
		return "wait"
	end
	if idx.status == "loading" then return "wait" end
	if idx.status == "failed" then return "unknown" end

	local waiting, resolved = false, 0
	for name in ivalues(cand.authors) do
		local entry = state.authorPacks[name]
		if entry == nil or entry.status == "loading" then
			waiting = true
		elseif entry.status == "ready" then
			resolved = resolved + 1
			if AuthorRecentCount(entry, cand.pack.id) >= FEAT.AUTHOR_MIN then
				return "accept"
			end
		end
	end

	if waiting then return "wait" end
	if resolved == 0 then return "unknown" end
	return "reject"
end

-- ---------------------------------------------------------------

-- a sortable date for a candidate: the list date when there is one, else the
-- one scraped off the pack page (keyboard candidates only have the latter)
local function FeaturedDate(pack)
	if pack.date and pack.date ~= "" then return pack.date end
	local det = state.details[pack.id]
	return det and IsoFromLongDate(det.date) or ""
end

local function FeaturedAccept(f, pack, score, spread)
	f.carded = f.carded or {}
	if f.carded[pack.id] then return end   -- never show a pack twice
	f.carded[pack.id] = true
	f.cards[#f.cards+1] = {
		pack = pack, score = score, spread = spread or false,
		date = FeaturedDate(pack),
	}
end

local function FeaturedConsider(pack, det)
	local f = state.featured
	local score = FeaturedQuality(pack, det)
	if not score then return end

	local spread = det ~= nil and FeaturedFullSpread(det) or false
	if spread then score = score + FEAT.SPREAD_BONUS end

	local authors = {}
	for name in ivalues((det and det.credits) or {}) do
		if #authors >= FEAT.AUTHOR_TOP then break end
		authors[#authors+1] = name
	end

	f.pending[#f.pending+1] = {
		pack = pack, score = score, authors = authors, spread = spread,
		tier = f.tier or 1,
	}
	FetchArrowcloud()
	-- The charter rules are only ever consulted when the ranking is
	-- unreachable, so they are only started then. Starting them speculatively
	-- put three author lookups per candidate on the wire and starved the detail
	-- fetches this grid is actually waiting on.
	local ranking = state.arrowcloud.status
	if ranking == "blocked" or ranking == "failed" then
		EnsureRecentIndex()
		for name in ivalues(authors) do
			FetchAuthorPacks(name, function() FeaturedResolve() end)
		end
	end
end

local function FeaturedFinalize()
	local f = state.featured
	-- packs whose charters could not be identified are held back and only used
	-- to keep the strip from looking broken
	if #f.cards < FEAT.BUILD and #f.fallback > 0 then
		table.sort(f.fallback, function(a, b)
			return FeaturedDate(a.pack) > FeaturedDate(b.pack)
		end)
		for cand in ivalues(f.fallback) do
			if #f.cards >= FEAT.BUILD then break end
			FeaturedAccept(f, cand.pack, cand.score, false)
		end
	end
	-- Deliberately NOT re-sorted here. Cards are already added in date order
	-- (see FeaturedResolve), and re-sorting at the end made the whole grid
	-- visibly rearrange itself several seconds after it had finished painting.
	f.status = "ready"
	Refresh()
end

FeaturedResolve = function()
	local f = state.featured
	if f.status ~= "loading" then return end

	-- Accepted candidates are sorted before they are added, and the finished
	-- grid is never re-sorted, so a card that has been painted keeps its place.
	-- Verdicts land out of order (an author lookup can outlive its neighbours),
	-- which is what made the grid rearrange itself after it looked finished.
	local stillPending, taking = {}, {}
	for cand in ivalues(f.pending) do
		local verdict = CandidateVerdict(cand)
		if verdict == "accept" then
			taking[#taking+1] = cand
		elseif verdict == "unknown" then
			f.fallback[#f.fallback+1] = cand
		elseif verdict == "wait" then
			stillPending[#stillPending+1] = cand
		end
		-- "reject" simply drops the candidate
	end
	table.sort(taking, function(a, b)
		local ad, bd = FeaturedDate(a.pack), FeaturedDate(b.pack)
		if ad ~= bd then return ad > bd end
		return a.score > b.score
	end)
	for cand in ivalues(taking) do
		FeaturedAccept(f, cand.pack, cand.score, cand.spread)
	end
	f.pending = stillPending

	Refresh()
	FeaturedStep()
end

-- The pad grid is arrowcloud's popularity ranking, walked in the ranking's own
-- order. SMO is consulted only for the pack id and song count, because
-- arrowcloud has neither and the id is what downloads a pack. No pack pages
-- and no paging through SMO are involved at all.
local function FeaturedPoolFromRanking(f)
	local ac = state.arrowcloud
	for rank = 1, LEVEL.POP_RANK do
		local key = ac.ranked[rank]
		local rec = key and state.smoByName and state.smoByName[key]
		if rec and not f.seen[rec.id] then
			f.seen[rec.id] = true
			local row = RowFromCatalog(rec.id, nil)
			if row then
				row.banner = ac.banner[key]          -- arrowcloud's own artwork
				row.date   = ac.created[key] or ""   -- and its release date
				f.pool[#f.pool+1] = row
			end
		end
	end
	f.poolReady = true
end

FeaturedStep = function()
	local f = state.featured
	if f.status ~= "loading" then return end

	-- The ranking decides which packs are worth a detail page at all, so wait
	-- for it rather than spending a request per pack on ones that cannot
	-- qualify. FetchArrowcloud calls back into here when it lands.
	if f.mode ~= "keyboard" then
		local ac = state.arrowcloud
		if ac.status == "idle" then
			FetchArrowcloud()
			if state.arrowcloud.status == "loading" then return end
		elseif ac.status == "loading" then
			return
		end
		-- the release dates decide the window, and every candidate is judged
		-- the moment it is reached, so they have to be here first
		if ac.newStatus == "idle" then
			FetchArrowcloudNew()
			if state.arrowcloud.newStatus == "loading" then return end
		elseif ac.newStatus == "loading" then
			return
		end
		-- and the catalogue is what separates a release from a simfile dump
		if not state.packTypes or not state.smoByName then
			FetchPackTypes()
			return
		end
		if not f.poolReady then FeaturedPoolFromRanking(f) end
	end

	while f.inFlight < 8 and f.poolPos < #f.pool
	      and #f.cards < (f.mode == "keyboard" and FEAT.TARGET or FEAT.BUILD)
	      and f.fetched < FEAT.MAX_DETAILS do
		f.poolPos = f.poolPos + 1
		local pack = f.pool[f.poolPos]
		local cached = state.details[pack.id]
		if f.mode ~= "keyboard" then
			-- judged from the row, decided on the spot, no request at all
			local score = FeaturedQuality(pack, nil)
			if score then FeaturedAccept(f, pack, score, false) end
		elseif cached then
			FeaturedConsider(pack, cached)
		else
			f.inFlight = f.inFlight + 1
			f.fetched = f.fetched + 1
			FetchDetail(pack, function(det)
				-- a filter change replaces state.featured; anything still in flight
				-- from the old build must not land in the new one
				if state.featured ~= f then return end
				f.inFlight = f.inFlight - 1
				if f.status == "loading" then
					if det then FeaturedConsider(pack, det) end
					FeaturedResolve()
				end
				Refresh()
			end)
		end
	end

	local exhausted = (#f.cards >= (f.mode == "keyboard" and FEAT.TARGET or FEAT.BUILD))
	                  or (f.poolReady and f.poolPos >= #f.pool)
	                  or (f.fetched >= FEAT.MAX_DETAILS)
	if f.inFlight == 0 and #f.pending == 0 and exhausted then
		FeaturedFinalize()
	end
end

local function BuildFeatured()
	local f = {
		status = "loading", cards = {}, pool = {}, poolPos = 0, poolReady = false,
		pending = {}, fallback = {}, inFlight = 0, fetched = 0,
		seen = {}, carded = {},   -- pack ids already pooled / already shown
		tier = 1,                 -- 1 = ranked only, 2 = quality top-up
		mode = state.filterMode, builtAt = GetTimeSinceStart(),
		cutoff = MonthsAgoStr(FEAT.PAD_MONTHS),
	}
	state.featured = f
	state.featCursor = 1
	state.featWindow = 0

	-- the keyboard tab is a plain list; there is nothing to build for it
	if state.filterMode == "keyboard" or not UrlAllowed() then
		f.status = "ready"
		return
	end

	-- both of these are shared across rebuilds; start them now and let the
	-- verdicts land whenever they finish
	FetchArrowcloud()
	FetchArrowcloudNew()
	FetchPackTypes()      -- the name join needs the catalogue

	-- The pool is arrowcloud's ranking joined to SMO's catalogue, and neither
	-- has landed yet; FeaturedStep builds it once both are in.
	FeaturedStep()
	Refresh()
end

-- rebuild list + featured after the pad/keyboard filter changes.
-- quiet=true keeps the current toast/cursor noise down (CSV just arrived).
ApplyFilterRefetch = function(quiet)
	state.page = 1
	state.cursor = 1
	state.pageOffsets = {}
	-- a filter change means a different result set; drop any search or year view
	state.localRows = nil
	state.search = ""
	state.viewYear = nil
	FetchPacks(1)
	BuildFeatured()
	if not quiet then
		Toast(FilterLabels[state.filterMode] or "")
	end
	Refresh()
end

local function StartDownload(pack)
	if state.downloads[pack.id] and state.downloads[pack.id].status ~= "error" then
		return
	end

	local uuid = "dl"
	if CRYPTMAN and CRYPTMAN.GenerateRandomUUID then
		uuid = CRYPTMAN:GenerateRandomUUID()
	else
		uuid = tostring(math.floor(GetTimeSinceStart()*1000))
	end
	local zipfile = "smo_" .. uuid .. ".zip"

	local before = {}
	for dir in ivalues(FILEMAN:GetDirListing("/Songs/", true, false)) do
		before[dir] = true
	end

	local dl = { status="active", cur=0, total=pack.bytes or 0, name=pack.name }
	state.downloads[pack.id] = dl
	-- queue order, so the header strip does not reshuffle itself every frame
	local queued = false
	for id in ivalues(state.dlOrder) do
		if id == pack.id then queued = true end
	end
	if not queued then state.dlOrder[#state.dlOrder+1] = pack.id end

	dl.request = NETWORK:HttpRequest{
		url = SMO_BASE .. "/download/pack/" .. pack.id .. "/",
		downloadFile = zipfile,
		connectTimeout = 15,
		onProgress = function(current, total)
			dl.cur = current or 0
			if total and total > 0 then dl.total = total end
		end,
		onResponse = function(response)
			dl.request = nil
			if response.error ~= nil then
				if ToEnumShortString(response.error) == "Cancelled" then
					state.downloads[pack.id] = nil
					return
				end
				dl.status = "error"
				dl.msg = response.errorMessage or "network error"
				Refresh()
				return
			end
			if response.statusCode ~= 200 then
				dl.status = "error"
				dl.msg = "HTTP " .. tostring(response.statusCode)
				Refresh()
				return
			end
			local contentType = ""
			if response.headers then
				contentType = response.headers["Content-Type"] or response.headers["content-type"] or ""
			end
			if not contentType:find("zip") then
				dl.status = "error"
				dl.msg = "server did not return a zip"
				Refresh()
				return
			end

			-- Unzip runs synchronously; the game will hitch for a moment on
			-- large packs.  This must happen inside onResponse because the
			-- engine deletes the downloaded file when this callback returns.
			dl.status = "installing"
			if FILEMAN:Unzip("/Downloads/" .. zipfile, "/Songs/", 0) then
				local groups = {}
				for dir in ivalues(FILEMAN:GetDirListing("/Songs/", true, false)) do
					if not before[dir] then groups[#groups+1] = dir end
				end
				dl.status = "done"
				dl.finishedAt = GetTimeSinceStart()
				dl.groups = groups
				state.needsReload = true
				-- what its age was, for the assumed-sync pass below
				if pack.date and pack.date ~= "" then
					state.autoSync[NormalizeName(pack.name)] = pack.date
				end
				-- the unzip will have littered the new pack with empty probe
				-- files; clear them before anybody looks in the folder
				CheckHelper()
				TidyProbeFiles()
				if not state.open then
					SCREENMAN:SystemMessage("Pack installed: " .. pack.name .. " (reload songs to play)")
				end
			else
				dl.status = "error"
				dl.msg = "unzip failed"
			end
			Refresh()
		end,
	}
end

-- true once a completed download's new group is actually loaded in SONGMAN
-- (i.e. a song reload has happened since it was installed)
local function DownloadLoaded(dl)
	if not (dl and dl.groups) then return false end
	for group in ivalues(dl.groups) do
		if SONGMAN:DoesSongGroupExist(group) then return true end
	end
	return false
end

local function DownloadsActive()
	for _, dl in pairs(state.downloads) do
		if dl.status == "active" or dl.status == "installing" then return true end
	end
	return false
end

-- ---------------------------------------------------------------
-- Network access
--
-- ITGmania does not let a theme reach the internet unless the host is on
-- its allowlist, and a theme cannot put it there itself: HttpEnabled and
-- HttpAllowHosts are PreferenceType::Immutable, and Preferences.ini is
-- passed to FILEMAN->ProtectPath().  The installer sets this up, so
-- normally the check below just passes.  If it does not, the browser shows
-- a short warning telling the player how to fix it -- it never prompts for
-- permission and never tries to change the setting behind their back.

local function HttpIsEnabled()
	local value = PREFSMAN:GetPreference("HttpEnabled")
	return value == true or value == 1
end

-- Why the browser cannot go online, or nil when it can.
local function NetworkBlockedReason()
	if UrlAllowed() then return nil end
	if not HttpIsEnabled() then
		return "HttpEnabled is turned off in Save/Preferences.ini."
	end
	return "stepmaniaonline.net is not in HttpAllowHosts in Save/Preferences.ini."
end

-- -----------------------------------------------------------------------
-- browser input

local function LeaveBrowser(destination)
	-- put the credits back where the rest of the theme expects them
	if refs.root then LiftAboveSystemLayer(refs.root, false) end
	Snd.Stop(true)
	state.open = false
	SetRedirect(false)
	SCREENMAN:SetNewScreen(destination or "ScreenTitleMenu")
end

-- called (from the watcher poll, or defensively from BrowserInput) once the
-- ScreenTextEntry search prompt has closed and our screen is on top again
local function ReclaimInputAfterTextEntry()
	if not state.textEntryOpen then return end
	state.textEntryOpen = false
	SetRedirect(true)
	if state.pendingSearch ~= nil then
		state.search = state.pendingSearch
		state.pendingSearch = nil
		state.cursor = 1
		state.page = 1
		state.pageOffsets = {}
		state.zone = "list"  -- search results live in the list
		RunSearch(state.search)
	end
	Refresh()
end

local function OpenSearchPrompt()
	state.pendingSearch = nil  -- a prompt session only commits its own OnOK
	state.textEntryOpen = true
	Refresh()  -- hides the browser UI so ScreenTextEntry is visible
	-- note: input redirection is per screen-stack entry, so the pushed
	-- ScreenTextEntry receives input normally while our screen stays blocked
	SCREENMAN:AddNewScreenToTop("ScreenTextEntry")
	SCREENMAN:GetTopScreen():Load({
		Question = "Search by pack name, chart author or song\n(leave empty to browse newest packs)",
		InitialAnswer = state.search or "",
		MaxInputLength = 64,
		OnOK = function(answer)
			state.pendingSearch = answer or ""
		end,
	})
	-- watch for the text entry closing (OK or cancel)
	if refs.watcher then refs.watcher:queuecommand("SMOWatchTextEntry") end
end

local BrowserInput = function(event)
	if not (event and event.type and event.GameButton) then return false end
	if not state.open then return false end
	if state.textEntryOpen then
		-- safety net: if the watcher chain ever got lost, reclaim here
		local top = SCREENMAN:GetTopScreen()
		if top and top:GetName() == BROWSER_SCREEN then
			ReclaimInputAfterTextEntry()
		end
		return false
	end
	if event.type == "InputEventType_Release" then return false end

	local button = event.GameButton
	local firstPress = (event.type == "InputEventType_FirstPress")

	-- restart the download-progress heartbeat on any input, just in case
	if refs.heart then refs.heart:playcommand("SMOArmHeartbeat") end

	if state.mode == "blocked" then
		-- network access is not set up; this screen only explains the fix
		if (button == "Back" or button == "Start") and firstPress then
			PlaySfx("cancel")
			LeaveBrowser("ScreenTitleMenu")
		end
		return false
	end

	if state.mode == "list" or state.mode == "installed" or state.mode == "year"
	   or InLevelView() then
		local isUp    = (button == "MenuUp" or button == "Up")
		local isDown  = (button == "MenuDown" or button == "Down")
		local isLeft  = (button == "MenuLeft" or button == "Left")
		local isRight = (button == "MenuRight" or button == "Right")
		local feat = state.featured

		-- shared handlers
		if button == "Select" and firstPress then
			-- the sync screen: an explainer everywhere, and on an installed
			-- pack the one place a Pack.ini can be written
			PlaySfx("start")
			state.syncFrom = state.mode
			state.syncPack = InInstalledView() and InstalledPack() or nil
			state.syncChoice = "NULL"
			state.syncNote = nil
			state.mode = "sync"
			Refresh()
			return false
		elseif button == "Back" and firstPress then
			PlaySfx("cancel")
			-- don't offer the song reload while a download is still running;
			-- it would race the unzip and lose track of the new pack
			if state.needsReload and not DownloadsActive() then
				state.mode = "reload"
				Refresh()
			else
				if DownloadsActive() then
					SCREENMAN:SystemMessage("Pack download continues in the background")
				end
				LeaveBrowser("ScreenTitleMenu")
			end
			return false
		end

		if state.zone == "tabs" then
			-- Left/Right cycles the pad/keyboard filter and applies it
			if (isLeft or isRight) and firstPress then
				local index = state.tabIndex + (isRight and 1 or -1)
				if index < 1 then index = #TabOrder end
				if index > #TabOrder then index = 1 end
				state.tabIndex = index
				PlaySfx("change")
				local choice = TabOrder[index]
				if choice == "installed" then
					EnterInstalled()
					state.zone = "tabs"
					Refresh()
				elseif choice == "year" then
					EnterYearView()
					state.zone = "tabs"
					Refresh()
				elseif choice == "tech" or choice == "stamina"
				       or choice == "beginner" then
					EnterLevelView(choice)
					state.zone = "tabs"
					Refresh()
				elseif choice == "search" then
					-- only focuses; Start opens the prompt.  Cycling past a tab
					-- must not pop a keyboard up.
					Refresh()
				else
					state.mode = "list"
					state.filterMode = choice
					FetchPackTypes()
					ApplyFilterRefetch()
				end
			elseif button == "Start" and firstPress and TabOrder[state.tabIndex] == "search" then
				PlaySfx("start")
				OpenSearchPrompt()
			elseif isDown or (button == "Start" and firstPress) then
				PlaySfx("change")
				if state.mode == "installed" then
					state.zone = (#state.installed.packs > 0) and "list" or "tabs"
				elseif state.mode == "year" then
					state.zone = "years"
				elseif state.mode == "list" and state.search == ""
				       and (#feat.cards > 0 or feat.status == "loading") then
					state.zone = "featured"
				else
					state.zone = "list"
				end
				Refresh()
			end
			return false
		end

		if state.mode == "installed" then
			local inst = state.installed
			local perCol = INST_ROWS / INST_COLS
			local slot   = inst.cursor - inst.window          -- 1 .. INST_ROWS
			local col    = math.floor((slot - 1) / perCol)
			local row    = (slot - 1) % perCol
			local page   = math.floor(inst.window / INST_ROWS)

			-- move to an absolute (page, column, row); false when nothing is
			-- there, which is what makes the edges of the grid feel solid
			local function goTo(p, c, r)
				if p < 0 or c < 0 or c >= INST_COLS then return false end
				if r < 0 or r >= perCol then return false end
				local index = p * INST_ROWS + c * perCol + r + 1
				if index < 1 or index > #inst.packs then return false end
				inst.window = p * INST_ROWS
				inst.cursor = index
				return true
			end

			if isUp then
				-- up the column, carrying back a page at its top
				if goTo(page, col, row - 1) or goTo(page - 1, col, perCol - 1) then
					PlaySfx("change")
				else
					PlaySfx("change")
					state.zone = "tabs"
				end
				Refresh()
			elseif isDown then
				-- down the column, carrying to the next page at its bottom
				if goTo(page, col, row + 1) or goTo(page + 1, col, 0) then
					PlaySfx("change")
				else
					PlaySfx("invalid")
				end
				Refresh()
			elseif isLeft then
				if goTo(page, col - 1, row) or goTo(page - 1, INST_COLS - 1, row) then
					PlaySfx("change")
				else
					PlaySfx("invalid")
				end
				Refresh()
			elseif isRight then
				if goTo(page, col + 1, row) or goTo(page + 1, 0, row) then
					PlaySfx("change")
				else
					PlaySfx("invalid")
				end
				Refresh()
			elseif button == "Start" and firstPress then
				local pack = InstalledPack()
				if not pack or state.removing then
					PlaySfx("invalid")
				elseif state.helper.status ~= "ready" then
					PlaySfx("invalid")
					CheckHelper(true)
					Toast(state.helper.reason or "pack removal is unavailable")
				else
					PlaySfx("start")
					state.mode = "removeconfirm"
					Refresh()
				end
			end
			return false
		end

		if state.zone == "years" then
			local years = YearList()
			if isLeft or isRight then
				local want = state.yearCursor + (isRight and 1 or -1)
				if want >= 1 and want <= #years then
					state.yearCursor = want
					PlaySfx("change")
					SelectYear(years[want])
				else
					PlaySfx("invalid")
				end
			elseif isUp then
				PlaySfx("change")
				state.tabIndex = ActiveTabIndex()
				state.zone = "tabs"
				Refresh()
			elseif isDown or (button == "Start" and firstPress) then
				PlaySfx("change")
				state.zone = "list"
				Refresh()
			end
			return false
		end

		if state.zone == "featured" then
			local page, row, col = FEAT.Page(), FEAT.RowCol()
			if isLeft then
				-- along the row, carrying back a page at the left edge
				local moved = (col > 0 and FEAT.Goto(page, row, col - 1))
					or (col == 0 and FEAT.Goto(page - 1, row, FEAT.COLS - 1))
				if moved then
					PlaySfx("change")
					Refresh()
				else
					PlaySfx("invalid")
				end
			elseif isRight then
				local moved = (col < FEAT.COLS - 1 and FEAT.Goto(page, row, col + 1))
					or (col == FEAT.COLS - 1 and FEAT.Goto(page + 1, row, 0))
				if moved then
					PlaySfx("change")
					Refresh()
				else
					PlaySfx("invalid")
				end
			elseif isUp then
				-- up a row inside the grid, else out to the tabs
				if FEAT.Goto(page, row - 1, col) then
					PlaySfx("change")
					Refresh()
				else
					PlaySfx("change")
					state.tabIndex = ActiveTabIndex()
					state.zone = "tabs"
					Refresh()
				end
			elseif isDown then
				-- down a row inside the grid, else on into the list
				if FEAT.Goto(page, row + 1, col) then
					PlaySfx("change")
					Refresh()
				else
					PlaySfx("change")
					state.zone = "list"
					Refresh()
				end
			elseif button == "Start" and firstPress then
				local pack = CurrentPack()
				if pack then
					PlaySfx("start")
					state.selected = pack
					state.returnMode = state.mode
					state.mode = "detail"
					state.songCursor = 0
					state.songPick = 1
					state.detailFailed[pack.id] = nil
					FetchDetail(pack, nil, true)
					Refresh()
				else
					PlaySfx("invalid")
				end
			end
			return false
		end

		-- zone == "list"
		-- A page request is still out. Swallow navigation until it lands, so a
		-- fast scroll cannot queue up page changes or leave the cursor pointing
		-- into a page that is about to be replaced.
		if state.fetchReq and (isUp or isDown or isLeft or isRight) then
			return false
		end

		if isUp then
			if state.cursor > 1 then
				state.cursor = state.cursor - 1
				PlaySfx("change")
				Refresh()
			elseif state.page > 1 then
				-- still list above: page back rather than leaving it. Holding
				-- Up walks the whole list to its top before the featured grid
				-- takes the cursor.
				PlaySfx("change")
				state.cursor = ROWS
				FetchPacks(state.page - 1, true)
			else
				-- top of the list: move up into whatever strip is above it
				PlaySfx("change")
				if state.mode == "year" then
					state.zone = "years"
				elseif state.mode == "list" and state.search == ""
				       and (#feat.cards > 0 or feat.status == "loading") then
					state.zone = "featured"
				else
					state.tabIndex = ActiveTabIndex()
					state.zone = "tabs"
				end
				Refresh()
			end
		elseif isDown then
			if #state.packs > 0 then
				if state.cursor < #state.packs then
					state.cursor = state.cursor + 1
				elseif state.page < TotalPages() then
					state.cursor = 1
					FetchPacks(state.page + 1, true)
				elseif InLevelView() and LEVEL.Extend() then
					-- end of what has been gathered: go and get more
				else
					state.cursor = 1
				end
				PlaySfx("change")
				Refresh()
			end
		elseif isLeft then
			if state.page > 1 then
				PlaySfx("change")
				state.cursor = 1
				FetchPacks(state.page - 1, true)
			elseif state.localRows then
				-- a search or year page has nothing to re-fetch
				PlaySfx("invalid")
			else
				-- already on page 1: treat as a manual refresh
				PlaySfx("change")
				FetchPacks(1, true)
				Toast("Refreshing...")
			end
		elseif isRight then
			if state.page < TotalPages() then
				PlaySfx("change")
				state.cursor = 1
				FetchPacks(state.page + 1, true)
			elseif InLevelView() and LEVEL.Extend() then
				-- end of what has been gathered: go and get more
				PlaySfx("change")
				Refresh()
			else
				PlaySfx("invalid")
			end
		elseif button == "Start" and firstPress then
			local pack = CurrentPack()
			if pack then
				PlaySfx("start")
				state.selected = pack
				state.returnMode = state.mode
				state.mode = "detail"
				state.songCursor = 0
				state.songPick = 1
				state.detailFailed[pack.id] = nil
				FetchDetail(pack, nil, true)
				Refresh()
			else
				PlaySfx("invalid")
			end
		end
		return false
	end

	if state.mode == "detail" then
		local pack = CurrentPack()
		local det = pack and state.details[pack.id]
		local numSongs = det and #det.songs or 0
		local maxScroll = math.max(0, numSongs - SONG_ROWS)

		-- The highlight moves and the window follows it, rather than the window
		-- dragging songs through fixed rows. Two things fall out of that: a
		-- highlighted song is something "play this one" can refer to, and a
		-- move that stays inside the visible window rebinds no rows at all, so
		-- most presses cost nothing in texture loads.
		local function MovePick(delta)
			if numSongs == 0 then return end
			local want = Clamp(state.songPick + delta, 1, numSongs)
			if want == state.songPick then return end
			state.songPick = want
			if want <= state.songCursor then
				state.songCursor = want - 1
			elseif want > state.songCursor + SONG_ROWS then
				state.songCursor = want - SONG_ROWS
			end
			state.songCursor = Clamp(state.songCursor, 0, maxScroll)
			PlaySfx("change")
			Refresh()
		end

		if button == "MenuUp" or button == "Up" then
			MovePick(-1)
		elseif button == "MenuDown" or button == "Down" then
			MovePick(1)
		elseif button == "MenuLeft" or button == "Left" then
			MovePick(-SONG_ROWS)
		elseif button == "MenuRight" or button == "Right" then
			MovePick(SONG_ROWS)
		elseif button == "Select" and firstPress then
			if Snd.Busy() then
				PlaySfx("cancel")
				Snd.Stop()
			else
				-- hear the song rather than read about it
				Snd.Play(pack, det and det.songs[state.songPick] or nil)
			end
		elseif button == "Start" and firstPress then
			if Snd.Busy() then
				PlaySfx("cancel")
				Snd.Stop()
			elseif pack then
				PlaySfx("start")
				state.chooseIdx = 1
				state.mode = "confirm"
				Refresh()
			else
				PlaySfx("invalid")
			end
		elseif button == "Back" and firstPress then
			PlaySfx("cancel")
			Snd.Stop(true)
			-- back to whichever list opened this pack, not always the plain one
			state.mode = state.returnMode or "list"
			state.returnMode = nil
			state.selected = nil
			Refresh()
		end
		return false
	end

	if state.mode == "removeconfirm" then
		if button == "Start" and firstPress then
			local pack = InstalledPack()
			PlaySfx("start")
			state.mode = "installed"
			Refresh()
			if pack then
				Toast("Removing " .. pack.name .. "...")
				DeletePack(pack, function(ok, why)
					if ok then
						-- the files are gone but SONGMAN still holds the group, so
						-- offer the same song reload a download does
						state.needsReload = true
						Toast("Removed " .. pack.name)
					else
						Toast("Could not remove " .. pack.name .. ": " .. tostring(why))
					end
					ScanInstalled()
					Refresh()
				end)
			end
		elseif button == "Back" and firstPress then
			PlaySfx("cancel")
			state.mode = "installed"
			Refresh()
		end
		return false
	end

	if state.mode == "confirm" then
		local pack = CurrentPack()
		local det = pack and state.details[pack.id]
		local song = det and det.songs[state.songPick] or nil

		if (button == "MenuLeft" or button == "Left"
		    or button == "MenuRight" or button == "Right") and firstPress then
			state.chooseIdx = (state.chooseIdx == 1) and 2 or 1
			PlaySfx("change")
			Refresh()
		elseif button == "Start" and firstPress then
			if state.chooseIdx == 1 then
				-- close the dialog first: the sample reports its own progress
				-- into the screen behind it
				state.mode = "detail"
				Refresh()
				Snd.Play(pack, song)
			else
				local dl = pack and state.downloads[pack.id]
				if dl and (dl.status == "active" or dl.status == "installing") then
					PlaySfx("invalid")
					Toast("Already downloading - watch the queue up in the corner")
				elseif dl and dl.status == "done" then
					PlaySfx("invalid")
					Toast(DownloadLoaded(dl) and "Already installed"
						or "Already installed - reload songs to play it")
				elseif pack then
					PlaySfx("start")
					StartDownload(pack)
					-- say plainly that leaving does not cancel it, because the
					-- queue in the corner is the only thing that says otherwise
					Toast("Downloading " .. pack.name
						.. " - keep browsing, you can start others too")
					if refs.heart then refs.heart:playcommand("SMOArmHeartbeat") end
				end
				state.mode = "detail"
				Refresh()
			end
		elseif button == "Back" and firstPress then
			PlaySfx("cancel")
			state.mode = "detail"
			Refresh()
		end
		return false
	end

	if state.mode == "sync" then
		local pack = state.syncPack
		local canWrite = (pack ~= nil) and (pack.sync == nil) and (pack.dir ~= nil)
		if (button == "MenuLeft" or button == "Left"
		    or button == "MenuRight" or button == "Right") and firstPress then
			if canWrite then
				state.syncChoice = (state.syncChoice == "NULL") and "ITG" or "NULL"
				PlaySfx("change")
			else
				PlaySfx("invalid")
			end
			Refresh()
		elseif button == "Start" and firstPress then
			if canWrite then
				local ok, why = Sync.Write(pack.dir, state.syncChoice)
				if ok then
					PlaySfx("start")
					state.syncNote = "Wrote Pack.ini with SyncOffset=" .. state.syncChoice
						.. ". Restart the game, or do a full song reload, for it to apply."
					ScanInstalled()
					state.syncPack = InstalledPack()
				else
					PlaySfx("invalid")
					state.syncNote = "Not written: " .. tostring(why)
				end
			else
				PlaySfx("cancel")
				state.mode = state.syncFrom or "list"
			end
			Refresh()
		elseif button == "Back" and firstPress then
			PlaySfx("cancel")
			state.mode = state.syncFrom or "list"
			state.syncPack = nil
			state.syncNote = nil
			Refresh()
		end
		return false
	end

	if state.mode == "reload" then
		if button == "Start" and firstPress then
			PlaySfx("start")
			state.needsReload = false
			state.reloadForUs = true
			LeaveBrowser("ScreenReloadSongsSSM")
		elseif button == "Back" and firstPress then
			PlaySfx("cancel")
			LeaveBrowser("ScreenTitleMenu")
		end
		return false
	end

	return false
end

-- -----------------------------------------------------------------------
-- title menu integration
--
-- The engine's title menu scroller is STATIC in Simply Love
-- (ScrollerSecondsPerItem=0, so items never slide; the highlight moves
-- through fixed rows at ScrollerY + 22*index).  Our item occupies the fixed
-- row below the last native choice.  Simply Love draws its "EVENT MODE" /
-- credit text at the very bottom, so we nudge the whole native menu up a few
-- pixels to make room for the extra row.

local titleFocused = false
local titleLeaving = false    -- a choice was activated; ignore input until the screen changes
local titleLastIndex = 0
local titleWatchIndex = -1
local titleWatchFocused = nil
local titleNumChoices = 4
local TITLE = {
	MENU_SHIFT  = 10,   -- pixels to raise the native menu block
	SPACING     = 22,   -- row pitch, matching the theme's own metric
	INSERT_SLOT = 3,    -- the row our entry takes, ahead of Exit
	ROWS        = 5,
}

local function TitleMenuBaseY()
	-- mirrors the theme metric: ScrollerY=_screen.cy+_screen.h/3.8
	return _screen.cy + _screen.h/3.8 - TITLE.MENU_SHIFT
end

local function TitleItemY()
	return TitleMenuBaseY() + TITLE.SPACING*TITLE.INSERT_SLOT
end

-- rows are 1-based; TITLE.ROWS is the four native choices plus ours

local function TitleRowY(row)
	return TitleMenuBaseY() + TITLE.SPACING*(row-1)
end

-- the engine choice a row stands for, or nil for our own row
local function TitleRowEngineIndex(row)
	local slot = row - 1
	if slot == TITLE.INSERT_SLOT then return nil end
	if slot < TITLE.INSERT_SLOT then return slot end
	return slot - 1
end

-- The label the theme would have drawn.  Simply Love puts it in the choice
-- metric ("screen,ScreenExit;text,Exit") and may translate it, so read the
-- metric and run the result through the screen's string table.
local titleLabelCache = {}

local function TitleChoiceLabel(index)
	if titleLabelCache[index] then return titleLabelCache[index] end
	local label
	local ok, metric = pcall(function()
		return THEME:GetMetric("ScreenTitleMenu", "Choice" .. (index+1))
	end)
	if ok and type(metric) == "string" then
		label = metric:match("text%s*,%s*([^;]+)")
	end
	if label then
		label = Trim(label)
		local okStr, translated = pcall(function()
			return THEME:GetString("ScreenTitleMenu", label)
		end)
		if okStr and type(translated) == "string" and translated ~= "" then
			label = translated
		end
	end
	label = label or ("Choice " .. (index+1))
	titleLabelCache[index] = label
	return label
end

local titleChoiceNames = {"1", "2", "3", "4"}

local function TitleGetEngineIndex()
	local screen = SCREENMAN:GetTopScreen()
	if not screen or not screen.GetSelectionIndex then return 0 end
	local ok, index = pcall(function() return screen:GetSelectionIndex(PLAYER_1) end)
	if ok and type(index) == "number" then return index end
	return 0
end

-- play GainFocus/LoseFocus on one of the engine's scroller choices (0-based
-- index) so the native entry visually loses focus while ours has it
local function TitleSetEngineChoiceFocus(index, hasFocus)
	local screen = SCREENMAN:GetTopScreen()
	if not screen then return end
	local scroller = screen:GetChild("Scroller")
	if not scroller then return end
	local name = titleChoiceNames[index+1]
	if not name then return end
	local choice = scroller:GetChild("ScrollChoice" .. name)
	if not choice then return end
	choice:playcommand(hasFocus and "GainFocus" or "LoseFocus")
end

-- The theme's scroller transform sets each choice's y every frame, so the
-- native rows cannot be repositioned.  They are hidden instead and every row
-- is drawn by this module, which is what allows a row for "Find Content"
-- above Exit and a pitch wider than the theme's 22px.
local function TitleLayoutChoices()
	local screen = SCREENMAN:GetTopScreen()
	if not screen or screen:GetName() ~= "ScreenTitleMenu" then return end
	local scroller = screen:GetChild("Scroller")
	if not scroller then return end
	for index = 0, titleNumChoices - 1 do
		local name = titleChoiceNames[index+1]
		local choice = name and scroller:GetChild("ScrollChoice" .. name)
		if choice then
			pcall(function() choice:visible(false) end)
		end
	end
end

-- refocusEngine=false leaves the native highlight alone (used when we let
-- the engine process the same event and move/wrap the selection itself)
local function TitleDefocus(refocusEngine)
	if not titleFocused then return end
	titleFocused = false
	if refocusEngine then
		TitleSetEngineChoiceFocus(TitleGetEngineIndex(), true)
	end
	MESSAGEMAN:Broadcast("SMOTitleRefresh")
end

local function TitleFocus()
	if titleFocused then return end
	titleFocused = true
	TitleSetEngineChoiceFocus(TitleGetEngineIndex(), false)
	if refs.titleItem then refs.titleItem:diffusealpha(1) end
	MESSAGEMAN:Broadcast("SMOTitleRefresh")
end

-- -----------------------------------------------------------------------
-- Title input, attached to the ScreenSystemLayer overlay screen.
--
-- Overlay screens receive input BEFORE the top screen, and a Lua callback
-- that returns true consumes the event entirely (ScreenManager::Input).
-- That lets our extra menu item participate in the title menu's wrap cycle
-- (WrapCursor=true): pressing forward on the last native choice, or backward
-- on the first, lands on "Find Content" instead of wrapping straight past
-- it; leaving our item in either direction hands the event back (or not) so
-- the engine's own selection always ends up on the right native choice.

local TitleOverlayInput = function(event)
	local screen = SCREENMAN:GetTopScreen()
	if not screen or screen:GetName() ~= "ScreenTitleMenu" then
		titleFocused = false
		return false
	end
	-- a choice was activated and the screen is tweening out; stay inert so a
	-- button mash can't hijack the pending transition
	if titleLeaving then return false end
	if not (event and event.type and event.GameButton) then return false end
	if event.type == "InputEventType_Release" then return false end

	local button = event.GameButton
	local firstPress = (event.type == "InputEventType_FirstPress")

	-- Simply Love's title menu navigates with MenuLeft/MenuRight on dance
	-- setups and MenuUp/MenuDown elsewhere.  Keyboard/pad Up/Down arrive as
	-- the raw "Up"/"Down" game buttons (which the engine's title menu
	-- ignores), so accept those for our item too.
	local isMenuNav  = (button == "MenuDown" or button == "MenuRight" or
	                    button == "MenuUp"   or button == "MenuLeft")
	local isForward  = (button == "MenuDown" or button == "MenuRight" or button == "Down")
	local isBackward = (button == "MenuUp"   or button == "MenuLeft"  or button == "Up")

	-- this runs BEFORE the engine sees the event, so this is the pre-move
	-- selection index
	local engineIndex = TitleGetEngineIndex()
	-- our row sits between these two native choices
	local above = TITLE.INSERT_SLOT - 1
	local below = TITLE.INSERT_SLOT

	-- the engine keeps re-running its own layout; put the rows back
	TitleLayoutChoices()

	if not titleFocused then
		if isForward and engineIndex == above then
			-- stepping down off the choice above ours
			PlaySfx("titlechange")
			TitleFocus()
			return true
		elseif isBackward and engineIndex == below then
			-- stepping up off the choice below ours
			PlaySfx("titlechange")
			TitleFocus()
			return true
		elseif button == "Start" and firstPress then
			-- a native choice was activated; fade our item out with the rest
			-- and go inert until the screen changes
			titleLeaving = true
			if refs.titleItem then refs.titleItem:playcommand("SMOTitleLeave") end
		end
		return false
	end

	-- our item is focused
	if button == "Start" and firstPress then
		PlaySfx("start")
		titleFocused = false
		titleLeaving = true
		state.open = true  -- flag intent before the screen switch
		if refs.titleItem then refs.titleItem:playcommand("SMOTitleLeave") end
		SCREENMAN:SetNewScreen(BROWSER_SCREEN)
		return true
	elseif button == "Back" and firstPress then
		PlaySfx("titlechange")
		TitleDefocus(true)
		return true
	elseif isForward then
		if engineIndex == above then
			if isMenuNav then
				-- let the engine step down onto the choice below ours
				TitleDefocus(false)
				return false
			end
			-- raw arrow only: the engine would not move, so stay put and let the
			-- event through so the screen's idle timer still resets
			return false
		else
			PlaySfx("titlechange")
			TitleDefocus(true)
			return true
		end
	elseif isBackward then
		if engineIndex == below then
			if isMenuNav then
				-- let the engine step up onto the choice above ours
				TitleDefocus(false)
				return false
			end
			return false
		else
			PlaySfx("titlechange")
			TitleDefocus(true)
			return true
		end
	elseif button == "Coin" or button == "Operator" then
		return false
	end

	-- anything else (Select etc.) has no effect on this screen; pass it
	-- through so the engine's idle timer resets
	return false
end

-- register the overlay callback once, on the ScreenSystemLayer screen that
-- our module actors live inside (found by walking up the actor tree)
local titleOverlayHooked = false
local function HookTitleOverlayInput(actor)
	if titleOverlayHooked then return true end
	local node = actor
	for _ = 1, 30 do
		local parent = node:GetParent()
		if not parent then break end
		node = parent
	end
	if node and node.AddInputCallback then
		node:AddInputCallback(TitleOverlayInput)
		titleOverlayHooked = true
		return true
	end
	return false
end

-- Fallback for the (unexpected) case where the overlay hook isn't available:
-- watch the selection from a callback on the title screen itself.  This runs
-- AFTER the engine processed the event, so a forward press on the last
-- choice has already wrapped the selection to 0 by the time we see it.
local TitleFallbackInput = function(event)
	if titleLeaving then return false end
	if not (event and event.type and event.GameButton) then return false end
	if event.type == "InputEventType_Release" then return false end

	local screen = SCREENMAN:GetTopScreen()
	if not screen or screen:GetName() ~= "ScreenTitleMenu" then return false end

	local button = event.GameButton
	local firstPress = (event.type == "InputEventType_FirstPress")
	local isForward  = (button == "MenuDown" or button == "MenuRight")
	local isBackward = (button == "MenuUp"   or button == "MenuLeft")

	if titleFocused then
		if isBackward or isForward or (button == "Back" and firstPress) then
			PlaySfx("titlechange")
			SetRedirect(false)
			TitleDefocus(true)
		elseif button == "Start" and firstPress then
			PlaySfx("start")
			titleFocused = false
			titleLeaving = true
			SetRedirect(false)
			state.open = true
			if refs.titleItem then refs.titleItem:playcommand("SMOTitleLeave") end
			SCREENMAN:SetNewScreen(BROWSER_SCREEN)
		end
		return false
	end

	if isForward or isBackward then
		local current = TitleGetEngineIndex()
		-- detect a wrap in either direction: jumping between the ends means
		-- the selection passed our item's slot
		-- our row is between these two, so the engine skipping straight across
		-- them is what tells us the cursor passed through it
		local steppedDown = isForward  and titleLastIndex == TITLE.INSERT_SLOT-1
		                    and current == TITLE.INSERT_SLOT
		local steppedUp   = isBackward and titleLastIndex == TITLE.INSERT_SLOT
		                    and current == TITLE.INSERT_SLOT-1
		if steppedDown or steppedUp then
			PlaySfx("titlechange")
			TitleFocus()
			SetRedirect(true)
		end
		titleLastIndex = TitleGetEngineIndex()
	elseif button == "Start" and firstPress then
		titleLeaving = true
		if refs.titleItem then refs.titleItem:playcommand("SMOTitleLeave") end
	end
	return false
end

-- -----------------------------------------------------------------------
-- layout constants for the browser

-- One table rather than twenty-one locals: Lua 5.1 caps a function at 60
-- upvalues, and the browser actor tree reads every one of these.
local LO = {}

LO.W  = _screen.w
LO.H  = _screen.h
LO.CONTENT_TOP = 44
LO.CONTENT_BOT = 440
LO.LIST_X      = 16
LO.LIST_W      = math.floor(LO.W * 0.53)
LO.ROW_H       = 36
LO.DL_ROWS     = 3                              -- queue rows before the rest become a count
LO.DIALOG_W    = 400
LO.DIALOG_H    = 170

-- vertical stack: filter tabs / featured grid / list columns.  There is no
-- sub-header band any more -- the active tab already says what you are looking
-- at, and the row it used to occupy is worth more as list space.
LO.TABS_Y      = 48                             -- just under the screen header
LO.TABS_RULE_Y = LO.TABS_Y + 12                 -- active-tab underline
LO.FEAT_LABEL_Y = 72                            -- 12px under the tab underline
LO.FEAT_TOP    = 80                             -- top of the featured cards
LO.FEAT_CARD_H = 47                             -- a banner's shape, near enough
LO.FEAT_GAP    = 4
LO.FEAT_ROW_GAP = 4
LO.FEAT_CARD_W = math.floor((LO.W - 2*LO.LIST_X - (FEAT.COLS-1)*LO.FEAT_GAP) / FEAT.COLS)
-- two rows of shorter cards fit in the band one row of tall ones used to
LO.FEAT_RULE_Y = LO.FEAT_TOP + FEAT.ROWS*LO.FEAT_CARD_H
                 + (FEAT.ROWS-1)*LO.FEAT_ROW_GAP + 3
LO.LIST_TOP    = 186                            -- list top with the featured grid up
LO.LIST_TOP_TIGHT = 148                         -- and without it: the band and the
                                                -- year chips both end by y=139
LO.PANE_X      = LO.LIST_X + LO.LIST_W + 12
LO.PANE_W      = LO.W - LO.PANE_X - 16
LO.SCROLL_W    = 4
-- where this module was installed, for checking that its icons came with it
LO.MODULE_DIR = ((THEME and THEME.GetCurrentThemeDirectory)
	and THEME:GetCurrentThemeDirectory() or "Themes/Simply Love/") .. "Modules/"                              -- scroll-indicator thickness

-- Is the featured grid on screen?  Everything that reserves the band and
-- everything that starts below it asks this one question, so the grid and the
-- list top can never disagree.  "confirm" is a dialog drawn over whichever
-- list opened it, so it borrows that view's answer instead of claiming to be
-- a plain pack list -- otherwise the rows would jump behind the dialog.
function LO.GridShowing()
	if state.filterMode == "keyboard" then return false end
	return state.search == "" and state.mode == "list"
end

-- The detail view is on screen for its own mode and behind the popup that mode
-- opens. It lives on LO because everything that asks is inside BrowserActor,
-- which has no room left for another upvalue of its own.
function LO.DetailShowing()
	return state.mode == "detail" or state.mode == "confirm"
end

-- True while a view is still assembling its own rows, as opposed to waiting on
-- a server page. The body shows placeholders rather than claiming to be empty.
function LO.ListBuilding()
	if InLevelView() then
		return state.level ~= nil and state.level.status == "loading"
	end
	if InYearView() then
		return state.recentIndex ~= nil and state.recentIndex.status == "loading"
	end
	if state.search ~= "" then return state.loading == true end
	return false
end

-- where the pack list and its info pane start, for the view on screen now
function LO.ListTop()
	if LO.GridShowing() then return LO.LIST_TOP end
	return LO.LIST_TOP_TIGHT
end

-- the pane keeps its bottom edge pinned, so it grows when the list moves up
function LO.PaneH()
	return LO.CONTENT_BOT - LO.ListTop() - 6
end

local function ScrollBar(x, y, length, horizontal, fn)
	local function Geometry()
		local total, visible, offset = fn()
		if not (total and visible) or total <= visible then return nil end
		local thumb = math.max(14, math.floor(length * (visible / total)))
		local span  = length - thumb
		local pos   = 0
		if total > visible then
			pos = math.floor(span * (Clamp(offset or 0, 0, total - visible) / (total - visible)) + 0.5)
		end
		return thumb, Clamp(pos, 0, span)
	end

	local af = Def.ActorFrame{
		InitCommand = function(self)
			self:xy(x, type(y) == "function" and y() or y):visible(false)
		end,
		SMORefreshMessageCommand = function(self)
			if type(y) == "function" then self:y(y()) end
			self:visible(state.open and not state.textEntryOpen and Geometry() ~= nil)
		end,
	}

	-- track
	af[#af+1] = Def.Quad{
		InitCommand = function(self)
			self:vertalign(top):horizalign(left)
			if horizontal then
				self:setsize(length, LO.SCROLL_W)
			else
				self:setsize(LO.SCROLL_W, length)
			end
			self:diffuse(1, 1, 1, 0.10)
		end,
	}

	-- thumb
	af[#af+1] = Def.Quad{
		InitCommand = function(self) self:vertalign(top):horizalign(left) end,
		SMORefreshMessageCommand = function(self)
			local thumb, pos = Geometry()
			if not thumb then return end
			if horizontal then
				self:xy(pos, 0):setsize(thumb, LO.SCROLL_W)
			else
				self:xy(0, pos):setsize(LO.SCROLL_W, thumb)
			end
			self:diffuse(AccentColor())
		end,
	}

	return af
end

-- A spinner that matches the rest of Simply Love: 30 frames over one second,
-- tinted with the player colour. visibleFn decides when it shows.
local function Spinner(x, y, scale, visibleFn)
	local function at() return type(y) == "function" and y() or y end
	return Def.Sprite{
		Texture = THEME:GetPathG("", "LoadingSpinner 10x3.png"),
		Frames  = Sprite.LinearFrames(30, 1),
		InitCommand = function(self)
			self:xy(x, at()):zoom(scale):visible(false)
			self:diffuse(AccentColor())
		end,
		SMORefreshMessageCommand = function(self)
			self:y(at())
			self:visible(state.open and visibleFn() and true or false)
			self:diffuse(AccentColor())
		end,
		SMOBannerReadyMessageCommand = function(self)
			self:visible(state.open and visibleFn() and true or false)
		end,
	}
end

-- true while a pack banner is still on its way in
local function BannerPending(pack)
	if not pack then return false end
	local url = BannerUrlFor(pack)
	if not url then return state.detailBusy[pack.id] == true end
	return state.banners[url] == nil
end

-- scale + position a sprite inside a box, preserving aspect ratio
local function FitSprite(sprite, maxw, maxh)
	local w = sprite:GetWidth()
	local h = sprite:GetHeight()
	if w > 0 and h > 0 then
		sprite:zoom(math.min(maxw/w, maxh/h))
	end
end

-- -----------------------------------------------------------------------
-- browser actor tree

local function BrowserActor()
	local af = Def.ActorFrame{
		Name = "SMOFindContentBrowser",

		ModuleCommand = function(self)
			refs.root = self
			LiftAboveSystemLayer(self, true)
			state.open = true
			state.textEntryOpen = false
			state.blockedReason = nil
			state.selected = nil
			state.zone = "list"
			-- stale UI state from a previous visit must not linger
			state.loadErr = nil
			state.loading = false
			-- a search or year slice belongs to the visit that made it; keeping it
			-- would show those rows under whichever tab happens to be active
			state.localRows = nil
			state.viewYear = nil
			state.search = ""
			-- converge any search term left by an interrupted text entry
			if state.pendingSearch ~= nil then
				state.search = state.pendingSearch
				state.pendingSearch = nil
				state.lastFetch = nil  -- force the refetch below
			end
			state.blockedReason = NetworkBlockedReason()
			state.mode = state.blockedReason and "blocked" or "list"
			if state.mode == "list" then
				FetchPackTypes()
				local stale = (state.lastFetch == nil) or (GetTimeSinceStart() - state.lastFetch > REFRESH_SECS)
				if stale or #state.packs == 0 then
					state.page = 1
					state.pageOffsets = {}
					FetchPacks(1, false)
				end
				local feat = state.featured
				local featStale = (feat.builtAt == nil) or (GetTimeSinceStart() - feat.builtAt > REFRESH_SECS)
				if feat.status == "idle" or feat.mode ~= state.filterMode or featStale then
					BuildFeatured()
				end
				-- the featured grid is where the eye should land first
				if #state.featured.cards > 0 or state.featured.status == "loading" then
					state.zone = "featured"
				end
			end

			MESSAGEMAN:Broadcast("SetHeaderText", {Text="Find Content"})

			local screen = SCREENMAN:GetTopScreen()
			if screen then
				-- make sure any engine-driven transition returns to the title
				screen:SetPrevScreenName("ScreenTitleMenu")
				screen:SetNextScreenName("ScreenTitleMenu")
				screen:AddInputCallback(BrowserInput)
			end
			SetRedirect(true)

			self:playcommand("SMOArmHeartbeat")
			Refresh()
		end,
	}

	-- ---------------------------------------------------------------
	-- invisible helper: the song sample player
	af[#af+1] = Def.Sound{
		InitCommand = function(self) Snd.actor = self end,
	}

	-- ---------------------------------------------------------------
	-- invisible helper: heartbeat for download progress updates
	af[#af+1] = Def.Actor{
		InitCommand = function(self) refs.heart = self end,

		SMOArmHeartbeatCommand = function(self)
			self:stoptweening()
			self:queuecommand("SMOHeartbeat")
		end,
		SMOHeartbeatCommand = function(self)
			if state.open and DownloadsActive() then
				Refresh()
				self:sleep(0.2):queuecommand("SMOHeartbeat")
			end
		end,
	}

	-- invisible helper: watches for ScreenTextEntry closing (its own actor,
	-- so nothing else can stoptweening() its polling chain away)
	af[#af+1] = Def.Actor{
		InitCommand = function(self) refs.watcher = self end,

		SMOWatchTextEntryCommand = function(self)
			if not state.textEntryOpen then return end
			local top = SCREENMAN:GetTopScreen()
			if top and top:GetName() == BROWSER_SCREEN then
				ReclaimInputAfterTextEntry()
			else
				self:sleep(0.1):queuecommand("SMOWatchTextEntry")
			end
		end,
	}

	-- ---------------------------------------------------------------
	-- main browser container (everything that hides while typing a search)
	local ui = Def.ActorFrame{
		Name = "UI",
		InitCommand = function(self) refs.ui = self end,
		SMORefreshMessageCommand = function(self)
			self:visible(state.open and not state.textEntryOpen)
		end,
	}

	-- dim the SL background a touch for readability
	ui[#ui+1] = Def.Quad{
		InitCommand = function(self)
			self:vertalign(top):horizalign(left)
			self:setsize(LO.W, LO.H):diffuse(0,0,0,0.66)
		end,
	}

	-- Opaque band over the strip ScreenSystemLayer uses for the credits
	-- ("PRESS START" at each side, "EVENT MODE" in the middle).  They are not
	-- ours to hide, so they get covered instead.
	ui[#ui+1] = Def.Quad{
		InitCommand = function(self)
			self:vertalign(bottom):horizalign(left)
			self:xy(0, LO.H):setsize(LO.W, LO.H - LO.CONTENT_BOT):diffuse(0, 0, 0, 1)
		end,
	}

	-- Where the content comes from, stated once and quietly, instead of a
	-- full-width header row repeating it.
	ui[#ui+1] = Def.BitmapText{
		Font = "Common Normal",
		Text = "pack data from stepmaniaonline.net",
		InitCommand = function(self)
			self:horizalign(right):xy(LO.W - 8, LO.CONTENT_BOT + 30):zoom(0.38)
			self:diffuse(0.55, 0.55, 0.55, 0.75)
		end,
		SMORefreshMessageCommand = function(self)
			self:visible(state.open and not state.textEntryOpen)
		end,
	}

	-- ---------------------------------------------------------------
	-- the download queue, top right.
	--
	-- Downloads outlive the screen that started them, so this is the only place
	-- they can be seen from once the player has moved on -- and the only thing
	-- that makes starting a second one feel deliberate rather than lost.
	for qi = 1, LO.DL_ROWS do
		local QY = 16 + (qi - 1) * 15

		ui[#ui+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(right):xy(LO.W - 118, QY):zoom(0.42)
				self:maxwidth(150/0.42):visible(false)
			end,
			SMORefreshMessageCommand = function(self)
				local dl = state.dlRows[qi]
				self:visible(state.open and not state.textEntryOpen and dl ~= nil)
				if not dl then return end
				self:settext(dl.name or "")
				if dl.status == "error" then
					self:diffuse(1, 0.45, 0.45, 1)
				elseif dl.status == "done" then
					self:diffuse(0.6, 0.6, 0.6, 1)
				else
					self:diffuse(0.88, 0.88, 0.88, 1)
				end
			end,
		}

		ui[#ui+1] = Def.Quad{
			InitCommand = function(self)
				self:horizalign(left):xy(LO.W - 112, QY):setsize(64, 5)
				self:diffuse(1, 1, 1, 0.16):visible(false)
			end,
			SMORefreshMessageCommand = function(self)
				local dl = state.dlRows[qi]
				self:visible(state.open and not state.textEntryOpen and dl ~= nil)
			end,
		}
		ui[#ui+1] = Def.Quad{
			InitCommand = function(self)
				self:horizalign(left):xy(LO.W - 112, QY):setsize(1, 5):visible(false)
			end,
			SMORefreshMessageCommand = function(self)
				local dl = state.dlRows[qi]
				self:visible(state.open and not state.textEntryOpen and dl ~= nil)
				if not dl then return end
				local frac = dl.frac
				if dl.status == "error" then
					self:diffuse(1, 0.35, 0.35, 1)
					self:setsize(64, 5)
				else
					self:diffuse(AccentColor())
					-- unpacking has no measure; it fills the bar and waits
					self:setsize(math.max(1, 64 * ((frac and frac >= 0) and frac or 1)), 5)
					if frac and frac < 0 then self:diffusealpha(0.5) end
				end
			end,
		}

		ui[#ui+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(right):xy(LO.W - 12, QY):zoom(0.4)
				self:maxwidth(40/0.4):visible(false)
			end,
			SMORefreshMessageCommand = function(self)
				local dl = state.dlRows[qi]
				self:visible(state.open and not state.textEntryOpen and dl ~= nil)
				if not dl then return end
				self:settext(dl.label)
				if dl.status == "error" then
					self:diffuse(1, 0.45, 0.45, 1)
				else
					self:diffuse(0.75, 0.75, 0.75, 1)
				end
			end,
		}
	end

	-- and what did not fit
	ui[#ui+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(right):xy(LO.W - 12, 16 + LO.DL_ROWS * 15):zoom(0.38)
			self:diffuse(0.6, 0.6, 0.6, 1):visible(false)
		end,
		SMORefreshMessageCommand = function(self)
			local extra = #state.dlRows - LO.DL_ROWS
			self:visible(state.open and not state.textEntryOpen and extra > 0)
			if extra > 0 then
				self:settext("+" .. extra .. " more downloading")
			end
		end,
	}

	-- loading spinner for the very first fetch (the list is empty behind it)
	ui[#ui+1] = Spinner(LO.W/2, LO.H/2, 0.3, function()
		return state.loading and state.mode == "list" and #state.packs == 0
	end)

	-- Where the rows run out with more still to find. It sits directly under
	-- the last row rather than at a fixed height, so it reads as the end of
	-- the list instead of as furniture.
	ui[#ui+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(LO.LIST_X + LO.LIST_W/2, 0):zoom(0.5):visible(false)
		end,
		SMORefreshMessageCommand = function(self)
			local lv = state.level
			local show = InLevelView() and lv ~= nil and lv.more
				and state.page >= TotalPages() and #state.packs > 0
			self:visible(show)
			if not show then return end
			self:y(LO.ListTop() + #state.packs * LO.ROW_H + 9)
			self:settext("&MENUDOWN; more")
			self:diffuse(AccentColor())
		end,
	}

	-- error / empty-state text
	ui[#ui+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(LO.LIST_X + LO.LIST_W/2, LO.H/2):zoom(0.7):diffuse(0.8, 0.8, 0.8, 1)
			self:wrapwidthpixels(LO.LIST_W / 0.7)
		end,
		SMORefreshMessageCommand = function(self)
			if not InPackList() then self:settext("") return end
			-- only overlay the error text when there is nothing else to show;
			-- transient errors over a working list surface as a toast instead
			if state.loadErr and #state.packs == 0 then
				self:settext("Could not reach stepmaniaonline.net\n(" .. tostring(state.loadErr) .. ")\n\nPress &MENULEFT; to retry")
			elseif (not state.loading) and not LO.ListBuilding()
			       and #state.packs == 0 and state.lastFetch then
				self:settext("No packs found")
			else
				self:settext("")
			end
		end,
	}

	-- ---------------------------------------------------------------
	-- filter tabs (pad / keyboard) and the view tabs

	-- eight tabs now, so the labels lose their filler words; the row sits on
	-- its own line above the readout, so the pitch only has to fit the labels
	local tabDefs = {
		{ view = "search",    label = "SEARCH" },
		{ mode = "pad",       label = "PAD" },
		{ mode = "keyboard",  label = "KEYBOARD" },
		{ view = "beginner",  label = "BEGINNER" },
		{ view = "tech",      label = "ALL AROUND" },
		{ view = "stamina",   label = "STAMINA" },
		{ view = "year",      label = "YEARS" },
		{ view = "installed", label = "INSTALLED" },
	}

	local tabsAF = Def.ActorFrame{
		Name = "Tabs",
		InitCommand = function(self) self:visible(false) end,
		SMORefreshMessageCommand = function(self)
			self:visible(state.open and BrowsingModes[state.mode] == true)
		end,
	}

	for tabIndex, tab in ipairs(tabDefs) do
		local tabX = LO.LIST_X + (tabIndex-1) * 76

		-- the icon sits in front of the label, so the label starts further in
		-- A Texture path is resolved relative to the directory the module was
		-- loaded from, so it is given relative even though the existence check
		-- needs it spelled out from the theme root.
		local iconName = "ContentBrowserIcons/" .. (tab.view or tab.mode) .. ".png"
		if FILEMAN:DoesFileExist(LO.MODULE_DIR .. iconName) then
			tabsAF[#tabsAF+1] = Def.Sprite{
				Texture = iconName,
				InitCommand = function(self)
					-- drawn at 96px, shown at 13
					self:xy(tabX + 7, LO.TABS_Y):zoom(13/96)
				end,
				SMORefreshMessageCommand = function(self)
					if TabIsActive(tab) then
						self:diffuse(AccentColor())
						self:diffusealpha(state.zone == "tabs" and 1 or 0.85)
					else
						self:diffuse(0.45, 0.45, 0.45, 1)
					end
				end,
			}
		end

		tabsAF[#tabsAF+1] = Def.BitmapText{
			Font = "Common Normal",
			Text = tab.label,
			InitCommand = function(self)
				self:horizalign(left):xy(tabX + 16, LO.TABS_Y):zoom(0.5)
				self:maxwidth(56/0.5)
			end,
			SMORefreshMessageCommand = function(self)
				if TabIsActive(tab) then
					self:diffuse(AccentColor())
					self:zoom(state.zone == "tabs" and 0.56 or 0.5)
				else
					self:diffuse(0.45, 0.45, 0.45, 1)
					self:zoom(0.5)
				end
			end,
		}

		-- underline for the active tab
		tabsAF[#tabsAF+1] = Def.Quad{
			InitCommand = function(self)
				self:horizalign(left):xy(tabX, LO.TABS_RULE_Y):setsize(62, 2):visible(false)
			end,
			SMORefreshMessageCommand = function(self)
				if TabIsActive(tab) then
					self:visible(true)
					self:diffuse(AccentColor())
					self:diffusealpha(state.zone == "tabs" and 1 or 0.5)
				else
					self:visible(false)
				end
			end,
		}
	end

	-- a page is on its way; navigation is paused until it lands
	tabsAF[#tabsAF+1] = Spinner(LO.W - LO.LIST_X - 4, LO.FEAT_LABEL_Y, 0.12, function()
		-- state.mode rather than InYearView(): naming that function in here
		-- would spend one of BrowserActor's last upvalue slots
		if state.mode == "year" and state.recentIndex.status == "loading" then return true end
		return state.fetchReq ~= nil and InPackList()
	end)

	-- position readout, in the slot the sub-header used to own
	tabsAF[#tabsAF+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(right):xy(LO.W - LO.LIST_X - 16, LO.FEAT_LABEL_Y):zoom(0.5)
			self:diffuse(0.62, 0.62, 0.62, 1)
		end,
		SMORefreshMessageCommand = function(self)
			if InInstalledView() then
				self:settext(string.format("%d installed", #state.installed.packs))
			elseif InYearView() then
				-- which page of a year you are on is not interesting; how far
				-- the index has got is, because that is what you are waiting on
				local idx = state.recentIndex
				if idx.status == "loading" then
					self:settext(idx.year and ("indexing " .. idx.year) or "indexing...")
				else
					self:settext(Commify(#(state.localRows or {})) .. " packs")
				end
			elseif state.search ~= "" then
				self:settext(string.format("%s%s results for \"%s\"",
					Commify(state.filtered), state.searchCapped and "+" or "", state.search))
			elseif #state.packs == 0 then
				self:settext("")
			elseif InLevelView() then
				local lv = state.level
				if state.mode == "beginner" then
					self:settext("")
				else
					self:settext("Page " .. Commify(state.page) .. "/" .. Commify(TotalPages())
						.. "   -   " .. Commify(state.filtered)
						.. ((lv and lv.more) and "+" or "") .. " packs")
				end
			else
				self:settext(Commify(state.filtered) .. " packs")
			end
		end,
	}

	ui[#ui+1] = tabsAF

	-- ---------------------------------------------------------------
	-- featured grid

	local featAF = Def.ActorFrame{
		Name = "Featured",
		InitCommand = function(self) self:visible(false) end,
		SMORefreshMessageCommand = function(self)
			-- a search replaces the strip with its own results, and the level and
			-- year views have their own band
			self:visible(state.open and LO.GridShowing())
		end,
	}

	featAF[#featAF+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(left):xy(LO.LIST_X, LO.FEAT_LABEL_Y):zoom(0.55)
		end,
		SMORefreshMessageCommand = function(self)
			local f = state.featured
			-- name the filter the strip was built for, so switching tabs visibly
			-- changes what is on offer
			local mode = f.mode or state.filterMode
			local scope = FeaturedScopeLabels[mode] or ""
			local window = (mode == "keyboard")
				and string.format("LAST %d YEARS", FEAT.KB_YEARS)
				or  "MOST PLAYED"
			local label = "FEATURED " .. scope .. window
			local ac = state.arrowcloud.status
			if ac == "blocked" or ac == "failed" then
				label = label .. "   (arrowcloud unavailable)"
			end
			if f.status == "loading" and #f.cards == 0 then
				label = label .. "   finding packs..."
			elseif f.status == "ready" and #f.cards == 0 then
				label = label .. "   nothing qualifying right now"
			elseif FEAT.Count() > FEAT.VISIBLE then
				label = label .. string.format("   %d/%d", state.featCursor, FEAT.Count())
			end
			self:settext(label)
			self:diffuse(AccentColor())
		end,
	}

	for slot = 1, FEAT.VISIBLE do
		local col = (slot - 1) % FEAT.COLS
		local row = math.floor((slot - 1) / FEAT.COLS)
		local cardX = LO.LIST_X + col * (LO.FEAT_CARD_W + LO.FEAT_GAP)
		local cardY = LO.FEAT_TOP + row * (LO.FEAT_CARD_H + LO.FEAT_ROW_GAP)

		local function CardAt()
			local index = state.featWindow + slot
			if index > FEAT.TARGET then return nil end   -- surplus stays hidden
			return state.featured.cards[index]
		end
		local function CardFocused()
			return state.zone == "featured"
				and (state.featWindow + slot) == state.featCursor
		end
		-- the size the banner is actually drawn at, so everything else can hug it.
		-- Falls back to the whole card while the image is still on its way, which
		-- is what the empty placeholder wants anyway.
		local function CardArtSize()
			local card = CardAt()
			local pack = card and card.pack
			local url  = pack and BannerUrlFor(pack)
			local aspect = url and state.bannerAspect[url]
			if not aspect or aspect <= 0 then
				return LO.FEAT_CARD_W, LO.FEAT_CARD_H
			end
			if aspect >= LO.FEAT_CARD_W / LO.FEAT_CARD_H then
				return LO.FEAT_CARD_W, LO.FEAT_CARD_W / aspect
			end
			return LO.FEAT_CARD_H * aspect, LO.FEAT_CARD_H
		end

		local card = Def.ActorFrame{
			InitCommand = function(self) self:xy(cardX, cardY) end,

			-- focus ring, behind everything so it reads as a rim
			Def.Quad{
				InitCommand = function(self)
					self:xy(LO.FEAT_CARD_W/2, LO.FEAT_CARD_H/2):visible(false)
				end,
				SMORefreshMessageCommand = function(self)
					self:visible(CardFocused() and CardAt() ~= nil)
					local w, h = CardArtSize()
					self:setsize(w + 4, h + 4)
					self:diffuse(AccentColor())
				end,
			},

			-- the card itself: a vertical gradient rather than a flat panel, so
			-- the art has something to sit on that is not just background
			Def.Quad{
				InitCommand = function(self)
					self:xy(LO.FEAT_CARD_W/2, LO.FEAT_CARD_H/2)
				end,
				SMORefreshMessageCommand = function(self)
					local card = CardAt()
					local pending = (card == nil)
						and state.featured.status == "loading"
						and (state.featWindow + slot) <= FEAT.TARGET
					self:visible(card ~= nil or pending)
					self:setsize(CardArtSize())
					if not card then
						self:diffusetopedge(color("#26262CF0"))
						self:diffusebottomedge(color("#131318F0"))
						return
					end
					local accent = AccentColor()
					if CardFocused() then
						self:diffusetopedge({accent[1]*0.85, accent[2]*0.85, accent[3]*0.85, 1})
						self:diffusebottomedge({accent[1]*0.22, accent[2]*0.22, accent[3]*0.22, 1})
					else
						self:diffusetopedge({accent[1]*0.40, accent[2]*0.40, accent[3]*0.40, 1})
						self:diffusebottomedge({accent[1]*0.07, accent[2]*0.07, accent[3]*0.07, 1})
					end
				end,
			},

			-- pack art, given as much of the card as it can take
			Def.Sprite{
				InitCommand = function(self)
					self:xy(LO.FEAT_CARD_W/2, LO.FEAT_CARD_H/2)
				end,
				SMORefreshMessageCommand = function(self) self:playcommand("SMOSetBanner") end,
				SMOBannerReadyMessageCommand = function(self) self:playcommand("SMOSetBanner") end,
				SMOSetBannerCommand = function(self)
					local card = CardAt()
					local pack = card and card.pack
					local url = pack and BannerUrlFor(pack)
					local path = url and state.banners[url]
					local key = "feat" .. slot
					if pack and path then
						if loadedBanner[key] ~= path then
							self:Load(path)
							loadedBanner[key] = path
						end
						MeasureBanner(self, url)
						FitSprite(self, LO.FEAT_CARD_W, LO.FEAT_CARD_H)
						self:visible(true)
					else
						self:visible(false)
						if url then RequestBanner(url) end
					end
				end,
			},

			-- spinner while this slot is still being filled in
			Spinner(LO.FEAT_CARD_W/2, LO.FEAT_CARD_H/2, 0.12, function()
				local index = state.featWindow + slot
				local card = state.featured.cards[index]
				if state.mode ~= "list" and state.mode ~= "confirm" then return false end
				if state.search ~= "" then return false end
				if card then return BannerPending(card.pack) end
				return state.featured.status == "loading" and index <= FEAT.TARGET
			end),

			-- a wash of the accent colour over the art while it is highlighted,
			-- strongest at the top so the card still reads bottom-lit
			Def.Quad{
				InitCommand = function(self)
					self:xy(LO.FEAT_CARD_W/2, LO.FEAT_CARD_H/2):visible(false)
				end,
				SMORefreshMessageCommand = function(self)
					if not (CardFocused() and CardAt()) then
						self:visible(false)
						return
					end
					local accent = AccentColor()
					self:visible(true)
					self:setsize(CardArtSize())
					self:diffusetopedge({accent[1], accent[2], accent[3], 0.42})
					self:diffusebottomedge({accent[1], accent[2], accent[3], 0.06})
				end,
			},
		}

		featAF[#featAF+1] = card
	end

	ui[#ui+1] = featAF

	-- position dots for the featured grid: one per page of cards
	for dot = 1, 8 do
		ui[#ui+1] = Def.Quad{
			InitCommand = function(self)
				self:setsize(5, 5):visible(false)
			end,
			SMORefreshMessageCommand = function(self)
				local cards = FEAT.Count()
				if not LO.GridShowing() then
					self:visible(false)
					return
				end
				local pages = math.ceil(cards / FEAT.VISIBLE)
				if state.search ~= "" or pages <= 1 or dot > pages then
					self:visible(false)
					return
				end
				local spacing = 11
				local x0 = LO.W/2 - ((pages - 1) * spacing) / 2
				self:visible(true)
				self:xy(x0 + (dot-1)*spacing, LO.FEAT_RULE_Y)
				if dot == FEAT.Page() + 1 then
					self:diffuse(AccentColor()):diffusealpha(1):setsize(7, 5)
				else
					self:diffuse(1, 1, 1, 0.20):setsize(5, 5)
				end
			end,
		}
	end

	-- ---------------------------------------------------------------
	-- LIST VIEW: rows

	local listAF = Def.ActorFrame{
		Name = "List",
		SMORefreshMessageCommand = function(self)
			self:visible(state.open and InPackList())
		end,
	}

	for i = 1, ROWS do
		local function RowY() return LO.ListTop() + (i-1)*LO.ROW_H end

		local row = Def.ActorFrame{
			InitCommand = function(self)
				self:xy(LO.LIST_X, RowY())
				refs.rows[i] = self
			end,
			SMORefreshMessageCommand = function(self)
				self:y(RowY())
			end,

			-- focus background
			Def.Quad{
				InitCommand = function(self)
					self:vertalign(top):horizalign(left)
					self:setsize(LO.LIST_W, LO.ROW_H - 3)
				end,
				SMORefreshMessageCommand = function(self)
					local pack = state.packs[i]
					if not pack then self:visible(false) return end
					self:visible(true)
					if i == state.cursor then
						self:diffuse(1, 1, 1, state.zone == "list" and 0.16 or 0.09)
					else
						self:diffuse(1, 1, 1, 0.05)
					end
				end,
			},

			-- a row that has not been found yet: a dim bar where it will land,
			-- so a list that is still assembling reads as working rather than
			-- as empty
			Def.Quad{
				InitCommand = function(self)
					self:vertalign(top):horizalign(left)
					self:setsize(LO.LIST_W, LO.ROW_H - 3)
					self:diffuse(1, 1, 1, 0.045)
				end,
				SMORefreshMessageCommand = function(self)
					self:visible(state.packs[i] == nil and LO.ListBuilding())
				end,
			},
			Def.Quad{
				InitCommand = function(self)
					self:vertalign(top):horizalign(left)
					self:xy(76, 10):setsize(LO.LIST_W/3, 6)
					self:diffuse(1, 1, 1, 0.07)
				end,
				SMORefreshMessageCommand = function(self)
					self:visible(state.packs[i] == nil and LO.ListBuilding())
				end,
			},
			Def.Quad{
				InitCommand = function(self)
					self:vertalign(top):horizalign(left)
					self:xy(76, 22):setsize(LO.LIST_W/6, 4)
					self:diffuse(1, 1, 1, 0.05)
				end,
				SMORefreshMessageCommand = function(self)
					self:visible(state.packs[i] == nil and LO.ListBuilding())
				end,
			},

			-- while a row's art is still on its way, or the row itself has not
			-- arrived, something has to occupy the space
			Spinner(42, (LO.ROW_H-3)/2, 0.11, function()
				local pack = state.packs[i]
				if pack == nil then return LO.ListBuilding() end
				return BannerPending(pack)
			end),

			-- banner thumbnail
			Def.Sprite{
				InitCommand = function(self)
					self:xy(42, (LO.ROW_H-3)/2)
				end,
				SMORefreshMessageCommand = function(self) self:playcommand("SMOSetBanner") end,
				SMOBannerReadyMessageCommand = function(self) self:playcommand("SMOSetBanner") end,
				SMOSetBannerCommand = function(self)
					local pack = state.packs[i]
					local url = pack and BannerUrlFor(pack)
					local path = url and state.banners[url]
					local key = "row" .. i
					if pack and path then
						if loadedBanner[key] ~= path then
							self:Load(path)
							loadedBanner[key] = path
						end
						MeasureBanner(self, url)
						FitSprite(self, 76, LO.ROW_H - 9)
						self:visible(true)
					else
						self:visible(false)
						if url then
							RequestBanner(url)
						elseif pack and pack.csvOnly and state.open then
							FetchDetail(pack)
						end
					end
				end,
			},

			-- pack name
			Def.BitmapText{
				Font = "Common Normal",
				InitCommand = function(self)
					self:horizalign(left):xy(88, 11):zoom(0.72):maxwidth((LO.LIST_W - 176)/0.72)
				end,
				SMORefreshMessageCommand = function(self)
					local pack = state.packs[i]
					if not pack then self:settext("") return end
					self:settext(pack.name)
					if i == state.cursor then
						if state.zone == "list" then self:diffuse(AccentColor()) else self:diffuse(1,1,1,1) end
					else
						self:diffuse(1, 1, 1, 1)
					end
				end,
			},

			-- sub-line: songs / size / date / types
			Def.BitmapText{
				Font = "Common Normal",
				InitCommand = function(self)
					self:horizalign(left):xy(88, 25):zoom(0.5):diffuse(0.6, 0.6, 0.6, 1)
					self:maxwidth((LO.LIST_W - 176)/0.5)
				end,
				SMORefreshMessageCommand = function(self)
					local pack = state.packs[i]
					if not pack then self:settext("") return end
					local bits = {}
					if pack.songs > 0 then bits[#bits+1] = pack.songs .. " songs" end
					if pack.sizeStr ~= "" then bits[#bits+1] = pack.sizeStr end
					if pack.date ~= "" then bits[#bits+1] = "added " .. FormatDate(pack.date, true) end
					-- why a search result matched, when it was not the pack name
					if pack.why then bits[#bits+1] = pack.why end
					self:settext(table.concat(bits, "  -  "))
				end,
			},

			-- in a search, which tab the result belongs to; otherwise only the
			-- types the active tab does not already imply
			Def.BitmapText{
				Font = "Common Normal",
				InitCommand = function(self)
					self:horizalign(left):xy(LO.LIST_W - 84, (LO.ROW_H-3)/2):zoom(0.5)
					self:maxwidth(40/0.5)
				end,
				SMORefreshMessageCommand = function(self)
					local pack = state.packs[i]
					if not pack then self:settext("") return end
					local ptype = PackTypeOf(pack.id)
					if state.search ~= "" then
						-- results come from every tab at once, so each row says
						-- where it would otherwise have been found
						if ptype == "keyboard" then
							self:settext("KEY"):diffuse(0.55, 0.72, 1, 1)
						elseif ptype == "mixed" then
							self:settext("PAD+KEY"):diffuse(0.55, 0.72, 1, 1)
						elseif ptype == "ddr" then
							self:settext("DDR"):diffuse(1, 0.72, 0.35, 1)
						else
							self:settext("PAD"):diffuse(0.55, 0.55, 0.55, 1)
						end
					elseif ptype == "mixed" then
						self:settext("PAD+KEY"):diffuse(0.55, 0.72, 1, 1)
					elseif ptype == "ddr" then
						self:settext("DDR"):diffuse(1, 0.72, 0.35, 1)
					else
						self:settext("")
					end
				end,
			},

			-- right-aligned status badge
			Def.BitmapText{
				Font = "Common Normal",
				InitCommand = function(self)
					self:horizalign(right):xy(LO.LIST_W - 8, (LO.ROW_H-3)/2):zoom(0.5)
				end,
				SMORefreshMessageCommand = function(self)
					local pack = state.packs[i]
					if not pack then self:settext("") return end
					local dl = state.downloads[pack.id]
					if dl then
						if dl.status == "active" then
							local pct = 0
							if dl.total > 0 then pct = math.floor(dl.cur / dl.total * 100) end
							self:settext(pct .. "%")
							self:diffuse(AccentColor())
						elseif dl.status == "installing" then
							self:settext("Installing")
							self:diffuse(AccentColor())
						elseif dl.status == "done" then
							self:settext(DownloadLoaded(dl) and "In Library" or "Installed")
							self:diffuse(0.4, 1, 0.4, 1)
						else
							self:settext("Error")
							self:diffuse(1, 0.4, 0.4, 1)
						end
					elseif SONGMAN:DoesSongGroupExist(pack.name) then
						self:settext("In Library")
						self:diffuse(0.45, 0.8, 0.45, 1)
					else
						self:settext("")
					end
				end,
			},
		}

		listAF[#listAF+1] = row
	end

	-- ---------------------------------------------------------------
	-- LIST VIEW: right-hand info pane for the highlighted pack

	local pane = Def.ActorFrame{
		Name = "Pane",
		InitCommand = function(self) self:xy(LO.PANE_X, LO.ListTop()):visible(false) end,
		SMORefreshMessageCommand = function(self)
			self:y(LO.ListTop())
			self:visible(state.open and InPackList() and CurrentPack() ~= nil)
		end,
	}

	pane[#pane+1] = Def.Quad{
		InitCommand = function(self)
			self:vertalign(top):horizalign(left)
			self:setsize(LO.PANE_W, LO.PaneH()):diffuse(1, 1, 1, 0.07)
		end,
		SMORefreshMessageCommand = function(self)
			self:setsize(LO.PANE_W, LO.PaneH())
		end,
	}

	pane[#pane+1] = Def.Sprite{
		InitCommand = function(self) self:xy(LO.PANE_W/2, 38) end,
		SMORefreshMessageCommand = function(self) self:playcommand("SMOSetBanner") end,
		SMOBannerReadyMessageCommand = function(self) self:playcommand("SMOSetBanner") end,
		SMOSetBannerCommand = function(self)
			local pack = CurrentPack()
			local url = pack and BannerUrlFor(pack)
			local path = url and state.banners[url]
			if pack and path then
				if loadedBanner.pane ~= path then
					self:Load(path)
					loadedBanner.pane = path
				end
				MeasureBanner(self, url)
				FitSprite(self, LO.PANE_W - 40, 62)
				self:visible(true)
			else
				self:visible(false)
				if url then RequestBanner(url) end
			end
		end,
	}

	pane[#pane+1] = Spinner(LO.PANE_W/2, 38, 0.18, function()
		if not InPackList() then return false end
		return BannerPending(CurrentPack())
	end)

	pane[#pane+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(LO.PANE_W/2, 84):zoom(0.7):maxwidth((LO.PANE_W - 24)/0.7)
		end,
		SMORefreshMessageCommand = function(self)
			local pack = CurrentPack()
			self:settext(pack and pack.name or "")
			self:diffuse(1, 1, 1, 1)

			-- lazy-load details for the highlighted pack while browsing
			-- (only while the browser is actually open and in the list view)
			if pack and state.open and InPackList() then
				FetchDetail(pack)
			end
		end,
	}

	-- info lines under the name
	local infoLines = {
		function(pack, det)
			local songsText = tostring(pack.songs) .. " songs"
			if det and det.stats.charts then songsText = songsText .. "   -   " .. det.stats.charts .. " charts" end
			return songsText
		end,
		function(pack, det)
			local text = pack.sizeStr
			if det and det.stats.difficulty then text = text .. "   -   difficulty " .. det.stats.difficulty end
			return text
		end,
		function(pack, det)
			local date = FormatDate(pack.date)
			if date == "" and det then date = det.date or "" end
			return (date ~= "") and ("Added to SMO on " .. date) or ""
		end,
		function(pack, det)
			if det and det.author then return "charts by " .. det.author end
			if state.detailBusy[pack.id] then return "loading details..." end
			return ""
		end,
		function(pack, det)
			return Sync.Line(pack)
		end,
	}

	for lineIndex, textFn in ipairs(infoLines) do
		pane[#pane+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:xy(LO.PANE_W/2, 96 + lineIndex*13):zoom(0.5):diffuse(0.75, 0.75, 0.75, 1)
				self:maxwidth((LO.PANE_W - 24)/0.5)
			end,
			SMORefreshMessageCommand = function(self)
				local pack = CurrentPack()
				if not pack then self:settext("") return end
				self:settext(textFn(pack, state.details[pack.id]) or "")
			end,
		}
	end

	-- mini difficulty histogram (bars scale to the pane)
	local HIST_MAX_BARS = 30
	local HIST_H = 42
	local function HistY() return LO.PaneH() - 24 end  -- baseline, clear of the caption
	local HIST_W = LO.PANE_W - 48

	for barIndex = 1, HIST_MAX_BARS do
		pane[#pane+1] = Def.Quad{
			InitCommand = function(self)
				self:vertalign(bottom):visible(false)
				refs.bars[barIndex] = self
			end,
			SMORefreshMessageCommand = function(self)
				local pack = CurrentPack()
				local det = pack and state.details[pack.id]
				local visible = InPackList()
				if not (visible and det and #det.counts > 0 and barIndex <= #det.counts) then
					self:visible(false)
					return
				end
				local maxCount = 1
				for count in ivalues(det.counts) do maxCount = math.max(maxCount, count) end
				local barW = math.max(2, math.floor(HIST_W / #det.counts) - 2)
				local x0 = 24 + (HIST_W - (#det.counts * (barW + 2))) / 2
				self:visible(true)
				self:horizalign(left)
				self:xy(x0 + (barIndex-1)*(barW+2), HistY())
				self:setsize(barW, math.max(2, det.counts[barIndex] / maxCount * HIST_H))
				self:diffuse(MeterColor(det.labels[barIndex], 0.95))
			end,
		}
	end

	pane[#pane+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(LO.PANE_W/2, LO.PaneH() - 11):zoom(0.45):diffuse(0.6, 0.6, 0.6, 1)
		end,
		SMORefreshMessageCommand = function(self)
			self:y(LO.PaneH() - 11)
			local pack = CurrentPack()
			local det = pack and state.details[pack.id]
			if det and #det.labels > 0 then
				self:settext("charts per difficulty  (" .. det.labels[1] .. " - " .. det.labels[#det.labels] .. ")")
			else
				self:settext("")
			end
		end,
	}

	-- ---------------------------------------------------------------
	-- DETAIL VIEW

	local detail = Def.ActorFrame{
		Name = "Detail",
		InitCommand = function(self) self:visible(false) end,
		SMORefreshMessageCommand = function(self)
			self:visible(state.open and LO.DetailShowing())
		end,
	}

	local DET_LEFT_W = math.floor(LO.W * 0.38)
	local DET_SONGS_X = DET_LEFT_W + 32
	local DET_SONGS_W = LO.W - DET_SONGS_X - 20
	local SONG_ROW_H = 46
	local SONG_TOP = 66

	-- left column: banner + stats + histogram
	detail[#detail+1] = Def.Sprite{
		InitCommand = function(self) self:xy(16 + DET_LEFT_W/2, 105) end,
		SMORefreshMessageCommand = function(self) self:playcommand("SMOSetBanner") end,
		SMOBannerReadyMessageCommand = function(self) self:playcommand("SMOSetBanner") end,
		SMOSetBannerCommand = function(self)
			local pack = CurrentPack()
			local url = pack and BannerUrlFor(pack)
			local path = url and state.banners[url]
			if pack and path and LO.DetailShowing() then
				if loadedBanner.detail ~= path then
					self:Load(path)
					loadedBanner.detail = path
				end
				FitSprite(self, DET_LEFT_W - 20, 110)
				self:visible(true)
			else
				self:visible(false)
			end
		end,
	}

	detail[#detail+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(16 + DET_LEFT_W/2, 178):zoom(0.85):maxwidth((DET_LEFT_W - 16)/0.85)
		end,
		SMORefreshMessageCommand = function(self)
			local pack = CurrentPack()
			self:settext(pack and pack.name or "")
		end,
	}

	local detailLines = {
		function(pack, det)
			local text = tostring(pack.songs) .. " songs"
			if det and det.stats.charts then text = text .. "   -   " .. det.stats.charts .. " charts" end
			return text
		end,
		function(pack, det)
			local text = pack.sizeStr
			if det and det.stats.difficulty then text = text .. "   -   difficulty " .. det.stats.difficulty end
			return text
		end,
		function(pack, det)
			local date = FormatDate(pack.date)
			if date == "" and det then date = det.date or "" end
			return (date ~= "") and ("Added to SMO on " .. date) or ""
		end,
		function(pack, det)
			if det and det.author then return "charts by " .. det.author end
			if state.detailBusy[pack.id] then return "loading details..." end
			return ""
		end,
		function(pack, det)
			local dl = state.downloads[pack.id]
			if dl then
				if dl.status == "active" then
					local pct = 0
					if dl.total > 0 then pct = math.floor(dl.cur / dl.total * 100) end
					return "downloading  " .. pct .. "%   (" .. FormatBytes(dl.cur) .. " / " .. FormatBytes(dl.total) .. ")"
				elseif dl.status == "installing" then
					return "installing..."
				elseif dl.status == "done" then
					local text = "installed"
					if dl.groups and #dl.groups > 0 then text = text .. ": " .. table.concat(dl.groups, ", ") end
					if DownloadLoaded(dl) then return text .. "  (in your library)" end
					return text .. "  (reload songs to play)"
				else
					return "download failed: " .. tostring(dl.msg)
				end
			end
			if SONGMAN:DoesSongGroupExist(pack.name) then
				return "already in your library"
			end
			return ""
		end,
	}

	for lineIndex, textFn in ipairs(detailLines) do
		detail[#detail+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:xy(16 + DET_LEFT_W/2, 196 + lineIndex*17):zoom(0.55):diffuse(0.78, 0.78, 0.78, 1)
				self:maxwidth((DET_LEFT_W - 8)/0.55)
			end,
			SMORefreshMessageCommand = function(self)
				local pack = CurrentPack()
				if not pack then self:settext("") return end
				self:settext(textFn(pack, state.details[pack.id]) or "")
				if lineIndex == 5 then
					local dl = state.downloads[pack.id]
					if dl and dl.status == "error" then
						self:diffuse(1, 0.45, 0.45, 1)
					elseif dl and dl.status == "done" then
						self:diffuse(0.45, 1, 0.45, 1)
					else
						self:diffuse(0.78, 0.78, 0.78, 1)
					end
				end
			end,
		}
	end

	-- download progress bar
	detail[#detail+1] = Def.Quad{
		InitCommand = function(self)
			self:vertalign(top):horizalign(left)
			self:xy(28, 300):setsize(DET_LEFT_W - 24, 7):diffuse(1, 1, 1, 0.12)
		end,
		SMORefreshMessageCommand = function(self)
			local pack = CurrentPack()
			local dl = pack and state.downloads[pack.id]
			self:visible(dl ~= nil and (dl.status == "active" or dl.status == "installing"))
		end,
	}
	detail[#detail+1] = Def.Quad{
		InitCommand = function(self)
			self:vertalign(top):horizalign(left)
			self:xy(28, 300):setsize(0, 7)
		end,
		SMORefreshMessageCommand = function(self)
			local pack = CurrentPack()
			local dl = pack and state.downloads[pack.id]
			if dl and (dl.status == "active" or dl.status == "installing") then
				local fraction = 0
				if dl.status == "installing" then
					fraction = 1
				elseif dl.total > 0 then
					fraction = Clamp(dl.cur / dl.total, 0, 1)
				end
				self:visible(true)
				self:setsize((DET_LEFT_W - 24) * fraction, 7)
				self:diffuse(AccentColor())
			else
				self:visible(false)
			end
		end,
	}

	-- big histogram at the bottom of the left column
	local BHIST_H = 80
	local BHIST_Y = 420
	local BHIST_W = DET_LEFT_W - 24

	for barIndex = 1, HIST_MAX_BARS do
		detail[#detail+1] = Def.Quad{
			InitCommand = function(self) self:vertalign(bottom):visible(false) end,
			SMORefreshMessageCommand = function(self)
				local pack = CurrentPack()
				local det = pack and state.details[pack.id]
				if not (LO.DetailShowing() and det and #det.counts > 0 and barIndex <= #det.counts) then
					self:visible(false)
					return
				end
				local maxCount = 1
				for count in ivalues(det.counts) do maxCount = math.max(maxCount, count) end
				local barW = math.max(2, math.floor(BHIST_W / #det.counts) - 2)
				local x0 = 28 + (BHIST_W - (#det.counts * (barW + 2))) / 2
				self:visible(true)
				self:horizalign(left)
				self:xy(x0 + (barIndex-1)*(barW+2), BHIST_Y)
				self:setsize(barW, math.max(2, det.counts[barIndex] / maxCount * BHIST_H))
				self:diffuse(MeterColor(det.labels[barIndex], 0.95))
			end,
		}
	end

	-- colour chip + meter number beneath each bar
	for barIndex = 1, HIST_MAX_BARS do
		detail[#detail+1] = Def.Quad{
			InitCommand = function(self) self:vertalign(top):horizalign(left):visible(false) end,
			SMORefreshMessageCommand = function(self)
				local pack = CurrentPack()
				local det = pack and state.details[pack.id]
				if not (LO.DetailShowing() and det and #det.counts > 0 and barIndex <= #det.counts) then
					self:visible(false)
					return
				end
				local barW = math.max(2, math.floor(BHIST_W / #det.counts) - 2)
				local x0 = 28 + (BHIST_W - (#det.counts * (barW + 2))) / 2
				self:visible(true)
				self:xy(x0 + (barIndex-1)*(barW+2), BHIST_Y + 3):setsize(barW, 3)
				self:diffuse(MeterColor(det.labels[barIndex], 1))
			end,
		}

		detail[#detail+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self) self:zoom(0.34):visible(false) end,
			SMORefreshMessageCommand = function(self)
				local pack = CurrentPack()
				local det = pack and state.details[pack.id]
				if not (LO.DetailShowing() and det and #det.counts > 0 and barIndex <= #det.counts) then
					self:visible(false)
					return
				end
				local barW = math.max(2, math.floor(BHIST_W / #det.counts) - 2)
				-- below about 9px the numbers collide, so let the chips speak
				if barW < 9 then self:visible(false) return end
				local x0 = 28 + (BHIST_W - (#det.counts * (barW + 2))) / 2
				self:visible(true)
				self:xy(x0 + (barIndex-1)*(barW+2) + barW/2, BHIST_Y + 12)
				self:settext(tostring(det.labels[barIndex] or ""))
				self:diffuse(MeterColor(det.labels[barIndex], 1))
			end,
		}
	end

	detail[#detail+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(16 + DET_LEFT_W/2, BHIST_Y + 24):zoom(0.5):diffuse(0.6, 0.6, 0.6, 1)
		end,
		SMORefreshMessageCommand = function(self)
			local pack = CurrentPack()
			local det = pack and state.details[pack.id]
			if LO.DetailShowing() and det and #det.labels > 0 then
				self:settext("charts per difficulty  (" .. det.labels[1] .. " - " .. det.labels[#det.labels] .. ")")
			else
				self:settext("")
			end
		end,
	}

	-- right column: song list
	detail[#detail+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(left):xy(DET_SONGS_X, SONG_TOP - 14):zoom(0.6):diffuse(0.7, 0.7, 0.7, 1)
		end,
		SMORefreshMessageCommand = function(self)
			local pack = CurrentPack()
			local det = pack and state.details[pack.id]
			if det then
				-- the highlighted song rather than the visible range: the range
				-- stopped being the interesting number once one song was picked
				local at = Clamp(state.songPick, 1, math.max(1, #det.songs))
				local note = Snd.Label()
				self:settext("Songs  " .. at .. " of " .. #det.songs
					.. (note and ("   -   " .. note) or ""))
			elseif pack and state.detailBusy[pack.id] then
				self:settext("Loading song list...")
			elseif pack and state.detailFailed[pack.id] then
				self:settext("Could not load this pack's song list   -   "
					.. "&BACK; and open it again to retry")
			else
				self:settext("")
			end
		end,
	}

	-- ---------------------------------------------------------------
	-- the sample: an equalizer while it plays, a bar while it is fetched.
	--
	-- Both sit at the right-hand end of the song-list header, and both are
	-- driven by one actor ticking on its own rather than by the screen refresh.
	-- Refreshing the whole browser thirty times a second to move a dozen quads
	-- is exactly the cost this module keeps working to avoid.
	-- The bank sits to the left of the row's meter numbers, and the row it sits
	-- in is whichever one is highlighted -- so both of these are positioned by
	-- the pump every frame rather than pinned at build time.
	local EQ_SPAN  = Snd.BARS * (Snd.BAR_W + Snd.BAR_GAP) - Snd.BAR_GAP
	local EQ_RIGHT = DET_SONGS_X + DET_SONGS_W - 58

	-- where the playing song's row is, and whether it is still on screen.
	-- Scrolling it out of view takes the bars with it rather than leaving them
	-- behind on a song that is not making any sound.
	function Snd.PickY()
		if not Snd.index then return nil end
		local n = Snd.index - state.songCursor
		if n < 1 or n > SONG_ROWS then return nil end
		return SONG_TOP + (n - 1) * SONG_ROW_H + (SONG_ROW_H - 4)/2
	end

	for i = 1, Snd.BARS do
		detail[#detail+1] = Def.Quad{
			InitCommand = function(self)
				Snd.bars[i] = self
				self:horizalign(left):vertalign(bottom)
				self:x(EQ_RIGHT - EQ_SPAN + (i-1)*(Snd.BAR_W + Snd.BAR_GAP))
				self:setsize(Snd.BAR_W, 2):visible(false)
			end,
		}
	end

	detail[#detail+1] = Def.Quad{
		InitCommand = function(self)
			Snd.pbTrack = self
			Snd.pbX = EQ_RIGHT - Snd.PROG_W
			self:horizalign(left):vertalign(bottom)
			self:x(Snd.pbX):setsize(Snd.PROG_W, 5)
			self:visible(false):diffuse(1, 1, 1, 0.16)
		end,
	}
	detail[#detail+1] = Def.Quad{
		InitCommand = function(self)
			Snd.pbFill = self
			self:horizalign(left):vertalign(bottom)
			self:x(Snd.pbX):setsize(1, 5):visible(false)
		end,
	}

	detail[#detail+1] = Def.Actor{
		InitCommand = function(self) self:queuecommand("SMOSamplePump") end,
		SMOSamplePumpCommand = function(self)
			local showing = state.open and LO.DetailShowing()
			local playing = showing and Snd.status == "playing"
			local loading = showing and Snd.status == "loading"
			local now = GetTimeSinceStart()

			-- ask the helper how far along it is, a few times a second. The
			-- request that started the work cannot answer that; it is busy.
			if Snd.status == "loading" and now >= (Snd.pollAt or 0) then
				Snd.pollAt = now + 0.4
				Snd.Poll()
			end

			-- the row being talked about, and whether it is scrolled into view
			local rowY = Snd.PickY()
			playing = playing and rowY ~= nil
			loading = loading and rowY ~= nil

			-- once per frame, not once per bar: this runs thirty times a second
			local accent = (playing or loading) and AccentColor() or nil

			for i = 1, Snd.BARS do
				local bar = Snd.bars[i]
				if bar then
					bar:visible(playing)
					if playing then
						local hgt = Snd.BarHeight(i, now)
						bar:y(rowY + 9)
						bar:setsize(Snd.BAR_W, hgt)
						bar:diffuse(accent)
						bar:diffusealpha(0.30 + 0.70 * (hgt / Snd.BAR_H))
					end
				end
			end

			if Snd.pbTrack then
				Snd.pbTrack:visible(loading)
				if loading then Snd.pbTrack:y(rowY + 6) end
			end
			if Snd.pbFill then
				Snd.pbFill:visible(loading)
				if loading then
					local _, frac = Snd.ProgLabel()
					Snd.pbFill:y(rowY + 6)
					Snd.pbFill:diffuse(accent)
					if frac and frac >= 0 then
						Snd.pbFill:x(Snd.pbX or 0)
						Snd.pbFill:setsize(math.max(1, Snd.PROG_W * frac), 5)
					else
						-- nothing measurable yet, so a block that travels
						-- rather than a bar that would be inventing a number
						local w = Snd.PROG_W * 0.3
						local at = (now * 0.7) % 2
						if at > 1 then at = 2 - at end
						Snd.pbFill:setsize(w, 5)
						Snd.pbFill:x((Snd.pbX or 0) + at * (Snd.PROG_W - w))
					end
				end
			end

			-- the sample stops itself; nothing else would notice that it had
			if playing and Snd.len > 0 and (now - Snd.startedAt) > (Snd.len + 1.6) then
				Snd.Stop()
			end

			self:sleep(1/30):queuecommand("SMOSamplePump")
		end,
	}

	for i = 1, SONG_ROWS do
		local ROW_H = SONG_ROW_H - 4

		-- the song this row owns for the current window: the one in view whose
		-- index leaves remainder i-1 when divided by the number of rows
		local function SongNumber()
			local c = state.songCursor
			return c + 1 + ((i - 1 - (c + 1)) % SONG_ROWS)
		end
		local function RowY()
			return SONG_TOP + (SongNumber() - state.songCursor - 1) * SONG_ROW_H
		end

		local function SongAt()
			local pack = CurrentPack()
			local det = pack and state.details[pack.id]
			return det and det.songs[SongNumber()] or nil
		end

		detail[#detail+1] = Def.Quad{
			InitCommand = function(self)
				self:vertalign(top):horizalign(left)
				self:xy(DET_SONGS_X - 6, RowY()):setsize(DET_SONGS_W + 12, ROW_H)
			end,
			SMORefreshMessageCommand = function(self)
				self:y(RowY())
				if SongNumber() == state.songPick then
					-- the song a preview would play
					self:diffuse(AccentColor()):diffusealpha(0.30)
				else
					-- banded by position rather than by row, so the stripes
					-- stay put while the rows move through them
					local band = (SongNumber() - state.songCursor) % 2
					self:diffuse(0, 0, 0, (band == 0) and 0.34 or 0.52)
				end
				self:visible(LO.DetailShowing() and SongAt() ~= nil)
			end,
		}

		-- Art: SMO gives a song its own jacket where it has one and the pack
		-- banner where it does not, so the box is banner-shaped and the frame
		-- takes whatever shape the image actually fits to.  Wider rather than
		-- taller, so the rows stay the height they were.
		local ART_W = 104
		local ART_H = ROW_H - 8
		local ART_X = DET_SONGS_X + 4 + ART_W/2
		local function ART_Y() return RowY() + ROW_H/2 end
		local TEXT_X = DET_SONGS_X + ART_W + 16
		local TEXT_W = DET_SONGS_W - (ART_W + 16) - 56

		local function ArtBox()
			local box = songArt[i]
			if box and box.w > 0 and box.h > 0 then return box.w, box.h end
			return ART_H, ART_H
		end

		-- Is there a picture to frame yet? Until there is, the frame and its
		-- backing stay out of the way: an empty lit square around a spinner
		-- reads as a broken image rather than as one still arriving.
		local function ArtReady()
			local song = LO.DetailShowing() and SongAt() or nil
			local url = song and song.image
			return url ~= nil and state.banners[url] ~= nil
		end

		-- lit border, sized to the image rather than to a fixed square
		detail[#detail+1] = Def.Quad{
			InitCommand = function(self) self:xy(ART_X, ART_Y()):visible(false) end,
			SMORefreshMessageCommand = function(self) self:playcommand("SMOArtFrame") end,
			SMOBannerReadyMessageCommand = function(self) self:playcommand("SMOArtFrame") end,
			SMOArtFrameCommand = function(self)
				self:y(ART_Y())
				self:visible(ArtReady())
				if not ArtReady() then return end
				local w, h = ArtBox()
				self:setsize(w + 4, h + 4)
				self:diffuse(AccentColor()):diffusealpha(0.4)
			end,
		}
		detail[#detail+1] = Def.Quad{
			InitCommand = function(self) self:xy(ART_X, ART_Y()):visible(false) end,
			SMORefreshMessageCommand = function(self) self:playcommand("SMOArtBack") end,
			SMOBannerReadyMessageCommand = function(self) self:playcommand("SMOArtBack") end,
			SMOArtBackCommand = function(self)
				self:y(ART_Y())
				self:visible(ArtReady())
				if not ArtReady() then return end
				local w, h = ArtBox()
				self:setsize(w, h)
				self:diffuse(0.10, 0.10, 0.10, 1)
			end,
		}

		detail[#detail+1] = Def.Sprite{
			InitCommand = function(self)
				self:xy(ART_X, ART_Y()):visible(false)
			end,
			SMORefreshMessageCommand = function(self) self:playcommand("SMOSetBanner") end,
			SMOBannerReadyMessageCommand = function(self) self:playcommand("SMOSetBanner") end,
			SMOSetBannerCommand = function(self)
				local song = LO.DetailShowing() and SongAt() or nil
				local url = song and song.image
				local path = url and state.banners[url]
				local key = "song" .. i
				self:y(ART_Y())
				if path then
					if loadedBanner[key] ~= path then
						self:Load(path)
						loadedBanner[key] = path
					end
					FitSprite(self, ART_W, ART_H)
					songArt[i] = { w = self:GetZoomedWidth(), h = self:GetZoomedHeight() }
					self:visible(true)
				else
					self:visible(false)
					songArt[i] = nil
					-- only the rows actually on screen ever ask for an image
					if url then RequestBanner(url) end
				end
			end,
		}

		-- spinner while a jacket is on its way in
		detail[#detail+1] = Spinner(ART_X, ART_Y, 0.11, function()
			local song = LO.DetailShowing() and SongAt() or nil
			if not song or not song.image then return false end
			-- a known-failed image collapses to the placeholder instead of
			-- spinning for the whole retry window
			if state.bannerFailed[song.image] then return false end
			return state.banners[song.image] == nil
		end)

		-- title: the largest thing in the row
		detail[#detail+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(left):xy(TEXT_X, RowY() + 15):zoom(0.66)
				self:maxwidth(TEXT_W/0.66)
			end,
			SMORefreshMessageCommand = function(self)
				local song = LO.DetailShowing() and SongAt() or nil
				self:y(RowY() + 15)
				self:settext(song and song.title or "")
				self:diffuse(1, 1, 1, 1)
			end,
		}

		detail[#detail+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(left):xy(TEXT_X, RowY() + 30):zoom(0.42):diffuse(0.58, 0.58, 0.58, 1)
				self:maxwidth(TEXT_W/0.42)
			end,
			SMORefreshMessageCommand = function(self)
				local song = LO.DetailShowing() and SongAt() or nil
				self:y(RowY() + 30)
				if not song then self:settext("") return end
				local bits = {}
				if song.artist ~= "" then bits[#bits+1] = song.artist end
				if song.bpm ~= "" then bits[#bits+1] = song.bpm .. " bpm" end
				if song.length ~= "" then bits[#bits+1] = song.length end
				if song.credit ~= "" then bits[#bits+1] = song.credit end
				self:settext(table.concat(bits, "  -  "))
			end,
		}

		-- meter range, tinted by the hardest chart in the song
		detail[#detail+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(right):xy(DET_SONGS_X + DET_SONGS_W, ART_Y()):zoom(0.68)
			end,
			SMORefreshMessageCommand = function(self)
				local song = LO.DetailShowing() and SongAt() or nil
				self:y(ART_Y())
				if song and song.meters ~= "" then
					self:settext(song.meters)
					local top = 0
					for n in song.meters:gmatch("%d+") do top = math.max(top, tonumber(n)) end
					self:diffuse(MeterColor(top, 1))
				else
					self:settext("")
				end
			end,
		}
	end

	-- how far through the pack's song list you are
	detail[#detail+1] = ScrollBar(DET_SONGS_X + DET_SONGS_W + 8, SONG_TOP,
		SONG_ROWS*SONG_ROW_H - 8, false,
		function()
			if state.mode ~= "detail" then return nil end
			local pack = CurrentPack()
			local det = pack and state.details[pack.id]
			if not det then return nil end
			return #det.songs, SONG_ROWS, state.songCursor
		end)

	-- ---------------------------------------------------------------
	-- Context band: fills the strip the featured cards occupy, for the views
	-- that have no featured grid of their own (search and the content levels).

	local bandAF = Def.ActorFrame{
		Name = "Band",
		InitCommand = function(self) self:visible(false) end,
		SMORefreshMessageCommand = function(self)
			-- the keyboard tab has no grid, so the band is its header too
			local keyboardList = state.mode == "list" and state.search == ""
				and state.filterMode == "keyboard"
			self:visible(state.open and state.mode ~= "detail"
				and (InLevelView() or state.search ~= "" or keyboardList))
		end,
	}

	bandAF[#bandAF+1] = Def.Quad{
		InitCommand = function(self)
			self:vertalign(top):horizalign(left)
			self:xy(LO.LIST_X, LO.FEAT_TOP):setsize(LO.W - 2*LO.LIST_X, LO.FEAT_CARD_H)
			self:diffuse(1, 1, 1, 0.05)
		end,
	}

	bandAF[#bandAF+1] = Def.BitmapText{
		Font = "Common Bold",
		InitCommand = function(self)
			self:horizalign(left):xy(LO.LIST_X + 18, LO.FEAT_TOP + 26):zoom(0.42)
		end,
		SMORefreshMessageCommand = function(self)
			self:settext(BandTitle())
			self:diffuse(AccentColor())
		end,
	}

	bandAF[#bandAF+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(left):xy(LO.LIST_X + 18, LO.FEAT_TOP + 52):zoom(0.55)
			self:diffuse(0.78, 0.78, 0.78, 1)
			self:maxwidth((LO.W - 2*LO.LIST_X - 120)/0.55)
		end,
		SMORefreshMessageCommand = function(self)
			self:settext(BandSubtitle())
		end,
	}

	-- progress, for the searches and level scans that take a moment
	bandAF[#bandAF+1] = Spinner(LO.W - LO.LIST_X - 34, LO.FEAT_TOP + LO.FEAT_CARD_H/2, 0.16,
		function()
			return BandBusy()
		end)

	bandAF[#bandAF+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(right):xy(LO.W - LO.LIST_X - 56, LO.FEAT_TOP + LO.FEAT_CARD_H/2)
			self:zoom(0.5)
		end,
		SMORefreshMessageCommand = function(self)
			self:settext(BandBusy() and BandBusyText() or "")
			self:diffuse(AccentColor())
		end,
	}

	ui[#ui+1] = bandAF

	-- ---------------------------------------------------------------
	-- YEAR view: the picker that sits where the featured grid normally is

	-- YEAR_SPAN + 1 chips (each year, plus OLDER) share the band width
	local YEAR_CHIP_W = math.floor((LO.W - 2*LO.LIST_X + 10) / (YEAR_SPAN + 1)) - 10
	local YEAR_CHIP_H = 34
	local YEAR_CHIP_Y = LO.FEAT_TOP + 18

	local yearAF = Def.ActorFrame{
		Name = "Years",
		InitCommand = function(self) self:visible(false) end,
		SMORefreshMessageCommand = function(self)
			self:visible(state.open and InYearView())
		end,
	}

	yearAF[#yearAF+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(left):xy(LO.LIST_X, LO.FEAT_LABEL_Y):zoom(0.55)
		end,
		SMORefreshMessageCommand = function(self)
			-- "added", never "released": this is the date SMO listed the pack
			local label = "PACKS BY YEAR"
			if state.viewYear == "older" then
				label = "PACKS ADDED TO SMO BEFORE " .. state.yearFloor
			elseif state.viewYear then
				label = "PACKS ADDED TO SMO IN " .. state.viewYear
			end
			if state.recentIndex.status == "loading" then
				-- the bar and the year on the right carry the detail
				label = label .. "   building index..."
			elseif state.localRows then
				label = label .. string.format("   %s packs", Commify(#state.localRows))
			end
			self:settext(label)
			self:diffuse(AccentColor())
		end,
	}

	-- How far the index has walked, where the page counter used to be. Shown
	-- only while it is walking: a full bar sitting there afterwards would be
	-- furniture.
	yearAF[#yearAF+1] = Def.Quad{
		InitCommand = function(self)
			self:horizalign(left):xy(LO.W - LO.LIST_X - 156, LO.FEAT_LABEL_Y + 10)
			self:setsize(140, 4):diffuse(1, 1, 1, 0.16):visible(false)
		end,
		SMORefreshMessageCommand = function(self)
			self:visible(state.recentIndex.status == "loading")
		end,
	}
	yearAF[#yearAF+1] = Def.Quad{
		InitCommand = function(self)
			self:horizalign(left):xy(LO.W - LO.LIST_X - 156, LO.FEAT_LABEL_Y + 10)
			self:setsize(1, 4):visible(false)
		end,
		SMORefreshMessageCommand = function(self)
			local idx = state.recentIndex
			self:visible(idx.status == "loading")
			if idx.status ~= "loading" then return end
			self:diffuse(AccentColor())
			self:setsize(math.max(1, 140 * Clamp(idx.frac or 0, 0, 1)), 4)
		end,
	}

	-- focus ring first, so the chips draw on top of it and it reads as a border
	yearAF[#yearAF+1] = Def.Quad{
		InitCommand = function(self)
			self:vertalign(top):horizalign(left):visible(false)
			self:setsize(YEAR_CHIP_W + 4, YEAR_CHIP_H + 4)
		end,
		SMORefreshMessageCommand = function(self)
			if state.zone ~= "years" then self:visible(false) return end
			local slot = Clamp(state.yearCursor or 1, 1, YEAR_SPAN + 1)
			self:visible(true)
			self:xy(LO.LIST_X + (slot-1)*(YEAR_CHIP_W + 10) - 2, YEAR_CHIP_Y - 2)
			self:diffuse(AccentColor())
		end,
	}

	for slot = 1, YEAR_SPAN + 1 do
		local chipX = LO.LIST_X + (slot-1) * (YEAR_CHIP_W + 10)

		local function YearAt()
			return YearList()[slot]
		end

		yearAF[#yearAF+1] = Def.Quad{
			InitCommand = function(self)
				self:vertalign(top):horizalign(left)
				self:xy(chipX, YEAR_CHIP_Y):setsize(YEAR_CHIP_W, YEAR_CHIP_H)
			end,
			SMORefreshMessageCommand = function(self)
				if YearAt() == state.viewYear then
					self:diffuse(AccentColor())
					self:diffusealpha(state.zone == "years" and 0.5 or 0.3)
				else
					self:diffuse(0, 0, 0, 0.55)
				end
			end,
		}

		yearAF[#yearAF+1] = Def.BitmapText{
			Font = "Common Bold",
			InitCommand = function(self)
				self:xy(chipX + YEAR_CHIP_W/2, YEAR_CHIP_Y + YEAR_CHIP_H/2 - 1):zoom(0.42)
				self:maxwidth((YEAR_CHIP_W - 8) / 0.42)
			end,
			SMORefreshMessageCommand = function(self)
				local yv = YearAt()
				self:settext(yv == "older" and "OLDER" or tostring(yv or ""))
				local lit = (YearAt() == state.viewYear) and 1 or 0.6
				self:diffuse(lit, lit, lit, 1)
			end,
		}
	end

	ui[#ui+1] = yearAF

	-- ---------------------------------------------------------------
	-- INSTALLED PACKS view

	local INST_TOP    = LO.FEAT_TOP
	local INST_ROW_H  = 32
	local INST_PER_COL = INST_ROWS / INST_COLS
	local INST_GAP    = 12
	local INST_W      = math.floor(
		(LO.W - 2*LO.LIST_X - (INST_COLS-1)*INST_GAP) / INST_COLS)

	local instAF = Def.ActorFrame{
		Name = "Installed",
		InitCommand = function(self) self:visible(false) end,
		SMORefreshMessageCommand = function(self)
			self:visible(state.open and (state.mode == "installed" or state.mode == "removeconfirm"))
		end,
	}

	-- summary line
	instAF[#instAF+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(left):xy(LO.LIST_X, LO.FEAT_LABEL_Y):zoom(0.55)
		end,
		SMORefreshMessageCommand = function(self)
			local inst = state.installed
			local label = string.format("%d PACKS IN YOUR LIBRARY", #inst.packs)
			if #inst.packs > INST_ROWS then
				label = label .. string.format("   PAGE %d/%d", InstalledPage(), InstalledPages())
			end
			if state.helper.status == "absent" then
				label = label .. "   -   removal unavailable"
			end
			self:settext(label)
			self:diffuse(AccentColor())
		end,
	}

	for slot = 1, INST_ROWS do
		local rowX = LO.LIST_X
			+ math.floor((slot-1) / INST_PER_COL) * (INST_W + INST_GAP)
		local rowY = INST_TOP + ((slot-1) % INST_PER_COL) * INST_ROW_H

		local function PackAt()
			local inst = state.installed
			return inst.packs[inst.window + slot]
		end
		local function Focused()
			local inst = state.installed
			return state.zone == "list" and (inst.window + slot) == inst.cursor
		end

		-- row background / focus fill
		instAF[#instAF+1] = Def.Quad{
			InitCommand = function(self)
				self:vertalign(top):horizalign(left)
				self:xy(rowX, rowY):setsize(INST_W, INST_ROW_H - 4)
			end,
			SMORefreshMessageCommand = function(self)
				local pack = PackAt()
				self:visible(pack ~= nil)
				if not pack then return end
				if Focused() then
					self:diffuse(AccentColor()):diffusealpha(0.30)
				elseif state.removing == pack.name then
					self:diffuse(0.55, 0.13, 0.16, 0.42)
				else
					self:diffuse(0, 0, 0, (slot % 2 == 0) and 0.34 or 0.5)
				end
			end,
		}

		-- pack banner
		instAF[#instAF+1] = Def.Sprite{
			InitCommand = function(self)
				self:xy(rowX + 36, rowY + (INST_ROW_H - 4)/2):visible(false)
			end,
			SMORefreshMessageCommand = function(self)
				local pack = PackAt()
				local path = pack and pack.banner
				local key = "inst" .. slot
				if path and path ~= "" then
					if loadedBanner[key] ~= path then
						self:Load(path)
						loadedBanner[key] = path
					end
					FitSprite(self, 64, INST_ROW_H - 8)
					self:visible(true)
				else
					self:visible(false)
				end
			end,
		}

		-- pack name
		instAF[#instAF+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(left):xy(rowX + 76, rowY + 8):zoom(0.55)
				self:maxwidth((INST_W - 76 - 96)/0.55)
			end,
			SMORefreshMessageCommand = function(self)
				local pack = PackAt()
				self:settext(pack and pack.name or "")
				if pack and state.removing == pack.name then
					self:diffuse(1, 0.62, 0.62, 1)
				else
					self:diffuse(1, 1, 1, 1)
				end
			end,
		}

		-- song count
		instAF[#instAF+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(left):xy(rowX + 76, rowY + 20):zoom(0.42)
				self:diffuse(0.6, 0.6, 0.6, 1)
				self:maxwidth((INST_W - 76 - 96)/0.42)
			end,
			SMORefreshMessageCommand = function(self)
				local pack = PackAt()
				if not pack then self:settext("") return end
				self:settext(pack.songs .. (pack.songs == 1 and " song" or " songs")
					.. "   -   " .. Sync.DiskLabel(pack.sync, pack.syncOurs))
			end,
		}

		-- SMO comparison / removal marker
		instAF[#instAF+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(right):xy(rowX + INST_W - 10, rowY + (INST_ROW_H - 4)/2)
				self:zoom(0.5)
			end,
			SMORefreshMessageCommand = function(self)
				local pack = PackAt()
				if not pack then self:settext("") return end
				if state.removing == pack.name then
					self:settext("REMOVING...")
					self:diffuse(1, 0.42, 0.42, 1)
					return
				end
				local text, r, g, b = InstalledStatusText(pack)
				self:settext(text)
				self:diffuse(r, g, b, 1)
			end,
		}
	end

	-- empty state
	instAF[#instAF+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(LO.W/2, INST_TOP + 60):zoom(0.6):diffuse(0.7, 0.7, 0.7, 1)
		end,
		SMORefreshMessageCommand = function(self)
			local inst = state.installed
			if inst.status == "ready" and #inst.packs == 0 then
				self:settext("No song packs found in /Songs.")
			else
				self:settext("")
			end
		end,
	}

	instAF[#instAF+1] = ScrollBar(
		LO.LIST_X + INST_COLS*INST_W + (INST_COLS-1)*INST_GAP + 5,
		INST_TOP, INST_PER_COL*INST_ROW_H - 4, false,
		function()
			if not InInstalledView() then return nil end
			return #state.installed.packs, INST_ROWS, state.installed.window
		end)

	ui[#ui+1] = instAF

	-- ---------------------------------------------------------------
	-- footer hints

	ui[#ui+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(LO.W/2, LO.CONTENT_BOT + 15):zoom(0.55):diffuse(0.75, 0.75, 0.75, 1):maxwidth((LO.W - 20)/0.55)
		end,
		SMORefreshMessageCommand = function(self)
			if state.mode == "list" or InLevelView() then
				if state.zone == "tabs" then
					if TabOrder[state.tabIndex] == "search" then
						self:settext("&MENULEFT;&MENURIGHT; views    &START; type a search    &BACK; exit")
					else
						self:settext("&MENULEFT;&MENURIGHT; views    &MENUDOWN; browse    &BACK; exit")
					end
				elseif state.zone == "featured" then
					self:settext("&MENULEFT;&MENURIGHT; browse    &MENUUP;&MENUDOWN; row    &START; details    &BACK; exit")
				else
					self:settext("&MENUUP;&MENUDOWN; browse    &MENULEFT;&MENURIGHT; page    &START; details    &BACK; exit")
				end
			elseif state.mode == "year" then
				if state.zone == "tabs" then
					self:settext("&MENULEFT;&MENURIGHT; switch view    &MENUDOWN; pick a year    &BACK; exit")
				elseif state.zone == "years" then
					self:settext("&MENULEFT;&MENURIGHT; year    &MENUDOWN; packs    &MENUUP; views    &BACK; exit")
				else
					self:settext("&MENUUP;&MENUDOWN; browse    &MENURIGHT; page    &START; details    &BACK; exit")
				end
			elseif state.mode == "installed" then
				if state.zone == "tabs" then
					self:settext("&MENULEFT;&MENURIGHT; switch view    &MENUDOWN; your packs    &BACK; exit")
				else
					self:settext("&MENUUP;&MENUDOWN; packs    &MENULEFT;&MENURIGHT; page    &START; remove pack    &BACK; exit")
				end
			elseif state.mode == "detail" then
				if Snd.Busy() then
					self:settext("&MENUUP;&MENUDOWN; songs    &SELECT;&START; stop the sample    &BACK; back")
				else
					self:settext("&MENUUP;&MENUDOWN; songs    &SELECT; hear a sample    &START; download    &BACK; back")
				end
			elseif state.mode == "sync" or state.mode == "blocked" or state.mode == "confirm"
			       or state.mode == "reload" or state.mode == "removeconfirm" then
				-- a dialog is up; it prints its own hint, so don't double it here
				self:settext("")
			else
				self:settext("")
			end
		end,
	}

	-- where this page sits in the whole filtered list
	ui[#ui+1] = ScrollBar(LO.LIST_X + LO.LIST_W + 3, LO.ListTop, ROWS*LO.ROW_H - 3, false,
		function()
			if not InPackList() then return nil end
			if state.filtered <= 0 then return nil end
			return state.filtered, ROWS, (state.page - 1) * ROWS
		end)

	ui[#ui+1] = listAF
	ui[#ui+1] = pane
	ui[#ui+1] = detail

	-- ---------------------------------------------------------------
	-- modal dialogs (network warning / confirm / reload)

	-- bodyFn returns title, body, hint.  The hint is the only place the
	-- confirm/cancel keys are printed for a dialog; the footer stays quiet.
	local function DialogFrame(name, visibleFn, bodyFn, height, choicesFn)
		local h = height or LO.DIALOG_H
		local dialog = Def.ActorFrame{
			Name = name,
			InitCommand = function(self) self:xy(LO.W/2, LO.H/2):visible(false) end,
			SMORefreshMessageCommand = function(self)
				self:visible(state.open and not state.textEntryOpen and visibleFn())
			end,

			Def.Quad{ InitCommand=function(self) self:setsize(LO.DIALOG_W + 4, h + 4):diffuse(1, 1, 1, 1) end },
			Def.Quad{ InitCommand=function(self) self:setsize(LO.DIALOG_W, h):diffuse(0, 0, 0, 1) end },

			Def.BitmapText{
				Font = "Common Bold",
				InitCommand = function(self)
					self:y(-h/2 + 22):zoom(0.4)
				end,
				SMORefreshMessageCommand = function(self)
					local title = bodyFn()
					self:settext(title or "")
					self:diffuse(AccentColor())
				end,
			},

			-- rule under the title
			Def.Quad{
				InitCommand = function(self)
					self:y(-h/2 + 38):setsize(LO.DIALOG_W - 48, 1)
				end,
				SMORefreshMessageCommand = function(self)
					self:diffuse(AccentColor()):diffusealpha(0.45)
				end,
			},

			Def.BitmapText{
				Font = "Common Normal",
				InitCommand = function(self)
					self:y(-h/2 + 46):vertalign(top):zoom(0.58):diffuse(0.9, 0.9, 0.9, 1)
					self:wrapwidthpixels((LO.DIALOG_W - 40)/0.58)
				end,
				SMORefreshMessageCommand = function(self)
					local _, body = bodyFn()
					self:settext(body or "")
				end,
			},

			-- the dialog's own confirm/cancel line
			Def.BitmapText{
				Font = "Common Normal",
				InitCommand = function(self)
					self:y(h/2 - 18):zoom(0.6)
					self:maxwidth((LO.DIALOG_W - 30)/0.6)
				end,
				SMORefreshMessageCommand = function(self)
					local _, _, hint = bodyFn()
					self:settext(hint or "")
					self:diffuse(AccentColor())
				end,
			},
		}

		-- A dialog that asks which of two things to do rather than whether to
		-- do one thing. The options sit above the hint line; a dialog without
		-- them is unchanged.
		if choicesFn then
			for ci = 1, 2 do
				local cx = (ci == 1) and -(LO.DIALOG_W/4 - 4) or (LO.DIALOG_W/4 - 4)
				local cy = h/2 - 48
				dialog[#dialog+1] = Def.Quad{
					InitCommand = function(self)
						self:xy(cx, cy):setsize(LO.DIALOG_W/2 - 26, 26)
					end,
					SMORefreshMessageCommand = function(self)
						local list, idx = choicesFn()
						self:visible(list ~= nil and list[ci] ~= nil)
						if not (list and list[ci]) then return end
						if idx == ci then
							self:diffuse(AccentColor()):diffusealpha(0.38)
						else
							self:diffuse(0.15, 0.15, 0.15, 1)
						end
					end,
				}
				dialog[#dialog+1] = Def.BitmapText{
					Font = "Common Normal",
					InitCommand = function(self)
						self:xy(cx, cy):zoom(0.5)
						self:maxwidth((LO.DIALOG_W/2 - 34)/0.5)
					end,
					SMORefreshMessageCommand = function(self)
						local list, idx = choicesFn()
						self:visible(list ~= nil and list[ci] ~= nil)
						if not (list and list[ci]) then return end
						self:settext(list[ci])
						if idx == ci then
							self:diffuse(1, 1, 1, 1)
						else
							self:diffuse(0.65, 0.65, 0.65, 1)
						end
					end,
				}
			end
		end
		return dialog
	end

	af[#af+1] = ui

	af[#af+1] = DialogFrame("NetworkWarningDialog",
		function() return state.mode == "blocked" end,
		function()
			local reason = state.blockedReason or "Network access is not enabled."
			local fix = "Run the Find Content installer again, or -- with ITGmania closed -- double-click  Enable Network Access.bat  in Themes/Simply Love/Modules/"
			return "Network Access Not Enabled", reason .. "\n\n" .. fix, "&BACK; back to the title menu"
		end, 210)

	af[#af+1] = DialogFrame("ConfirmDialog",
		function() return state.mode == "confirm" end,
		function()
			local pack = CurrentPack()
			if not pack then return "", "" end
			local det = state.details[pack.id]
			local song = det and det.songs[state.songPick] or nil
			local body = pack.name .. "\n" .. pack.sizeStr .. "  -  " .. pack.songs .. " songs"
			if SONGMAN:DoesSongGroupExist(pack.name) then
				body = body .. "\n(a pack with this name is already in your library)"
			end
			if song then
				body = body .. "\nselected song:  " .. song.title
			end
			local dl = state.downloads[pack.id]
			if dl and (dl.status == "active" or dl.status == "installing") then
				body = body .. "\n(this pack is downloading already)"
			end
			return "Listen or Download?", body,
				"&MENULEFT;&MENURIGHT; choose    &START; go    &BACK; cancel"
		end, 205,
		function()
			local pack = CurrentPack()
			local det = pack and state.details[pack.id]
			local song = det and det.songs[state.songPick] or nil
			return { song and "Hear a sample" or "No song picked", "Download pack" },
				state.chooseIdx
		end)

	af[#af+1] = DialogFrame("RemovePackDialog",
		function() return state.mode == "removeconfirm" end,
		function()
			local pack = InstalledPack()
			if not pack then return "", "" end
			local body = pack.name .. "\n"
				.. pack.songs .. (pack.songs == 1 and " song" or " songs") .. "\n\n"
				.. "This deletes the pack from your Songs folder. It cannot be undone; "
				.. "you would have to download the pack again.\n\n"
				.. "Your song list refreshes when you leave the browser."
			return "Delete This Pack?", body, "&START; delete it    &BACK; cancel"
		end, 230)

	af[#af+1] = DialogFrame("ReloadDialog",
		function() return state.mode == "reload" end,
		function()
			return "New Packs Installed",
				"Reload songs now so your new packs show up?",
				"&START; reload songs    &BACK; not yet"
		end)

	-- The sync screen. It is the explainer for the whole subject, and on an
	-- installed pack with no Pack.ini it is also where one gets written.
	af[#af+1] = DialogFrame("SyncDialog",
		function() return state.mode == "sync" end,
		function()
			local pack = state.syncPack
			local canWrite = (pack ~= nil) and (pack.sync == nil) and (pack.dir ~= nil)

			local body = "A pack is either NULL synced, or ITG synced -- ITG meaning its "
				.. "charts carry the arcade's 9ms bias, which ITGmania removes on the way in.\n\n"
				.. "A pack says which in a Pack.ini file. With no Pack.ini this machine's "
				.. "DefaultSyncOffset decides, and that is ITG -- so an ITG pack is already "
				.. "right, and only a NULL pack plays 9ms out.\n\n"
				.. "Nothing published says which a pack needs. SMO's Sync field has no value "
				.. "for ITG at all, and lists In The Groove 2 -- the pack the 9ms offset is "
				.. "named for -- as NULL. So the browser reports what SMO says and attributes "
				.. "it, and never guesses on your behalf."

			if state.syncNote then
				body = state.syncNote .. "\n\n" .. body
			elseif pack and pack.sync then
				body = pack.name .. " ships its own " .. (pack.syncFile or "Pack.ini")
					.. ", declaring SyncOffset=" .. pack.sync .. ". That came from whoever "
					.. "made the pack, so it is left alone.\n\n" .. body
			elseif canWrite then
				body = pack.name .. " has no Pack.ini, so it is being played at this "
					.. "machine's default (ITG). If it feels 9ms out, write NULL.\n\n"
					.. "Write:  " .. state.syncChoice
					.. ((state.syncChoice == "NULL")
						and "   (charts are already null synced)"
						or  "   (charts carry the 9ms bias)")
					.. "\n\n" .. body
			elseif pack then
				body = pack.name .. "'s folder could not be found, so nothing can be "
					.. "written for it.\n\n" .. body
			else
				body = "Open this from the INSTALLED tab with a pack highlighted to write a "
					.. "Pack.ini for it.\n\n" .. body
			end

			local hint = "&BACK; close"
			if canWrite and not state.syncNote then
				hint = "&MENULEFT;&MENURIGHT; NULL / ITG    &START; write Pack.ini    &BACK; close"
			end
			return "Pack Sync", body, hint
		end, 330)

	-- ---------------------------------------------------------------
	-- toast

	af[#af+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(LO.W/2, LO.CONTENT_BOT - 8):zoom(0.6):diffusealpha(0)
		end,
		SMOToastMessageCommand = function(self, params)
			if not state.open then return end
			self:finishtweening()
			self:settext(params and params.Text or "")
			self:diffuse(AccentColor()):diffusealpha(1)
			self:sleep(2):linear(0.4):diffusealpha(0)
		end,
	}

	return af
end

-- -----------------------------------------------------------------------
-- title menu actor

local function TitleActor()
	local af = Def.ActorFrame{
		Name = "SMOFindContentTitleItem",

		InitCommand = function(self) refs.titleAF = self end,

		ModuleCommand = function(self)
			-- fresh title screen: reset transient state
			titleFocused = false
			titleLeaving = false
			state.open = false
			state.textEntryOpen = false
			SetRedirect(false)

			-- read the theme's current choice list so we sit underneath it
			local ok, names = pcall(function() return THEME:GetMetric("ScreenTitleMenu", "ChoiceNames") end)
			if ok and type(names) == "string" and names ~= "" then
				local list = {}
				for name in names:gmatch("[^,]+") do
					list[#list+1] = (Trim(name):gsub("[\"']", ""))
				end
				if #list > 0 then
					titleNumChoices = #list
					titleChoiceNames = list
				end
			end
			titleLastIndex = TitleGetEngineIndex()

			-- preferred: consume input ahead of the engine via the overlay
			-- screen; fallback: watch the selection from the title screen
			local hooked = HookTitleOverlayInput(self)

			local screen = SCREENMAN:GetTopScreen()
			if screen then
				if not hooked then
					screen:AddInputCallback(TitleFallbackInput)
				end
				-- raise the (static) native menu a few pixels so our extra
				-- row fits above Simply Love's bottom "EVENT MODE" text.
				-- Setting y() absolutely keeps this idempotent.
				local scroller = screen:GetChild("Scroller")
				if scroller then
					scroller:y(TitleMenuBaseY())
				end
				-- and spread the choices out, leaving our row free
				TitleLayoutChoices()
			end

			self:playcommand("SMOTitleEnter")
		end,

	}

	-- Watches the engine's selection so the rows follow it. This module sees
	-- input before the engine does, so the index read during an input event is
	-- the pre-move one; polling for the change is simpler than predicting it.
	af[#af+1] = Def.Actor{
		SMOTitleEnterCommand = function(self)
			titleWatchIndex = -1
			titleWatchFocused = nil
			self:stoptweening():queuecommand("SMOTitleWatch")
		end,
		SMOTitleWatchCommand = function(self)
			local screen = SCREENMAN:GetTopScreen()
			if not screen or screen:GetName() ~= "ScreenTitleMenu" then return end
			local index = TitleGetEngineIndex()
			if index ~= titleWatchIndex or titleFocused ~= titleWatchFocused then
				titleWatchIndex = index
				titleWatchFocused = titleFocused
				MESSAGEMAN:Broadcast("SMOTitleRefresh")
			end
			-- the engine can re-show its own rows on a selection change
			TitleLayoutChoices()
			self:sleep(0.03):queuecommand("SMOTitleWatch")
		end,
	}

	-- One actor per visible row.  The engine's own choices are hidden (see
	-- TitleHideEngineChoices) because their y is reset by the theme's scroller
	-- transform every frame, so there is no way to reposition them; drawing the
	-- rows here is what lets "Find Content" sit above Exit and gives the block
	-- a pitch that is not cramped.
	for row = 1, TITLE.ROWS do
		af[#af+1] = Def.BitmapText{
			Font = "Common Bold",
			InitCommand = function(self)
				if row == TITLE.INSERT_SLOT + 1 then refs.titleItem = self end
				self:shadowlength(0.5)
				self:zoom(0.4)
				self:diffusealpha(0)
			end,

			SMOTitleEnterCommand = function(self)
				self:finishtweening()
				self:playcommand("SMOTitleUpdate")
				-- match the staggered fade-in of the native choices
				self:diffusealpha(0):sleep(row*0.075):linear(0.2):diffusealpha(1)
			end,

			SMOTitleUpdateCommand = function(self)
				local engineIndex = TitleRowEngineIndex(row)
				self:settext(engineIndex and TitleChoiceLabel(engineIndex) or "Find Content")
				self:xy(_screen.cx, TitleRowY(row))

				local focused
				if engineIndex == nil then
					focused = titleFocused
				else
					focused = (not titleFocused) and TitleGetEngineIndex() == engineIndex
				end

				if focused then
					self:stoptweening():zoom(0.5)
					self:accelerate(0.1):glow(1, 1, 1, 0.5)
					self:decelerate(0.05):glow(1, 1, 1, 0)
					local textColor = PlayerColor(PLAYER_2)
					if ThemePrefs.Get("VisualStyle") == "SRPG10" then
						textColor = GetCurrentColor(true)
					end
					self:diffuse(textColor)
				else
					self:stoptweening():zoom(0.4):glow(1, 1, 1, 0)
					local textColor = color("#888888")
					if ThemePrefs.Get("RainbowMode") then
						textColor = Color.White
					end
					if ThemePrefs.Get("VisualStyle") == "SRPG10" then
						textColor = color(SL.SRPG10.TextColor)
					end
					self:diffuse(textColor)
				end
			end,

			VisualStyleSelectedMessageCommand = function(self)
				self:playcommand("SMOTitleUpdate")
			end,

			SMOTitleRefreshMessageCommand = function(self)
				self:playcommand("SMOTitleUpdate")
			end,

			-- fade out alongside the native choices when leaving the screen
			SMOTitleLeaveCommand = function(self)
				self:stoptweening()
				self:sleep(row*0.075):linear(0.18):diffusealpha(0)
			end,
		}
	end

	return af
end

-- -----------------------------------------------------------------------
-- module table

local t = {}

t["ScreenTitleMenu"] = TitleActor()
t[BROWSER_SCREEN]    = BrowserActor()

-- when we send the player to the differential song reload, make sure it
-- returns to the title menu instead of ScreenSelectMusic
t["ScreenReloadSongsSSM"] = Def.Actor{
	ModuleCommand = function(self)
		-- any differential reload (ours or Simply Love's own "Load New Songs")
		-- picks up packs we installed, so the reload reminder is settled
		state.needsReload = false
		if state.reloadForUs then
			state.reloadForUs = false
			local screen = SCREENMAN:GetTopScreen()
			if screen then
				screen:SetNextScreenName("ScreenTitleMenu")
			end
		end
	end,
}

return t
