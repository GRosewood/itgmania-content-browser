-- -----------------------------------------------------------------------
-- Four actors that draw nothing
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local BROWSER_SCREEN             = CB.BROWSER_SCREEN
local DownloadsActive            = CB.DownloadsActive
local LO                         = CB.LO
local ReclaimInputAfterTextEntry = CB.ReclaimInputAfterTextEntry
local Refresh                    = CB.Refresh
local Snd                        = CB.Snd
local UP                         = CB.UP
local refs                       = CB.refs
local state                      = CB.state

function CB.Screen.HiddenHelpers(af)
	-- ---------------------------------------------------------------
	-- invisible helper: the song sample player
	af[#af+1] = Def.Sound{
		InitCommand = function(self) Snd.actor = self end,
	}

	-- ---------------------------------------------------------------
	-- invisible helper: heartbeat for download progress updates
	af[#af+1] = Def.Actor{
		InitCommand = function(self) refs.heart = self end,

		SMOArmHeartbeatCommand = function(self)
			self:stoptweening()
			self:queuecommand("SMOHeartbeat")
		end,
		SMOHeartbeatCommand = function(self)
			-- An update needs this as much as a download does. Its progress is
			-- read by a poll that Refresh fires, and Refresh is only called
			-- when something happens -- so without a clock the first answer
			-- from the helper would also be the last, and the dialog would sit
			-- on "Downloading..." through an update that had already finished.
			if state.open and (DownloadsActive() or UP.Busy()
			   or LO.DetailTicking()) then
				Refresh()
				self:sleep(0.2):queuecommand("SMOHeartbeat")
			end
		end,
	}

	-- invisible helper: holds a tabbed view's fetches back until the tab row
	-- has stopped moving, so cycling past a tab does not ask the network for
	-- it.  See LO.LevelBegin.
	af[#af+1] = Def.Actor{
		InitCommand = function(self) refs.settle = self end,
		SMOArmSettleCommand = function(self)
			self:stoptweening()
			self:sleep(0.3):queuecommand("SMOSettled")
		end,
		SMOSettledCommand = function(self)
			LO.LevelBegin()
		end,
	}

	-- invisible helper: watches for ScreenTextEntry closing (its own actor,
	-- so nothing else can stoptweening() its polling chain away)
	af[#af+1] = Def.Actor{
		InitCommand = function(self) refs.watcher = self end,

		SMOWatchTextEntryCommand = function(self)
			if not state.textEntryOpen then return end
			local top = SCREENMAN:GetTopScreen()
			if top and top:GetName() == BROWSER_SCREEN then
				ReclaimInputAfterTextEntry()
			else
				self:sleep(0.1):queuecommand("SMOWatchTextEntry")
			end
		end,
	}
end
