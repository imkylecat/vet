---
sidebar_position: 1
---

# Getting Started

Vet validates unknown data against a schema and gives you back a typed value.
Define the shape once, and it serves as both the runtime check and the type.

## Installation

Add Vet to your `wally.toml`:

```toml
[dependencies]
Vet = "imkylecat/vet@0.1.0"
```

Then run `wally install`.

## Your first schema

```lua
local v = require(ReplicatedStorage.Packages.Vet)

local Username = v.string():min(3):max(22)

Username:parse("kyle") --> "kyle"
Username:parse("ky")   --> errors: expected at least 3 characters, got 2
```

Every schema starts from a constructor on `v` and is narrowed by chaining
refinements. Refinements return a *new* schema, so a base schema is safe to
share:

```lua
local Base = v.string()
local Short = Base:max(10)
local Long = Base:min(50)
-- Base itself stays unconstrained
```

## parse and safeParse

`parse` returns the value and throws when validation fails. Use it when a
failure is a bug worth surfacing.

`safeParse` never throws. Use it for data you do not control — remote
arguments, DataStore reads, HTTP responses:

```lua
local result = Username:safeParse(input)

if result.success then
	print(result.value) -- typed as string
else
	for _, issue in result.issues do
		warn(issue.message)
	end
end
```

Luau narrows on `result.success`, so `result.value` is only reachable once you
have checked it.

Every refinement runs before the result is returned, so `issues` describes each
failure rather than stopping at the first.

`parse` throws, so it is the assertion if you want one. It is named for what it
returns rather than what it raises — see [why parse and not assert](./why-parse)
for the reasoning.

## Inferring types

`v.infer` extracts the type a schema parses to, so the schema stays the only
place your field types are written down:

```lua
local User = v.object({
	name = v.string():min(3),
	nickname = v.string():optional(),
})

type User = v.infer<typeof(User)>
--> { name: string, nickname: string? }
```

It works on every schema, including nested objects and arrays.

`v.infer` is a user-defined type function, so it runs during analysis and
costs nothing at runtime. It needs a Luau version that supports user-defined
type functions — in editors that means enabling the new type solver.
