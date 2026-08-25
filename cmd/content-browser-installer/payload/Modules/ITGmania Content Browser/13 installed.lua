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
local CheckHelper    = CB.CheckHelper
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
	CheckHelper()
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

-- "unknown" (no SMO data yet) | "absent" | "match" | "differs"
local function InstalledStatus(pack)
	if not state.smoByName then return "unknown", nil end
	local smo = state.smoByName[NormalizeName(pack.name)]
	if not smo then return "absent", nil end
	if smo.songs == pack.songs then return "match", smo end
	return "differs", smo
end

local function InstalledStatusText(pack)
	local status, smo = InstalledStatus(pack)
	if status == "unknown" then return "checking stepmaniaonline...", 0.55, 0.55, 0.55 end
	if status == "absent"  then return "not on SMO", 0.55, 0.55, 0.55 end
	if status == "match"   then return "matches SMO", 0.40, 0.85, 0.45 end
	return "SMO has " .. smo.songs .. " songs", 0.97, 0.78, 0.30
end

local function InInstalledView()
	return state.mode == "installed" or state.mode == "removeconfirm"
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

local function TabIsActive(tab)
	-- while the cursor is on the row it leads; otherwise the active view does
	local want = (state.zone == "tabs") and state.tabIndex or ActiveTabIndex()
	return TabOrder[want] == (tab.view or tab.mode)
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
CB.ScanInstalled       = ScanInstalled
CB.TabIsActive         = TabIsActive
CB.TabOrder            = TabOrder
