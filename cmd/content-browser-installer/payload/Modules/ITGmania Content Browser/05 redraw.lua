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

-- Declared before Refresh because Refresh calls it: Lua binds a name when it
-- compiles the line mentioning it, so a local declared further down is a
-- different name to the code above -- a global, and a nil one.
local DropMeasuredBanners

local function Refresh()
	-- A replaced module draws nothing. Its actors are about to be deleted, and
	-- a request that lands in between would otherwise reach for them.
	if state.retired then return end

	-- Anything a previous pass found to be the wrong shape goes now, before a
	-- single actor reads a list. Doing it here rather than at the moment of
	-- measurement is what keeps a redraw out of the middle of a draw.
	DropMeasuredBanners()

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
	return true
end

-- Deal with any banner that turned out to be the wrong shape.
--
-- Called at the top of a redraw, which is the only safe moment: the pruning
-- moves rows out from under every actor that is about to read them, so doing
-- it from inside an actor's own command left the rest of that command working
-- from a list that had changed underneath it.
DropMeasuredBanners = function()
	local any = false
	for url in pairs(state.bannerDrop) do
		state.bannerDrop[url] = nil
		if DropPackByBanner(url) then any = true end
	end
	return any
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
		-- written down, not acted on: this runs while an actor is drawing
		-- itself, and pruning the lists there would pull rows out from under
		-- the pass that is reading them
		state.bannerDrop[url] = true
	end
end

local function Toast(text)
	MESSAGEMAN:Broadcast("SMOToast", {Text=text})
end

-- Raise (or restore) our position among ScreenSystemLayer's children.  The
-- credits texts are drawn by that layer after the module container, so without
-- this they sit on top of the browser.
--
-- A draw order is not a request to be drawn later; it is a number a frame sorts
-- on when asked. An ActorFrame draws its children in the order it happens to
-- hold them, and only SortByDrawOrder rebuilds that order from the numbers -- so
-- setting the number and walking away, which is what this used to do, changed
-- nothing at all. Each step therefore tells the PARENT to sort, because it is
-- the parent that owns the list this node's number is being sorted in.
--
-- The sort is stable, so restoring to 0 puts everything back the way it was
-- rather than merely somewhere else.
local function LiftAboveSystemLayer(actor, lifted)
	local node = actor
	for _ = 1, 3 do
		if not node then return end
		pcall(function() node:draworder(lifted and 200 or 0) end)
		local ok, parent = pcall(function() return node:GetParent() end)
		if not ok then return end
		if parent then pcall(function() parent:SortByDrawOrder() end) end
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
	return false
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
