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

-- readonly and writeonly change the type a field gets, never the check. Both
-- come last in a chain, so the refinements before them still apply.
local PlayerId = Vet.number():integer():min(1):readonly()

assert(PlayerId:parse(7) == 7)
assert(not PlayerId:safeParse(0).success)
assert(not PlayerId:safeParse(1.5).success)
assert(PlayerId.access == "read")
assert(PlayerId.minimum == 1)
assert(PlayerId.isOptional == false)

local Token = Vet.string():length(4):writeonly()

assert(Token:parse("abcd") == "abcd")
assert(not Token:safeParse("abc").success)
assert(Token.access == "write")
assert(Token.maximum == 4)

-- Every schema carries a marker, so a shape can be walked without knowing
-- which kind of schema each field is.
assert(Vet.string().access == "readwrite")
assert(Vet.number():optional().access == "readwrite")
assert(Vet.boolean():default(false).access == "readwrite")
assert(Vet.literal("npc").access == "readwrite")
assert(Vet.color3().access == "readwrite")
assert(Vet.array(Vet.string()).access == "readwrite")
assert(Vet.tuple({ Vet.string() }).access == "readwrite")
assert(Vet.object({}).access == "readwrite")
assert(Vet.union({ Vet.string() }).access == "readwrite")

-- The wrappers are terminal but not a dead end: asking again is a no-op, and
-- asking for the other one replaces the marker.
assert(PlayerId:readonly() == PlayerId)
assert(PlayerId:writeonly().access == "write")
assert(PlayerId:writeonly():readonly().access == "read")
assert(PlayerId:writeonly():parse(7) == 7)

-- The standalone form takes a schema that arrived from somewhere else, and
-- carries its reflection across.
local Wrapped = Vet.readonly(Settings.shape.volume)

assert(Wrapped.access == "read")
assert(Wrapped.minimum == 0)
assert(Wrapped.maximum == 1)
assert(Wrapped:parse(nil) == 0.5)
assert(Vet.writeonly(Vet.string():optional()).isOptional)

local PlayerData = Vet.object({
    id = Vet.number():integer():readonly(),
    name = Vet.string():min(1),
    secretToken = Vet.string():length(4):writeonly(),
})

local player = PlayerData:parse({ id = 1, name = "kyle", secretToken = "abcd" })

-- The values are all there at runtime; only the type says who may touch them.
assert(player.id == 1)
assert((player :: any).secretToken == "abcd")
assert(not PlayerData:safeParse({ id = 1.5, name = "kyle", secretToken = "abcd" }).success)
assert(not PlayerData:safeParse({ id = 1, name = "kyle", secretToken = "ab" }).success)

-- The marker survives into the shape, which is where inference reads it from.
assert(PlayerData.shape.id.access == "read")
assert(PlayerData.shape.name.access == "readwrite")
assert(PlayerData.shape.secretToken.access == "write")

local badPlayer = PlayerData:safeParse({ id = 1, name = "kyle" })

assert(not badPlayer.success)

if not badPlayer.success then
    assert(badPlayer.issues[1].path[1] == "secretToken")
end

-- A default still fills in behind a marker, and the fill is what gets read.
local Filled = Vet.object({ level = Vet.number():default(1):readonly() })

assert(Filled:parse({}).level == 1)

local Waypoint = Vet.tuple({ Vet.string(), Vet.number():integer() })

assert(Waypoint:parse({ "spawn", 3 })[2] == 3)
assert(not Waypoint:safeParse({ "spawn", "3" }).success)
assert(not Waypoint:safeParse({ "spawn" }).success)
assert(not Waypoint:safeParse({ "spawn", 3, 4 }).success)

-- A position that tolerates nil may be left off the end.
local Ping = Vet.tuple({ Vet.string(), Vet.number():default(0) })

assert(Ping:parse({ "hello" })[2] == 0)

local Id = Vet.union({ Vet.string():min(1), Vet.number():integer() })

assert(Id:parse("player_1") == "player_1")
assert(Id:parse(7) == 7)
assert(not Id:safeParse(true).success)
assert(not Id:safeParse(1.5).success)
assert(not Id:safeParse("").success)

-- Nothing matching is one failure of the union, not one per option, and the
-- message says what each option made of the value.
local unmatched = Id:safeParse(1.5)

assert(not unmatched.success)

if not unmatched.success then
    assert(#unmatched.issues == 1)
    assert(#unmatched.issues[1].path == 0)
    assert(string.find(unmatched.issues[1].message, "expected an integer, got 1.5", 1, true) ~= nil)
end

-- Options are tried in order, so the wider one wins when both accept.
assert(Vet.union({ Vet.number(), Vet.number():integer() }):parse(2) == 2)

-- Reflection reaches the options, and the copy is frozen like a shape.
assert(#Id.options == 2)
assert(Id.options[1]:parse("hi") == "hi")
assert(table.isfrozen(Id.options))
assert(Id.isOptional == false)
assert(Vet.union({ Vet.string():optional(), Vet.number() }).isOptional)
-- A default option accepts nil but fills it in, so the union is not optional.
assert(not Vet.union({ Vet.string():default("x"), Vet.number() }).isOptional)
assert(Vet.union({ Vet.number(), Vet.string():default("x") }):parse(nil) == "x")

-- An empty union has nothing that could ever match. The annotation is only
-- there to give infer a schema to read; the list is still empty.
assert(not pcall(function()
    return Vet.union({} :: { Vet.StringSchema })
end))

-- Literals and objects compose into a tagged union. Annotating each tag as a
-- singleton is what lets Luau tell the arms apart after parsing.
local Join: Vet.LiteralSchema<"join"> = Vet.literal("join")
local Chat: Vet.LiteralSchema<"chat"> = Vet.literal("chat")

local Event = Vet.union({
    Vet.object({ kind = Join, userId = Vet.number() }),
    Vet.object({ kind = Chat, text = Vet.string() }),
})

local chatted = Event:parse({ kind = "chat", text = "hi" })

assert(chatted.kind == "chat")

if chatted.kind == "chat" then
    assert(chatted.text == "hi")
end

assert(not Event:safeParse({ kind = "chat", userId = 1 }).success)
assert(not Event:safeParse({ kind = "leave" }).success)

-- Nested, the issue sits at the union itself rather than inside an option.
local Payload = Vet.object({ id = Id })
local badPayload = Payload:safeParse({ id = false })

assert(not badPayload.success)

if not badPayload.success then
    assert(badPayload.issues[1].path[1] == "id")
    assert(#badPayload.issues[1].path == 1)
end

assert(#Vet.array(Id):parse({ "a", 2, "c" }) == 3)
assert(not Vet.array(Id):safeParse({ "a", true }).success)

assert(Id:optional():parse(nil) == nil)
assert(Id:default(0):parse(nil) == 0)
assert(not pcall(function()
    return Id:default(1.5)
end))

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

-- A union schema infers to the union of what its options parse to.
type InferredId = Vet.infer<typeof(Id)>

local identifier: InferredId = Id:parse(7)
local asEither: string | number = identifier

assert(asEither == 7)

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

-- Access modifiers survive inference, so the record carries Luau's `read` and
-- `write` property qualifiers rather than plain fields.
type InferredPlayerData = Vet.infer<typeof(PlayerData)>

local playerData: InferredPlayerData = PlayerData:parse({ id = 1, name = "kyle", secretToken = "abcd" })

local playerId: number = playerData.id
local playerName: string = playerData.name

-- A plain field is still writable, and a write-only one is writable but never
-- readable.
playerData.name = "alex"
playerData.secretToken = "efgh"

assert(playerId == 1)
assert(playerName == "kyle")

-- A modifier composes with the wrappers before it, and the field type stays
-- whatever the wrapped schema parses to.
local Marked = Vet.object({
    tagline = Vet.string():optional():readonly(),
    level = Vet.number():default(1):readonly(),
})

type InferredMarked = Vet.infer<typeof(Marked)>

local marked: InferredMarked = Marked:parse({})
local markedTagline: string? = marked.tagline
local markedLevel: number = marked.level

assert(markedTagline == nil)
assert(markedLevel == 1)

-- These must NOT compile. Uncomment to confirm infer is exact rather than any:
-- local notANumber: number = username
-- local notOptional: string = nickname
-- local notAString: string = user.level
-- local notRequired: string = user.nickname
-- local notEither: string = identifier

-- These must NOT compile either, which is the whole point of the modifiers:
-- playerData.id = 2
-- local leaked: string = playerData.secretToken
-- marked.level = 5
-- marked.tagline = "kyle"

local result = Username:safeParse("k")
if not result.success then
    print(`rejected as expected: {result.issues[1].message}`)
end

print("Vet smoke test passed")
