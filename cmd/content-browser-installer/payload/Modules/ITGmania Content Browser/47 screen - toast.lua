-- -----------------------------------------------------------------------
-- The toast
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local AccentColor = CB.AccentColor
local LO          = CB.LO
local state       = CB.state

function CB.Screen.Toast(af)
	-- ---------------------------------------------------------------
	-- toast

	af[#af+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(LO.W/2, LO.CONTENT_BOT - 8):zoom(0.6):diffusealpha(0)
		end,
		SMOToastMessageCommand = function(self, params)
			if not state.open then return end
			self:finishtweening()
			self:settext(params and params.Text or "")
			self:diffuse(AccentColor()):diffusealpha(1)
			self:sleep(2):linear(0.4):diffusealpha(0)
		end,
	}
end
