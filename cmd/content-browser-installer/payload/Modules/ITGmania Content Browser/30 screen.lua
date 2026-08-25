-- -----------------------------------------------------------------------
-- The browser screen, and the order its pieces go together in
--
-- Everything the player sees when Find Content opens is built here, but
-- nothing is built here: each piece lives in its own file and this says what
-- order they are put together in. Read it as a contents page for the seventeen
-- files that follow.
--
-- Two orders matter and they are not the same one.
--
-- The order things are BUILT in is the order of the lines below, and it
-- matters because a piece cannot be handed to another before it exists --
-- the info pane has to be built before the detail page, which wants a
-- constant from it.
--
-- The order things are ADDED in is the order an ActorFrame draws its
-- children, first to last, so the last thing added is the thing on top.
-- That is why the pack list, the info pane and the detail page are built
-- early but added late: they have to be drawn over the tabs, the featured
-- grid and the views behind them. A piece that is only built returns its
-- frame; a piece that adds itself takes the container to add itself to.
--
-- One part of the ITGMania Content Browser. The entry file beside this
-- folder lists every part in the order they load, and says what each is for.
-- -----------------------------------------------------------------------

local CB = ...

local function BrowserActor()
	-- The outermost frame, and the four actors on it that draw nothing: the
	-- sound the previews play through, the heartbeat that keeps download
	-- progress moving, the settle timer that holds a tab's fetches until the
	-- tab row stops, and the watcher that reclaims input when the search's
	-- text entry closes.
	local af = CB.Screen.Frame()
	CB.Screen.HiddenHelpers(af)

	-- Everything visible hangs from this one, so that typing a search can
	-- hide the lot with a single flag.
	local ui = CB.Screen.Container()

	-- Drawn first, so everything else lands on top.
	CB.Screen.DownloadTicker(ui)
	CB.Screen.Tabs(ui)
	CB.Screen.FeaturedGrid(ui)

	-- Built now, added further down: these three are the foreground.
	local listAF = CB.Screen.PackRows()
	local pane, HIST_MAX_BARS = CB.Screen.InfoPane()
	local detail = CB.Screen.DetailPage(HIST_MAX_BARS)

	-- The views that take the featured grid's place, each hiding itself
	-- unless its own tab is the one showing.
	CB.Screen.ContextBand(ui)
	CB.Screen.YearPicker(ui)
	CB.Screen.InstalledView(ui)
	CB.Screen.DoublesView(ui)

	-- The hints along the bottom, and then the list and its pane on top of
	-- everything added so far.
	CB.Screen.FooterHints(ui, listAF, pane)

	-- The chart preview belongs to the detail page, and puts the detail page
	-- itself on last -- it covers the whole screen when it is open.
	CB.Screen.ChartWindow(ui, detail)

	-- Above the browser rather than inside it: a dialog has to cover the
	-- screen it is asking about, and a toast has to be readable over both.
	CB.Screen.Dialogs(af, ui)
	CB.Screen.Toast(af)

	return af
end

-- -----------------------------------------------------------------------
-- What the parts after this one use.

CB.BrowserActor = BrowserActor
