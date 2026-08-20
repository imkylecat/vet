# Vet

Lua-first schema validation with type inference

```lua
local v = require(ReplicatedStorage.Packages.Vet)

local Profile = v.object({
    Tagline = v.string():min(3):max(22),
    Level = v.number():integer():min(1):max(100):default(1),
    Money = v.number():integer():min(0):max(100000):default(0),
})

-- Fields with a default are filled in when they are missing.
Profile:parse({ Tagline = "kyle" })
--> { Tagline = "kyle", Level = 1, Money = 0 }

Profile:parse({ Tagline = "kyle", Level = 42 })
--> { Tagline = "kyle", Level = 42, Money = 0 }

-- parse throws, and the message names the field that failed.
Profile:parse({ Tagline = "ky" })
--> errors: Tagline: expected at least 3 characters, got 2

-- Every field is checked, so one call reports everything that is wrong.
Profile:parse({ Tagline = "ky", Level = 900 })
--> errors: Tagline: expected at least 3 characters, got 2;
--          Level: expected at most 100, got 900
```

The schema is the type too, so the fields are written down only once:

```lua
type Profile = v.infer<typeof(Profile)>
--> { Tagline: string, Level: number, Money: number }
```
