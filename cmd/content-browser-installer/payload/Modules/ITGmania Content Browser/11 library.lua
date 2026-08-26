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
			return "warn", "its Pack.ini says " .. pack.sync .. " but the library was "
				.. "loaded before that file existed - reload songs and it will play "
				.. "as " .. pack.sync
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
			.. ", which is what is being applied, but nothing in the pack pins it"
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
	return "A pack is either ITG synced -- its chart files were written with 9ms "
		.. "added, which the engine takes back off on the way in -- or NULL synced, "
		.. "written with no offset at all. A Pack.ini is how a pack says which. "
		.. "Without one, this machine's "
		.. "DefaultSyncOffset answers for every unlabelled pack at once.\n\n"
		.. "Packs made before Pack.ini existed are ITG, so that is what an unknown pack "
		.. "is taken to be here, and what gets written unless you say otherwise.\n\n"
		.. "If you know what a pack really is -- you made it, or you have played it "
		.. "enough to be sure -- this is where to say so. Writing a Pack.ini here "
		.. "records that sync for this pack on this machine and every other, and it "
		.. "can be changed again at any time."
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
-- ranged requests and serves the one thing the engine cannot make for
-- itself: playable audio, chart windows, and single-song archives. The
-- default is the relay running beside a development machine; a cabinet
-- whose relay lives elsewhere writes its URL as the one line of
-- Save/ITGmaniaContentBrowser/webapp.txt. Read once: a file that has not
-- changed mid-session is not worth reopening per press.
local webBase
local function WebBase()
	if webBase then return webBase end
	webBase = "http://localhost:3000"
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

	for name in ivalues(FILEMAN:GetDirListing(dir, false, false)) do
		local path = dir .. name
		local file = RageFileUtil:CreateRageFile()
		if file:Open(path, RAGEFILE_WRITE) then
			file:Close()
			wiped = wiped + 1
		else
			failed = failed + 1
		end
		file:destroy()
	end

	for name in ivalues(FILEMAN:GetDirListing(dir, true, false)) do
		local w, f = TruncateTree(dir .. name .. "/", seen)
		wiped, failed = wiped + w, failed + f
	end
	return wiped, failed
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

	local wiped, failed = TruncateTree(dir)
	state.removing = nil

	if wiped == 0 then
		cb(false, failed > 0 and "none of the pack's files could be written"
			or "that pack folder was already empty")
		return
	end

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
CB.GroupDirFor      = GroupDirFor
CB.INST_COLS        = INST_COLS
CB.INST_ROWS        = INST_ROWS
CB.RAGEFILE_READ    = RAGEFILE_READ
CB.RAGEFILE_WRITE   = RAGEFILE_WRITE
CB.Sync             = Sync
CB.WebBase          = WebBase
