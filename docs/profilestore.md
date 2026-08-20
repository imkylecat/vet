---
sidebar_position: 2
---

# Using Vet with ProfileStore

[ProfileStore](https://madstudioroblox.github.io/ProfileStore/) needs a profile
template — the data a brand new player starts with. A Vet schema already
describes that, so you can write the shape once and get the template, the
validation, and the Luau type from it.

## The schema is the template

Give every field either a default or `:optional()`, then parse nothing:

```lua
local v = require(ReplicatedStorage.Packages.Vet)

local ProfileSchema = v.object({
    Tagline = v.string():min(3):max(22):optional(),
    Level = v.number():integer():min(1):max(100):default(1),
    Money = v.number():integer():min(0):max(100000):default(0),
})

local PROFILE_TEMPLATE = ProfileSchema:parse({})
--> { Level = 1, Money = 0 }
```

`Tagline` is absent rather than `nil`-valued, because an optional field that was
not supplied is simply not there. `Level` and `Money` are filled from their
defaults.

Each call returns a fresh table, so nothing is shared between profiles.

:::tip

If a field has neither a default nor `:optional()`, `parse({})` throws. That is
the point — a profile template has to have a value for every field, and this
makes the omission a startup error rather than a `nil` that surfaces in
production three weeks later.

:::

## A full session

Everything below is the standard ProfileStore flow, with the template coming
from the schema and one validation step added after `Reconcile`:

```lua
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ProfileStore = require(ServerScriptService.ProfileStore)
local v = require(ReplicatedStorage.Packages.Vet)

local ProfileSchema = v.object({
    Tagline = v.string():min(3):max(22):optional(),
    Level = v.number():integer():min(1):max(100):default(1),
    Money = v.number():integer():min(0):max(100000):default(0),
})

local PROFILE_TEMPLATE = ProfileSchema:parse({})

local PlayerStore = ProfileStore.New("PlayerStore", PROFILE_TEMPLATE)
local Profiles: { [Player]: typeof(PlayerStore:StartSessionAsync()) } = {}

local function PlayerAdded(player)
    local profile = PlayerStore:StartSessionAsync(`{player.UserId}`, {
        Cancel = function()
            return player.Parent ~= Players
        end,
    })

    if profile == nil then
        player:Kick(`Profile load fail - Please rejoin`)
        return
    end

    profile:AddUserId(player.UserId)
    profile:Reconcile()

    -- Reconcile fills in keys the template has and the save does not. Vet
    -- checks the values themselves, which reconciling cannot do.
    local result = ProfileSchema:safeParse(profile.Data)

    if not result.success then
        for _, issue in result.issues do
            warn(`{player.UserId} profile invalid at {issue.path[1]}: {issue.message}`)
        end

        profile:EndSession()
        player:Kick(`Profile invalid - Please contact support`)
        return
    end

    profile.OnSessionEnd:Connect(function()
        Profiles[player] = nil
        player:Kick(`Profile session end - Please rejoin`)
    end)

    if player.Parent == Players then
        Profiles[player] = profile
        profile.Data.Money += 100
    else
        profile:EndSession()
    end
end

for _, player in Players:GetPlayers() do
    task.spawn(PlayerAdded, player)
end

Players.PlayerAdded:Connect(PlayerAdded)

Players.PlayerRemoving:Connect(function(player)
    local profile = Profiles[player]

    if profile ~= nil then
        profile:EndSession()
    end
end)
```

## Reconcile fills, Vet verifies

The two do different jobs and you want both:

- `profile:Reconcile()` copies keys the template has and the saved profile is
  missing. It does not look at the values.
- `ProfileSchema:safeParse(profile.Data)` checks the values. A `Money` of `-5`,
  a `Level` of `9999`, or a `Tagline` someone injected through an exploit are
  all caught here and nowhere else.

Validate **after** reconciling, so a profile saved before you added a field is
not reported as invalid for missing it.

Note that the example does not assign the parsed value back onto
`profile.Data`. It does not need to: after `Reconcile`, there is nothing left
for the schema to fill, so `safeParse` hands back the same table it was given.
Mutate `profile.Data` in place as usual.

That gives you a free consistency check:

```lua
if result.value ~= profile.Data then
    -- A default fired, so the template no longer matches the schema.
    -- PROFILE_TEMPLATE was probably built from an older version.
    warn("profile template is out of sync with the schema")
end
```

## Adding a field later

Add it to the schema with a default. The template picks it up automatically on
the next server start, and `Reconcile` copies it into existing profiles:

```lua
local ProfileSchema = v.object({
    Tagline = v.string():min(3):max(22):optional(),
    Level = v.number():integer():min(1):max(100):default(1),
    Money = v.number():integer():min(0):max(100000):default(0),
    Gems = v.number():integer():min(0):default(0), -- new
})
```

There is no second place to update, which is the point — a template and a
validator that are edited separately drift apart, and the drift shows up as
corrupt saves.

## Typing the data

`v.infer` gives you the type of `profile.Data` from the same schema:

```lua
type ProfileData = v.infer<typeof(ProfileSchema)>
--> { Tagline: string?, Level: number, Money: number }
```

`Tagline` is `string?` because it is optional, while `Level` and `Money` are
plain `number` — a field with a default is always present after parsing, so
there is nothing to check for at the call site.
