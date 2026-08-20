---
sidebar_position: 2
---

# Using Vet with ProfileStore

[ProfileStore](https://madstudioroblox.github.io/ProfileStore/) saves whatever
you put in `Profile.Data`. It does not care what that is, and it will happily
persist a `Money` of `-2000000`, a `Level` that is a string, or a field your
code stopped writing two updates ago.

A Vet schema gives you one description of the shape that serves as the profile
template, the runtime check, and the Luau type — and catches the values
ProfileStore cannot.

## What goes wrong without it

**Your saved data outlives your code.** Every profile in your DataStore was
written by some past version of your game. Change a rule today and yesterday's
data does not change with it. Cap `Money` at 100,000 and the player who banked
five million during a broken promo still has five million.

**Bad data is sticky.** Once a wrong value is in `Profile.Data` it saves again
on the next autosave, and the one after that. The gap between writing it and
noticing it is the difference between one confused player and a support
backlog.

**`Reconcile` does not look at values.** It copies keys the template has and the
save is missing. That is all. A `Level` of `-4`, a `Tagline` holding a table, a
number where you expected a string — all reconcile cleanly and load without a
word.

**Three places drift apart.** Without a schema you write the template literal,
then the Luau type, then whatever ad-hoc checks you sprinkle around. Nothing
keeps them in agreement, and the disagreement shows up as corrupt saves.

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

Kicking is the blunt option. Refusing to load is often the right call, because
a session that starts on bad data will save that data back — but see
[what to do about it](#deciding-what-to-do) for the alternatives.

## Reconcile fills, Vet verifies

The two do different jobs and you want both:

- `profile:Reconcile()` copies keys the template has and the saved profile is
  missing. It does not look at the values.
- `ProfileSchema:safeParse(profile.Data)` checks the values. A `Money` of `-5`,
  a `Level` of `9999`, or a `Tagline` that ended up holding a table are all
  caught here and nowhere else.

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

## Catching bad writes before they save

Validating on load catches data that was already wrong. The more valuable check
is on the way out, because that is where **your own code** puts bad values in.

Exploiters cannot touch `Profile.Data` — it only exists on the server. Every
wrong value in it was written by a line you wrote: an unchecked remote argument
stored straight into the profile, a subtraction that went negative, a reward
multiplied by an empty variable. `Profile.OnSave` fires immediately before each
autosave, so it is the last point where you can notice:

```lua
profile.OnSave:Connect(function()
    local result = ProfileSchema:safeParse(profile.Data)

    if result.success then
        return
    end

    for _, issue in result.issues do
        warn(`{player.UserId} writing invalid {issue.path[1]}: {issue.message}`)
    end
end)
```

This turns "a player emails you in three weeks" into a warning in your logs the
first time it happens, with the field name and what was wrong with it.

:::caution

`OnSave` must not yield. `safeParse` does not, but do not add a `task.wait` or a
`:WaitForChild` next to it — ProfileStore only guarantees that changes made at
the moment `OnSave` fires are included in that save.

:::

You cannot cancel a save from `OnSave`. You can, however, repair the value
before it goes out, since changes made during the callback are included:

```lua
profile.OnSave:Connect(function()
    local result = ProfileSchema:safeParse(profile.Data)

    if not result.success then
        warn(`{player.UserId} profile repaired before save`)
        profile.Data.Money = math.clamp(profile.Data.Money, 0, 100000)
    end
end)
```

Prefer logging while you are still finding bugs. Silent repair keeps players
playing, but it also hides the bug that caused the bad value.

## Deciding what to do

Loading an invalid profile leaves you three choices, and the right one depends
on what failed:

- **Refuse the session.** End it and kick. Correct when the data is unusable and
  starting anyway would save the damage back.
- **Repair and continue.** Clamp the field, or overwrite it from the template.
  Correct for values that are merely out of range, where a slightly wrong
  number beats locking someone out of their account.
- **Load anyway and report.** Correct while you are still learning which rules
  are too strict. A schema tightened in the wrong place should not lock out a
  thousand players before you notice.

Whichever you choose, `issue.path` tells you which field failed, so you can
branch on it rather than treating every failure the same.

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

That is the whole argument in one line: the shape is written once, and the
template, the runtime check, and the type all come from it.
