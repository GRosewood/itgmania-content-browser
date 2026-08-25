-- -----------------------------------------------------------------------
-- The modal dialogs
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local AccentColor   = CB.AccentColor
local Clamp         = CB.Clamp
local CurrentPack   = CB.CurrentPack
local InstalledPack = CB.InstalledPack
local LO            = CB.LO
local Snd           = CB.Snd
local Sync          = CB.Sync
local UP            = CB.UP
local state         = CB.state

function CB.Screen.Dialogs(af, ui)
	-- ---------------------------------------------------------------
	-- modal dialogs (network warning / confirm / reload)

	-- bodyFn returns title, body, hint.  The hint is the only place the
	-- confirm/cancel keys are printed for a dialog; the footer stays quiet.
	local function DialogFrame(name, visibleFn, bodyFn, height, choicesFn, choiceIcons, radio, slots)
		local h = height or LO.DIALOG_H
		local bodyText   -- captured so the choice row can sit under it
		local dialog = Def.ActorFrame{
			Name = name,
			InitCommand = function(self) self:xy(LO.W/2, LO.H/2):visible(false) end,
			SMORefreshMessageCommand = function(self)
				self:visible(state.open and not state.textEntryOpen and visibleFn())
			end,

			Def.Quad{ InitCommand=function(self) self:setsize(LO.DIALOG_W + 4, h + 4):diffuse(1, 1, 1, 1) end },
			Def.Quad{ InitCommand=function(self) self:setsize(LO.DIALOG_W, h):diffuse(0, 0, 0, 1) end },

			Def.BitmapText{
				Font = "Common Bold",
				InitCommand = function(self)
					self:y(-h/2 + 22):zoom(0.4)
				end,
				SMORefreshMessageCommand = function(self)
					local title = bodyFn()
					self:settext(title or "")
					self:diffuse(AccentColor())
				end,
			},

			-- rule under the title
			Def.Quad{
				InitCommand = function(self)
					self:y(-h/2 + 38):setsize(LO.DIALOG_W - 48, 1)
				end,
				SMORefreshMessageCommand = function(self)
					self:diffuse(AccentColor()):diffusealpha(0.45)
				end,
			},

			Def.BitmapText{
				Font = "Common Normal",
				InitCommand = function(self)
					bodyText = self
					self:y(-h/2 + 46):vertalign(top):zoom(0.58):diffuse(0.9, 0.9, 0.9, 1)
					self:wrapwidthpixels((LO.DIALOG_W - 40)/0.58)
				end,
				SMORefreshMessageCommand = function(self)
					local _, body = bodyFn()
					self:settext(body or "")
				end,
			},

			-- The dialog's own confirm/cancel line.
			--
			-- Near enough to white on purpose. The button names in it are not
			-- letters, they are little pictures from the theme's glyph sheet, and
			-- they arrive already coloured -- START green, SELECT red, BACK grey,
			-- the menu arrows yellow. Diffuse multiplies, so tinting this line
			-- with the accent left START looking right by luck and turned grey
			-- BACK into a murky green that read as a third kind of button.
			Def.BitmapText{
				Font = "Common Normal",
				InitCommand = function(self)
					self:y(h/2 - 18):zoom(0.6):diffuse(0.88, 0.88, 0.88, 1)
					self:maxwidth((LO.DIALOG_W - 30)/0.6)
				end,
				SMORefreshMessageCommand = function(self)
					local _, _, hint = bodyFn()
					self:settext(hint or "")
				end,
			},
		}

		-- A dialog that asks which of two things to do rather than whether to
		-- do one thing. The options sit above the hint line; a dialog without
		-- them is unchanged.
		-- a line under where the body stops, or the bottom of the dialog if the
		-- body runs long enough to reach it
		local function ChoiceY()
			local top = -h/2 + 46
			local used = bodyText and bodyText:GetZoomedHeight() or 0
			if used <= 0 then return h/2 - 48 end
			return math.min(top + used + 20, h/2 - 48)
		end

		if choicesFn then
			-- An icon shifts its label sideways to keep the pair centred in the
			-- box, and the icon then hangs off the label's measured width --
			-- which is why the row frame below sets the label and places the
			-- icon itself, in one pass, rather than leaving the width in a
			-- table for the icon to pick up whenever its turn happens to come.
			local ICON_W, ICON_GAP = 13, 5
			local COUNT = slots or 2
			local BOX_GAP = 8
			local BOX_W = math.floor((LO.DIALOG_W - 20 - (COUNT-1)*BOX_GAP) / COUNT)
			local ROW_W = COUNT*BOX_W + (COUNT-1)*BOX_GAP
			local DOT_X, TEXT_X = -BOX_W/2 + 14, -BOX_W/2 + 28

			for ci = 1, COUNT do
				local cx = -ROW_W/2 + BOX_W/2 + (ci-1)*(BOX_W + BOX_GAP)
				local cy = 0   -- everything below sits inside the row frame

				-- which icon this slot carries, if the file is actually there
				local iconName = nil
				do
					local want = choiceIcons and choiceIcons[ci]
					if want and FILEMAN:DoesFileExist(LO.ICONS .. want) then
						iconName = LO.ICONS .. want
					end
				end
				local shift = (ICON_W + ICON_GAP)/2

				-- A slot can still turn its icon off for a particular state --
				-- a play triangle on "No song picked" would be a lie -- so the
				-- labels say which slots are live, and the label only shifts
				-- over for an icon that is really there.
				local function IconOn()
					if not (iconName or radio) then return false end
					local list, _, on = choicesFn()
					if not (list and list[ci]) then return false end
					if radio then return true end
					if on == nil then return true end
					return on[ci] ~= nil
				end

				-- The row itself, positioned once on behalf of all its parts --
				-- and the one place the label and the icon are dealt with,
				-- because the icon is placed from how wide the label came out
				-- and only the label can measure the label. Written below
				-- IconOn on purpose: a closure compiled above a local binds
				-- that name to a global instead, and a global nobody sets is nil.
				local slot = Def.ActorFrame{
					InitCommand = function(self) self:y(h/2 - 48) end,
					SMORefreshMessageCommand = function(self)
						self:y(ChoiceY())

						local label = self:GetChild("Label")
						local icon  = self:GetChild("Icon")
						local list, idx = choicesFn()
						local live = list ~= nil and list[ci] ~= nil

						-- the label first: the icon is placed from its width
						label:visible(live)
						if live then
							label:settext(list[ci])
							if not radio then
								label:x(cx + (IconOn() and shift or 0))
							end
							if idx == ci then
								label:diffuse(1, 1, 1, 1)
							else
								label:diffuse(0.65, 0.65, 0.65, 1)
							end
						end

						if icon then
							local on = live and IconOn()
							icon:visible(on and true or false)
							if on then
								local w = label:GetZoomedWidth()
								icon:x(cx + shift - w/2 - ICON_GAP - ICON_W/2)
								if idx == ci then
									icon:diffuse(1, 1, 1, 1)
								else
									icon:diffuse(0.65, 0.65, 0.65, 1)
								end
							end
						end
					end,
				}

				slot[#slot+1] = Def.Quad{
					InitCommand = function(self)
						self:xy(cx, cy):setsize(BOX_W, 26)
					end,
					SMORefreshMessageCommand = function(self)
						local list, idx = choicesFn()
						self:visible(list ~= nil and list[ci] ~= nil)
						if not (list and list[ci]) then return end
						if idx == ci then
							self:diffuse(AccentColor()):diffusealpha(0.38)
						else
							self:diffuse(0.15, 0.15, 0.15, 1)
						end
					end,
				}
				slot[#slot+1] = Def.BitmapText{
					Name = "Label",
					Font = "Common Normal",
					InitCommand = function(self)
						self:zoom(0.5)
						if radio then
							self:horizalign(left):xy(cx + TEXT_X, cy)
							self:maxwidth((BOX_W - 40)/0.5)
						else
							self:xy(cx, cy)
							self:maxwidth((BOX_W - 8 - shift*2)/0.5)
						end
						self:visible(false)
					end,
				}

				-- A radio pair rather than a fixed icon: the filled one shows on
				-- the choice that is selected, so the dialog says which it will
				-- write rather than only writing it.
				if radio then
					for state_on in ivalues({ false, true }) do
						local file = state_on and "radioon.png" or "radiooff.png"
						local path = LO.ICONS .. file
						if FILEMAN:DoesFileExist(path) then
							slot[#slot+1] = Def.Sprite{
								Texture = path,
								InitCommand = function(self)
									self:xy(cx + DOT_X, cy):zoom(ICON_W/96):visible(false)
								end,
								SMORefreshMessageCommand = function(self)
									local list, idx = choicesFn()
									local mine = (list ~= nil and list[ci] ~= nil)
										and ((idx == ci) == state_on)
									self:visible(mine)
									if not mine then return end
									if idx == ci then
										self:diffuse(1, 1, 1, 1)
									else
										self:diffuse(0.62, 0.62, 0.62, 1)
									end
								end,
							}
						end
					end
				end

				if iconName then
					slot[#slot+1] = Def.Sprite{
						Name = "Icon",
						Texture = iconName,
						InitCommand = function(self)
							-- drawn at 96px, shown at 13, like the tab icons
							self:xy(cx, cy):zoom(ICON_W/96):visible(false)
						end,
					}
				end

				dialog[#dialog+1] = slot
			end
		end
		return dialog
	end

	af[#af+1] = ui

	af[#af+1] = DialogFrame("NetworkWarningDialog",
		function() return state.mode == "blocked" end,
		function()
			if LO.TooNarrow() then
				-- nothing to run and nothing to install; the fix is a setting
				return LO.BlockedTitle(), LO.BlockedReason(),
					"&BACK; back to the title menu"
			end
			local reason = state.blockedReason or "Network access is not enabled."
			local fix = "Run the Find Content installer again, or -- with ITGmania closed -- "
				.. LO.SetupScript() .. "  in " .. LO.MODULE_DIR
			return LO.BlockedTitle(), reason .. "\n\n" .. fix,
				"&BACK; back to the title menu"
		end, 210)

	af[#af+1] = DialogFrame("ConfirmDialog",
		function() return state.mode == "confirm" end,
		function()
			local pack = CurrentPack()
			if not pack then return "", "" end
			local det = state.details[pack.id]
			local song = det and det.songs[state.songPick] or nil
			local body = pack.name .. "\n" .. pack.sizeStr .. "  -  " .. pack.songs .. " songs"
			if SONGMAN:DoesSongGroupExist(pack.name) then
				body = body .. "\nalready in your library - remove it from the"
					.. "\nInstalled tab if you want it again"
			end
			if song then
				body = body .. "\nselected song:  " .. song.title
					.. "\nsingles land in:  " .. Sync.SinglesFolder(pack)
			end
			local dl = state.downloads[pack.id]
			if dl and (dl.status == "active" or dl.status == "installing") then
				body = body .. "\n(this pack is downloading already)"
			end
			local hint = "&MENULEFT;&MENURIGHT; choose    &START; go    &BACK; cancel"
			local known = Snd.KnownFor(song, pack)
			if state.chooseIdx == 1 and known and #known > 1 then
				hint = "&MENUUP;&MENUDOWN; difficulty   &MENULEFT;&MENURIGHT; choose   "
					.. "&START; go   &BACK; cancel"
			end
			return "Listen or Download?", body, hint
		end, 205,
		function()
			local pack = CurrentPack()
			local det = pack and state.details[pack.id]
			local song = det and det.songs[state.songPick] or nil
			local have = pack ~= nil and SONGMAN:DoesSongGroupExist(pack.name)
			-- The first choice names the difficulty it would play once one is
			-- known, so choosing between them is the same press as choosing
			-- the choice. Before that it is simply "Preview": the difficulties
			-- are inside the pack, and the first preview is what reads them.
			local known = Snd.KnownFor(song, pack)
			local label = "Preview"
			if known and #known > 0 then
				local at = Snd.pick
				if not at or at < 1 then
					local was = Snd.charts
					Snd.charts = known
					at = Snd.DefaultChart()
					Snd.charts = was
				end
				label = "Preview  " .. Snd.ChartLabel(known[at])
			end
			return { song and label or "No song picked",
					song and "Get this song" or "No song picked",
					have and "In your library" or "Download pack" },
				state.chooseIdx,
				-- a symbol for something that will not happen is worse than
				-- none: the triangle goes when there is no song to play, and
				-- the arrow goes when there is nothing left to fetch
				{ song and true or nil, song and true or nil,
					(not have) and true or nil }
		end, { "play.png", "download.png", "download.png" }, nil, 3)

	af[#af+1] = DialogFrame("RemovePackDialog",
		function() return state.mode == "removeconfirm" end,
		function()
			local pack = InstalledPack()
			if not pack then return "", "" end
			local body = pack.name .. "\n"
				.. pack.songs .. (pack.songs == 1 and " song" or " songs") .. "\n\n"
				.. "This deletes the pack from your Songs folder. It cannot be undone; "
				.. "you would have to download the pack again.\n\n"
				.. "Your song list refreshes when you leave the browser."
			return "Delete This Pack?", body, "&START; delete it    &BACK; cancel"
		end, 230)

	-- What changed, in the words for what actually changed. It said "New Packs
	-- Installed" over a single song, and over a removal, because it only ever
	-- knew that *something* had.
	local function ReloadWords()
		local bits = {}
		if state.reloadPacks > 0 then
			bits[#bits+1] = state.reloadPacks .. (state.reloadPacks == 1 and " pack" or " packs")
		end
		if state.reloadSongs > 0 then
			bits[#bits+1] = state.reloadSongs .. (state.reloadSongs == 1 and " song" or " songs")
		end
		local got = table.concat(bits, " and ")
		local gone = state.reloadGone > 0
		if got ~= "" and gone then
			return "Library Changed",
				got .. " added, " .. state.reloadGone .. " removed."
				.. "\nReload songs now so the changes show up?"
		elseif got ~= "" then
			local what = (state.reloadSongs > 0 and state.reloadPacks == 0)
				and "song" or "content"
			return (state.reloadSongs > 0 and state.reloadPacks == 0)
					and "New Songs Installed" or "New Content Installed",
				got .. " added.\nReload songs now so the new " .. what .. " shows up?"
		elseif gone then
			return "Packs Removed",
				state.reloadGone .. (state.reloadGone == 1 and " pack" or " packs")
				.. " removed.\nReload songs now so they leave the wheel?"
		end
		return "Library Changed", "Reload songs now so the changes show up?"
	end

	-- The update, while it happens.
	--
	-- There is no cancel on it. By the time this is on screen the helper is
	-- already fetching, and stopping half way through writing a module over
	-- itself is worse than finishing. The only branch is what to do when it
	-- fails, and that is a way back rather than a way out.
	local function UpdateWords()
		local job = UP.job or {}
		local phase = tostring(job.phase or "checking")
		local version = tostring(job.version or UP.Latest())
		local title = (version ~= "" and ("Installing " .. version)) or "Installing the update"

		if phase == "error" then
			-- Honest about what a failure leaves behind. The update writes the
			-- module's files one at a time, so a failure partway can leave a
			-- mixture of old and new on disk -- "nothing was changed" was true
			-- when the module was one file and is not true of forty. Running
			-- the update again rewrites everything, which is the repair.
			return "Update Failed",
				tostring(job.error or "something went wrong") ..
				"\nRun the update again to finish the job -- a failure partway "
				.. "can leave a mix of old and new files, and a re-run rewrites "
				.. "them all. You are on " .. UP.VERSION .. " until it completes.",
				"&START;&BACK; back"
		elseif phase == "downloading" then
			return title, "Downloading...", ""
		elseif phase == "verifying" then
			return title, "Checking what arrived...", ""
		elseif phase == "writing" then
			return title, "Installing the files...", ""
		elseif phase == "done" then
			return title, "Reloading...", ""
		end
		return title, "Asking for the update...", ""
	end

	af[#af+1] = DialogFrame("UpdateDialog",
		function() return state.mode == "update" end,
		UpdateWords, 150)

	-- Its progress bar. DialogFrame draws words; this is the one dialog where
	-- the words alone leave you watching a screen that might be stuck.
	do
		local BAR_W, BAR_Y = LO.DIALOG_W - 96, 26
		local function Showing()
			return state.open and not state.textEntryOpen
			       and state.mode == "update"
			       and (UP.job == nil or UP.job.phase ~= "error")
		end
		-- -1 while the size is unknown, which is most of the short phases
		local function Fraction()
			local job = UP.job
			if not job then return -1 end
			local pct = tonumber(job.pct)
			if not pct or pct < 0 then return -1 end
			return Clamp(pct, 0, 1)
		end

		af[#af+1] = Def.Quad{
			InitCommand = function(self)
				self:xy(LO.W/2, LO.H/2 + BAR_Y):setsize(BAR_W, 5)
				self:diffuse(1, 1, 1, 0.14):visible(false)
			end,
			SMORefreshMessageCommand = function(self) self:visible(Showing()) end,
		}
		af[#af+1] = Def.Quad{
			InitCommand = function(self)
				self:horizalign(left):xy(LO.W/2 - BAR_W/2, LO.H/2 + BAR_Y)
				self:setsize(0, 5):visible(false)
			end,
			SMORefreshMessageCommand = function(self)
				self:visible(Showing())
				if not Showing() then return end
				local frac = Fraction()
				self:diffuse(AccentColor())
				if frac < 0 then
					-- nothing to measure yet: a sliver that breathes, so the
					-- bar reads as working rather than as stuck at zero
					local beat = 0.5 + 0.5 * math.sin(GetTimeSinceStart() * 3)
					self:diffusealpha(0.35 + 0.3 * beat)
					self:setsize(math.max(4, BAR_W * 0.12), 5)
					self:x(LO.W/2 - BAR_W/2 + (BAR_W - BAR_W*0.12) * beat)
				else
					self:diffusealpha(0.95)
					self:x(LO.W/2 - BAR_W/2)
					self:setsize(math.max(2, BAR_W * frac), 5)
				end
			end,
		}
	end

	af[#af+1] = DialogFrame("ReloadDialog",
		function() return state.mode == "reload" end,
		function()
			local title, body = ReloadWords()
			return title, body, "&MENULEFT;&MENURIGHT; choose    &START; go    &BACK; cancel"
		end, 150,
		function()
			return { "Reload songs", "Not yet" }, state.reloadIdx
		end, { "installed.png", nil }, nil, 2)

	-- The sync screen. It is the explainer for the whole subject, and on an
	-- installed pack with no Pack.ini it is also where one gets written.
	af[#af+1] = DialogFrame("SyncDialog",
		function() return state.mode == "sync" end,
		function()
			local pack = state.syncPack
			if not pack then
				return "Pack Sync",
					"Open this from the INSTALLED tab with a pack highlighted and it will "
					.. "write a Pack.ini for that pack." .. "\n\n" .. Sync.Explain(),
					"&BACK; close"
			end

			local canWrite = (pack.dir ~= nil) and (pack.sync == nil or pack.syncOurs)
			local _, why = Sync.Health(pack)

			-- Where the pack stands: what it is actually being played as, what
			-- decides that when the pack does not, and what SMO claims.
			local body = pack.name .. "\n"
				.. "playing as " .. (Sync.Applied(pack) or Sync.Machine())
				.. "   -   machine default: " .. Sync.MachineLabel()
				.. "   -   SMO: " .. (Sync.SmoFor(pack) or "not listed")
				.. "\n\n" .. why .. "\n\n"

			if state.syncNote then
				body = body .. state.syncNote
			elseif pack.dir == nil then
				body = body .. "This pack's folder could not be found, so nothing can be "
					.. "written for it."
			elseif canWrite then
				-- the value itself is the radio row below, not a sentence
				body = body .. (pack.syncOurs and "Change what this pack is recorded as:"
						or "Record what this pack really is:")
					.. "\n\n"
					.. "If you know what this pack's sync actually is, set it here and "
					.. "a Pack.ini is written saying so. That pins it, and this "
					.. "machine's preference stops deciding for it. Packs made before "
					.. "Pack.ini existed are ITG, which is why that is what this opens "
					.. "on."
			else
				body = body .. "It came with its own " .. (pack.syncFile or "Pack.ini")
					.. ", so it is left alone -- rewriting one would throw away its title, "
					.. "banner and series keys along with the sync. Delete that file to hand "
					.. "the pack back to the machine's preference."
			end

			local hint = "&BACK; close"
			if state.syncNote then
				hint = "&START;&BACK; OK"
			elseif canWrite then
				hint = "&MENULEFT;&MENURIGHT; ITG / NULL    &START; write Pack.ini    &BACK; close"
			end
			return "Pack Sync", body, hint
		end, 320,
		-- The two values as radio buttons while there is something to choose,
		-- and afterwards a single lit OK.
		--
		-- Something has to be under the cursor once the writing is done. The
		-- radio pair disappearing left the dialog with a paragraph and no way
		-- out that the screen itself named, so the reader had to know that Back
		-- would do it.
		function()
			local pack = state.syncPack
			if state.syncNote then return { "OK" }, 1 end
			if not pack then return nil end
			if pack.dir == nil or (pack.sync ~= nil and not pack.syncOurs) then return nil end
			return { "ITG  (+9ms)", "NULL  (0ms)" },
				(state.syncChoice == "ITG") and 1 or 2
		end, nil, true)
end
