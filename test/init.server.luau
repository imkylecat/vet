--!strict

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
assert(Enabled:isTrue():safeParse(true).success)
assert(not Enabled:isTrue():safeParse(false).success)

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
