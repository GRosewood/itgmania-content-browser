-- -----------------------------------------------------------------------
-- Choosing what to feature
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local CandidateVerdict   = CB.CandidateVerdict
local EnsureRecentIndex  = CB.EnsureRecentIndex
local FEAT               = CB.FEAT
local FeaturedFullSpread = CB.FeaturedFullSpread
local FeaturedQuality    = CB.FeaturedQuality
local FetchArrowcloud    = CB.FetchArrowcloud
local FetchArrowcloudNew = CB.FetchArrowcloudNew
local FetchAuthorPacks   = CB.FetchAuthorPacks
local FetchDetail        = CB.FetchDetail
local FetchPackTypes     = CB.FetchPackTypes
local FetchPacks         = CB.FetchPacks
local FilterLabels       = CB.FilterLabels
local IsoFromLongDate    = CB.IsoFromLongDate
local LEVEL              = CB.LEVEL
local MonthsAgoStr       = CB.MonthsAgoStr
local REFRESH_SECS       = CB.REFRESH_SECS
local AbandonSearch      = CB.AbandonSearch
local Refresh            = CB.Refresh
local RowFromCatalog     = CB.RowFromCatalog
local Toast              = CB.Toast
local UrlAllowed         = CB.UrlAllowed
local state              = CB.state


-- Declared here and filled in below. Other parts reach these through the
-- shared table, so they see the finished thing rather than this nil.
local ApplyFilterRefetch
local FeaturedResolve
local FeaturedStep

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
	-- Already built for this filter, and not old enough to be worth doing
	-- again: keep it. Rebuilding meant every card blinked back to a spinner
	-- and the whole qualifying walk ran a second time for the same answer.
	local had = state.featured
	if had and had.mode == state.filterMode and had.status ~= "idle"
	   and had.builtAt and (GetTimeSinceStart() - had.builtAt) <= REFRESH_SECS then
		return
	end

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
	-- The page cache is NOT dropped here. Its keys already carry the filter and
	-- the search, so pad's pages and keyboard's cannot be confused for each
	-- other -- and keeping them is what makes stepping off a tab and back onto
	-- it instant instead of a fresh round of requests behind a row of spinners.
	--
	-- a filter change means a different result set; drop any search or year view
	AbandonSearch()
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

-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.ApplyFilterRefetch = ApplyFilterRefetch
CB.BuildFeatured      = BuildFeatured
CB.FeaturedResolve    = FeaturedResolve
CB.FeaturedStep       = FeaturedStep
