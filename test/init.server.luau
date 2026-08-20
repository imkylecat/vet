--!strict

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Vet = require(ReplicatedStorage.Vet)

local Username = Vet.string():min(3):max(22)
local Level = Vet.number():integer():min(1):max(100)

assert(Username:parse("kyle") == "kyle")
assert(not Username:safeParse("ky").success)
assert(not Username:safeParse(5).success)

assert(Level:parse(50) == 50)
assert(not Level:safeParse(1.5).success)
assert(not Level:safeParse(0).success)

local Enabled = Vet.boolean()

assert(Enabled:parse(false) == false)
assert(not Enabled:safeParse(1).success)
-- Pinning a boolean to one value is what literal is for.
local Consented = Vet.literal(true)

assert(Consented:parse(true) == true)
assert(not Consented:safeParse(false).success)
assert(not Consented:safeParse("true").success)
assert(not Consented:safeParse(nil).success)
assert(Consented:optional():safeParse(nil).success)

-- Colours are checked as a datatype, so a lookalike table does not pass.
local Tint = Vet.color3()
local red = Color3.new(1, 0, 0)

assert(Tint:parse(red) == red)
assert(not Tint:safeParse({ R = 1, G = 0, B = 0 }).success)
assert(not Tint:safeParse(Vector3.new(1, 0, 0)).success)
assert(Tint:optional():safeParse(nil).success)
assert(Vet.color3() == Vet.color3())

local Size = Vet.udim2()

assert(Size:parse(UDim2.fromScale(1, 0.5)) ~= nil)
assert(not Size:safeParse({ X = 1, Y = 0.5 }).success)
assert(not Size:safeParse(UDim.new(1, 0)).success)
assert(not Size:safeParse(red).success)

local Kind = Vet.literal("player")

assert(Kind:parse("player") == "player")
assert(not Kind:safeParse("npc").success)
assert(Kind.value == "player")
assert(Kind.isOptional == false)

-- Literals compose into objects the same way any other schema does.
local Tagged = Vet.object({ kind = Vet.literal("npc"), level = Vet.number():integer() })

assert(Tagged:parse({ kind = "npc", level = 3 }).kind == "npc")
assert(not Tagged:safeParse({ kind = "player", level = 3 }).success)

local Nickname = Vet.string():max(20):optional()

assert(Nickname:parse(nil) == nil)
assert(Nickname:parse("kyle") == "kyle")
assert(not Nickname:safeParse(5).success)
assert(not Nickname:safeParse(string.rep("a", 21)).success)

local Scores = Vet.array(Vet.number():integer()):max(4)

assert(#Scores:parse({ 1, 2, 3 }) == 3)
assert(Scores:safeParse({}).success)
assert(not Scores:safeParse({ 1, 1.5 }).success)
assert(not Scores:safeParse({ 1, 2, 3, 4, 5 }).success)
assert(not Scores:safeParse({ 1, 2, extra = 3 }).success)

local User = Vet.object({
    name = Vet.string():min(3),
    level = Vet.number():integer(),
    nickname = Vet.string():optional(),
})

assert(User:parse({ name = "kyle", level = 5 }).name == "kyle")
assert(not User:safeParse({ name = "kyle" }).success)
assert(not User:safeParse({ name = "ky", level = 5 }).success)
assert(User:safeParse({ name = "kyle", level = 5, extra = true }).success)
assert(not User:strict():safeParse({ name = "kyle", level = 5, extra = true }).success)

local nestedFailure = Vet.object({ members = Vet.array(User) }):safeParse({
    members = { { name = "alex", level = 2.5 } },
})

assert(not nestedFailure.success)

if not nestedFailure.success then
    -- Issue paths locate the failure: { "members", 1, "level" }
    assert(nestedFailure.issues[1].path[1] == "members")
    assert(nestedFailure.issues[1].path[2] == 1)
    assert(nestedFailure.issues[1].path[3] == "level")
end

local Settings = Vet.object({
    volume = Vet.number():min(0):max(1):default(0.5),
    muted = Vet.boolean():default(false),
    name = Vet.string():min(1),
})

local filled = Settings:parse({ name = "kyle" })

assert(filled.volume == 0.5)
assert(filled.muted == false)
assert(Settings:parse({ name = "kyle", volume = 0.1 }).volume == 0.1)
assert(not Settings:safeParse({ name = "kyle", volume = 2 }).success)
assert(not Settings:safeParse({}).success)

-- Filling a default copies rather than modifying the table handed to parse.
local original: { name: string, volume: number? } = { name = "kyle" }
assert(Settings:parse(original) ~= original)
assert(original.volume == nil)

-- Nothing to fill means the original table comes straight back.
local plain = { name = "kyle" }
assert(Vet.object({ name = Vet.string() }):parse(plain) == plain)

-- A constant table default is shared between parses, so build tables per parse.
local Tags = Vet.array(Vet.string()):defaultWith(function()
    return {}
end)

local firstTags = Tags:parse(nil)
table.insert(firstTags, "hi")
assert(#Tags:parse(nil) == 0)

-- Field schemas stay reachable, so a single field can be checked on its own.
assert(Settings.shape.volume:parse(0.25) == 0.25)
assert(not Settings.shape.volume:safeParse(2).success)
assert(Settings.shape.volume:parse(nil) == 0.5)

-- The shape is frozen, so writing to it fails at runtime. The cast is needed
-- because the assignment is deliberately the wrong type as well.
assert(table.isfrozen(Settings.shape))
assert(not pcall(function()
    (Settings.shape :: any).volume = Vet.string()
end))

-- A field schema can be reused in another object.
local JustVolume = Vet.object({ volume = Settings.shape.volume })

assert(JustVolume:parse({}).volume == 0.5)

local Waypoint = Vet.tuple({ Vet.string(), Vet.number():integer() })

assert(Waypoint:parse({ "spawn", 3 })[2] == 3)
assert(not Waypoint:safeParse({ "spawn", "3" }).success)
assert(not Waypoint:safeParse({ "spawn" }).success)
assert(not Waypoint:safeParse({ "spawn", 3, 4 }).success)

-- A position that tolerates nil may be left off the end.
local Ping = Vet.tuple({ Vet.string(), Vet.number():default(0) })

assert(Ping:parse({ "hello" })[2] == 0)

local SessionId = Vet.uuid({ version = "v7" })

assert(SessionId:parse("01912d68-783e-7cc0-a2f0-5f8b1d3e9a7c") ~= nil)
assert(not SessionId:safeParse("6f9619ff-8b86-4d11-b42d-00cf4fc964ff").success)
assert(Vet.uuid():safeParse("6f9619ff-8b86-4d11-b42d-00cf4fc964ff").success)
assert(Vet.uuid():safeParse("6F9619FF-8B86-4D11-B42D-00CF4FC964FF").success)

-- Version and variant are both enforced, so these sentinels are not UUIDs.
assert(not Vet.uuid():safeParse("00000000-0000-0000-0000-000000000000").success)
assert(not Vet.uuid():safeParse("6f9619ff-8b86-4d11-c42d-00cf4fc964ff").success)

-- GUIDs are layout only, and HttpService hands them over braced and uppercase.
local Guid = Vet.guid()

assert(Guid:safeParse(HttpService:GenerateGUID(true)).success)
assert(Guid:safeParse(HttpService:GenerateGUID(false)).success)
assert(Guid:safeParse("{6F9619FF-8B86-D011-B42D-00CF4FC964FF}").success)
assert(not Guid:safeParse("not-a-guid").success)

-- infer<S> resolves to the type a schema parses to. It runs during analysis, so
-- these annotations are the test: they only type-check if infer got it right.
type InferredUsername = Vet.infer<typeof(Username)>
type InferredLevel = Vet.infer<typeof(Level)>
type InferredEnabled = Vet.infer<typeof(Enabled)>
type InferredNickname = Vet.infer<typeof(Nickname)>

local username: InferredUsername = Username:parse("kyle")
local level: InferredLevel = Level:parse(50)
local enabled: InferredEnabled = Enabled:parse(true)
local nickname: InferredNickname = Nickname:parse(nil)

-- Assigning to the concrete type proves inference reached the right one.
local asString: string = username
local asNumber: number = level
local asBoolean: boolean = enabled
local asOptional: string? = nickname

assert(typeof(asString) == "string")
assert(typeof(asNumber) == "number")
assert(typeof(asBoolean) == "boolean")
assert(asOptional == nil)

-- A union of schemas infers to the union of their outputs.
type InferredEither = Vet.infer<typeof(Username) | typeof(Level)>

local either: InferredEither = Level:parse(7)
assert(typeof(either) == "number")

-- Arrays infer to a list, objects to a record built from the shape.
type InferredScores = Vet.infer<typeof(Scores)>
type InferredUser = Vet.infer<typeof(User)>

local scores: InferredScores = Scores:parse({ 1, 2 })
local user: InferredUser = User:parse({ name = "kyle", level = 5 })

local asList: { number } = scores
local userName: string = user.name
local userLevel: number = user.level
local userNickname: string? = user.nickname

assert(#asList == 2)
assert(userName == "kyle")
assert(userLevel == 5)
assert(userNickname == nil)

-- A defaulted field infers as required, not optional, since parse always fills it.
type InferredSettings = Vet.infer<typeof(Settings)>

local settings: InferredSettings = Settings:parse({ name = "kyle" })
local settingsVolume: number = settings.volume

assert(settingsVolume == 0.5)

-- These must NOT compile. Uncomment to confirm infer is exact rather than any:
-- local notANumber: number = username
-- local notOptional: string = nickname
-- local notAString: string = user.level
-- local notRequired: string = user.nickname

local result = Username:safeParse("k")
if not result.success then
    print(`rejected as expected: {result.issues[1].message}`)
end

print("Vet smoke test passed")
