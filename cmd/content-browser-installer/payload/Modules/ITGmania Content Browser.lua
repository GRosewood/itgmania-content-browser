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
local SONG_ROWS     = 11     -- visible song rows in the detail view
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
	selected      = nil,     -- pack captured when entering detail/confirm view
	songCursor    = 0,       -- scroll offset into the detail song list
	downloads     = {},      -- packId -> {status,cur,total,msg,groups}
	banners       = {},      -- url -> local VFS path (once cached)
	bannerBusy    = {},      -- url -> true while downloading
	needsReload   = false,   -- something was installed this session
	textEntryOpen = false,
	pendingSearch = nil,
	reloadForUs   = false,   -- we sent the player to ScreenReloadSongsSSM
	blockedReason = nil,     -- why network access is unavailable, if it is

	-- pad/keyboard filtering (pack type metadata from /api/packs)
	filterMode    = "pad",   -- pad | keyboard | all
	packTypes     = nil,     -- packId(string) -> packtype ("keyboard"/"itg"/...)
	packTypesBusy = false,
	keyboardPacks = nil,     -- rows built from the CSV for keyboard mode, id desc
	pageOffsets   = {},      -- uiPage -> server row offset (pad mode paging)

	-- featured section
	zone          = "list",  -- tabs | featured | list (cursor zone in list mode)
	featCursor    = 1,
	featWindow    = 0,       -- first visible featured card (0-based)
	featured      = { status="idle", cards={}, pool={}, poolPos=0,
	                  inFlight=0, fetched=0, mode=nil, builtAt=nil },
}

-- refs to live actors, filled in by InitCommands
local refs = { rows = {}, songRows = {}, bars = {} }

-- actors are userdata, so per-sprite bookkeeping lives here instead
local loadedBanner = {}  -- spriteKey -> last path loaded into that sprite

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

local function Commify(n)
	local s = tostring(n)
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

local function TotalPages()
	if state.filtered <= 0 then return 1 end
	return math.max(1, math.ceil(state.filtered / ROWS))
end

local function CurrentPack()
	-- Detail/confirm views pin the pack that opened them, so an in-flight
	-- page fetch replacing the list can't swap the pack mid-view.
	if (state.mode == "detail" or state.mode == "confirm") and state.selected then
		return state.selected
	end
	-- otherwise: a featured card when the cursor is in the featured strip,
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

local function PassesFilter(pack)
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
	all      = "All packs",
}

-- date helpers for the featured window -----------------------------------

local function CurrentYear()
	local ok, y = pcall(function() return Year() end)
	if ok and type(y) == "number" and y > 2000 then return y end
	return 2026
end

-- first day of the month four months back, as a sortable "YYYY-MM-DD"
local function FourMonthsAgoStr()
	local y = CurrentYear()
	local m = 1
	local ok, mm = pcall(function() return MonthOfYear() end)
	if ok and type(mm) == "number" then m = mm + 1 end  -- MonthOfYear() is 0-based
	m = m - 4
	if m < 1 then
		m = m + 12
		y = y - 1
	end
	return string.format("%04d-%02d-01", y, m)
end

local function AccentColor()
	return GetCurrentColor and GetCurrentColor() or Color.White
end

local function PlaySfx(what)
	local path
	if what == "change" then path = THEME:GetPathS("ScreenSelectMaster", "change")
	elseif what == "start" then path = THEME:GetPathS("Common", "Start")
	elseif what == "cancel" then path = THEME:GetPathS("Common", "Cancel")
	elseif what == "invalid" then path = THEME:GetPathS("Common", "invalid")
	end
	if path then SOUND:PlayOnce(path) end
end

local function Refresh()
	MESSAGEMAN:Broadcast("SMORefresh")
end

local function Toast(text)
	MESSAGEMAN:Broadcast("SMOToast", {Text=text})
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
	local det = { stats = {}, labels = {}, counts = {}, songs = {} }

	for _, key in ipairs({"Songs", "Size", "Charts", "Difficulty"}) do
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
		for n in labels:gmatch("%-?%d+") do det.labels[#det.labels+1] = tonumber(n) end
		for n in counts:gmatch("%-?%d+") do det.counts[#det.counts+1] = tonumber(n) end
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
				song.title    = CleanText(tds[2]:match('href="/song/%d+">(.-)</a>') or "")
				song.artist   = CleanText(tds[2]:match('<span class="small translatable text%-gray%-400"[^>]*>(.-)</span>') or "")
				song.subtitle = CleanText(tds[3])
				song.length   = CleanText(tds[4])
				song.bpm      = CleanText(tds[5])
				song.credit   = (CleanText(tds[6]):gsub("[,%s]+$", ""))
				song.meters   = CleanText(tds[8])
				if song.title ~= "" then
					det.songs[#det.songs+1] = song
					if song.credit ~= "" then
						for credit in song.credit:gmatch("[^,]+") do
							credit = Trim(credit)
							if credit ~= "" then
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
	table.sort(ranked, function(a,b) return a.count > b.count end)
	if #ranked > 0 then
		local names = {}
		for i = 1, math.min(3, #ranked) do names[#names+1] = ranked[i].name end
		det.author = table.concat(names, ", ")
		if #ranked > 3 then det.author = det.author .. ", ..." end
	end

	return det
end

-- -----------------------------------------------------------------------
-- networking

local BANNER_RETRY_SECS = 600

local function RequestBanner(url)
	if not url or state.banners[url] or state.bannerBusy[url] then return end
	-- negative cache: don't hammer the server re-requesting failed banners
	-- on every refresh
	local failedAt = state.bannerFailed[url]
	if failedAt and GetTimeSinceStart() - failedAt < BANNER_RETRY_SECS then return end
	if not UrlAllowed() then return end

	local file = url:match("([%w%._%-]+)$")
	if not file then return end
	local cachePath = BANNER_DIR .. file

	if FILEMAN:DoesFileExist(cachePath) then
		state.banners[url] = cachePath
		MESSAGEMAN:Broadcast("SMOBannerReady")
		return
	end

	state.bannerBusy[url] = true
	NETWORK:HttpRequest{
		url = SMO_BASE .. url,
		downloadFile = "smo_" .. file,
		connectTimeout = 10,
		transferTimeout = 60,
		onResponse = function(response)
			state.bannerBusy[url] = nil
			if response.error == nil and response.statusCode == 200 then
				if FILEMAN:Copy("/Downloads/smo_" .. file, cachePath) then
					state.banners[url] = cachePath
					state.bannerFailed[url] = nil
					MESSAGEMAN:Broadcast("SMOBannerReady")
					return
				end
			end
			state.bannerFailed[url] = GetTimeSinceStart()
		end,
	}
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
			local keyboard = {}
			local first = true
			for line in response.body:gmatch("[^\r\n]+") do
				if first then
					first = false  -- header row
				else
					local ok, f = pcall(ParseCsvLine, line)
					-- id, name, song count, size, sync, packtype, substyle, min version
					if ok and f[1] and f[1]:match("^%d+$") and f[6] then
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
			state.keyboardPacks = keyboard

			-- the current view was built unfiltered; rebuild it now that the
			-- filter can actually apply (only if the user is still on page 1)
			if state.open and state.mode ~= "blocked" and state.page == 1 and ApplyFilterRefetch then
				ApplyFilterRefetch(true)
			else
				Refresh()
			end
		end,
	}
end

-- ---------------------------------------------------------------
-- pack list fetching (filter-aware)

local FetchPacks  -- forward declaration (keyboard branch has no request)

FetchPacks = function(page, keepCursor)
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
		local startIndex = (page-1) * ROWS
		local pagePacks = {}
		for i = startIndex + 1, math.min(startIndex + ROWS, #rows) do
			pagePacks[#pagePacks+1] = rows[i]
		end
		state.packs      = pagePacks
		state.page       = page
		state.totalPacks = #source
		state.filtered   = #rows
		state.cursor     = keepCursor and Clamp(state.cursor, 1, math.max(1, #pagePacks)) or 1
		state.loading    = false
		state.loadErr    = nil
		state.lastFetch  = GetTimeSinceStart()
		Refresh()
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
	local filteringActive = (state.filterMode == "pad" and state.packTypes ~= nil)
	local serverStart, length
	if filteringActive then
		if page <= 1 then state.pageOffsets = { [1] = 0 } end
		serverStart = state.pageOffsets[page] or ((page-1) * ROWS)
		length = ROWS + 20
	else
		serverStart = (page-1) * ROWS
		length = ROWS
	end

	state.fetchReq = FetchServerRows(serverStart, length, state.search, function(rows, recordsFiltered, err)
		if generation ~= state.fetchGen then return end
		state.fetchReq = nil
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
-- featured packs: recent releases (this year, or the last 4 months if the
-- year is young) with a banner, 20+ charts across 3+ difficulties, and a
-- wide difficulty spread in the 7-15 range.  Candidates are pulled from one
-- big date-sorted page, then qualified by fetching pack details a couple at
-- a time; the strip fills in progressively.

local FEAT_TARGET      = 8    -- stop once this many cards qualify
local FEAT_MIN_SCORE   = 4    -- distinct meters in 7..15 required to qualify
local FEAT_MAX_DETAILS = 40   -- give up after this many detail fetches
local FEAT_VISIBLE     = 4    -- cards shown at once in the strip

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

local function FeaturedQualify(pack, det)
	if not det then return nil end
	if not BannerUrlFor(pack) then return nil end
	local charts = tonumber((det.stats.charts or ""):match("%d+")) or 0
	if charts < 20 then return nil end
	if #det.labels < 3 then return nil end
	-- CSV-sourced candidates have no list date; use the detail page's year
	if pack.csvOnly and det.year ~= CurrentYear() then return nil end
	local score = FeaturedScore(det)
	if score < FEAT_MIN_SCORE then return nil end
	return score
end

local FeaturedStep  -- forward declaration (recursive via callbacks)

FeaturedStep = function()
	local f = state.featured
	if f.status ~= "loading" then return end

	while f.inFlight < 2 and f.poolPos < #f.pool
	      and #f.cards < FEAT_TARGET and f.fetched < FEAT_MAX_DETAILS do
		f.poolPos = f.poolPos + 1
		local pack = f.pool[f.poolPos]
		local cached = state.details[pack.id]
		if cached then
			local score = FeaturedQualify(pack, cached)
			if score then
				f.cards[#f.cards+1] = { pack = pack, score = score }
				RequestBanner(BannerUrlFor(pack))
			end
		else
			f.inFlight = f.inFlight + 1
			f.fetched = f.fetched + 1
			FetchDetail(pack, function(det)
				f.inFlight = f.inFlight - 1
				if f.status == "loading" then
					local score = det and FeaturedQualify(pack, det)
					if score then
						f.cards[#f.cards+1] = { pack = pack, score = score }
						RequestBanner(BannerUrlFor(pack))
					end
					FeaturedStep()
				end
				Refresh()
			end)
		end
	end

	if f.inFlight == 0 and
	   (#f.cards >= FEAT_TARGET or f.poolPos >= #f.pool or f.fetched >= FEAT_MAX_DETAILS) then
		table.sort(f.cards, function(a, b)
			if a.score ~= b.score then return a.score > b.score end
			return (a.pack.date or "") > (b.pack.date or "")
		end)
		f.status = "ready"
		Refresh()
	end
end

local function BuildFeatured()
	local f = {
		status = "loading", cards = {}, pool = {}, poolPos = 0,
		inFlight = 0, fetched = 0,
		mode = state.filterMode, builtAt = GetTimeSinceStart(),
	}
	state.featured = f
	state.featCursor = 1
	state.featWindow = 0

	if state.filterMode == "keyboard" then
		-- newest keyboard packs by id; dates are checked from detail pages
		local source = state.keyboardPacks or {}
		for i = 1, math.min(30, #source) do
			f.pool[#f.pool+1] = source[i]
		end
		FeaturedStep()
		Refresh()
		return
	end

	if not UrlAllowed() then
		f.status = "ready"
		return
	end

	-- one big newest-first page as the candidate pool
	FetchServerRows(0, 120, "", function(rows, _, err)
		if state.featured ~= f then return end  -- superseded
		if err or not rows then
			f.status = "ready"
			Refresh()
			return
		end

		local year = tostring(CurrentYear())
		local thisYear = {}
		local candidates = {}
		for pack in ivalues(rows) do
			if pack.banner and PassesFilter(pack) then
				candidates[#candidates+1] = pack
				if pack.date:sub(1, 4) == year then
					thisYear[#thisYear+1] = pack
				end
			end
		end

		if #thisYear >= 12 then
			f.pool = thisYear
		else
			-- young year: widen the window to the last four months
			local cutoff = FourMonthsAgoStr()
			for pack in ivalues(candidates) do
				if pack.date >= cutoff then
					f.pool[#f.pool+1] = pack
				end
			end
		end

		FeaturedStep()
		Refresh()
	end)
end

-- rebuild list + featured after the pad/keyboard filter changes.
-- quiet=true keeps the current toast/cursor noise down (CSV just arrived).
ApplyFilterRefetch = function(quiet)
	state.page = 1
	state.cursor = 1
	state.pageOffsets = {}
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
				dl.groups = groups
				state.needsReload = true
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
		FetchPacks(1, false)
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
		Question = "Search stepmaniaonline.net packs\n(leave empty to browse newest packs)",
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

	if state.mode == "list" then
		local isUp    = (button == "MenuUp" or button == "Up")
		local isDown  = (button == "MenuDown" or button == "Down")
		local isLeft  = (button == "MenuLeft" or button == "Left")
		local isRight = (button == "MenuRight" or button == "Right")
		local feat = state.featured

		-- shared handlers
		if button == "Select" and firstPress then
			OpenSearchPrompt()
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
			-- Left/Right cycles the pad/keyboard/all filter and applies it
			if (isLeft or isRight) and firstPress then
				local order = { "pad", "keyboard", "all" }
				local index = 1
				for i, m in ipairs(order) do
					if m == state.filterMode then index = i end
				end
				index = index + (isRight and 1 or -1)
				if index < 1 then index = #order end
				if index > #order then index = 1 end
				state.filterMode = order[index]
				PlaySfx("change")
				if state.filterMode ~= "all" then FetchPackTypes() end
				ApplyFilterRefetch()
			elseif isDown or (button == "Start" and firstPress) then
				PlaySfx("change")
				state.zone = (#feat.cards > 0 or feat.status == "loading") and "featured" or "list"
				Refresh()
			end
			return false
		end

		if state.zone == "featured" then
			if isLeft then
				if state.featCursor > 1 then
					state.featCursor = state.featCursor - 1
					if state.featCursor - 1 < state.featWindow then
						state.featWindow = state.featCursor - 1
					end
					PlaySfx("change")
					Refresh()
				end
			elseif isRight then
				if state.featCursor < #feat.cards then
					state.featCursor = state.featCursor + 1
					if state.featCursor > state.featWindow + FEAT_VISIBLE then
						state.featWindow = state.featCursor - FEAT_VISIBLE
					end
					PlaySfx("change")
					Refresh()
				else
					PlaySfx("invalid")
				end
			elseif isUp then
				PlaySfx("change")
				state.zone = "tabs"
				Refresh()
			elseif isDown then
				PlaySfx("change")
				state.zone = "list"
				Refresh()
			elseif button == "Start" and firstPress then
				local pack = CurrentPack()
				if pack then
					PlaySfx("start")
					state.selected = pack
					state.mode = "detail"
					state.songCursor = 0
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
		if isUp then
			if state.cursor > 1 then
				state.cursor = state.cursor - 1
				PlaySfx("change")
				Refresh()
			else
				-- top of the list: move up into the featured strip (or tabs)
				PlaySfx("change")
				state.zone = (#feat.cards > 0 or feat.status == "loading") and "featured" or "tabs"
				Refresh()
			end
		elseif isDown then
			if #state.packs > 0 then
				if state.cursor < #state.packs then
					state.cursor = state.cursor + 1
				elseif state.page < TotalPages() then
					state.cursor = 1
					FetchPacks(state.page + 1, true)
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
			else
				PlaySfx("invalid")
			end
		elseif button == "Start" and firstPress then
			local pack = CurrentPack()
			if pack then
				PlaySfx("start")
				state.selected = pack
				state.mode = "detail"
				state.songCursor = 0
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

		if button == "MenuUp" or button == "Up" then
			if state.songCursor > 0 then
				state.songCursor = state.songCursor - 1
				PlaySfx("change")
				Refresh()
			end
		elseif button == "MenuDown" or button == "Down" then
			if state.songCursor < maxScroll then
				state.songCursor = state.songCursor + 1
				PlaySfx("change")
				Refresh()
			end
		elseif button == "MenuLeft" or button == "Left" then
			state.songCursor = math.max(0, state.songCursor - SONG_ROWS)
			PlaySfx("change")
			Refresh()
		elseif button == "MenuRight" or button == "Right" then
			state.songCursor = Clamp(state.songCursor + SONG_ROWS, 0, maxScroll)
			PlaySfx("change")
			Refresh()
		elseif button == "Start" and firstPress then
			if pack then
				local dl = state.downloads[pack.id]
				if dl and (dl.status == "active" or dl.status == "installing") then
					PlaySfx("invalid")
					Toast("Already downloading")
				elseif dl and dl.status == "done" then
					PlaySfx("invalid")
					Toast(DownloadLoaded(dl) and "Already installed" or "Already installed - reload songs to play it")
				else
					PlaySfx("start")
					state.mode = "confirm"
					Refresh()
				end
			end
		elseif button == "Back" and firstPress then
			PlaySfx("cancel")
			state.mode = "list"
			state.selected = nil
			Refresh()
		end
		return false
	end

	if state.mode == "confirm" then
		if button == "Start" and firstPress then
			local pack = CurrentPack()
			if pack then
				PlaySfx("start")
				StartDownload(pack)
				Toast("Downloading " .. pack.name)
				if refs.heart then refs.heart:playcommand("SMOArmHeartbeat") end
			end
			state.mode = "detail"
			Refresh()
		elseif button == "Back" and firstPress then
			PlaySfx("cancel")
			state.mode = "detail"
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
local titleNumChoices = 4
local TITLE_MENU_SHIFT = 10   -- pixels to raise the native menu block

local function TitleMenuBaseY()
	-- mirrors the theme metric: ScrollerY=_screen.cy+_screen.h/3.8
	return _screen.cy + _screen.h/3.8 - TITLE_MENU_SHIFT
end

local function TitleItemY()
	-- the fixed row right below the last native choice
	return TitleMenuBaseY() + 22*titleNumChoices
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

-- refocusEngine=false leaves the native highlight alone (used when we let
-- the engine process the same event and move/wrap the selection itself)
local function TitleDefocus(refocusEngine)
	if not titleFocused then return end
	titleFocused = false
	if refocusEngine then
		TitleSetEngineChoiceFocus(TitleGetEngineIndex(), true)
	end
	if refs.titleItem then refs.titleItem:playcommand("SMOTitleUpdate") end
	if refs.titleAF then refs.titleAF:stoptweening() end
end

local function TitleFocus()
	if titleFocused then return end
	titleFocused = true
	TitleSetEngineChoiceFocus(TitleGetEngineIndex(), false)
	if refs.titleItem then
		refs.titleItem:diffusealpha(1)
		refs.titleItem:playcommand("SMOTitleUpdate")
	end
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
	local lastIndex = titleNumChoices - 1

	if not titleFocused then
		if isForward and engineIndex == lastIndex then
			-- forward past the last native choice: land on our item
			PlaySfx("change")
			TitleFocus()
			return true
		elseif isBackward and engineIndex == 0 then
			-- backward past the first native choice: wrap onto our item
			PlaySfx("change")
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
		PlaySfx("change")
		TitleDefocus(true)
		return true
	elseif isForward then
		if engineIndex == lastIndex then
			if isMenuNav then
				-- continue forward: let the engine wrap to the first choice
				TitleDefocus(false)
				return false
			end
			-- raw arrow at the end of the menu: stay on our item.  Pass the
			-- event through (the engine ignores raw arrows here) so the
			-- screen's idle timer still resets.
			return false
		else
			PlaySfx("change")
			TitleDefocus(true)
			return true
		end
	elseif isBackward then
		if engineIndex == 0 then
			if isMenuNav then
				-- continue backward: let the engine wrap to the last choice
				TitleDefocus(false)
				return false
			end
			return false
		else
			PlaySfx("change")
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
			PlaySfx("change")
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
		local wrappedForward  = isForward  and titleLastIndex >= titleNumChoices-1 and current == 0
		local wrappedBackward = isBackward and titleLastIndex == 0 and current >= titleNumChoices-1
		if wrappedForward or wrappedBackward then
			PlaySfx("change")
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

local W  = _screen.w
local H  = _screen.h
local CONTENT_TOP = 44
local CONTENT_BOT = 440
local LIST_X      = 16
local LIST_W      = math.floor(W * 0.53)
local ROW_H       = 36
local DIALOG_W    = 400
local DIALOG_H    = 170

-- vertical stack: subheader / filter tabs / featured strip / list columns
local TABS_Y      = 66
local FEAT_LABEL_Y = 82
local FEAT_TOP    = 90                          -- top of the featured cards
local FEAT_CARD_H = 88
local FEAT_GAP    = 8
local FEAT_CARD_W = math.floor((W - 2*LIST_X - (FEAT_VISIBLE-1)*FEAT_GAP) / FEAT_VISIBLE)
local LIST_TOP    = FEAT_TOP + FEAT_CARD_H + 10 -- 188
local PANE_X      = LIST_X + LIST_W + 12
local PANE_W      = W - PANE_X - 16
local PANE_H      = ROWS*ROW_H - 3              -- 249

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
			state.open = true
			state.textEntryOpen = false
			state.blockedReason = nil
			state.selected = nil
			state.zone = "list"
			-- stale UI state from a previous visit must not linger
			state.loadErr = nil
			state.loading = false
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
				-- the featured strip is where the eye should land first
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
			self:setsize(W, H):diffuse(0,0,0,0.66)
		end,
	}

	-- sub-header: context on the left, paging info on the right
	ui[#ui+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(left):xy(LIST_X, CONTENT_TOP + 10):zoom(0.62)
		end,
		SMORefreshMessageCommand = function(self)
			if state.mode == "detail" or state.mode == "reload" then
				self:settext("")
				return
			end
			if state.mode == "blocked" then
				self:settext("stepmaniaonline.net")
				self:diffuse(0.7, 0.7, 0.7, 1)
				return
			end
			if state.search ~= "" then
				self:settext("Search: \"" .. state.search .. "\"  (" .. Commify(state.filtered) .. " results)")
			else
				self:settext((FilterLabels[state.filterMode] or "Packs") .. ", newest first  -  stepmaniaonline.net")
			end
			self:diffuse(0.7, 0.7, 0.7, 1)
		end,
	}

	ui[#ui+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(right):xy(W - 16, CONTENT_TOP + 10):zoom(0.55):diffuse(0.55, 0.55, 0.55, 1)
		end,
		SMORefreshMessageCommand = function(self)
			if state.mode == "blocked" or #state.packs == 0 then
				self:settext("")
				return
			end
			self:settext("Page " .. Commify(state.page) .. "/" .. Commify(TotalPages()) .. "  -  " .. Commify(state.totalPacks) .. " packs")
		end,
	}

	-- loading spinner
	ui[#ui+1] = Def.Sprite{
		Texture = THEME:GetPathG("", "LoadingSpinner 10x3.png"),
		InitCommand = function(self)
			self:xy(W/2, H/2):zoom(0.5):visible(false)
		end,
		SMORefreshMessageCommand = function(self)
			self:visible(state.open and state.loading and (state.mode == "list") and #state.packs == 0)
		end,
	}

	-- error / empty-state text
	ui[#ui+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(LIST_X + LIST_W/2, H/2):zoom(0.7):diffuse(0.8, 0.8, 0.8, 1)
			self:wrapwidthpixels(LIST_W / 0.7)
		end,
		SMORefreshMessageCommand = function(self)
			if state.mode ~= "list" and state.mode ~= "confirm" then self:settext("") return end
			-- only overlay the error text when there is nothing else to show;
			-- transient errors over a working list surface as a toast instead
			if state.loadErr and #state.packs == 0 then
				self:settext("Could not reach stepmaniaonline.net\n(" .. tostring(state.loadErr) .. ")\n\nPress &MENULEFT; to retry")
			elseif (not state.loading) and #state.packs == 0 and state.lastFetch then
				self:settext("No packs found")
			else
				self:settext("")
			end
		end,
	}

	-- ---------------------------------------------------------------
	-- filter tabs (pad / keyboard / all)

	local tabDefs = {
		{ mode = "pad",      label = "PAD PACKS" },
		{ mode = "keyboard", label = "KEYBOARD" },
		{ mode = "all",      label = "ALL PACKS" },
	}

	local tabsAF = Def.ActorFrame{
		Name = "Tabs",
		InitCommand = function(self) self:visible(false) end,
		SMORefreshMessageCommand = function(self)
			self:visible(state.open and (state.mode == "list" or state.mode == "confirm"))
		end,
	}

	for tabIndex, tab in ipairs(tabDefs) do
		local tabX = LIST_X + (tabIndex-1) * 130

		tabsAF[#tabsAF+1] = Def.BitmapText{
			Font = "Common Normal",
			Text = tab.label,
			InitCommand = function(self)
				self:horizalign(left):xy(tabX, TABS_Y):zoom(0.62)
			end,
			SMORefreshMessageCommand = function(self)
				if state.filterMode == tab.mode then
					self:diffuse(AccentColor())
					self:zoom(state.zone == "tabs" and 0.68 or 0.62)
				else
					self:diffuse(0.45, 0.45, 0.45, 1)
					self:zoom(0.62)
				end
			end,
		}

		-- underline for the active tab
		tabsAF[#tabsAF+1] = Def.Quad{
			InitCommand = function(self)
				self:horizalign(left):xy(tabX, TABS_Y + 10):setsize(74, 2):visible(false)
			end,
			SMORefreshMessageCommand = function(self)
				if state.filterMode == tab.mode then
					self:visible(true)
					self:diffuse(AccentColor())
					self:diffusealpha(state.zone == "tabs" and 1 or 0.5)
				else
					self:visible(false)
				end
			end,
		}
	end

	-- small hint when the tab row has the cursor
	tabsAF[#tabsAF+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(right):xy(W - 16, TABS_Y):zoom(0.5):diffuse(0.55, 0.55, 0.55, 1)
		end,
		SMORefreshMessageCommand = function(self)
			if state.zone == "tabs" then
				self:settext("&MENULEFT;&MENURIGHT; change filter")
			else
				self:settext("")
			end
		end,
	}

	ui[#ui+1] = tabsAF

	-- ---------------------------------------------------------------
	-- featured strip

	local featAF = Def.ActorFrame{
		Name = "Featured",
		InitCommand = function(self) self:visible(false) end,
		SMORefreshMessageCommand = function(self)
			self:visible(state.open and (state.mode == "list" or state.mode == "confirm"))
		end,
	}

	featAF[#featAF+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(left):xy(LIST_X, FEAT_LABEL_Y):zoom(0.55)
		end,
		SMORefreshMessageCommand = function(self)
			local f = state.featured
			local label = "FEATURED " .. CurrentYear()
			if f.status == "loading" and #f.cards == 0 then
				label = label .. "   finding packs..."
			elseif f.status == "ready" and #f.cards == 0 then
				label = label .. "   nothing qualifying right now"
			elseif #f.cards > FEAT_VISIBLE then
				label = label .. string.format("   %d/%d", state.featCursor, #f.cards)
			end
			self:settext(label)
			self:diffuse(AccentColor())
		end,
	}

	for slot = 1, FEAT_VISIBLE do
		local cardX = LIST_X + (slot-1) * (FEAT_CARD_W + FEAT_GAP)

		local card = Def.ActorFrame{
			InitCommand = function(self) self:xy(cardX, FEAT_TOP) end,

			-- focus border
			Def.Quad{
				InitCommand = function(self)
					self:vertalign(top):horizalign(left)
					self:xy(-2, -2):setsize(FEAT_CARD_W + 4, FEAT_CARD_H + 4):visible(false)
				end,
				SMORefreshMessageCommand = function(self)
					local index = state.featWindow + slot
					local focused = (state.zone == "featured" and index == state.featCursor)
					self:visible(focused and state.featured.cards[index] ~= nil)
					self:diffuse(AccentColor())
				end,
			},

			-- card background: opaque dark when focused so the accent quad
			-- behind it reads as a 2px rim rather than flooding the card
			Def.Quad{
				InitCommand = function(self)
					self:vertalign(top):horizalign(left)
					self:setsize(FEAT_CARD_W, FEAT_CARD_H)
				end,
				SMORefreshMessageCommand = function(self)
					local index = state.featWindow + slot
					local card = state.featured.cards[index]
					self:visible(card ~= nil)
					if state.zone == "featured" and index == state.featCursor then
						self:diffuse(0.07, 0.07, 0.07, 1)
					else
						self:diffuse(1, 1, 1, 0.06)
					end
				end,
			},

			-- banner
			Def.Sprite{
				InitCommand = function(self)
					self:xy(FEAT_CARD_W/2, 27)
				end,
				SMORefreshMessageCommand = function(self) self:playcommand("SMOSetBanner") end,
				SMOBannerReadyMessageCommand = function(self) self:playcommand("SMOSetBanner") end,
				SMOSetBannerCommand = function(self)
					local index = state.featWindow + slot
					local card = state.featured.cards[index]
					local pack = card and card.pack
					local url = pack and BannerUrlFor(pack)
					local path = url and state.banners[url]
					local key = "feat" .. slot
					if pack and path then
						if loadedBanner[key] ~= path then
							self:Load(path)
							loadedBanner[key] = path
						end
						FitSprite(self, FEAT_CARD_W - 10, 50)
						self:visible(true)
					else
						self:visible(false)
						if url then RequestBanner(url) end
					end
				end,
			},

			-- pack name
			Def.BitmapText{
				Font = "Common Normal",
				InitCommand = function(self)
					self:xy(FEAT_CARD_W/2, 63):zoom(0.52):maxwidth((FEAT_CARD_W - 10)/0.52)
				end,
				SMORefreshMessageCommand = function(self)
					local index = state.featWindow + slot
					local card = state.featured.cards[index]
					if not card then self:settext("") return end
					self:settext(card.pack.name)
					if state.zone == "featured" and index == state.featCursor then
						self:diffuse(AccentColor())
					else
						self:diffuse(1, 1, 1, 1)
					end
				end,
			},

			-- songs / difficulty summary
			Def.BitmapText{
				Font = "Common Normal",
				InitCommand = function(self)
					self:xy(FEAT_CARD_W/2, 77):zoom(0.42):diffuse(0.6, 0.6, 0.6, 1)
					self:maxwidth((FEAT_CARD_W - 10)/0.42)
				end,
				SMORefreshMessageCommand = function(self)
					local index = state.featWindow + slot
					local card = state.featured.cards[index]
					if not card then self:settext("") return end
					local det = state.details[card.pack.id]
					local bits = {}
					if card.pack.songs and card.pack.songs > 0 then
						bits[#bits+1] = card.pack.songs .. " songs"
					end
					if det and #det.labels > 0 then
						bits[#bits+1] = "diff " .. det.labels[1] .. "-" .. det.labels[#det.labels]
					end
					self:settext(table.concat(bits, "  -  "))
				end,
			},
		}

		featAF[#featAF+1] = card
	end

	ui[#ui+1] = featAF

	-- ---------------------------------------------------------------
	-- LIST VIEW: rows

	local listAF = Def.ActorFrame{
		Name = "List",
		SMORefreshMessageCommand = function(self)
			self:visible(state.open and (state.mode == "list" or state.mode == "confirm"))
		end,
	}

	for i = 1, ROWS do
		local rowY = LIST_TOP + (i-1)*ROW_H

		local row = Def.ActorFrame{
			InitCommand = function(self)
				self:xy(LIST_X, rowY)
				refs.rows[i] = self
			end,

			-- focus background
			Def.Quad{
				InitCommand = function(self)
					self:vertalign(top):horizalign(left)
					self:setsize(LIST_W, ROW_H - 3)
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

			-- banner thumbnail
			Def.Sprite{
				InitCommand = function(self)
					self:xy(42, (ROW_H-3)/2)
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
						FitSprite(self, 76, ROW_H - 9)
						self:visible(true)
					else
						self:visible(false)
						if url then RequestBanner(url) end
					end
				end,
			},

			-- pack name
			Def.BitmapText{
				Font = "Common Normal",
				InitCommand = function(self)
					self:horizalign(left):xy(88, 11):zoom(0.72):maxwidth((LIST_W - 176)/0.72)
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
					self:maxwidth((LIST_W - 176)/0.5)
				end,
				SMORefreshMessageCommand = function(self)
					local pack = state.packs[i]
					if not pack then self:settext("") return end
					local bits = {}
					if pack.songs > 0 then bits[#bits+1] = pack.songs .. " songs" end
					if pack.sizeStr ~= "" then bits[#bits+1] = pack.sizeStr end
					if pack.date ~= "" then bits[#bits+1] = pack.date end
					if #pack.types > 0 then bits[#bits+1] = table.concat(pack.types, "/") end
					self:settext(table.concat(bits, "  -  "))
				end,
			},

			-- right-aligned status badge
			Def.BitmapText{
				Font = "Common Normal",
				InitCommand = function(self)
					self:horizalign(right):xy(LIST_W - 8, (ROW_H-3)/2):zoom(0.5)
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
		InitCommand = function(self) self:xy(PANE_X, LIST_TOP):visible(false) end,
		SMORefreshMessageCommand = function(self)
			self:visible(state.open and (state.mode == "list" or state.mode == "confirm") and CurrentPack() ~= nil)
		end,
	}

	pane[#pane+1] = Def.Quad{
		InitCommand = function(self)
			self:vertalign(top):horizalign(left)
			self:setsize(PANE_W, PANE_H):diffuse(1, 1, 1, 0.07)
		end,
	}

	pane[#pane+1] = Def.Sprite{
		InitCommand = function(self) self:xy(PANE_W/2, 38) end,
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
				FitSprite(self, PANE_W - 40, 62)
				self:visible(true)
			else
				self:visible(false)
				if url then RequestBanner(url) end
			end
		end,
	}

	pane[#pane+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(PANE_W/2, 84):zoom(0.7):maxwidth((PANE_W - 24)/0.7)
		end,
		SMORefreshMessageCommand = function(self)
			local pack = CurrentPack()
			self:settext(pack and pack.name or "")
			self:diffuse(1, 1, 1, 1)

			-- lazy-load details for the highlighted pack while browsing
			-- (only while the browser is actually open and in the list view)
			if pack and state.open and (state.mode == "list" or state.mode == "confirm") then
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
			local date = pack.date
			if date == "" and det then date = det.date or "" end
			return (date ~= "") and ("added " .. date) or ""
		end,
		function(pack, det)
			if det and det.author then return "charts by " .. det.author end
			if state.detailBusy[pack.id] then return "loading details..." end
			return ""
		end,
	}

	for lineIndex, textFn in ipairs(infoLines) do
		pane[#pane+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:xy(PANE_W/2, 98 + lineIndex*14):zoom(0.5):diffuse(0.75, 0.75, 0.75, 1)
				self:maxwidth((PANE_W - 24)/0.5)
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
	local HIST_H = 52
	local HIST_Y = 226  -- baseline within the pane
	local HIST_W = PANE_W - 48

	for barIndex = 1, HIST_MAX_BARS do
		pane[#pane+1] = Def.Quad{
			InitCommand = function(self)
				self:vertalign(bottom):visible(false)
				refs.bars[barIndex] = self
			end,
			SMORefreshMessageCommand = function(self)
				local pack = CurrentPack()
				local det = pack and state.details[pack.id]
				local visible = (state.mode == "list" or state.mode == "confirm")
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
				self:xy(x0 + (barIndex-1)*(barW+2), HIST_Y)
				self:setsize(barW, math.max(2, det.counts[barIndex] / maxCount * HIST_H))
				self:diffuse(AccentColor())
				self:diffusealpha(0.9)
			end,
		}
	end

	pane[#pane+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(PANE_W/2, PANE_H - 11):zoom(0.45):diffuse(0.6, 0.6, 0.6, 1)
		end,
		SMORefreshMessageCommand = function(self)
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
			self:visible(state.open and state.mode == "detail")
		end,
	}

	local DET_LEFT_W = math.floor(W * 0.38)
	local DET_SONGS_X = DET_LEFT_W + 32
	local DET_SONGS_W = W - DET_SONGS_X - 20
	local SONG_ROW_H = 32
	local SONG_TOP = 70

	-- left column: banner + stats + histogram
	detail[#detail+1] = Def.Sprite{
		InitCommand = function(self) self:xy(16 + DET_LEFT_W/2, 105) end,
		SMORefreshMessageCommand = function(self) self:playcommand("SMOSetBanner") end,
		SMOBannerReadyMessageCommand = function(self) self:playcommand("SMOSetBanner") end,
		SMOSetBannerCommand = function(self)
			local pack = CurrentPack()
			local url = pack and BannerUrlFor(pack)
			local path = url and state.banners[url]
			if pack and path and state.mode == "detail" then
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
			local bits = {}
			local date = pack.date
			if date == "" and det then date = det.date or "" end
			if date ~= "" then bits[#bits+1] = "added " .. date end
			if #pack.types > 0 then bits[#bits+1] = table.concat(pack.types, "/") end
			return table.concat(bits, "   -   ")
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
				if not (state.mode == "detail" and det and #det.counts > 0 and barIndex <= #det.counts) then
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
				self:diffuse(AccentColor())
				self:diffusealpha(0.9)
			end,
		}
	end

	detail[#detail+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(16 + DET_LEFT_W/2, BHIST_Y + 12):zoom(0.5):diffuse(0.6, 0.6, 0.6, 1)
		end,
		SMORefreshMessageCommand = function(self)
			local pack = CurrentPack()
			local det = pack and state.details[pack.id]
			if state.mode == "detail" and det and #det.labels > 0 then
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
				local firstShown = state.songCursor + 1
				local lastShown = math.min(state.songCursor + SONG_ROWS, #det.songs)
				self:settext("Songs  " .. firstShown .. "-" .. lastShown .. " of " .. #det.songs)
			elseif pack and state.detailBusy[pack.id] then
				self:settext("Loading song list...")
			else
				self:settext("")
			end
		end,
	}

	for i = 1, SONG_ROWS do
		local rowY = SONG_TOP + (i-1)*SONG_ROW_H

		detail[#detail+1] = Def.Quad{
			InitCommand = function(self)
				self:vertalign(top):horizalign(left)
				self:xy(DET_SONGS_X - 6, rowY - 2):setsize(DET_SONGS_W + 12, SONG_ROW_H - 3)
				self:diffuse(1, 1, 1, 0.05)
			end,
			SMORefreshMessageCommand = function(self)
				local pack = CurrentPack()
				local det = pack and state.details[pack.id]
				self:visible(det ~= nil and det.songs[state.songCursor + i] ~= nil)
			end,
		}

		detail[#detail+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(left):xy(DET_SONGS_X, rowY + 6):zoom(0.58)
				self:maxwidth((DET_SONGS_W - 90)/0.58)
			end,
			SMORefreshMessageCommand = function(self)
				local pack = CurrentPack()
				local det = pack and state.details[pack.id]
				local song = det and det.songs[state.songCursor + i]
				if song then
					self:settext(song.title)
				else
					self:settext("")
				end
			end,
		}

		detail[#detail+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(left):xy(DET_SONGS_X, rowY + 20):zoom(0.45):diffuse(0.6, 0.6, 0.6, 1)
				self:maxwidth((DET_SONGS_W - 90)/0.45)
			end,
			SMORefreshMessageCommand = function(self)
				local pack = CurrentPack()
				local det = pack and state.details[pack.id]
				local song = det and det.songs[state.songCursor + i]
				if song then
					local bits = {}
					if song.artist ~= "" then bits[#bits+1] = song.artist end
					if song.bpm ~= "" then bits[#bits+1] = song.bpm .. " bpm" end
					if song.length ~= "" then bits[#bits+1] = song.length end
					if song.credit ~= "" then bits[#bits+1] = song.credit end
					self:settext(table.concat(bits, "  -  "))
				else
					self:settext("")
				end
			end,
		}

		detail[#detail+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(right):xy(DET_SONGS_X + DET_SONGS_W, rowY + 13):zoom(0.6)
			end,
			SMORefreshMessageCommand = function(self)
				local pack = CurrentPack()
				local det = pack and state.details[pack.id]
				local song = det and det.songs[state.songCursor + i]
				if song and song.meters ~= "" then
					self:settext(song.meters)
					self:diffuse(AccentColor())
				else
					self:settext("")
				end
			end,
		}
	end

	-- ---------------------------------------------------------------
	-- footer hints

	ui[#ui+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(W/2, CONTENT_BOT + 15):zoom(0.55):diffuse(0.75, 0.75, 0.75, 1):maxwidth((W - 20)/0.55)
		end,
		SMORefreshMessageCommand = function(self)
			if state.mode == "list" then
				if state.zone == "tabs" then
					self:settext("&MENULEFT;&MENURIGHT; filter    &MENUDOWN; browse    &SELECT; search    &BACK; exit")
				elseif state.zone == "featured" then
					self:settext("&MENULEFT;&MENURIGHT; featured    &MENUUP; filter    &MENUDOWN; all packs    &START; details    &BACK; exit")
				else
					self:settext("&MENUUP;&MENUDOWN; browse    &MENULEFT;&MENURIGHT; page    &START; details    &SELECT; search    &BACK; exit")
				end
			elseif state.mode == "detail" then
				self:settext("&MENUUP;&MENUDOWN; songs    &START; download    &BACK; back to list")
			elseif state.mode == "blocked" then
				self:settext("&BACK; back to the title menu")
			elseif state.mode == "confirm" or state.mode == "reload" then
				self:settext("&START; confirm    &BACK; cancel")
			else
				self:settext("")
			end
		end,
	}

	ui[#ui+1] = listAF
	ui[#ui+1] = pane
	ui[#ui+1] = detail

	-- ---------------------------------------------------------------
	-- modal dialogs (network warning / confirm / reload)

	local function DialogFrame(name, visibleFn, bodyFn)
		local dialog = Def.ActorFrame{
			Name = name,
			InitCommand = function(self) self:xy(W/2, H/2):visible(false) end,
			SMORefreshMessageCommand = function(self)
				self:visible(state.open and not state.textEntryOpen and visibleFn())
			end,

			Def.Quad{ InitCommand=function(self) self:setsize(DIALOG_W + 4, DIALOG_H + 4):diffuse(1, 1, 1, 1) end },
			Def.Quad{ InitCommand=function(self) self:setsize(DIALOG_W, DIALOG_H):diffuse(0, 0, 0, 1) end },

			Def.BitmapText{
				Font = "Common Normal",
				InitCommand = function(self)
					self:y(-DIALOG_H/2 + 24):zoom(0.75)
				end,
				SMORefreshMessageCommand = function(self)
					local title, _ = bodyFn()
					self:settext(title or "")
					self:diffuse(AccentColor())
				end,
			},

			Def.BitmapText{
				Font = "Common Normal",
				InitCommand = function(self)
					self:y(10):zoom(0.58):diffuse(0.9, 0.9, 0.9, 1)
					self:wrapwidthpixels((DIALOG_W - 40)/0.58)
				end,
				SMORefreshMessageCommand = function(self)
					local _, body = bodyFn()
					self:settext(body or "")
				end,
			},
		}
		return dialog
	end

	af[#af+1] = ui

	af[#af+1] = DialogFrame("NetworkWarningDialog",
		function() return state.mode == "blocked" end,
		function()
			local reason = state.blockedReason or "Network access is not enabled."
			local fix = "Run the Find Content installer again, or -- with ITGmania closed -- double-click  Enable Network Access.bat  in Themes/Simply Love/Modules/"
			return "Network Access Not Enabled", reason .. "\n\n" .. fix .. "\n\n&BACK; back to the title menu"
		end)

	af[#af+1] = DialogFrame("ConfirmDialog",
		function() return state.mode == "confirm" end,
		function()
			local pack = CurrentPack()
			if not pack then return "", "" end
			local body = pack.name .. "\n" .. pack.sizeStr .. "  -  " .. pack.songs .. " songs"
			if SONGMAN:DoesSongGroupExist(pack.name) then
				body = body .. "\n(a pack with this name is already in your library)"
			end
			body = body .. "\n\n&START; download    &BACK; cancel"
			return "Download Pack?", body
		end)

	af[#af+1] = DialogFrame("ReloadDialog",
		function() return state.mode == "reload" end,
		function()
			return "New Packs Installed",
				"Reload songs now so your new packs show up?\n\n&START; reload songs    &BACK; not yet"
		end)

	-- ---------------------------------------------------------------
	-- toast

	af[#af+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(W/2, CONTENT_BOT - 8):zoom(0.6):diffusealpha(0)
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
	return Def.ActorFrame{
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
			end

			self:playcommand("SMOTitleEnter")
		end,

		Def.BitmapText{
			Font = "Common Bold",
			Text = "Find Content",
			InitCommand = function(self)
				refs.titleItem = self
				self:shadowlength(0.5)
				self:zoom(0.4)
				self:diffusealpha(0)
			end,

			SMOTitleEnterCommand = function(self)
				self:finishtweening()
				self:playcommand("SMOTitleUpdate")
				-- match the staggered fade-in of the native choices
				self:diffusealpha(0):sleep(titleNumChoices*0.075):linear(0.2):diffusealpha(1)
			end,

			SMOTitleUpdateCommand = function(self)
				self:xy(_screen.cx, TitleItemY())

				if titleFocused then
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

			-- fade out alongside the native choices when leaving the screen
			SMOTitleLeaveCommand = function(self)
				self:stoptweening()
				self:sleep(titleNumChoices*0.075):linear(0.18):diffusealpha(0)
			end,
		},
	}
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
