-- -----------------------------------------------------------------------
-- The pack detail page, and the equalizer on it
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local AccentColor    = CB.AccentColor
local BannerUrlFor   = CB.BannerUrlFor
local Clamp          = CB.Clamp
local Commify        = CB.Commify
local CurrentPack    = CB.CurrentPack
local DownloadLoaded = CB.DownloadLoaded
local FitSprite      = CB.FitSprite
local FormatBytes    = CB.FormatBytes
local FormatDate     = CB.FormatDate
local LO             = CB.LO
local MeterColor     = CB.MeterColor
local RequestBanner  = CB.RequestBanner
local SONG_ROWS      = CB.SONG_ROWS
local ScrollBar      = CB.ScrollBar
local Snd            = CB.Snd
local Spinner        = CB.Spinner
local SpinnerChild   = CB.SpinnerChild
local SpinnerSet     = CB.SpinnerSet
local loadedBanner   = CB.loadedBanner
local songArt        = CB.songArt
local state          = CB.state

function CB.Screen.DetailPage(HIST_MAX_BARS)
	-- ---------------------------------------------------------------
	-- DETAIL VIEW

	local detail = Def.ActorFrame{
		Name = "Detail",
		InitCommand = function(self) self:visible(false) end,
		SMORefreshMessageCommand = function(self)
			self:visible(state.open and LO.DetailShowing())
		end,
	}

	local DET_LEFT_W = math.floor(LO.W * 0.38)
	local DET_SONGS_X = DET_LEFT_W + 32
	local DET_SONGS_W = LO.W - DET_SONGS_X - 20
	local SONG_ROW_H = 46
	local SONG_TOP = 66

	-- left column: banner + stats + histogram
	detail[#detail+1] = Def.Sprite{
		InitCommand = function(self) self:xy(16 + DET_LEFT_W/2, 105) end,
		SMORefreshMessageCommand = function(self) self:playcommand("SMOSetBanner") end,
		SMOBannerReadyMessageCommand = function(self) self:playcommand("SMOSetBanner") end,
		SMOSetBannerCommand = function(self)
			local pack = CurrentPack()
			local url = pack and BannerUrlFor(pack)
			local path = url and state.banners[url]
			if pack and path and LO.DetailShowing() then
				if loadedBanner.detail ~= path then
					self:Load(path)
					loadedBanner.detail = path
				end
				FitSprite(self, DET_LEFT_W - 20, 110)
				self:visible(true)
			else
				self:visible(false)
			end
		end,
	}

	detail[#detail+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(16 + DET_LEFT_W/2, 178):zoom(0.85):maxwidth((DET_LEFT_W - 16)/0.85)
		end,
		SMORefreshMessageCommand = function(self)
			local pack = CurrentPack()
			self:settext(pack and pack.name or "")
		end,
	}

	-- The pack's facts as a table.
	--
	-- They were a stack of centred sentences, which gave every value a
	-- different width and the eye no column to run down: to compare two packs
	-- you had to read both. A label beside a value gives one edge for the
	-- labels and another for the values, so the same fact is in the same place
	-- for every pack and the pane can be skimmed rather than read.
	local TAB_X  = 30                     -- where the labels start
	local TAB_VX = TAB_X + 82             -- and where the values do
	local TAB_Y  = 194                    -- the top of the first row
	local TAB_H  = 15
	local TAB_W  = DET_LEFT_W - 2*(TAB_X - 16)
	local function TabY(row) return TAB_Y + (row - 0.5)*TAB_H end

	-- Every row is a label and a value, except the two that are drawn out of
	-- more than one piece: the difficulty, whose two ends are coloured
	-- separately, and the style, which is an icon and a word.
	local tabRows = {
		-- The song count, and how many of them are modfiles.
		--
		-- Not its own row: the table is eight rows deep already and the
		-- histogram starts where a ninth would land. It belongs here anyway --
		-- "97, 4 with mods" is one fact about what is in the pack, and the
		-- number it qualifies is right beside it.
		--
		-- The count comes from the archive rather than from any matching, so it
		-- is exact even where a song's folder was named something its title
		-- would never suggest.
		{ "Songs", function(pack)
			local text = Commify(pack.songs or 0)
			local mods = LO.ModsOf(pack)
			if mods and (tonumber(mods.count) or 0) > 0 then
				text = text .. ", " .. Commify(mods.count) .. " with mods"
			end
			return text end },
		-- A value that never arrived shows a dash rather than an empty cell: an
		-- empty cell reads as a fact about the pack ("no charts"), and a dash
		-- reads as what it is -- nothing was learned. The header line above
		-- carries the why and the key that retries.
		{ "Charts", function(pack, det)
			if det and det.stats.charts then
				return Commify(tonumber(det.stats.charts) or det.stats.charts)
			end
			return LO.DetailLost(pack) and "--" or "" end,
			function(pack, det) return det == nil and LO.DetailPending(pack) end },
		{ "Size", function(pack) return pack.sizeStr or "" end },
		{ "Difficulty" },
		{ "Style" },
		-- What sync this pack will play at, and who decided.
		--
		-- SMO carries a sync tag for some packs and "n/a" for the rest, and the
		-- rest is most of the older catalogue -- Pack.ini did not exist when
		-- they were made. A blank row said nothing at all about those, when the
		-- true answer is that nothing declares a sync so the machine settles it,
		-- and the machine is a per-install preference that another player will
		-- have set differently. So the row says which of the two happened, and
		-- when it is the machine it reads that preference rather than assuming
		-- the default.
		{ "Sync", function(pack, det)
			-- asking is free after the first time, and the answer replaces
			-- the catalogue's guess when it lands
			LO.PackIniAsk(pack)
			return LO.SyncLine(pack, det) end,
			-- This one already says something -- what the catalogue thinks --
			-- while the download itself is being read. The spinner sits after
			-- that rather than instead of it, because the line is about to get
			-- better rather than about to appear.
			function(pack)
				local read = pack and state.packIni and state.packIni[pack.id]
				return read ~= nil and read.status == "asking"
			end },
		{ "Added", function(pack, det)
			local date = FormatDate(pack.date)
			if date == "" and det then date = det.date or "" end
			if date == "" and LO.DetailLost(pack) then return "--" end
			return date end,
			-- the catalogue carries no date for the keyboard rows, so those
			-- wait on the pack page like the rest
			function(pack, det)
				return FormatDate(pack.date) == "" and det == nil
					and LO.DetailPending(pack)
			end },
		{ "Charts by", function(pack, det)
			if det and det.credits and #det.credits > 0 then
				local names = det.credits
				-- "and more" only when there were more: the parser counts what
				-- it found, so this is a fact rather than a hedge
				local shown = math.min(2, #names)
				local text = table.concat({ names[1], names[2] }, ", ", 1, shown)
				if (det.creditCount or #names) > shown then
					text = text .. " and more"
				end
				return text
			end
			return LO.DetailLost(pack) and "--" or "" end,
			function(pack, det) return det == nil and LO.DetailPending(pack) end },
	}

	for rowIndex, row in ipairs(tabRows) do
		-- a band behind alternate rows, faint enough to be a guide and not a
		-- stripe: it is what makes a label and its value read as one line
		if rowIndex % 2 == 1 then
			detail[#detail+1] = Def.Quad{
				InitCommand = function(self)
					self:vertalign(top):horizalign(left)
					self:xy(TAB_X - 6, TAB_Y + (rowIndex-1)*TAB_H)
					self:setsize(TAB_W, TAB_H):diffuse(1, 1, 1, 0.035)
				end,
			}
		end

		detail[#detail+1] = Def.BitmapText{
			Font = "Common Normal",
			Text = row[1],
			InitCommand = function(self)
				self:horizalign(left):xy(TAB_X, TabY(rowIndex)):zoom(0.46)
				self:diffuse(0.52, 0.52, 0.52, 1):maxwidth((TAB_VX - TAB_X - 6)/0.46)
			end,
		}

		if row[2] then
			-- The value and the wheel that waits beside it, in one command.
			--
			-- The wheel sits AFTER whatever the row managed to say, so it has
			-- to know how wide that came out, and only the text can measure the
			-- text. It used to ask the sibling for that width directly, which
			-- meant it was reading whatever the LAST pack's line had come out
			-- as: a broadcast reaches every actor separately, in no order this
			-- code can rely on. So the frame sets the text, measures it, and
			-- places the wheel from that measurement, all in the one pass.
			local rowFrame = Def.ActorFrame{
				SMORefreshMessageCommand = function(self) self:playcommand("SMORow") end,
				SMOBannerReadyMessageCommand = function(self) self:playcommand("SMORow") end,
				SMORowCommand = function(self)
					local value = self:GetChild("Value")
					local wheel = self:GetChild("Wheel")
					local pack  = CurrentPack()

					value:settext(pack and (row[2](pack, state.details[pack.id]) or "") or "")

					if not wheel then return end
					-- After the text, not instead of it: a row that already says
					-- something provisional keeps saying it while the better
					-- answer is fetched.
					local wide = value:GetZoomedWidth()
					local waiting = LO.DetailShowing() and pack ~= nil
						and row[3](pack, state.details[pack.id]) == true
					SpinnerSet(wheel,
						TAB_VX + wide + (wide > 0 and 9 or 2), TabY(rowIndex),
						waiting)
				end,

				Def.BitmapText{
					Name = "Value",
					Font = "Common Normal",
					InitCommand = function(self)
						self:horizalign(left):xy(TAB_VX, TabY(rowIndex)):zoom(0.5)
						self:diffuse(0.86, 0.86, 0.86, 1)
						self:maxwidth((TAB_W - (TAB_VX - TAB_X) - 4)/0.5)
					end,
				},
			}
			if row[3] then rowFrame[#rowFrame+1] = SpinnerChild("Wheel", 0.075) end
			detail[#detail+1] = rowFrame
		end
	end

	-- The difficulty row: both ends carry their own colour, because the pair is
	-- the whole point. "11 - 20" in one colour says how wide the pack is; the
	-- ends coloured say what it is like at each of them, which is the thing
	-- somebody deciding whether to download it is actually after.
	-- Laid out from the width of the number to its left rather than from fixed
	-- offsets. A range is two numbers and a dash and should read as one thing;
	-- spacing it for two digits left "7 - 12" with a hole either side of the
	-- dash, and spacing it for one crowded "11 - 20".
	-- All three in one command, because the dash and the high number are
	-- placed from how wide the LOW number came out, and only the low number
	-- can measure itself. Asking it from a sibling laid the range out against
	-- the previous pack's digits -- "7 - 12" spaced for two, "11 - 20" spaced
	-- for one -- and left it that way, because redraw is event driven.
	detail[#detail+1] = Def.ActorFrame{
		SMORefreshMessageCommand = function(self)
			local lowT  = self:GetChild("Low")
			local dashT = self:GetChild("Dash")
			local highT = self:GetChild("High")

			local pack = CurrentPack()
			local low, high = LO.PackSpan(pack and state.details[pack.id])

			-- the low number first: the other two are placed from its width
			if low == nil and pack and LO.DetailLost(pack) then
				-- with nothing learned this row says so, like the others; the
				-- dash and the high number stay hidden, so it reads as one dash
				-- rather than as a range with holes in it
				lowT:visible(true)
				lowT:settext("--")
				lowT:diffuse(0.55, 0.55, 0.55, 1)
			elseif low then
				lowT:visible(true)
				lowT:settext(tostring(low))
				lowT:diffuse(MeterColor(low, 1))
			else
				lowT:visible(false)
			end

			-- A range needs both ends. Either one alone is a number, and a
			-- dash with nothing after it is not a range -- it is a loose dash.
			local show = low ~= nil and high ~= nil and low ~= high
			dashT:visible(show)
			highT:visible(show)
			if not show then return end

			local x = TAB_VX + lowT:GetZoomedWidth() + 4
			dashT:x(x)
			highT:x(x + dashT:GetZoomedWidth() + 4)
			highT:settext(tostring(high))
			highT:diffuse(MeterColor(high, 1))
		end,

		Def.BitmapText{
			Name = "Low",
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(left):xy(TAB_VX, TabY(4)):zoom(0.5)
			end,
		},
		Def.BitmapText{
			Name = "Dash",
			Font = "Common Normal",
			Text = "-",
			InitCommand = function(self)
				self:horizalign(left):xy(TAB_VX + 14, TabY(4)):zoom(0.5)
				self:diffuse(0.5, 0.5, 0.5, 1)
				self:visible(false)
			end,
		},
		Def.BitmapText{
			Name = "High",
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(left):xy(TAB_VX + 26, TabY(4)):zoom(0.5)
				self:visible(false)
			end,
		},
	}

	-- The difficulty span comes off the pack page like the chart count, so it
	-- waits the same way and says so in the same place.
	detail[#detail+1] = Spinner(TAB_VX + 2, TabY(4), 0.075, function()
		local pack = LO.DetailShowing() and CurrentPack() or nil
		if not pack then return false end
		return state.details[pack.id] == nil and LO.DetailPending(pack)
	end)

	-- The style row: the icon for what the pack is, and the word for it.
	-- A pack that is both gets both icons, in the order the words are in, so
	-- the icons and the phrase beside them read the same way round.
	for _, kind in ipairs({ "pad", "doubles", "keyboard" }) do
		local iconName = LO.ICONS .. kind .. ".png"
		if FILEMAN:DoesFileExist(iconName) then
			detail[#detail+1] = Def.Sprite{
				Texture = iconName,
				InitCommand = function(self)
					self:xy(TAB_VX, TabY(5)):zoom(LO.IconZoom(kind, 13/96))
					self:visible(false)
				end,
				SMORefreshMessageCommand = function(self)
					local icon = LO.StyleOf(CurrentPack())
					local both = (icon == "both")
					local mine = (icon == kind)
						or (both and (kind == "pad" or kind == "doubles"))
					self:visible(LO.DetailShowing() and mine)
					if not mine then return end
					-- laid out from each icon's own width, since the doubles
					-- one is twice as wide as the others
					local at = TAB_VX + 2
					if both and kind == "doubles" then
						at = at + LO.IconWide("pad", 13/96) + 4
					end
					self:x(at + LO.IconWide(kind, 13/96)/2)
					self:diffuse(0.82, 0.82, 0.82, 1)
				end,
			}
		end
	end
	detail[#detail+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(left):xy(TAB_VX + 18, TabY(5)):zoom(0.5)
			self:diffuse(0.86, 0.86, 0.86, 1)
		end,
		SMORefreshMessageCommand = function(self)
			local icon, word = LO.StyleOf(CurrentPack())
			self:settext(word or "")
			local used = LO.IconWide(icon == "both" and "pad" or icon, 13/96)
			if icon == "both" then
				used = used + 4 + LO.IconWide("doubles", 13/96)
			end
			local left = TAB_VX + 2 + used + 6
			self:x(left)
			self:maxwidth((TAB_W - (left - TAB_X) - 4)/0.5)
		end,
	}

	-- What the download is doing, under the table rather than in it: it is the
	-- one line here that is about this moment rather than about the pack.
	detail[#detail+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(16 + DET_LEFT_W/2, TAB_Y + #tabRows*TAB_H + 12):zoom(0.5)
			self:maxwidth((DET_LEFT_W - 16)/0.5)
		end,
		SMORefreshMessageCommand = function(self)
			local pack = CurrentPack()
			if not pack then self:settext("") return end
			local dl = state.downloads[pack.id]
			local text = ""
			if dl then
				if dl.status == "active" then
					local pct = 0
					if dl.total > 0 then pct = math.floor(dl.cur / dl.total * 100) end
					text = "downloading  " .. pct .. "%   ("
						.. FormatBytes(dl.cur) .. " / " .. FormatBytes(dl.total) .. ")"
				elseif dl.status == "installing" then
					text = "installing..."
				elseif dl.status == "done" then
					text = "installed"
					if dl.groups and #dl.groups > 0 then
						text = text .. ": " .. table.concat(dl.groups, ", ")
					end
					text = text .. (DownloadLoaded(dl) and "  (in your library)"
						or "  (reload songs to play)")
				else
					text = "download failed: " .. tostring(dl.msg)
				end
			elseif SONGMAN:DoesSongGroupExist(pack.name) then
				text = "already in your library"
			end
			self:settext(text)
			if dl and dl.status == "error" then
				self:diffuse(1, 0.45, 0.45, 1)
			elseif dl and dl.status == "done" then
				self:diffuse(0.45, 1, 0.45, 1)
			else
				self:diffuse(0.78, 0.78, 0.78, 1)
			end
		end,
	}

	-- download progress bar
	detail[#detail+1] = Def.Quad{
		InitCommand = function(self)
			self:vertalign(top):horizalign(left)
			self:xy(28, 330):setsize(DET_LEFT_W - 24, 5):diffuse(1, 1, 1, 0.12)
		end,
		SMORefreshMessageCommand = function(self)
			local pack = CurrentPack()
			local dl = pack and state.downloads[pack.id]
			self:visible(dl ~= nil and (dl.status == "active" or dl.status == "installing"))
		end,
	}
	detail[#detail+1] = Def.Quad{
		InitCommand = function(self)
			self:vertalign(top):horizalign(left)
			self:xy(28, 330):setsize(0, 5)
		end,
		SMORefreshMessageCommand = function(self)
			local pack = CurrentPack()
			local dl = pack and state.downloads[pack.id]
			if dl and (dl.status == "active" or dl.status == "installing") then
				local fraction = 0
				if dl.status == "installing" then
					fraction = 1
				elseif dl.total > 0 then
					fraction = Clamp(dl.cur / dl.total, 0, 1)
				end
				self:visible(true)
				self:setsize((DET_LEFT_W - 24) * fraction, 5)
				self:diffuse(AccentColor())
			else
				self:visible(false)
			end
		end,
	}

	-- big histogram at the bottom of the left column
	local BHIST_H = 80
	local BHIST_Y = 420
	local BHIST_W = DET_LEFT_W - 24

	for barIndex = 1, HIST_MAX_BARS do
		detail[#detail+1] = Def.Quad{
			InitCommand = function(self) self:vertalign(bottom):visible(false) end,
			SMORefreshMessageCommand = function(self)
				local pack = CurrentPack()
				local det = pack and state.details[pack.id]
				if not (LO.DetailShowing() and det and #det.counts > 0 and barIndex <= #det.counts) then
					self:visible(false)
					return
				end
				local maxCount = 1
				for count in ivalues(det.counts) do maxCount = math.max(maxCount, count) end
				local barW = math.max(2, math.floor(BHIST_W / #det.counts) - 2)
				local x0 = 28 + (BHIST_W - (#det.counts * (barW + 2))) / 2
				self:visible(true)
				self:horizalign(left)
				self:xy(x0 + (barIndex-1)*(barW+2), BHIST_Y)
				self:setsize(barW, math.max(2, det.counts[barIndex] / maxCount * BHIST_H))
				self:diffuse(MeterColor(det.labels[barIndex], 0.95))
			end,
		}
	end

	-- colour chip + meter number beneath each bar
	for barIndex = 1, HIST_MAX_BARS do
		detail[#detail+1] = Def.Quad{
			InitCommand = function(self) self:vertalign(top):horizalign(left):visible(false) end,
			SMORefreshMessageCommand = function(self)
				local pack = CurrentPack()
				local det = pack and state.details[pack.id]
				if not (LO.DetailShowing() and det and #det.counts > 0 and barIndex <= #det.counts) then
					self:visible(false)
					return
				end
				local barW = math.max(2, math.floor(BHIST_W / #det.counts) - 2)
				local x0 = 28 + (BHIST_W - (#det.counts * (barW + 2))) / 2
				self:visible(true)
				self:xy(x0 + (barIndex-1)*(barW+2), BHIST_Y + 3):setsize(barW, 3)
				self:diffuse(MeterColor(det.labels[barIndex], 1))
			end,
		}

		detail[#detail+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self) self:zoom(0.34):visible(false) end,
			SMORefreshMessageCommand = function(self)
				local pack = CurrentPack()
				local det = pack and state.details[pack.id]
				if not (LO.DetailShowing() and det and #det.counts > 0 and barIndex <= #det.counts) then
					self:visible(false)
					return
				end
				local barW = math.max(2, math.floor(BHIST_W / #det.counts) - 2)
				-- below about 9px the numbers collide, so let the chips speak
				if barW < 9 then self:visible(false) return end
				local x0 = 28 + (BHIST_W - (#det.counts * (barW + 2))) / 2
				self:visible(true)
				self:xy(x0 + (barIndex-1)*(barW+2) + barW/2, BHIST_Y + 12)
				self:settext(tostring(det.labels[barIndex] or ""))
				self:diffuse(MeterColor(det.labels[barIndex], 1))
			end,
		}
	end

	detail[#detail+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(16 + DET_LEFT_W/2, BHIST_Y + 24):zoom(0.5):diffuse(0.6, 0.6, 0.6, 1)
		end,
		SMORefreshMessageCommand = function(self)
			local pack = CurrentPack()
			local det = pack and state.details[pack.id]
			if LO.DetailShowing() and det and #det.labels > 0 then
				self:settext("charts per difficulty  (" .. det.labels[1] .. " - " .. det.labels[#det.labels] .. ")")
			else
				self:settext("")
			end
		end,
	}

	-- Download the whole pack: the reason most people opened this page, so it
	-- is at the top of it rather than three presses down a popup. It shares
	-- the header line with the song count, which costs the song list no rows.
	local DL_BTN_W = 208
	local DL_BTN_H = 21
	local DL_BTN_X = DET_SONGS_X + DET_SONGS_W - DL_BTN_W
	local DL_BTN_Y = SONG_TOP - 14

	-- what the button says, and whether pressing it would do anything
	local function DownloadLabel()
		local pack = CurrentPack()
		if not pack then return "", false end
		local dl = state.downloads[pack.id]
		if dl then
			if dl.status == "active" then
				local pct = (dl.total > 0) and math.floor(dl.cur / dl.total * 100) or 0
				return "DOWNLOADING   " .. pct .. "%", false
			elseif dl.status == "installing" then
				return "INSTALLING...", false
			elseif dl.status == "done" then
				return DownloadLoaded(dl) and "IN YOUR LIBRARY"
					or "INSTALLED - RELOAD SONGS", false
			end
		end
		if SONGMAN:DoesSongGroupExist(pack.name) then
			return "IN YOUR LIBRARY", false
		end
		local size = (pack.sizeStr ~= "") and ("   " .. pack.sizeStr) or ""
		return "DOWNLOAD PACK" .. size, true
	end

	detail[#detail+1] = Def.Quad{
		InitCommand = function(self)
			self:vertalign(top):horizalign(left)
			self:xy(DL_BTN_X, DL_BTN_Y - DL_BTN_H/2):setsize(DL_BTN_W, DL_BTN_H)
		end,
		SMORefreshMessageCommand = function(self)
			local label, armed = DownloadLabel()
			self:visible(LO.DetailShowing() and label ~= "")
			if state.detailZone == "download" then
				self:diffuse(AccentColor()):diffusealpha(armed and 0.85 or 0.45)
			else
				self:diffuse(1, 1, 1, armed and 0.14 or 0.07)
			end
		end,
	}
	-- a lit edge, so it reads as a control rather than as a coloured strip
	detail[#detail+1] = Def.Quad{
		InitCommand = function(self)
			self:vertalign(top):horizalign(left)
			self:xy(DL_BTN_X, DL_BTN_Y - DL_BTN_H/2):setsize(DL_BTN_W, 1)
		end,
		SMORefreshMessageCommand = function(self)
			local label = DownloadLabel()
			self:visible(LO.DetailShowing() and label ~= ""
				and state.detailZone ~= "download")
			self:diffuse(1, 1, 1, 0.22)
		end,
	}
	detail[#detail+1] = Def.Quad{
		InitCommand = function(self)
			self:vertalign(top):horizalign(left)
			self:xy(DL_BTN_X, DL_BTN_Y + DL_BTN_H/2 - 1):setsize(DL_BTN_W, 1)
		end,
		SMORefreshMessageCommand = function(self)
			local label = DownloadLabel()
			self:visible(LO.DetailShowing() and label ~= ""
				and state.detailZone ~= "download")
			self:diffuse(1, 1, 1, 0.22)
		end,
	}

	if FILEMAN:DoesFileExist(LO.ICONS .. "download.png") then
		detail[#detail+1] = Def.Sprite{
			Texture = LO.ICONS .. "download.png",
			InitCommand = function(self)
				self:xy(DL_BTN_X + 16, DL_BTN_Y):zoom(13/96)
			end,
			SMORefreshMessageCommand = function(self)
				local label, armed = DownloadLabel()
				self:visible(LO.DetailShowing() and label ~= "")
				if state.detailZone == "download" then
					self:diffuse(0.08, 0.08, 0.08, 1)
				else
					self:diffuse(1, 1, 1, armed and 0.85 or 0.4)
				end
			end,
		}
	end

	detail[#detail+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(left):xy(DL_BTN_X + 30, DL_BTN_Y):zoom(0.5)
			self:maxwidth((DL_BTN_W - 40)/0.5)
		end,
		SMORefreshMessageCommand = function(self)
			local label, armed = DownloadLabel()
			self:settext(LO.DetailShowing() and label or "")
			if state.detailZone == "download" then
				self:diffuse(0.08, 0.08, 0.08, 1)
			else
				self:diffuse(1, 1, 1, armed and 0.9 or 0.45)
			end
		end,
	}

	-- right column: song list
	detail[#detail+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(left):xy(DET_SONGS_X, SONG_TOP - 14):zoom(0.6):diffuse(0.7, 0.7, 0.7, 1)
			-- the button shares this line, so the count stops before it
			self:maxwidth((DET_SONGS_W - DL_BTN_W - 16)/0.6)
		end,
		SMORefreshMessageCommand = function(self)
			local pack = CurrentPack()
			local det = pack and state.details[pack.id]
			if det then
				-- the highlighted song rather than the visible range: the range
				-- stopped being the interesting number once one song was picked
				local at = Clamp(state.songPick, 1, math.max(1, #det.songs))
				local note = Snd.Label()
				self:settext("Songs  " .. at .. " of " .. #det.songs
					.. (note and ("   -   " .. note) or ""))
			elseif pack and LO.DetailPending(pack) then
				self:settext("Loading song list...")
			elseif pack and LO.DetailLost(pack) then
				self:settext("Could not load this pack's song list   -   "
					.. "&SELECT; to try again")
			else
				self:settext("")
			end
		end,
	}

	-- ---------------------------------------------------------------
	-- the sample: an equalizer while it plays, a bar while it is fetched.
	--
	-- Both sit at the right-hand end of the song-list header, and both are
	-- driven by one actor ticking on its own rather than by the screen refresh.
	-- Refreshing the whole browser thirty times a second to move a dozen quads
	-- is exactly the cost this module keeps working to avoid.
	-- The bank sits to the left of the row's meter numbers, and the row it sits
	-- in is whichever one is highlighted -- so both of these are positioned by
	-- the pump every frame rather than pinned at build time.
	local EQ_SPAN  = Snd.BARS * (Snd.BAR_W + Snd.BAR_GAP) - Snd.BAR_GAP
	-- clear of the style icons and the meter, which share the right end of a
	-- row with it; the bars used to run straight through both
	local EQ_RIGHT = DET_SONGS_X + DET_SONGS_W - 92

	-- where the playing song's row is, and whether it is still on screen.
	-- Scrolling it out of view takes the bars with it rather than leaving them
	-- behind on a song that is not making any sound.
	function Snd.PickY()
		if not Snd.index then return nil end
		local n = Snd.index - state.songCursor
		if n < 1 or n > SONG_ROWS then return nil end
		return SONG_TOP + (n - 1) * SONG_ROW_H + (SONG_ROW_H - 4)/2
	end

	for i = 1, Snd.BARS do
		detail[#detail+1] = Def.Quad{
			InitCommand = function(self)
				Snd.bars[i] = self
				self:horizalign(left):vertalign(bottom)
				self:x(EQ_RIGHT - EQ_SPAN + (i-1)*(Snd.BAR_W + Snd.BAR_GAP))
				self:setsize(Snd.BAR_W, 2):visible(false)
			end,
		}
	end

	detail[#detail+1] = Def.Quad{
		InitCommand = function(self)
			Snd.pbTrack = self
			Snd.pbX = EQ_RIGHT - Snd.PROG_W
			self:horizalign(left):vertalign(bottom)
			self:x(Snd.pbX):setsize(Snd.PROG_W, 5)
			self:visible(false):diffuse(1, 1, 1, 0.16)
		end,
	}
	detail[#detail+1] = Def.Quad{
		InitCommand = function(self)
			Snd.pbFill = self
			self:horizalign(left):vertalign(bottom)
			self:x(Snd.pbX):setsize(1, 5):visible(false)
		end,
	}

	detail[#detail+1] = Def.Actor{
		InitCommand = function(self) self:queuecommand("SMOSamplePump") end,
		SMOSamplePumpCommand = function(self)
			local showing = state.open and LO.DetailShowing()
			local playing = showing and Snd.status == "playing"
			local loading = showing and Snd.status == "loading"
			local now = GetTimeSinceStart()

			-- the row being talked about, and whether it is scrolled into view
			local rowY = Snd.PickY()
			playing = playing and rowY ~= nil
			loading = loading and rowY ~= nil

			-- once per frame, not once per bar: this runs thirty times a second
			local accent = (playing or loading) and AccentColor() or nil

			for i = 1, Snd.BARS do
				local bar = Snd.bars[i]
				if bar then
					bar:visible(playing)
					if playing then
						local hgt = Snd.BarHeight(i, now)
						bar:y(rowY + 9)
						bar:setsize(Snd.BAR_W, hgt)
						bar:diffuse(accent)
						bar:diffusealpha(0.30 + 0.70 * (hgt / Snd.BAR_H))
					end
				end
			end

			if Snd.pbTrack then
				Snd.pbTrack:visible(loading)
				if loading then Snd.pbTrack:y(rowY + 6) end
			end
			if Snd.pbFill then
				Snd.pbFill:visible(loading)
				if loading then
					local _, frac = Snd.ProgLabel()
					Snd.pbFill:y(rowY + 6)
					Snd.pbFill:diffuse(accent)
					if frac and frac >= 0 then
						Snd.pbFill:x(Snd.pbX or 0)
						Snd.pbFill:setsize(math.max(1, Snd.PROG_W * frac), 5)
					else
						-- nothing measurable yet, so a block that travels
						-- rather than a bar that would be inventing a number
						local w = Snd.PROG_W * 0.3
						local at = (now * 0.7) % 2
						if at > 1 then at = 2 - at end
						Snd.pbFill:setsize(w, 5)
						Snd.pbFill:x((Snd.pbX or 0) + at * (Snd.PROG_W - w))
					end
				end
			end

			-- The sample stops itself; nothing else would notice that it had.
			--
			-- Asked of Snd, not of the row: "playing" was narrowed twice above,
			-- once by the detail page being on screen and once by the playing
			-- row still being inside the eight-row window. Scrolling that row
			-- out of view therefore used to leave the status pinned at
			-- "playing" for ever -- silent audio, a chart window that would not
			-- go away, and Up and Down captured by a preview that had ended.
			if Snd.status == "playing" and Snd.len > 0
			   and (now - Snd.startedAt) > (Snd.len + 1.6) then
				Snd.Stop()
			end

			-- Thirty times a second only while there is something to animate --
			-- the loading bar's sweep, the header equalizer. The engine gates
			-- Draw on visibility but never Update, so before this the pump
			-- cost its full rate on every screen including gameplay, forever.
			-- Idle, four ticks a second still catches a sample starting and
			-- still runs the stuck-status watchdog above, whose patience is
			-- measured in whole seconds.
			self:sleep((playing or loading) and 1/30 or 0.25)
			self:queuecommand("SMOSamplePump")
		end,
	}

	for i = 1, SONG_ROWS do
		local ROW_H = SONG_ROW_H - 4

		-- the song this row owns for the current window: the one in view whose
		-- index leaves remainder i-1 when divided by the number of rows
		local function SongNumber()
			local c = state.songCursor
			return c + 1 + ((i - 1 - (c + 1)) % SONG_ROWS)
		end
		local function RowY()
			return SONG_TOP + (SongNumber() - state.songCursor - 1) * SONG_ROW_H
		end

		local function SongAt()
			local pack = CurrentPack()
			local det = pack and state.details[pack.id]
			return det and det.songs[SongNumber()] or nil
		end

		detail[#detail+1] = Def.Quad{
			InitCommand = function(self)
				self:vertalign(top):horizalign(left)
				self:xy(DET_SONGS_X - 6, RowY()):setsize(DET_SONGS_W + 12, ROW_H)
			end,
			SMORefreshMessageCommand = function(self)
				self:y(RowY())
				if SongNumber() == state.songPick then
					-- the song a preview would play; dimmer while the cursor
					-- is on the button, so only one thing looks focused
					self:diffuse(AccentColor())
					self:diffusealpha(state.detailZone == "download" and 0.13 or 0.30)
				else
					-- banded by position rather than by row, so the stripes
					-- stay put while the rows move through them
					local band = (SongNumber() - state.songCursor) % 2
					self:diffuse(0, 0, 0, (band == 0) and 0.34 or 0.52)
				end
				self:visible(LO.DetailShowing() and SongAt() ~= nil)
			end,
		}

		-- Art: SMO gives a song its own jacket where it has one and the pack
		-- banner where it does not, so the box is banner-shaped and the frame
		-- takes whatever shape the image actually fits to.  Wider rather than
		-- taller, so the rows stay the height they were.
		local ART_W = 104
		local ART_H = ROW_H - 8
		local ART_X = DET_SONGS_X + 4 + ART_W/2
		local function ART_Y() return RowY() + ROW_H/2 end
		local TEXT_X = DET_SONGS_X + ART_W + 16
		-- the right end of the row now carries the style icons as well as the
		-- meter, so the text stops sooner
		local TEXT_W = DET_SONGS_W - (ART_W + 16) - 92

		-- Art, its lit border and its dark backing, as ONE actor.
		--
		-- They were three siblings: the border and the backing read the size
		-- the sprite had measured on some earlier pass, so whenever an image
		-- arrived before the sprite had measured it they sized themselves from
		-- the square fallback, and a wide banner ended up sitting on a green
		-- square that then stayed, because redraw is event driven.
		--
		-- And "before" was not even reliably "before": an ActorFrame does not
		-- hand a broadcast down to its children (ActorFrame.cpp refuses to
		-- propagate one), so every actor subscribes to MESSAGEMAN separately
		-- and is served out of a set keyed on its own POINTER. Sibling handlers
		-- therefore run in heap-address order -- no order at all, from here.
		--
		-- Now the parent does the whole job in one command: load, fit, measure,
		-- then size the two quads from that measurement. The children have no
		-- commands of their own, so the order they run in cannot matter. They
		-- are still added border-backing-sprite, because that IS defined --
		-- children draw in the order they were added, whatever order their
		-- handlers would have run in.
		--
		-- The rule this is an instance of: whatever an actor measures, that
		-- same actor publishes to everything that depends on it. Never leave a
		-- measurement lying in a shared table for a sibling to pick up.
		detail[#detail+1] = Def.ActorFrame{
			InitCommand = function(self) self:xy(ART_X, ART_Y()) end,
			SMORefreshMessageCommand = function(self) self:playcommand("SMOArt") end,
			SMOBannerReadyMessageCommand = function(self) self:playcommand("SMOArt") end,
			SMOArtCommand = function(self)
				self:y(ART_Y())

				local border = self:GetChild("Border")
				local back   = self:GetChild("Back")
				local art    = self:GetChild("Art")

				local song = LO.DetailShowing() and SongAt() or nil
				local url  = song and song.image
				local path = url and state.banners[url]
				local key  = "song" .. i

				-- What the sprite ended up being, or nil when there is nothing
				-- to show. The two quads follow this and nothing else.
				local w, h

				if path then
					if loadedBanner[key] ~= path then
						art:Load(path)
						loadedBanner[key] = path
					end
					FitSprite(art, ART_W, ART_H)
					art:diffuse(1, 1, 1, 1)
					art:visible(true)
					w, h = art:GetZoomedWidth(), art:GetZoomedHeight()
				elseif url and not state.bannerFailed[url] then
					-- on its way in; the spinner below says so
					art:visible(false)
					RequestBanner(url)
				elseif SongAt() then
					LO.ShowNoBanner(art, key, loadedBanner, ART_W, ART_H)
					if art:GetVisible() then
						w, h = art:GetZoomedWidth(), art:GetZoomedHeight()
					end
				else
					art:visible(false)
				end

				songArt[i] = (w and h and w > 0 and h > 0) and { w = w, h = h } or nil

				-- An empty lit square around a spinner reads as a broken image
				-- rather than as one still arriving, so with nothing measured
				-- the frame stays out of the way entirely.
				local show = songArt[i] ~= nil
				border:visible(show)
				back:visible(show)
				if show then
					border:setsize(w + 4, h + 4)
					border:diffuse(AccentColor()):diffusealpha(0.4)
					back:setsize(w, h)
					back:diffuse(0.10, 0.10, 0.10, 1)
				end
			end,

			-- added in drawing order: border behind backing behind art
			Def.Quad{ Name = "Border",
				InitCommand = function(self) self:visible(false) end },
			Def.Quad{ Name = "Back",
				InitCommand = function(self) self:visible(false) end },
			Def.Sprite{ Name = "Art",
				InitCommand = function(self) self:visible(false) end },
		}

		-- spinner while a jacket is on its way in
		detail[#detail+1] = Spinner(ART_X, ART_Y, 0.11, function()
			local song = LO.DetailShowing() and SongAt() or nil
			if not song or not song.image then return false end
			-- a known-failed image collapses to the placeholder instead of
			-- spinning for the whole retry window
			if state.bannerFailed[song.image] then return false end
			return state.banners[song.image] == nil
		end)

		-- title: the largest thing in the row
		detail[#detail+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(left):xy(TEXT_X, RowY() + 15):zoom(0.66)
				self:maxwidth(TEXT_W/0.66)
			end,
			SMORefreshMessageCommand = function(self)
				local song = LO.DetailShowing() and SongAt() or nil
				self:y(RowY() + 15)
				self:settext(song and song.title or "")
				self:diffuse(1, 1, 1, 1)
			end,
		}

		detail[#detail+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(left):xy(TEXT_X, RowY() + 30):zoom(0.42):diffuse(0.58, 0.58, 0.58, 1)
				self:maxwidth(TEXT_W/0.42)
			end,
			SMORefreshMessageCommand = function(self)
				local song = LO.DetailShowing() and SongAt() or nil
				self:y(RowY() + 30)
				if not song then self:settext("") return end
				local bits = {}
				if song.artist ~= "" then bits[#bits+1] = song.artist end
				if song.bpm ~= "" then bits[#bits+1] = song.bpm .. " bpm" end
				if song.length ~= "" then bits[#bits+1] = song.length end
				if song.credit ~= "" then bits[#bits+1] = song.credit end
				self:settext(table.concat(bits, "  -  "))
			end,
		}

		-- There is no per-song style icon here any more.
		--
		-- There was one for singles and one for doubles, and they appeared on
		-- every song of every pack, because the column they were read from is
		-- the page's mode filter rather than a description of the song. Two
		-- icons that are always both lit say nothing; the meter beside them is
		-- real, so that is what the row shows.

		-- Lua on the row, under the meter.
		--
		-- A modfile is a chart that brings its own Lua and runs it during play,
		-- and it is the one thing about a song that decides whether somebody
		-- wants it before they have heard a note of it -- some players come to
		-- a pack for these and some want none of them. Nothing in the catalogue
		-- says so; the archive does, and only the archive.
		--
		-- Under the meter rather than beside the title: it is a fact about the
		-- chart like the meter is, the column is otherwise the row\x27s own, and
		-- a title at full width has nowhere to put it.
		detail[#detail+1] = Def.BitmapText{
			Font = "Common Normal",
			Text = "MODS",
			InitCommand = function(self)
				self:horizalign(right):xy(DET_SONGS_X + DET_SONGS_W, RowY() + 35)
				self:zoom(0.32):diffuse(0.98, 0.72, 0.20, 1)
			end,
			SMORefreshMessageCommand = function(self)
				local pack = LO.DetailShowing() and CurrentPack() or nil
				self:y(RowY() + 35)
				self:visible(pack ~= nil and SongAt() ~= nil
					and LO.SongMods(pack, SongNumber()))
			end,
		}

		-- The song\x27s meter, tinted by the hardest chart in it. With the icons
		-- gone it has the end of the row to itself, so it is set a little
		-- larger: it is the one number on the row worth reading at a glance.
		detail[#detail+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(right):xy(DET_SONGS_X + DET_SONGS_W, ART_Y()):zoom(0.74)
			end,
			SMORefreshMessageCommand = function(self)
				local song = LO.DetailShowing() and SongAt() or nil
				self:y(ART_Y())
				if song and song.meters ~= "" then
					self:settext(song.meters)
					local top = 0
					for n in song.meters:gmatch("%d+") do top = math.max(top, tonumber(n)) end
					self:diffuse(MeterColor(top, 1))
				else
					self:settext("")
				end
			end,
		}
	end

	-- how far through the pack's song list you are
	detail[#detail+1] = ScrollBar(DET_SONGS_X + DET_SONGS_W + 8, SONG_TOP,
		SONG_ROWS*SONG_ROW_H - 8, false,
		function()
			if state.mode ~= "detail" then return nil end
			local pack = CurrentPack()
			local det = pack and state.details[pack.id]
			if not det then return nil end
			return #det.songs, SONG_ROWS, state.songCursor
		end)
	return detail
end
