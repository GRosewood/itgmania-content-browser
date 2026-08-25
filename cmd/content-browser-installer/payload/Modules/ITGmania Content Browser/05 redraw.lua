-- -----------------------------------------------------------------------
-- Redrawing, toasts, and where input goes
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local BANNER_MAX_ASPECT = CB.BANNER_MAX_ASPECT
local BANNER_MIN_ASPECT = CB.BANNER_MIN_ASPECT
local Clamp             = CB.Clamp
local DL                = CB.DL
local FEAT              = CB.FEAT
local PassesFilter      = CB.PassesFilter
local ROWS              = CB.ROWS
local SMO_BASE          = CB.SMO_BASE
local UP                = CB.UP
local state             = CB.state

local function Refresh()
	-- A replaced module draws nothing. Its actors are about to be deleted, and
	-- a request that lands in between would otherwise reach for them.
	if state.retired then return end

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

	-- A helper-run install reports from its own side, so it has to be asked.
	-- Refreshes come thick and fast while a download runs; three times a second
	-- is as often as a progress bar can say anything new.
	-- guarded because Refresh is defined long before these methods are
	-- attached, and it can run during load
	if DL.Watching and DL.Watching() then
		local now = GetTimeSinceStart()
		if now >= (DL.pollAt or 0) then
			DL.pollAt = now + 0.35
			DL.Poll()
		end
	end

	-- and an update reports from the same place, for the same reason
	if UP.Busy and UP.Busy() then
		local now = GetTimeSinceStart()
		if now >= (UP.pollAt or 0) then
			UP.pollAt = now + UP.POLL_EVERY
			UP.Poll()
		end
	end

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

-- Can this url be fetched at all? Directly is best; failing that, the
-- helper's relay counts -- Upstream hands back a rewritten URL exactly when
-- the relay is available, so "did it rewrite" is the test. Upstream lives in
-- a later part, hence the reach through the shared table at call time.
--
-- Every gate in front of an outside fetch must ask THIS question and not
-- NETWORK:IsUrlAllowed alone: on a fresh install the game's allowlist holds
-- only 127.0.0.1 and every outside read rides the relay, so the direct test
-- answers no for hosts the fetch below it would reach without trouble.
local function CanReach(url)
	if NETWORK:IsUrlAllowed(url) then return true end
	return CB.Upstream ~= nil and CB.Upstream(url) ~= url
end

local function UrlAllowed()
	return CanReach(SMO_BASE .. "/")
end

-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.LiftAboveSystemLayer = LiftAboveSystemLayer
CB.MeasureBanner        = MeasureBanner
CB.Refresh              = Refresh
CB.SetRedirect          = SetRedirect
CB.Toast                = Toast
CB.CanReach             = CanReach
CB.UrlAllowed           = UrlAllowed
