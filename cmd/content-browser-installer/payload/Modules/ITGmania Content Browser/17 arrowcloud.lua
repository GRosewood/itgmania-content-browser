-- -----------------------------------------------------------------------
-- Arrowcloud, and looking a charter up by name
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local CanReach          = CB.CanReach
local EnsureRecentIndex = CB.EnsureRecentIndex
local FEAT              = CB.FEAT
local LEVEL             = CB.LEVEL
local NormalizeName     = CB.NormalizeName
local Refresh           = CB.Refresh
local SMO_BASE          = CB.SMO_BASE
local RefreshLevelView  = CB.RefreshLevelView
local Upstream          = CB.Upstream
local UrlAllowed        = CB.UrlAllowed
local state             = CB.state

-- These two are filled in by a part that loads AFTER this one, so they cannot
-- be copied here -- the copy would be the nil they hold right now, forever.
-- Reached through the shared table at call time instead.
local function FeaturedResolve(...) return CB.FeaturedResolve(...) end
local function FeaturedStep(...) return CB.FeaturedStep(...) end

-- Declared here and filled in below. Other parts reach these through the
-- shared table, so they see the finished thing rather than this nil.
local FetchArrowcloud

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
	if not CanReach(string.format(ARROWCLOUD_URL, 1)) then
		ac.status = "blocked"
		ac.deep = "failed"
		return
	end

	ac.status = "loading"
	ac.deep = "loading"
	ac.pending = 3

	for page = 1, 3 do
		NETWORK:HttpRequest{
			url = Upstream(string.format(ARROWCLOUD_URL, page)),
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
	if not CanReach(string.format(url, 1)) then
		ac.newStatus = "failed"
		return
	end

	ac.newStatus = "loading"
	ac.newPending = 3
	for page = 1, 3 do
		NETWORK:HttpRequest{
			url = Upstream(string.format(url, page)),
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
		url = Upstream(SMO_BASE .. "/api/search/?" .. query),
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

-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.CandidateVerdict   = CandidateVerdict
CB.FetchArrowcloud    = FetchArrowcloud
CB.FetchArrowcloudNew = FetchArrowcloudNew
CB.FetchAuthorPacks   = FetchAuthorPacks
