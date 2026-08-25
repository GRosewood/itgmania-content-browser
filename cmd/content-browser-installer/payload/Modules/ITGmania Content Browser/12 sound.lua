-- -----------------------------------------------------------------------
-- Song previews and the chart preview
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

-- What this part uses from the parts before it. Everything named here was
-- set by a file that has already run; nothing here reaches forwards.
local CACHE_DIR        = CB.CACHE_DIR
local Clamp            = CB.Clamp
local HelperUrl        = CB.HelperUrl
local LoadHelperConfig = CB.LoadHelperConfig
local PlaySfx          = CB.PlaySfx
local Refresh          = CB.Refresh
local Toast            = CB.Toast
local state            = CB.state

-- A sample of a song, played from the pack's own audio.
--
-- The audio worth hearing is the audio the pack was charted against, and it is
-- already sitting in the zip on the download server -- which serves ranges, so
-- the helper can read the archive's directory, inflate one entry and drop it
-- next to us without pulling the other hundred megabytes. A representative
-- pack: 100 MB on the server, 4 MB pulled, about a second.
--
-- The window played is the one the pack's author chose: #SAMPLESTART and
-- #SAMPLELENGTH out of the simfile, the same fields the music wheel uses. So
-- this is the author's sample of the author's audio, not a guess at which
-- upload on some other site happens to be the same song.
--
-- The extraction has to live in the helper. There is no inflate anywhere in the
-- engine's Lua bindings, and RageFile:Write stops at the first NUL byte, so a
-- theme could not write an audio file even while holding one.
local Snd = {}

Snd.status  = "idle"  -- idle | loading | playing | failed
Snd.song    = nil     -- the song being previewed
Snd.message = nil     -- why it failed, when it did
Snd.actor   = nil     -- the ActorSound, once the tree exists
Snd.token   = 0       -- generation, so a late reply for an abandoned song is dropped
Snd.bpm     = 0       -- the song's tempo, so something on screen can move with it
Snd.startedAt = 0     -- when playback began, for both the beat and the run-out
Snd.len     = 0       -- how long the sample runs
Snd.prog    = nil     -- {phase, frac} while the helper is still fetching
Snd.index   = nil     -- which song in the list is playing, so the bars stay on it
Snd.bars    = {}      -- the equalizer bars, once the tree exists
Snd.charts  = nil     -- every difficulty of the song, from the helper
Snd.chartIdx = 0      -- which of them is being shown
Snd.notes   = nil     -- what that one does during the sample
Snd.lanes   = 0       -- 4 for a singles chart, 8 for a doubles one
Snd.known   = {}      -- song title -> the difficulties a preview already found
Snd.pick    = nil     -- the difficulty the popup is offering, while it is open
Snd.want    = nil     -- the difficulty this attempt was asked to open on
Snd.packId  = nil     -- which pack the playing song came from
Snd.polling = false   -- a progress poll is in flight
Snd.winFade = 0       -- the chart window's own fade, 0..1
Snd.LANE_POOL = 8     -- note actors per column; a jack at 16ths fills about six
Snd.HIT     = 0.085   -- how close to the moment a receptor counts as struck
-- A real read speed, so this reads like the game rather than like a
-- decoration. The numbers come out of how StepMania moves a note field: a
-- beat is 64 pixels, a C-mod scrolls as though the song were at that tempo,
-- and mini scales the whole field.
Snd.MINI    = 0.5
-- C550 at 50% mini is the reference -- what most people can actually read.
-- The window is a fraction of a real note field's height, and the same pixels
-- a second crossing a short frame reads faster than it does crossing a tall
-- one, so this sits below the reference rather than on it.
Snd.CMOD    = 516
Snd.ARROW   = 64 * Snd.MINI                   -- an arrow, at the size it plays
Snd.PPS     = 64 * Snd.CMOD / 60 * Snd.MINI   -- pixels a second
Snd.LEAD    = 1                               -- set from the window height
Snd.usingSkin = false -- whether the noteskin's own receptors loaded
Snd.skinNotes = false -- ...and its tap notes, which are coloured differently
Snd.edgeAF  = {}      -- the pale line inside the fallback arrow

-- How this noteskin turns a quantization into a colour.
--
-- Every ITG-style skin does it the same way and cel is no exception: the arrow
-- and a strip of eight colours live in one image, and the note is coloured by
-- sliding the texture coordinates along that strip. NoteDisplay reads these
-- three metrics and calls DISPLAY->TextureTranslate; Actor:texturetranslate is
-- the same call, so the preview can colour a note exactly as gameplay does
-- rather than approximating it with a tint.
--
-- Defaults are what nearly every skin sets, for the case where the metrics
-- cannot be read at all.
Snd.QSPACE_X = 0.03125
Snd.QSPACE_Y = 0
Snd.QCOUNT   = 8
Snd.fired   = {}      -- lane -> the last note index that struck it
Snd.pressAt = {}      -- lane -> when it was pressed, so it can be let go
Snd.bpmText = nil     -- the tempo as the pack lists it, for the preview
Snd.BARS    = 16
Snd.BAR_W   = 3
Snd.BAR_GAP = 2
Snd.BAR_H   = 15
Snd.PROG_W  = 118     -- the loading bar occupies the same corner as the bars

-- How tall bar i stands right now.
--
-- The engine hands Lua no spectrum -- RageSound exposes length, pitch, speed
-- and volume and nothing else, and the stock "visualizer" is a video file. What
-- it does hand over is the tempo out of the simfile, so the bars are driven by
-- the beat instead of by the waveform: the left of the bank lands on each beat
-- the way a low end does, the right flutters faster, and a slow wander keeps
-- neighbours from locking into the same shape. It is honestly a metronome
-- wearing an equalizer's coat, but it is a metronome set to the song.
function Snd.BarHeight(i, now)
	local elapsed = now - Snd.startedAt
	local bpm = Snd.bpm
	if not bpm or bpm <= 0 then bpm = 128 end   -- a pack that never said
	local beat = elapsed * bpm / 60
	local lowness = 1 - (i - 1) / math.max(1, Snd.BARS - 1)

	local hit = 1 - (beat % 1)
	hit = hit * hit                                     -- sharp attack, soft tail
	local flutter = 0.5 + 0.5 * math.sin(beat * 6.28318 * (0.8 + i * 0.45) + i * 1.7)
	local amount = lowness * hit + (1 - lowness) * flutter * 0.75
	amount = amount * (0.75 + 0.25 * math.sin(elapsed * 1.3 + i))

	return math.max(2, Snd.BAR_H * (0.12 + 0.88 * Clamp(amount, 0, 1)))
end

-- What the loading bar says while the helper works. The index read is the
-- indeterminate part -- how much of the archive has to be walked is not known
-- until it has been -- so that phase gets a moving block rather than a lie.
function Snd.ProgLabel()
	local p = Snd.prog
	if not p then return "loading sample...", -1 end
	if p.phase == "audio" then
		return "loading sample  " .. math.floor(Clamp(p.frac, 0, 1) * 100 + 0.5) .. "%", p.frac
	end
	if p.phase == "writing" then return "loading sample  100%", 1 end
	return "loading sample...", -1
end

-- A difficulty, as it would be written on the wheel.
function Snd.ChartLabel(chart)
	if not chart then return "" end
	local name = tostring(chart.diff or ""):upper()
	if name == "" then name = (chart.lanes == 8) and "DOUBLES" or "SINGLES" end
	local meter = tonumber(chart.meter) or 0
	if meter > 0 then return name .. "  " .. meter end
	return name
end

-- Show one of the difficulties the helper sent.
--
-- Switching costs nothing: every chart came back with the audio, because the
-- simfile had to be read either way and twenty seconds of one is a few
-- kilobytes. So this is a table lookup, not another request.
function Snd.SelectChart(index)
	local list = Snd.charts
	if not list or #list == 0 then
		Snd.chartIdx, Snd.notes, Snd.lanes = 0, nil, 0
		return
	end
	index = Clamp(index or 1, 1, #list)
	local chart = list[index]
	Snd.chartIdx = index
	Snd.lanes = tonumber(chart.lanes) or 0
	Snd.notes = (type(chart.notes) == "table" and #chart.notes > 0) and chart.notes or nil
	-- Let go of anything the last chart left held. The noteskin's Press is a
	-- pose it holds until Lift, and dropping the bookkeeping without playing
	-- Lift stranded a receptor lit for the rest of the preview.
	for lane, at in pairs(Snd.pressAt or {}) do
		local rec = at and Snd.receptors and Snd.receptors[lane]
		if rec then pcall(rec.playcommand, rec, "Lift") end
	end
	Snd.noteFrom, Snd.fired, Snd.pressAt = 1, {}, {}
end

-- Which difficulty to open on: Expert, always, where the song has one.
--
-- That is what the preview is for -- somebody deciding whether a pack is worth
-- downloading is looking at what it does at its hardest, and the other
-- difficulties are the exception rather than the default. A doubles-only pack
-- gets its Expert doubles chart, for the same reason.
--
-- Charts arrive easiest-first, singles before doubles.
function Snd.DefaultChart()
	return Snd.DefaultIn(Snd.charts or {})
end

-- The same question asked of a list that is not the one playing: what the
-- window will open on, worked out before the sample has arrived.
function Snd.DefaultIn(list)
	local function expert(lanes)
		for index, chart in ipairs(list) do
			local name = tostring(chart.diff or ""):lower()
			if (name == "challenge" or name == "expert")
			   and tonumber(chart.lanes) == lanes then
				return index
			end
		end
		return 0
	end
	-- Expert singles, then Expert doubles, then the hardest of whichever the
	-- song has: charts are sorted easiest-first, so the last is the hardest.
	local at = expert(4)
	if at > 0 then return at end
	at = expert(8)
	if at > 0 then return at end
	local best = 0
	for index, chart in ipairs(list) do
		if tonumber(chart.lanes) == 4 then best = index end
	end
	if best > 0 then return best end
	return math.max(1, #list)
end

-- The charts a preview of this song already turned up, if any.
function Snd.KnownNow()
	local key = Snd.KnownKey(Snd.packId, Snd.song)
	return key and Snd.known[key] or nil
end

-- What a song's known charts are filed under. A title on its own is not
-- enough: "Vertex" or "Dance Dance Revolution" appear in a dozen packs, and
-- they are not the same song.
function Snd.KnownKey(packId, title)
	if not (packId and title and title ~= "") then return nil end
	return tostring(packId) .. "\\0" .. tostring(title)
end

-- The difficulties the popup can offer for a song: whatever a preview of it
-- has already turned up. Nothing before the first play -- the simfile lives
-- inside the pack, and reading it is the fetch itself.
function Snd.KnownFor(song, pack)
	local title = type(song) == "table" and song.title or nil
	local key = Snd.KnownKey(pack and pack.id, title)
	return key and Snd.known[key] or nil
end

-- Move the popup's difficulty along, wrapping at the ends.
function Snd.Cycle(song, pack, delta)
	local list = Snd.KnownFor(song, pack)
	if not list or #list < 2 then return false end
	local at = (Snd.pick or 0)
	if at < 1 then
		-- start from what a preview would open on
		local was = Snd.charts
		Snd.charts = list
		at = Snd.DefaultChart()
		Snd.charts = was
	end
	Snd.pick = ((at - 1 + delta) % #list) + 1
	return true
end

-- The colour the wheel gives a difficulty, so the row of them reads the way
-- the song wheel does rather than as six identical boxes.
Snd.DIFF_COLOR = {
	beginner  = { 0.35, 0.65, 0.95 },
	easy      = { 0.95, 0.85, 0.30 },
	medium    = { 0.95, 0.35, 0.40 },
	hard      = { 0.35, 0.85, 0.45 },
	challenge = { 0.70, 0.45, 0.95 },
	edit      = { 0.70, 0.70, 0.70 },
}
function Snd.DiffColor(chart)
	local name = chart and tostring(chart.diff or ""):lower() or ""
	return Snd.DIFF_COLOR[name] or { 0.70, 0.70, 0.70 }
end

-- Move along the difficulties the helper sent for this song. Nothing is
-- fetched: they all came back with the audio.
function Snd.Step(delta)
	local list = Snd.charts
	if not list or #list < 2 then return false end
	local at = Clamp(Snd.chartIdx, 1, #list) + delta
	if at < 1 or at > #list then return false end
	Snd.SelectChart(at)
	return true
end

-- Is the chart window on screen?
--
-- Asked of the charts, not of the notes. A difficulty can be real and have
-- nothing inside the twenty seconds being sampled -- a Beginner chart under an
-- intro does it every time -- and treating that as "no chart window" tore the
-- window and its difficulty selector off the screen mid-preview, with no way
-- back to the difficulty that did have steps. The window stays; it says the
-- chart is quiet here.
function Snd.ChartOn()
	return Snd.status == "playing" and Snd.charts ~= nil and Snd.lanes > 0
end

-- Is the window on screen at all?
--
-- It opens when the sample is asked for rather than when the notes arrive.
-- Fetching one takes a few seconds -- the helper has to reach into a pack
-- archive over the network -- and all that said so was one small line above
-- the song list, which is not where the reader is looking after pressing a
-- button called Preview.
function Snd.WindowOn()
	return Snd.status == "loading" or Snd.ChartOn()
end

-- The first note not yet gone past, so neither the drawing nor the flashes
-- have to walk the notes already played. It only ever moves forward, which is
-- what makes this thirty-times-a-second work cost the same at the end of a
-- sample as at the start.
function Snd.NoteFrom(now)
	local list = Snd.notes
	if not list then return 1 end
	local elapsed = now - Snd.startedAt
	local from = Snd.noteFrom or 1
	while list[from] and (elapsed - list[from].t) > Snd.HIT do
		from = from + 1
	end
	Snd.noteFrom = from
	return from
end

-- Does this note occupy that column? Lua 5.1 has no bitwise operators and the
-- mask is eight bits at the most, so this is arithmetic rather than a library.
function Snd.InLane(note, lane)
	return math.floor(note.c / (2 ^ (lane - 1))) % 2 == 1
end

-- Where a column sits, for a field of however many columns there are. The
-- arrows are the width of the column, edge to edge, the way a note field is
-- -- doubles is the same four directions twice over, which is what the pad is.
--
-- over says how many to lay out for, which is not always how many there are:
-- while a sample is loading there are none yet, and the empty field drawn
-- under the spinner has to be laid out for the four it is about to have or the
-- receptors appear off to one side and slide across when the notes arrive.
function Snd.LaneX(lane, middle, over)
	local lanes = math.max(1, over or Snd.lanes)
	return middle - (lanes - 1) * Snd.ARROW/2 + (lane - 1) * Snd.ARROW
end
-- for the fallback arrow, which is drawn pointing up and turned
function Snd.LaneRot(lane)
	local turn = { -90, 180, 0, 90 }   -- left, down, up, right
	return turn[((lane - 1) % 4) + 1]
end

-- An arrow's colour says where in the beat it falls, which is how every
-- StepMania screen has ever drawn one: a run of red quarters reads as slow and
-- a wall of green reads as a burst, before you have counted anything.
--
-- These are cel's own quantization colours, read out of its texture: the left
-- half of the image is the arrow in greyscale, and to the right is a strip of
-- eight solid colours, one per quantization, which the engine slides the
-- body's texture coordinates along. The preview does the same with the real
-- skin via Actor:texturetranslate; this table is for the own-art FALLBACK,
-- when the skin will not load, so even that arrow is the colour it would be
-- in a song.
--
-- They are not quite the palette other skins use -- cel's fourths are a red
-- orange rather than red, its sixteenths green, its thirty-seconds gold -- and
-- matching cel is the point.
Snd.QUANT = {
	{ 0.933, 0.420, 0.129 },   -- 4th
	{ 0.000, 0.506, 1.000 },   -- 8th
	{ 0.725, 0.294, 0.910 },   -- 12th
	{ 0.451, 0.804, 0.204 },   -- 16th
	{ 0.725, 0.294, 0.910 },   -- 24th
	{ 0.929, 0.725, 0.012 },   -- 32nd
	{ 0.725, 0.294, 0.910 },   -- 48th
	{ 0.102, 0.851, 0.600 },   -- 64th
	{ 0.725, 0.294, 0.910 },   -- anything finer
}

function Snd.QuantColor(note)
	local q = (tonumber(note.q) or 8) + 1
	return Snd.QUANT[q] or Snd.QUANT[9]
end

-- Read the three metrics off the noteskin, once, when the window is built.
function Snd.ReadQuant(skin)
	if not skin then return end
	local function metric(fn, name, dflt)
		local ok, v = pcall(fn, NOTESKIN, "Left", name, skin)
		if ok and type(v) == "number" then return v end
		return dflt
	end
	Snd.QSPACE_X = metric(NOTESKIN.GetMetricFForNoteSkin,
		"TapNoteNoteColorTextureCoordSpacingX", 0.03125)
	Snd.QSPACE_Y = metric(NOTESKIN.GetMetricFForNoteSkin,
		"TapNoteNoteColorTextureCoordSpacingY", 0)
	local n = metric(NOTESKIN.GetMetricIForNoteSkin, "TapNoteNoteColorCount", 8)
	Snd.QCOUNT = (n and n > 0) and math.floor(n) or 8
end

-- Where along that strip a note of this quantization sits.
--
-- NoteDisplay clamps to the last colour the skin has, so a 192nd on a skin
-- with eight lands on the eighth rather than off the end of the image.
function Snd.QuantSlide(note)
	local q = math.floor(tonumber(note.q) or 0)
	q = Clamp(q, 0, Snd.QCOUNT - 1)
	return Snd.QSPACE_X * q, Snd.QSPACE_Y * q
end


-- Is a receptor being struck this instant? Anything within a beat's grace of
-- the moment counts, which is what makes the flash read as a hit rather than
-- as a flicker.
function Snd.Struck(lane, now)
	local list = Snd.notes
	if not list then return 0 end
	local elapsed = now - Snd.startedAt
	for index = Snd.noteFrom or 1, #list do
		local note = list[index]
		local gap = elapsed - note.t
		if gap < 0 then break end
		if gap < Snd.HIT and Snd.InLane(note, lane) then
			return 1 - gap / Snd.HIT
		end
	end
	return 0
end

function Snd.Busy()
	return Snd.status == "playing" or Snd.status == "loading"
end

function Snd.Stop(quiet)
	Snd.token = Snd.token + 1
	if Snd.actor then Snd.actor:stop() end
	local was = Snd.status
	-- stopping early hands the music back early too
	if was == "playing" then SOUND:DimMusic(1, 0) end
	Snd.status, Snd.song, Snd.message = "idle", nil, nil
	Snd.prog, Snd.bpm, Snd.len, Snd.startedAt = nil, 0, 0, 0
	Snd.notes, Snd.lanes, Snd.noteFrom = nil, 0, 1
	Snd.charts, Snd.chartIdx = nil, 0
	Snd.want, Snd.packId, Snd.polling = nil, nil, false
	Snd.fired, Snd.pressAt, Snd.bpmText = {}, {}, nil
	Snd.index = nil
	if was ~= "idle" and not quiet then Refresh() end
end

-- what the song-list header says about the preview, if anything
function Snd.Label()
	if Snd.status == "loading" then return (Snd.ProgLabel()) end
	if Snd.status == "playing" then return "playing a sample" end
	if Snd.status == "failed" then return Snd.message end
	return nil
end

-- The sample and the notes come from the same window of the same file, so
-- the only thing needed to line them up is when playback started. There is
-- no feedback from the sound -- RageSound will not say where it is -- so
-- startedAt is the clock the audio was started against, which holds for the
-- twenty seconds that matter and would not for a song.
function Snd.Begin(sample)
	local name = type(sample) == "table" and tostring(sample.name or "") or ""
	if not Snd.actor or name == "" then
		Snd.status = "failed"
		Snd.message = Snd.actor and "nothing came back" or "no audio output"
		return
	end
	Snd.actor:stop()
	-- The engine addresses files through its own filesystem, where the cache
	-- is mounted at /Cache wherever it physically lives; the helper's absolute
	-- path would mean nothing to it. The helper extracts into the same folder
	-- by its OS path, so the two meet in the middle.
	Snd.actor:load(CACHE_DIR .. "previews/" .. name)
	local sound = Snd.actor:get()
	if sound then
		local from = tonumber(sample.start) or 0
		local len  = tonumber(sample.length) or 0
		-- a pack that never declared a sample still gets one: a little way in,
		-- which is where a song has usually started doing something
		if len <= 0 then from, len = math.max(from, 20), 20 end
		Snd.len = len
		-- A song that ships its own preview clip sends that clip rather than
		-- the whole song, and a clip starts at its beginning: seeking into it
		-- by the sample offset would skip past most of the thing the author cut
		-- for exactly this. The note window is still the one the simfile
		-- declared, which is the stretch such a clip is normally taken from.
		if sample.preview then from = 0 end
		sound:SetParam("StartSecond", from)
		sound:SetParam("LengthSeconds", len)
		sound:SetParam("FadeInSeconds", 0.5)
		sound:SetParam("FadeSeconds", 1.5)
		-- take the theme music down for as long as the sample runs; it comes
		-- back on its own, so nothing stays muted if the player wanders off
		SOUND:DimMusic(0, len + 1.5)
	end
	Snd.actor:play()
	Snd.status = "playing"
	Snd.prog = nil
	Snd.bpm = tonumber(sample.bpm) or 0
	-- The helper sends every difficulty of the song when it could read them.
	-- An older helper sends nothing, and the window simply does not appear --
	-- the sample still plays, which is what it was always for.
	Snd.charts = nil
	if type(sample.charts) == "table" and #sample.charts > 0 then
		Snd.charts = sample.charts
		-- Kept so the popup can offer the same difficulties next time without
		-- playing anything first, against the pack as well as the song: pack
		-- names are unique but song titles are not, and two packs holding a
		-- song of the same name would otherwise share one list of charts.
		local key = Snd.KnownKey(Snd.packId, Snd.song)
		if key then Snd.known[key] = sample.charts end
	end
	Snd.SelectChart(Snd.want or Snd.DefaultChart())
	Snd.want = nil
	Snd.startedAt = GetTimeSinceStart()
end

-- What the helper is doing right now, if anything. Deliberately quiet: a poll
-- that failed is not worth a message, and a poll that lands after the fetch
-- finished must not resurrect a bar over a sample that is already playing.
function Snd.Poll()
	if Snd.status ~= "loading" then return end
	-- One at a time.
	--
	-- The engine runs one request at a time in the order they were asked for,
	-- and the thing this is asking about is the fetch sitting in front of it.
	-- Firing another every 0.4s only lengthens the queue the answer has to
	-- come through -- a twenty-second extraction used to leave a backlog of
	-- polls to drain before anything else could be asked for at all.
	if Snd.polling then return end
	local h = state.helper
	if not h.config then return end
	local url = HelperUrl("/preview/progress")
	if not NETWORK:IsUrlAllowed(url) then return end
	local mine = Snd.token
	Snd.polling = true
	NETWORK:HttpRequest{
		url = url,
		headers = { ["X-Browser-Token"] = h.config.token },
		connectTimeout = 2,
		transferTimeout = 4,
		onResponse = function(response)
			Snd.polling = false
			if mine ~= Snd.token or Snd.status ~= "loading" then return end
			if response.error ~= nil then return end
			local ok, data = pcall(JsonDecode, response.body or "")
			if not ok or type(data) ~= "table" then return end
			local p = data.progress
			if type(p) == "table" and p.active then
				Snd.prog = { phase = tostring(p.phase or ""), frac = tonumber(p.frac) or -1 }
			end
		end,
	}
end

-- Play a sample of one song. Asking again for the song already playing stops it.
function Snd.Play(pack, song)
	local title = type(song) == "table" and song.title or nil
	local id = pack and tonumber(pack.id)
	if not (id and title and title ~= "") then
		PlaySfx("invalid")
		return
	end
	local h = state.helper
	if not h.config then h.config = LoadHelperConfig() end
	if not h.config then
		PlaySfx("invalid")
		Toast("song samples need the content browser helper installed")
		return
	end
	local url = HelperUrl("/preview")
	if not NETWORK:IsUrlAllowed(url) then
		PlaySfx("invalid")
		Toast("127.0.0.1 is missing from HttpAllowHosts")
		return
	end

	Snd.Stop(true)
	PlaySfx("start")
	Snd.token = Snd.token + 1
	local mine = Snd.token
	-- The popup's chosen difficulty belongs to this attempt. Taken here rather
	-- than in Begin so a preview that never arrives cannot leave it lying
	-- about for the next song.
	Snd.want, Snd.pick = Snd.pick, nil
	Snd.status, Snd.song, Snd.message = "loading", title, nil
	-- the pack it came from, so its charts are remembered against both
	Snd.packId = id
	-- the pack's own tempo text, which says "146-741" where a number cannot
	Snd.bpmText = (type(song) == "table" and song.bpm ~= "" ) and song.bpm or nil
	Snd.index = state.songPick
	Snd.prog = nil
	-- leave the fetch a clear run at the network before asking after it
	Snd.pollAt = GetTimeSinceStart() + 0.6
	Refresh()

	NETWORK:HttpRequest{
		url = url,
		method = "POST",
		body = JsonEncode({ pack = id, song = title }),
		headers = {
			["X-Browser-Token"] = h.config.token,
			["Content-Type"]    = "application/json",
		},
		connectTimeout = 5,
		transferTimeout = 90,
		onResponse = function(response)
			-- the player asked for something else, or left
			if mine ~= Snd.token then return end
			if response.error ~= nil then
				Snd.status, Snd.message = "failed", "the helper is not running"
			else
				local ok, data = pcall(JsonDecode, response.body or "")
				if not ok or type(data) ~= "table" then
					Snd.status, Snd.message = "failed", "the helper sent something unreadable"
				elseif not data.ok then
					Snd.status, Snd.message = "failed", tostring(data.error or "no sample for this song")
				else
					Snd.Begin(data.sample)
				end
			end
			Refresh()
		end,
	}
end

-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.Snd = Snd
