-- -----------------------------------------------------------------------
-- The network gate, leaving the browser, and the self-updater
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local HelperUrl            = CB.HelperUrl
local LEVEL                = CB.LEVEL
local LiftAboveSystemLayer = CB.LiftAboveSystemLayer
local Refresh              = CB.Refresh
local RunSearch            = CB.RunSearch
local SetRedirect          = CB.SetRedirect
local Snd                  = CB.Snd
local UP                   = CB.UP
local UrlAllowed           = CB.UrlAllowed
local refs                 = CB.refs
local state                = CB.state

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
	return "stepmaniaonline.net is not in HttpAllowHosts, and the helper "
		.. "that could relay for it is not running."
end

-- -----------------------------------------------------------------------
-- browser input

local function LeaveBrowser(destination)
	-- Anything the beginner walk decided and has not written yet. It normally
	-- saves when the walk settles, but leaving part-way through is exactly when
	-- the reader has paid for pack pages and would otherwise pay again.
	LEVEL.SaveVerdicts()
	-- put the credits back where the rest of the theme expects them
	if refs.root then LiftAboveSystemLayer(refs.root, false) end
	Snd.Stop(true)
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
		state.pageCache = {}
		state.zone = "list"  -- search results live in the list
		RunSearch(state.search)
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
		Question = "Search by pack name, chart author or song\n(leave empty to browse newest packs)",
		InitialAnswer = state.search or "",
		MaxInputLength = 64,
		OnOK = function(answer)
			state.pendingSearch = answer or ""
		end,
	})
	-- watch for the text entry closing (OK or cancel)
	if refs.watcher then refs.watcher:queuecommand("SMOWatchTextEntry") end
end

-- Ask for a whole pack.
--
-- Two things now start a download -- the popup a song row opens, and the
-- button at the top of the detail page -- so the checks that decide whether
-- one can start live here rather than in whichever of them was written first.
-- -----------------------------------------------------------------------
-- updates: asking, installing, and swapping this module for the new one

-- Something newer exists and pressing the button can deliver it.
function UP.Available()
	local u = UP.state
	return u ~= nil and u.available == true and u.inGame == true
end

-- Something newer exists but needs the installer run -- a release that wants a
-- newer helper, say. Worth saying; not worth a button that cannot finish.
function UP.Blocked()
	local u = UP.state
	return u ~= nil and u.available == true and u.inGame ~= true
end

function UP.Latest()
	return tostring((UP.state and UP.state.latest) or "")
end

-- An update is being installed right now.
function UP.Busy()
	return UP.job ~= nil and UP.job.done ~= true
end

-- Ask once a session. The helper caches its own answer for an hour, so asking
-- again would spend a round trip to be told the same thing.
function UP.Check()
	if UP.asked or state.retired then return end
	local h = state.helper
	if not (h and h.config) then return end
	local url = HelperUrl("/version")
	if not url or not NETWORK:IsUrlAllowed(url) then return end

	UP.asked = true
	NETWORK:HttpRequest{
		url = url,
		headers = { ["X-Browser-Token"] = h.config.token },
		connectTimeout = 3,
		-- the helper may be reaching the manifest for the first time, and a
		-- cabinet on a slow line should not turn that into a failure
		transferTimeout = 25,
		onResponse = function(response)
			if state.retired or response.error ~= nil then return end
			local ok, data = pcall(JsonDecode, response.body or "")
			if not ok or type(data) ~= "table" then return end
			if type(data.update) ~= "table" then return end
			UP.state = data.update
			Refresh()
		end,
	}
end

-- Begin. The helper does the work and reports through UP.Poll, the same shape
-- a pack install takes.
function UP.Start()
	local h = state.helper
	if not (h and h.config) then return false end
	local url = HelperUrl("/update")
	if not url or not NETWORK:IsUrlAllowed(url) then return false end

	UP.job = { phase = "checking", pct = -1 }
	UP.pollAt = 0
	NETWORK:HttpRequest{
		url = url,
		method = "POST",
		body = "{}",
		headers = {
			["X-Browser-Token"] = h.config.token,
			["Content-Type"] = "application/json",
		},
		connectTimeout = 3,
		transferTimeout = 10,
		onResponse = function(response)
			if state.retired then return end
			if response.error ~= nil then
				UP.job = { phase = "error", done = true, pct = -1,
					error = "could not reach the helper" }
				Refresh()
			end
		end,
	}
	return true
end

function UP.Poll()
	if UP.polling or state.retired then return end
	local h = state.helper
	if not (h and h.config) then return end
	local url = HelperUrl("/update/progress")
	if not url or not NETWORK:IsUrlAllowed(url) then return end

	UP.polling = true
	NETWORK:HttpRequest{
		url = url,
		headers = { ["X-Browser-Token"] = h.config.token },
		connectTimeout = 3,
		transferTimeout = 8,
		onResponse = function(response)
			UP.polling = false
			if state.retired or response.error ~= nil then return end
			local ok, data = pcall(JsonDecode, response.body or "")
			if not ok or type(data) ~= "table" or type(data.progress) ~= "table" then
				return
			end
			UP.job = data.progress
			if UP.job.done and UP.job.phase == "done" then
				-- The new files are on disk. This is the one place they can be
				-- picked up -- see UP.Reload for why it has to be here.
				UP.Reload()
				return
			end
			Refresh()
		end,
	}
end

-- Swap this module for the one that was just written.
--
-- Simply Love builds its modules by loadfile()ing every .lua in Modules/ each
-- time ScreenSystemLayer is constructed, so reloading that overlay screen is
-- the whole of picking up new files: no restart, no theme switch.
--
-- It must be called from an HTTP response and from nowhere else. Reloading
-- deletes the overlay screens, and this module's actors live on one of them,
-- so doing it from a key press or an actor command would free the screen whose
-- Input() or Update() is still on the C++ stack -- and free it out from under
-- the loop that is iterating them. Response callbacks run from
-- NetworkManager::Update, which the game loop calls before it touches
-- ScreenManager at all, so nothing is part-way through anything when the
-- screens go.
function UP.Reload()
	-- Everything left holding this chunk stops here: requests still in flight,
	-- the heartbeat, anything that would reach for an actor that is about to
	-- stop existing.
	state.retired = true

	-- Input callbacks are registered on the screen, not on the overlay, so
	-- they outlive the reload and would go on running beside the new module's
	-- own copies of themselves.
	if UP.inputScreen and UP.inputCb then
		pcall(function() UP.inputScreen:RemoveInputCallback(UP.inputCb) end)
	end
	if UP.titleScreen and UP.titleCb then
		pcall(function() UP.titleScreen:RemoveInputCallback(UP.titleCb) end)
	end

	-- and everything the browser did to the screen while it was open is undone
	-- here, because the new module will do it again from scratch
	if state.fetchReq then pcall(function() state.fetchReq:Cancel() end) end
	state.fetchReq = nil
	pcall(function() Snd.Stop(true) end)
	if refs.root then pcall(LiftAboveSystemLayer, refs.root, false) end
	state.open = false
	SetRedirect(false)

	-- the theme's directory listing still describes what was there before
	THEME:ReloadMetrics()
	SCREENMAN:ReloadOverlayScreens()
	-- ReloadOverlayScreens does not broadcast this, and a module's frame only
	-- wakes up when it hears it. Nothing on this line or the one above touches
	-- an actor, which is what makes it safe to still be running at all.
	MESSAGEMAN:Broadcast("ScreenChanged")
end

-- Drop everything the browser remembers about downloading a pack, so it can
-- be downloaded again. Called when the pack is removed.
-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.LeaveBrowser               = LeaveBrowser
CB.NetworkBlockedReason       = NetworkBlockedReason
CB.OpenSearchPrompt           = OpenSearchPrompt
CB.ReclaimInputAfterTextEntry = ReclaimInputAfterTextEntry
