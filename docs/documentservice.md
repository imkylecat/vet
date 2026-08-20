---
sidebar_position: 3
---

# Using Vet with DocumentService

[DocumentService](https://anthony0br.github.io/DocumentService/) already expects
a schema. Every `DocumentStore` takes a `check` function that it calls before it
trusts anything it loaded, and it refuses to open a document whose data does not
pass. That is not a place to bolt validation on — it is a hole shaped exactly
like a Vet schema.

## check is the integration point

`check` has the signature `(unknown) -> (boolean, T)`: given whatever came back
from the DataStore, say whether it is valid and hand back the typed value. Vet's
`safeParse` returns the same two things, so the adapter is four lines:

```lua
local v = require(ReplicatedStorage.Packages.Vet)

local DataSchema = v.object({
    Coins = v.number():integer():min(0):default(100),
    Level = v.number():integer():min(1):max(100):default(1),
    Tagline = v.string():min(3):max(22):optional(),
})

local function check(value: unknown)
    local result = DataSchema:safeParse(value)

    if result.success then
        return true, result.value
    end

    for _, issue in result.issues do
        warn(`document invalid at {issue.path[1]}: {issue.message}`)
    end

    return false, nil
end
```

The `warn` loop matters. `check` can only answer yes or no, so the reason is
lost the moment you return `false` — DocumentService will report a `CheckError`
and nothing about which field was wrong. Logging the issues first is the
difference between "a document failed to open" and "`Coins` was -40".

## The default is the same schema

Parse nothing to get the starting document, exactly as with a profile template:

```lua
local DEFAULT = DataSchema:parse({})
--> { Coins = 100, Level = 1 }
```

`Tagline` is absent rather than `nil`-valued, because an optional field that was
not supplied is simply not there. Every other field is filled from its default,
and a field with neither a default nor `:optional()` makes this call throw —
which is what you want, since a default document cannot have a missing field.

## A store

```lua
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DocumentStore = require(ServerScriptService.DocumentService.DocumentStore)
local v = require(ReplicatedStorage.Packages.Vet)

local DataSchema = v.object({
    Coins = v.number():integer():min(0):default(100),
    Level = v.number():integer():min(1):max(100):default(1),
    Tagline = v.string():min(3):max(22):optional(),
})

type PlayerData = v.infer<typeof(DataSchema)>

local store = DocumentStore.new({
    dataStore = DataStoreService:GetDataStore("PlayerData") :: any,
    check = function(value: unknown)
        local result = DataSchema:safeParse(value)

        if result.success then
            return true, result.value
        end

        for _, issue in result.issues do
            warn(`document invalid at {issue.path[1]}: {issue.message}`)
        end

        return false, nil
    end,
    default = DataSchema:parse({}),
    migrations = {},
    lockSessions = true,
})
```

Opening follows DocumentService's own conventions — the result carries
`success` and, on failure, a `reason`:

```lua
local document = store:GetDocument(`{player.UserId}`)
local result = document:Open()

if not result.success and result.reason == "SessionLockedError" then
    document:Steal()
    result = document:Open()
end

if not result.success then
    player:Kick(`Could not load your data: {result.reason}`)
    return
end

local data = document:GetCache()
print(data.Coins) -- typed as number
```

A `CheckError` here means your schema rejected the stored data, and the warnings
from `check` are already in the log saying why.

## What this replaces

DocumentService's own guide writes `check` by hand, asserting the type of each
field and wrapping it with a helper:

```lua
local function dataCheck(value: unknown): DataSchema
    assert(type(value) == "table", "Data must be a table")
    -- one assert per field, by hand
end
```

That works, and it is one more thing to keep in step with the default document
and the type. With a schema you write the shape once and get all three, plus
the parts an `assert` chain usually skips: ranges, string lengths, optionality,
and a message naming the field rather than the first `assert` that fired.

## Fits the immutable cache

`SetCache` expects you not to mutate the previous cache in place, which suits
how Vet parses. A value that satisfies its schema comes back as the same table
you passed in — nothing is copied, and nothing is modified. A copy is made only
when a default fills a field in, and then the original is left untouched:

```lua
local current = document:GetCache()

document:SetCache({
    Coins = current.Coins + 100,
    Level = current.Level,
    Tagline = current.Tagline,
})
```

If you want to be sure a hand-built cache is still valid before storing it,
parse it first — this is the same check the store will run on the way back in,
so running it early turns a failed load tomorrow into a caught bug today:

```lua
document:SetCache(DataSchema:parse(nextCache))
```

## Migrations

DocumentService applies migrations to bring old documents up to the current
shape, then runs `check`. Keeping one schema per version makes the two agree:
the migration describes how the data moves, and the schema for that version
describes what it should look like when it arrives.

```lua
local V1 = v.object({
    Coins = v.number():integer():min(0):default(100),
})

local V2 = v.object({
    Coins = v.number():integer():min(0):default(100),
    Level = v.number():integer():min(1):max(100):default(1),
})
```

Point `check` at the current version. The older schemas stay useful as a record
of what each migration was migrating from, and you can parse against them while
writing a migration to confirm the input really is the shape you think it is.

## Typing the data

`v.infer` gives you the type DocumentService is generic over:

```lua
type PlayerData = v.infer<typeof(DataSchema)>
--> { Coins: number, Level: number, Tagline: string? }
```

`GetCache` returns that type, so `data.Coins` is a `number` and `data.Tagline` is
a `string?` you have to handle. The shape is written once, and the check, the
default document, and the type all come from it.
