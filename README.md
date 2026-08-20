# Vet

Lua-first schema validation with type inference

```lua
local v = require(ReplicatedStorage.Packages.Vet)

local Profile = v.object({
    Tagline = v.string():min(3):max(22):optional(),
    Level = v.number():integer():min(1):max(100):default(1),
    Money = v.number():integer():min(0):max(100000):default(0),
})

-- An optional field may be missing. A field with a default gets filled in.
Profile:parse({})
--> { Level = 1, Money = 0 }

Profile:parse({ Tagline = "kyle" })
--> { Tagline = "kyle", Level = 1, Money = 0 }

Profile:parse({ Tagline = "kyle", Level = 42 })
--> { Tagline = "kyle", Level = 42, Money = 0 }

-- Optional is not unchecked: a value that is present still has to be valid.
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
--> { Tagline: string?, Level: number, Money: number }
```

## Compared to t

[t](https://github.com/osyrisrblx/t) is the established runtime type checker for
Roblox, and it is a good library. The difference is not features first — it is
what a schema is for.

**t checks. Vet parses.** A `t` checker is a predicate, `(value) -> (boolean,
string?)`. It answers whether a value is acceptable and then gets out of the
way:

```lua
local checkProfile = t.interface({
    Tagline = t.optional(t.string),
    Level = t.numberConstrained(1, 100),
})

if checkProfile(data) then
    -- `data` is the same untyped table you started with
end
```

A Vet schema hands back the validated value, which is what makes defaults and
type inference possible at all:

```lua
local profile = Profile:parse(data)
--> Level and Money filled in, typed as { Tagline: string?, Level: number, ... }
```

That one difference is where the rest of it comes from. Because parsing returns
a value it can fill defaults, so the schema doubles as the default document for
[ProfileStore](./profilestore) or [DocumentService](./documentservice). Because
it returns a *typed* value, `v.infer` can derive the Luau type from the same
declaration instead of you writing it twice.

|  | t | Vet |
| --- | --- | --- |
| Shape | Predicate returning `boolean, string?` | Parser returning the validated value |
| Luau type | Written separately by hand | Derived with `v.infer` |
| Defaults | — | `:default(v)` and `:defaultWith(f)` |
| Errors | First failure, one string | Every failure, each with a path like `members[1].level` |
| Introspection | — | `shape`, `minimum`, `maximum`, `isOptional` |
| Roblox datatypes | All of them | `color3`, `udim2` so far |
| Instances | `instanceOf`, `instanceIsA`, `children` | — |
| Unions, maps, patterns | `union`, `intersection`, `map`, `keys`, `values`, `match` | `union` |
| Requires the new type solver | No | Yes, for `v.infer` |

### When t is the better choice

- **You want breadth today.** t covers every Roblox datatype, Instances, Enums,
  maps, intersections and string patterns. Vet has `union`, but none of the
  other three yet.
- **You are checking function arguments.** `t.wrap` and `t.tuple` are built for
  it, and a predicate is the right shape when there is no value to hand back.
- **You cannot enable the new type solver.** `v.infer` is a user-defined type
  function, so it needs a Luau version that supports them. Everything else in
  Vet works without it, but the headline feature does not.
- **You want the smaller, settled dependency.** t is widely used and has been
  stable for years.

### When Vet is the better choice

- **The data is stored, not just checked.** Defaults mean the schema is also the
  template, and one declaration stops the template, the validator and the type
  from drifting apart.
- **You want the type for free.** `v.infer` derives it from the schema.
- **You need to know what failed, not just that something did.** Issue paths
  point at `members[1].level` rather than handing you one string about the
  outermost table.
- **Something else reads the schema.** `Profile.shape.Level.minimum` can drive a
  slider range or an input limit without restating the bound.
