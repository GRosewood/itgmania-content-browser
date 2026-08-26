-- -----------------------------------------------------------------------
-- Search
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local FetchPacks      = CB.FetchPacks
local FetchServerRows = CB.FetchServerRows
local PassesFilter    = CB.PassesFilter
local Refresh         = CB.Refresh
local SMO_BASE        = CB.SMO_BASE
local Toast           = CB.Toast
local Trim            = CB.Trim
local state           = CB.state

-- One text box that has to find a pack by its name, by a chart author, or by a
-- song inside it.  The site cannot do that in one request:
--   * the pack list's search[value] matches the pack NAME only, but the rows it
--     returns are complete (banner, date, size, song count);
--   * /api/search/?type=credit and ?type=title match charters and song titles,
--     but return only pack ids and names -- no date, no banner, no size.
-- So this runs the name search first and paints from it immediately, then fills
-- in the deeper matches by resolving their ids against the pack CSV that the
-- pad/keyboard filter already downloads.  No extra catalogue fetch is needed.
-- These two live in later parts, so they are reached through the shared
-- table at call time: Upstream in the library part, the index kick in the
-- featured-pool part.
local function Upstream(...) return CB.Upstream(...) end
local function EnsureRecentIndex(...) return CB.EnsureRecentIndex(...) end

local SEARCH = {
	MIN_CHARS = 2,
	MAX_ROWS  = 200,
	TIER1_LEN = 60,
	-- How many partial-credit packs one search may verify against the actual
	-- simfiles, via the helper. Each verification is one ranged read per song
	-- on the helper's side, so the chain runs one pack at a time, smallest
	-- pack first -- the cheap answers land in seconds and a megapack that was
	-- never going to change tier goes last, if at all.
	VERIFY_MAX = 32,
}

local SearchScores = {
	name_prefix = 100,
	name_match  = 80,
	credit      = 60,
	title       = 40,
	-- A charter who wrote MOST of a pack made that pack; one who put a single
	-- file in a 190-song megapack merely appears in it. The credit search
	-- reports both matching_songs and songs_count, so the two cases can be
	-- told apart -- but they are a boundary, not a scale. Scoring the share
	-- proportionally turned out to rank by pack SIZE: two-of-three charts beat
	-- sixty-of-a-hundred, which is the denominator talking, not the author.
	-- So majority authorship is one flat tier -- every pack the charter made
	-- scores the same, and the date tiebreak in SearchPublish puts the newest
	-- of them first -- while partial contributions take a proportional bonus
	-- underneath, where a forty-percent hand still outranks a cameo.
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

-- What the simfiles say, applied over what the catalogue guessed.
--
-- The catalogue's per-chart credit index is sparse for older packs: a pack
-- that is entirely one charter's work can show a single credited chart there,
-- which filed it in the cameo tier with a why-line that read like an
-- accusation. The simfiles are the account that can be trusted, and the
-- helper reads them out of the pack archive on request.
--
-- The rule an uncredited chart gets is "unknown", never "somebody else's":
-- a pack is majority-tier when the matched charts are a true majority, OR
-- when every credit that exists in the pack belongs to the searched charter
-- -- nothing in the pack contradicts their authorship, and the only evidence
-- there is points at them.
local function CreditTruth(acc, id)
	local entry = acc.byId[id]
	local cred = state.packCredits[id]
	if not (entry and cred) then return end

	local total = tonumber(cred.total) or 0
	local known = tonumber(cred.credited) or 0
	local matched = 0
	for name, count in pairs(cred.credits or {}) do
		if tostring(name):lower():find(acc.needle, 1, true) then
			matched = matched + (tonumber(count) or 0)
		end
	end
	if matched == 0 or total == 0 then return end

	local majority = (matched * 2 > total) or (matched == known)
	local bonus
	if majority then
		bonus = SearchScores.credit_share
	else
		bonus = math.floor(
			math.min(matched / math.max(known, 1), 0.5) * SearchScores.credit_share)
	end
	entry.score = math.max(entry.score, SearchScores.credit + bonus)
	if matched >= total then
		entry.pack.why = "all charts by " .. acc.query
	elseif majority and matched == known then
		entry.pack.why = "all credited charts by " .. acc.query
	else
		entry.pack.why = matched .. " of " .. total .. " by " .. acc.query
	end
end

-- One pack at a time through the helper, so the engine's single HTTP worker
-- is never held by more than one verification while the search's own
-- requests and the player's browsing share it.
local VerifyNext
VerifyNext = function(acc)
	if state.searchGen ~= acc.gen then return end
	if acc.verifyBusy then return end
	local item = table.remove(acc.verify, 1)
	if not item then return end

	-- already scanned this session: apply it and move straight on
	if state.packCredits[item.id] then
		CreditTruth(acc, item.id)
		SearchPublish(acc)
		return VerifyNext(acc)
	end
	if acc.verified >= SEARCH.VERIFY_MAX then return end

	local url = CB.WebBase and (CB.WebBase() .. "/api/credits/" .. item.id)
	if not (url and NETWORK:IsUrlAllowed(url)) then return end

	acc.verifyBusy = true
	acc.verified = acc.verified + 1
	NETWORK:HttpRequest{
		url = url,
		connectTimeout = 5,
		-- a large pack is many ranged reads; give the relay room
		transferTimeout = 120,
		onResponse = function(response)
			acc.verifyBusy = false
			if response.error == nil and response.statusCode == 200 then
				local ok, data = pcall(JsonDecode, response.body or "")
				if ok and type(data) == "table" and type(data.credits) == "table" then
					-- cached even when this search is over: the next one wants it
					state.packCredits[item.id] = data.credits
				end
			end
			if state.searchGen == acc.gen then
				CreditTruth(acc, item.id)
				SearchPublish(acc)
				VerifyNext(acc)
			end
		end,
	}
end

local function VerifyCredits(acc)
	-- smallest packs first: they verify in a couple of seconds, and they are
	-- also where the catalogue's index is most often wrong
	table.sort(acc.verify, function(a, b) return a.total < b.total end)
	VerifyNext(acc)
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
		url = Upstream(url),
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
								if total > 0 and matched * 2 > total then
									-- theirs: the full bonus, identical for
									-- every majority pack, so recency decides
									-- among them rather than pack size
									bonus = SearchScores.credit_share
								elseif total > 0 and matched > 0 then
									-- a hand in it: proportional, and always
									-- under what a majority pack scores
									bonus = math.floor(
										math.min(matched / total, 0.5) * SearchScores.credit_share)
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
							-- a partial credit answer is exactly the kind the
							-- catalogue gets wrong; queue it for the simfiles
							if kind == "credit" and bonus < SearchScores.credit_share then
								acc.verify[#acc.verify+1] = {
									id = id,
									total = tonumber(result.songs_count) or 0,
								}
							end
						end
					end
				end
			end
			if kind == "credit" and #acc.verify > 0 then
				VerifyCredits(acc)
			end
			SearchPublish(acc)
		end,
	}
end

-- The recency index landed more dates; put them on any dateless rows of the
-- search still on screen, and publish again so the order follows.
--
-- This is what makes "search for a charter" come back newest-first even when
-- the search ran before anything had built the index: the rows went up
-- dateless -- majority-tier packs tying on score and falling back to name
-- order -- and this re-sort repairs that the moment the index can say which
-- pack is newest. Rows older than the index's window never get a date and
-- keep sorting after the dated ones, which is the right place for them.
local function SearchIndexLanded()
	local acc = state.searchAcc
	if not acc or state.searchGen ~= acc.gen then return end
	local dates = state.recentIndex.dates
	local touched = false
	for entry in ivalues(acc.list) do
		local pack = entry.pack
		if (pack.date == nil or pack.date == "") and dates[pack.id] then
			pack.date = dates[pack.id]
			touched = true
		end
	end
	if touched then SearchPublish(acc) end
end

local function RunSearch(query)
	query = Trim(query or "")
	state.searchGen = (state.searchGen or 0) + 1
	local acc = {
		gen = state.searchGen, list = {}, byId = {}, inFlight = 0,
		query = query, needle = query:lower(),
		-- packs whose credit answer deserves a second opinion, and the state
		-- of the one-at-a-time chain that gets it
		verify = {}, verified = 0, verifyBusy = false,
	}
	-- kept where the recency index can find it when more dates land; the gen
	-- field is what says whether it is still the search on screen
	state.searchAcc = acc
	-- simfile credit scans, kept across searches: a pack's authorship does
	-- not change between queries, only what it is matched against
	state.packCredits = state.packCredits or {}

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
	-- reads as "these are your results", which they are not. The page fetch
	-- already in the air gets the same treatment -- cancelled and outdated --
	-- or its late answer would paint the old catalogue rows back over the
	-- results, under the SEARCH RESULTS heading.
	if state.fetchReq then state.fetchReq:Cancel() state.fetchReq = nil end
	state.fetchGen = state.fetchGen + 1
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
		-- after the search's own requests, so they reach the engine's one
		-- HTTP worker first and the index pages queue behind them
		EnsureRecentIndex()
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

	-- The dates for CSV-resolved rows come from the recency index, so make
	-- sure somebody is building it. After the search's own requests, so they
	-- reach the engine's one HTTP worker first and the index pages queue
	-- behind them; a no-op whenever the index is already built or building.
	EnsureRecentIndex()
end

-- -----------------------------------------------------------------------
-- What the parts after this one use.

-- Give up on whatever the search was doing.
--
-- A search fans out into several requests that publish as each one lands, and
-- they are kept honest by a generation counter -- but only a NEWER search ever
-- bumped it. Walking away from the search instead (a filter tab, a level view,
-- a year, leaving the browser) left every one of those requests still holding
-- the current generation, so the next one to land republished its results over
-- whatever list had replaced it. The keyboard tab filling up with search
-- results a second after you got there is exactly that.
local function AbandonSearch()
	state.searchGen = (state.searchGen or 0) + 1
end

CB.AbandonSearch     = AbandonSearch
CB.RowFromCatalog    = RowFromCatalog
CB.RunSearch         = RunSearch
CB.SearchIndexLanded = SearchIndexLanded
