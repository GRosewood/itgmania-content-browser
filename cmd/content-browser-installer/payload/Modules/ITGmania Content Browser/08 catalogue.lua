-- -----------------------------------------------------------------------
-- Asking the catalogue for pages of packs
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local Clamp           = CB.Clamp
local FormatBytes     = CB.FormatBytes
local NormalizeName   = CB.NormalizeName
local ParsePackRow    = CB.ParsePackRow
local PassesFilter    = CB.PassesFilter
local PrefetchBanners = CB.PrefetchBanners
local ROWS            = CB.ROWS
local Refresh         = CB.Refresh
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

	-- A page fetched once is served from what was kept. Paging back through a
	-- list should not re-ask the server for rows nobody has changed, and on a
	-- queue that runs one request at a time it also stops a fast scroll back
	-- through five pages from putting five requests in front of the banners
	-- and pack pages the rows on screen are waiting for.
	--
	-- The keys carry the filter and the search because those are what change
	-- the answer; the whole lot is dropped when either does, and a refresh on
	-- page 1 drops it deliberately.
	local cacheKey = tostring(state.filterMode) .. "|" .. tostring(state.search)
		.. "|" .. tostring(page)
	local kept = state.pageCache[cacheKey]
	if kept then
		if state.fetchReq then state.fetchReq:Cancel() state.fetchReq = nil end
		-- a request still in flight must not land on top of this
		state.fetchGen = state.fetchGen + 1
		state.packs      = kept.packs
		-- the over-fetched spare belonged to that fetch, not to this page
		state.packsSpare = {}
		state.page       = page
		state.totalPacks = kept.total
		state.filtered   = kept.total
		state.cursor     = keepCursor and Clamp(state.cursor, 1, math.max(1, #kept.packs)) or 1
		state.loading    = false
		state.loadErr    = nil
		Refresh()
		PrefetchBanners()
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
	if page <= 1 then state.pageOffsets = { [1] = 0 } end
	local serverStart = state.pageOffsets[page] or ((page-1) * ROWS)
	local length = ROWS + 20

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
		state.pageCache[cacheKey] = { packs = packs, total = recordsFiltered }
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

-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.FetchPackTypes  = FetchPackTypes
CB.FetchPacks      = FetchPacks
CB.FetchServerRows = FetchServerRows
