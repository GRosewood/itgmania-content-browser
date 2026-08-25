-- -----------------------------------------------------------------------
-- The difficulty levels, and the band that heads them
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local BROWSER_DATA_DIR  = CB.BROWSER_DATA_DIR
local BannerShapeOk     = CB.BannerShapeOk
local CanReach          = CB.CanReach
local Clamp             = CB.Clamp
local DanceChartsOnly   = CB.DanceChartsOnly
local DanceOnly         = CB.DanceOnly
local EnsureRecentIndex = CB.EnsureRecentIndex
local FetchDetail       = CB.FetchDetail
local FetchPackTypes    = CB.FetchPackTypes
local FetchPacks        = CB.FetchPacks
local FetchServerRows   = CB.FetchServerRows
local InLevelView       = CB.InLevelView
local NormalizeName     = CB.NormalizeName
local Upstream          = CB.Upstream
local PackTypeOf        = CB.PackTypeOf
local RAGEFILE_READ     = CB.RAGEFILE_READ
local RAGEFILE_WRITE    = CB.RAGEFILE_WRITE
local Refresh           = CB.Refresh
local RowFromCatalog    = CB.RowFromCatalog
local Trim              = CB.Trim
local refs              = CB.refs
local state             = CB.state

-- These are filled in by a part that loads AFTER this one, so they cannot
-- be copied here -- the copy would be the nil they hold right now, forever.
-- Reached through the shared table at call time instead.
local function FetchArrowcloud(...) return CB.FetchArrowcloud(...) end

-- Declared here and filled in below. Other parts reach these through the
-- shared table, so they see the finished thing rather than this nil.
local RefreshLevelView

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
	DBL_FIRST   = 20,   -- and the doubles column's helping, which pages the same way
	POP_RANK    = 250,  -- how deep the popularity list is read
	FEAT_RANK   = 250,  -- how deep the featured grid's gate goes: the whole
	                    -- popularity list rather than its first three pages,
	                    -- which was too tight to fill a grid of 24
}

-- The first helping for a bucket: how many rows it finds before pausing and
-- letting the reader ask for more.
--
-- Written out rather than as a chain of and/or, which quietly answers the
-- wrong branch the moment a middle term is false -- the bug that had Right
-- fetching packs instead of turning a page.
function LEVEL.FirstHelping(bucket)
	if bucket == "beginner" then return LEVEL.BEG_FIRST end
	if bucket == "doubles" then return LEVEL.DBL_FIRST end
	return LEVEL.TARGET
end

local LevelLabels = {
	beginner = "BEGINNER FRIENDLY",
	tech     = "ALL AROUND",
	stamina  = "HARD CONTENT / STAMINA",
	doubles  = "DOUBLES",
}

local LevelBlurbs = {
	beginner = "Popular packs whose beginner charts are mostly 1s to 4s.",
	tech     = "Packs stepmaniaonline.net lists as technical or all-around.",
	stamina  = "Packs stepmaniaonline.net lists as stamina.",
	doubles  = "Packs made for doubles, then packs with doubles charts in them.",
}

-- Whether a pack is beginner-friendly, remembered on disk.
--
-- Deciding costs a pack page each, and about three in four candidates fail, so
-- filling one screen of seven reads around thirty pages. Nothing on SMO can
-- shortcut that -- its browser filters by style and substyle but not by
-- difficulty, there is no per-pack JSON, and the answer lives in a table near
-- the end of the HTML -- so the work is real. What is avoidable is doing it
-- again on every launch, which is what this is for.
--
-- A verdict is about the pack's charts, and those do not change: SMO serves a
-- pack under an id, and a pack that reached down to the easy blocks last month
-- still does. So there is no expiry. The file is a few kilobytes at the size
-- this list works over.
LEVEL.VERDICT_FILE = BROWSER_DATA_DIR .. "beginner-packs.txt"

function LEVEL.Verdicts()
	if state.begVerdicts then return state.begVerdicts end
	local kept = {}
	if FILEMAN:DoesFileExist(LEVEL.VERDICT_FILE) then
		local f = RageFileUtil:CreateRageFile()
		if f:Open(LEVEL.VERDICT_FILE, RAGEFILE_READ) then
			local body = f:Read()
			f:Close()
			for line in tostring(body or ""):gmatch("[^\r\n]+") do
				local id, verdict = line:match("^(%d+)|([yn])$")
				if id then kept[id] = (verdict == "y") end
			end
		end
		f:destroy()
	end
	state.begVerdicts = kept
	return kept
end

-- What was decided about this pack last time, or nil for never asked.
function LEVEL.Verdict(pack)
	if not (pack and pack.id) then return nil end
	return LEVEL.Verdicts()[tostring(pack.id)]
end

-- Write one down. Batched by a dirty flag rather than rewritten per pack: a
-- walk settles thirty of these in a few seconds and the file is rewritten
-- whole, so doing it per verdict would be thirty rewrites for one answer.
function LEVEL.Remember(pack, verdict)
	if not (pack and pack.id) then return end
	local kept = LEVEL.Verdicts()
	local key = tostring(pack.id)
	if kept[key] == verdict then return end
	kept[key] = verdict
	state.begDirty = true
end

function LEVEL.SaveVerdicts()
	if not state.begDirty then return end
	state.begDirty = false
	local kept = LEVEL.Verdicts()
	local f = RageFileUtil:CreateRageFile()
	if f:Open(LEVEL.VERDICT_FILE, RAGEFILE_WRITE) then
		for id, verdict in pairs(kept) do
			f:PutLine(id .. "|" .. (verdict and "y" or "n"))
		end
		f:Close()
	end
	f:destroy()
end

-- A pack worth handing a beginner: it reaches down to the easiest blocks,
-- never goes above 14, and has a real easy ramp rather than one token chart.
-- Measured over arrowcloud's top 250, that last test is what separates a pack
-- a beginner can work through from one with a single easy chart bolted on.
local function BeginnerPack(det)
	if not det or not det.songs then return false end
	local easy, total = 0, 0
	for song in ivalues(det.songs) do
		-- This used to ask whether the song had a singles chart first. It was
		-- reading the page\x27s mode filter, which says yes for every song, so
		-- the test never excluded anything -- and now that the fake field is
		-- gone, asking would exclude everything. The low end of the meter is
		-- what the ramp is measured from either way.
		local low = tonumber(tostring(song.meters or ""):match("^%s*(%d+)"))
		if low then
			total = total + 1
			if low >= LEVEL.BEG_FLOOR and low <= LEVEL.BEG_CEIL then
				easy = easy + 1
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

-- Rows visible in one doubles column. It lives here rather than on LO because
-- the split below has to clamp the cursor with it, and LO is not built yet.
LEVEL.DBL_ROWS = 7

-- The two lists the DOUBLES tab is made of.
--
-- itgdb.net keeps a category for packs built specifically for doubles, which is
-- the dedicated list outright -- about thirty packs on one page, no reading
-- required. SMO's own browser can filter its table by chart type, and
-- dance-double with every substyle ticked narrows nine and a half thousand
-- packs to a couple of hundred. Those are candidates rather than answers: each
-- has at least one doubles chart, so each is read and its doubles counted.
function LEVEL.FetchDoubles()
	local d = state.doubles
	if d.status ~= "idle" then return end
	d.status = "loading"

	local url = "https://itgdb.net/pack_search/"
		.. "?search_by=name&order_by=name&order_dir=asc&category=5"
	if CanReach(url) then
		NETWORK:HttpRequest{
			url = Upstream(url),
			connectTimeout = 10,
			transferTimeout = 30,
			onResponse = function(response)
				local names = {}
				if response.error == nil and response.statusCode == 200 then
					local body = tostring(response.body or "")
					for raw in body:gmatch('href="/packs/%d+/"[^>]*>(.-)</a>') do
						local clean = Trim((raw:gsub("<[^>]*>", "")))
						if clean ~= "" then names[NormalizeName(clean)] = true end
					end
				end
				d.dedicated = names
				if RefreshLevelView then RefreshLevelView() end
				Refresh()
			end,
		}
	else
		-- neither road reaches itgdb.net -- no allowlist entry and no helper
		-- to relay; the partial list still works, and the tab says so
		d.dedicated, d.blocked = {}, true
	end

	FetchServerRows(0, 500, "", function(rows, _, err)
		d.partial, d.partialById = {}, nil
		if rows then
			for pack in ivalues(rows) do d.partial[#d.partial+1] = pack end
		end
		d.status = err and "failed" or "ready"
		if RefreshLevelView then RefreshLevelView() end
		Refresh()
	end, {
		["style_filters"] = "dance-double",
		["pack_substyle_filters"] = "technical,mods,stamina",
	})
end

-- is this one of itgdb's dedicated doubles packs?
local function DedicatedDoubles(pack)
	local d = state.doubles
	return d.dedicated ~= nil and pack ~= nil
		and d.dedicated[NormalizeName(pack.name)] == true
end

-- The two columns the DOUBLES tab draws.
--
-- The walk produces one list, dedicated first, because that is the order the
-- filtering wants. The screen wants them apart: a pack built for doubles and a
-- pack with four doubles charts in it are two different things to go looking
-- for, and a single list leaves the reader to work out where one ends.
--
-- This runs on every publish, so a column can grow under the cursor. The
-- clamp at the end is for the other direction -- a column that shrinks, which
-- happens when the lists arrive and the rows are placed again.
function LEVEL.Split()
	local d = state.doubles
	local left, right = {}, {}
	for pack in ivalues(state.level.rows) do
		if DedicatedDoubles(pack) then
			left[#left+1] = pack
		else
			right[#right+1] = pack
		end
	end
	d.left, d.right = left, right

	local list = (d.col == 2) and right or left
	d.win[d.col] = Clamp(d.win[d.col], 0, math.max(0, #list - 1))
	local visible = math.min(LEVEL.DBL_ROWS, #list - d.win[d.col])
	d.row = Clamp(d.row, 1, math.max(1, visible))
end

local function LevelPool(bucket)
	if bucket == "beginner" then return BeginnerPool() end

	-- Doubles: the packs made for it first, then the ones that merely contain
	-- some. Both lists come from elsewhere, so this only orders them.
	if bucket == "doubles" then
		local d = state.doubles
		local pool, seen = {}, {}

		if d.dedicated and next(d.dedicated) ~= nil then
			-- itgdb names them; SMO is where they can be downloaded from, so
			-- the two are joined on the name
			for key in pairs(d.dedicated) do
				local rec = state.smoByName and state.smoByName[key]
				local row = rec and RowFromCatalog(rec.id, nil)
				if row and not seen[row.id] then
					seen[row.id] = true
					pool[#pool+1] = row
				end
			end
			-- Newest first. The catalogue carries no date, but SMO's pack ids
			-- run in the order packs were added, so they order this the same
			-- way -- which is how the keyboard list is sorted too.
			table.sort(pool, function(a, b)
				return (tonumber(a.id) or 0) > (tonumber(b.id) or 0)
			end)
		end

		for pack in ivalues(d.partial or {}) do
			if not seen[pack.id] then
				seen[pack.id] = true
				pool[#pool+1] = pack
			end
		end
		return pool
	end

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

local LevelStep  -- forward declaration (re-entered via callbacks)

-- The walk is re-entered from inside itself, and these are what make that
-- flat rather than deep. See LevelStep at the bottom of this group for why.
local levelStepping      = false   -- a walk is on the stack right now
local levelStepAgain     = false   -- ...and something asked it for another lap
local levelPublishWanted = false   -- a publish, held until the walking stops
local levelRefreshWanted = false   -- a repaint, held the same way

-- Another helping: called when somebody reaches the end of what has been
-- gathered so far. Returns false when there is genuinely nothing more.
function LEVEL.Extend()
	local lv = state.level
	if not lv or lv.status ~= "loading" and lv.status ~= "ready" then return false end
	if not lv.more then return false end
	-- another helping of the same size the first one was
	lv.limit = lv.limit + LEVEL.FirstHelping(lv.bucket)
	lv.budget = lv.budget + LEVEL.MAX_DETAILS
	lv.more   = false
	lv.status = "loading"
	LevelStep()
	return true
end

-- How many rows count against the helping the reader was given.
--
-- The doubles view fills two columns and only one of them is bounded: the
-- dedicated column is a fixed thirty-odd from itgdb, placed outright, while
-- the other is five hundred candidates paged through on demand. Counting both
-- would spend the whole first helping on the column that was never going to
-- grow, and the reader would be asked to page for rows that had already
-- arrived.
local function LevelFilled(lv)
	if lv.bucket == "doubles" then return lv.paged or 0 end
	return #lv.rows
end

local function LevelPublish()
	local lv = state.level
	if state.mode ~= lv.bucket then return end
	-- Kept from the first row onward, not just when the walk finishes: a
	-- reader who looks at another tab after a few seconds and comes back
	-- should find what had arrived, not an empty list being built again.
	state.levelCache[lv.bucket] = lv
	state.localRows = lv.rows
	if lv.bucket == "doubles" then
		-- nothing to page: the doubles view draws every row it has, in the
		-- column that row belongs to
		state.packs = {}
		LEVEL.Split()
		Refresh()
		return
	end
	FetchPacks(state.page, true)
end

-- Publish the list, or note that it wants publishing.
--
-- Called once per placed row, and while the walk is running that can be a
-- whole pool's worth in a single frame -- each one rebuilding the page and
-- repainting the screen for a list nobody has seen yet. Held until the walking
-- stops, it happens once, with every row that lap found already in it.
local function LevelPublishSoon()
	if levelStepping then levelPublishWanted = true return end
	LevelPublish()
end

local function LevelRefreshSoon()
	if levelStepping then levelRefreshWanted = true return end
	Refresh()
end

local function LevelStepOnce()
	local lv = state.level
	if lv.status ~= "loading" then return end
	-- nothing happens until the reader has actually stopped on this tab; see
	-- LO.LevelBegin
	if not lv.began then return end

	if lv.bucket == "doubles" then
		-- both lists are fetched rather than derived, so nothing can be placed
		-- until they have arrived
		local d = state.doubles
		if d.status == "idle" then LEVEL.FetchDoubles() return end
		-- A fetch that failed outright leaves nothing in flight, and "idle"
		-- above is the only thing that ever asked again -- so a failure that
		-- landed before the catalogue did used to park this view on its
		-- spinner for good. The pump that delivered the failure drives the
		-- retry, so it asks exactly as often as an answer says it should,
		-- and the walk carries on below over whichever list did arrive.
		if d.status == "failed" then
			d.status = "idle"
			LEVEL.FetchDoubles()
		end
		-- The join is itgdb's names looked up in SMO's catalogue, so the
		-- catalogue is not optional here. Asking again is free while one is
		-- in flight or already in hand -- FetchPackTypes guards both -- and
		-- it is the only thing that gets this view moving after a failure.
		if not state.smoByName then
			if state.packTypesFailed then FetchPackTypes() end
			return
		end
		-- Only the dedicated list is waited for. It fills the first column on
		-- its own, and the partial list -- which is the slower of the two --
		-- is appended to the pool by RefreshLevelView when it lands, so the
		-- screen has something in it a good deal sooner.
		if d.dedicated == nil then return end
		if #lv.pool == 0 then
			lv.pool = LevelPool("doubles")
			-- an empty pool is only worth parking on while the slower list
			-- is still on its way; once both are in hand, falling through
			-- lets the walk settle over nothing rather than spin over it
			if #lv.pool == 0 and d.partial == nil then return end
		end
	elseif lv.bucket == "beginner" then
		local ac = state.arrowcloud
		if ac.deep == "idle" or ac.deep == "loading" then return end
		-- the pool is a join against the catalogue, and a failed fetch of it
		-- leaves nothing in flight to bring this walk back to life -- the
		-- doubles branch above learned that first, and this is the same
		if not state.smoByName then
			if state.packTypesFailed then FetchPackTypes() end
			return
		end
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
			-- park only while the index is still on its way and its callbacks
			-- will step this walk again; once it has settled, an empty pool is
			-- the answer, not a thing to wait on
			if #lv.pool == 0 then
				local idx = state.recentIndex
				if idx.status == "idle" or idx.status == "loading" then return end
			end
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

	-- Beginner reads a pack page to answer a question about its charts and
	-- stops after one screen, so four at a time is plenty. Doubles has a whole
	-- column of candidates to get through and no way to shortcut them, so it
	-- reads at the same rate as the rest.
	local atOnce = (lv.bucket == "beginner") and 4 or 8
	while lv.inFlight < atOnce and lv.poolPos < #lv.pool
	      and LevelFilled(lv) < lv.limit
	      and lv.fetched < lv.budget do
		lv.poolPos = lv.poolPos + 1
		local pack = lv.pool[lv.poolPos]

		-- Pass one is free: SMO's tag answers outright. Pass two reads the pack
		-- page for the ones it did not, which is the only way to place a pack
		-- from before SMO started tagging.
		if lv.bucket ~= "beginner" and lv.bucket ~= "doubles" then
			local tagged = ContentBucket(pack)
			if not lv.deep then
				if tagged == lv.bucket then lv.rows[#lv.rows+1] = pack end
			-- lv.budget, not the constant it started at: LEVEL.Extend raises
			-- the budget when the reader asks for more, and testing the
			-- constant here meant the deep pass could never spend the
			-- increase. "&MENUDOWN; more" put the list back into loading,
			-- found nothing it was allowed to read, and offered more again.
			elseif tagged == nil and lv.fetched < lv.budget then
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
						LevelPublishSoon()
						LevelStep()
						LevelRefreshSoon()
					end)
				end
			end
		else
			-- The second column needed no reading in the first place.
			--
			-- Its packs come from SMO's own catalogue filtered to dance-double,
			-- so SMO has already said each one contains doubles. The pack page
			-- was being read on top of that to count how many, and the count
			-- came from a column that turned out to be the page's mode filter
			-- rather than a description of anything -- so it counted every song
			-- of every pack and the threshold it fed let everything through.
			-- The filter is the answer; there was never a question to ask after
			-- it.
			if lv.bucket == "doubles" then
				-- Neither doubles column needs a pack page read.
				--
				-- The dedicated one is itgdb's answer and the other is SMO's
				-- own dance-double filter: both lists are already the answer,
				-- so there is nothing left to ask a page about. It used to read
				-- one per pack to count the doubles charts inside, and that
				-- count came from a column that turned out to be the page's
				-- mode filter -- so the reading bought nothing and was the
				-- whole reason this column arrived a few rows at a time.
				lv.rows[#lv.rows+1] = pack
				if not DedicatedDoubles(pack) then
					lv.paged = (lv.paged or 0) + 1
				end
			else
				local cached = state.details[pack.id]
				local known = LEVEL.Verdict(pack)
				if cached then
					local verdict = BeginnerPack(cached)
					LEVEL.Remember(pack, verdict)
					if verdict then lv.rows[#lv.rows+1] = pack end
				elseif known ~= nil then
					-- Decided on an earlier run. This is what turns a first
					-- build of thirty pack pages into a second build of none.
					if known then lv.rows[#lv.rows+1] = pack end
				else
					lv.inFlight = lv.inFlight + 1
					lv.fetched = lv.fetched + 1
					FetchDetail(pack, function(det)
						if state.level ~= lv then return end
						lv.inFlight = lv.inFlight - 1
						-- A fetch that FAILED says nothing about the pack.
						-- Verdicts are remembered on disk forever, so writing
						-- one here turned any network hiccup into a permanent
						-- "not beginner friendly" -- wrong, invisible, and
						-- carried across every future session. No detail, no
						-- verdict; the pack gets asked about again some other
						-- time.
						if det == nil then
							LevelPublishSoon()
							LevelStep()
							LevelRefreshSoon()
							return
						end
						local verdict = BeginnerPack(det)
						LEVEL.Remember(pack, verdict)
						if verdict then lv.rows[#lv.rows+1] = pack end
						LevelPublishSoon()
						LevelStep()
						LevelRefreshSoon()
					end)
				end
			end
		end
	end

	-- Rows placed without a fetch still have to reach the screen. Publishing
	-- only happened from a fetch's callback, which was fine while every row
	-- cost one -- but the dedicated doubles column is placed outright, and sat
	-- there invisible until some other pack's page happened to land.
	if #lv.rows ~= (lv.published or 0) then
		lv.published = #lv.rows
		LevelPublishSoon()
	end

	-- the tagged pass finishing is not the end; the deep pass follows it
	local lastPass = (lv.bucket == "beginner") or (lv.bucket == "doubles") or lv.deep
	local filled = (LevelFilled(lv) >= lv.limit)
	local spent  = (lv.fetched >= lv.budget)
	local exhausted = filled
	                  or (lv.poolPos >= #lv.pool and lastPass)
	                  or (spent and lastPass)
	-- Doubles is not finished while the second of its two lists is still on
	-- its way, however far the walk has got through the first: settling to
	-- "ready" here would stop the spinner and shut RefreshLevelView out of
	-- appending the partial candidates when they arrive. "loading" covers the
	-- retry of a failed fetch the same way: what that retry brings back must
	-- still find a walk that will take it.
	if lv.bucket == "doubles"
	   and (state.doubles.partial == nil or state.doubles.status == "loading") then
		exhausted = false
	end
	-- The free pass can end right here: the loop above consumed the last of
	-- the pool, and the handover to the deep pass sits at the top of this
	-- function -- a place this call has already been past. When that happens
	-- with nothing in flight, no callback is coming to run this function
	-- again, so the walk used to sit on "loading" forever: enter the tab
	-- before the sources land, and the pumps that would have moved it have
	-- all fired by the time the pool runs out. One more step is the cure --
	-- either the handover runs and the walk moves, or the index is still on
	-- its way and its own callback supplies the step instead.
	if lv.inFlight == 0 and not exhausted and not lv.deep
	   and lv.bucket ~= "beginner" and lv.bucket ~= "doubles"
	   and lv.poolPos >= #lv.pool then
		local idx = state.recentIndex
		if idx.status ~= "idle" and idx.status ~= "loading" then
			return LevelStep()
		end
	end
	-- there is more to find if the walk stopped on a limit rather than on the
	-- end of the pool
	if lv.inFlight == 0 and exhausted then
		lv.more = (filled or spent) and (lv.poolPos < #lv.pool or not lv.deep)
	end
	if lv.inFlight == 0 and exhausted then
		-- the walk has stopped; put anything it decided on disk
		if lv.bucket == "beginner" then LEVEL.SaveVerdicts() end
		lv.status = "ready"
		LevelPublishSoon()
		LevelRefreshSoon()
	end
end

-- Take a walk, and keep taking one while the walking asks for another.
--
-- Everything that used to recurse into the walk now lands here while a walk is
-- already on the stack, and all that does is set a flag. The lap that is
-- running finishes its own loop, and the repeat below starts the next one --
-- same order of work, same forward progress, no stack.
--
-- The flag is cleared through a pcall so that an error inside the walk cannot
-- leave levelStepping stuck true, which would silently wedge the tab: every
-- later step would think a walk was already running and quietly decline.
LevelStep = function()
	if levelStepping then levelStepAgain = true return end

	levelStepping = true
	local ok, err = pcall(function()
		repeat
			levelStepAgain = false
			LevelStepOnce()
		until not levelStepAgain
	end)
	levelStepping = false

	-- Whatever the whole walk decided, said once.
	local publish, repaint = levelPublishWanted, levelRefreshWanted
	levelPublishWanted, levelRefreshWanted = false, false
	if publish then LevelPublish() end
	if repaint then Refresh() end

	if not ok then error(err, 0) end
end

-- Start the view the reader has actually settled on.
--
-- Cycling the tab row enters each view it passes through, which is what makes
-- the row feel live -- and the engine runs one HTTP request at a time, in the
-- order they were asked for, on a single worker thread (NetworkManager keeps
-- exactly one httpWorker). So walking from PAD to DOUBLES used to put a
-- popularity ranking, a catalogue crawl and a page of beginner pack reads in
-- the queue ahead of the one list the reader wanted, and Doubles waited behind
-- all of it.
--
-- Holding the fetches back a fraction of a second costs a settled view
-- nothing, and it means passing over four tabs to reach the fifth asks for
-- nothing on behalf of the four.
function LEVEL.Begin()
	state.settled = true
	local lv = state.level
	if lv and state.mode == lv.bucket then
		if not lv.began then
			lv.began = true
			if lv.bucket == "beginner" then
				-- the popularity ranking and the CSV catalogue, both idempotent
				FetchArrowcloud()
				FetchPackTypes()
			elseif lv.bucket == "doubles" then
				-- Doubles is itgdb's list and a filtered SMO table joined to
				-- the catalogue by name. It has no use for the recency index,
				-- and starting that crawl anyway put a dozen requests in front
				-- of the pack pages this view is actually waiting on.
				FetchPackTypes()
			else
				EnsureRecentIndex()
			end
			lv.pool = LevelPool(lv.bucket)
		end
		-- starts a new walk, resumes one that was left part way, and does
		-- nothing at all to a list that is already finished
		LevelStep()
		-- doubles draws its own two columns; there is no page to fetch
		if lv.bucket ~= "doubles" then FetchPacks(1, false) end
	end

	-- rows and panes hold their own requests back until this: one refresh and
	-- they ask for what the settled view actually needs
	Refresh()
end

-- Forget what a list was built from, so the next visit builds it again.
--
-- Keeping a finished list is right nearly always -- the walk would find the
-- same packs -- but it leaves no way to go and look for new ones, which is
-- what this is for. The pack pages already read are kept: what a pack contains
-- does not change, only which packs exist, and that is what the sources say.
function LEVEL.Reload(bucket)
	state.levelCache[bucket] = nil

	if bucket == "doubles" then
		local d = state.doubles
		d.status, d.dedicated, d.partial, d.blocked = "idle", nil, nil, false
		d.partialById = nil
	elseif bucket == "beginner" then
		-- the beginner pool is the popularity ranking joined to the catalogue
		local ac = state.arrowcloud
		ac.status, ac.deep = "idle", "idle"
	else
		-- all around, stamina and the year pages are walked over the index
		local idx = state.recentIndex
		-- a new walk, so whatever the old one still has in flight is not this
		idx.gen = (idx.gen or 0) + 1
		idx.status, idx.page = "idle", 0
		idx.rows, idx.dates, idx.seen = {}, {}, {}
	end
end

local function EnterLevelView(bucket)
	state.mode = bucket
	state.zone = "list"
	state.search = ""
	state.viewYear = nil

	if bucket == "doubles" then
		local d = state.doubles
		d.left, d.right = {}, {}
		d.col, d.row, d.win = 1, 1, {0, 0}
	end

	-- Banners queued for the view being left would sit in the one request
	-- queue in front of everything this view needs -- the featured grid alone
	-- queues two dozen. Whatever is still on screen asks again on the next
	-- refresh, and what is not, nobody was going to look at.
	for url in ivalues(state.bannerQueue) do state.bannerQueued[url] = nil end
	state.bannerQueue = {}

	-- A list finished on an earlier visit comes back as it was, rather than
	-- being walked again for the same answer. LEVEL.Reload is how the reader
	-- asks for it fresh.
	local kept = state.levelCache[bucket]
	if kept then
		if kept.status == "loading" then
			-- The walk was interrupted part way. Its outstanding callbacks
			-- belong to that object and bail out when they land, so its
			-- in-flight count would never come back down and the walk would
			-- never move again. It resumes from a copy that owns itself, over
			-- the same rows and the same pool.
			kept = {
				status = "loading", bucket = bucket, began = true,
				rows = kept.rows, pool = kept.pool, poolPos = kept.poolPos,
				inFlight = 0, fetched = kept.fetched, published = kept.published,
				deep = kept.deep, limit = kept.limit, budget = kept.budget,
				more = kept.more, paged = kept.paged,
			}
			state.levelCache[bucket] = kept
		end
		state.level = kept
		state.localRows = kept.rows
		state.packs = {}
		state.page = 1
		state.cursor = 1
		if bucket == "doubles" then
			-- the columns are derived, and the cursor is left where it was
			LEVEL.Split()
		else
			FetchPacks(1, false)
		end
		Refresh()
		return
	end

	state.level = {
		status = "loading", bucket = bucket, rows = {}, pool = {},
		poolPos = 0, inFlight = 0, fetched = 0,
		began = false,  -- nothing is asked for until the tab is settled on
		deep = false,   -- false while the free pass over SMO's tags is running
		-- the beginner list pays a pack page per candidate, so it stops far
		-- sooner and picks up again if anyone reaches the end
		limit = LEVEL.FirstHelping(bucket),
		budget = LEVEL.MAX_DETAILS,  -- pack pages to spend before pausing
		more = false,                -- true when a pause left something behind
	}
	state.page = 1
	state.cursor = 1
	-- the catalogue fetch already in the air would otherwise land on this
	-- freshly-cleared view and paint the old rows into it
	if state.fetchReq then state.fetchReq:Cancel() state.fetchReq = nil end
	state.fetchGen = state.fetchGen + 1
	state.localRows = {}
	state.packs = {}
	-- The view is on screen immediately -- its heading, its blurb, its
	-- placeholder rows -- but it does not ask for anything yet. See
	-- LO.LevelBegin for why.
	if refs.settle then refs.settle:playcommand("SMOArmSettle") end
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
			-- every one of these lists is built against the catalogue, so a
			-- walk parked on a fetch of it that failed is retrying, not
			-- checking packs -- and saying the latter dresses it up as
			-- progress
			if state.packTypesFailed and not state.smoByName then
				return blurb .. "  Could not reach stepmaniaonline.net --"
					.. " retrying.  &SELECT; reloads."
			end
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

-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.BandBusy         = BandBusy
CB.BandBusyText     = BandBusyText
CB.BandSubtitle     = BandSubtitle
CB.BandTitle        = BandTitle
CB.DedicatedDoubles = DedicatedDoubles
CB.EnterLevelView   = EnterLevelView
CB.LEVEL            = LEVEL
CB.RefreshLevelView = RefreshLevelView
