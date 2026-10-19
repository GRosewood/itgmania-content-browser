-- -----------------------------------------------------------------------
-- The Rip Packs tab: the options, and the pack being opened
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local AccentColor   = CB.AccentColor
local Clamp         = CB.Clamp
local FormatBytes   = CB.FormatBytes
local LO            = CB.LO
local RELAY_OUT_WHY = CB.RELAY_OUT_WHY
local RIP           = CB.RIP
local ScrollBar     = CB.ScrollBar
local state         = CB.state

-- ---------------------------------------------------------------
-- Left, the options a rip is made with, one row each and the button under
-- them. Right, the stage: a booster pack that idles, shakes while the relay
-- looks for songs, tears open when they are found, and deals fifteen cards
-- face down, each turning over when its song is in.
--
-- Everything that moves is moved by one pump (Tick, at the bottom) from the
-- clock and what the rip says -- which phase, when it got there, which songs
-- are in -- so a card's place is always worked out, never remembered, and
-- leaving the tab and coming back finds the stage where it should be.

local PANEL_X, PANEL_W = 16, 292
local ROW_Y0, ROW_H    = 74, 42

local STAGE_X, STAGE_Y = 579, 246      -- the stage's centre
local PW, PH           = 150, 214      -- the pack
local CW, CH           = 96, 112       -- a card
local GRID_X0, GRID_Y0 = 325, 70       -- the deal's top-left
local GAP_X, GAP_Y     = 7, 8

local DEAL_AT, DEAL_EACH, DEAL_TIME = 0.5, 0.07, 0.35
local FLIP_AFTER, FLIP_TIME = 0.08, 0.32   -- a card turns over this soon after it lands

-- a card's face, top to bottom: the picture, the meter's badge on its lower
-- edge, the title and credit, the pack
local ART_H      = 40
local ART_Y      = -CH/2 + 2 + ART_H/2
local BADGE_Y    = -CH/2 + 2 + ART_H
local INFO_Y     = 22
local TITLE_ZOOM, CREDIT_ZOOM, YEAR_ZOOM = 0.42, 0.36, 0.34
local GOLD       = { 1.00, 0.80, 0.30 }

-- A song's BPM in the colour of how fast it plays -- slow under 140, medium
-- to 180, fast from there -- as the site's cards colour it; grey when the
-- chart hides its BPM. The medium is an orange well clear of the gold.
local function BpmColor(bpm)
	bpm = tonumber(bpm) or 0
	if bpm <= 0 then return { 0.6, 0.6, 0.63, 1 } end
	if bpm < 140 then return { 0.49, 0.83, 0.99, 1 } end
	if bpm < 180 then return { 0.98, 0.57, 0.24, 1 } end
	return { 0.98, 0.44, 0.52, 1 }
end

-- the sound of the pack tearing open, when it is there to play
local TEAR = LO.ICONS .. "tear.wav"
if not FILEMAN:DoesFileExist(TEAR) then TEAR = nil end

local function CardXY(i)
	local col = (i - 1) % 5
	local row = math.floor((i - 1) / 5)
	return GRID_X0 + CW/2 + col * (CW + GAP_X), GRID_Y0 + CH/2 + row * (CH + GAP_Y)
end

-- Fill a W x H window with a picture, cropping whatever overhangs it evenly
-- from both sides, so every card's picture is the same shape whatever the
-- banner's.
local function CoverSprite(sprite, W, H)
	local w, h = sprite:GetWidth(), sprite:GetHeight()
	if w <= 0 or h <= 0 then return end
	local z = math.max(W / w, H / h)
	sprite:zoom(z)
	local cx = (w * z - W) / (2 * w * z)
	local cy = (h * z - H) / (2 * h * z)
	sprite:cropleft(cx):cropright(cx):croptop(cy):cropbottom(cy)
end

-- Set wrapped text, taking words off the end until it fits in so many lines.
local function FitLines(text, s, lines)
	text:settext("A")
	local one = text:GetHeight()
	text:settext(s)
	if text:GetHeight() <= one * lines + 1 then return end
	local words = {}
	for word in s:gmatch("%S+") do words[#words+1] = word end
	for n = #words - 1, 1, -1 do
		text:settext(table.concat(words, " ", 1, n) .. "...")
		if text:GetHeight() <= one * lines + 1 then return end
	end
end

local function Ease(p) return 1 - (1 - p) * (1 - p) end
local function EaseBack(p)
	local s = 1.4
	p = p - 1
	return p * p * ((s + 1) * p + s) + 1
end

local function Showing()
	return state.open and not state.textEntryOpen and state.mode == "rip"
end

local function Pack() return state.rip.pack end
local function Song(i)
	local pack = Pack()
	return pack and pack.songs and pack.songs[i]
end

-- The pack's gold card: the one whose Expert is hardest, or each of those
-- tied for it while there are three or fewer. More than that and the top
-- meter is simply what the pack is made of, so no card is marked.
local function IsFoil(i)
	local pack, song = Pack(), Song(i)
	if not song or song.state == "failed" then return false end
	if pack.topOf ~= pack.songs then
		local hi, count = -1, 0
		for s in ivalues(pack.songs) do
			local m = tonumber(s.meter) or 0
			if m > hi then
				hi, count = m, 1
			elseif m == hi then
				count = count + 1
			end
		end
		pack.top, pack.topCount, pack.topOf = hi, count, pack.songs
	end
	return pack.topCount <= 3 and (tonumber(song.meter) or 0) == pack.top
end

-- What a row says its value is.
local function RowValue(key)
	local r = state.rip
	if key == "era" then
		local eras = RIP.ErasInOrder()
		if #eras == 0 then return "Any era  (START to choose)" end
		local names = {}
		for era in ivalues(eras) do names[#names+1] = RIP.ERA_SHORT[era] end
		return table.concat(names, ", ")
	elseif key == "author" then
		local n = #r.chosen
		if n == 1 then return r.chosen[1] end
		if n == 2 then return r.chosen[1] .. ", " .. r.chosen[2] end
		if n > 2 then return r.chosen[1] .. ", " .. r.chosen[2] .. "  +" .. (n - 2) .. " more" end
		if r.authorsStatus == "loading" then return "loading the list..." end
		if r.authorsStatus == "failed" then
			return r.authorsOut and "unavailable for now"
				or "list unavailable  (START to retry)"
		end
		return "Anyone  (START to choose)"
	elseif key == "typed" then
		return r.typed ~= "" and r.typed or "none  (START to type exact names)"
	elseif key == "avoid" then
		return r.avoid ~= "" and r.avoid or "nobody  (START to type exact names)"
	elseif key == "lo" then
		return tostring(r.lo)
	elseif key == "hi" then
		return tostring(r.hi)
	elseif key == "full" then
		return r.full and "Yes: Beginner to Challenge" or "No"
	end
	return ""
end

local ROW_LABEL = {
	era = "ERA", author = "AUTHOR", typed = "OR TYPE AUTHORS", avoid = "AVOID CHARTS BY",
	lo = "EXPERT FROM", hi = "EXPERT TO", full = "FULL DIFFICULTIES",
}
local CYCLES = { lo = true, hi = true, full = true }

function CB.Screen.RipPacks(ui)
	local A = { cards = {} }

	local root = Def.ActorFrame{
		Name = "RipPacks",
		InitCommand = function(self) self:visible(false) end,
		SMORefreshMessageCommand = function(self) self:visible(Showing()) end,
	}

	-- -------------------------------------------------------- the options

	for index, key in ipairs(RIP.ROWS) do
		local y = ROW_Y0 + (index - 1) * ROW_H
		if key == "rip" then
			y = y + 10
			local function Lit() return state.zone ~= "tabs" and state.rip.row == index end
			local function Choosing() return state.rip.phase == "choosing" end

			-- one button while there is nothing to choose: RIP A PACK, or what
			-- the rip is busy doing
			local single = Def.ActorFrame{
				SMORefreshMessageCommand = function(self) self:visible(not Choosing()) end,
			}
			single[#single+1] = Def.Quad{
				InitCommand = function(self)
					self:horizalign(left):xy(PANEL_X, y):setsize(PANEL_W, 34)
				end,
				SMORefreshMessageCommand = function(self)
					if RIP.Busy() then
						self:diffuse(0.18, 0.18, 0.18, 1)
					elseif Lit() then
						self:diffuse(AccentColor()):diffusealpha(1)
					else
						self:diffuse(AccentColor()):diffusealpha(0.32)
					end
				end,
			}
			-- while a kept pack comes in, the button fills with it: the songs
			-- in so far, and the one on its way as it grows on the disk
			single[#single+1] = Def.Quad{
				InitCommand = function(self)
					self:horizalign(left):xy(PANEL_X, y):setsize(0, 34):visible(false)
				end,
				SMORefreshMessageCommand = function(self)
					local pack = Pack()
					if state.rip.phase ~= "filling" or not pack then
						self:visible(false)
						return
					end
					local dl = state.downloads[pack.dlKey] or {}
					local frac = (pack.total or 0) > 0 and Clamp((dl.cur or 0) / pack.total, 0, 1) or 0
					self:visible(true):setsize(math.max(1, PANEL_W * frac), 34)
					self:diffuse(AccentColor()):diffusealpha(0.7)
				end,
			}
			-- the game's arrow, in its own colours whatever the button's
			single[#single+1] = Def.Sprite{
				Texture = LO.ICONS .. "itgmania.png",
				InitCommand = function(self) self:xy(PANEL_X + 22, y):zoom(24/192) end,
				SMORefreshMessageCommand = function(self)
					self:diffuse(1, 1, 1, RIP.Busy() and 0.45 or 1)
				end,
			}
			single[#single+1] = Def.BitmapText{
				Font = "Common Bold",
				InitCommand = function(self)
					self:horizalign(left):xy(PANEL_X + 40, y):zoom(0.42)
				end,
				SMORefreshMessageCommand = function(self)
					local phase, pack = state.rip.phase, Pack()
					if phase == "filling" and pack then
						self:settext(string.format("DOWNLOADING  %d / %d",
							pack.got + pack.failed, #pack.songs))
					else
						self:settext(phase == "searching" and "RIPPING..." or "RIP A PACK")
					end
					local dark = Lit() and not RIP.Busy()
					self:diffuse(dark and 0.08 or 1, dark and 0.08 or 1, dark and 0.08 or 1, 1)
				end,
			}
			root[#root+1] = single

			-- two while a pack is on the table: keep it, or throw it back
			-- and rip another
			local pair = Def.ActorFrame{
				SMORefreshMessageCommand = function(self) self:visible(Choosing()) end,
			}
			local HALF = (PANEL_W - 6) / 2
			for n, it in ipairs({
				{ choice = "keep",  label = "KEEP",   icon = "download.png", glyph = true },
				{ choice = "rerip", label = "RE-RIP", icon = "itgmania.png" },
			}) do
				local x0 = PANEL_X + (n - 1) * (HALF + 6)
				local function On() return Lit() and state.rip.choice == it.choice end
				pair[#pair+1] = Def.Quad{
					InitCommand = function(self)
						self:horizalign(left):xy(x0, y):setsize(HALF, 34)
					end,
					SMORefreshMessageCommand = function(self)
						self:diffuse(AccentColor()):diffusealpha(On() and 1 or 0.32)
					end,
				}
				pair[#pair+1] = Def.Sprite{
					Texture = LO.ICONS .. it.icon,
					InitCommand = function(self)
						self:xy(x0 + 22, y):zoom((it.glyph and 22/96) or 24/192)
					end,
					SMORefreshMessageCommand = function(self)
						-- the white glyph darkens on a lit button, as the label
						-- does; the arrow keeps its own colours
						local dark = it.glyph and On()
						self:diffuse(dark and 0.08 or 1, dark and 0.08 or 1, dark and 0.08 or 1, 1)
					end,
				}
				pair[#pair+1] = Def.BitmapText{
					Font = "Common Bold",
					Text = it.label,
					InitCommand = function(self)
						self:horizalign(left):xy(x0 + 40, y):zoom(0.42):maxwidth((HALF - 46) / 0.42)
					end,
					SMORefreshMessageCommand = function(self)
						local dark = On()
						self:diffuse(dark and 0.08 or 1, dark and 0.08 or 1, dark and 0.08 or 1, 1)
					end,
				}
			end
			root[#root+1] = pair
		elseif key == "reset" then
			-- a quiet way back to the start, under the button: every option
			-- as the tab first opens, and the pack unopened again
			root[#root+1] = Def.BitmapText{
				Font = "Common Normal",
				Text = "RESET OPTIONS",
				InitCommand = function(self)
					self:horizalign(right):xy(PANEL_X + PANEL_W - 4, y - 6):zoom(0.4)
				end,
				SMORefreshMessageCommand = function(self)
					local lit = state.zone ~= "tabs" and state.rip.row == index
					if lit then
						self:diffuse(AccentColor())
					elseif state.rip.phase == "filling" then
						self:diffuse(0.32, 0.32, 0.34, 1)
					else
						self:diffuse(0.55, 0.55, 0.58, 1)
					end
				end,
			}
		else
			-- the cursor's row, as a band behind it
			root[#root+1] = Def.Quad{
				InitCommand = function(self)
					self:horizalign(left):xy(PANEL_X, y):setsize(PANEL_W, ROW_H - 4)
				end,
				SMORefreshMessageCommand = function(self)
					if state.zone ~= "tabs" and state.rip.row == index then
						self:diffuse(AccentColor()):diffusealpha(0.22)
					else
						self:diffuse(1, 1, 1, 0.04)
					end
				end,
			}
			root[#root+1] = Def.BitmapText{
				Font = "Common Normal",
				Text = ROW_LABEL[key],
				InitCommand = function(self)
					self:horizalign(left):xy(PANEL_X + 10, y - 9):zoom(0.38):diffuse(0.6, 0.6, 0.6, 1)
				end,
			}
			root[#root+1] = Def.BitmapText{
				Font = "Common Normal",
				InitCommand = function(self)
					self:horizalign(left):xy(PANEL_X + 10, y + 7):zoom(0.55)
					self:maxwidth((PANEL_W - 44) / 0.55)
				end,
				SMORefreshMessageCommand = function(self)
					self:settext(RowValue(key))
					local muted = (key == "author" and #state.rip.chosen == 0)
						or (key == "era" and #state.rip.eras == 0)
						or (key == "typed" and state.rip.typed == "")
						or (key == "avoid" and state.rip.avoid == "")
					if muted then self:diffuse(0.55, 0.55, 0.55, 1) else self:diffuse(1, 1, 1, 1) end
				end,
			}
			if CYCLES[key] then
				-- the arrows that change it, on the row the cursor is on
				root[#root+1] = Def.BitmapText{
					Font = "Common Normal",
					InitCommand = function(self)
						self:horizalign(right):xy(PANEL_X + PANEL_W - 8, y):zoom(0.42)
						self:settext("&MENULEFT;&MENURIGHT;")
					end,
					SMORefreshMessageCommand = function(self)
						self:visible(state.zone ~= "tabs" and state.rip.row == index)
					end,
				}
			end
		end
	end

	-- under the button: how many so far, and what a booster is
	root[#root+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(left):vertalign(top):xy(PANEL_X + 4, ROW_Y0 + (#RIP.ROWS - 1) * ROW_H + 12)
			self:zoom(0.4):wrapwidthpixels((PANEL_W - 8) / 0.4):diffuse(0.6, 0.6, 0.6, 1)
		end,
		SMORefreshMessageCommand = function(self)
			local h = state.rip.history
			local count = h and h.count or 0
			self:settext(RIP.SIZE .. " random songs, each from a different pack on "
				.. "stepmaniaonline.net, as a new pack in your library."
				.. (count > 0 and ("\nPacks ripped so far: " .. count) or ""))
		end,
	}

	-- -------------------------------------------------------- the stage

	-- what is going on, over the stage and under it
	root[#root+1] = Def.BitmapText{
		Font = "Common Bold",
		InitCommand = function(self)
			self:xy(STAGE_X, 54):zoom(0.36):maxwidth(500 / 0.36)
		end,
		SMORefreshMessageCommand = function(self)
			local phase, pack = state.rip.phase, Pack()
			local text = "RIP A BOOSTER PACK"
			if phase == "searching" then
				text = "LOOKING FOR SONGS..."
			elseif phase == "choosing" then
				text = "KEEP THIS PACK?"
			elseif (phase == "filling" or phase == "done") and pack and pack.folder then
				text = pack.folder:upper()
			elseif phase == "failed" then
				text = "NO PACK THIS TIME"
			end
			self:settext(text):diffuse(AccentColor())
		end,
	}
	root[#root+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			A.under = self
			self:xy(STAGE_X, 434):zoom(0.42):maxwidth(510 / 0.42):diffuse(0.8, 0.8, 0.8, 1)
		end,
	}

	-- the flash when the pack tears: a round burst of light over the pack, not
	-- a sheet over the whole stage. (A quad faded on all four sides draws a
	-- cross, not a glow; the glow is a picture of one.)
	root[#root+1] = Def.Sprite{
		Texture = LO.ICONS .. "glow.png",
		InitCommand = function(self)
			A.flash = self
			self:xy(STAGE_X, STAGE_Y):zoomto(440, 400):diffuse(1, 1, 1, 0)
			self:blend("BlendMode_Add")
		end,
	}

	-- the pack itself
	local packAF = Def.ActorFrame{
		InitCommand = function(self) A.pack = self; self:xy(STAGE_X, STAGE_Y) end,
	}
	-- the halo it has while the relay looks
	packAF[#packAF+1] = Def.Sprite{
		Texture = LO.ICONS .. "glow.png",
		InitCommand = function(self)
			A.glow = self
			self:zoomto(PW + 150, PH + 150):diffuse(1, 1, 1, 0):blend("BlendMode_Add")
		end,
		SMORefreshMessageCommand = function(self)
			local c = AccentColor()
			self:diffuse(c[1], c[2], c[3], self:GetDiffuseAlpha())
		end,
	}
	local body = Def.ActorFrame{ InitCommand = function(self) A.body = self end }
	body[#body+1] = Def.Quad{
		InitCommand = function(self) self:setsize(PW + 4, PH + 4):diffuse(0.9, 0.9, 0.9, 1) end,
	}
	body[#body+1] = Def.Quad{
		InitCommand = function(self) self:setsize(PW, PH) end,
		SMORefreshMessageCommand = function(self)
			local c = AccentColor()
			self:diffusetopedge(c[1], c[2], c[3], 1)
			self:diffusebottomedge(c[1] * 0.35, c[2] * 0.35, c[3] * 0.35, 1)
		end,
	}
	-- the crimp along the bottom
	body[#body+1] = Def.Quad{
		InitCommand = function(self) self:y(PH/2 - 8):setsize(PW, 16):diffuse(0, 0, 0, 0.35) end,
	}
	for t = 0, 12 do
		body[#body+1] = Def.Quad{
			InitCommand = function(self)
				self:xy(-PW/2 + 6 + t * ((PW - 12) / 12), PH/2):setsize(7, 7):rotationz(45):diffuse(0.9, 0.9, 0.9, 1)
			end,
		}
	end
	body[#body+1] = Def.BitmapText{
		Font = "Common Bold",
		Text = "CONTENT",
		InitCommand = function(self) self:y(-PH/2 + 44):zoom(0.42):diffuse(1, 1, 1, 1) end,
	}
	body[#body+1] = Def.BitmapText{
		Font = "Common Bold",
		Text = "BOOSTER",
		InitCommand = function(self) self:y(-PH/2 + 62):zoom(0.42):diffuse(1, 1, 1, 1) end,
	}
	body[#body+1] = Def.Sprite{
		Texture = LO.ICONS .. "itgmania.png",
		InitCommand = function(self) self:y(10):zoom(78/192) end,
	}
	-- what this one will be made of
	body[#body+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:y(PH/2 - 40):zoom(0.36):maxwidth((PW - 14) / 0.36):diffuse(1, 1, 1, 0.9)
		end,
		SMORefreshMessageCommand = function(self)
			local r = state.rip
			local who = RIP.Authors()
			local eras = RIP.ErasInOrder()
			local named = {}
			for era in ivalues(eras) do named[#named+1] = RIP.ERA_SHORT[era]:upper() end
			local bits = {
				(#eras == 0 or #eras == #RIP.ERAS) and "ANY ERA" or table.concat(named, " + "),
				"EXPERT " .. r.lo .. (r.hi ~= r.lo and ("-" .. r.hi) or ""),
			}
			if #who == 1 then bits[#bits+1] = tostring(who[1]):upper()
			elseif #who > 1 then bits[#bits+1] = #who .. " AUTHORS" end
			if r.full then bits[#bits+1] = "FULL" end
			self:settext(table.concat(bits, "  -  "))
		end,
	}
	body[#body+1] = Def.BitmapText{
		Font = "Common Normal",
		Text = RIP.SIZE .. " SONGS",
		InitCommand = function(self) self:y(PH/2 - 24):zoom(0.34):diffuse(1, 1, 1, 0.8) end,
	}
	-- the shine that runs across it
	body[#body+1] = Def.Quad{
		InitCommand = function(self)
			A.sheen = self
			self:setsize(26, PH - 6):diffuse(1, 1, 1, 0):fadeleft(0.5):faderight(0.5)
			self:blend("BlendMode_Add")
		end,
	}
	packAF[#packAF+1] = body

	-- the strip that tears off the top. (Not "top": a local by that name would
	-- hide the vertalign constant from every actor made after it.)
	local strip = Def.ActorFrame{
		InitCommand = function(self) A.strip = self; self:y(-PH/2 + 10) end,
	}
	strip[#strip+1] = Def.Quad{
		InitCommand = function(self) self:setsize(PW + 4, 22):diffuse(0.9, 0.9, 0.9, 1) end,
	}
	strip[#strip+1] = Def.Quad{
		InitCommand = function(self) self:setsize(PW, 18) end,
		SMORefreshMessageCommand = function(self)
			local c = AccentColor()
			self:diffuse(c[1] * 0.6, c[2] * 0.6, c[3] * 0.6, 1)
		end,
	}
	for t = 0, 12 do
		strip[#strip+1] = Def.Quad{
			InitCommand = function(self)
				self:xy(-PW/2 + 6 + t * ((PW - 12) / 12), -11):setsize(7, 7):rotationz(45):diffuse(0.9, 0.9, 0.9, 1)
			end,
		}
	end
	strip[#strip+1] = Def.BitmapText{
		Font = "Common Normal",
		Text = "- - - TEAR HERE - - -",
		InitCommand = function(self) self:zoom(0.3):diffuse(1, 1, 1, 0.75) end,
	}
	packAF[#packAF+1] = strip
	root[#root+1] = packAF

	-- -------------------------------------------------------- the cards

	-- The gold card's glow, one per card and all of them behind every card: a
	-- glow inside its own card's frame would light up the cards dealt before
	-- it and hide under the ones dealt after. The pump places and breathes it.
	for i = 1, RIP.SIZE do
		local card = { }
		A.cards[i] = card
		root[#root+1] = Def.Sprite{
			Texture = LO.ICONS .. "glow.png",
			InitCommand = function(self)
				card.halo = self
				self:zoomto(CW + 120, CH + 120):diffuse(GOLD[1], GOLD[2], GOLD[3], 0)
				self:blend("BlendMode_Add")
			end,
		}
	end

	for i = 1, RIP.SIZE do
		local card = A.cards[i]
		local af = Def.ActorFrame{
			InitCommand = function(self) card.af = self; self:visible(false) end,
		}

		-- the back: what a card is until its song is in, the game's own arrow
		-- on it as a trading card has its game's logo
		local back = Def.ActorFrame{ InitCommand = function(self) card.back = self end }
		back[#back+1] = Def.Quad{
			InitCommand = function(self) self:setsize(CW + 4, CH + 4) end,
			SMORefreshMessageCommand = function(self) self:diffuse(AccentColor()) end,
		}
		back[#back+1] = Def.Quad{
			InitCommand = function(self) self:setsize(CW, CH):diffuse(0.07, 0.07, 0.09, 1) end,
		}
		back[#back+1] = Def.Quad{
			InitCommand = function(self) self:setsize(CW - 10, CH - 10) end,
			SMORefreshMessageCommand = function(self)
				local c = AccentColor()
				self:diffuse(c[1], c[2], c[3], 0.10)
			end,
		}
		back[#back+1] = Def.Sprite{
			Texture = LO.ICONS .. "itgmania.png",
			InitCommand = function(self) self:zoom(60/192):diffuse(1, 1, 1, 0.9) end,
		}
		af[#af+1] = back

		-- the face: the song. Every card is drawn the same way -- its picture
		-- across the top, its Expert meter on a badge where the picture ends,
		-- then the title, who charted it and the pack it came from -- and only
		-- the pack's hardest chart is drawn differently, in gold.
		local front = Def.ActorFrame{ InitCommand = function(self) card.front = self; self:visible(false) end }
		front[#front+1] = Def.Quad{
			InitCommand = function(self) self:setsize(CW + 4, CH + 4) end,
			SMORefreshMessageCommand = function(self)
				local song = Song(i)
				if not song then return end
				if song.state == "failed" then
					self:diffuse(0.3, 0.3, 0.3, 1)
				elseif IsFoil(i) then
					self:diffuse(GOLD[1], GOLD[2], GOLD[3], 1)
				else
					local c = AccentColor()
					self:diffuse(c[1], c[2], c[3], 0.55)
				end
			end,
		}
		front[#front+1] = Def.Quad{
			InitCommand = function(self)
				self:setsize(CW, CH)
				self:diffusetopedge(0.11, 0.11, 0.13, 1):diffusebottomedge(0.04, 0.04, 0.05, 1)
			end,
		}
		-- under the picture, so a song without one still has colour there;
		-- it pulses while the banner is on its way
		front[#front+1] = Def.Quad{
			InitCommand = function(self) card.artBase = self; self:y(ART_Y):setsize(CW - 4, ART_H) end,
			SMORefreshMessageCommand = function(self)
				local c = AccentColor()
				self:diffusetopedge(c[1] * 0.45, c[2] * 0.45, c[3] * 0.45, 1)
				self:diffusebottomedge(0.09, 0.09, 0.105, 1)
			end,
		}
		front[#front+1] = Def.Sprite{
			InitCommand = function(self) self:y(ART_Y):visible(false) end,
			SMORefreshMessageCommand = function(self) self:playcommand("SMOCardArt") end,
			SMOBannerReadyMessageCommand = function(self) self:playcommand("SMOCardArt") end,
			SMOCardArtCommand = function(self)
				local song = Song(i)
				local path = song and song.artUrl and state.banners[song.artUrl]
				if not path then self:visible(false) return end
				if card.loaded ~= path then
					self:Load(path)
					card.loaded = path
				end
				CoverSprite(self, CW - 4, ART_H)
				self:visible(true)
			end,
		}
		-- the picture fades into the card rather than stopping at a line
		front[#front+1] = Def.Quad{
			InitCommand = function(self)
				self:y(ART_Y + ART_H/2 - 7):setsize(CW - 4, 14)
				self:diffusetopedge(0.09, 0.09, 0.105, 0):diffusebottomedge(0.09, 0.09, 0.105, 1)
			end,
		}
		-- the badge: a ring in the card's colour round the meter
		local badge = Def.ActorFrame{ InitCommand = function(self) self:y(BADGE_Y) end }
		badge[#badge+1] = Def.Sprite{
			Texture = LO.ICONS .. "disc.png",
			InitCommand = function(self) self:zoomto(31, 31) end,
			SMORefreshMessageCommand = function(self)
				local song = Song(i)
				if not song then return end
				if song.state == "failed" then
					self:diffuse(0.3, 0.3, 0.3, 1)
				elseif IsFoil(i) then
					self:diffuse(GOLD[1], GOLD[2], GOLD[3], 1)
				else
					self:diffuse(AccentColor())
				end
			end,
		}
		badge[#badge+1] = Def.Sprite{
			Texture = LO.ICONS .. "disc.png",
			InitCommand = function(self) self:zoomto(25, 25):diffuse(0.06, 0.06, 0.07, 1) end,
		}
		badge[#badge+1] = Def.BitmapText{
			Font = "Common Bold",
			InitCommand = function(self) self:y(1):zoom(0.42):maxwidth(21 / 0.42) end,
			SMORefreshMessageCommand = function(self)
				local song = Song(i)
				if not song then self:settext("") return end
				self:settext(song.state == "failed" and "--" or tostring(song.meter))
				if song.state == "failed" then
					self:diffuse(0.5, 0.5, 0.5, 1)
				elseif IsFoil(i) then
					self:diffuse(GOLD[1], GOLD[2], GOLD[3], 1)
				else
					self:diffuse(1, 1, 1, 1)
				end
			end,
		}
		front[#front+1] = badge
		-- the year and the BPM, the title and who charted it, as one block: the
		-- title takes two lines at most, the year and the BPM share the line over
		-- it, side by side, when the song has either, and the credit sits under
		-- however many lines the title took, so the one command that sets the
		-- texts also measures and places them
		front[#front+1] = Def.ActorFrame{
			InitCommand = function(self) self:y(INFO_Y) end,
			SMORefreshMessageCommand = function(self)
				local song = Song(i)
				local title, credit = self:GetChild("Title"), self:GetChild("Credit")
				local year, bpm = self:GetChild("Year"), self:GetChild("Bpm")
				if not song then
					title:settext("")
					credit:settext("")
					year:settext("")
					bpm:settext("")
					return
				end
				local y = tonumber(song.year) or 0
				year:settext(y > 0 and tostring(y) or "")
				if IsFoil(i) then year:diffuse(GOLD[1], GOLD[2], GOLD[3], 1) else year:diffuse(AccentColor()) end
				local tempo = tostring(song.bpmText or "")
				bpm:settext(tempo ~= "" and (tempo .. " BPM") or ""):diffuse(BpmColor(song.bpm))
				FitLines(title, tostring(song.title or ""), 2)
				if song.state == "failed" then
					credit:settext("could not be downloaded"):diffuse(1, 0.55, 0.55, 1)
				else
					local who = tostring(song.credit or "")
					credit:settext(who ~= "" and ("by " .. who) or ""):diffuse(0.7, 0.7, 0.72, 1)
				end
				-- the line over the title: the year and the BPM as one centred pair
				local yw = year:GetText() ~= "" and year:GetZoomedWidth() or 0
				local bw = bpm:GetText() ~= "" and bpm:GetZoomedWidth() or 0
				local pair = (yw > 0 and bw > 0) and 5 or 0
				local lw = yw + pair + bw
				year:x(-lw/2 + yw/2)
				bpm:x(lw/2 - bw/2)
				local yh = lw > 0 and year:GetHeight() * YEAR_ZOOM or 0
				local ygap = yh > 0 and 1 or 0
				local th = title:GetHeight() * TITLE_ZOOM
				local ch = credit:GetText() ~= "" and credit:GetHeight() * CREDIT_ZOOM or 0
				local gap = ch > 0 and 3 or 0
				local total = yh + ygap + th + gap + ch
				year:y(-total/2 + yh/2)
				bpm:y(-total/2 + yh/2)
				title:y(-total/2 + yh + ygap + th/2)
				credit:y(total/2 - ch/2)
			end,
			Def.BitmapText{
				Name = "Year",
				Font = "Common Normal",
				InitCommand = function(self) self:zoom(YEAR_ZOOM) end,
			},
			Def.BitmapText{
				Name = "Bpm",
				Font = "Common Normal",
				InitCommand = function(self) self:zoom(YEAR_ZOOM) end,
			},
			Def.BitmapText{
				Name = "Title",
				Font = "Common Normal",
				InitCommand = function(self)
					self:zoom(TITLE_ZOOM):wrapwidthpixels((CW - 10) / TITLE_ZOOM)
				end,
			},
			Def.BitmapText{
				Name = "Credit",
				Font = "Common Normal",
				InitCommand = function(self)
					self:zoom(CREDIT_ZOOM):maxwidth((CW - 10) / CREDIT_ZOOM)
				end,
			},
		}
		-- the pack it came from, along the foot
		front[#front+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:y(CH/2 - 8):zoom(0.33):maxwidth((CW - 10) / 0.33):diffuse(0.6, 0.6, 0.63, 1)
			end,
			SMORefreshMessageCommand = function(self)
				local song = Song(i)
				self:settext(song and tostring(song.pack or "") or "")
			end,
		}
		-- what the gold means, on the gold card itself
		local tag = Def.ActorFrame{
			InitCommand = function(self) self:xy(CW/2 - 2, -CH/2 + 2) end,
			SMORefreshMessageCommand = function(self) self:visible(IsFoil(i)) end,
		}
		tag[#tag+1] = Def.Quad{
			InitCommand = function(self)
				self:horizalign(right):vertalign(top):setsize(50, 13):diffuse(GOLD[1], GOLD[2], GOLD[3], 1)
			end,
		}
		tag[#tag+1] = Def.BitmapText{
			Font = "Common Normal",
			Text = "HARDEST",
			InitCommand = function(self)
				self:xy(-25, 6.5):zoom(0.38):maxwidth(46 / 0.38):diffuse(0.08, 0.06, 0.02, 1)
			end,
		}
		front[#front+1] = tag
		-- the shine across the gold card: a soft glint of light, added to
		-- what is under it rather than painted over it
		front[#front+1] = Def.Quad{
			InitCommand = function(self)
				card.shine = self
				self:setsize(18, CH - 4):diffuse(1, 0.92, 0.7, 0):fadeleft(0.5):faderight(0.5)
				self:blend("BlendMode_Add")
			end,
		}
		-- while a kept pack downloads, the cards whose songs are not in yet
		-- sit under a shade; the pump lifts it as each lands
		front[#front+1] = Def.Quad{
			InitCommand = function(self)
				card.veil = self
				self:setsize(CW + 4, CH + 4):diffuse(0, 0, 0, 0)
			end,
		}
		-- ...and the one coming in now turns a wheel
		front[#front+1] = Def.Sprite{
			Texture = THEME:GetPathG("", "LoadingSpinner 10x3.png"),
			Frames  = Sprite.LinearFrames(30, 1),
			InitCommand = function(self)
				card.spin = self
				self:y(INFO_Y - 4):zoom(28 / 200):visible(false)
			end,
			SMORefreshMessageCommand = function(self) self:diffuse(AccentColor()) end,
		}
		af[#af+1] = front
		root[#root+1] = af
	end

	-- -------------------------------------------------------- the notice

	-- When the relay is off for its bandwidth there is no pack to show, so the
	-- stage says what happened instead, in full: the one line under it is too
	-- short to explain.
	local function RelayNotice()
		local pack = Pack()
		return state.rip.phase == "failed" and pack and pack.relayOut
	end
	local notice = Def.ActorFrame{
		InitCommand = function(self) A.notice = self; self:xy(STAGE_X, STAGE_Y):visible(false) end,
		SMORefreshMessageCommand = function(self) self:visible(RelayNotice() and true or false) end,
	}
	notice[#notice+1] = Def.Quad{
		InitCommand = function(self) self:setsize(424, 118):diffuse(1, 1, 1, 0.9) end,
	}
	notice[#notice+1] = Def.Quad{
		InitCommand = function(self) self:setsize(420, 114):diffuse(0.05, 0.05, 0.06, 1) end,
	}
	notice[#notice+1] = Def.BitmapText{
		Font = "Common Bold",
		Text = "BACK SOON",
		InitCommand = function(self) self:y(-34):zoom(0.42) end,
		SMORefreshMessageCommand = function(self) self:diffuse(AccentColor()) end,
	}
	notice[#notice+1] = Def.BitmapText{
		Font = "Common Normal",
		Text = RELAY_OUT_WHY,
		InitCommand = function(self)
			self:vertalign(top):y(-16):zoom(0.5):wrapwidthpixels(380 / 0.5)
		end,
	}
	root[#root+1] = notice

	-- -------------------------------------------------------- the picker

	-- A list to tick any number of rows in, open over the tab: the eras, or
	-- every charter the relay ranks -- a screenful at a time, each with how
	-- many of their packs are on the most-played list now. The rip takes songs
	-- from any era ticked, by any author ticked. The box is as tall as the list
	-- it holds, up to a screenful, and stays centred.
	local PICK_W, PICK_ROW = 400, 22
	local PICK_H = 70 + RIP.PICK_ROWS * PICK_ROW     -- at its tallest
	local PICK_TOP = -PICK_H/2 + 52                  -- the first row, from the top edge
	local function Picking() return Showing() and state.rip.picking end
	local function Rows() return Clamp(RIP.PickCount(), 1, RIP.PICK_ROWS) end
	local function BoxH() return 70 + Rows() * PICK_ROW end
	local picker = Def.ActorFrame{
		InitCommand = function(self) self:xy(LO.W/2, LO.H/2):visible(false) end,
		SMORefreshMessageCommand = function(self)
			self:visible(Picking() and true or false)
			-- laid out from the top edge, so a shorter box is moved down by
			-- half of what it gave up
			self:y(LO.H/2 + (PICK_H - BoxH()) / 2)
		end,
	}
	picker[#picker+1] = Def.Quad{
		InitCommand = function(self) self:setsize(LO.W * 2, LO.H * 3):diffuse(0, 0, 0, 0.7) end,
	}
	picker[#picker+1] = Def.Quad{
		InitCommand = function(self) self:vertalign(top):y(-PICK_H/2 - 2):diffuse(1, 1, 1, 0.9) end,
		SMORefreshMessageCommand = function(self) self:setsize(PICK_W + 4, BoxH() + 4) end,
	}
	picker[#picker+1] = Def.Quad{
		InitCommand = function(self) self:vertalign(top):y(-PICK_H/2):diffuse(0.05, 0.05, 0.06, 1) end,
		SMORefreshMessageCommand = function(self) self:setsize(PICK_W, BoxH()) end,
	}
	picker[#picker+1] = Def.BitmapText{
		Font = "Common Bold",
		InitCommand = function(self) self:horizalign(left):xy(-PICK_W/2 + 14, -PICK_H/2 + 20):zoom(0.4) end,
		SMORefreshMessageCommand = function(self)
			self:settext(state.rip.picking == "era" and "CHOOSE ERAS" or "CHOOSE AUTHORS")
			self:diffuse(AccentColor())
		end,
	}
	picker[#picker+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(right):xy(PICK_W/2 - 14, -PICK_H/2 + 20):zoom(0.45):diffuse(0.75, 0.75, 0.78, 1)
		end,
		SMORefreshMessageCommand = function(self)
			local r = state.rip
			local n = #(r.picking == "era" and r.eras or r.chosen)
			if n > 0 then
				self:settext(n .. " chosen")
			else
				self:settext(r.picking == "era" and "any era" or "anyone")
			end
		end,
	}
	for k = 1, RIP.PICK_ROWS do
		local ry = PICK_TOP + (k - 1) * PICK_ROW
		local function Item()
			local at = state.rip.pickTop + k - 1
			local key, label, note = RIP.PickItem(at)
			return key, label, note, at
		end
		local row = Def.ActorFrame{
			InitCommand = function(self) self:y(ry) end,
			SMORefreshMessageCommand = function(self)
				self:visible(Item() ~= nil)
			end,
		}
		-- the cursor
		row[#row+1] = Def.Quad{
			InitCommand = function(self) self:setsize(PICK_W - 28, PICK_ROW - 2) end,
			SMORefreshMessageCommand = function(self)
				local _, _, _, at = Item()
				local c = AccentColor()
				self:diffuse(c[1], c[2], c[3], at == state.rip.pickAt and 0.3 or 0)
			end,
		}
		-- the tick box
		row[#row+1] = Def.Quad{
			InitCommand = function(self) self:x(-PICK_W/2 + 30):setsize(12, 12):diffuse(1, 1, 1, 0.6) end,
		}
		row[#row+1] = Def.Quad{
			InitCommand = function(self) self:x(-PICK_W/2 + 30):setsize(10, 10):diffuse(0.05, 0.05, 0.06, 1) end,
		}
		row[#row+1] = Def.Quad{
			InitCommand = function(self) self:x(-PICK_W/2 + 30):setsize(7, 7) end,
			SMORefreshMessageCommand = function(self)
				local key = Item()
				self:visible(key ~= nil and RIP.PickTicked(key) ~= nil)
				self:diffuse(AccentColor())
			end,
		}
		row[#row+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(left):x(-PICK_W/2 + 44):zoom(0.5):maxwidth((PICK_W - 150) / 0.5)
			end,
			SMORefreshMessageCommand = function(self)
				local _, label = Item()
				self:settext(label or "")
			end,
		}
		-- beside an author, how much of theirs is played now, and nothing else
		row[#row+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(right):x(PICK_W/2 - 26):zoom(0.42)
			end,
			SMORefreshMessageCommand = function(self)
				local _, _, note = Item()
				self:settext(note or "")
				local c = AccentColor()
				self:diffuse(c[1], c[2], c[3], 1)
			end,
		}
		picker[#picker+1] = row
	end
	picker[#picker+1] = ScrollBar(PICK_W/2 - 12, PICK_TOP - PICK_ROW/2, RIP.PICK_ROWS * PICK_ROW, false,
		function()
			local n = RIP.PickCount()
			if not Picking() or n <= RIP.PICK_ROWS then return nil end
			return n, RIP.PICK_ROWS, state.rip.pickTop - 1
		end)
	picker[#picker+1] = Def.BitmapText{
		Font = "Common Normal",
		Text = "&START; choose    &SELECT; clear    &BACK; done",
		InitCommand = function(self) self:zoom(0.45):diffuse(0.85, 0.85, 0.88, 1) end,
		SMORefreshMessageCommand = function(self) self:y(-PICK_H/2 + BoxH() - 16) end,
	}

	-- -------------------------------------------------------- the pump

	local function Tick()
		if not Showing() then return end
		local r = state.rip
		local now = GetTimeSinceStart()
		local pack = r.pack
		local opened = pack and pack.openedAt and (r.phase == "choosing" or r.phase == "filling" or r.phase == "done")

		-- the pack: idling, shaking while it waits, tearing when it opens --
		-- out loud, the moment it does, but not again on coming back to a
		-- pack opened while the player was elsewhere
		local e = opened and (now - pack.openedAt) or 0
		if opened and A.tornFor ~= pack then
			A.tornFor = pack
			if TEAR and e < 0.5 then SOUND:PlayOnce(TEAR) end
		end
		if not opened then
			local bob, rot, x, glow = math.sin(now * 1.6) * 4, math.sin(now * 0.9) * 2, 0, 0
			if r.phase == "searching" then
				local waited = now - (r.phaseAt or now)
				rot = math.sin(now * 38) * (1.5 + math.min(waited, 12) * 0.25)
				x = math.sin(now * 53) * 1.5
				glow = 0.55 + 0.25 * math.sin(now * 7)
			end
			A.pack:visible(not RelayNotice()):xy(STAGE_X + x, STAGE_Y + bob):rotationz(rot)
			A.body:zoom(1):diffusealpha(1):y(0)
			A.strip:visible(true):y(-PH/2 + 10):rotationz(0):diffusealpha(1)
			A.glow:diffusealpha(glow)
			A.flash:diffusealpha(0)
			-- the shine runs across now and then; faster while it waits
			local cycle = (r.phase == "searching") and 1.1 or 2.6
			local p = (now % cycle) / cycle * 1.6
			if p <= 1 then
				A.sheen:x(-PW/2 + 13 + p * (PW - 26)):diffusealpha(0.32 * math.sin(p * math.pi))
			else
				A.sheen:diffusealpha(0)
			end
		else
			local tp = Clamp(e / 0.45, 0, 1)
			A.strip:y(-PH/2 + 10 - 70 * Ease(tp)):rotationz(-28 * tp):diffusealpha(1 - tp)
			local bp = Clamp((e - 0.25) / 0.5, 0, 1)
			A.body:zoom(1 - 0.15 * bp):diffusealpha(1 - bp):y(40 * Ease(bp))
			A.pack:visible(bp < 1):xy(STAGE_X, STAGE_Y):rotationz(0)
			A.glow:diffusealpha(0)
			A.sheen:diffusealpha(0)
			local flash = 0
			if e < 0.1 then flash = e / 0.1 * 0.7
			elseif e < 0.55 then flash = 0.7 * (1 - (e - 0.1) / 0.45) end
			A.flash:diffusealpha(flash)
		end

		-- the cards: dealt from the pack, each turning over as it lands -- the
		-- relay's answer already says what is on them -- and, once the pack is
		-- kept, lighting up as its song comes in
		for i, card in ipairs(A.cards) do
			local song = pack and pack.songs and pack.songs[i]
			if not (opened and song) then
				card.af:visible(false)
				card.halo:diffusealpha(0)
			else
				local start = DEAL_AT + (i - 1) * DEAL_EACH
				local dp = Clamp((e - start) / DEAL_TIME, 0, 1)
				local tx, ty = CardXY(i)
				local k = EaseBack(dp)
				local x, y = STAGE_X + (tx - STAGE_X) * k, STAGE_Y + (ty - STAGE_Y) * k
				card.af:visible(e >= start)
				card.af:xy(x, y)
				card.af:rotationz((1 - dp) * ((i % 2 == 0) and 14 or -14))
				card.halo:xy(x, y)
				local fp = Clamp((e - start - DEAL_TIME - FLIP_AFTER) / FLIP_TIME, 0, 1)
				local show = fp >= 0.5
				card.back:visible(not show)
				card.front:visible(show)
				-- a song that has just landed gives its card a small bump
				local bump = 0
				if song.landedAt then
					local lp = Clamp((now - song.landedAt) / 0.3, 0, 1)
					bump = 0.07 * math.sin(lp * math.pi)
				end
				local size = (0.6 + 0.4 * dp) * (1 + bump)
				card.af:zoomx(math.abs(math.cos(fp * math.pi)) * size)
				card.af:zoomy(size)
				-- the shade over a kept card whose song is not in yet; the one
				-- on its way breathes
				local shade = 0
				if r.phase == "filling" then
					if song.state == "waiting" then
						shade = 0.62
					elseif song.state == "downloading" then
						shade = 0.42 + 0.14 * math.sin(now * 6)
					end
				end
				card.veil:diffusealpha(shade)
				card.spin:visible(r.phase == "filling" and song.state == "downloading")
				-- the picture's stand-in breathes until the banner lands, or
				-- until it is known there is none
				local url = song.artUrl
				if url and not state.banners[url] and not state.bannerFailed[url] then
					card.artBase:diffusealpha(0.55 + 0.45 * math.sin(now * 5 + i))
				else
					card.artBase:diffusealpha(1)
				end
				if show and IsFoil(i) then
					local p = ((now + i * 0.37) % 2.4) / 2.4 * 1.5
					if p <= 1 then
						card.shine:x(-CW/2 + 9 + p * (CW - 18)):diffusealpha(0.45 * math.sin(p * math.pi))
					else
						card.shine:diffusealpha(0)
					end
					card.halo:diffusealpha(0.5 + 0.15 * math.sin(now * 2.6 + i))
				else
					card.shine:diffusealpha(0)
					card.halo:diffusealpha(0)
				end
			end
		end

		-- the line under the stage
		local text = RIP.SIZE .. " random songs within the limits on the left, made into a pack of their own"
		if r.phase == "searching" then
			text = string.format("Searching stepmaniaonline.net for songs that fit...   %ds",
				math.floor(now - (r.phaseAt or now)))
		elseif pack and r.phase == "choosing" then
			text = string.format("%d songs, %s%s   -   KEEP downloads them, RE-RIP brings a new set",
				#pack.songs, FormatBytes(pack.total or 0),
				pack.short and (" (only " .. #pack.songs .. " matched)") or "")
		elseif pack and r.phase == "filling" then
			-- nothing in yet reads as the whole to fetch: FormatBytes has no
			-- words for none
			local cur = (state.downloads[pack.dlKey] or {}).cur or 0
			text = string.format("%d of %d songs in   -   %s", pack.got + pack.failed, #pack.songs,
				cur > 0 and (FormatBytes(cur) .. " of " .. FormatBytes(pack.total or 0))
				or (FormatBytes(pack.total or 0) .. " to fetch"))
		elseif pack and r.phase == "done" then
			if pack.relayOut then
				text = string.format("%d songs added, synced %s   -   the rest are unavailable for now",
					pack.got, pack.sync)
			else
				text = string.format("%d songs added, synced %s%s   -   reload songs when you leave to play them",
					pack.got, pack.sync,
					pack.short and ("   -   only " .. #pack.songs .. " matched") or "")
			end
		elseif pack and r.phase == "failed" then
			text = tostring(pack.msg or "the rip did not work")
		end
		A.under:settext(text)
		if r.phase == "failed" then A.under:diffuse(1, 0.5, 0.5, 1) else A.under:diffuse(0.8, 0.8, 0.8, 1) end
	end

	root[#root+1] = Def.ActorFrame{
		InitCommand = function(self)
			self:SetUpdateFunction(function() Tick() end)
		end,
	}

	root[#root+1] = picker

	ui[#ui+1] = root
end
