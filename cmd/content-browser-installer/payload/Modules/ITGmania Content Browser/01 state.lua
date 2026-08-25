-- -----------------------------------------------------------------------
-- What the browser knows
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

local SMO_HOST      = "stepmaniaonline.net"
local SMO_BASE      = "https://" .. SMO_HOST
local BROWSER_SCREEN = "ScreenWithMenuElements"
-- Where the browser keeps things it can fetch again.
--
-- Cache, not Save, and the distinction is load-bearing. Save is for state --
-- profiles, preferences, anything whose loss loses something. Cache is for
-- bytes the network can hand back on request, and on a cabinet it is often
-- the one folder sitting on a big mounted drive (or one wiped every boot),
-- which is exactly the right home for a pile of downloaded artwork. The
-- engine mounts /Cache wherever that really is -- beside the game on a
-- portable install, under the user's data folder otherwise, through whatever
-- symlink or mount the machine put in the way -- so this path is right on
-- every layout without knowing which one it is on.
--
-- Two facts make this safe. The engine's own cache wipe (SongCacheIndex, on a
-- cache-version mismatch) deletes loose files and its own subfolders, never a
-- foreign subfolder, so this one rides through engine upgrades. And if a
-- cabinet clears its cache drive anyway, everything here downloads again the
-- next time it is looked at.
local CACHE_DIR     = "/Cache/ITGmaniaContentBrowser/"
local BANNER_DIR    = CACHE_DIR .. "Banners/"
local ROWS          = 7      -- list rows per page (also the server page size)
local SONG_ROWS     = 8      -- visible song rows in the detail view
-- Featured strip tuning, gathered into one table: Lua 5.1 caps a chunk at 200
-- local variables and this file sits close to that.
local FEAT = {
	COLS = 6,             -- cards per row
	ROWS = 2,             -- rows of cards
	TARGET = 24,          -- two full pages of twelve, so the grid never gaps
	BUILD = 34,           -- built, not shown: cover for banner-shape pruning
	MIN_SCORE = 4,        -- distinct meters in 7..15 required to qualify
	MAX_DETAILS = 400,    -- give up after this many detail fetches
	MIN_SONGS = 15,       -- below this there is not enough pack to feature
	MAX_SONGS = 100,      -- above this it is a megapack, not a recommendation
	PAD_MONTHS = 5,       -- pad packs: how far back the strip looks
	KB_YEARS = 10,        -- keyboard packs release far less often
	AUTHOR_MIN = 2,       -- other recent packs a charter needs to count
	AUTHOR_TOP = 3,       -- credits checked on a multi-author pack
	SPREAD_BONUS = 10,    -- sorts full-spread packs to the front
}
FEAT.VISIBLE = FEAT.COLS * FEAT.ROWS
local REFRESH_SECS  = 300    -- auto-refresh the pack list if older than this

-- -----------------------------------------------------------------------
-- module state; persists for the whole game session

local state = {
	open          = false,   -- browser screen active
	-- Which screenful is up. Set directly: list, detail, confirm, reload,
	-- removeconfirm, sync, update, year, installed, blocked -- plus a level
	-- bucket (beginner, tech, stamina, doubles) while one of those tabs is
	-- open.
	mode          = "list",
	packs         = {},      -- rows on the current page
	page          = 1,
	totalPacks    = 0,       -- recordsTotal from the server
	filtered      = 0,       -- recordsFiltered (differs while searching)
	cursor        = 1,       -- selected row in packs
	search        = "",
	loading       = false,
	loadErr       = nil,
	lastFetch     = nil,     -- GetTimeSinceStart() of last successful fetch
	fetchReq      = nil,     -- in-flight HttpRequestFuture for the list
	fetchGen      = 0,       -- generation counter; stale responses are dropped
	details       = {},      -- packId -> parsed detail table
	detailBusy    = {},      -- packId -> true while its detail page is being fetched
	detailAt      = {},      -- packId -> when that fetch began, so a lost one can be told
	detailFailed  = {},      -- packId -> GetTimeSinceStart() of last failed fetch
	bannerFailed  = {},      -- url -> GetTimeSinceStart() of last failed fetch
	bannerAspect  = {},      -- url -> width/height, once a sprite has loaded it
	packsSpare    = {},      -- rows fetched past the page, held to backfill it
	selected      = nil,     -- pack captured when entering detail/confirm view
	songCursor    = 0,       -- scroll offset into the detail song list
	songPick      = 1,       -- which song in that list is highlighted
	chooseIdx     = 1,       -- 1 hear a sample, 2 download, on the detail popup
	dlOrder       = {},      -- packIds in the order their downloads were started
	dlRows        = {},      -- the queue as drawn: worked out once per refresh
	addedDates    = nil,     -- normalised pack name -> the day it was installed
	doubles       = {        -- the two lists the DOUBLES tab is built from
		status    = "idle",  -- idle | loading | ready | failed
		dedicated = nil,     -- normalised name -> true, from itgdb.net
		partial   = nil,     -- SMO rows that hold at least one doubles chart
		blocked   = false,   -- itgdb.net is not on this machine's allowlist
		-- the two columns as drawn, and the cursor inside them
		left      = {},      -- packs made for doubles
		right     = {},      -- packs that merely contain some
		col       = 1,       -- 1 = left, 2 = right
		row       = 1,       -- visible row inside that column, 1..LO.DBL_ROWS
		win       = {0, 0},  -- rows scrolled past, per column
		-- pick | rows. Arriving on this tab focuses a whole COLUMN first and
		-- only a second press dives into its rows -- two lists side by side
		-- with the cursor already deep in one read as a single list with a
		-- seam, and nothing on screen said how to reach the second.
		zone      = "pick",
	},
	downloads     = {},      -- packId -> {status,cur,total,msg,groups}
	banners       = {},      -- url -> local VFS path (once cached)
	bannerBusy    = {},      -- url -> true while downloading
	bannerQueue   = {},      -- urls waiting for a download slot
	bannerQueued  = {},      -- url -> true while it sits in that queue
	bannerInFlight = 0,
	needsReload   = false,   -- something was installed this session
	reloadPacks   = 0,       -- ...and what it was, so the dialog can say so
	reloadSongs   = 0,
	reloadGone    = 0,       -- packs removed, which also needs a reload
	reloadIdx     = 1,       -- which choice the reload dialog is on
	textEntryOpen = false,
	pendingSearch = nil,
	reloadForUs   = false,   -- we sent the player to ScreenReloadSongsSSM
	blockedReason = nil,     -- why network access is unavailable, if it is

	-- pad/keyboard filtering (pack type metadata from /api/packs)
	filterMode    = "pad",   -- pad | keyboard
	packTypes     = nil,     -- packId(string) -> packtype ("keyboard"/"itg"/...)
	packTypesBusy = false,
	packSync      = nil,     -- packId(string) -> SMO's sync tag, lowercased
	packSubstyle  = nil,     -- packId(string) -> technical|stamina|all around|mods
	syncPack      = nil,     -- the installed pack the sync screen is acting on
	syncChoice    = "NULL",  -- which value that screen would write
	syncNote      = nil,     -- result of the last write, shown on that screen
	syncFrom      = nil,     -- the mode to return to when that screen closes
	autoSync      = {},      -- packs installed here: normalised name -> SMO date
	keyboardPacks = nil,     -- rows built from the CSV for keyboard mode, id desc
	pageOffsets   = {},      -- uiPage -> server row offset (pad mode paging)
	pageCache     = {},      -- "filter|search|page" -> rows already fetched for it

	-- arrowcloud.dance's popularity ranking, which gates the featured grid
	arrowcloud    = {
		status  = "idle",   -- settles on page 1: the featured grid waits on this
		deep    = "idle",   -- settles on all three: the beginner view waits on this
		keys    = {},       -- normalised name -> popularity rank, 1-based
		ranked  = {},       -- rank -> normalised name; sparse, walk it numerically
		created = {},       -- normalised name -> release date, YYYY-MM-DD
		packId  = {},       -- normalised name -> arrowcloud's own pack id
		banner  = {},       -- normalised name -> arrowcloud art url
		fresh   = {},       -- normalised names from the newest-first listing
		newStatus = "idle", -- idle | loading | ready | failed
		newPending = 0,
		count   = 0,
		pending = 0,
	},

	-- content level buckets (all-around / stamina)
	level         = { status="idle", bucket=nil, rows={}, pool={}, poolPos=0,
	                  inFlight=0, fetched=0 },

	-- installed packs view
	installed     = { status="idle", packs={}, cursor=1, window=0, scannedAt=nil },
	helper        = { status="idle", config=nil, reason=nil },
	removing      = nil,     -- pack name currently being deleted
	smoByName     = nil,     -- normalized pack name -> {id,name,songs,bytes,sizeStr}
	smoById       = nil,     -- pack id -> the same record, for search results

	-- search / year views: a locally held result set that pages client-side
	localRows     = nil,     -- non-nil = the list reads from here, not the server
	searchGen     = 0,       -- generation counter; stale search responses are dropped
	searchCapped  = false,   -- more matched than SEARCH.MAX_ROWS
	viewYear      = nil,     -- calendar year, or "older", the year view shows
	yearFloor     = 0,       -- oldest year with its own page; "older" is below it
	yearCursor    = 1,       -- selected year in the year picker

	-- charter recency (item: featured packs from charters active in the window)
	recentIndex   = { status="idle", dates={}, rows={}, page=0, cutoff="",
	                  yearCutoff="", deep=false, seen={} },
	authorPacks   = {},      -- charter name -> {status, ids, waiting}

	-- featured section
	zone          = "list",  -- tabs | featured | years | list (cursor zone)
	settled       = true,    -- false while the tab row is still moving; see LEVEL.Begin
	levelCache    = {},      -- bucket -> the finished list, kept between visits
	detailZone    = "songs", -- songs | download: what the detail page's cursor is on
	tabIndex      = 2,       -- cursor position in the tab row
	featCursor    = 1,
	featWindow    = 0,       -- first visible featured card (0-based)
	featured      = { status="idle", cards={}, pool={}, poolPos=0, pending={},
	                  fallback={}, inFlight=0, fetched=0, mode=nil, builtAt=nil },
}

-- refs to live actors, filled in by InitCommands
local refs = { rows = {}, songRows = {}, bars = {} }

-- actors are userdata, so per-sprite bookkeeping lives here instead
local loadedBanner = {}  -- spriteKey -> last path loaded into that sprite
local songArt      = {}  -- detail song row -> the fitted size of its artwork

-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.BANNER_DIR     = BANNER_DIR
CB.CACHE_DIR      = CACHE_DIR
CB.BROWSER_SCREEN = BROWSER_SCREEN
CB.FEAT           = FEAT
CB.REFRESH_SECS   = REFRESH_SECS
CB.ROWS           = ROWS
CB.SMO_BASE       = SMO_BASE
CB.SONG_ROWS      = SONG_ROWS
CB.loadedBanner   = loadedBanner
CB.refs           = refs
CB.songArt        = songArt
CB.state          = state
