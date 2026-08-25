-- -----------------------------------------------------------------------
-- Fetching one pack's own page
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local ParsePackDetail = CB.ParsePackDetail
local Refresh         = CB.Refresh
local SMO_BASE        = CB.SMO_BASE
local UrlAllowed      = CB.UrlAllowed
local state           = CB.state

-- Upstream lives in the library part, which loads after this one, so it is
-- reached through the shared table at call time.
local function Upstream(...) return CB.Upstream(...) end

local DETAIL_RETRY_SECS = 30

-- How long a request may be in flight before it is treated as lost.
--
-- Comfortably past the engine's own limits below (10s to connect, 30s to
-- transfer), because a reply that beat those would have arrived. What this
-- catches is the reply that never comes at all: onResponse is the only thing
-- that clears detailBusy, so a request dropped by a module reload, or one
-- whose callback was skipped because the browser had retired, left the flag
-- set for the rest of the session -- and the page spun forever waiting on a
-- reply nobody was carrying.
local DETAIL_DEADLINE = 45

-- Is a fetch for this pack genuinely in the air right now?
--
-- The flag alone is not enough to say so, because nothing but a reply clears
-- it. Past the deadline the flag is a leftover, not a promise.
local function DetailInFlight(packId)
	if not state.detailBusy[packId] then return false end
	local at = state.detailAt[packId]
	if at and GetTimeSinceStart() - at > DETAIL_DEADLINE then return false end
	return true
end

-- force=true bypasses the failure cooldown (used for explicit user actions)
local function FetchDetail(pack, cb, force)
	local existing = state.details[pack.id]
	if existing then
		if cb then cb(existing) end
		return
	end
	-- negative cache so a failing detail page isn't refetched in a loop by
	-- every UI refresh
	local failedAt = state.detailFailed[pack.id]
	if failedAt and not force and GetTimeSinceStart() - failedAt < DETAIL_RETRY_SECS then
		if cb then cb(nil) end
		return
	end
	if DetailInFlight(pack.id) then
		if cb then cb(nil) end
		return
	end
	if not UrlAllowed() then
		-- Nothing was asked and nothing is coming. Recording it as a failure
		-- is what stops the page waiting on a request that was never made --
		-- an absence and a wait look identical from the outside, and only one
		-- of them ends.
		state.detailFailed[pack.id] = GetTimeSinceStart()
		state.detailBusy[pack.id] = nil
		if cb then cb(nil) end
		return
	end

	state.detailBusy[pack.id] = true
	state.detailAt[pack.id] = GetTimeSinceStart()
	NETWORK:HttpRequest{
		url = Upstream(SMO_BASE .. "/pack/" .. pack.id),
		connectTimeout = 10,
		transferTimeout = 30,
		onResponse = function(response)
			state.detailBusy[pack.id] = nil
			state.detailAt[pack.id] = nil
			local det = nil
			if response.error == nil and response.statusCode == 200 then
				local ok, parsed = pcall(ParsePackDetail, response.body)
				if ok and parsed then
					state.details[pack.id] = parsed
					state.detailFailed[pack.id] = nil
					det = parsed
				end
			end
			if det == nil then
				state.detailFailed[pack.id] = GetTimeSinceStart()
			end
			if cb then cb(det) end
			Refresh()
		end,
	}
end

-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.DetailInFlight = DetailInFlight
CB.FetchDetail    = FetchDetail
