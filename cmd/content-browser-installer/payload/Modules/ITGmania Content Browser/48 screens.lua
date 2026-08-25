-- -----------------------------------------------------------------------
-- The table the theme asked for
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local BROWSER_SCREEN = CB.BROWSER_SCREEN
local BrowserActor   = CB.BrowserActor
local TitleActor     = CB.TitleActor
local state          = CB.state


-- -----------------------------------------------------------------------
-- module table

local t = {}

t["ScreenTitleMenu"] = TitleActor()
t[BROWSER_SCREEN]    = BrowserActor()

-- when we send the player to the differential song reload, make sure it
-- returns to the title menu instead of ScreenSelectMusic
t["ScreenReloadSongsSSM"] = Def.Actor{
	ModuleCommand = function(self)
		-- any differential reload (ours or Simply Love's own "Load New Songs")
		-- picks up packs we installed, so the reload reminder is settled
		state.needsReload = false
		if state.reloadForUs then
			state.reloadForUs = false
			local screen = SCREENMAN:GetTopScreen()
			if screen then
				screen:SetNextScreenName("ScreenTitleMenu")
			end
		end
	end,
}

return t
