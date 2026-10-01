-- -----------------------------------------------------------------------
-- Asking the catalogue for pages of packs
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local BannerUrlFor    = CB.BannerUrlFor
local Clamp           = CB.Clamp
local FormatBytes     = CB.FormatBytes
local NormalizeName   = CB.NormalizeName
local ParsePackRow    = CB.ParsePackRow
local PassesFilter    = CB.PassesFilter
local PrefetchBanners = CB.PrefetchBanners
local ROWS            = CB.ROWS
local Refresh         = CB.Refresh
local RequestBanner   = CB.RequestBanner
local SMO_BASE        = CB.SMO_BASE
local Toast           = CB.Toast
local Trim            = CB.Trim
local UrlAllowed      = CB.UrlAllowed
local state           = CB.state

-- These are filled in by a part that loads AFTER this one, so they cannot
-- be copied here -- the copy would be the nil they hold right now, forever.
-- Reached through the shared table at call time instead.
local function ApplyFilterRefetch(...) return CB.ApplyFilterRefetch(...) end
local function RefreshLevelView(...) return CB.RefreshLevelView(...) end
local function Upstream(...) return CB.Upstream(...) end

-- one page of rows from the datatables endpoint, newest first.
-- cb(rows, recordsFiltered) on success, cb(nil, nil, errmsg) on failure.
local function FetchServerRows(serverStart, length, search, cb, extra)
	local params = {
		["draw"]   = "1",
		["start"]  = tostring(serverStart),
		["length"] = tostring(length),
		["search[value]"]     = search or "",
		["order[0][column]"]  = "5",     -- date column
		["order[0][dir]"]     = "desc",  -- newest first
	}
	-- the pack browser's own filters, which its table sends the same way
	for key, value in pairs(extra or {}) do params[key] = value end
	local query = NETWORK:EncodeQueryParameters(params)
	return NETWORK:HttpRequest{
		url = Upstream(SMO_BASE .. "/api/packs/datatables?" .. query),
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

FetchPackTypes = function()
	if state.packTypes or state.packTypesBusy then return end
	if not UrlAllowed() then return end
	state.packTypesBusy = true
	NETWORK:HttpRequest{
		url = Upstream(SMO_BASE .. "/api/packs"),
		connectTimeout = 10,
		transferTimeout = 60,
		onResponse = function(response)
			state.packTypesBusy = false
			if response.error ~= nil or response.statusCode ~= 200 then
				-- Remembered, because more than the keyboard list waits on this
				-- now: the doubles join is itgdb's names looked up in this
				-- catalogue, and with none it has nothing to look them up in.
				-- A view that knows the fetch failed can say so; one that only
				-- knows the data is missing can only keep spinning.
				state.packTypesFailed = true
				-- keyboard mode depends entirely on this data; surface the
				-- failure instead of spinning forever
				if state.filterMode == "keyboard" and state.open then
					state.loading = false
					state.loadErr = "could not load pack type data"
					Refresh()
				end
				if RefreshLevelView then RefreshLevelView() end
				Refresh()
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

			state.packTypesFailed = false
			state.packTypes = types
			-- Pages kept before these arrived were cut without the pad filter,
			-- which needs them, so none of them can be served now. (They are
			-- asked for first and usually land first; this is for a retry.)
			state.pageCache = {}
			state.pageOffsets = {}
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
	-- the next page's art, queued behind this one's
	for i = page * ROWS + 1, math.min((page + 1) * ROWS, #rows) do
		RequestBanner(BannerUrlFor(rows[i]))
	end
end

-- ---------------------------------------------------------------
-- server pages: a window at a time, and the next one fetched ahead
--
-- Every new page of the pad list used to be its own request, and the list
-- waited at each page boundary for as long as SMO took to answer -- a quarter
-- to half a second, more while the featured grid's lookups were ahead of it
-- in the engine's one-at-a-time queue. The answer was 27 rows, of which one
-- page's seven were kept.
--
-- SMO answers a hundred rows about as quickly as 27 (it is the query that
-- costs, not the size), so one request now brings a window of WINDOW_ROWS,
-- and every full page in it is kept: turning to one is a lookup. Not every row
-- makes the list -- measured at the top of SMO in September 2026, two thirds
-- did, most of the rest for having no banner, and the newest rows are the
-- sparsest -- so a window is counted in rows, and 96 of them have made six to
-- ten pages. Two pages before a window runs out, the next is asked for in the
-- background, so it is usually in before the key that needs it; a player who
-- gets there first waits on that request rather than a second one behind it.
local WINDOW_ROWS = 96

-- a background fetch older than this is taken to be lost
local PREFETCH_EXPIRES = 30

local function PageKey(page)
	return tostring(state.filterMode) .. "|" .. tostring(state.search) .. "|" .. tostring(page)
end

-- Cut a window of server rows into pages, from page on. Every full page is
-- kept, with where the page after it starts in the server's ordering. What is
-- left after the last full page is not a page -- the next window starts with
-- it -- unless the list ends in this window, or nothing in it made a full
-- page, and then it is one. Returns how many pages were kept.
local function KeepWindow(rows, serverStart, page, total)
	local atEnd = serverStart + #rows >= (tonumber(total) or 0)
	local kept, current = 0, {}
	for index, pack in ipairs(rows) do
		if PassesFilter(pack) then
			current[#current+1] = pack
			if #current >= ROWS then
				state.pageCache[PageKey(page + kept)] = { packs = current, total = total, next = serverStart + index }
				state.pageOffsets[page + kept + 1] = serverStart + index
				kept, current = kept + 1, {}
			end
		end
	end
	if #current > 0 and (atEnd or kept == 0) then
		state.pageCache[PageKey(page + kept)] = { packs = current, total = total, next = serverStart + #rows }
		state.pageOffsets[page + kept + 1] = serverStart + #rows
		kept = kept + 1
	end
	return kept
end

-- The rows after a page in the window it came from, kept to backfill it when
-- one of its own is dropped (DropPackByBanner).
local function SpareAfter(rows, serverStart, page)
	local spare = {}
	local from = (state.pageOffsets[page + 1] or (serverStart + #rows)) - serverStart
	for index = from + 1, #rows do
		if PassesFilter(rows[index]) then spare[#spare+1] = rows[index] end
	end
	return spare
end

local function PageFailed(err)
	state.loading = false
	state.loadErr = err
	-- an optimistic cursor move (page crossing) may point past the end of the
	-- still-displayed page; pull it back in bounds
	state.cursor = Clamp(state.cursor, 1, math.max(1, #state.packs))
	if #state.packs > 0 then
		Toast("Could not reach stepmaniaonline.net")
	end
	Refresh()
end

-- The background fetch, while it still belongs to the list on screen. A list
-- rebuilt meanwhile has new cache tables; a fetch that was cancelled never
-- answers at all (FetchServerRows drops a Cancelled reply), so it expires.
local function LiveJob()
	local job = state.prefetch
	if job and job.cache == state.pageCache and job.offsets == state.pageOffsets
	   and GetTimeSinceStart() - job.at < PREFETCH_EXPIRES then
		return job
	end
	return nil
end

local ShowKept, LookAhead  -- each calls the other; defined below

-- Fetch the window that starts at page (row start in the server's ordering),
-- without touching the page on screen.
local function PrefetchWindow(page, start)
	if LiveJob() or not UrlAllowed() then return end
	-- nowhere known to start from, or nothing past the end
	if not start or start >= (tonumber(state.filtered) or 0) then return end
	local job = {
		key = PageKey(page), page = page, at = GetTimeSinceStart(),
		cache = state.pageCache, offsets = state.pageOffsets,
	}
	state.prefetch = job
	job.req = FetchServerRows(start, WINDOW_ROWS, state.search, function(rows, total, err)
		if state.prefetch == job then state.prefetch = nil end
		-- adopted: the player reached this page first and is waiting on it
		local adopted = job.req ~= nil and state.fetchReq == job.req
		if adopted then state.fetchReq = nil end
		if state.pageCache ~= job.cache or state.pageOffsets ~= job.offsets then return end
		if err then
			if adopted then PageFailed(err) end
			return
		end
		if KeepWindow(rows, start, page, total) == 0 then
			state.pageCache[job.key] = { packs = {}, total = total, next = start + #rows }
			state.pageOffsets[page + 1] = start + #rows
		end
		if adopted and state.awaitPage == page then
			state.awaitPage = nil
			state.lastFetch = GetTimeSinceStart()
			ShowKept(page, state.awaitKeepCursor, SpareAfter(rows, start, page))
		elseif not state.localRows and state.filterMode ~= "keyboard" then
			-- the next page's art may only now be known
			LookAhead(state.page)
		end
	end)
end

-- What the player is likely to want next: the next page's art, and the next
-- window while there is still a page in hand to read -- asked for from the
-- first of the next two pages not held yet, starting where the page before
-- it ends.
LookAhead = function(page)
	local nextKept = state.pageCache[PageKey(page + 1)]
	if nextKept then
		for pack in ivalues(nextKept.packs) do
			RequestBanner(BannerUrlFor(pack))
		end
	end
	for ahead = page + 1, page + 2 do
		if not state.pageCache[PageKey(ahead)] then
			local before = state.pageCache[PageKey(ahead - 1)]
			PrefetchWindow(ahead, before and before.next or state.pageOffsets[ahead])
			return
		end
	end
end

-- Put a kept page on screen. spare is what may backfill it.
ShowKept = function(page, keepCursor, spare)
	local kept = state.pageCache[PageKey(page)]
	-- Where the next page starts goes with the page, because the offsets are
	-- cleared without the pages when the view is rebuilt (a tab switched off
	-- and back): without it the next window would have nowhere to start.
	if kept.next then state.pageOffsets[page + 1] = kept.next end
	state.packs      = kept.packs
	state.packsSpare = spare or {}
	state.page       = page
	state.totalPacks = kept.total
	state.filtered   = kept.total
	state.cursor     = keepCursor and Clamp(state.cursor, 1, math.max(1, #kept.packs)) or 1
	state.loading    = false
	state.loadErr    = nil
	Refresh()
	PrefetchBanners()
	LookAhead(page)
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

	-- A page fetched once is served from what was kept. Paging back through a
	-- list should not re-ask the server for rows nobody has changed, and on a
	-- queue that runs one request at a time it also stops a fast scroll back
	-- through five pages from putting five requests in front of the banners
	-- and pack pages the rows on screen are waiting for.
	--
	-- The keys carry the filter and the search because those are what change
	-- the answer; the whole lot is dropped when either does, and a refresh on
	-- page 1 drops it deliberately.
	local cacheKey = PageKey(page)
	if state.pageCache[cacheKey] then
		if state.fetchReq then state.fetchReq:Cancel() state.fetchReq = nil end
		-- a request still in flight must not land on top of this
		state.fetchGen = state.fetchGen + 1
		-- the over-fetched spare belonged to that fetch, not to this page
		ShowKept(page, keepCursor, {})
		return
	end

	if not UrlAllowed() then return end
	if state.fetchReq then state.fetchReq:Cancel() state.fetchReq = nil end

	state.fetchGen = state.fetchGen + 1
	local generation = state.fetchGen

	state.loading = true
	state.loadErr = nil

	-- Already on its way in the background (LookAhead): wait for that rather
	-- than ask again behind it. Holding its handle as the page request is what
	-- makes navigation wait for it, the way it waits for any page.
	local job = LiveJob()
	if job and job.key == cacheKey and job.req then
		state.fetchReq = job.req
		state.awaitPage, state.awaitKeepCursor = page, keepCursor
		Refresh()
		return
	end
	Refresh()

	-- In pad mode keyboard-tagged packs are dropped client-side, so each UI
	-- page's start in the server's ordering is tracked as the windows land.
	if page <= 1 then state.pageOffsets = { [1] = 0 } end
	local serverStart = state.pageOffsets[page] or ((page-1) * ROWS)

	local req
	req = FetchServerRows(serverStart, WINDOW_ROWS, state.search, function(rows, recordsFiltered, err)
		-- only if the handle is still ours: a superseded request must never
		-- nil out the one that replaced it
		if state.fetchReq == req then state.fetchReq = nil end
		if generation ~= state.fetchGen then return end
		if err then
			PageFailed(err)
			return
		end
		-- Keep the pagefuls that pass the filter, each capped at ROWS. The
		-- screen draws ROWS slots and the cursor logic trusts #state.packs, so
		-- an uncapped page let Down walk the cursor into rows nothing drew,
		-- while the page refused to turn.
		if KeepWindow(rows, serverStart, page, recordsFiltered) == 0 then
			state.pageCache[cacheKey] = { packs = {}, total = recordsFiltered, next = serverStart + #rows }
			state.pageOffsets[page + 1] = serverStart + #rows
		end
		state.lastFetch = GetTimeSinceStart()
		ShowKept(page, keepCursor, SpareAfter(rows, serverStart, page))
	end)
	state.fetchReq = req
end

-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.FetchPackTypes  = FetchPackTypes
CB.FetchPacks      = FetchPacks
CB.FetchServerRows = FetchServerRows
