-- -----------------------------------------------------------------------
-- Scoring a pack, and the index of what is recent
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local BannerShapeOk   = CB.BannerShapeOk
local BannerUrlFor    = CB.BannerUrlFor
local Clamp           = CB.Clamp
local CurrentMonth    = CB.CurrentMonth
local CurrentYear     = CB.CurrentYear
local DanceChartsOnly = CB.DanceChartsOnly
local DanceOnly       = CB.DanceOnly
local FEAT            = CB.FEAT
local FetchServerRows = CB.FetchServerRows
local NormalizeName   = CB.NormalizeName
local PackTypeOf      = CB.PackTypeOf
local UrlAllowed      = CB.UrlAllowed
local Refresh         = CB.Refresh
local SearchIndexLanded = CB.SearchIndexLanded
local state           = CB.state

-- These are filled in by a part that loads AFTER this one, so they cannot
-- be copied here -- the copy would be the nil they hold right now, forever.
-- Reached through the shared table at call time instead.
local function FeaturedResolve(...) return CB.FeaturedResolve(...) end
local function RefreshLevelView(...) return CB.RefreshLevelView(...) end
local function RefreshYearView(...) return CB.RefreshYearView(...) end

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


-- The walk has stopped, for whatever reason. Everything parked on the index
-- has to hear about it, and the screen with them: a view whose row count did
-- not change has a header still reading "indexing ...", and nothing else is
-- coming along to correct it.
local function IndexSettled()
	FeaturedResolve()
	if RefreshYearView then RefreshYearView() end
	if RefreshLevelView then RefreshLevelView() end
	SearchIndexLanded()
	Refresh()
end

local function RecentIndexStep()
	local idx = state.recentIndex
	if idx.status ~= "loading" then return end
	-- Which walk this is. LEVEL.Reload empties the index in place rather
	-- than replacing it, so without this the page still in flight from
	-- the previous walk lands on the fresh one, advances its page counter
	-- past a page it never fetched, and appends rows the reset threw away.
	local walk = idx.gen or 0
	if idx.page >= RECENT_MAX_PAGES then
		idx.status = "ready"
		IndexSettled()
		return
	end

	FetchServerRows(idx.page * RECENT_PAGE, RECENT_PAGE, "", function(rows, _, err)
		if (idx.gen or 0) ~= walk then return end
		if state.recentIndex ~= idx then return end
		if err or not rows or #rows == 0 then
			-- a partial index still answers most questions; only a completely
			-- empty one counts as a failure
			-- a partial index settles the same way a complete one does: the
			-- views parked on it are waiting for it to stop, not to succeed
			idx.status = (idx.page > 0) and "ready" or "failed"
			IndexSettled()
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
			IndexSettled()
		else
			RecentIndexStep()
			if RefreshYearView then RefreshYearView() end
			if RefreshLevelView then RefreshLevelView() end
			SearchIndexLanded()
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

-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.EnsureRecentIndex  = EnsureRecentIndex
CB.FeaturedFullSpread = FeaturedFullSpread
CB.FeaturedQuality    = FeaturedQuality
CB.RecentIndexStep    = RecentIndexStep
CB.YEAR_SPAN          = YEAR_SPAN
