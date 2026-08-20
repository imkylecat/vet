# Vet

Lua-first schema validation with type inference

```luau
local Vet = require(ReplicatedStorage.Packages.Vet)

local Username = Vet.string():min(3):max(22)
local Level = Vet.number():integer():min(1):max(100)

Username:parse("kyle") --> "kyle"
Username:parse("ky")   --> errors: expected at least 3 characters, got 2
```
