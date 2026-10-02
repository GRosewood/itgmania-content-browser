-- -----------------------------------------------------------------------
-- Which packs are already on this machine
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local BROWSER_DATA_DIR = CB.BROWSER_DATA_DIR
local CurrentDay     = CB.CurrentDay
local CurrentMonth   = CB.CurrentMonth
local CurrentYear    = CB.CurrentYear
local Clamp          = CB.Clamp
local DL             = CB.DL
local FetchPackTypes = CB.FetchPackTypes
local GroupDirFor    = CB.GroupDirFor
local INST_ROWS      = CB.INST_ROWS
local NormalizeName  = CB.NormalizeName
local RAGEFILE_READ  = CB.RAGEFILE_READ
local RAGEFILE_WRITE = CB.RAGEFILE_WRITE
local Refresh        = CB.Refresh
local Sync           = CB.Sync
local Toast          = CB.Toast
local WebBase        = CB.WebBase
local state          = CB.state

-- ------------------------------------------------- when a pack arrived here
--
-- SONGMAN knows nothing about when a folder appeared, and the engine's Lua
-- bindings cannot ask the filesystem for a date -- Copy, DoesFileExist,
-- GetFileSizeBytes, GetHashForFile, GetDirListing and Unzip is the whole of it.
-- So the browser writes down what it installed and when, one line per pack,
-- beside its own config. Packs that arrived some other way simply have no line,
-- and say nothing rather than guessing.
DL.FILE = BROWSER_DATA_DIR .. "installed-dates.txt"

function DL.AddedDates()
	if state.addedDates then return state.addedDates end
	local dates = {}
	if FILEMAN:DoesFileExist(DL.FILE) then
		local f = RageFileUtil:CreateRageFile()
		if f:Open(DL.FILE, RAGEFILE_READ) then
			local body = f:Read()
			f:Close()
			for line in tostring(body or ""):gmatch("[^\r\n]+") do
				local key, when = line:match("^(.-)|(%d%d%d%d%-%d%d%-%d%d)$")
				if key and key ~= "" then dates[key] = when end
			end
		end
		f:destroy()
	end
	state.addedDates = dates
	return dates
end

-- Note that a pack arrived, unless it already has a date. A pack removed and
-- fetched again keeps the first one, which is the honest answer to "how long
-- have I had this".
function DL.Remember(name)
	if not name or name == "" then return end
	local key = NormalizeName(name)
	local dates = DL.AddedDates()
	if dates[key] then return end
	dates[key] = string.format("%04d-%02d-%02d",
		CurrentYear(), CurrentMonth(), CurrentDay())

	local f = RageFileUtil:CreateRageFile()
	if f:Open(DL.FILE, RAGEFILE_WRITE) then
		for k, when in pairs(dates) do
			f:PutLine(k .. "|" .. when)
		end
		f:Close()
	end
	f:destroy()
end

local function ScanInstalled()
	local inst = state.installed
	inst.packs = {}
	for name in ivalues(SONGMAN:GetSongGroupNames()) do
		local songs = SONGMAN:GetSongsInGroup(name)
		local dir = GroupDirFor(songs)
		-- SONGMAN gives the real folder, which is why the sync check lives
		-- here: GetDirListing caches for 30 seconds and would miss a pack that
		-- had only just been unzipped
		local sync, syncFile, syncOurs = Sync.OnDisk(dir)
		-- What the engine itself decided for this pack. Group objects are built
		-- during the song load and carry the resolved offset, so this is the
		-- offset gameplay will really use -- not a second guess at it from the
		-- same inputs.
		local applied, hasIni
		if #songs > 0 and SONGMAN.GetGroup then
			local ok, group = pcall(function() return SONGMAN:GetGroup(songs[1]) end)
			if ok and group then
				applied = group:GetSyncOffset()
				hasIni = group:HasPackIni()
			end
		end
		inst.packs[#inst.packs+1] = {
			name     = name,
			songs    = #songs,
			banner   = SONGMAN:GetSongGroupBannerPath(name),
			dir      = dir,
			sync     = sync,
			syncFile = syncFile,
			syncOurs = syncOurs,
			applied  = applied,
			hasIni   = hasIni,
			added    = DL.AddedDates()[NormalizeName(name)],
		}
	end
	-- And what has arrived since the library was loaded.
	--
	-- This list is SONGMAN's groups, and SONGMAN learns about a folder when
	-- songs are loaded and not before. So a pack downloaded a moment ago is
	-- unzipped, complete, sitting on disk -- and absent from the one screen
	-- that exists to say what you have, which reads as the download having
	-- failed. It is on the list, from what the download itself reported, and
	-- says what it is waiting for.
	--
	-- Only downloads that finished, and only ones SONGMAN has not caught up
	-- with: after a reload the real row replaces this one and nothing here
	-- matches any more.
	do
		local have = {}
		for row in ivalues(inst.packs) do have[NormalizeName(row.name)] = true end
		for _, dl in pairs(state.downloads) do
			if dl.status == "done" and not dl.single then
				-- the folders it actually created, or its own name when the
				-- installer did not report any
				local groups = dl.groups
				if not groups or #groups == 0 then groups = { dl.name } end
				for name in ivalues(groups) do
					local key = NormalizeName(tostring(name or ""))
					if key ~= "" and not have[key] then
						have[key] = true
						inst.packs[#inst.packs+1] = {
							name    = tostring(name),
							songs   = 0,
							waiting = true,   -- on a song reload, not on us
							added   = DL.AddedDates()[key],
						}
					end
				end
			end
		end
	end

	-- Alphabetical, always.
	--
	-- Sorting the ones this browser downloaded to the top was tried and is
	-- worse: the date survives between sessions, so a list opened weeks later
	-- still led with whatever was downloaded last time, for no reason the
	-- reader could see. A library you are looking through is a reference, and a
	-- reference is ordered by name.
	table.sort(inst.packs, function(a, b) return a.name:lower() < b.name:lower() end)
	inst.status = "ready"
	inst.scannedAt = GetTimeSinceStart()
	inst.cursor = Clamp(inst.cursor, 1, math.max(1, #inst.packs))
	-- the window holds the page the cursor is actually on -- resetting it to
	-- the first page while the cursor stayed deep in the list left the
	-- highlight stranded off-grid, on a row no slot was drawing
	inst.window = INST_ROWS * math.floor((inst.cursor - 1) / INST_ROWS)
	-- the CSV is what powers the SMO comparison
	FetchPackTypes()
end

-- Packs installed through this browser that came without a Pack.ini and are
-- old enough to predate the null-sync convention get one written for them,
-- assuming ITG.
--
-- Assuming ITG is the conservative half of the guess: with no Pack.ini the
-- engine already falls back to DefaultSyncOffset, which ships as ITG, so on a
-- stock machine the written file pins the behaviour the pack already had
-- rather than changing it. What it does cost is that DefaultSyncOffset stops
-- reaching these packs, which is why the file says so in a comment and why
-- this only ever touches packs installed from here -- never the rest of a
-- library.
local function ApplyAssumedSync()
	local wrote, value = 0, nil
	for pack in ivalues(state.installed.packs) do
		local key = NormalizeName(pack.name)
		if state.autoSync[key] and pack.sync == nil and pack.dir
		   -- the folder has to still be there: a scan can run while SONGMAN
		   -- still holds a group whose files have just been deleted, and a
		   -- write would recreate the folder around a single file
		   and FILEMAN:DoesFileExist(pack.dir) then
			-- ITG unless SMO says otherwise; the sync screen can override it
			value = Sync.Suggest(pack)
			if Sync.Write(pack.dir, value) then
				state.autoSync[key] = nil
				pack.sync, pack.syncOurs = value, true
				wrote = wrote + 1
			end
		end
	end
	if wrote > 0 then
		Toast((wrote == 1 and ("Wrote a Pack.ini (" .. value .. ") for 1 new pack")
			or ("Wrote a Pack.ini for " .. wrote .. " new packs"))
			.. " - reload songs to apply")
		Refresh()
	end
end

local function InstalledPack()
	local inst = state.installed
	return inst.packs[inst.cursor]
end

local function InstalledPages()
	return math.max(1, math.ceil(#state.installed.packs / INST_ROWS))
end

local function InstalledPage()
	return math.floor(state.installed.window / INST_ROWS) + 1
end

-- ------------------------------------------------- packs patched on SMO
--
-- Pack authors fix charts after release -- wrong notes, a BPM change in the
-- wrong place, a missing difficulty -- and stepmaniaonline.net replaces the
-- zip. Everyone who downloaded the old one keeps the old charts, and nothing
-- here could tell. SMO is the reference for the charts: an installed pack is
-- held against SMO's copy, and what differs can be fetched on its own
-- (DL.Patch).
--
-- Charts are compared as charts, song by song, by their GrooveStats hashes:
-- the steps and the BPMs, nothing else. SMO resyncs packs -- every #OFFSET
-- moved by the 9ms ITG bias, the files rewritten around it, a .oldsync backup
-- left beside each -- and held up file against file, that is every chart in
-- the pack changed when not one step moved. The game knows its own songs'
-- hashes already (Steps:GetGrooveStatsHash); the relay works SMO's out the
-- way the engine does (/api/packfiles), so the two can be held side by side.
-- A song whose hashes differ takes SMO's simfiles, and keeps the player's
-- offset (PATCH.KeepSync).
--
-- Sync is never part of an update: not the offsets, not the pack's Pack.ini,
-- not the backups a resync leaves. The small text files beside the charts are
-- compared by MD5, audio, video and art by size. A file the installed copy has
-- and SMO's does not is the player's own, and is left alone -- and a song SMO
-- has only renamed, the same charts under a new folder name, is not fetched a
-- second time.
--
-- One pack at a time, and only the ones that come into view: each check is a
-- request, and the engine runs requests one by one.
local PATCH = {}

-- what a check found, by the pack's name in SONGMAN (state.patches):
--   status   "queued" | "checking" | "current" | "outdated" | "unrelated" | "failed"
--   id, v    SMO's pack id, and the version of its zip this was against
--   want     places in the relay's list of the files to fetch (0-based)
--   bytes    what those weigh in the zip
--   charts, songs, other   what they are: songs here whose charts changed,
--            whole new songs, and every other file
--   folders  the songs here whose charts changed, lowercased, for the reload
--   changed  those songs: { path = the simfile here, charts = { {rel, o} ... } }
--   fresh    the new songs: { charts = { {rel, o} ... } }
--   samples  songs held in common: { path, o }, for how far SMO's sync sits
--            from this copy's
--   items    the files themselves, for the update dialog to list: { rel, why },
--            why being "charts" | "song" | "new" | "changed", sorted by path
--   strip    path parts the patch's names carry above the pack's folder

-- how many of those the update dialog shows at once; Up and Down scroll it
PATCH.FILE_ROWS = 8

-- The engine loads the first of these kinds a song folder has.
local CHART_RANK = { ssc = 1, sma = 2, sm = 3, dwi = 4, ksf = 5 }
-- the charts a pad plays, which are the ones the relay hashes
local DANCE = { StepsType_Dance_Single = "dance-single", StepsType_Dance_Double = "dance-double" }

-- CRYPTMAN hands back the raw digest; the relay writes hex
local function Hex(raw)
	return (tostring(raw or ""):gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

-- Places as the relay reads them: "0-3,7,9-12".
function PATCH.Ranges(list)
	local out, i = {}, 1
	while i <= #list do
		local j = i
		while j < #list and list[j + 1] == list[j] + 1 do j = j + 1 end
		out[#out+1] = (j > i) and (list[i] .. "-" .. list[j]) or tostring(list[i])
		i = j + 1
	end
	return table.concat(out, ",")
end

-- The game's own word on a song's charts: "dance-single:<hash>" for each,
-- sorted and joined. nil when one of them has no hash of the version the
-- relay works out, which leaves the song to the file comparison.
local function SongCharts(song, version)
	local list = {}
	for steps in ivalues(song:GetAllSteps()) do
		local kind = DANCE[steps:GetStepsType()]
		if kind and not steps:IsAutogen() then
			local hash = steps:GetGrooveStatsHash()
			if hash == "" or steps:GetGrooveStatsHashVersion() ~= version then return nil end
			list[#list+1] = kind .. ":" .. hash
		end
	end
	table.sort(list)
	return table.concat(list, ",")
end

-- The same for one of SMO's simfiles, from what the relay worked out.
local function FileCharts(f)
	if type(f.g) ~= "table" then return nil end
	local list = {}
	for hash in ivalues(f.g) do list[#list+1] = tostring(hash) end
	table.sort(list)
	return table.concat(list, ",")
end

-- An installed file against SMO's: by its contents where the relay hashed
-- them, by its size where it did not.
local function FileDiffers(path, f)
	if not FILEMAN:DoesFileExist(path) then return true end
	if f.h then return Hex(CRYPTMAN:MD5File(path)) ~= f.h end
	return FILEMAN:GetFileSizeBytes(path) ~= tonumber(f.s)
end

-- Hold one installed pack against SMO's list of its files.
local function Compare(row, smoId, list)
	local dir = row.dir
	local files = list.files
	-- The relay names files from the zip's one top folder down. A zip with no
	-- single top folder keeps its paths whole, and only what sits under a
	-- folder named like this pack is this pack -- which the patch then
	-- carries one path part too deep, for the unzip to strip.
	local strip, prefix = 0, ""
	if (list.root or "") == "" then
		strip = 1
		local mine = NormalizeName(row.name)
		for f in ivalues(files) do
			local top = type(f.p) == "string" and f.p:match("^([^/]+)/")
			if top and NormalizeName(top) == mine then
				prefix = top .. "/"
				break
			end
		end
		if prefix == "" then return { status = "unrelated", id = smoId } end
	end
	local version = tonumber(list.gv)

	local p = {
		status = "current", id = smoId, v = tostring(list.v or ""), strip = strip,
		want = {}, bytes = 0, charts = 0, songs = 0, other = 0, folders = {},
		changed = {}, fresh = {}, samples = {}, items = {},
	}
	local same = 0
	local function Want(e, why)
		p.want[#p.want+1] = e.i
		p.bytes = p.bytes + (tonumber(e.f.c) or tonumber(e.f.s) or 0)
		p.items[#p.items+1] = { rel = e.rel, why = why }
	end

	-- the pack as the game loaded it, song by song
	local songs = {}
	for song in ivalues(SONGMAN:GetSongsInGroup(row.name)) do
		local folder = (song:GetSongDir() or ""):match("([^/]+)/*$")
		if folder then songs[folder:lower()] = song end
	end

	-- SMO's files: the simfiles straight inside each song folder, and the rest
	local folders, order, rest = {}, {}, {}
	for i, f in ipairs(files) do
		local rel = type(f.p) == "string" and f.p or ""
		if prefix ~= "" then
			rel = (rel:sub(1, #prefix) == prefix) and rel:sub(#prefix + 1) or ""
		end
		local low = rel:lower()
		-- the pack's sync, and the backups a resync leaves: never an update
		if rel ~= "" and low ~= "pack.ini" and not low:find("%.oldsync$") then
			local e = { i = i - 1, f = f, rel = rel }
			local folder = rel:match("^([^/]+)/[^/]+$")
			local rank = CHART_RANK[low:match("%.([^%./]+)$") or ""]
			if folder and rank then
				local key = folder:lower()
				if not folders[key] then
					folders[key] = { name = folder, charts = {} }
					order[#order+1] = key
				end
				e.rank = rank
				table.insert(folders[key].charts, e)
			else
				e.folder = rel:match("^([^/]+)/")
				e.chart = rank ~= nil
				rest[#rest+1] = e
			end
		end
	end

	-- The charts of songs here whose folder SMO no longer has: a folder SMO
	-- renamed, which fetching again would only put in the pack twice.
	local orphans = {}
	if version then
		for key, song in pairs(songs) do
			if not folders[key] then
				local mine = SongCharts(song, version)
				if mine and mine ~= "" then orphans[mine] = true end
			end
		end
	end

	local renamed = {}
	for key in ivalues(order) do
		local fo = folders[key]
		table.sort(fo.charts, function(a, b)
			if a.rank ~= b.rank then return a.rank < b.rank end
			return a.i < b.i
		end)
		local first = fo.charts[1]
		local theirs = version and FileCharts(first.f)
		local song = songs[key]
		local entries = {}
		for e in ivalues(fo.charts) do
			entries[#entries+1] = { rel = e.rel, o = tonumber(e.f.o) }
		end
		if not FILEMAN:DoesFileExist(dir .. fo.name) then
			if theirs and theirs ~= "" and orphans[theirs] then
				renamed[key] = true
				same = same + 1
			else
				p.songs = p.songs + 1
				p.fresh[#p.fresh+1] = { charts = entries }
				for e in ivalues(fo.charts) do Want(e, "song") end
			end
		else
			local differs
			local mine = theirs and song and SongCharts(song, version)
			if mine then
				-- A kind of simfile the engine prefers to all of SMO's would go on
				-- winning after the update, which would then change nothing.
				local loaded = ((song:GetSongFilePath() or ""):match("%.([^%./]+)$") or ""):lower()
				differs = mine ~= theirs and (CHART_RANK[loaded] or 99) >= first.rank
			else
				-- no hashes to go on: the simfile as a file
				differs = FileDiffers(dir .. first.rel, first.f)
			end
			if differs then
				p.charts = p.charts + 1
				p.folders[key] = true
				p.changed[#p.changed+1] = {
					path = song and song:GetSongFilePath() or (dir .. first.rel),
					charts = entries,
				}
				for e in ivalues(fo.charts) do Want(e, "charts") end
			else
				same = same + 1
			end
			if song and entries[1].o and #p.samples < 12 then
				p.samples[#p.samples+1] = { path = song:GetSongFilePath(), o = entries[1].o }
			end
		end
	end

	for e in ivalues(rest) do
		local key = e.folder and e.folder:lower()
		if not (key and renamed[key]) then
			local path = dir .. e.rel
			if not FILEMAN:DoesFileExist(path) then
				-- a new song's files are counted with it, anything else on its own
				if key and folders[key] and not FILEMAN:DoesFileExist(dir .. e.folder) then
					Want(e, "song")
				else
					Want(e, "new")
					p.other = p.other + 1
				end
			elseif not e.chart and FileDiffers(path, e.f) then
				-- a simfile deeper than a song folder is never loaded, so only a
				-- missing one counts
				Want(e, "changed")
				p.other = p.other + 1
			else
				same = same + 1
			end
		end
	end

	table.sort(p.want)
	-- a song's files together, the way a file browser would show them
	table.sort(p.items, function(a, b) return a.rel:lower() < b.rel:lower() end)
	if #p.want > 0 then
		-- Nothing at all in common is not an old copy of this pack: it is
		-- another pack that shares the name, and "updating" it would replace it.
		p.status = (same == 0) and "unrelated" or "outdated"
	end
	return p
end

-- The song's own #OFFSET: the first in the file, read the way the relay reads
-- SMO's (songOffset in lib/gshash.ts). 0 when the file has none, which is what
-- the engine plays it at; nil when it cannot be read.
local function ReadOffset(path)
	if not path then return nil end
	local f = RageFileUtil:CreateRageFile()
	local text
	if f:Open(path, RAGEFILE_READ) then
		text = f:Read()
		f:Close()
	end
	f:destroy()
	if not text then return nil end
	local value = text:match("#[Oo][Ff][Ff][Ss][Ee][Tt]:([^;#]*)")
	if not value then return 0 end
	return tonumber((value:gsub("^%s+", ""):gsub("%s+$", "")))
end

-- Every #OFFSET in a simfile moved by delta seconds -- the song's and any
-- chart's of its own alike, the way a resync moves them. True when the file
-- was written. Lua cannot write a NUL, so a file holding one is left alone.
local function ShiftOffsets(path, delta)
	if not delta or math.abs(delta) < 0.0005 then return false end
	local f = RageFileUtil:CreateRageFile()
	local text
	if f:Open(path, RAGEFILE_READ) then
		text = f:Read()
		f:Close()
	end
	f:destroy()
	if not text or text:find("\0", 1, true) then return false end
	local moved = 0
	text = text:gsub("(#[Oo][Ff][Ff][Ss][Ee][Tt]:)([^;#]*)", function(tag, value)
		local v = tonumber((value:gsub("^%s+", ""):gsub("%s+$", "")))
		if not v then return nil end
		moved = moved + 1
		return tag .. string.format("%.6f", v + delta)
	end)
	if moved == 0 then return false end
	local ok = false
	f = RageFileUtil:CreateRageFile()
	if f:Open(path, RAGEFILE_WRITE) then
		f:Write(text)
		f:Close()
		ok = true
	end
	f:destroy()
	return ok
end

-- What an update has to keep, read before the unzip writes over it: each
-- changed song's offset as this copy has it, and -- for songs new to the
-- pack -- how far SMO's sync sits from this copy's, as most of the songs held
-- in common agree. A resync moves every song alike; a song synced by hand is
-- outvoted rather than followed.
function PATCH.SyncPlan(p)
	local plan = { changed = {}, fresh = p.fresh or {} }
	for c in ivalues(p.changed or {}) do
		plan.changed[#plan.changed+1] = { offset = ReadOffset(c.path), charts = c.charts }
	end
	if #plan.fresh > 0 then
		local buckets, total, best = {}, 0, nil
		for s in ivalues(p.samples or {}) do
			local mine = ReadOffset(s.path)
			if mine and s.o then
				local d = mine - s.o
				local key = math.floor(d * 1000 + 0.5)
				local b = buckets[key] or { n = 0, sum = 0 }
				b.n, b.sum = b.n + 1, b.sum + d
				buckets[key] = b
				total = total + 1
				if not best or b.n > best.n then best = b end
			end
		end
		if best and best.n * 2 > total then plan.delta = best.sum / best.n end
	end
	return plan
end

-- ...and, once SMO's simfiles are in, the songs they brought moved to this
-- copy's sync. How many songs that took.
function PATCH.KeepSync(dir, plan)
	local kept = 0
	for c in ivalues(plan.changed) do
		local moved = false
		if c.offset then
			for e in ivalues(c.charts) do
				if e.o and ShiftOffsets(dir .. e.rel, c.offset - e.o) then moved = true end
			end
		end
		if moved then kept = kept + 1 end
	end
	if plan.delta then
		for song in ivalues(plan.fresh) do
			local moved = false
			for e in ivalues(song.charts) do
				if ShiftOffsets(dir .. e.rel, plan.delta) then moved = true end
			end
			if moved then kept = kept + 1 end
		end
	end
	return kept
end

-- The next pack in line, if nothing is being checked already.
function PATCH.Pump()
	if state.patchBusy or not state.open then return end
	local row = table.remove(state.patchQueue, 1)
	if not row then return end
	local p = state.patches[row.name]
	local smo = state.smoByName and state.smoByName[NormalizeName(row.name)]
	if not (p and p.status == "queued" and smo and smo.id) then return PATCH.Pump() end
	local url = WebBase() .. "/api/packfiles/" .. smo.id
	if not NETWORK:IsUrlAllowed(url) then
		state.patches[row.name] = { status = "failed" }
		return PATCH.Pump()
	end
	p.status = "checking"
	state.patchBusy = row.name
	NETWORK:HttpRequest{
		url = url,
		connectTimeout = 10,
		transferTimeout = 90,
		onResponse = function(response)
			state.patchBusy = nil
			if state.retired then return end
			local list
			if response.error == nil and response.statusCode == 200 then
				local ok, data = pcall(JsonDecode, response.body or "")
				if ok and type(data) == "table" and type(data.files) == "table" then list = data end
			end
			local result = { status = "failed" }
			if list then
				local ok, compared = pcall(Compare, row, smo.id, list)
				if ok and compared then result = compared end
			end
			state.patches[row.name] = result
			Refresh()
			PATCH.Pump()
		end,
	}
end

-- Ask about a pack as it comes into view -- the one under the cursor first --
-- once a session. A pack just updated is already known to be current.
function PATCH.Need(row, first)
	if row and not row.waiting and row.dir and not state.patches[row.name] then
		local smo = state.smoByName and state.smoByName[NormalizeName(row.name)]
		if smo and smo.id then
			state.patches[row.name] = { status = "queued" }
			if first then
				table.insert(state.patchQueue, 1, row)
			else
				state.patchQueue[#state.patchQueue+1] = row
			end
		end
	end
	-- also how a queue left waiting when the browser closed starts moving again
	PATCH.Pump()
end

-- The row's word on it, or nil when the check has nothing to say yet.
function PATCH.RowText(pack)
	local p = state.patches[pack.name]
	if not p then return nil end
	if p.status == "outdated" then
		return "UPDATE: " .. #p.want .. (#p.want == 1 and " file" or " files"), 0.97, 0.78, 0.30
	elseif p.status == "current" then
		return "up to date with SMO", 0.40, 0.85, 0.45
	elseif p.status == "queued" or p.status == "checking" then
		return "checking files...", 0.55, 0.55, 0.55
	end
	return nil
end

-- What an update would bring: "new charts for 2 songs, 1 new song and 3
-- other files".
function PATCH.Words(p)
	local bits = {}
	if p.charts > 0 then
		bits[#bits+1] = "new charts for " .. p.charts .. (p.charts == 1 and " song" or " songs")
	end
	if p.songs > 0 then
		bits[#bits+1] = p.songs .. (p.songs == 1 and " new song" or " new songs")
	end
	if p.other > 0 then
		bits[#bits+1] = p.other .. (p.other == 1 and " other file" or " other files")
	end
	if #bits <= 1 then return bits[1] or "" end
	return table.concat(bits, ", ", 1, #bits - 1) .. " and " .. bits[#bits]
end

-- "unknown" (no SMO data yet) | "absent" | "match" | "differs"
local function InstalledStatus(pack)
	if not state.smoByName then return "unknown", nil end
	local smo = state.smoByName[NormalizeName(pack.name)]
	if not smo then return "absent", nil end
	if smo.songs == pack.songs then return "match", smo end
	return "differs", smo
end

local function InstalledStatusText(pack)
	-- the file check, when it has an answer, says more than the song counts
	local text, r, g, b = PATCH.RowText(pack)
	if text then return text, r, g, b end
	local status, smo = InstalledStatus(pack)
	if status == "unknown" then return "checking stepmaniaonline...", 0.55, 0.55, 0.55 end
	if status == "absent"  then return "not on SMO", 0.55, 0.55, 0.55 end
	if status == "match"   then return "matches SMO", 0.40, 0.85, 0.45 end
	return "SMO has " .. smo.songs .. " songs", 0.97, 0.78, 0.30
end

local function InInstalledView()
	return state.mode == "installed" or state.mode == "removeconfirm"
		or state.mode == "patchconfirm"
end

local function InYearView()
	return state.mode == "year"
end

local function InLevelView()
	return state.mode == "tech" or state.mode == "stamina"
		or state.mode == "beginner" or state.mode == "doubles"
end

-- every mode that shows the paged pack list and its info pane; the featured
-- strip is deliberately not part of this
--
-- Doubles is deliberately excluded even though it is a level view. It puts two
-- columns of its own in the same space, so the one-column list, its
-- placeholders, its info pane and its scrollbar all have to stand down -- and
-- they all ask this one question, so excluding it here is the whole of it.
local function InPackList()
	if state.mode == "doubles" then return false end
	return state.mode == "list" or state.mode == "year" or InLevelView()
end

-- Every mode that keeps the tab row on screen: the tabbed views themselves,
-- plus the dialogs drawn over one of them.
--
-- This used to be a table of mode names written out by hand, which is how the
-- doubles tab shipped without a tab row above it -- and with Up out of its
-- list putting the cursor on a row that was not being drawn. Derived from the
-- views themselves, a new tab cannot be left out of it.
-- "confirm" is deliberately not here. It was in the hand-written list, from
-- back when it was a dialog over a pack list -- it is the download popup now,
-- and that opens over the pack detail page, which has no tab row of its own.
-- Drawing one over it put the tab labels through the detail view's header.
local function InBrowsingMode()
	return InPackList() or InLevelView() or InYearView() or InInstalledView()
end

-- the order the tab row cycles in; index 1 is SEARCH
local TabOrder = { "search", "pad", "keyboard", "beginner", "tech", "stamina", "doubles", "year", "installed" }

-- which tab the current view corresponds to
local function ActiveTabIndex()
	local want
	if InInstalledView() then want = "installed"
	elseif InYearView() then want = "year"
	elseif InLevelView() then want = state.mode
	elseif state.search ~= "" then want = "search"
	else want = state.filterMode end
	for i, name in ipairs(TabOrder) do
		if name == want then return i end
	end
	return 2
end

-- What a tab is, of the three things it can be.
--
-- Where the cursor is and which view the page is on are separate facts, and a
-- tab can be either, both, or neither. Deciding them from one index meant only
-- one tab was ever lit: while the cursor was on the row the page's own tab
-- showed as nothing, and the moment the cursor stepped off onto the update
-- chip that tab lit up in full accent with the cursor nowhere near it.
--
-- "focus" wins when a tab is both, because the cursor is the more specific
-- thing to say about it.
local function TabRole(tab)
	local key = tab.view or tab.mode
	if state.zone == "tabs" and TabOrder[state.tabIndex] == key then
		return "focus"
	end
	if TabOrder[ActiveTabIndex()] == key then
		return "shown"
	end
	return "idle"
end

local function EnterInstalled()
	state.mode = "installed"
	state.zone = "list"
	local inst = state.installed
	-- a download during this session changes the library, so rescan on a
	-- revisit rather than trusting the first scan forever
	if inst.status == "idle" or state.needsReload
	   or (inst.scannedAt and GetTimeSinceStart() - inst.scannedAt > 30) then
		ScanInstalled()
	end
	if #inst.packs == 0 then state.zone = "tabs" end
	ApplyAssumedSync()
	Refresh()
end

-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.ActiveTabIndex      = ActiveTabIndex
CB.EnterInstalled      = EnterInstalled
CB.InBrowsingMode      = InBrowsingMode
CB.InInstalledView     = InInstalledView
CB.InLevelView         = InLevelView
CB.InPackList          = InPackList
CB.InYearView          = InYearView
CB.InstalledPack       = InstalledPack
CB.InstalledPage       = InstalledPage
CB.InstalledPages      = InstalledPages
CB.InstalledStatusText = InstalledStatusText
CB.PATCH               = PATCH
CB.ScanInstalled       = ScanInstalled
CB.TabRole             = TabRole
CB.TabOrder            = TabOrder
