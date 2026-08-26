-- -----------------------------------------------------------------------
-- The chart preview window
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local AccentColor = CB.AccentColor
local Clamp       = CB.Clamp
local LO          = CB.LO
local Snd         = CB.Snd

function CB.Screen.ChartWindow(ui, detail)
	-- ---------------------------------------------------------------
	-- CHART WINDOW: what the song being sampled is actually doing.
	--
	-- The sample was always the honest part of this screen -- everything else
	-- is somebody's description of a pack -- and this is the rest of it: the
	-- arrows that go with the twenty seconds you are hearing, in the player's
	-- own noteskin, at a speed they can read, arriving on receptors that light
	-- up as they land.
	--
	-- Nothing here is read back from the sound. RageSound will not say where it
	-- is, so the picture runs off the clock the audio was started against. Over
	-- a twenty-second sample that holds; over a song it would not.

	LO.NOTESKIN = LO.NoteSkinName()
	Snd.ReadQuant(LO.NOTESKIN)

	local CW_W, CW_H = 304, 380
	local CW_X = LO.W/2 - CW_W/2
	local CW_Y = 48
	local CW_MID = LO.W/2
	-- The receptor line. Far enough under the difficulty chips that the two
	-- read as separate things: an arrow is thirty-odd pixels tall and sits
	-- centred on this line, so anything tighter puts its top edge into the row
	-- of chips above it.
	local CW_REC_Y = CW_Y + 96
	local CW_ENTER = CW_Y + CW_H - 34          -- where a note comes into view
	Snd.LEAD = (CW_ENTER - CW_REC_Y) / Snd.PPS

	local chartWin = Def.ActorFrame{
		Name = "ChartWindow",
		InitCommand = function(self) self:visible(false) end,
	}

	-- the panel: solid, because the song list behind it would read as notes
	chartWin[#chartWin+1] = Def.Quad{
		InitCommand = function(self)
			self:vertalign(top):horizalign(left)
			self:xy(CW_X, CW_Y):setsize(CW_W, CW_H):diffuse(0.03, 0.03, 0.04, 1)
		end,
	}
	for edge in ivalues({
		{ 0, 0, CW_W, 1 }, { 0, CW_H - 1, CW_W, 1 },
		{ 0, 0, 1, CW_H }, { CW_W - 1, 0, 1, CW_H },
	}) do
		chartWin[#chartWin+1] = Def.Quad{
			InitCommand = function(self)
				self:vertalign(top):horizalign(left)
				self:xy(CW_X + edge[1], CW_Y + edge[2]):setsize(edge[3], edge[4])
			end,
			SMORefreshMessageCommand = function(self)
				self:diffuse(AccentColor()):diffusealpha(0.5)
			end,
		}
	end

	chartWin[#chartWin+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(CW_MID, CW_Y + 15):zoom(0.5)
			self:maxwidth((CW_W - 24)/0.5)
		end,
		SMORefreshMessageCommand = function(self)
			self:settext("CHART PREVIEW")
			self:diffuse(AccentColor())
		end,
	}
	chartWin[#chartWin+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(CW_MID, CW_Y + 29):zoom(0.42)
			self:maxwidth((CW_W - 24)/0.42)
		end,
		SMORefreshMessageCommand = function(self)
			-- Snd.song is the title itself, not the song row it came from
			self:settext(Snd.song or "")
			self:diffuse(0.72, 0.72, 0.72, 1)
		end,
	}
	chartWin[#chartWin+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(CW_MID, CW_Y + 42):zoom(0.38)
			self:maxwidth((CW_W - 24)/0.38)
		end,
		SMORefreshMessageCommand = function(self)
			-- the difficulty on show, and the tempo: what the pack lists,
			-- which is a range as often as a number, and the simfile's own
			-- only where the pack said nothing
			local bits = {}
			local chart = Snd.charts and Snd.charts[Snd.chartIdx]
			if chart then bits[#bits+1] = Snd.ChartLabel(chart) end
			local tempo = Snd.bpmText
			if not tempo and Snd.bpm and Snd.bpm > 0 then
				tempo = tostring(math.floor(Snd.bpm + 0.5))
			end
			if tempo then bits[#bits+1] = tempo .. " bpm" end
			self:settext(table.concat(bits, "   -   "))
			self:diffuse(0.6, 0.6, 0.6, 1)
		end,
	}

	-- What the window shows while the sample is on its way.
	--
	-- A spinner, what the helper is doing, and how far it has got. Getting a
	-- song out of a pack archive takes a few seconds of range reads and an
	-- inflate, and the window being empty for those seconds is the difference
	-- between "working" and "broken" to whoever pressed the button.
	--
	-- Driven from the chart pump rather than from a refresh: the pump runs
	-- every frame, and a refresh only happens when something else makes one.
	chartWin[#chartWin+1] = Def.Sprite{
		Texture = THEME:GetPathG("", "LoadingSpinner 10x3.png"),
		Frames  = Sprite.LinearFrames(30, 1),
		InitCommand = function(self)
			Snd.loadSpin = self
			-- the source frames are large; this is about an arrow across
			self:xy(CW_MID, CW_Y + 148):zoom(0.17):visible(false)
		end,
	}
	chartWin[#chartWin+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			Snd.loadWord = self
			self:xy(CW_MID, CW_Y + 178):zoom(0.46):visible(false)
			self:maxwidth((CW_W - 40)/0.46)
		end,
	}
	-- the track the bar runs in, and the bar
	chartWin[#chartWin+1] = Def.Quad{
		InitCommand = function(self)
			Snd.loadTrack = self
			self:xy(CW_MID, CW_Y + 194):setsize(CW_W - 80, 3)
			self:diffuse(1, 1, 1, 0.12):visible(false)
		end,
	}
	chartWin[#chartWin+1] = Def.Quad{
		InitCommand = function(self)
			Snd.loadBar = self
			self:horizalign(left):xy(CW_MID - (CW_W - 80)/2, CW_Y + 194)
			self:setsize(0, 3):visible(false)
		end,
	}

	-- What a chart is doing when it is doing nothing: a real difficulty can
	-- have no steps inside the twenty seconds being sampled, and an empty
	-- field with no explanation reads as something broken.
	chartWin[#chartWin+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:xy(CW_MID, CW_Y + 170):zoom(0.45):visible(false)
			self:wrapwidthpixels((CW_W - 40)/0.45)
		end,
		SMORefreshMessageCommand = function(self)
			local quiet = Snd.ChartOn() and Snd.notes == nil
			self:visible(quiet)
			if quiet then
				self:settext("nothing in this part of the song")
				self:diffuse(0.55, 0.55, 0.55, 1)
			end
		end,
	}

	-- Every difficulty the song has, as the wheel would list them, with the one
	-- on show lit. This is the selector: it is in the window because the window
	-- is what the reader is looking at while the sample plays.
	local CW_CHIP_Y = CW_Y + 58
	local CW_CHIP_W = 46
	local CW_CHIP_H = 15

	-- The row is a control, and a row of coloured boxes does not say so on its
	-- own. The arrows sit against it, pointing at the thing they move.
	chartWin[#chartWin+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(right):y(CW_CHIP_Y):zoom(0.34):visible(false)
		end,
		SMORefreshMessageCommand = function(self)
			local n = Snd.charts and #Snd.charts or 0
			self:visible(n > 1)
			if n <= 1 then return end
			self:x(CW_MID - n*(CW_CHIP_W + 3)/2 - 5)
			self:settext("&MENUUP;&MENUDOWN;")
			self:diffuse(0.75, 0.75, 0.75, 1)
		end,
	}
	chartWin[#chartWin+1] = Def.BitmapText{
		Font = "Common Normal",
		InitCommand = function(self)
			self:horizalign(left):y(CW_CHIP_Y):zoom(0.34):visible(false)
		end,
		SMORefreshMessageCommand = function(self)
			local n = Snd.charts and #Snd.charts or 0
			self:visible(n > 1)
			if n <= 1 then return end
			self:x(CW_MID + n*(CW_CHIP_W + 3)/2 + 5)
			self:settext("difficulty")
			self:diffuse(0.6, 0.6, 0.6, 1)
		end,
	}

	for slot = 1, 8 do
		local function ChipChart()
			local list = Snd.charts
			return list and list[slot] or nil
		end
		local function ChipX()
			local n = Snd.charts and #Snd.charts or 0
			return CW_MID + (slot - (n + 1)/2) * (CW_CHIP_W + 3)
		end

		-- a lit edge round the one on show, so the row reads as a selection
		-- rather than as six coloured labels
		chartWin[#chartWin+1] = Def.Quad{
			InitCommand = function(self)
				self:setsize(CW_CHIP_W + 4, CW_CHIP_H + 4):visible(false)
			end,
			SMORefreshMessageCommand = function(self)
				self:visible(ChipChart() ~= nil and slot == Snd.chartIdx)
				self:xy(ChipX(), CW_CHIP_Y):diffuse(1, 1, 1, 0.9)
			end,
		}
		chartWin[#chartWin+1] = Def.Quad{
			InitCommand = function(self)
				self:setsize(CW_CHIP_W, CW_CHIP_H):visible(false)
			end,
			SMORefreshMessageCommand = function(self)
				local chart = ChipChart()
				self:visible(chart ~= nil)
				if not chart then return end
				self:xy(ChipX(), CW_CHIP_Y)
				local tint = Snd.DiffColor(chart)
				if slot == Snd.chartIdx then
					self:diffuse(tint[1], tint[2], tint[3], 1)
				else
					self:diffuse(tint[1], tint[2], tint[3], 0.18)
				end
			end,
		}
		-- which style this difficulty is for. A song with singles and doubles
		-- lists both, and two chips reading "11" say nothing about which pad
		-- you would be standing on.
		for _, kind in ipairs({ { 4, "pad" }, { 8, "doubles" } }) do
			local iconName = LO.ICONS .. kind[2] .. ".png"
			if FILEMAN:DoesFileExist(iconName) then
				chartWin[#chartWin+1] = Def.Sprite{
					Texture = iconName,
					InitCommand = function(self) self:zoom(10/96):visible(false) end,
					SMORefreshMessageCommand = function(self)
						local chart = ChipChart()
						local mine = chart ~= nil and tonumber(chart.lanes) == kind[1]
						self:visible(mine)
						if not mine then return end
						self:xy(ChipX() - 12, CW_CHIP_Y)
						if slot == Snd.chartIdx then
							self:diffuse(0.06, 0.06, 0.06, 1)
						else
							self:diffuse(0.85, 0.85, 0.85, 1)
						end
					end,
				}
			end
		end

		chartWin[#chartWin+1] = Def.BitmapText{
			Font = "Common Normal",
			InitCommand = function(self)
				self:horizalign(left):zoom(0.4)
				self:maxwidth((CW_CHIP_W - 22)/0.4):visible(false)
			end,
			SMORefreshMessageCommand = function(self)
				local chart = ChipChart()
				self:visible(chart ~= nil)
				if not chart then return end
				self:xy(ChipX() - 3, CW_CHIP_Y)
				local meter = tonumber(chart.meter) or 0
				self:settext(meter > 0 and tostring(meter)
					or tostring(chart.diff or ""):sub(1, 3):upper())
				if slot == Snd.chartIdx then
					self:diffuse(0.06, 0.06, 0.06, 1)
				else
					self:diffuse(0.85, 0.85, 0.85, 1)
				end
			end,
		}
	end

	-- Receptors, notes and hit flashes, a column at a time. The player's own
	-- noteskin where it will load, and the module's own arrow where it will
	-- not -- which is also what a fork with no noteskins installed would get.
	Snd.receptors, Snd.flashes, Snd.notesAF = {}, {}, {}
	local COLUMN = { "Left", "Down", "Up", "Right" }
	local ownNote = FILEMAN:DoesFileExist(LO.ICONS .. "note.png")
	local ownEdge = FILEMAN:DoesFileExist(LO.ICONS .. "noteedge.png")
	local ownRec  = FILEMAN:DoesFileExist(LO.ICONS .. "receptor.png")

	-- Built in three passes, because the order actors are added is the order
	-- they are drawn and NoteField draws in exactly this order: the receptors,
	-- then the notes over them, then the explosions over everything.
	for lane = 1, 8 do
		local column = COLUMN[((lane - 1) % 4) + 1]
		local receptor = LO.NoteActor(column, "Receptor")
		if receptor then
			Snd.usingSkin = true
			chartWin[#chartWin+1] = receptor .. {
				InitCommand = function(self)
					Snd.receptors[lane] = self
					self:y(CW_REC_Y):zoom(Snd.MINI):visible(false)
				end,
			}
		elseif ownRec then
			chartWin[#chartWin+1] = Def.Sprite{
				Texture = LO.ICONS .. "receptor.png",
				InitCommand = function(self)
					Snd.receptors[lane] = self
					self:y(CW_REC_Y):zoom(Snd.ARROW/96)
					self:rotationz(Snd.LaneRot(lane)):visible(false)
				end,
			}
		end
	end

	-- The arrows are the player's own noteskin, coloured the way the game
	-- colours them.
	--
	-- cel keeps its arrow and a strip of eight quantization colours in one
	-- image and picks a colour by sliding the texture coordinates along that
	-- strip; NoteDisplay does it with DISPLAY->TextureTranslate, and
	-- Actor:texturetranslate is the same call by another name. So the note is
	-- not tinted, not composited and not imitated -- it is cel's own arrow with
	-- cel's own colour on it, which is the only version of this that is right.
	--
	-- The module's own art is the fallback for a skin that will not load, and
	-- that one does need two layers: a body to take the colour and a pale line
	-- over it that must not, because tinting one flat graphic would colour the
	-- border along with the arrow.
	local skinNote = LO.NoteActor("Left", "Tap Note") ~= nil
	Snd.skinNotes = skinNote

	-- A lift is its own element in every noteskin that has one -- "Tap Lift",
	-- beside "Tap Note" -- so the right way to draw one is to ask the skin for
	-- it rather than to dress a tap up as one. Skins that predate lifts do not
	-- answer, and those fall back below.
	--
	-- Only worth a pool when the skin draws taps too: the fallback art shows a
	-- lift by hollowing the arrow it already has, at no cost in actors.
	local skinLift = skinNote and LO.NoteActor("Left", "Tap Lift") ~= nil
	Snd.skinLifts = skinLift
	Snd.liftsAF = {}

	for lane = 1, 8 do
		local column = COLUMN[((lane - 1) % 4) + 1]
		Snd.notesAF[lane] = {}
		for slot = 1, Snd.LANE_POOL do
			local note = skinNote and LO.NoteActor(column, "Tap Note") or nil
			if note then
				chartWin[#chartWin+1] = note .. {
					InitCommand = function(self)
						Snd.notesAF[lane][slot] = self
						self:zoom(Snd.MINI):visible(false)
					end,
				}
			elseif ownNote then
				chartWin[#chartWin+1] = Def.Sprite{
					Texture = LO.ICONS .. "note.png",
					InitCommand = function(self)
						Snd.notesAF[lane][slot] = self
						self:zoom(Snd.ARROW/96)
						self:rotationz(Snd.LaneRot(lane)):visible(false)
					end,
				}
			end
		end
	end

	-- One lift actor per tap actor, because a slot holds either a tap or a lift
	-- and never both: the pair is what makes the choice per column free at draw
	-- time, and only one of the two is ever visible.
	if skinLift then
		for lane = 1, 8 do
			local column = COLUMN[((lane - 1) % 4) + 1]
			Snd.liftsAF[lane] = {}
			for slot = 1, Snd.LANE_POOL do
				local lift = LO.NoteActor(column, "Tap Lift")
				if lift then
					chartWin[#chartWin+1] = lift .. {
						InitCommand = function(self)
							Snd.liftsAF[lane][slot] = self
							self:zoom(Snd.MINI):visible(false)
						end,
					}
				end
			end
		end
	end

	-- built only when the fallback art is what is being drawn, because a pool
	-- of sixty-four actors that can never be seen is still sixty-four actors
	if not skinNote then
		for lane = 1, 8 do
			Snd.edgeAF[lane] = {}
			for slot = 1, Snd.LANE_POOL do
				if ownEdge then
					chartWin[#chartWin+1] = Def.Sprite{
						Texture = LO.ICONS .. "noteedge.png",
						InitCommand = function(self)
							Snd.edgeAF[lane][slot] = self
							self:zoom(Snd.ARROW/96)
							self:rotationz(Snd.LaneRot(lane)):visible(false)
						end,
					}
				end
			end
		end
	end

	-- The noteskin's own hit flash. "Explosion" is the whole set -- bright,
	-- dim, hold, mine -- carrying the W1..W5 commands the game plays on a
	-- judgment, which is what makes this look like the game rather than like
	-- something imitating it. Last, so it is on top, as it is in game.
	for lane = 1, 8 do
		local column = COLUMN[((lane - 1) % 4) + 1]
		local flash = LO.NoteActor(column, "Explosion")
		if flash then
			chartWin[#chartWin+1] = flash .. {
				InitCommand = function(self)
					Snd.flashes[lane] = self
					self:y(CW_REC_Y):zoom(Snd.MINI):visible(false)
				end,
			}
		end
	end

	-- the equalizer, wrapped round the foot of the window: the same bank that
	-- plays in the song row, given the width to be the frame of this one
	Snd.winBars = {}
	local CW_EQ_Y = CW_Y + CW_H - 12
	local CW_EQ_N = 28
	local CW_EQ_PAD = 16
	local CW_EQ_W = (CW_W - 2*CW_EQ_PAD) / CW_EQ_N
	for i = 1, CW_EQ_N do
		chartWin[#chartWin+1] = Def.Quad{
			InitCommand = function(self)
				Snd.winBars[i] = self
				self:vertalign(bottom):horizalign(left)
				self:xy(CW_X + CW_EQ_PAD + (i-1)*CW_EQ_W, CW_EQ_Y)
				self:setsize(math.max(1, CW_EQ_W - 2), 2)
			end,
		}
	end

	-- Everything above is placed from here rather than from a message handler
	-- on each of a hundred actors, which is what keeps this affordable.
	chartWin[#chartWin+1] = Def.Actor{
		InitCommand = function(self) self:queuecommand("SMOChartPump") end,
		SMOChartPumpCommand = function(self)
			-- Two questions, not one: whether the window is up, and whether
			-- there are notes to draw in it. Between pressing Preview and the
			-- first note arriving the answer to the first is yes and to the
			-- second no, and that gap is what the spinner fills.
			local showing = Snd.WindowOn() and LO.DetailShowing()
			local on = Snd.ChartOn() and LO.DetailShowing()

			-- The window arrives and leaves rather than blinking in and out.
			-- Driven here rather than by a tween because the pump is what
			-- knows when a sample stopped, and a tween started from somewhere
			-- else would be cut off by the next thing to touch the frame.
			local fade = Snd.winFade or 0
			if showing then
				fade = math.min(1, fade + 1/30/0.18)
			else
				fade = math.max(0, fade - 1/30/0.40)
			end
			Snd.winFade = fade

			local frame = self:GetParent()
			if frame then
				frame:visible(fade > 0)
				frame:diffusealpha(fade)
			end

			local waiting = showing and Snd.status == "loading"
			if Snd.loadSpin then
				Snd.loadSpin:visible(waiting)
				if waiting then Snd.loadSpin:diffuse(AccentColor()) end
			end
			if Snd.loadWord then
				Snd.loadWord:visible(waiting)
				if waiting then
					Snd.loadWord:settext((Snd.ProgLabel()))
					Snd.loadWord:diffuse(0.78, 0.78, 0.78, 1)
				end
			end
			do
				-- the bar only appears once there is a fraction to show; the
				-- indeterminate phases have the spinner and say so in words
				local _, frac = Snd.ProgLabel()
				local measured = waiting and frac ~= nil and frac >= 0
				if Snd.loadTrack then Snd.loadTrack:visible(measured) end
				if Snd.loadBar then
					Snd.loadBar:visible(measured)
					if measured then
						Snd.loadBar:diffuse(AccentColor())
						Snd.loadBar:setsize(
							math.max(2, (CW_W - 80) * Clamp(frac, 0, 1)), 3)
					end
				end
			end

			-- An empty field under the spinner, so the window looks like the
			-- thing it is about to be rather than like a box with a wheel in
			-- it. Four, because the style is not known until the charts land
			-- and four is what most songs are; a doubles chart widens to eight
			-- when it arrives.
			if not on then
				-- Nothing from the last sample survives into this one.
				--
				-- The arrows, the hit flashes and the equalizer are all placed
				-- by the part of this pump below, which does not run while a
				-- sample is being fetched -- so without this they sat wherever
				-- the previous preview left them, and opening a second one
				-- showed the first one's notes frozen under the spinner.
				--
				-- Done once per state rather than per tick: this branch used
				-- to touch ~140 actors and build 28 color tables four times a
				-- second for the life of the process. The signature is every
				-- input the pose depends on; while it is unchanged there is
				-- nothing new to draw.
				local over = waiting and LO.PreviewLanes() or 0
				local sig = (waiting and "w" or "-") .. over
					.. (Snd.usingSkin and "s" or "-")
				if Snd.winIdleSig == sig then
					self:sleep(fade > 0 and 1/30 or 0.25):queuecommand("SMOChartPump")
					return
				end
				Snd.winIdleSig = sig
				local accent = AccentColor()
				for lane = 1, 8 do
					local pool, edges = Snd.notesAF[lane], Snd.edgeAF[lane]
					local lifts = Snd.liftsAF[lane]
					for slot = 1, Snd.LANE_POOL do
						if pool and pool[slot] then pool[slot]:visible(false) end
						if edges and edges[slot] then edges[slot]:visible(false) end
						if lifts and lifts[slot] then lifts[slot]:visible(false) end
					end

					local rec = Snd.receptors[lane]
					if rec then
						local idle = waiting and lane <= over
						rec:visible(idle)
						if idle then
							rec:xy(Snd.LaneX(lane, CW_MID, over), CW_REC_Y)
							rec:zoom(Snd.usingSkin and Snd.MINI or (Snd.ARROW/96))
							rec:glow(1, 1, 1, 0)
							if not Snd.usingSkin then
								rec:diffuse(accent):diffusealpha(0.32)
							end
						end
					end
					local flash = Snd.flashes[lane]
					if flash then flash:visible(false) end
				end
				for i = 1, CW_EQ_N do
					local bar = Snd.winBars[i]
					if bar then
						bar:setsize(math.max(1, CW_EQ_W - 2), 2)
						bar:diffuse(accent):diffusealpha(0.22)
					end
				end
				-- while it is still fading, keep up; once it has gone, tick
				-- slowly enough to cost nothing and often enough to catch a
				-- sample starting
				self:sleep(fade > 0 and 1/30 or 0.25):queuecommand("SMOChartPump")
				return
			end
			-- back to work; the next idle spell starts with a fresh pose
			Snd.winIdleSig = nil

			local now = GetTimeSinceStart()
			local accent = AccentColor()
			local list = Snd.notes or {}
			local from = Snd.NoteFrom(now)
			local elapsed = now - Snd.startedAt

			for lane = 1, 8 do
				local x = Snd.LaneX(lane, CW_MID)
				local shown = lane <= Snd.lanes

				local rec = Snd.receptors[lane]
				if rec then
					rec:visible(shown)
					if shown then
						local hit = Snd.Struck(lane, now)
						local base = Snd.usingSkin and Snd.MINI or (Snd.ARROW/96)
						rec:x(x)
						-- The noteskin plays its own press below, but what that
						-- looks like is the skin's business and cel's is nearly
						-- invisible. This is the part that always reads: the
						-- receptor swells and lights up under the arrow, which
						-- is what stepping on one looks like.
						rec:zoom(base * (1 + 0.30*hit))
						rec:glow(1, 1, 1, hit * 0.75)
						if not Snd.usingSkin then
							rec:diffuse(accent):diffusealpha(0.32 + 0.68*hit)
						end
					end
				end
				local flash = Snd.flashes[lane]
				if flash then
					flash:visible(shown)
					if shown then flash:xy(x, CW_REC_Y):zoom(Snd.MINI) end
				end
			end

			-- A note landing is an event, not a state. The noteskin's press
			-- and explosion commands animate themselves once played -- that is
			-- what they are for -- so playing them every frame would restart
			-- them thirty times a second and they would never be seen.
			if Snd.usingSkin then
				for index = from, #list do
					local note = list[index]
					if note.t > elapsed then break end
					for lane = 1, Snd.lanes do
						if Snd.InLane(note, lane) and (Snd.fired[lane] or 0) < index then
							Snd.fired[lane] = index
							local rec = Snd.receptors[lane]
							local boom = Snd.flashes[lane]
							-- The order the engine uses, from GhostArrowRow::DidTapNote
							-- and ReceptorArrow::Step: on the explosion, Judgment then
							-- Dim then the judgment command; on the receptor, the
							-- judgment command, then Press when it next draws.
							--
							-- Dim rather than Bright. The bright set is for a combo
							-- past BrightGhostComboThreshold, and Simply Love sets
							-- that to -1, which the engine reads unsigned -- so a
							-- player of this theme only ever sees Dim. cel also wires
							-- its bright W1 backwards, and playing it would flash
							-- white on every note.
							--
							-- playcommand, not playcommandonleaves: the latter looks
							-- the command up on the frame it is called on, which
							-- defines none of these, and then does nothing at all.
							-- playcommand recurses to every descendant, which is what
							-- the engine's own PlayCommand does.
							if boom then
								boom:playcommand("Judgment")
								boom:playcommand("Dim")
								boom:playcommand("W1")
							end
							if rec then
								rec:playcommand("W1")
								rec:playcommand("Press")
							end
							Snd.pressAt[lane] = now
						end
					end
				end
				-- and let go a moment after, the way a foot does
				for lane = 1, 8 do
					local at = Snd.pressAt[lane]
					if at and now - at > 0.09 then
						Snd.pressAt[lane] = nil
						local rec = Snd.receptors[lane]
						if rec then rec:playcommand("Lift") end
					end
				end
			end

			local used = {}
			for lane = 1, 8 do used[lane] = 0 end
			for index = from, #list do
				local note = list[index]
				local y = CW_REC_Y + (note.t - elapsed) * Snd.PPS
				if y > CW_ENTER then break end
				-- an arrow that has arrived is gone: in the game it is the
				-- explosion that carries on from there, not the note
				if note.t >= elapsed then
				for lane = 1, Snd.lanes do
					if Snd.InLane(note, lane) then
						local slot = used[lane] + 1
						local arrow = Snd.notesAF[lane] and Snd.notesAF[lane][slot]
						local edge = Snd.edgeAF[lane] and Snd.edgeAF[lane][slot]
						local lift = Snd.liftsAF[lane] and Snd.liftsAF[lane][slot]
						local isLift = Snd.IsLift(note, lane)
						local x = Snd.LaneX(lane, CW_MID)
						-- The two share a slot, so whichever is not drawing
						-- has to be put away right here. Leaving it to the
						-- sweep below would be too late: that one clears from
						-- the last used slot on, and this slot is in use.
						if lift then lift:visible(false) end
						if isLift and lift then
							used[lane] = slot
							if arrow then arrow:visible(false) end
							lift:visible(true)
							lift:xy(x, y)
							-- No quantization slide. A skin draws its lift as one
							-- fixed frame of the very strip a tap is coloured out
							-- of, so sliding it would land on a neighbouring
							-- graphic -- and a lift has no colour of its own to
							-- go looking for anyway.
						elseif arrow then
							used[lane] = slot
							arrow:visible(true)
							arrow:xy(x, y)
							if Snd.skinNotes then
								-- the skin's own colour, by the skin's own
								-- means: slide the texture onto the right
								-- entry of its quantization strip
								arrow:texturetranslate(Snd.QuantSlide(note))
							else
								local tint = Snd.QuantColor(note)
								-- With no lift art to reach for, the arrow is
								-- drawn hollow instead: the body faded right
								-- back, the line around it left to carry the
								-- colour. It reads as the thing you let go of
								-- rather than the thing you press, which is the
								-- whole of the distinction.
								local body = isLift and 0.22 or 1
								arrow:diffuse(tint[1], tint[2], tint[3], body)
							end
						end
						if edge then
							-- the fallback arrow's inner line, white at every
							-- quantization -- except around a hollowed lift,
							-- where it is the only part left to carry one
							edge:visible(true)
							edge:xy(x, y)
							if isLift then
								local tint = Snd.QuantColor(note)
								edge:diffuse(tint[1], tint[2], tint[3], 1)
							else
								edge:diffuse(1, 1, 1, 0.93)
							end
						end
					end
				end
				end
			end
			for lane = 1, 8 do
				local pool, edges = Snd.notesAF[lane], Snd.edgeAF[lane]
				local lifts = Snd.liftsAF[lane]
				for slot = used[lane] + 1, Snd.LANE_POOL do
					if pool and pool[slot] then pool[slot]:visible(false) end
					if edges and edges[slot] then edges[slot]:visible(false) end
					if lifts and lifts[slot] then lifts[slot]:visible(false) end
				end
			end

			for i = 1, CW_EQ_N do
				local bar = Snd.winBars[i]
				if bar then
					local hgt = Snd.BarHeight(i, now)
					bar:setsize(math.max(1, CW_EQ_W - 2), hgt)
					bar:diffuse(accent)
					bar:diffusealpha(0.20 + 0.55 * (hgt / Snd.BAR_H))
				end
			end

			self:sleep(1/30):queuecommand("SMOChartPump")
		end,
	}

	detail[#detail+1] = chartWin

	ui[#ui+1] = detail
end
