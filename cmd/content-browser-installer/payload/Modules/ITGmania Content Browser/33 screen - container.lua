-- -----------------------------------------------------------------------
-- The container everything visible hangs from
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local LO    = CB.LO
local refs  = CB.refs
local state = CB.state

function CB.Screen.Container()
	-- ---------------------------------------------------------------
	-- main browser container (everything that hides while typing a search)
	local ui = Def.ActorFrame{
		Name = "UI",
		InitCommand = function(self) refs.ui = self end,
		SMORefreshMessageCommand = function(self)
			self:visible(state.open and not state.textEntryOpen)
		end,
	}

	-- dim the SL background a touch for readability
	ui[#ui+1] = Def.Quad{
		InitCommand = function(self)
			self:vertalign(top):horizalign(left)
			self:setsize(LO.W, LO.H):diffuse(0,0,0,0.66)
		end,
	}

	-- Opaque band over the strip ScreenSystemLayer uses for the credits
	-- ("PRESS START" at each side, "EVENT MODE" in the middle).  They are not
	-- ours to hide, so they get covered instead.
	ui[#ui+1] = Def.Quad{
		InitCommand = function(self)
			self:vertalign(bottom):horizalign(left)
			self:xy(0, LO.H):setsize(LO.W, LO.H - LO.CONTENT_BOT):diffuse(0, 0, 0, 1)
		end,
	}

	-- Where the content comes from, stated once and quietly, instead of a
	-- full-width header row repeating it.
	ui[#ui+1] = Def.BitmapText{
		Font = "Common Normal",
		Text = "pack data from stepmaniaonline.net",
		InitCommand = function(self)
			self:horizalign(right):xy(LO.W - 8, LO.CONTENT_BOT + 44):zoom(0.38)
			self:diffuse(0.55, 0.55, 0.55, 0.75)
		end,
		SMORefreshMessageCommand = function(self)
			self:visible(state.open and not state.textEntryOpen)
		end,
	}
	return ui
end
