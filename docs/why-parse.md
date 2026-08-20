---
sidebar_position: 4
---

# Why parse and not assert

A fair question, and one worth answering properly rather than pointing at
another library: `parse` throws when validation fails, so why not call it
`assert`?

## The short answer

Because it hands something back, and that something is not always what you gave
it.

An assertion is a guard. You call it for its side effect, and if it returns at
all you carry on with the value you already had. That is what `assert` means in
Lua, and naming a method `assert` promises the same:

```lua
Settings:assert(raw)
-- looks safe to keep using `raw`
```

That promise would be false here. Parsing fills in defaults, so the value that
comes back is not the value that went in:

```lua
local Settings = v.object({
    Volume = v.number():min(0):max(1):default(0.5),
    Muted = v.boolean():default(false),
})

local raw = { Volume = 0.2 }
local settings = Settings:parse(raw)

raw.Muted      --> nil
settings.Muted --> false
```

Under an `assert` name, the line above reads as a check you can ignore the
result of, and ignoring it silently drops every default. Under `parse` it reads
as a conversion, and the shape of the call makes you keep the result. The name
is doing real work.

:::note

The input is never modified. `parse` copies before writing a filled value in,
and returns the original table untouched when there is nothing to fill:

```lua
local complete = { Volume = 0.2, Muted = true }
Settings:parse(complete) == complete --> true
```

:::

## It still asserts

`parse` throws on failure, and the message names the field:

```lua
Settings:parse({ Volume = 4 })
--> Volume: expected at most 1, got 4
```

So if what you wanted was an assertion, you have one. Nothing about the name
takes that away — it just also gives you the parsed value, and does not pretend
the input was already fine.

## parse and safeParse

Two methods, one distinction: what happens when the data is wrong.

| | Throws | Returns |
| --- | --- | --- |
| `parse` | Yes | The validated value |
| `safeParse` | No | `{ success, value }` or `{ success, issues }` |

Use `parse` when bad data is a bug — your own config, a constant, a value your
code just built. Use `safeParse` when bad data is expected — remote arguments,
DataStore reads, HTTP responses — and you want to decide what to do rather than
unwind the stack:

```lua
local result = Settings:safeParse(payload)

if result.success then
    apply(result.value)
else
    for _, issue in result.issues do
        warn(issue.path, issue.message)
    end
end
```

## On matching Roblox conventions

The convention this usually gets measured against is
[t](https://github.com/osyrisrblx/t), and t is a predicate library: a checker is
`(value) -> (boolean, string?)`, and `t.strict` wraps one so it raises. For a
predicate, `assert` is the right word — there is no value to hand back, so
asserting is all it can do.

Vet is not a predicate library. Its checkers return the validated value, which
is what makes defaults and [type inference](./intro#inferring-types) work at
all. Borrowing the vocabulary of a design it does not share would be the
confusing choice, not the conforming one.

Where Vet does follow the platform, it follows it properly:
[datatypes](/api/DatatypeSchema) are checked with `typeof` rather than by
shape, so a table carrying `R`, `G` and `B` is not a `Color3`, and the
[ProfileStore](./profilestore) and [DocumentService](./documentservice) guides
use each library's own conventions rather than wrapping them in something new.
The name `parse` is not a Roblox-versus-elsewhere question — it is a question of
whether the method returns something you need to keep. It does.
