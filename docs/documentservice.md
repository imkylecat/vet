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
`safeParse` returns the same two things, so the adapter is a few lines:

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
lost the moment you return `false` — DocumentService reports the failure as
`"CheckError"` and nothing about which field was wrong. Logging the issues first
is the difference between "a document failed to open" and "`Coins` was -40".

## The default is the same schema

Parse nothing to get the starting document:

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
local ServerScriptService = game:GetService("ServerScriptService")

local DocumentStore = require(ServerScriptService.DocumentService.DocumentStore)

type PlayerData = v.infer<typeof(DataSchema)>

local store = DocumentStore.new({
    dataStore = DataStoreService:GetDataStore("PlayerData") :: any,
    check = check,
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

print(document:GetCache().Coins) -- typed as number
```

Of the reasons DocumentService can give — `"RobloxAPIError"`,
`"SessionLockedError"`, `"CheckError"`, `"BackwardsCompatibilityError"` and
`"SchemaError"` — only `"CheckError"` comes from your schema, and the warnings
from `check` are already in the log saying why.

## Validating on the way in, not just out

`check` guards what you load. It does not guard what you write: the cache is
yours to set, and a bad value goes to the DataStore without complaint. You find
out on the next load, in a different session, with no idea which line put it
there.

`Update` takes a `Transform<T>`, which is `(data: T) -> T` — a pure function
returning the next state. Parsing on the way out closes the loop:

```lua
local result = document:Update(function(data)
    local next = table.clone(data)
    next.Coins = data.Coins + reward

    return DataSchema:parse(next)
end)
```

If `reward` was negative, or a bug pushed `Coins` past its cap, this throws
inside the transform instead of persisting. The same call works on
`OpenAndUpdate`, and on a plain `SetCache`:

```lua
document:SetCache(DataSchema:parse(next))
```

This suits DocumentService's immutable cache rather than fighting it. A value
that already satisfies its schema comes back as the same table — nothing is
copied and nothing is modified — and a copy is made only when a default fills a
field in, leaving the original untouched.

## Migrations

A migration is an entry in an ordered array:

```lua
export type Migrations = {
    {
        backwardsCompatible: boolean,
        migrate: (data: any) -> any,
    }
}
```

`migrate` receives `any` and returns `any`, so nothing checks that it produced
what the next version expects. Keeping a schema per version makes it check
itself — parse the result and the migration cannot quietly emit the wrong
shape:

```lua
local V1 = v.object({
    Coins = v.number():integer():min(0):default(100),
})

local V2 = v.object({
    Coins = v.number():integer():min(0):default(100),
    Level = v.number():integer():min(1):max(100):default(1),
})

local migrations = {
    {
        backwardsCompatible = true,
        migrate = function(data)
            local previous = V1:parse(data)

            return V2:parse({
                Coins = previous.Coins,
                -- Level is filled from its default
            })
        end,
    },
}
```

Parsing the input as well as the output is worth the extra line: it fails inside
the migration you are writing, naming the field, rather than as a `CheckError`
on a document you cannot see. Point `check` at the newest version and keep the
older schemas around — they are the record of what each migration was migrating
from.

## Documents nobody owns

Session locking makes one server responsible for a document at a time. Turn it
off — `lockSessions = false`, for a shared house, a guild bank, a global
leaderboard — and several servers write to the same key through `Update`
transactions.

Validation matters more there, not less. With a session lock, a bad value is one
player's problem and one server wrote it. Without one, any server can write, and
the next transform starts from whatever the last one left. Parsing inside the
transform keeps a bad state from becoming the base for every write after it.

## Typing the data

`v.infer` gives you the type DocumentService is generic over:

```lua
type PlayerData = v.infer<typeof(DataSchema)>
--> { Coins: number, Level: number, Tagline: string? }
```

`GetCache` returns that type, so `data.Coins` is a `number` and `data.Tagline` is
a `string?` you have to handle.

## What this replaces

DocumentService's own guide writes `check` by hand, asserting the type of each
field and wrapping it with a helper:

```lua
local function dataCheck(value: unknown): DataSchema
    assert(type(value) == "table", "Data must be a table")
    -- one assert per field, by hand
end
```

That works, and it is three things to keep in step: the assert chain, the
default document, and the type. With a schema the shape is written once and all
three come from it — plus the parts an `assert` chain usually skips, like
ranges, string lengths, optionality, and a message naming the field rather than
the first `assert` that fired.
