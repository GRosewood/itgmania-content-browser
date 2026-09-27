-- -----------------------------------------------------------------------
-- Downloading a pack and putting it in place
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local BROWSER_DATA_DIR = CB.BROWSER_DATA_DIR
local DL               = CB.DL
local LO               = CB.LO
local PlaySfx          = CB.PlaySfx
local Toast            = CB.Toast
local UrlEncode        = CB.UrlEncode
local WebBase          = CB.WebBase
local refs             = CB.refs
local NormalizeName    = CB.NormalizeName
local Refresh          = CB.Refresh
local RAGEFILE_READ    = CB.RAGEFILE_READ
local RAGEFILE_WRITE   = CB.RAGEFILE_WRITE
local SMO_BASE         = CB.SMO_BASE
local ScanInstalled    = CB.ScanInstalled
local Sync             = CB.Sync
local Trim             = CB.Trim
local state            = CB.state

-- ------------------------------------------------- where a download lands
--
-- A pack is unpacked through the engine into /Songs, and /Songs is every song
-- folder the game has at once: its own, plus any listed in Preferences.ini.
-- For a pack folder that does not exist yet, the engine tries the newest mount
-- first, and it mounts whole trees (AdditionalFolders*) before song folders
-- (AdditionalSongFolders*), each list in the order written. So a writable song
-- folder the player listed is where a download goes, ahead of any tree and of
-- the game's own Songs folder. (A note here once said a download always went
-- to the game's own folder. The engine was run to check; it does not.)
--
-- What the engine will not do is write into a folder listed ...ReadOnly -- or
-- say so. It carries on to the next folder that takes writes, and Unzip reports
-- success. That is the ITG System Image as shipped: its start script lists the
-- songs drive under AdditionalSongFoldersReadOnly (and mounts it read-only) on
-- every start, with /mnt/stepmania as the one writable tree, so every download
-- lands in /mnt/stepmania/Songs while the drive meant for songs sits untouched.
-- The installer can change that on the image. Where it has not, this asks
-- before a download goes somewhere the player did not mean it to.

-- The folders one preference lists, in the order the engine mounts them.
local function PrefDirs(name)
	local dirs = {}
	local ok, value = pcall(PREFSMAN.GetPreference, PREFSMAN, name)
	if not (ok and type(value) == "string") then return dirs end
	for dir in value:gmatch("[^,]+") do
		dir = Trim(dir)
		if dir ~= "" then dirs[#dirs+1] = dir end
	end
	return dirs
end

-- The player's song library, when a download cannot go into it: their song
-- folder is listed read-only and no writable one is. Returns nil otherwise.
-- instead is the Songs/ of the writable tree that gets the pack, or nil for
-- the game's own Songs folder.
--
-- Read-only whole trees are not counted. Those often carry themes or
-- noteskins rather than songs, and a question about a library the player does
-- not have would be worse than none.
function DL.ReadOnlyLibrary()
	if #PrefDirs("AdditionalSongFoldersWritable") > 0 then return nil end
	local ro = PrefDirs("AdditionalSongFoldersReadOnly")
	if #ro == 0 then return nil end
	local trees = PrefDirs("AdditionalFoldersWritable")
	return { dir = ro[#ro], instead = trees[#trees] and (trees[#trees] .. "/Songs") or nil }
end

-- Where a pack goes when the library will not take it, in words for a toast.
function DL.InsteadWords(lib)
	return (lib and lib.instead) or "the game's own Songs folder"
end

-- What the installer last noted about this machine, in installer.txt beside
-- the browser's saved state: { version = "0.9", ["songs-drive"] = "writable"
-- or "read-only" }. Empty when it never ran, or ran before it kept a note --
-- 0.8 and older -- which is how a machine that needs the installer run again
-- is told apart from one that has had it.
function DL.InstallerRecord()
	local rec = {}
	local f = RageFileUtil:CreateRageFile()
	if f:Open(BROWSER_DATA_DIR .. "installer.txt", RAGEFILE_READ) then
		local body = f:Read() or ""
		f:Close()
		for line in body:gmatch("[^\r\n]+") do
			local key, value = line:match("^%s*(%S+)%s+(.-)%s*$")
			if key then rec[key] = value end
		end
	end
	f:destroy()
	return rec
end

-- Before a download goes somewhere the player did not choose, ask. Once a
-- session: the answer stands for the downloads after it, and each of those
-- still says where it is going. Not at all when the player chose the
-- read-only drive when the installer offered to change it -- they know.
-- Returns whether to go ahead, and the library when it is one that will not
-- take the pack.
function DL.Gate(pack, song)
	local lib = DL.ReadOnlyLibrary()
	if not lib then return true, nil end
	if state.libraryOk then return true, lib end
	if DL.InstallerRecord()["songs-drive"] == "read-only" then return true, lib end
	state.libraryAsk = { pack = pack, song = song, dir = lib.dir, instead = lib.instead }
	return false, lib
end

-- Download and unpack through the engine, into whichever song folder it
-- decides on (see above). DL.Gate has already asked, when that is not the
-- player's library.
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

	-- what the answer means for the pack; the progress window hears after
	local function Settle(response)
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
	end

	-- no onProgress: DL.Measure reads how far it has got off the disk
	dl.file = "/Downloads/" .. zipfile
	dl.request = NETWORK:HttpRequest{
		url = SMO_BASE .. "/download/pack/" .. pack.id .. "/",
		downloadFile = zipfile,
		connectTimeout = 15,
		onResponse = function(response)
			dl.request = nil
			Settle(response)
			DL.Landed(pack.id)
		end,
	}
end

-- Start a download, unless one for this pack is already going or it is
-- already installed.
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

-- ------------------------------------------------- how far a download has got
--
-- Read off the disk, not heard from the engine. Its onProgress runs once for
-- every 16 KB that arrives, each run queued for the game's thread, and that
-- queue is emptied no faster than 32 a frame. On a fast line it fell seconds
-- behind, and the download's own answer queued at the back of it: a cancel
-- took eight seconds to land, and a pack already in waited on a bar still
-- climbing towards it.
--
-- The engine writes the zip under its own name as it arrives, so the size of
-- that file is the progress. RageFile will not say how big a file is, and
-- FILEMAN answers from a listing it keeps for thirty seconds -- but a read at
-- an offset past the end finds nothing, so galloping up from the last answer
-- and halving back finds the end in a couple of dozen seeks.

-- How much of the file at path is on disk, to within 16 KB, or nil when it
-- cannot be opened. known is a size it has already reached.
local function BytesOnDisk(path, known)
	local f = RageFileUtil:CreateRageFile()
	if not f:Open(path, RAGEFILE_READ) then
		f:destroy()
		return nil
	end
	-- whether there is a byte at offset n
	local function Has(n)
		f:Seek(n)
		f:ReadBytes(1)
		return not f:AtEOF()
	end
	local MOST = 2147483646   -- Seek takes an int
	local lo, step = math.max(0, known or 0), 262144
	local hi = math.min(lo + step, MOST)
	while hi < MOST and Has(hi) do
		lo, step = hi + 1, step * 2
		hi = math.min(lo + step, MOST)
	end
	while hi - lo > 16384 do
		local mid = math.floor((lo + hi) / 2)
		if Has(mid) then lo = mid + 1 else hi = mid end
	end
	f:Close()
	f:destroy()
	return lo
end

-- Bring each running download's count up to date. The heartbeat calls this,
-- five times a second while the browser is open.
function DL.Measure()
	for _, dl in pairs(state.downloads) do
		if dl.status == "active" and dl.file then
			local got = BytesOnDisk(dl.file, dl.cur)
			if got and got > (dl.cur or 0) then
				dl.cur = got
				-- SMO's listed size was wrong if the file has outgrown it,
				-- and a bar stuck full would be wrong too
				if (dl.total or 0) > 0 and got > dl.total then dl.total = 0 end
			end
		end
	end
end

-- ------------------------------------------------- the progress window
--
-- A download holds the browser until it is in, behind a window with its
-- progress and a way out.
--
-- Not by choice: the engine fetches everything it saves to disk -- packs,
-- banners, song art, preview audio -- over one connection, one file at a time
-- (every downloadFile request goes to the same client, which works through
-- them in order; on 1.3.0 a tiny download queued behind an eight-second one
-- finished at 7.7 s). So while a pack is coming in, the art and previews of
-- whatever the player moved on to would sit behind all of it, and a theme has
-- no other way to get a picture or a sound onto the disk. A browser that looks
-- broken for minutes is worse than one that says plainly it is busy.

-- Put up the window for a download. into, when given, is where it lands, for
-- saying so when that is not the usual place.
function DL.Watch(key, into)
	local dl = state.downloads[key]
	if not dl then return end
	if into then dl.into = into end
	state.dlWatch = key
	state.dlCancelArmed = nil
	if refs.heart then refs.heart:playcommand("SMOArmHeartbeat") end
	Refresh()
end

-- A watched download's answer has been dealt with. Installed or cancelled, the
-- window goes; a failure stays up, saying why, until the player puts it away.
function DL.Landed(key)
	if state.dlWatch ~= key then return end
	local dl = state.downloads[key]
	if not dl or dl.status == "done" then
		state.dlWatch, state.dlCancelArmed = nil, nil
	end
	if dl and dl.status == "done" then
		if dl.single then
			Toast("Added " .. dl.name .. " - reload songs when you leave to play it")
		else
			Toast("Installed " .. dl.name .. " - reload songs when you leave to play it")
		end
	end
	Refresh()
end

-- Stop the watched download. The engine answers it as cancelled, and
-- DL.Landed takes the window down then.
function DL.CancelWatched()
	local dl = state.dlWatch and state.downloads[state.dlWatch]
	if not (dl and dl.status == "active") then return end
	dl.cancelling = true
	if dl.request then dl.request:Cancel() end
	Refresh()
end

-- ------------------------------------------------- installing one song

-- A single song, without the pack. The relay re-serves the song's folder as
-- a small real archive -- the pack's own compressed bytes behind fresh
-- headers -- because that is the one shape the engine will unzip. The zip
-- goes to /Downloads, then Unzip lands it in the singles pack for its sync.
--
-- Returns true when it started (then the read-only library, if that is why it
-- is going somewhere else, and the download's key), false and why when it
-- cannot, and nil when it stopped to ask about the library first.
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

	local go, refused = DL.Gate(pack, song)
	if not go then return nil end

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
	-- what the answer means for the song; the progress window hears after
	local function Settle(response)
		if response.error ~= nil and ToEnumShortString(response.error) == "Cancelled" then
			state.downloads[key] = nil
			return
		end
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
	end

	-- no onProgress, as for a pack: DL.Measure reads it off the disk
	dl.file = "/Downloads/" .. zipname
	dl.request = NETWORK:HttpRequest{
		url = root,
		downloadFile = zipname,
		connectTimeout = 10,
		onResponse = function(response)
			dl.request = nil
			Settle(response)
			DL.Landed(key)
		end,
	}
	return true, refused, key
end

-- "Get this song", with what happened said out loud. The folder is named up
-- front because it is where to look afterwards.
function DL.AskSong(pack, song)
	-- after "started", the second answer is the read-only library if there
	-- is one; after "cannot", it is why
	local ok, more, key = DL.StartSong(pack, song)
	if ok then
		PlaySfx("start")
		-- the singles pack it joins is named, because that is where to look
		DL.Watch(key, more and DL.InsteadWords(more) or Sync.SinglesFolder(pack))
	elseif ok == nil then
		PlaySfx("start")   -- the library dialog is up, and asks the rest
	else
		PlaySfx("invalid")
		Toast(tostring(more))
	end
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
		-- still coming in from before: back to its window
		PlaySfx("start")
		DL.Watch(pack.id)
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
		local go, refused = DL.Gate(pack)
		PlaySfx("start")
		if not go then return end   -- the library dialog takes it from here
		StartDownload(pack)
		-- where it lands is said when it is not the player's library
		DL.Watch(pack.id, refused and DL.InsteadWords(refused) or nil)
	end
end

-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.DownloadLoaded  = DownloadLoaded
CB.DownloadsActive = DownloadsActive
CB.StartDownload   = StartDownload
