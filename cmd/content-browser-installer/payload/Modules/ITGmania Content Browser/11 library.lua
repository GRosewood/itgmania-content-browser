-- -----------------------------------------------------------------------
-- The songs folder, pack sync, and the helper service
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local NormalizeName = CB.NormalizeName
local Refresh       = CB.Refresh
local UP            = CB.UP
local UrlEncode     = CB.UrlEncode
local state         = CB.state

-- The local library, cross-checked against SMO.  Song counts come from
-- SONGMAN; the SMO side reuses the /api/packs CSV that already backs the
-- pad/keyboard filter, so the comparison costs no extra requests.
--
-- Packs are removed from here without leaving the game; see the helper block
-- below for how, and why it has to work that way.

local BROWSER_DATA_DIR = "/Save/ITGmaniaContentBrowser/"
local INST_COLS        = 2
local INST_ROWS        = 22   -- packs visible at once: INST_COLS columns of 11
local RAGEFILE_READ    = 1
-- WRITE|STREAMED rather than plain WRITE. Plain WRITE writes a temp file and
-- renames it into place from the file object's destructor, but Close() tells
-- the filename cache about the final path BEFORE that rename -- so the cache
-- stats a file that is not there yet, gives up, and the directory listing
-- stays stale for thirty seconds. STREAMED opens the real path directly, which
-- is what the engine's own Unzip does. The usual objection to it, that a crash
-- mid-write truncates whatever was there, cannot apply: nothing here writes
-- over an existing file.
local RAGEFILE_WRITE   = 6

-- ---------------------------------------------------------------
-- pack sync.
--
-- ITGmania reads Pack.ini's [Group] SyncOffset. "ITG" says the charts carry
-- the arcade 9ms bias and the engine subtracts it; "NULL" says there is
-- nothing to correct. With no Pack.ini at all the machine's DefaultSyncOffset
-- preference decides, and that ships as ITG -- so a genuinely ITG-synced pack
-- is already right without a file, and only a NULL-synced one is wrong.
--
-- Nothing published will tell you which a pack needs. SMO's Sync field has no
-- value for ITG at all (its whole vocabulary is n/a, null, 0, mixed, other)
-- and it lists In The Groove 2 -- the pack the 9ms offset is named after -- as
-- "null". The community NULL Progress sheet is one-sided in the same way: it
-- records NULL or blank, and blank means "not looked at yet", never "ITG". Of
-- the packs on this machine that ship an author-written Pack.ini, five that
-- the sheet marks NULL declare SyncOffset=ITG.
--
-- So: report what SMO says and attribute it, read the real answer off disk
-- where a pack supplies one, and never write a guess.
local Sync = {}

-- SMO's own tag for a pack, lowercased, or nil when it lists nothing
function Sync.Smo(pack)
	if not pack then return nil end
	local det = state.details[pack.id]
	local raw = det and det.stats and det.stats.sync
	if not raw and state.packSync then raw = state.packSync[tostring(pack.id)] end
	raw = raw and tostring(raw):lower() or nil
	if not raw or raw == "" or raw == "n/a" or raw == "none" then return nil end
	return raw
end

-- one line for the info pane of a pack being browsed
function Sync.Line(pack)
	local smo = Sync.Smo(pack)
	if smo == "null" or smo == "0" then return "sync: NULL, per SMO" end
	if smo then return "sync: " .. smo .. ", per SMO" end
	return "sync: not listed"
end

-- What a pack on disk declares. Returns the value and the filename it came
-- from, or nil when the pack has no Pack.ini. Both spellings occur in the
-- wild, so both are tried.
-- Stamped into any file this module writes, so a value it assumed can still be
-- told apart from one the pack's author declared.
local SYNC_MARK = "Written by the ITGmania Content Browser."

function Sync.OnDisk(dir)
	if not dir then return nil end
	for name in ivalues({"Pack.ini", "pack.ini"}) do
		local path = dir .. name
		if FILEMAN:DoesFileExist(path) then
			local file = RageFileUtil:CreateRageFile()
			local value, ours
			if file:Open(path, RAGEFILE_READ) then
				local body = file:Read()
				file:Close()
				value = body and body:match("[Ss]ync[Oo]ffset%s*=%s*(%w+)")
				ours = body ~= nil and body:find(SYNC_MARK, 1, true) ~= nil
			end
			file:destroy()
			return (value and value:upper() or "?"), name, ours
		end
	end
	return nil
end

-- Which singles pack a song from here would land in. The helper decides for
-- real by reading the pack's own Pack.ini out of the archive; this is the same
-- rule applied to what SMO says, so the popup can name the folder before the
-- download starts rather than after.
function Sync.SinglesFolder(pack)
	local smo = Sync.Smo(pack)
	local which = (smo == "null" or smo == "0") and "NULL" or "ITG"
	return "Content Browser Singles - " .. which .. " Sync"
end

-- how a pack's on-disk sync reads in a list
function Sync.DiskLabel(value, ours)
	local suffix = ours and ", assumed" or ""
	if value == "NULL" then return "sync: NULL" .. suffix end
	if value == "ITG" then return "sync: 9ms (ITG)" .. suffix end
	if value then return "sync: " .. value .. suffix end
	return "no Pack.ini"
end

-- Write one. Version is not optional: the engine gates the whole [Group]
-- parse on it and silently discards every other key when it is missing, so a
-- file carrying only SyncOffset does nothing at all. Refuses point blank when
-- the pack already has a file -- that one was written by whoever made the
-- pack, and rewriting it would throw away its title and banner keys too.
function Sync.Write(dir, value)
	if not dir then return false, "this pack's folder could not be found" end
	if value ~= "NULL" and value ~= "ITG" then return false, "invalid sync value" end
	-- An author's file is left alone: it carries title, banner and series keys
	-- that rewriting would throw away with the sync. One this browser wrote
	-- holds nothing but a version and an offset, so changing your mind about it
	-- costs nothing and is the only way to correct a guess.
	local existing, _, ours = Sync.OnDisk(dir)
	if existing and not ours then
		return false, "this pack came with its own Pack.ini"
	end
	local file = RageFileUtil:CreateRageFile()
	local ok = false
	if file:Open(dir .. "Pack.ini", RAGEFILE_WRITE) then
		file:PutLine("[Group]")
		file:PutLine("# " .. SYNC_MARK)
		file:PutLine("# Delete this file to hand the pack back to the machine's")
		file:PutLine("# DefaultSyncOffset preference.")
		file:PutLine("Version=1")
		file:PutLine("SyncOffset=" .. value)
		file:Close()
		ok = true
	end
	file:destroy()
	if not ok then return false, "could not write to the pack folder" end
	return true
end

-- ---------------------------------------------------------------------------
-- Is a pack going to feel right?
--
-- The engine settles one offset per pack when it loads the library: -0.009s for
-- an ITG synced pack, whose charts carry the arcade's 9ms bias for the engine
-- to take back out, and 0.0 for a NULL synced one that never had it. A Pack.ini
-- with SyncOffset= decides that for a pack. Without one, the machine's
-- DefaultSyncOffset decides for every unlabelled pack at once.
--
-- Which puts a pack in one of three states, and they deserve different colours:
--
--   good  the pack pins its own sync. Nothing on this machine can change it,
--         and carrying it to another machine will not either.
--   warn  nothing pins it. It is playing at a preference, which is probably
--         right, but a preference is not a fact and it applies library-wide.
--   bad   nothing pins it, and something credible disagrees with what is being
--         applied. This pack really is playing 9ms away from its charts.

-- What this machine does with a pack that says nothing for itself. The
-- preference is an enum, and how an enum reaches Lua depends on the binding, so
-- every shape it could arrive in is read rather than one being assumed.
function Sync.Machine()
	local raw
	if PREFSMAN and PREFSMAN.GetPreference then
		local ok, v = pcall(function() return PREFSMAN:GetPreference("DefaultSyncOffset") end)
		if ok then raw = v end
	end
	if type(raw) == "number" then return (raw == 0) and "NULL" or "ITG" end
	local text = tostring(raw or ""):upper()
	if text:find("NULL", 1, true) then return "NULL" end
	if text:find("ITG", 1, true) then return "ITG" end
	return "ITG"   -- what the engine ships as, if nothing answers
end

function Sync.MachineLabel()
	local m = Sync.Machine()
	return (m == "NULL") and "NULL (0ms)" or "ITG (+9ms)"
end

-- What the engine actually resolved for this pack, read off the Group object it
-- built at load. The real answer, rather than a re-derivation of one.
function Sync.Applied(pack)
	local off = pack and pack.applied
	if off == nil then return nil end
	return (off < -0.004) and "ITG" or "NULL"
end

-- SMO's tag for an installed pack, which carries no id of its own to look up by.
function Sync.SmoFor(pack)
	if not (pack and state.smoByName and state.packSync) then return nil end
	local rec = state.smoByName[NormalizeName(pack.name)]
	local raw = rec and state.packSync[tostring(rec.id)]
	raw = raw and tostring(raw):lower() or nil
	if not raw or raw == "" or raw == "n/a" or raw == "none" then return nil end
	if raw == "null" or raw == "0" then return "NULL" end
	if raw == "itg" then return "ITG" end
	return nil
end

-- What the pack ought to be, and how confidently.
--
-- The fallback for anything unlabelled is ITG, and it is the conservative one:
-- the 9ms bias is what packs carried in the years before Pack.ini existed to
-- say otherwise, and it is already what the engine applies by default.
function Sync.Believed(pack)
	if pack and (pack.sync == "ITG" or pack.sync == "NULL") and not pack.syncOurs then
		return pack.sync, "declared"
	end
	local smo = Sync.SmoFor(pack)
	if smo then return smo, "smo" end
	return "ITG", "assumed"
end

-- The value the writer should offer. Legacy packs get ITG, per the above.
function Sync.Suggest(pack)
	return (Sync.Believed(pack))
end

-- "good" or "warn", and a sentence saying why.
--
-- There is no third state. Whether a pack is actually playing off sync is not
-- knowable from here: the only evidence is what it declares against what the
-- engine applied, and that only ever disagrees while a reload is pending.
function Sync.Health(pack)
	if not pack then return "warn", "" end
	local applied = Sync.Applied(pack)
	local pinned = (pack.sync == "ITG" or pack.sync == "NULL")

	if pinned then
		-- Nothing here is ever reported as definitely off sync.
		--
		-- There is no test for it. The only evidence available is what a pack
		-- declares against what the engine applied, and a disagreement between
		-- those means the file was written after the library was loaded -- a
		-- pending reload, not a fault. And nothing can be inferred from SMO
		-- either: they have been re-syncing packs and re-serving them under the
		-- same name, so a local copy with no Pack.ini may be an older ITG one
		-- that is entirely correct, whatever their catalogue says about the
		-- copy they hand out today.
		--
		-- So this is amber, with the one thing that clears it.
		if applied and applied ~= pack.sync then
			return "warn", "its Pack.ini says " .. pack.sync .. " - reload songs and it "
				.. "will play as " .. pack.sync
		end
		-- Green: something says what this pack is, and it is playing that way.
		-- Which file said so does not change that, so it is said plainly.
		return "good", pack.syncOurs
			and ("its Pack.ini says " .. pack.sync .. ", written from here")
			or  ("its Pack.ini says " .. pack.sync)
	end

	local believed, how = Sync.Believed(pack)
	local now = applied or Sync.Machine()
	if how == "smo" and believed ~= now then
		return "warn", "SMO lists this pack as " .. believed
			.. ", and yours has no Pack.ini of its own."
	end
	if how == "smo" then
		return "warn", "SMO lists this pack as " .. believed
			.. ", and it plays that way, but it has no Pack.ini to say so"
	end
	return "warn", "no Pack.ini, so it plays at this machine's default (" .. now .. ")"
end

function Sync.HealthColor(health)
	if health == "good" then return 0.40, 0.85, 0.45 end
	-- kept so an older cached verdict cannot fall through to amber unnoticed,
	-- though nothing produces one any more
	if health == "bad" then return 1.00, 0.42, 0.42 end
	return 0.97, 0.78, 0.30
end

-- The short form beside a pack in the list.
-- What a row says about its sync.
--
-- Just the value. It used to add whether the file was "pinned" or came from
-- SMO, which is vocabulary this screen invented for itself: a reader scanning a
-- list of ninety packs wants to know what each one plays at, and every extra
-- word in that column is one more thing to decode. Where the answer came from
-- belongs on the sync screen, which is where somebody has stopped to ask.
function Sync.RowLabel(pack)
	if pack.sync then return "sync " .. pack.sync end
	return "no Pack.ini - using " .. (Sync.Applied(pack) or Sync.Machine())
end

-- Why SMO's answer is evidence rather than proof.
-- The standing explanation, shown on the sync screen whatever it is being
-- opened for.
function Sync.Explain()
	return "A pack is either ITG synced -- its charts include the 9ms ITG offset -- "
		.. "or NULL synced, with no offset. A Pack.ini says which. Without one, the "
		.. "pack plays at this machine's default.\n\n"
		.. "Packs made before Pack.ini existed are ITG, so that is what an unknown pack "
		.. "is taken to be here, and what gets written unless you say otherwise.\n\n"
		.. "If you know what a pack really is -- you made it, or you have played it "
		.. "enough to be sure -- set it here. That writes a Pack.ini for the pack, and "
		.. "you can change it again any time."
end

-- /Songs/<Group>/<Song>/  ->  /Songs/<Group>/
local function GroupDirFor(songs)
	if #songs == 0 then return nil end
	local dir = songs[1]:GetSongDir()
	if not dir or dir == "" then return nil end
	local trimmed = dir:gsub("/+$", "")
	local parent = trimmed:match("^(.*)/[^/]+$")
	return parent and (parent .. "/") or nil
end

-- ---------------------------------------------------------------
-- deleting a pack, from inside the game.
--
-- ITGmania's Lua API cannot delete anything: RageFileManager exposes only
-- Copy, DoesFileExist, GetFileSizeBytes, GetHashForFile, GetDirListing and
-- Unzip, and there is no delete, move or rename anywhere else in the API.
-- What Lua CAN do is open a file for writing, which truncates it -- so a
-- pack is emptied file by file further down, and the next song reload drops
-- the hollowed group from the wheel.

-- Where the preview relay lives. It reads the catalogue's pack zips with
-- ranged requests and serves the things the engine cannot make for itself:
-- playable audio, chart windows, pack facts, and single-song archives. The
-- default is the deployed relay; a machine running its own -- a developer
-- with the dev server up, say -- writes that URL as the one line of
-- Save/ITGmaniaContentBrowser/webapp.txt. Read once: a file that has not
-- changed mid-session is not worth reopening per press.
local webBase
local function WebBase()
	if webBase then return webBase end
	webBase = "https://itgcontent.net"
	local path = BROWSER_DATA_DIR .. "webapp.txt"
	if FILEMAN:DoesFileExist(path) then
		local f = RageFileUtil:CreateRageFile()
		if f:Open(path, RAGEFILE_READ) then
			local line = tostring(f:GetLine() or ""):gsub("%s+$", ""):gsub("/+$", "")
			if line:match("^https?://") then webBase = line end
			f:Close()
		end
		f:destroy()
	end
	return webBase
end

-- The relay runs on a free host with a monthly allowance. Once it has used
-- the allowance up, the host turns it off -- every request comes back 402,
-- "Payment required", with x-vercel-error DEPLOYMENT_DISABLED -- and it stays
-- off until the allowance comes round again, up to thirty days later. The
-- answer then is not an error to retry but a fact to tell the player, in
-- words: what is off, until when, and what still works. Not why: hosting and
-- its allowances are nothing a player needs to hear about.
local RELAY_OUT = "unavailable for now - back within a month"
local RELAY_OUT_WHY = "Booster packs, song previews, single songs and pack updates are "
	.. "unavailable for now, and will be back within a month. Whole packs still "
	.. "download as usual."

local function RelayOut(response)
	if type(response) ~= "table" then return false end
	if response.statusCode == 402 then return true end
	if type(response.headers) == "table" then
		for name, value in pairs(response.headers) do
			if tostring(name):lower() == "x-vercel-error" then
				value = tostring(value):upper()
				if value == "DEPLOYMENT_DISABLED" or value == "DEPLOYMENT_PAUSED" then return true end
			end
		end
	end
	return false
end

-- ---------------------------------------------------------------
-- the download host
--
-- The relay's heavy routes -- a song's folder, a preview's audio, a pack
-- update, a booster card's art -- are the bulk of what it sends, and on its
-- host every byte of them counts against a monthly allowance, twice. The same
-- routes run on a Cloudflare Worker at dl.itgcontent.net, where bandwidth is
-- not metered, so they come from there. Which host is the relay's to say, in
-- its /dl.json, read once a session -- a switch its owner can flip back
-- without a release -- and a request the download host turns away is asked
-- of the relay itself before it fails: an outage there costs a detour, not
-- the feature. The game's allowlist already covers *.itgcontent.net.
local DL_HOST = "https://dl.itgcontent.net"
local dlBase          -- what /dl.json said; "" is the relay itself
local dlAsked = false
local dlOverride      -- dl.txt, or the relay a webapp.txt points at; false when neither

local function DlBase()
	if dlOverride == nil then
		dlOverride = false
		local path = BROWSER_DATA_DIR .. "dl.txt"
		if FILEMAN:DoesFileExist(path) then
			local f = RageFileUtil:CreateRageFile()
			if f:Open(path, RAGEFILE_READ) then
				local line = tostring(f:GetLine() or ""):gsub("%s+$", ""):gsub("/+$", "")
				if line:match("^https?://") then dlOverride = line end
				f:Close()
			end
			f:destroy()
		end
		-- a machine running a relay of its own gets everything from it,
		-- unless dl.txt names a download host of its own as well
		if not dlOverride and WebBase() ~= "https://itgcontent.net" then dlOverride = WebBase() end
	end
	if dlOverride then return dlOverride end
	if dlBase ~= nil then return dlBase ~= "" and dlBase or WebBase() end
	if NETWORK:IsUrlAllowed(DL_HOST .. "/") then return DL_HOST end
	return WebBase()
end

-- Ask the relay which host serves the heavy routes. Once a session. Until it
-- answers, and if it cannot, the download host is used anyway: the relay
-- being unreachable is one of the things that host is there for.
local function FetchDlBase()
	if dlAsked then return end
	dlAsked = true
	local url = WebBase() .. "/dl.json"
	if not NETWORK:IsUrlAllowed(url) then return end
	NETWORK:HttpRequest{
		url = url,
		connectTimeout = 10,
		transferTimeout = 15,
		onResponse = function(response)
			if response.error ~= nil or response.statusCode ~= 200 then return end
			local ok, data = pcall(JsonDecode, response.body or "")
			if not (ok and type(data) == "table" and type(data.base) == "string") then return end
			local base = data.base:gsub("/+$", "")
			if base == "" or (base:match("^https?://") and NETWORK:IsUrlAllowed(base .. "/")) then
				dlBase = base
			end
		end,
	}
end

-- A request for one of the heavy routes: to the download host, and asked
-- again of the relay -- which serves every one of the same routes -- when the
-- host turns it away: no answer, a fault, a refusal, a redirect not followed.
-- An answer the relay would give the same way (no such song, a stale patch)
-- is final. The retry downloads under a name of its own, since the engine
-- deletes the first file once its answer has been handled, which is after
-- the retry has begun writing; args.onRetry hears the new name, and the
-- response handed to args.onResponse carries the name the file landed
-- under, as response.file. Returns a handle whose Cancel stops whichever
-- request is out.
local function DlRequest(path, args)
	local handle = {}
	local function Ask(base, file, again)
		local req = {}
		for k, v in pairs(args) do req[k] = v end
		req.onRetry = nil
		req.url = base .. path
		req.downloadFile = file
		req.onResponse = function(response)
			local cancelled = response.error ~= nil and ToEnumShortString(response.error) == "Cancelled"
			local code = tonumber(response.statusCode) or 0
			local turnedAway = not cancelled and (response.error ~= nil or code == 0 or code >= 500
				or code == 429 or code == 403 or (code >= 300 and code < 400))
			if again and turnedAway then
				local retry = file and ("relay-" .. file) or nil
				if args.onRetry then args.onRetry(retry) end
				handle.request = Ask(WebBase(), retry, false)
				return
			end
			response.file = file
			args.onResponse(response)
		end
		return NETWORK:HttpRequest(req)
	end
	function handle:Cancel()
		if self.request then self.request:Cancel() end
	end
	local base = DlBase()
	handle.request = Ask(base, args.downloadFile, base ~= WebBase())
	return handle
end

-- Once a relay: URLs used to detour through a loopback helper when the
-- machine's allowlist refused them. The installer allowlists the catalogue's
-- hosts directly now, so this is the URL it was handed -- kept as a seam
-- because every fetch in the module goes through it.
local function Upstream(url)
	return url
end

-- Empty a pack out, in the only way the engine allows.
--
-- Lua has no delete. RageFileManager has Remove and DeleteRecursive in C++,
-- but neither is bound, and the os/io libraries are not opened -- so nothing
-- here can unlink a file. What it CAN do is open one for writing: that goes
-- through O_TRUNC, and /Songs is not a protected path, so opening every file
-- in a pack and closing it again drops all of them to zero bytes and hands the
-- blocks back to the filesystem. A pack is almost entirely audio and video, so
-- that is very nearly all of its size.
--
-- What survives is the folder tree: empty files in empty directories, a few
-- kilobytes, which Lua cannot remove and which nothing reads. The songs stop
-- loading because their step files are gone, so the group leaves the wheel on
-- the next song reload -- which the browser already sends the player through
-- after installing.
--
-- Mode 6 is WRITE|STREAMED. Plain WRITE writes a temp file and renames it over
-- the target, which would leave the original intact until the rename and is not
-- what is wanted here; STREAMED opens the real path directly.
local function TruncateTree(dir, seen)
	local wiped, failed = 0, 0
	seen = seen or {}
	-- A symlinked pack folder could otherwise be walked forever.
	if seen[dir] then return 0, 0 end
	seen[dir] = true

	-- The full listing has the folders in it too, and a folder cannot be opened
	-- as a file: each one used to be counted as a locked file.
	local subdirs = FILEMAN:GetDirListing(dir, true, false)
	local isDir = {}
	for name in ivalues(subdirs) do isDir[name] = true end

	for name in ivalues(FILEMAN:GetDirListing(dir, false, false)) do
		if not isDir[name] then
			local file = RageFileUtil:CreateRageFile()
			if file:Open(dir .. name, RAGEFILE_WRITE) then
				file:Close()
				wiped = wiped + 1
			else
				failed = failed + 1
			end
			file:destroy()
		end
	end

	for name in ivalues(subdirs) do
		local w, f = TruncateTree(dir .. name .. "/", seen)
		wiped, failed = wiped + w, failed + f
	end
	return wiped, failed
end

-- What an emptied pack's folder says to anyone who opens it outside the game.
--
-- Its files stay behind, each at zero bytes, and so do its folders: nothing
-- in reach can remove either. So the folder gets one file that does have
-- something in it, whose name says what the folder is. That note cannot be
-- renamed or removed later either -- so when songs land in the same folder
-- again (the pack downloaded a second time, the singles folder reused) its
-- words are rewritten to say the folder is in use, and its name is the one
-- thing left saying otherwise. The deletions of this session are remembered
-- as well, so that holds even where the engine's listing has not yet caught
-- up with the note being written.
local DELETED_NOTE = "DELETED INGAME - SAFE TO REMOVE.txt"

-- The engine keeps its own copy of every song in its song cache, and an
-- ordinary start trusts that copy without looking in the folder again. So a
-- pack emptied here came back at the next start as it was, charts and all,
-- unless a full reload had rewritten the cache first -- and a pack downloaded
-- again into a folder that had been emptied came back with no charts. A
-- cached copy that will not load sends the engine to the folder itself, so
-- each song's copy is emptied along with it. The path is the one
-- SongCacheIndex::GetCacheFilePath builds, which Lua cannot call.
local function ForgetCached(group)
	for song in ivalues(SONGMAN:GetSongsInGroup(group) or {}) do
		local s = (song:GetSongDir():gsub("^/", ""):gsub("/$", ""))
		s = s:gsub("[/\192\193\245-\255]", "_")
		local f = RageFileUtil:CreateRageFile()
		if f:Open("/Cache/Songs/" .. s, RAGEFILE_WRITE) then f:Close() end
		f:destroy()
	end
end

local function Stamp()
	return string.format("%04d-%02d-%02d at %02d:%02d",
		Year(), MonthOfYear() + 1, DayOfMonth(), Hour(), Minute())
end

local function WriteNote(dir, lines)
	local f = RageFileUtil:CreateRageFile()
	local ok = f:Open(dir .. DELETED_NOTE, RAGEFILE_WRITE)
	if ok then
		f:Write(table.concat(lines, "\n") .. "\n")
		f:Close()
	end
	f:destroy()
	return ok
end

local function MarkDeleted(dir)
	state.deletedDirs[dir:lower()] = true
	return WriteNote(dir, {
		"DELETED INGAME - SAFE TO REMOVE",
		"",
		"This pack was deleted in game on " .. Stamp() .. ".",
		"Everything in this folder is empty. Delete the whole folder.",
	})
end

-- Songs have just landed in dir. If it was emptied by a deletion, its note
-- says so no longer -- and the engine, which still holds the emptied songs,
-- needs the full reload to see what came back (see ForgetCached).
local function KeepNote(dir)
	if not (state.deletedDirs[dir:lower()] or FILEMAN:DoesFileExist(dir .. DELETED_NOTE)) then
		return
	end
	state.deletedDirs[dir:lower()] = nil
	local group = dir:match("^/Songs/(.-)/$")
	if group then ForgetCached(group) end
	state.reloadFull = true
	WriteNote(dir, {
		"IN USE - KEEP THIS FOLDER",
		"",
		"Songs were downloaded into this folder again on " .. Stamp() .. ".",
		"It is in use: do not delete it, whatever this file is called.",
	})
end

-- Whether a pack is in the player's library, for everything that asks.
--
-- The engine's group list alone says no such thing about a pack emptied here.
-- Until songs are reloaded it still holds the pack as it was; and a reload
-- loads every song folder that is still there, emptied or not, as a song with
-- no charts -- which the music wheel hides, but which keeps the group on the
-- engine's list for as long as the folder stays on disk. Asked plainly, that
-- list put a deleted pack back on the Installed tab after the next reload and
-- refused to download it again ("already in your library").
local function InLibrary(name)
	if not (name and SONGMAN:DoesSongGroupExist(name)) then return false end
	if state.deletedDirs[("/Songs/" .. name .. "/"):lower()] then return false end
	for song in ivalues(SONGMAN:GetSongsInGroup(name) or {}) do
		if #song:GetAllSteps() > 0 then return true end
	end
	return false
end

-- cb(ok, message)
--
-- Native now: the browser empties the pack itself rather than asking a local
-- service to delete it. Nothing outside the game is involved.
local function DeletePack(pack, cb)
	local dir = "/Songs/" .. pack.name .. "/"
	if not FILEMAN:DoesFileExist(dir) then
		cb(false, "that pack is not in /Songs")
		return
	end

	state.autoSync[NormalizeName(pack.name)] = nil
	state.removing = pack.name
	Refresh()

	ForgetCached(pack.name)
	local wiped, failed = TruncateTree(dir)
	state.removing = nil

	if wiped == 0 then
		cb(false, failed > 0 and "none of the pack's files could be written"
			or "that pack folder was already empty")
		return
	end
	MarkDeleted(dir)

	-- The group goes from the wheel on the next reload, which the browser
	-- already offers on the way out; say so rather than implying it is gone.
	state.needsReload = true
	if failed > 0 then
		cb(true, "emptied " .. wiped .. " files; " .. failed .. " were locked")
	else
		cb(true, nil)
	end
end

-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.BROWSER_DATA_DIR = BROWSER_DATA_DIR
CB.Upstream         = Upstream
CB.DeletePack       = DeletePack
CB.DlBase           = DlBase
CB.DlRequest        = DlRequest
CB.FetchDlBase      = FetchDlBase
CB.GroupDirFor      = GroupDirFor
CB.InLibrary        = InLibrary
CB.KeepNote         = KeepNote
CB.INST_COLS        = INST_COLS
CB.INST_ROWS        = INST_ROWS
CB.RAGEFILE_READ    = RAGEFILE_READ
CB.RAGEFILE_WRITE   = RAGEFILE_WRITE
CB.RELAY_OUT        = RELAY_OUT
CB.RELAY_OUT_WHY    = RELAY_OUT_WHY
CB.RelayOut         = RelayOut
CB.Sync             = Sync
CB.WebBase          = WebBase
