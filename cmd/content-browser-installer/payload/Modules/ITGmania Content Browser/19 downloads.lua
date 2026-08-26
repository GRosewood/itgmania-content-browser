-- -----------------------------------------------------------------------
-- Downloading a pack and putting it in place
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local DL               = CB.DL
local LO               = CB.LO
local PlaySfx          = CB.PlaySfx
local Toast            = CB.Toast
local UrlEncode        = CB.UrlEncode
local WebBase          = CB.WebBase
local refs             = CB.refs
local NormalizeName    = CB.NormalizeName
local Refresh          = CB.Refresh
local RAGEFILE_WRITE   = CB.RAGEFILE_WRITE
local SMO_BASE         = CB.SMO_BASE
local ScanInstalled    = CB.ScanInstalled
local Sync             = CB.Sync
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

	EngineDownload(pack, dl)
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

-- ------------------------------------------------- installing one song

-- A single song, without the pack. The relay re-serves the song's folder as
-- a small real archive -- the pack's own compressed bytes behind fresh
-- headers -- because that is the one shape the engine will unzip. The zip
-- goes to /Downloads, then Unzip lands it in the singles pack for its sync.
function DL.StartSong(pack, song)
	local title = type(song) == "table" and song.title or nil
	local id = pack and tonumber(pack.id)
	if not (id and title and title ~= "") then return false, "no song selected" end

	local root = WebBase() .. "/api/songzip/" .. id .. "/" .. UrlEncode(title)
	if not NETWORK:IsUrlAllowed(root) then
		local host = WebBase():match("^https?://([^/:]+)") or WebBase()
		return false, host .. " is missing from HttpAllowHosts"
	end

	-- which singles pack it belongs in, decided here from what SMO says so
	-- that the folder named in the popup is the folder it lands in
	local smo = Sync.Smo(pack)
	local sync = (smo == "null" or smo == "0") and "NULL" or "ITG"
	local folder = "Content Browser Singles - " .. sync .. " Sync"

	local key = "song:" .. id .. ":" .. title
	for _, existing in pairs(state.downloads) do
		if existing.songKey == key and existing.status ~= "error" then
			return false, "that song is already on its way"
		end
	end

	local dl = {
		status = "active", cur = 0, total = 0,
		name = title, single = true, songKey = key,
		sync = sync,
	}
	state.downloads[key] = dl
	local queued = false
	for existing in ivalues(state.dlOrder) do
		if existing == key then queued = true end
	end
	if not queued then state.dlOrder[#state.dlOrder+1] = key end

	DL.singleSeq = (DL.singleSeq or 0) + 1
	local zipname = "cb-single-" .. DL.singleSeq .. ".zip"
	NETWORK:HttpRequest{
		url = root,
		downloadFile = zipname,
		connectTimeout = 10,
		onProgress = function(current, total)
			dl.cur = current or 0
			if total and total > 0 then dl.total = total end
		end,
		onResponse = function(response)
			if response.error ~= nil or response.statusCode ~= 200 then
				dl.status = "error"
				dl.msg = response.errorMessage or ("HTTP " .. tostring(response.statusCode))
				Refresh()
				return
			end
			-- Unzip must run inside onResponse: the engine deletes the
			-- downloaded file when this callback returns.
			dl.status = "installing"
			local dest = "/Songs/" .. folder .. "/"
			if not FILEMAN:Unzip("/Downloads/" .. zipname, dest, 0) then
				dl.status = "error"
				dl.msg = "unzip failed"
				Refresh()
				return
			end

			-- The singles pack declares its sync once, so every song in it
			-- plays at the offset it was authored for.
			if not FILEMAN:DoesFileExist(dest .. "Pack.ini") then
				local nl = string.char(10)
				local f = RageFileUtil:CreateRageFile()
				if f:Open(dest .. "Pack.ini", RAGEFILE_WRITE) then
					f:Write("[Group]" .. nl
						.. "# Written by the ITGmania Content Browser." .. nl
						.. "# Songs downloaded one at a time land here, grouped by the" .. nl
						.. "# sync they were authored with, so this offset is right for" .. nl
						.. "# every song in it." .. nl
						.. "Version=1" .. nl
						.. "SyncOffset=" .. sync .. nl)
					f:Close()
				end
				f:destroy()
			end

			dl.status = "done"
			dl.finishedAt = GetTimeSinceStart()
			dl.groups = { folder }
			state.needsReload = true
			state.reloadSongs = state.reloadSongs + 1
			if state.open and state.mode == "installed" then ScanInstalled() end
			if not state.open then
				SCREENMAN:SystemMessage("Song installed: " .. title .. " (reload songs to play)")
			end
			Refresh()
		end,
	}
	return true
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
