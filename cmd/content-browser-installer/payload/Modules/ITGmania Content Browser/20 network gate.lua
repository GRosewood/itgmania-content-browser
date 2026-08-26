-- -----------------------------------------------------------------------
-- The network gate, leaving the browser, and the self-updater
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
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
	return "stepmaniaonline.net is not in HttpAllowHosts."
		.. " Run the installer, or the Enable Network Access script, again."
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

-- Where update news lives: the repo's own manifest, the same file the old
-- helper read. Fetched by the game itself now -- the installer allowlists
-- github.com and *.githubusercontent.com for exactly this.
UP.MANIFEST = "https://raw.githubusercontent.com/GRosewood/itgmania-content-browser/main/update.json"

-- is b a newer dotted version than a?
local function Newer(b, a)
	local function parts(v)
		local out = {}
		for n in tostring(v or ""):gmatch("%d+") do out[#out+1] = tonumber(n) end
		return out
	end
	local pb, pa = parts(b), parts(a)
	for i = 1, math.max(#pb, #pa) do
		local x, y = pb[i] or 0, pa[i] or 0
		if x ~= y then return x > y end
	end
	return false
end

-- Ask once a session: one manifest fetch, and the answer shaped the way the
-- rest of the browser has always read it.
function UP.Check()
	if UP.asked or state.retired then return end
	if not NETWORK:IsUrlAllowed(UP.MANIFEST) then return end

	UP.asked = true
	NETWORK:HttpRequest{
		url = UP.MANIFEST,
		connectTimeout = 5,
		transferTimeout = 25,
		onResponse = function(response)
			if state.retired or response.error ~= nil then return end
			if response.statusCode ~= 200 then return end
			local ok, man = pcall(JsonDecode, response.body or "")
			if not ok or type(man) ~= "table" or type(man.version) ~= "string" then return end
			UP.manifest = man
			local mod = type(man.module) == "table" and man.module or {}
			local available = Newer(man.version, UP.VERSION)
			-- an update the game can finish by itself needs a published
			-- archive, a checksum to hold it against, and a hasher to do the
			-- holding
			local inGame = type(mod.url) == "string" and mod.url ~= ""
				and type(mod.sha256) == "string" and mod.sha256 ~= ""
				and NETWORK:IsUrlAllowed(mod.url)
			UP.state = {
				current   = UP.VERSION,
				latest    = man.version,
				notes     = tostring(man.notes or ""),
				available = available,
				inGame    = available and inGame or false,
				reason    = (available and not inGame) and "run the installer to get this one" or nil,
			}
			Refresh()
		end,
	}
end

-- Begin. The game does the whole job itself: the archive to /Downloads, the
-- checksum against the manifest, and Unzip over the module's own folder.
function UP.Start()
	local man = UP.manifest
	local mod = man and type(man.module) == "table" and man.module or nil
	if not (mod and mod.url and NETWORK:IsUrlAllowed(mod.url)) then return false end

	UP.job = { phase = "downloading", pct = 0 }
	local zipname = "cb-update.zip"
	NETWORK:HttpRequest{
		url = mod.url,
		downloadFile = zipname,
		connectTimeout = 10,
		onProgress = function(current, total)
			if total and total > 0 then
				UP.job = { phase = "downloading", pct = current / total }
			end
		end,
		onResponse = function(response)
			if state.retired then return end
			if response.error ~= nil or response.statusCode ~= 200 then
				UP.job = { phase = "error", done = true, pct = -1,
					error = response.errorMessage or ("HTTP " .. tostring(response.statusCode)) }
				Refresh()
				return
			end

			-- Everything below must happen inside this response: the engine
			-- deletes the downloaded file when the callback returns, and
			-- UP.Reload may only run from an HTTP response besides.
			local zip = "/Downloads/" .. zipname
			-- The engine hands back the digest as thirty-two raw bytes, not
			-- hex -- lua_pushlstring of the bare buffer -- so it is spelled
			-- out here before it can be compared with what the manifest says.
			local sum = CRYPTMAN:SHA256File(zip)
			local hex
			if type(sum) == "string" and #sum == 32 then
				local parts = {}
				for i = 1, #sum do
					parts[i] = string.format("%02x", sum:byte(i))
				end
				hex = table.concat(parts)
			end
			if not hex or hex ~= tostring(mod.sha256):lower() then
				UP.job = { phase = "error", done = true, pct = -1,
					error = "the download did not match its checksum" }
				Refresh()
				return
			end

			UP.job = { phase = "writing", pct = -1 }
			-- into the theme that is actually running this module: a fork
			-- keeps its own name, and writing into a folder that merely has
			-- the stock name would change nothing the player can see
			local dest = "/Themes/" .. THEME:GetCurThemeName() .. "/Modules/"
			if not FILEMAN:Unzip(zip, dest, 0) then
				UP.job = { phase = "error", done = true, pct = -1,
					error = "the new files could not be written" }
				Refresh()
				return
			end

			UP.job = { phase = "done", done = true, pct = 1,
				version = UP.state and UP.state.latest or nil }
			-- The new files are on disk. This is the one place they can be
			-- picked up -- see UP.Reload for why it has to be here.
			UP.Reload()
		end,
	}
	return true
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
