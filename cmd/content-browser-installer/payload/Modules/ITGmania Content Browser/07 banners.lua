-- -----------------------------------------------------------------------
-- Fetching pack artwork, a few at a time
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local BANNER_DIR = CB.BANNER_DIR
local SMO_BASE   = CB.SMO_BASE
local UrlAllowed = CB.UrlAllowed
local state      = CB.state

local BANNER_RETRY_SECS = 600

-- Banner downloads are queued rather than all started at once.
--
-- A page of list rows, a full featured grid and the detail pane between them
-- ask for forty-odd images the moment the browser opens, and SMO's banners
-- average around 350 KB. Firing them together does not make any of them arrive
-- sooner -- it makes every one of them crawl, because they are all sharing the
-- same pipe. A handful at a time finishes the ones on screen far quicker.
-- The engine runs one HTTP request at a time on a single worker thread, so
-- handing it eight banners at once does not fetch them any faster -- it only
-- puts eight of them in front of whatever the view is actually waiting on.
-- Three keeps the art flowing without the data queueing behind a wall of it.
local BANNER_MAX_INFLIGHT = 3

local BannerPump   -- forward declaration (the download callback pumps again)

-- Upstream lives in the library part, which loads after this one, so it is
-- reached through the shared table at call time.
local function Upstream(...) return CB.Upstream(...) end

local function BannerBegin(url)
	-- SMO art is a site-relative path; arrowcloud art is an absolute url, and
	-- every pack of theirs is served as ".../<packdir>/pack-banner.png", so the
	-- filename alone would collide across the whole site. Take the directory
	-- with it.
	local absolute = url:match("^https?://") ~= nil
	local file = url:match("([%w%._%-]+)$")
	if not file then return false end
	if absolute then
		local dir = url:match("/([%w%._%-]+)/[%w%._%-]+$")
		file = (dir and (dir .. "_") or "ac_") .. file
	end
	local cachePath = BANNER_DIR .. file

	if FILEMAN:DoesFileExist(cachePath) then
		state.banners[url] = cachePath
		MESSAGEMAN:Broadcast("SMOBannerReady")
		return false          -- took no slot
	end

	state.bannerBusy[url] = true
	state.bannerInFlight = state.bannerInFlight + 1
	NETWORK:HttpRequest{
		url = Upstream(absolute and url or (SMO_BASE .. url)),
		downloadFile = "smo_" .. file,
		connectTimeout = 10,
		transferTimeout = 60,
		onResponse = function(response)
			state.bannerBusy[url] = nil
			state.bannerInFlight = math.max(0, state.bannerInFlight - 1)
			if response.error == nil and response.statusCode == 200
			   and FILEMAN:Copy("/Downloads/smo_" .. file, cachePath) then
				state.banners[url] = cachePath
				state.bannerFailed[url] = nil
				MESSAGEMAN:Broadcast("SMOBannerReady")
			else
				state.bannerFailed[url] = GetTimeSinceStart()
			end
			BannerPump()
		end,
	}
	return true
end

BannerPump = function()
	while state.bannerInFlight < BANNER_MAX_INFLIGHT and #state.bannerQueue > 0 do
		local url = table.remove(state.bannerQueue, 1)
		state.bannerQueued[url] = nil
		-- a cache hit takes no slot, so keep going in that case
		BannerBegin(url)
	end
end

local function RequestBanner(url)
	if not url or state.banners[url] or state.bannerBusy[url] then return end
	if state.bannerQueued[url] then return end
	-- negative cache: don't hammer the server re-requesting failed banners
	-- on every refresh
	local failedAt = state.bannerFailed[url]
	if failedAt and GetTimeSinceStart() - failedAt < BANNER_RETRY_SECS then return end
	if not UrlAllowed() then return end

	state.bannerQueued[url] = true
	state.bannerQueue[#state.bannerQueue+1] = url
	BannerPump()
end

-- a pack's banner url, falling back to the one scraped from its detail page
-- (CSV-sourced keyboard rows have no banner in the row data)
local function BannerUrlFor(pack)
	if not pack then return nil end
	if pack.banner then return pack.banner end
	local det = state.details[pack.id]
	return det and det.banner
end

local function PrefetchBanners()
	for pack in ivalues(state.packs) do
		RequestBanner(BannerUrlFor(pack))
	end
end

-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.BannerUrlFor    = BannerUrlFor
CB.PrefetchBanners = PrefetchBanners
CB.RequestBanner   = RequestBanner
