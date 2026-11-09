--!strict

-- Endless blocky terrain with a variety of biomes like plains, forest, and desert. Chunks load and appear around players and get culled once nobody
-- is near them anymore. Typing "generate" in chat and it will generate a new seed with a new world.

-- How it works together: the controller works out which chunks are wanted, workers run the
-- noise over in parallel, and the controller turns the numbers into merged boxes, and some basic decor.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

-- All the blocks that can exist. A union type rather than plain `string`, so something like "Gras" gets caught by the
-- editor instead of blowing up at runtime.
type BlockName = "Grass" | "Moss" | "Dirt" | "Sand" | "Sandstone" | "Snow" | "Stone" | "Water"
| "Wood" | "OakLeaves" | "PineLeaves" | "Cactus" | "Tuft" | "Flower"

type BlockStyle = {
	Color: Color3,
	Material: Enum.Material,
	Solid: boolean, -- turns into CanCollide
	Transparency: number?,
	Shadow: boolean?, -- leave it out and the part casts shadows
}

-- leaves are a single box sitting on the trunk, sizes in blocks
type Crown = { Width: number, Height: number }

type TreeShape = {
	Trunk: BlockName,
	Leaf: BlockName,
	MinHeight: number,
	MaxHeight: number,
	Crown: Crown?, -- nil means a bare trunk (cactus)
}

type Biome = {
	Name: string,
	Surface: BlockName,
	Under: BlockName, -- the handful of blocks right under the surface
	Tree: TreeShape?,
	TreeChance: number, -- per tree slot, not per cell (see plantFoliage)
	TuftChance: number,
	FlowerChance: number,
}

-- Everything is in blocks, never studs. The old build mixed the two units and needed asserts
-- to keep them straight.
type Config = {
	BlockSize: number,
	FloorY: number, -- world Y where the bottom of the world sits
	HeightBlocks: number,
	SeaLevel: number, -- in blocks above the floor
	BaseHeight: number,
	HillSize: number,
	HillFreq: number,
	DetailSize: number,
	DetailFreq: number,
	BiomeFreq: number,
	BiomeBlend: number, -- how hard columns get pulled toward the biome around them (0 = off)
	SandDepth: number,
	DirtDepth: number,
	SnowLine: number,
	TreeCell: number,
	MaxSlope: number,
	ForestFreq: number,
	ChunkSize: number, -- blocks per chunk side
	ViewRadius: number, -- chunks kept around each player
	Workers: number,
	Cooldown: number,
	BuildBudget: number, -- seconds per frame spent turning chunks into parts
}

-- What a worker hands back for one chunk. It carries a margin of extra columns so trees and
-- slopes near the edge can be checked against the neighbouring ground.
type Region = {
	Heights: { { number } },
	Biomes: { { number } },
	OriginX: number, -- global cell number of Heights[1][1]
	OriginZ: number,
}

local CONFIG: Config = {
	BlockSize = 4,
	FloorY = -12,
	HeightBlocks = 16,
	SeaLevel = 4,

	BaseHeight = 7,
	HillSize = 8, -- noise is roughly +-0.5, so hills swing about +-4 blocks
	HillFreq = 0.015, -- per stud; lower means wider hills
	DetailSize = 1.5,
	DetailFreq = 0.025,

	-- Biome fields are sampled much coarser than the hills, so one biome covers a big patch of
	-- ground. Kept low on purpose so regions feel continuous rather than noisy.
	BiomeFreq = 0.002,
	BiomeBlend = 0.55,

	SandDepth = 2,
	DirtDepth = 3,
	SnowLine = 13,

	TreeCell = 5, -- one tree slot per 5x5 cells
	MaxSlope = 1,
	ForestFreq = 0.02,

	ChunkSize = 16,
	ViewRadius = 6,
	Workers = 8,
	Cooldown = 5,
	BuildBudget = 0.005,
}

local BLOCKS: { [BlockName]: BlockStyle } = {
	Grass = { Color = Color3.fromRGB(83, 154, 65), Material = Enum.Material.Grass, Solid = true },
	Moss = { Color = Color3.fromRGB(58, 120, 54), Material = Enum.Material.Grass, Solid = true },
	Dirt = { Color = Color3.fromRGB(120, 82, 52), Material = Enum.Material.Ground, Solid = true },
	Sand = { Color = Color3.fromRGB(218, 198, 133), Material = Enum.Material.Sand, Solid = true },
	Sandstone = { Color = Color3.fromRGB(196, 165, 107), Material = Enum.Material.Sandstone, Solid = true },
	Snow = { Color = Color3.fromRGB(240, 244, 248), Material = Enum.Material.Snow, Solid = true },
	Stone = { Color = Color3.fromRGB(105, 108, 113), Material = Enum.Material.Slate, Solid = true },
	-- Glass so the seabed shows through, and no collision so you just wade in
	Water = { Color = Color3.fromRGB(71, 145, 205), Material = Enum.Material.Glass, Solid = false, Transparency = 0.35, Shadow = false },

	Wood = { Color = Color3.fromRGB(102, 77, 46), Material = Enum.Material.Wood, Solid = true },
	OakLeaves = { Color = Color3.fromRGB(52, 122, 48), Material = Enum.Material.Grass, Solid = true },
	PineLeaves = { Color = Color3.fromRGB(33, 92, 52), Material = Enum.Material.Grass, Solid = true },
	Cactus = { Color = Color3.fromRGB(74, 140, 70), Material = Enum.Material.Fabric, Solid = true },

	-- decoration; no collision, no shadows, since there are loads of them
	Tuft = { Color = Color3.fromRGB(96, 170, 70), Material = Enum.Material.Grass, Solid = false, Shadow = false },
	Flower = { Color = Color3.fromRGB(214, 59, 59), Material = Enum.Material.SmoothPlastic, Solid = false, Shadow = false },
}

local FLOWER_COLORS = {
	Color3.fromRGB(214, 59, 59),
	Color3.fromRGB(240, 205, 66),
	Color3.fromRGB(240, 240, 240),
	Color3.fromRGB(150, 90, 200),
	Color3.fromRGB(235, 130, 190),
}

local OAK: TreeShape = {
	Trunk = "Wood",
	Leaf = "OakLeaves",
	MinHeight = 3,
	MaxHeight = 5,
	Crown = { Width = 3, Height = 3 },
}

-- same idea as the oak, just taller and narrower
local PINE: TreeShape = {
	Trunk = "Wood",
	Leaf = "PineLeaves",
	MinHeight = 4,
	MaxHeight = 6,
	Crown = { Width = 2, Height = 5 },
}

-- leaves are the trunk itself in this case
local CACTUS: TreeShape = { Trunk = "Cactus", Leaf = "Cactus", MinHeight = 2, MaxHeight = 4, Crown = nil }

-- Order matters here so an array is used. workers send these by index, and the constants below match. Chances are
-- per tree slot, so they're higher than they'd look per cell.
local BIOMES: { Biome } = {
	{ Name = "Plains", Surface = "Grass", Under = "Dirt", Tree = OAK, TreeChance = 0.15, TuftChance = 0.18, FlowerChance = 0.035 },
	{ Name = "Forest", Surface = "Moss", Under = "Dirt", Tree = OAK, TreeChance = 0.5, TuftChance = 0.10, FlowerChance = 0.012 },
	{ Name = "Desert", Surface = "Sand", Under = "Sandstone", Tree = CACTUS, TreeChance = 0.12, TuftChance = 0, FlowerChance = 0 },
	{ Name = "Tundra", Surface = "Snow", Under = "Dirt", Tree = PINE, TreeChance = 0.3, TuftChance = 0, FlowerChance = 0 },
	{ Name = "Mountains", Surface = "Stone", Under = "Stone", Tree = nil, TreeChance = 0, TuftChance = 0, FlowerChance = 0 },
}
local PLAINS, FOREST, DESERT, TUNDRA, MOUNTAINS = 1, 2, 3, 4, 5

local ROLE_ATTRIBUTE = "BlockTerrainGeneratorRole"
local role = script:GetAttribute(ROLE_ATTRIBUTE) -- nil on the very first copy; "Controller"/"Worker" on the clones
local actor = script:GetActor() -- nil unless this copy lives inside an Actor

local BLOCK = CONFIG.BlockSize
local HEIGHT = CONFIG.HeightBlocks
local SEA = CONFIG.SeaLevel
local C = CONFIG.ChunkSize
local CHUNK_STUDS = C * BLOCK

-- Workers generate this many extra columns on every side. Only trees whose trunk lies inside the
-- chunk are built by it, and the slope check looks one cell past the trunk, so one is enough.
local MARGIN = 1
local REGION = C + MARGIN * 2

-- cell number to the world coordinate of its centre. Cells count from the origin in both
-- directions, so the world has no edge.
local function toWorld(cell: number): number
	return (cell + 0.5) * BLOCK
end

-- The one noise call everything goes through. math.noise is deterministic, so "seeding" just
-- means nudging the offsets. `shift` keeps different fields from becoming copies of each other.
local function field(wx: number, wz: number, ox: number, oz: number, freq: number, shift: number): number
	return math.noise((wx + ox) * freq + shift, (wz + oz) * freq - shift)
end

-- The first copy does one job only: make the controller Actor, then bow out.
if not actor then
	local controllerActor = Instance.new("Actor")
	controllerActor.Name = "BlockTerrainGenerationController"
	controllerActor.Parent = ServerScriptService

	local copy = script:Clone()
	copy.Name = "Controller"
	copy:SetAttribute(ROLE_ATTRIBUTE, "Controller") -- must be set before parenting; it's read on start
	copy.Disabled = false
	copy.Parent = controllerActor
	return
end

-- Worker path. Each worker gets its own Actor.
if role == "Worker" then
	local link = actor:FindFirstChild("ControllerActor")
	if not link or not link:IsA("ObjectValue") then
		warn("worker has no controller link")
		return
	end

	local controller = link.Value
	if not controller or not controller:IsA("Actor") then
		warn("worker controller link is broken")
		return
	end

	-- Priorities, highest first: mountains, then cold, then hot and dry, then wet, then plain.
	local function pickBiome(temperature: number, moisture: number, relief: number): number
		if relief > 0.15 then
			return MOUNTAINS
		elseif temperature < -0.12 then
			return TUNDRA
		elseif temperature > 0.1 and moisture < 0.05 then
			return DESERT
		elseif moisture > 0.05 then
			return FOREST
		end
		return PLAINS
	end

	-- Grouping pass: instead of taking the raw per-column biome, each column looks at a few
	-- points around it and adopts whichever biome shows up most often. This fattens up regions
	-- and eats the little one-column slivers the noise would otherwise leave behind.
	local offsets = {
		{ 0, 0 },
		{ 1, 0 },
		{ -1, 0 },
		{ 0, 1 },
		{ 0, -1 },
	}

	local function groupedBiome(wx: number, wz: number, ox: number, oz: number): number
		local counts = { 0, 0, 0, 0, 0 }
		for _, o in offsets do
			local sx, sz = wx + o[1] * BLOCK, wz + o[2] * BLOCK
			local temperature = field(sx, sz, ox, oz, CONFIG.BiomeFreq, 211)
			local moisture = field(sx, sz, ox, oz, CONFIG.BiomeFreq, -347)
			local relief = field(sx, sz, ox, oz, CONFIG.BiomeFreq * 1.5, 659)
			local b = pickBiome(temperature, moisture, relief)
			counts[b] += 1
		end

		-- pick the most common, ties go to whichever comes first in the list
		local best, bestCount = PLAINS, -1
		for i = 1, 5 do
			if counts[i] > bestCount then
				best, bestCount = i, counts[i]
			end
		end
		return best
	end

	-- the parallel handler; several run at once on different threads
	actor:BindToMessageParallel("GenerateChunk", function(
		generationId: number, -- echoed back so stale answers can be thrown away
		cx: number,
		cz: number,
		ox: number,
		oz: number
	)
		-- global cell of the first column we return. Margins mean neighbours overlap on purpose,
		-- but the noise is deterministic so both agree on the shared columns.
		local originX = cx * C - MARGIN
		local originZ = cz * C - MARGIN
		local out: { string } = table.create(REGION * REGION)
		local n = 0

		for i = 0, REGION - 1 do
			for j = 0, REGION - 1 do
				-- sample column centres, not corners
				local wx = toWorld(originX + i)
				local wz = toWorld(originZ + j)

				local hills = field(wx, wz, ox, oz, CONFIG.HillFreq, 0)
				local detail = field(wx, wz, ox, oz, CONFIG.DetailFreq, 37)
				local relief = field(wx, wz, ox, oz, CONFIG.BiomeFreq * 1.5, 659)

				-- relief both picks mountains and stretches the hills, so peaks end up noticeably taller
				local stretch = math.clamp(1 + relief * 1.6, 0.6, 1.8)
				local height = CONFIG.BaseHeight + (hills * CONFIG.HillSize + detail * CONFIG.DetailSize) * stretch
				-- whole blocks only, with a block of floor and a block of sky kept free
				local solid = math.clamp(math.floor(height + 0.5), 1, HEIGHT - 1)

				local biome = groupedBiome(wx, wz, ox, oz)

				-- three bytes per column: height split over two, then biome. One string is far
				-- cheaper to copy across actors than a table of numbers.
				n += 1
				out[n] = string.char(solid // 256, solid % 256, biome)
			end
		end

		task.synchronize() -- leave the parallel phase before sending anything
		controller:SendMessage("ChunkReady", generationId, cx, cz, table.concat(out))
	end)

	-- announce ready only after the handler exists, so no GenerateChunk can slip through first
	controller:SendMessage("WorkerReady")
	return
end

if role ~= "Controller" then
	return
end

-- ---------- controller ----------

local workers: { Actor } = {}
local readyCount = 0
local ready = false
local lastCommand = -math.huge

local generation = 0 -- bumped on every new seed; answers from older worlds are ignored
local worldSeed = 0
local offX, offZ = 0, 0 -- noise offsets derived from worldSeed

type Want = { Key: string, Cx: number, Cz: number, Dist: number }
type Job = { Key: string, Cx: number, Cz: number, Data: string, Generation: number }

local loaded: { [string]: Folder } = {}
local inFlight: { [string]: number } = {} -- key -> when it was sent
local queued: { [string]: boolean } = {} -- answer in hand, waiting to be built
local keep: { [string]: boolean } = {} -- close enough to a player to stay
local queue: { Job } = {}
local spawnPoint: Vector3? = nil
local nextWorker = 0

-- wipe any leftover world from a previous run, then make a fresh folder for this one
local old = Workspace:FindFirstChild("GeneratedBlockTerrain")
if old then
	old:Destroy()
end
local world = Instance.new("Folder")
world.Name = "GeneratedBlockTerrain"
world.Parent = Workspace

local function seedOffsets(seed: number): (number, number)
	local rng = Random.new(seed)
	return rng:NextNumber(-10000, 10000), rng:NextNumber(-10000, 10000)
end

-- A random stream tied to a world position rather than to build order. Trees and plants depend
-- on this, which is why a tree comes out identical no matter which chunk reaches it first.
local function mix(x: number, z: number, salt: number): number
	return bit32.bxor(worldSeed, x * 73856093, z * 19349663, salt * 83492791)
end

local function heightAt(region: Region, gx: number, gz: number): number
	return region.Heights[gx - region.OriginX + 1][gz - region.OriginZ + 1]
end

-- The cast is just to silence strict mode, which types array indexing as possibly nil. Indices
-- always come from BIOMES itself, so it's safe.
local function biomeAt(region: Region, gx: number, gz: number): Biome
	return BIOMES[region.Biomes[gx - region.OriginX + 1][gz - region.OriginZ + 1]] :: Biome
end

-- What block lives at global cell (gx, y, gz)? nil means air. Nothing is stored in 3D; the
-- answer is derived from the column, the way a heightmap game would do it.
local function blockAt(region: Region, gx: number, y: number, gz: number): BlockName?
	local i, j = gx - region.OriginX + 1, gz - region.OriginZ + 1
	if i < 1 or i > REGION or j < 1 or j > REGION or y < 1 or y > HEIGHT then
		return nil
	end

	local solid = region.Heights[i][j]
	if y > solid then
		return if y <= SEA then "Water" else nil
	end

	local depth = solid - y -- zero is the surface block
	-- these two rules beat the biome: low ground becomes beach, high ground becomes snowy rock
	if solid <= SEA + 1 then
		return if depth <= CONFIG.SandDepth then "Sand" else "Stone"
	elseif solid >= CONFIG.SnowLine then
		return if depth == 0 then "Snow" else "Stone"
	end

	local biome = biomeAt(region, gx, gz)
	if depth == 0 then
		return biome.Surface
	elseif depth <= CONFIG.DirtDepth then
		return biome.Under
	end
	return "Stone"
end

-- Single factory for every part, terrain or plant, so material/colour rules live in one place.
local function makePart(parent: Instance, block: BlockName, size: Vector3, cframe: CFrame, tint: Color3?)
	local style = BLOCKS[block] :: BlockStyle

	local part = Instance.new("Part")
	part.Name = block
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Material = style.Material
	part.Color = tint or style.Color
	part.Transparency = style.Transparency or 0
	part.CastShadow = style.Shadow ~= false -- nil counts as true
	part.CanCollide = style.Solid
	part.CanTouch = false
	part.CanQuery = style.Solid -- raycasts sail through water and plants
	part.Parent = parent -- parented last so it never replicates half-configured
end

-- Random colour for a single tree. Hue, saturation and brightness each drift a bit; just
-- darkening gives the same green but dimmer, which looks flat. HSV because nudging RGB directly
-- shifts hue unevenly.
local function vary(color: Color3, rng: Random, hue: number, value: number): Color3
	local h, s, v = color:ToHSV()
	return Color3.fromHSV(
		(h + rng:NextNumber(-hue, hue)) % 1, -- % 1 wraps back into 0..1
		math.clamp(s * rng:NextNumber(0.85, 1.1), 0, 1),
		math.clamp(v * (1 + rng:NextNumber(-value, value)), 0, 1)
	)
end

-- Plants and trees for one chunk. No shared RNG anywhere, because chunks are built in arbitrary
-- order. Each tree slot gets position and dice from mix(), so the result depends only on location.
-- The chunk containing the trunk builds the whole tree, even if its leaves poke past the border.
local function plantFoliage(region: Region, cx: number, cz: number, folder: Folder)
	local startX, startZ = cx * C, cz * C

	local function inside(gx: number, gz: number): boolean
		return gx >= startX and gx < startX + C and gz >= startZ and gz < startZ + C
	end

	-- columns occupied by trunks, so flowers don't sprout through them
	local trunkAt: { [number]: boolean } = {}
	local function key(gx: number, gz: number): number
		return (gx - startX) + (gz - startZ) * 64
	end

	-- surface must be the biome's own block, which also rules out beach and snow cap. Beach sand
	-- and desert sand are the same block, hence the height checks as well.
	local function canGrow(gx: number, gz: number): boolean
		local ground = heightAt(region, gx, gz)
		return ground > SEA + 1
			and ground < CONFIG.SnowLine
			and blockAt(region, gx, ground, gz) == biomeAt(region, gx, gz).Surface
	end

	-- a tree on a slope would float on one side
	local function isFlat(gx: number, gz: number): boolean
		for dx = -1, 1 do
			for dz = -1, 1 do
				if math.abs(heightAt(region, gx + dx, gz + dz) - heightAt(region, gx, gz)) > CONFIG.MaxSlope then
					return false
				end
			end
		end
		return true
	end

	-- 1. find tree slots. A slot at (sx, sz) puts its trunk inside the middle 3x3 of its 5x5
	-- area, so two trunks are never closer than 3 cells and neighbours don't need to consult each
	-- other. Trunks outside this chunk are left to the chunk that owns them.
	local slot = CONFIG.TreeCell
	local trees: { { X: number, Z: number, Shape: TreeShape } } = {}

	for sx = startX // slot, (startX + C - 1) // slot do -- // floors, including negatives
		for sz = startZ // slot, (startZ + C - 1) // slot do
			local dice = Random.new(mix(sx, sz, 1))
			local tx = sx * slot + dice:NextInteger(1, slot - 2)
			local tz = sz * slot + dice:NextInteger(1, slot - 2)
			local roll = dice:NextNumber()

			if not inside(tx, tz) then
				continue
			end

			local biome = biomeAt(region, tx, tz)
			local shape = biome.Tree
			if not shape or not canGrow(tx, tz) or not isFlat(tx, tz) then
				continue
			end

			-- slow forest noise creates clumps and clearings. It hovers near +-0.25 here, this
			-- squeezes it into 0..1
			local density = math.clamp(
				(field(toWorld(tx), toWorld(tz), offX, offZ, CONFIG.ForestFreq, 113) + 0.25) / 0.5,
				0,
				1
			)
			if roll < biome.TreeChance * (0.15 + 1.85 * density) then
				table.insert(trees, { X = tx, Z = tz, Shape = shape })
			end
		end
	end

	-- 2. spawn them. One trunk part, plus one leaf box where the tree has a crown.
	for _, tree in trees do
		local shape = tree.Shape
		local rng = Random.new(mix(tree.X, tree.Z, 2)) -- the tree's own stream, same on every rebuild
		local ground = heightAt(region, tree.X, tree.Z)
		local trunk = rng:NextInteger(shape.MinHeight, shape.MaxHeight)
		local top = ground + trunk -- cell number of the topmost trunk block

		trunkAt[key(tree.X, tree.Z)] = true

		makePart(
			folder,
			shape.Trunk,
			Vector3.new(BLOCK, trunk * BLOCK, BLOCK),
			-- one long part; centre is half its height above the ground
			CFrame.new(toWorld(tree.X), CONFIG.FloorY + (ground + trunk / 2) * BLOCK, toWorld(tree.Z)),
			-- bark barely varies, leaves get the big swing later
			vary((BLOCKS[shape.Trunk] :: BlockStyle).Color, rng, 0.01, 0.12)
		)

		local crown = shape.Crown
		if crown then
			-- box starts a block below the trunk top so the trunk vanishes into it. Still clear of
			-- neighbouring columns, since trunks only grow on <=1 slope and are at least 3 tall.
			makePart(
				folder,
				shape.Leaf,
				Vector3.new(crown.Width * BLOCK, crown.Height * BLOCK, crown.Width * BLOCK),
				CFrame.new(toWorld(tree.X), CONFIG.FloorY + (top - 1 + crown.Height / 2) * BLOCK, toWorld(tree.Z)),
				vary((BLOCKS[shape.Leaf] :: BlockStyle).Color, rng, 0.04, 0.25)
			)
		end
	end

	-- 3. small stuff, only this chunk's own cells. Runs after trees so it can skip trunk cells.
	for gx = startX, startX + C - 1 do
		for gz = startZ, startZ + C - 1 do
			local biome = biomeAt(region, gx, gz)
			local ground = heightAt(region, gx, gz)
			if biome.TuftChance + biome.FlowerChance == 0
				or trunkAt[key(gx, gz)]
				or not canGrow(gx, gz) then
				continue
			end

			-- per-cell stream. Low end of the roll means flower, next slice means tuft, rest
			-- means nothing.
			local dice = Random.new(mix(gx, gz, 3))
			local roll = dice:NextNumber()
			if roll >= biome.FlowerChance + biome.TuftChance then
				continue
			end

			local top = CONFIG.FloorY + ground * BLOCK -- world Y of the grass surface
			local px = toWorld(gx) + dice:NextNumber(-1.2, 1.2) -- nudge off the cell grid
			local pz = toWorld(gz) + dice:NextNumber(-1.2, 1.2)
			local spin = CFrame.Angles(0, dice:NextNumber(0, math.pi), 0) -- they're boxes; rotation helps

			if roll < biome.FlowerChance then
				local stem = BLOCK * 0.4
				local head = BLOCK * 0.25
				makePart(folder, "Tuft", Vector3.new(BLOCK * 0.08, stem, BLOCK * 0.08), CFrame.new(px, top + stem / 2, pz))
				-- head sits at 0.4 of its size, not 0.5, so it slightly overlaps the stem
				makePart(
					folder,
					"Flower",
					Vector3.new(head, head, head),
					CFrame.new(px, top + stem + head * 0.4, pz) * spin,
					FLOWER_COLORS[dice:NextInteger(1, #FLOWER_COLORS)]
				)
			else
				local tall = BLOCK * dice:NextNumber(0.3, 0.55)
				makePart(folder, "Tuft", Vector3.new(BLOCK * 0.25, tall, BLOCK * 0.25), CFrame.new(px, top + tall / 2, pz) * spin)
			end
		end
	end
end

-- worker string -> finished chunk folder
local function buildChunk(cx: number, cz: number, data: string): Folder
	if #data ~= REGION * REGION * 3 then
		error(("chunk %d,%d came back the wrong size"):format(cx, cz))
	end

	-- decode in the same order the worker wrote it (i outer, j inner, 3 bytes each)
	local region: Region = { Heights = {}, Biomes = {}, OriginX = cx * C - MARGIN, OriginZ = cz * C - MARGIN }
	local p = 0
	for i = 1, REGION do
		local heights, biomes = table.create(REGION, 1), table.create(REGION, 1)
		for j = 1, REGION do
			local high, low, biome = string.byte(data, p + 1, p + 3)
			heights[j] = high * 256 + low
			biomes[j] = biome
			p += 3
		end
		region.Heights[i], region.Biomes[i] = heights, biomes
	end

	-- built unparented; much cheaper than letting the engine react to every part as it appears.
	-- The folder drops into the world at the very end.
	local folder = Instance.new("Folder")
	folder.Name = `Chunk {cx},{cz}`

	local startX, startZ = cx * C, cz * C
	local ok, err = pcall(function()
		-- Greedy merge, first pass: per column, find vertical runs of one block. The key includes
		-- the block and the y range, so two columns only merge when their stacks are identical.
		type Run = { Block: BlockName, From: number, To: number }
		local runs: { { { [string]: boolean } } } = {}
		local used: { { { [string]: boolean } } } = {}
		local info: { [string]: Run } = {}

		for x = 1, C do
			runs[x], used[x] = {}, {}
			for z = 1, C do
				runs[x][z], used[x][z] = {}, {}

				local y = 1
				while y <= HEIGHT do
					local block = blockAt(region, startX + x - 1, y, startZ + z - 1)
					if not block then
						y += 1
						continue
					end

					local from = y
					repeat
						y += 1
					until y > HEIGHT or blockAt(region, startX + x - 1, y, startZ + z - 1) ~= block

					local id = `{block}:{from}:{y - 1}`
					runs[x][z][id] = true
					info[id] = { Block = block, From = from, To = y - 1 }
				end
			end
		end

		-- Second pass: grow a box out of each unused run. Boxes never cross a chunk border;
		-- the neighbour handles its own.
		for x = 1, C do
			for z = 1, C do
				-- this loop only writes to `used`, so walking `runs` here is fine
				for id in runs[x][z] do
					if used[x][z][id] then
						continue
					end

					-- extend along Z while the same key keeps going...
					local depth = 1
					while z + depth <= C and runs[x][z + depth][id] and not used[x][z + depth][id] do
						depth += 1
					end

					-- ...then along X, only if the whole depth-wide row matches
					local width = 1
					while x + width <= C do
						local rowOk = true
						for zz = z, z + depth - 1 do
							if not runs[x + width][zz][id] or used[x + width][zz][id] then
								rowOk = false
								break
							end
						end
						if not rowOk then
							break
						end
						width += 1
					end

					for xx = x, x + width - 1 do
						for zz = z, z + depth - 1 do
							used[xx][zz][id] = true -- claimed; nothing builds it twice
						end
					end

					local run = info[id]
					local tall = run.To - run.From + 1
					makePart(
						folder,
						run.Block,
						Vector3.new(width * BLOCK, tall * BLOCK, depth * BLOCK),
						-- CFrame is the box centre: start edge in cells plus half its size
						CFrame.new(
							(startX + x - 1 + width / 2) * BLOCK,
							CONFIG.FloorY + (run.From - 1 + tall / 2) * BLOCK,
							(startZ + z - 1 + depth / 2) * BLOCK
						)
					)
				end
			end
		end

		plantFoliage(region, cx, cz, folder)

		-- chunk (0,0) hosts spawn. Find the dry cell nearest its middle.
		if cx == 0 and cz == 0 and not spawnPoint then
			local best: Vector3? = nil
			local bestDist = math.huge
			for gx = 0, C - 1 do
				for gz = 0, C - 1 do
					local h = heightAt(region, gx, gz)
					local dist = (gx - C / 2) ^ 2 + (gz - C / 2) ^ 2
					if h > SEA + 1 and h < CONFIG.SnowLine and dist < bestDist then
						bestDist = dist
						-- +28 studs clears any canopy, so players never pop inside a tree
						best = Vector3.new(toWorld(gx), CONFIG.FloorY + h * BLOCK + 28, toWorld(gz))
					end
				end
			end
			spawnPoint = best or Vector3.new(toWorld(C // 2), CONFIG.FloorY + HEIGHT * BLOCK, toWorld(C // 2))
		end
	end)

	if not ok then
		folder:Destroy()
		error(err)
	end

	folder.Parent = world
	return folder
end

---------- STREAMING ----------

-- Hold characters still until there's ground, then drop them at spawn.
local function sendToSpawn(character: Model)
	local root = character:WaitForChild("HumanoidRootPart", 5)
	if not root or not root:IsA("BasePart") then
		return
	end

	root.Anchored = true -- otherwise they fall through the void while chunk 0,0 is still cooking
	while not spawnPoint and root.Parent do
		task.wait(0.1)
	end

	if spawnPoint and root.Parent then
		character:PivotTo(CFrame.new(spawnPoint))
		root.Anchored = false
	end
end

-- Runs a few times per second. Works out which chunks players need, requests the missing ones
-- closest-first, and tosses out chunks nobody is near anymore.
local function refresh()
	table.clear(keep)
	local view = CONFIG.ViewRadius
	local wants: { [string]: Want } = {}

	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not character or not root or not root:IsA("BasePart") then
			continue
		end

		-- fell out of the world, or the world got re-rolled underneath them
		if root.Position.Y < CONFIG.FloorY - 40 and not root.Anchored then
			task.spawn(sendToSpawn, character)
		end

		local pcx = math.floor(root.Position.X / CHUNK_STUDS)
		local pcz = math.floor(root.Position.Z / CHUNK_STUDS)

		-- Keep one ring beyond ViewRadius (kept but not requested), so pacing back and forth
		-- across a border doesn't delete and rebuild the same chunk over and over.
		for dx = -view - 1, view + 1 do
			for dz = -view - 1, view + 1 do
				local dist = dx * dx + dz * dz -- squared, so the view is round instead of square
				if dist > (view + 1) ^ 2 then
					continue
				end

				local cx, cz = pcx + dx, pcz + dz
				local key = `{cx},{cz}`
				keep[key] = true

				if dist <= view * view and not loaded[key] and not inFlight[key] and not queued[key] then
					local existing = wants[key]
					if not existing or dist < existing.Dist then
						wants[key] = { Key = key, Cx = cx, Cz = cz, Dist = dist }
					end
				end
			end
		end
	end

	-- the spawn chunk is never dropped, and always sorted first
	keep["0,0"] = true
	if not loaded["0,0"] and not inFlight["0,0"] and not queued["0,0"] then
		wants["0,0"] = { Key = "0,0", Cx = 0, Cz = 0, Dist = -1 }
	end

	for key, folder in loaded do
		if not keep[key] then
			folder:Destroy()
			loaded[key] = nil -- removing a key mid-loop is allowed in Luau
		end
	end

	-- count what's still out. Anything older than 20 seconds is assumed lost, otherwise one
	-- dead worker could eat the entire request budget.
	local flying = 0
	for key, sentAt in inFlight do
		if os.clock() - sentAt > 20 then
			inFlight[key] = nil
		else
			flying += 1
		end
	end

	local list: { Want } = {}
	for _, want in wants do
		table.insert(list, want)
	end
	table.sort(list, function(a: Want, b: Want)
		return a.Dist < b.Dist
	end)

	for _, want in list do
		if flying >= CONFIG.Workers * 2 then
			break -- two jobs per worker keeps them fed without building a huge backlog
		end

		inFlight[want.Key] = os.clock()
		flying += 1
		nextWorker += 1
		workers[nextWorker % #workers + 1]:SendMessage("GenerateChunk", generation, want.Cx, want.Cz, offX, offZ)
	end
end

-- New seed means new world; everything already built goes and chunks rebuild around players.
local function reseed(seed: number)
	generation += 1
	worldSeed = seed
	offX, offZ = seedOffsets(seed)

	for _, folder in loaded do
		folder:Destroy()
	end
	table.clear(loaded)
	table.clear(inFlight)
	table.clear(queued)
	table.clear(queue)
	spawnPoint = nil
	print(`New world, seed {seed}`)
end

actor:BindToMessage("WorkerReady", function()
	readyCount += 1
end)

-- arrives per chunk, from whichever worker finished first
actor:BindToMessage("ChunkReady", function(id: number, cx: number, cz: number, data: string)
	if id ~= generation then
		return -- from before the latest reseed
	end

	local key = `{cx},{cz}`
	inFlight[key] = nil
	-- the player might have walked away while the worker was busy
	if keep[key] and not loaded[key] then
		queued[key] = true
		table.insert(queue, { Key = key, Cx = cx, Cz = cz, Data = data, Generation = id })
	end
end)

-- Spread the building out across frames: pull jobs until BuildBudget is used up
RunService.Heartbeat:Connect(function()
	local started = os.clock()
	repeat
		local job = table.remove(queue, 1)
		if not job then
			return
		end

		queued[job.Key] = nil
		if job.Generation == generation and keep[job.Key] and not loaded[job.Key] then
			local ok, result = pcall(buildChunk, job.Cx, job.Cz, job.Data)
			if ok then
				loaded[job.Key] = result
			else
				warn(`Chunk {job.Key} failed: {result}`)
			end
		end
	until os.clock() - started > CONFIG.BuildBudget
end)

local function listen(player: Player)
	player.CharacterAdded:Connect(function(character)
		task.spawn(sendToSpawn, character)
	end)
	if player.Character then
		task.spawn(sendToSpawn, player.Character)
	end

	player.Chatted:Connect(function(message: string)
		-- lazy match trims whitespace; `or ""` keeps strict mode happy
		if string.lower(string.match(message, "^%s*(.-)%s*$") or "") ~= "generate" then
			return
		end

		local now = os.clock()
		if not ready or now - lastCommand < CONFIG.Cooldown then
			return
		end

		lastCommand = now
		reseed(Random.new():NextInteger(1, 2147483647)) -- unseeded Random, new number each time
	end)
end

for _, player in Players:GetPlayers() do
	listen(player)
end
Players.PlayerAdded:Connect(listen)

for i = 1, CONFIG.Workers do
	local worker = Instance.new("Actor")
	worker.Name = "BlockTerrainWorker" .. i
	worker.Parent = ServerScriptService

	local link = Instance.new("ObjectValue") -- what the worker block searches for
	link.Name = "ControllerActor"
	link.Value = actor
	link.Parent = worker -- parented before the script, so it exists the moment the script starts

	local copy = script:Clone()
	copy.Name = "Worker"
	copy:SetAttribute(ROLE_ATTRIBUTE, "Worker")
	copy.Disabled = false
	copy.Parent = worker

	workers[i] = worker
end

-- give workers up to five seconds to bind their handlers
local deadline = os.clock() + 5
while readyCount < #workers and os.clock() < deadline do
	task.wait()
end

if readyCount < #workers then
	warn("Workers never reported ready, generation is off")
	return
end

ready = true
reseed(Random.new():NextInteger(1, 2147483647))

while true do
	refresh()
	task.wait(0.25)
end
