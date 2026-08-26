-- -----------------------------------------------------------------------
-- The download queue and the self-updater
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local Clamp = CB.Clamp
local state = CB.state

local LO = {}

local DL = {}

-- How a finished download leaves the ticker: it brightens for a moment so the
-- eye is caught by something that has just changed, then fades, then is gone.
-- Twelve silent seconds of a row that had already finished was neither.
DL.SHOW_DONE = 2.6   -- seconds a finished row lingers before it drops off
DL.GLOW_FOR  = 0.7   -- ...of which this many are the bright flare
DL.FADE_FOR  = 1.4   -- ...and this many are the fade after it

-- 0 while a row is still working, then 0..1 through the flare and the fade.
-- Anything past 1 has left.
function DL.Leaving(dl)
	if not (dl and dl.status == "done" and dl.finishedAt) then return 0 end
	local gone = GetTimeSinceStart() - dl.finishedAt
	if gone <= 0 then return 0 end
	return gone / DL.SHOW_DONE
end

-- The queue as it should be drawn: start order, finished rows ageing out,
-- failures staying put because a failure nobody saw is not worth reporting.
function DL.Rows()
	local rows = {}
	local now = GetTimeSinceStart()
	for id in ivalues(state.dlOrder) do
		local dl = state.downloads[id]
		if dl then
			local keep = (dl.status == "active" or dl.status == "installing"
				or dl.status == "error")
			if dl.status == "done" and dl.finishedAt
			   and (now - dl.finishedAt) < DL.SHOW_DONE then
				keep = true
			end
			if keep then rows[#rows+1] = dl end
		end
	end
	return rows
end

-- What one row says on the right-hand side, and how full its bar is. A
-- negative fraction means there is nothing to measure: unpacking happens in
-- one blocking call that cannot report on itself.
function DL.RowState(dl)
	if dl.status == "installing" then return "unpacking", -1 end
	if dl.status == "done" then return "done", 1 end
	if dl.status == "error" then return "failed", 0 end
	if dl.total and dl.total > 0 then
		local frac = Clamp(dl.cur / dl.total, 0, 1)
		return math.floor(frac * 100 + 0.5) .. "%", frac
	end
	return "", -1
end

-- -----------------------------------------------------------------------
-- updates
--
-- The helper decides whether a newer browser has been published and installs
-- it; this side asks, draws the answer, and reloads once the files have landed.
--
-- The check is not made from here for the same reason removal is not: the
-- engine will only talk to hosts on its own allowlist, and asking a player to
-- widen that list to read one small JSON file is a poor trade. The helper has
-- no such limit and is already running.
local UP = {}

UP.VERSION = "0.7"     -- what this module is; the installer reports the same
UP.state   = nil       -- the last manifest answer about versions
UP.asked   = false     -- ...and whether it has been asked yet this session
UP.job     = nil       -- an update in flight

-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.DL = DL
CB.LO = LO
CB.UP = UP
