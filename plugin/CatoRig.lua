--[[
	════════════════════════════════════════════════════════════════
	  CatoRig
	  Roblox Studio plugin — browse the avatar catalog, customize a
	  body, insert a finished R6/R15 rig into the workspace.

	  EXE Development
	════════════════════════════════════════════════════════════════

	INSTALL
	  1. Create a Script anywhere in Studio (e.g. in ServerStorage).
	  2. Paste this whole file into it.
	  3. Right-click the script in the Explorer → Save as Local Plugin.
	  4. Delete the script from your place — the saved plugin file
	     (in your Plugins folder) is what Studio actually runs.

	NOTES ON THE CATALOG API
	  Roblox blocks HttpService from reaching *.roblox.com — from plugins
	  and games alike. So item search doesn't hit catalog.roblox.com
	  directly; it goes through a small proxy (see catorig-proxy/server.js)
	  that runs outside Roblox's sandbox and relays the request. Set
	  CFG.ProxyBaseUrl below to wherever that proxy is running — a
	  localhost address while you're building, a deployed URL once you
	  want CatoRig to work without your machine running the proxy.

	  The Category/Subcategory pairs in CFG.Categories match the current
	  official docs (create.roblox.com/docs/en-us/projects/assets/api).
	  If a tab ever comes back empty, that's the first thing to re-check.
	  Thumbnails don't depend on any of this — they're loaded via the
	  rbxthumb:// URI scheme, which talks to Roblox's CDN directly and
	  isn't affected by the roblox.com HttpService block.
--]]

--// SERVICES ///-----------------------------------------------------

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

--// TYPES ///---------------------------------------------------------

type CategoryDef = {
	Name: string,
	Field: string,       -- HumanoidDescription property this category fills
	Category: number,    -- catalog "Category" query param
	Sub: number,          -- catalog "Subcategory" query param
	Multi: boolean,       -- true = comma-joined list (accessories), false = single id
}

type CatalogItem = {
	AssetId: number,
	Name: string,
	Price: number?,
}

type Filters = {
	Keyword: string,
	SortType: number,
	SortAggregation: number,
	Genre: number?,
	MinPrice: number?,
	MaxPrice: number?,
}

--// CFG ///------------------------------------------------------------

local CFG = {

	-- Point this at wherever catorig-proxy/server.js is running.
	-- "http://localhost:3000" while you're running it yourself for dev;
	-- swap in a deployed URL once it's hosted somewhere real.
	ProxyBaseUrl = "http://localhost:3000",

	Theme = {
		Background = Color3.fromRGB(10, 10, 10),
		Panel      = Color3.fromRGB(16, 16, 16),
		Line       = Color3.fromRGB(44, 44, 44),
		White      = Color3.fromRGB(255, 255, 255),
		Gray       = Color3.fromRGB(140, 140, 140),
		DimGray    = Color3.fromRGB(85, 85, 85),
	},

	-- Category = 1 ("All") is used everywhere below rather than trying to
	-- pin the exact parent category per subcategory — Subcategory alone
	-- narrows the search, and Category=1 is guaranteed compatible with
	-- every Subcategory value per the official docs.
	Categories = {
		{ Name = "Hats",       Field = "HatAccessory",      Category = 1, Sub = 9,  Multi = true  },
		{ Name = "Hair",       Field = "HairAccessory",     Category = 1, Sub = 20, Multi = true  },
		{ Name = "Faces",      Field = "Face",              Category = 1, Sub = 10, Multi = false },
		{ Name = "Face Acc.",  Field = "FaceAccessory",     Category = 1, Sub = 21, Multi = true  },
		{ Name = "Neck",       Field = "NeckAccessory",     Category = 1, Sub = 22, Multi = true  },
		{ Name = "Shoulder",   Field = "ShoulderAccessory", Category = 1, Sub = 23, Multi = true  },
		{ Name = "Front",      Field = "FrontAccessory",    Category = 1, Sub = 24, Multi = true  },
		{ Name = "Back",       Field = "BackAccessory",     Category = 1, Sub = 25, Multi = true  },
		{ Name = "Waist",      Field = "WaistAccessory",    Category = 1, Sub = 26, Multi = true  },
		{ Name = "Shirts",     Field = "Shirt",             Category = 1, Sub = 12, Multi = false },
		{ Name = "Pants",      Field = "Pants",             Category = 1, Sub = 14, Multi = false },
		{ Name = "T-Shirts",   Field = "GraphicTShirt",     Category = 1, Sub = 13, Multi = false },
	} :: { CategoryDef },

	SortOptions = {
		{ Name = "Relevance", SortType = 0, SortAggregation = 5 },
		{ Name = "Favorites", SortType = 1, SortAggregation = 5 },
		{ Name = "Sales",     SortType = 2, SortAggregation = 5 },
		{ Name = "Updated",   SortType = 3, SortAggregation = 5 },
		{ Name = "Price ↑",   SortType = 4, SortAggregation = 5 },
		{ Name = "Price ↓",   SortType = 5, SortAggregation = 5 },
	},

	Genres = {
		{ Name = "All Genres", Id = nil },
		{ Name = "Town & City", Id = 1 },
		{ Name = "Medieval",    Id = 2 },
		{ Name = "Sci-Fi",      Id = 3 },
		{ Name = "Fighting",    Id = 4 },
		{ Name = "Horror",      Id = 5 },
		{ Name = "Naval",       Id = 6 },
		{ Name = "Adventure",   Id = 7 },
		{ Name = "Sports",      Id = 8 },
		{ Name = "Comedy",      Id = 9 },
		{ Name = "Western",     Id = 10 },
		{ Name = "Military",    Id = 11 },
	},

	Sliders = {
		{ Name = "Height",    Field = "HeightScale",     Min = 0.9, Max = 1.05, Default = 1.0 },
		{ Name = "Width",     Field = "WidthScale",      Min = 0.7, Max = 1.0,  Default = 1.0 },
		{ Name = "Head",      Field = "HeadScale",       Min = 0.95, Max = 1.0, Default = 1.0 },
		{ Name = "Body Type", Field = "BodyTypeScale",   Min = 0.0, Max = 1.0,  Default = 0.0 },
	},

	ItemLimit = 30,
}

--// STATE ///----------------------------------------------------------

local State = {
	ActiveCategoryIndex = 1,
	Selected = {} :: { [string]: any }, -- Field -> assetId (single) or {[assetId]=true} (multi)
	RigType = Enum.HumanoidRigType.R15,
	SliderValues = {} :: { [string]: number },
	SortIndex = 1,
	GenreIndex = 1,
	Keyword = "",
}

for _, s in CFG.Sliders do
	State.SliderValues[s.Field] = s.Default
end

--// CATALOG FETCH ///---------------------------------------------------

local function buildCatalogUrl(def: CategoryDef, filters: Filters): string
	local params = {
		Category = def.Category,
		Subcategory = def.Sub,
		Limit = CFG.ItemLimit,
		SortType = filters.SortType,
		SortAggregation = filters.SortAggregation,
	}
	if filters.Keyword ~= "" then
		params.Keyword = HttpService:UrlEncode(filters.Keyword)
	end
	if filters.Genre then
		params.Genres = filters.Genre
	end
	if filters.MinPrice then
		params.MinPrice = filters.MinPrice
	end
	if filters.MaxPrice then
		params.MaxPrice = filters.MaxPrice
	end

	local parts = {}
	for k, v in pairs(params) do
		table.insert(parts, k .. "=" .. tostring(v))
	end
	return CFG.ProxyBaseUrl .. "/catalog?" .. table.concat(parts, "&")
end

local function fetchCategory(def: CategoryDef, filters: Filters): ({ CatalogItem }, string?)
	local url = buildCatalogUrl(def, filters)

	local ok, response = pcall(function()
		return HttpService:RequestAsync({ Url = url, Method = "GET" })
	end)

	if not ok then
		local msg = "request errored — " .. tostring(response)
		warn("[CatoRig] " .. msg .. " (" .. url .. ")")
		return {}, msg
	end
	if not response.Success then
		local msg = ("HTTP %d from catalog"):format(response.StatusCode)
		warn("[CatoRig] " .. msg .. " — " .. url .. " — body: " .. tostring(response.Body):sub(1, 300))
		return {}, msg
	end

	local decodeOk, body = pcall(HttpService.JSONDecode, HttpService, response.Body)
	if not decodeOk or not body then
		warn("[CatoRig] bad JSON from catalog — " .. url)
		return {}, "couldn't parse the response — see Output"
	end
	if not body.data then
		warn("[CatoRig] no 'data' field — " .. url .. " — body: " .. tostring(response.Body):sub(1, 300))
		return {}, "unexpected response shape — see Output"
	end

	local items = {}
	for _, entry in body.data do
		table.insert(items, {
			AssetId = entry.id,
			Name = entry.name,
			Price = entry.price,
		})
	end
	return items, nil
end

--// UI BUILD ///---------------------------------------------------------

local toolbar = plugin:CreateToolbar("EXE Development")
local toggleButton = toolbar:CreateButton("CatoRig", "Open CatoRig", "rbxassetid://0")
toggleButton.ClickableWhenViewportHidden = true

local widget = plugin:CreateDockWidgetPluginGui(
	"CatoRig",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, false, 720, 480, 560, 380)
)
widget.Title = "CatoRig"

toggleButton.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)

local function mk(class: string, props: { [string]: any }, parent: Instance?): Instance
	local inst = Instance.new(class)
	for k, v in props do
		(inst :: any)[k] = v
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local Theme = CFG.Theme

local root = mk("Frame", {
	Name = "Root",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Theme.Background,
	BorderSizePixel = 0,
}, widget)

-- left column: category tabs + filters
local leftCol = mk("Frame", {
	Size = UDim2.new(0, 150, 1, 0),
	BackgroundColor3 = Theme.Panel,
	BorderSizePixel = 0,
}, root)
mk("UIListLayout", { Padding = UDim.new(0, 0), SortOrder = Enum.SortOrder.LayoutOrder }, leftCol)
mk("Frame", { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = Theme.Line, BorderSizePixel = 0 }, leftCol)

local tabButtons = {}
for i, def in CFG.Categories do
	local btn = mk("TextButton", {
		Name = def.Name,
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundColor3 = Theme.Panel,
		BorderSizePixel = 0,
		Font = Enum.Font.Code,
		Text = def.Name,
		TextSize = 13,
		TextColor3 = i == 1 and Theme.White or Theme.Gray,
		LayoutOrder = i,
	}, leftCol)
	tabButtons[i] = btn
end

-- filter panel under the tabs
local filterPanel = mk("Frame", {
	Size = UDim2.new(1, 0, 0, 150),
	BackgroundColor3 = Theme.Panel,
	BorderSizePixel = 0,
	LayoutOrder = #CFG.Categories + 1,
}, leftCol)
mk("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, filterPanel)
mk("UIPadding", {
	PaddingTop = UDim.new(0, 12), PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10),
}, filterPanel)

local searchBox = mk("TextBox", {
	Size = UDim2.new(1, 0, 0, 24),
	BackgroundColor3 = Theme.Background,
	BorderColor3 = Theme.Line,
	BorderSizePixel = 1,
	Font = Enum.Font.Code,
	PlaceholderText = "search…",
	Text = "",
	TextSize = 12,
	TextColor3 = Theme.White,
	PlaceholderColor3 = Theme.DimGray,
	ClearTextOnFocus = false,
	LayoutOrder = 1,
}, filterPanel)

local sortButton = mk("TextButton", {
	Size = UDim2.new(1, 0, 0, 22),
	BackgroundColor3 = Theme.Background,
	BorderColor3 = Theme.Line,
	BorderSizePixel = 1,
	Font = Enum.Font.Code,
	Text = "Sort: " .. CFG.SortOptions[1].Name,
	TextSize = 11,
	TextColor3 = Theme.Gray,
	LayoutOrder = 2,
}, filterPanel)

local genreButton = mk("TextButton", {
	Size = UDim2.new(1, 0, 0, 22),
	BackgroundColor3 = Theme.Background,
	BorderColor3 = Theme.Line,
	BorderSizePixel = 1,
	Font = Enum.Font.Code,
	Text = CFG.Genres[1].Name,
	TextSize = 11,
	TextColor3 = Theme.Gray,
	LayoutOrder = 3,
}, filterPanel)

local priceRow = mk("Frame", {
	Size = UDim2.new(1, 0, 0, 22),
	BackgroundTransparency = 1,
	LayoutOrder = 4,
}, filterPanel)
mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }, priceRow)

local minPriceBox = mk("TextBox", {
	Size = UDim2.new(0.5, -3, 1, 0),
	BackgroundColor3 = Theme.Background,
	BorderColor3 = Theme.Line,
	BorderSizePixel = 1,
	Font = Enum.Font.Code,
	PlaceholderText = "min",
	Text = "",
	TextSize = 11,
	TextColor3 = Theme.White,
	PlaceholderColor3 = Theme.DimGray,
}, priceRow)

local maxPriceBox = mk("TextBox", {
	Size = UDim2.new(0.5, -3, 1, 0),
	BackgroundColor3 = Theme.Background,
	BorderColor3 = Theme.Line,
	BorderSizePixel = 1,
	Font = Enum.Font.Code,
	PlaceholderText = "max",
	Text = "",
	TextSize = 11,
	TextColor3 = Theme.White,
	PlaceholderColor3 = Theme.DimGray,
}, priceRow)

-- right side: grid + bottom bar
local rightCol = mk("Frame", {
	Size = UDim2.new(1, -150, 1, 0),
	Position = UDim2.new(0, 150, 0, 0),
	BackgroundColor3 = Theme.Background,
	BorderSizePixel = 0,
}, root)

local grid = mk("ScrollingFrame", {
	Size = UDim2.new(1, 0, 1, -140),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = Theme.Line,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, rightCol)
mk("UIPadding", {
	PaddingTop = UDim.new(0, 10), PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10),
}, grid)
local gridLayout = mk("UIGridLayout", {
	CellSize = UDim2.new(0, 90, 0, 110),
	CellPadding = UDim2.new(0, 8, 0, 8),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, grid)

local statusLabel = mk("TextLabel", {
	Size = UDim2.new(1, -20, 0, 20),
	Position = UDim2.new(0, 10, 0, 4),
	BackgroundTransparency = 1,
	Font = Enum.Font.Code,
	Text = "",
	TextSize = 11,
	TextColor3 = Theme.DimGray,
	TextXAlignment = Enum.TextXAlignment.Left,
}, rightCol)

-- bottom bar: rig toggle, sliders, insert button
local bottomBar = mk("Frame", {
	Size = UDim2.new(1, 0, 0, 140),
	Position = UDim2.new(0, 0, 1, -140),
	BackgroundColor3 = Theme.Panel,
	BorderSizePixel = 0,
}, rightCol)
mk("Frame", { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = Theme.Line, BorderSizePixel = 0 }, bottomBar)
mk("UIPadding", {
	PaddingTop = UDim.new(0, 12), PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14),
}, bottomBar)

local rigToggleRow = mk("Frame", {
	Size = UDim2.new(0, 120, 0, 24),
	BackgroundTransparency = 1,
}, bottomBar)
mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 0) }, rigToggleRow)

local r15Button = mk("TextButton", {
	Size = UDim2.new(0, 60, 1, 0),
	BackgroundColor3 = Theme.White,
	BorderColor3 = Theme.Line,
	BorderSizePixel = 1,
	Font = Enum.Font.Code,
	Text = "R15",
	TextSize = 12,
	TextColor3 = Theme.Background,
}, rigToggleRow)

local r6Button = mk("TextButton", {
	Size = UDim2.new(0, 60, 1, 0),
	BackgroundColor3 = Theme.Background,
	BorderColor3 = Theme.Line,
	BorderSizePixel = 1,
	Font = Enum.Font.Code,
	Text = "R6",
	TextSize = 12,
	TextColor3 = Theme.Gray,
}, rigToggleRow)

local slidersRow = mk("Frame", {
	Size = UDim2.new(1, -260, 0, 90),
	Position = UDim2.new(0, 0, 0, 34),
	BackgroundTransparency = 1,
}, bottomBar)
mk("UIGridLayout", {
	CellSize = UDim2.new(0.5, -8, 0, 40),
	CellPadding = UDim2.new(0, 16, 0, 6),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, slidersRow)

local insertButton = mk("TextButton", {
	Size = UDim2.new(0, 160, 0, 40),
	Position = UDim2.new(1, -160, 1, -40),
	AnchorPoint = Vector2.new(0, 0),
	BackgroundColor3 = Theme.White,
	BorderSizePixel = 0,
	Font = Enum.Font.Code,
	Text = "INSERT RIG",
	TextSize = 13,
	TextColor3 = Theme.Background,
}, bottomBar)
insertButton.Position = UDim2.new(1, -160, 1, -40)

--// SLIDERS ///-------------------------------------------------------------

local function buildSlider(def, layoutOrder: number)
	local container = mk("Frame", { BackgroundTransparency = 1, LayoutOrder = layoutOrder }, slidersRow)

	local label = mk("TextLabel", {
		Size = UDim2.new(1, 0, 0, 14),
		BackgroundTransparency = 1,
		Font = Enum.Font.Code,
		Text = def.Name,
		TextSize = 10,
		TextColor3 = Theme.Gray,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, container)

	local track = mk("Frame", {
		Size = UDim2.new(1, 0, 0, 2),
		Position = UDim2.new(0, 0, 0, 22),
		BackgroundColor3 = Theme.Line,
		BorderSizePixel = 0,
	}, container)

	local fraction = (def.Default - def.Min) / (def.Max - def.Min)

	local fill = mk("Frame", {
		Size = UDim2.new(fraction, 0, 1, 0),
		BackgroundColor3 = Theme.White,
		BorderSizePixel = 0,
	}, track)

	local knob = mk("Frame", {
		Size = UDim2.new(0, 10, 0, 10),
		Position = UDim2.new(fraction, 0, 0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Theme.White,
		BorderSizePixel = 0,
	}, track)
	mk("UICorner", { CornerRadius = UDim.new(1, 0) }, knob)

	local dragging = false

	local function setFraction(f: number)
		f = math.clamp(f, 0, 1)
		fill.Size = UDim2.new(f, 0, 1, 0)
		knob.Position = UDim2.new(f, 0, 0.5, 0)
		State.SliderValues[def.Field] = def.Min + (def.Max - def.Min) * f
	end

	knob.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			local relX = (input.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X
			setFraction(relX)
		end
	end)
end

for i, def in CFG.Sliders do
	buildSlider(def, i)
end

--// RIG TYPE TOGGLE ///-----------------------------------------------------

local function refreshRigButtons()
	local isR15 = State.RigType == Enum.HumanoidRigType.R15
	r15Button.BackgroundColor3 = isR15 and Theme.White or Theme.Background
	r15Button.TextColor3 = isR15 and Theme.Background or Theme.Gray
	r6Button.BackgroundColor3 = isR15 and Theme.Background or Theme.White
	r6Button.TextColor3 = isR15 and Theme.Gray or Theme.Background
end

r15Button.MouseButton1Click:Connect(function()
	State.RigType = Enum.HumanoidRigType.R15
	refreshRigButtons()
end)
r6Button.MouseButton1Click:Connect(function()
	State.RigType = Enum.HumanoidRigType.R6
	refreshRigButtons()
end)

--// GRID POPULATION ///-----------------------------------------------------

local function currentFilters(): Filters
	local sort = CFG.SortOptions[State.SortIndex]
	local genre = CFG.Genres[State.GenreIndex]
	return {
		Keyword = State.Keyword,
		SortType = sort.SortType,
		SortAggregation = sort.SortAggregation,
		Genre = genre.Id,
		MinPrice = tonumber(minPriceBox.Text),
		MaxPrice = tonumber(maxPriceBox.Text),
	}
end

local function isSelected(def: CategoryDef, assetId: number): boolean
	local sel = State.Selected[def.Field]
	if def.Multi then
		return sel ~= nil and sel[assetId] == true
	end
	return sel == assetId
end

local function toggleSelection(def: CategoryDef, assetId: number)
	if def.Multi then
		State.Selected[def.Field] = State.Selected[def.Field] or {}
		local set = State.Selected[def.Field]
		if set[assetId] then
			set[assetId] = nil
		else
			set[assetId] = true
		end
	else
		if State.Selected[def.Field] == assetId then
			State.Selected[def.Field] = nil
		else
			State.Selected[def.Field] = assetId
		end
	end
end

local currentLoadToken = 0

local function populateGrid(def: CategoryDef)
	currentLoadToken += 1
	local myToken = currentLoadToken

	for _, child in grid:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	statusLabel.Text = "loading " .. def.Name .. "…"

	task.spawn(function()
		local items, errorMsg = fetchCategory(def, currentFilters())
		if myToken ~= currentLoadToken then
			return -- a newer request superseded this one
		end
		if errorMsg then
			statusLabel.Text = def.Name .. " — " .. errorMsg
			return
		end
		if #items == 0 then
			statusLabel.Text = def.Name .. " — 0 results for these filters"
			return
		end
		statusLabel.Text = ("%s — %d items"):format(def.Name, #items)

		for i, item in items do
			local cell = mk("Frame", {
				Name = tostring(item.AssetId),
				BackgroundColor3 = Theme.Panel,
				BorderColor3 = isSelected(def, item.AssetId) and Theme.White or Theme.Line,
				BorderSizePixel = 1,
				LayoutOrder = i,
			}, grid)

			mk("ImageLabel", {
				Size = UDim2.new(1, -8, 1, -34),
				Position = UDim2.new(0, 4, 0, 4),
				BackgroundColor3 = Theme.Background,
				BorderSizePixel = 0,
				Image = ("rbxthumb://type=Asset&id=%d&w=150&h=150"):format(item.AssetId),
			}, cell)

			mk("TextLabel", {
				Size = UDim2.new(1, -8, 0, 14),
				Position = UDim2.new(0, 4, 1, -30),
				BackgroundTransparency = 1,
				Font = Enum.Font.Code,
				Text = item.Name,
				TextSize = 9,
				TextColor3 = Theme.White,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextXAlignment = Enum.TextXAlignment.Left,
			}, cell)

			mk("TextLabel", {
				Size = UDim2.new(1, -8, 0, 12),
				Position = UDim2.new(0, 4, 1, -16),
				BackgroundTransparency = 1,
				Font = Enum.Font.Code,
				Text = item.Price and (tostring(item.Price) .. " R$") or "—",
				TextSize = 9,
				TextColor3 = Theme.Gray,
				TextXAlignment = Enum.TextXAlignment.Left,
			}, cell)

			local clickCatcher = mk("TextButton", {
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				Text = "",
			}, cell)

			clickCatcher.MouseButton1Click:Connect(function()
				toggleSelection(def, item.AssetId)
				cell.BorderColor3 = isSelected(def, item.AssetId) and Theme.White or Theme.Line
			end)
		end
	end)
end

--// TAB SWITCHING ///--------------------------------------------------------

local function selectTab(index: number)
	State.ActiveCategoryIndex = index
	for i, btn in tabButtons do
		btn.TextColor3 = (i == index) and Theme.White or Theme.Gray
	end
	populateGrid(CFG.Categories[index])
end

for i, btn in tabButtons do
	btn.MouseButton1Click:Connect(function()
		selectTab(i)
	end)
end

--// FILTER WIRING ///--------------------------------------------------------

searchBox.FocusLost:Connect(function(enterPressed)
	State.Keyword = searchBox.Text
	if enterPressed then
		populateGrid(CFG.Categories[State.ActiveCategoryIndex])
	end
end)

sortButton.MouseButton1Click:Connect(function()
	State.SortIndex = (State.SortIndex % #CFG.SortOptions) + 1
	sortButton.Text = "Sort: " .. CFG.SortOptions[State.SortIndex].Name
	populateGrid(CFG.Categories[State.ActiveCategoryIndex])
end)

genreButton.MouseButton1Click:Connect(function()
	State.GenreIndex = (State.GenreIndex % #CFG.Genres) + 1
	genreButton.Text = CFG.Genres[State.GenreIndex].Name
	populateGrid(CFG.Categories[State.ActiveCategoryIndex])
end)

for _, box in { minPriceBox, maxPriceBox } do
	box.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			populateGrid(CFG.Categories[State.ActiveCategoryIndex])
		end
	end)
end

--// INSERT RIG ///------------------------------------------------------------

local function buildDescription(): HumanoidDescription
	local desc = Instance.new("HumanoidDescription")

	for _, def in CFG.Categories do
		local sel = State.Selected[def.Field]
		if sel == nil then
			continue
		end
		if def.Multi then
			local ids = {}
			for assetId in pairs(sel) do
				table.insert(ids, tostring(assetId))
			end
			if #ids > 0 then
				(desc :: any)[def.Field] = table.concat(ids, ",")
			end
		else
			(desc :: any)[def.Field] = sel
		end
	end

	if State.RigType == Enum.HumanoidRigType.R15 then
		for _, s in CFG.Sliders do
			(desc :: any)[s.Field] = State.SliderValues[s.Field]
		end
	end

	return desc
end

insertButton.MouseButton1Click:Connect(function()
	local ok, result = pcall(function()
		local desc = buildDescription()
		return Players:CreateHumanoidModelFromDescription(desc, State.RigType)
	end)

	if not ok then
		warn("[CatoRig] failed to build rig: " .. tostring(result))
		statusLabel.Text = "insert failed — see Output"
		return
	end

	local model = result :: Model
	model.Name = "CatoRig"
	model:PivotTo(CFrame.new(0, 3, 0))
	model.Parent = workspace

	local Selection = game:GetService("Selection")
	Selection:Set({ model })
	statusLabel.Text = "inserted " .. model.Name
end)

--// INIT ///-------------------------------------------------------------------

refreshRigButtons()
selectTab(1)
