-- -----------------------------------------------------------------------
-- The heading band
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local AccentColor  = CB.AccentColor
local BandBusy     = CB.BandBusy
local BandBusyText = CB.BandBusyText
local BandSubtitle = CB.BandSubtitle
local BandTitle    = CB.BandTitle
local InLevelView  = CB.InLevelView
local LO           = CB.LO
local Spinner      = CB.Spinner
local state        = CB.state

function CB.Screen.ContextBand(ui)
	-- ---------------------------------------------------------------
	-- Context band: fills the strip the featured cards occupy, for the views
	-- that have no featured grid of their own (search and the content levels).

	local bandAF = Def.ActorFrame{
		Name = "Band",
		InitCommand = function(self) self:visible(false) end,
		SMORefreshMessageCommand = function(self)
			-- the keyboard tab has no grid, so the band is its header too
			local keyboardList = state.mode == "list" and state.search == ""
				and state.filterMode == "keyboard"
			self:visible(state.open and state.mode ~= "detail"
				and (InLevelView() or state.search ~= "" or keyboardList))
		end,
	}

	bandAF[#bandAF+1] = Def.Quad{
		InitCommand = function(self)
			self:vertalign(top):horizalign(left)
			self:xy(LO.LIST_X, LO.FEAT_TOP):setsize(LO.W - 2*LO.LIST_X, LO.FEAT_CARD_H)
			self:diffuse(1, 1, 1, 0.05)
		end,
	}

	bandAF[#bandAF+1] = Def.BitmapText{
		Font = "Common Bold",
		InitCommand = function(self)
			self:horizalign(left):xy(LO.LIST_X + 18, LO.FEAT_TOP + 26):zoom(0.42)
		end,
		SMORefreshMessageCommand = function(self)
			self:settext(BandTitle())
			self:diffuse(AccentColor())
		end,
	}

	bandAF[#bandAF+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(left):xy(LO.LIST_X + 18, LO.FEAT_TOP + 52):zoom(0.55)
			self:diffuse(0.78, 0.78, 0.78, 1)
			self:maxwidth((LO.W - 2*LO.LIST_X - 120)/0.55)
		end,
		SMORefreshMessageCommand = function(self)
			self:settext(BandSubtitle())
		end,
	}

	-- progress, for the searches and level scans that take a moment
	bandAF[#bandAF+1] = Spinner(LO.W - LO.LIST_X - 34, LO.FEAT_TOP + LO.FEAT_CARD_H/2, 0.16,
		function()
			return BandBusy()
		end)

	bandAF[#bandAF+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(right):xy(LO.W - LO.LIST_X - 56, LO.FEAT_TOP + LO.FEAT_CARD_H/2)
			self:zoom(0.5)
		end,
		SMORefreshMessageCommand = function(self)
			self:settext(BandBusy() and BandBusyText() or "")
			self:diffuse(AccentColor())
		end,
	}

	ui[#ui+1] = bandAF
end
