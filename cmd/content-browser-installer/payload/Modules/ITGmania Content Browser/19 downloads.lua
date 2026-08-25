-- -----------------------------------------------------------------------
-- Downloading a pack and putting it in place
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local CheckHelper      = CB.CheckHelper
local DL               = CB.DL
local LO               = CB.LO
local PlaySfx          = CB.PlaySfx
local Toast            = CB.Toast
local refs             = CB.refs
local HelperUrl        = CB.HelperUrl
local LoadHelperConfig = CB.LoadHelperConfig
local NormalizeName    = CB.NormalizeName
local Refresh          = CB.Refresh
local SMO_BASE         = CB.SMO_BASE
local ScanInstalled    = CB.ScanInstalled
local Sync             = CB.Sync
local TidyProbeFiles   = CB.TidyProbeFiles
local state            = CB.state

-- Download and unpack through the engine, into whichever song folder it
-- decides on.
--
-- That decision is the problem this is no longer the first choice for: every
-- song folder is mounted at /Songs, and the file manager picks a driver for a
-- new file by counting the directories it would have to create, ties going to
-- the earliest-loaded. A pack that does not exist yet ties everywhere, so this
-- always lands in <install>/Songs even when the player's library is elsewhere.
-- It is kept because it needs nothing installed beyond the game itself.
local function EngineDownload(pack, dl)
	local uuid = "dl"
	if CRYPTMAN and CRYPTMAN.GenerateRandomUUID then
		uuid = CRYPTMAN:GenerateRandomUUID()
	else
		uuid = tostring(math.floor(GetTimeSinceStart()*1000))
	end
	local zipfile = "smo_" .. uuid .. ".zip"

	local before = {}
	for dir in ivalues(FILEMAN:GetDirListing("/Songs/", true, false)) do
		before[dir] = true
	end

	dl.request = NETWORK:HttpRequest{
		url = SMO_BASE .. "/download/pack/" .. pack.id .. "/",
		downloadFile = zipfile,
		connectTimeout = 15,
		onProgress = function(current, total)
			dl.cur = current or 0
			if total and total > 0 then dl.total = total end
		end,
		onResponse = function(response)
			dl.request = nil
			if response.error ~= nil then
				if ToEnumShortString(response.error) == "Cancelled" then
					state.downloads[pack.id] = nil
					return
				end
				dl.status = "error"
				dl.msg = response.errorMessage or "network error"
				Refresh()
				return
			end
			if response.statusCode ~= 200 then
				dl.status = "error"
				dl.msg = "HTTP " .. tostring(response.statusCode)
				Refresh()
				return
			end
			local contentType = ""
			if response.headers then
				contentType = response.headers["Content-Type"] or response.headers["content-type"] or ""
			end
			if not contentType:find("zip") then
				dl.status = "error"
				dl.msg = "server did not return a zip"
				Refresh()
				return
			end

			-- Unzip runs synchronously; the game will hitch for a moment on
			-- large packs.  This must happen inside onResponse because the
			-- engine deletes the downloaded file when this callback returns.
			dl.status = "installing"
			if FILEMAN:Unzip("/Downloads/" .. zipfile, "/Songs/", 0) then
				local groups = {}
				for dir in ivalues(FILEMAN:GetDirListing("/Songs/", true, false)) do
					if not before[dir] then groups[#groups+1] = dir end
				end
				dl.status = "done"
				dl.finishedAt = GetTimeSinceStart()
				dl.groups = groups
				state.needsReload = true
				state.reloadPacks = state.reloadPacks + 1
				DL.Remember(pack.name)
				-- Every pack that arrives through this browser gets a Pack.ini
				-- written for it if the download had none. It used to depend on
				-- the pack having a date, which left the undated ones with
				-- nothing declared -- and a pack with nothing declared is
				-- exactly what the installed list flags amber.
				state.autoSync[NormalizeName(pack.name)] =
					(pack.date ~= nil and pack.date ~= "") and pack.date or "installed"
				-- the unzip will have littered the new pack with empty probe
				-- files; clear them before anybody looks in the folder
				CheckHelper()
				TidyProbeFiles()
				if not state.open then
					SCREENMAN:SystemMessage("Pack installed: " .. pack.name .. " (reload songs to play)")
				end
			else
				dl.status = "error"
				dl.msg = "unzip failed"
			end
			Refresh()
		end,
	}
end

-- Start a download, by whichever route is available.
--
-- The helper writes into the song folder the player configured, which is the
-- whole reason it is preferred: on a machine whose library is a mounted drive,
-- the engine's own unzip puts packs somewhere the player is not looking, and on
-- one whose Songs directory is read-only it fails outright.
local function StartDownload(pack)
	if state.downloads[pack.id] and state.downloads[pack.id].status ~= "error" then
		return
	end
	-- already on disk: removing it is the only way to ask for it again
	if SONGMAN:DoesSongGroupExist(pack.name) then
		return
	end

	local dl = { status="active", cur=0, total=pack.bytes or 0, name=pack.name }
	state.downloads[pack.id] = dl
	-- queue order, so the header strip does not reshuffle itself every frame
	local queued = false
	for id in ivalues(state.dlOrder) do
		if id == pack.id then queued = true end
	end
	if not queued then state.dlOrder[#state.dlOrder+1] = pack.id end

	if not DL.StartViaHelper(pack, dl) then
		EngineDownload(pack, dl)
	end
end

-- true once a completed download's new group is actually loaded in SONGMAN
-- (i.e. a song reload has happened since it was installed)
local function DownloadLoaded(dl)
	if not (dl and dl.groups) then return false end
	for group in ivalues(dl.groups) do
		if SONGMAN:DoesSongGroupExist(group) then return true end
	end
	return false
end

local function DownloadsActive()
	for _, dl in pairs(state.downloads) do
		if dl.status == "active" or dl.status == "installing" then return true end
	end
	return false
end

-- ------------------------------------------------- installing via the helper
--
-- Defined here rather than beside the rest of DL because it needs the helper
-- client below it in the file; DL is a table, so its methods can be added
-- wherever the things they call are in scope.

-- Ask the helper to install a pack. Returns whether it took the job.
function DL.StartViaHelper(pack, dl)
	local h = state.helper
	if not h.config then h.config = LoadHelperConfig() end
	if not h.config then return false end
	local id = tonumber(pack.id)
	if not id then return false end
	local url = HelperUrl("/install")
	if not NETWORK:IsUrlAllowed(url) then return false end

	dl.viaHelper = true
	dl.helperKey = "pack:" .. id
	NETWORK:HttpRequest{
		url = url,
		method = "POST",
		body = JsonEncode({ pack = id, name = pack.name }),
		headers = {
			["X-Browser-Token"] = h.config.token,
			["Content-Type"]    = "application/json",
		},
		connectTimeout = 5,
		transferTimeout = 20,
		onResponse = function(response)
			local ok, data = pcall(JsonDecode, response.body or "")
			local took = response.error == nil and ok
				and type(data) == "table" and data.ok == true
			if took then return end
			-- The helper is installed but would not take it. Rather than leave
			-- the player with a stuck row, hand the job to the engine and let
			-- it land wherever it lands.
			dl.viaHelper, dl.helperKey = nil, nil
			EngineDownload(pack, dl)
			Refresh()
		end,
	}
	return true
end

-- Ask the helper for one song out of a pack.
--
-- It lands in a "Content Browser Singles" pack chosen by the sync the source
-- pack declares, so songs that need the 9ms bias removed never share a folder
-- with songs that do not. The helper reads that from the pack's own Pack.ini
-- inside the archive, which is a better answer than anything this end knows.
function DL.StartSong(pack, song)
	local title = type(song) == "table" and song.title or nil
	local id = pack and tonumber(pack.id)
	if not (id and title and title ~= "") then return false, "no song selected" end

	local h = state.helper
	if not h.config then h.config = LoadHelperConfig() end
	if not h.config then
		return false, "single songs need the content browser helper installed"
	end
	local url = HelperUrl("/single")
	if not NETWORK:IsUrlAllowed(url) then
		return false, "127.0.0.1 is missing from HttpAllowHosts"
	end

	-- which singles pack it belongs in, decided here from what SMO says so
	-- that the folder named in the popup is the folder it lands in
	local smo = Sync.Smo(pack)
	local sync = (smo == "null" or smo == "0") and "NULL" or "ITG"

	local key = "song:" .. id .. ":" .. title
	for _, existing in pairs(state.downloads) do
		if existing.helperKey == key and existing.status ~= "error" then
			return false, "that song is already on its way"
		end
	end

	local dl = {
		status = "active", cur = 0, total = 0,
		name = title, single = true,
		viaHelper = true, helperKey = key,
	}
	state.downloads[key] = dl
	-- queue order, and only once: retrying a song that failed used to append
	-- a second entry, and the strip drew the same download twice
	local queued = false
	for id in ivalues(state.dlOrder) do
		if id == key then queued = true end
	end
	if not queued then state.dlOrder[#state.dlOrder+1] = key end

	NETWORK:HttpRequest{
		url = url,
		method = "POST",
		body = JsonEncode({ pack = id, song = title, sync = sync }),
		headers = {
			["X-Browser-Token"] = h.config.token,
			["Content-Type"]    = "application/json",
		},
		connectTimeout = 5,
		transferTimeout = 20,
		onResponse = function(response)
			local ok, data = pcall(JsonDecode, response.body or "")
			if response.error ~= nil or not (ok and type(data) == "table" and data.ok) then
				dl.status = "error"
				dl.msg = (ok and type(data) == "table" and data.error)
					or "the helper would not take it"
				Refresh()
			end
		end,
	}
	return true
end

-- is anything waiting on the helper right now?
function DL.Watching()
	for _, dl in pairs(state.downloads) do
		if dl.viaHelper and (dl.status == "active" or dl.status == "installing") then
			return true
		end
	end
	return false
end

-- Read where the helper's installs have got to, and fold that into the queue.
-- The rows the header draws come from state.downloads either way, so nothing
-- downstream has to know which route a pack took.
function DL.Poll()
	local h = state.helper
	if not h.config or DL.polling then return end
	local url = HelperUrl("/install/progress")
	if not NETWORK:IsUrlAllowed(url) then return end

	DL.polling = true
	NETWORK:HttpRequest{
		url = url,
		headers = { ["X-Browser-Token"] = h.config.token },
		connectTimeout = 3,
		transferTimeout = 8,
		onResponse = function(response)
			DL.polling = false
			if response.error ~= nil then return end
			local ok, data = pcall(JsonDecode, response.body or "")
			if not ok or type(data) ~= "table" or type(data.installs) ~= "table" then
				return
			end
			local changed = false
			for job in ivalues(data.installs) do
				-- matched on the id the job was started with, because the
				-- catalogue hands out ids as strings and the helper as numbers
				for _, dl in pairs(state.downloads) do
					if dl.helperKey and dl.helperKey == job.key then
						changed = DL.Apply(dl, job) or changed
					end
				end
			end
			if changed then Refresh() end
		end,
	}
end

-- one job's state, folded onto the row that is drawing it
function DL.Apply(dl, job)
	local before = dl.status .. tostring(dl.cur)
	dl.cur = tonumber(job.done) or dl.cur
	if tonumber(job.total) and tonumber(job.total) > 0 then
		dl.total = tonumber(job.total)
	end
	dl.root = job.root
	if job.sync and job.sync ~= "" then dl.sync = job.sync end

	local phase = tostring(job.phase or "")
	if phase == "downloading" then
		dl.status = "active"
	elseif phase == "unpacking" then
		dl.status = "installing"
	elseif phase == "failed" then
		dl.status = "error"
		dl.msg = tostring(job.error or "install failed")
	elseif phase == "done" and dl.status ~= "done" then
		dl.status = "done"
		dl.finishedAt = GetTimeSinceStart()
		dl.groups = {}
		if type(job.groups) == "table" then
			for g in ivalues(job.groups) do dl.groups[#dl.groups+1] = g end
		end
		state.needsReload = true
		-- a single is not a pack, so it is not something to remember the
		-- arrival date of, and its folder already exists
		if dl.single then
			state.reloadSongs = state.reloadSongs + 1
		else
			state.reloadPacks = state.reloadPacks + 1
			DL.Remember(dl.name)
		end
		-- so the assumed-sync pass writes this pack a Pack.ini
		state.autoSync[NormalizeName(dl.name)] = "installed"
		-- Standing on the Installed tab while this landed? Then the list in
		-- front of the reader is the one thing that ought to show it, and it is
		-- only rebuilt on the way in. Rebuild it where they are.
		if state.open and state.mode == "installed" then ScanInstalled() end
		if not state.open then
			SCREENMAN:SystemMessage("Pack installed: " .. dl.name .. " (reload songs to play)")
		end
	end
	return before ~= (dl.status .. tostring(dl.cur))
end

function DL.Forget(pack)
	if not (pack and pack.id) then return end
	state.downloads[pack.id] = nil
	for index = #state.dlOrder, 1, -1 do
		if state.dlOrder[index] == pack.id then
			table.remove(state.dlOrder, index)
		end
	end
	state.dlRows = DL.Rows()
end

function DL.Ask(pack)
	if not pack then
		PlaySfx("invalid")
		return
	end
	local dl = state.downloads[pack.id]
	if SONGMAN:DoesSongGroupExist(pack.name) then
		PlaySfx("invalid")
		Toast(pack.name .. " is already in your library"
			.. " - remove it from the Installed tab first")
	elseif dl and (dl.status == "active" or dl.status == "installing") then
		PlaySfx("invalid")
		Toast("Already downloading - watch the queue up in the corner")
	elseif dl and dl.status == "done" then
		PlaySfx("invalid")
		Toast(DownloadLoaded(dl) and "Already installed"
			or "Already installed - reload songs to play it")
	elseif not (LO.SpaceFor(pack)) then
		-- Refused rather than warned. A download that runs the disk out takes
		-- the rest of the library down with it -- a half-written unzip, a
		-- Preferences.ini the engine cannot save -- and the pack is still there
		-- to fetch once there is room.
		PlaySfx("invalid")
		local _, why = LO.SpaceFor(pack)
		Toast(why or "Not enough room on the drive for this pack")
	else
		PlaySfx("start")
		StartDownload(pack)
		-- say plainly that leaving does not cancel it, because the queue in
		-- the corner is the only thing that says otherwise
		Toast("Downloading " .. pack.name
			.. " - keep browsing, you can start others too")
		if refs.heart then refs.heart:playcommand("SMOArmHeartbeat") end
	end
end

-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.DownloadLoaded  = DownloadLoaded
CB.DownloadsActive = DownloadsActive
CB.StartDownload   = StartDownload
