--!strict

--[=[
	@class Vet

	Lua-first schema validation with type inference.

	```lua
	local v = require(ReplicatedStorage.Packages.Vet)

	local Name = v.string():min(3):max(22)

	Name:parse("kyle") --> "kyle"
	Name:parse("ky")   --> errors
	```
]=]

--[=[
	@interface Issue
	@within Vet
	.path { string | number } -- Location of the failure inside the value
	.message string -- Human-readable description of the failure
]=]
export type Issue = {
    path: { string | number },
    message: string,
}

--[=[
	@type Result<T> { success: true, value: T } | { success: false, issues: { Issue } }
	@within Vet

	Returned by `safeParse`. Narrow it with `if result.success then` to get a
	typed `result.value`.
]=]
export type Result<T> = { success: true, value: T } | { success: false, issues: { Issue } }

--[=[
	@type infer<S> the value type produced by schema S
	@within Vet

	Extracts the type a schema parses to, so a schema can be the single source
	of truth for both validation and types.

	```lua
	local Username = v.string():min(3)
	type Username = v.infer<typeof(Username)> --> string

	local Nickname = v.string():optional()
	type Nickname = v.infer<typeof(Nickname)> --> string?
	```

	Given a union of schemas, the result is the union of what each one parses
	to: `Vet.infer<StringSchema | NumberSchema>` is `string | number`.

	This is a user-defined type function, so it runs during analysis and costs
	nothing at runtime. It requires a Luau version that supports user-defined
	type functions.
]=]
export type function infer(schema)
    local PARSE = types.singleton("parse")

    local function outputOf(candidate)
        if not candidate:is("table") then
            error(`expected a schema, got a {candidate.tag}`)
        end

        -- Closure-based schemas hold `parse` directly; metatable-based ones
        -- keep it on the metatable, either as a property or behind __index.
        local parse = candidate:readproperty(PARSE)

        if parse == nil then
            local metatable = candidate:metatable()

            if metatable ~= nil then
                parse = metatable:readproperty(PARSE)

                if parse == nil then
                    local index = metatable:readproperty(types.singleton("__index"))

                    if index ~= nil and index:is("table") then
                        parse = index:readproperty(PARSE)
                    end
                end
            end
        end

        if parse == nil then
            error("expected a schema with a `parse` method")
        end

        if not parse:is("function") then
            error("expected `parse` to be a method")
        end

        local head = parse:returns().head

        if head == nil or #head == 0 then
            error("expected `parse` to return a value")
        end

        return head[1]
    end

    if schema:is("union") then
        local outputs = {}

        for _, component in schema:components() do
            table.insert(outputs, outputOf(component))
        end

        if #outputs == 1 then
            return outputs[1]
        end

        return types.unionof(unpack(outputs))
    end

    return outputOf(schema)
end

--[=[
	@type objectOutput<S> the record type a shape of schemas parses to
	@within Vet

	Maps `{ name: StringSchema, age: NumberSchema }` to `{ name: string, age:
	number }`. Used to type the result of `Vet.object`, so the shape you pass in
	is the only place the field types are written down.

	The property walk duplicates the one in [Vet.infer] because a type function
	cannot call another type function.
]=]
export type function objectOutput(shape)
    if not shape:is("table") then
        error(`expected a table of schemas, got a {shape.tag}`)
    end

    local PARSE = types.singleton("parse")
    local output = types.newtable()

    for key, property in shape:properties() do
        local candidate = property.read

        if candidate == nil or not candidate:is("table") then
            error("expected every field to be a schema")
        end

        local parse = candidate:readproperty(PARSE)

        if parse == nil then
            local metatable = candidate:metatable()

            if metatable ~= nil then
                parse = metatable:readproperty(PARSE)

                if parse == nil then
                    local index = metatable:readproperty(types.singleton("__index"))

                    if index ~= nil and index:is("table") then
                        parse = index:readproperty(PARSE)
                    end
                end
            end
        end

        if parse == nil or not parse:is("function") then
            error("expected every field to be a schema with a `parse` method")
        end

        local head = parse:returns().head

        if head == nil or #head == 0 then
            error("expected `parse` to return a value")
        end

        output:setproperty(key, head[1])
    end

    return output
end

type Check<T> = (value: T) -> string?

local function append<T>(list: { T }, item: T): { T }
    local copy = table.clone(list)
    table.insert(copy, item)
    return copy
end

local function fail(message: string): Result<any>
    return { success = false, issues = { { path = {}, message = message } } }
end

local function run<T>(value: T, checks: { Check<T> }): Result<T>
    local issues: { Issue } = {}

    for _, check in checks do
        local message = check(value)
        if message then
            table.insert(issues, { path = {}, message = message })
        end
    end

    if #issues > 0 then
        return { success = false, issues = issues }
    end

    return { success = true, value = value }
end

local function prependPath(key: string | number, path: { string | number }): { string | number }
    local combined = table.create(#path + 1)
    combined[1] = key
    table.move(path, 1, #path, 2, combined)
    return combined
end

local function formatPath(path: { string | number }): string
    local parts = {}

    for _, key in path do
        if type(key) == "number" then
            table.insert(parts, `[{key}]`)
        elseif #parts == 0 then
            table.insert(parts, key)
        else
            table.insert(parts, `.{key}`)
        end
    end

    return table.concat(parts)
end

local function describe(issues: { Issue }): string
    local messages = {}

    for _, issue in issues do
        if #issue.path > 0 then
            table.insert(messages, `{formatPath(issue.path)}: {issue.message}`)
        else
            table.insert(messages, issue.message)
        end
    end

    return table.concat(messages, "; ")
end

--[=[
	@class OptionalSchema

	Accepts `nil` in addition to whatever the wrapped schema accepts. Created by
	calling `:optional()` on any schema, which comes last in a chain so that the
	refinements before it still apply to non-nil values.

	```lua
	local Nickname = v.string():max(20):optional()

	Nickname:parse(nil)        --> nil
	Nickname:parse("kyle")     --> "kyle"
	Nickname:parse(5)          --> errors
	```
]=]
export type OptionalSchema<T> = {
    safeParse: (self: OptionalSchema<T>, value: unknown) -> Result<T?>,
    parse: (self: OptionalSchema<T>, value: unknown) -> T?,
    optional: (self: OptionalSchema<T>) -> OptionalSchema<T>,
}

local function newOptional<T>(inner: (value: unknown) -> Result<T>): OptionalSchema<T>
    local self = {}

    --[=[
		@within OptionalSchema
		@method safeParse
		@tag Parsing
		@param value unknown
		@return Result<T?>

		Succeeds with `nil` when `value` is `nil`, and otherwise defers to the
		wrapped schema.
	]=]
    function self:safeParse(value: unknown): Result<T?>
        if value == nil then
            return { success = true, value = nil }
        end

        local result = inner(value)
        if result.success then
            return { success = true, value = result.value }
        end

        return { success = false, issues = result.issues }
    end

    --[=[
		@within OptionalSchema
		@method parse
		@tag Parsing
		@param value unknown
		@return T?
		@error "expected ..." -- Thrown when a non-nil `value` fails validation

		Validates `value` and returns it, throwing on failure.
	]=]
    function self:parse(value: unknown): T?
        local result = self:safeParse(value)
        if result.success then
            return result.value
        end

        error(describe(result.issues), 2)
    end

    --[=[
		@within OptionalSchema
		@method optional
		@tag Wrapper
		@return OptionalSchema<T>

		Returns the same schema, since it already accepts `nil`.
	]=]
    function self:optional(): OptionalSchema<T>
        return self
    end

    return (self :: any) :: OptionalSchema<T>
end

--[=[
	@class DefaultSchema

	Substitutes a fallback when the value is `nil`. Unlike [OptionalSchema] the
	result is never `nil`, so downstream code does not have to handle a missing
	value.

	```lua
	local Volume = v.number():min(0):max(1):default(0.5)

	Volume:parse(nil)  --> 0.5
	Volume:parse(0.2)  --> 0.2
	Volume:parse(2)    --> errors
	```

	Pass a function to build the fallback per parse, which matters for tables
	since a constant would be shared by every caller:

	```lua
	local Tags = v.array(v.string()):default(function()
		return {}
	end)
	```
]=]
export type DefaultSchema<T> = {
    safeParse: (self: DefaultSchema<T>, value: unknown) -> Result<T>,
    parse: (self: DefaultSchema<T>, value: unknown) -> T,
}

local function newDefault<T>(inner: (value: unknown) -> Result<T>, fallback: T | () -> T): DefaultSchema<T>
    local self = {}
    local produce: (() -> T)? = nil
    local constant: T = nil :: any

    if type(fallback) == "function" then
        produce = fallback :: () -> T
    else
        -- Validate a constant fallback up front, so a mistake surfaces where
        -- the schema is written rather than on some later parse of nil.
        local result = inner(fallback :: any)

        if not result.success then
            error(`default value is invalid: {describe(result.issues)}`, 3)
        end

        constant = result.value
    end

    --[=[
		@within DefaultSchema
		@method safeParse
		@tag Parsing
		@param value unknown
		@return Result<T>

		Returns the fallback when `value` is `nil`, and otherwise defers to the
		wrapped schema. A fallback built by a function is validated too.
	]=]
    function self:safeParse(value: unknown): Result<T>
        if value == nil then
            if produce ~= nil then
                return inner(produce())
            end

            return { success = true, value = constant }
        end

        return inner(value)
    end

    --[=[
		@within DefaultSchema
		@method parse
		@tag Parsing
		@param value unknown
		@return T
		@error "expected ..." -- Thrown when a non-nil `value` fails validation

		Validates `value` and returns it, throwing on failure.
	]=]
    function self:parse(value: unknown): T
        local result = self:safeParse(value)
        if result.success then
            return result.value
        end

        error(describe(result.issues), 2)
    end

    return (self :: any) :: DefaultSchema<T>
end

--[=[
	@class StringSchema

	Validates strings. Every refinement returns a new schema, so a base schema
	can be shared and specialised without being modified.

	```lua
	local Base = v.string()
	local Username = Base:min(3):max(22)
	```
]=]
type StringImpl = {
    __index: StringImpl,
    safeParse: (self: StringSchema, value: unknown) -> Result<string>,
    parse: (self: StringSchema, value: unknown) -> string,
    min: (self: StringSchema, n: number) -> StringSchema,
    max: (self: StringSchema, n: number) -> StringSchema,
    length: (self: StringSchema, n: number) -> StringSchema,
    optional: (self: StringSchema) -> OptionalSchema<string>,
    default: (self: StringSchema, fallback: string | () -> string) -> DefaultSchema<string>,
}

export type StringSchema = typeof(setmetatable({} :: { _checks: { Check<string> } }, {} :: StringImpl))

local StringSchema = {} :: StringImpl
StringSchema.__index = StringSchema

local function newString(checks: { Check<string> }): StringSchema
    return setmetatable({ _checks = checks }, StringSchema)
end

--[=[
	@within StringSchema
	@tag Parsing
	@param value unknown
	@return Result<string>

	Validates `value` without throwing. All refinements run, so the returned
	issues describe every failure rather than only the first.
]=]
function StringSchema:safeParse(value: unknown): Result<string>
    if type(value) ~= "string" then
        return fail(`expected string, got {typeof(value)}`)
    end

    return run(value, self._checks)
end

--[=[
	@within StringSchema
	@tag Parsing
	@param value unknown
	@return string
	@error "expected ..." -- Thrown when `value` fails validation

	Validates `value` and returns it, throwing on failure.
]=]
function StringSchema:parse(value: unknown): string
    local result = self:safeParse(value)
    if result.success then
        return result.value
    end

    error(describe(result.issues), 2)
end

--[=[
	@within StringSchema
	@tag Refinement
	@param n number -- Minimum length, inclusive
	@return StringSchema

	Requires the string to be at least `n` characters long.
]=]
function StringSchema:min(n: number): StringSchema
    return newString(append(self._checks, function(value)
        return if #value < n then `expected at least {n} characters, got {#value}` else nil
    end))
end

--[=[
	@within StringSchema
	@tag Refinement
	@param n number -- Maximum length, inclusive
	@return StringSchema

	Requires the string to be at most `n` characters long.
]=]
function StringSchema:max(n: number): StringSchema
    return newString(append(self._checks, function(value)
        return if #value > n then `expected at most {n} characters, got {#value}` else nil
    end))
end

--[=[
	@within StringSchema
	@tag Refinement
	@param n number -- Exact length
	@return StringSchema

	Requires the string to be exactly `n` characters long.
]=]
function StringSchema:length(n: number): StringSchema
    return newString(append(self._checks, function(value)
        return if #value ~= n then `expected exactly {n} characters, got {#value}` else nil
    end))
end

--[=[
	@within StringSchema
	@tag Wrapper
	@return OptionalSchema<string>

	Wraps this schema so that `nil` is also accepted.
]=]
function StringSchema:optional(): OptionalSchema<string>
    local inner = self
    return newOptional(function(value)
        return inner:safeParse(value)
    end)
end

--[=[
	@within StringSchema
	@tag Wrapper
	@param fallback string | () -> string -- Value used when parsing `nil`
	@return DefaultSchema<string>

	Wraps this schema so that `nil` yields `fallback` instead of failing.
]=]
function StringSchema:default(fallback: string | () -> string): DefaultSchema<string>
    local inner = self
    return newDefault(function(value)
        return inner:safeParse(value)
    end, fallback)
end

--[=[
	@class NumberSchema

	Validates numbers. NaN is rejected before any refinement runs.

	```lua
	local Level = v.number():integer():min(1):max(100)
	```
]=]
type NumberImpl = {
    __index: NumberImpl,
    safeParse: (self: NumberSchema, value: unknown) -> Result<number>,
    parse: (self: NumberSchema, value: unknown) -> number,
    min: (self: NumberSchema, n: number) -> NumberSchema,
    max: (self: NumberSchema, n: number) -> NumberSchema,
    integer: (self: NumberSchema) -> NumberSchema,
    optional: (self: NumberSchema) -> OptionalSchema<number>,
    default: (self: NumberSchema, fallback: number | () -> number) -> DefaultSchema<number>,
}

export type NumberSchema = typeof(setmetatable({} :: { _checks: { Check<number> } }, {} :: NumberImpl))

local NumberSchema = {} :: NumberImpl
NumberSchema.__index = NumberSchema

local function newNumber(checks: { Check<number> }): NumberSchema
    return setmetatable({ _checks = checks }, NumberSchema)
end

--[=[
	@within NumberSchema
	@tag Parsing
	@param value unknown
	@return Result<number>

	Validates `value` without throwing. All refinements run, so the returned
	issues describe every failure rather than only the first.
]=]
function NumberSchema:safeParse(value: unknown): Result<number>
    if type(value) ~= "number" then
        return fail(`expected number, got {typeof(value)}`)
    end

    if value ~= value then
        return fail("expected number, got nan")
    end

    return run(value, self._checks)
end

--[=[
	@within NumberSchema
	@tag Parsing
	@param value unknown
	@return number
	@error "expected ..." -- Thrown when `value` fails validation

	Validates `value` and returns it, throwing on failure.
]=]
function NumberSchema:parse(value: unknown): number
    local result = self:safeParse(value)
    if result.success then
        return result.value
    end

    error(describe(result.issues), 2)
end

--[=[
	@within NumberSchema
	@tag Refinement
	@param n number -- Minimum value, inclusive
	@return NumberSchema

	Requires the number to be greater than or equal to `n`.
]=]
function NumberSchema:min(n: number): NumberSchema
    return newNumber(append(self._checks, function(value)
        return if value < n then `expected at least {n}, got {value}` else nil
    end))
end

--[=[
	@within NumberSchema
	@tag Refinement
	@param n number -- Maximum value, inclusive
	@return NumberSchema

	Requires the number to be less than or equal to `n`.
]=]
function NumberSchema:max(n: number): NumberSchema
    return newNumber(append(self._checks, function(value)
        return if value > n then `expected at most {n}, got {value}` else nil
    end))
end

--[=[
	@within NumberSchema
	@tag Refinement
	@return NumberSchema

	Requires the number to have no fractional part. Infinities are rejected.
]=]
function NumberSchema:integer(): NumberSchema
    return newNumber(append(self._checks, function(value)
        return if value % 1 ~= 0 then `expected an integer, got {value}` else nil
    end))
end

--[=[
	@within NumberSchema
	@tag Wrapper
	@return OptionalSchema<number>

	Wraps this schema so that `nil` is also accepted.
]=]
function NumberSchema:optional(): OptionalSchema<number>
    local inner = self
    return newOptional(function(value)
        return inner:safeParse(value)
    end)
end

--[=[
	@within NumberSchema
	@tag Wrapper
	@param fallback number | () -> number -- Value used when parsing `nil`
	@return DefaultSchema<number>

	Wraps this schema so that `nil` yields `fallback` instead of failing.
]=]
function NumberSchema:default(fallback: number | () -> number): DefaultSchema<number>
    local inner = self
    return newDefault(function(value)
        return inner:safeParse(value)
    end, fallback)
end

--[=[
	@class BooleanSchema

	Validates booleans. Truthy values that are not booleans, such as `1` or
	`"true"`, are rejected.

	```lua
	local Enabled = v.boolean()
	```
]=]
type BooleanImpl = {
    __index: BooleanImpl,
    safeParse: (self: BooleanSchema, value: unknown) -> Result<boolean>,
    parse: (self: BooleanSchema, value: unknown) -> boolean,
    isTrue: (self: BooleanSchema) -> BooleanSchema,
    isFalse: (self: BooleanSchema) -> BooleanSchema,
    optional: (self: BooleanSchema) -> OptionalSchema<boolean>,
    default: (self: BooleanSchema, fallback: boolean | () -> boolean) -> DefaultSchema<boolean>,
}

export type BooleanSchema = typeof(setmetatable({} :: { _checks: { Check<boolean> } }, {} :: BooleanImpl))

local BooleanSchema = {} :: BooleanImpl
BooleanSchema.__index = BooleanSchema

local function newBoolean(checks: { Check<boolean> }): BooleanSchema
    return setmetatable({ _checks = checks }, BooleanSchema)
end

--[=[
	@within BooleanSchema
	@tag Parsing
	@param value unknown
	@return Result<boolean>

	Validates `value` without throwing.
]=]
function BooleanSchema:safeParse(value: unknown): Result<boolean>
    if type(value) ~= "boolean" then
        return fail(`expected boolean, got {typeof(value)}`)
    end

    return run(value, self._checks)
end

--[=[
	@within BooleanSchema
	@tag Parsing
	@param value unknown
	@return boolean
	@error "expected ..." -- Thrown when `value` fails validation

	Validates `value` and returns it, throwing on failure.
]=]
function BooleanSchema:parse(value: unknown): boolean
    local result = self:safeParse(value)
    if result.success then
        return result.value
    end

    error(describe(result.issues), 2)
end

--[=[
	@within BooleanSchema
	@tag Refinement
	@return BooleanSchema

	Requires the value to be `true`.
]=]
function BooleanSchema:isTrue(): BooleanSchema
    return newBoolean(append(self._checks, function(value)
        return if value ~= true then "expected true, got false" else nil
    end))
end

--[=[
	@within BooleanSchema
	@tag Refinement
	@return BooleanSchema

	Requires the value to be `false`.
]=]
function BooleanSchema:isFalse(): BooleanSchema
    return newBoolean(append(self._checks, function(value)
        return if value ~= false then "expected false, got true" else nil
    end))
end

--[=[
	@within BooleanSchema
	@tag Wrapper
	@return OptionalSchema<boolean>

	Wraps this schema so that `nil` is also accepted.
]=]
function BooleanSchema:optional(): OptionalSchema<boolean>
    local inner = self
    return newOptional(function(value)
        return inner:safeParse(value)
    end)
end

--[=[
	@within BooleanSchema
	@tag Wrapper
	@param fallback boolean | () -> boolean -- Value used when parsing `nil`
	@return DefaultSchema<boolean>

	Wraps this schema so that `nil` yields `fallback` instead of failing.
]=]
function BooleanSchema:default(fallback: boolean | () -> boolean): DefaultSchema<boolean>
    local inner = self
    return newDefault(function(value)
        return inner:safeParse(value)
    end, fallback)
end

--[=[
	@class ArraySchema

	Validates a contiguous array where every element matches one inner schema.
	Tables carrying non-array keys are rejected outright.

	```lua
	local Scores = v.array(v.number():integer()):max(4)
	```
]=]
export type ArraySchema<T> = {
    safeParse: (self: ArraySchema<T>, value: unknown) -> Result<{ T }>,
    parse: (self: ArraySchema<T>, value: unknown) -> { T },
    min: (self: ArraySchema<T>, n: number) -> ArraySchema<T>,
    max: (self: ArraySchema<T>, n: number) -> ArraySchema<T>,
    optional: (self: ArraySchema<T>) -> OptionalSchema<{ T }>,
    default: (self: ArraySchema<T>, fallback: { T } | () -> { T }) -> DefaultSchema<{ T }>,
}

type LengthCheck = (length: number) -> string?

local function newArray<T>(inner: (value: unknown) -> Result<T>, checks: { LengthCheck }): ArraySchema<T>
    local self = {}

    --[=[
		@within ArraySchema
		@method safeParse
		@tag Parsing
		@param value unknown
		@return Result<{ T }>

		Validates every element, reporting each failure with its index in the
		issue path.
	]=]
    function self:safeParse(value: unknown): Result<{ T }>
        if type(value) ~= "table" then
            return fail(`expected an array, got {typeof(value)}`)
        end

        local length = #value
        local total = 0

        for _ in value :: any do
            total += 1
        end

        if total ~= length then
            return fail(`expected an array, got a table with {total - length} non-array keys`)
        end

        local issues: { Issue } = {}

        for _, check in checks do
            local message = check(length)
            if message then
                table.insert(issues, { path = {}, message = message })
            end
        end

        local parsed: { T } = table.create(length)

        for index = 1, length do
            local result = inner((value :: any)[index])

            if result.success then
                parsed[index] = result.value
            else
                for _, issue in result.issues do
                    table.insert(issues, { path = prependPath(index, issue.path), message = issue.message })
                end
            end
        end

        if #issues > 0 then
            return { success = false, issues = issues }
        end

        return { success = true, value = parsed }
    end

    --[=[
		@within ArraySchema
		@method parse
		@tag Parsing
		@param value unknown
		@return { T }
		@error "expected ..." -- Thrown when `value` fails validation

		Validates `value` and returns it, throwing on failure.
	]=]
    function self:parse(value: unknown): { T }
        local result = self:safeParse(value)
        if result.success then
            return result.value
        end

        error(describe(result.issues), 2)
    end

    --[=[
		@within ArraySchema
		@method min
		@tag Refinement
		@param n number -- Minimum element count, inclusive
		@return ArraySchema<T>

		Requires the array to hold at least `n` elements.
	]=]
    function self:min(n: number): ArraySchema<T>
        return newArray(
            inner,
            append(checks, function(length)
                return if length < n then `expected at least {n} elements, got {length}` else nil
            end)
        )
    end

    --[=[
		@within ArraySchema
		@method max
		@tag Refinement
		@param n number -- Maximum element count, inclusive
		@return ArraySchema<T>

		Requires the array to hold at most `n` elements.
	]=]
    function self:max(n: number): ArraySchema<T>
        return newArray(
            inner,
            append(checks, function(length)
                return if length > n then `expected at most {n} elements, got {length}` else nil
            end)
        )
    end

    --[=[
		@within ArraySchema
		@method optional
		@tag Wrapper
		@return OptionalSchema<{ T }>

		Wraps this schema so that `nil` is also accepted.
	]=]
    function self:optional(): OptionalSchema<{ T }>
        return newOptional(function(value)
            return self:safeParse(value)
        end)
    end

    --[=[
		@within ArraySchema
		@method default
		@tag Wrapper
		@param fallback { T } | () -> { T } -- Value used when parsing `nil`
		@return DefaultSchema<{ T }>

		Wraps this schema so that `nil` yields `fallback` instead of failing.
		Prefer passing a function, since a constant array would be shared by
		every parse.
	]=]
    function self:default(fallback: { T } | () -> { T }): DefaultSchema<{ T }>
        return newDefault(function(value)
            return self:safeParse(value)
        end, fallback)
    end

    return (self :: any) :: ArraySchema<T>
end

--[=[
	@class TupleSchema

	Validates a fixed sequence where each position has its own schema. Use it
	for packed argument lists and other positional payloads, where [ArraySchema]
	would only let you say that every element is the same shape.

	```lua
	local Waypoint = v.tuple({ v.string(), v.number():integer() })

	Waypoint:parse({ "spawn", 3 }) --> { "spawn", 3 }
	Waypoint:parse({ "spawn" })    --> errors: [2]: expected number, got nil
	Waypoint:parse({ "a", 1, 2 })  --> errors: expected a tuple of 2 values, got 3
	```

	A position whose schema is optional or has a default may be left off the
	end, since Lua cannot tell a trailing `nil` from a shorter list:

	```lua
	local Ping = v.tuple({ v.string(), v.number():default(0) })

	Ping:parse({ "hello" }) --> { "hello", 0 }
	```
]=]
export type TupleSchema<T> = {
    safeParse: (self: TupleSchema<T>, value: unknown) -> Result<{ T }>,
    parse: (self: TupleSchema<T>, value: unknown) -> { T },
    optional: (self: TupleSchema<T>) -> OptionalSchema<{ T }>,
    default: (self: TupleSchema<T>, fallback: { T } | () -> { T }) -> DefaultSchema<{ T }>,
}

type Positions = { { safeParse: (any, unknown) -> Result<any> } }

local function newTuple<T>(positions: Positions): TupleSchema<T>
    local self = {}

    --[=[
		@within TupleSchema
		@method safeParse
		@tag Parsing
		@param value unknown
		@return Result<{ T }>

		Validates each position against its own schema, reporting failures with
		the index in the issue path.
	]=]
    function self:safeParse(value: unknown): Result<{ T }>
        if type(value) ~= "table" then
            return fail(`expected a tuple, got {typeof(value)}`)
        end

        local length = #value
        local total = 0

        for _ in value :: any do
            total += 1
        end

        if total ~= length then
            return fail(`expected a tuple, got a table with {total - length} non-array keys`)
        end

        if length > #positions then
            return fail(`expected a tuple of {#positions} values, got {length}`)
        end

        local issues: { Issue } = {}
        local parsed: { T } = table.create(#positions)

        -- Positions past the end are parsed as nil, so an optional or defaulted
        -- tail still succeeds while a required one reports the missing index.
        for index, schema in positions do
            local result = schema:safeParse((value :: any)[index])

            if result.success then
                parsed[index] = result.value
            else
                for _, issue in result.issues do
                    table.insert(issues, { path = prependPath(index, issue.path), message = issue.message })
                end
            end
        end

        if #issues > 0 then
            return { success = false, issues = issues }
        end

        return { success = true, value = parsed }
    end

    --[=[
		@within TupleSchema
		@method parse
		@tag Parsing
		@param value unknown
		@return { T }
		@error "expected ..." -- Thrown when `value` fails validation

		Validates `value` and returns it, throwing on failure.
	]=]
    function self:parse(value: unknown): { T }
        local result = self:safeParse(value)
        if result.success then
            return result.value
        end

        error(describe(result.issues), 2)
    end

    --[=[
		@within TupleSchema
		@method optional
		@tag Wrapper
		@return OptionalSchema<{ T }>

		Wraps this schema so that `nil` is also accepted.
	]=]
    function self:optional(): OptionalSchema<{ T }>
        return newOptional(function(value)
            return self:safeParse(value)
        end)
    end

    --[=[
		@within TupleSchema
		@method default
		@tag Wrapper
		@param fallback { T } | () -> { T } -- Value used when parsing `nil`
		@return DefaultSchema<{ T }>

		Wraps this schema so that `nil` yields `fallback` instead of failing.
		Prefer passing a function, since a constant table would be shared by
		every parse.
	]=]
    function self:default(fallback: { T } | () -> { T }): DefaultSchema<{ T }>
        return newDefault(function(value)
            return self:safeParse(value)
        end, fallback)
    end

    return (self :: any) :: TupleSchema<T>
end

--[=[
	@class ObjectSchema

	Validates a table field by field. Fields absent from the shape are ignored
	unless the schema is made [ObjectSchema:strict].

	The original table is returned untouched unless a field fills in a value —
	a [DefaultSchema] field, or a nested object that filled one in. In that case
	the input is shallow copied and the filled values written to the copy, so
	the value handed to `parse` is never modified.

	```lua
	local User = v.object({
		name = v.string():min(3),
		level = v.number():integer(),
	})
	```

	The field schemas stay reachable through [ObjectSchema.shape], so a single
	field can be validated on its own.
]=]
export type ObjectSchema<T, S> = {
    shape: S,
    safeParse: (self: ObjectSchema<T, S>, value: unknown) -> Result<T>,
    parse: (self: ObjectSchema<T, S>, value: unknown) -> T,
    strict: (self: ObjectSchema<T, S>) -> ObjectSchema<T, S>,
    optional: (self: ObjectSchema<T, S>) -> OptionalSchema<T>,
    default: (self: ObjectSchema<T, S>, fallback: T | () -> T) -> DefaultSchema<T>,
}

type Shape = { [string]: { safeParse: (any, unknown) -> Result<any> } }

local function newObject<T, S>(shape: Shape, strict: boolean): ObjectSchema<T, S>
    local self = {}

    --[=[
		@within ObjectSchema
		@prop shape S
		@tag Reflection
		@readonly

		The schemas this object was built from, so a field can be reused or
		validated on its own:

		```lua
		local Profile = v.object({ Level = v.number():integer():min(1) })

		Profile.shape.Level:parse(42) --> 42
		Profile.shape.Level:parse(0)  --> errors: expected at least 1, got 0
		```

		The table is a frozen copy of the one passed to [Vet.object], so
		mutating it fails loudly rather than corrupting the schema.
	]=]
    local fields = table.freeze(table.clone(shape))

    self.shape = fields

    --[=[
		@within ObjectSchema
		@method safeParse
		@tag Parsing
		@param value unknown
		@return Result<T>

		Validates every field in the shape, reporting each failure with its
		field name in the issue path.
	]=]
    function self:safeParse(value: unknown): Result<T>
        if type(value) ~= "table" then
            return fail(`expected an object, got {typeof(value)}`)
        end

        local issues: { Issue } = {}
        local output = value :: any
        local copied = false

        for key, schema in fields do
            local raw = (value :: any)[key]
            local result = schema:safeParse(raw)

            if result.success then
                -- A field only produces a different value when something filled
                -- it in, so the copy is paid for only by schemas using defaults.
                if result.value ~= raw then
                    if not copied then
                        output = table.clone(value :: any)
                        copied = true
                    end

                    output[key] = result.value
                end
            else
                for _, issue in result.issues do
                    table.insert(issues, { path = prependPath(key, issue.path), message = issue.message })
                end
            end
        end

        if strict then
            for key in value :: any do
                if fields[key] == nil then
                    table.insert(issues, { path = { key }, message = "unexpected key" })
                end
            end
        end

        if #issues > 0 then
            return { success = false, issues = issues }
        end

        return { success = true, value = output :: T }
    end

    --[=[
		@within ObjectSchema
		@method parse
		@tag Parsing
		@param value unknown
		@return T
		@error "expected ..." -- Thrown when `value` fails validation

		Validates `value` and returns it, throwing on failure.
	]=]
    function self:parse(value: unknown): T
        local result = self:safeParse(value)
        if result.success then
            return result.value
        end

        error(describe(result.issues), 2)
    end

    --[=[
		@within ObjectSchema
		@method strict
		@tag Refinement
		@return ObjectSchema<T, S>

		Returns a schema that also rejects keys absent from the shape. Use it
		for data crossing a trust boundary, where an unexpected field is more
		likely a mistake than a spare.
	]=]
    function self:strict(): ObjectSchema<T, S>
        return newObject(fields, true)
    end

    --[=[
		@within ObjectSchema
		@method optional
		@tag Wrapper
		@return OptionalSchema<T>

		Wraps this schema so that `nil` is also accepted.
	]=]
    function self:optional(): OptionalSchema<T>
        return newOptional(function(value)
            return self:safeParse(value)
        end)
    end

    --[=[
		@within ObjectSchema
		@method default
		@tag Wrapper
		@param fallback T | () -> T -- Value used when parsing `nil`
		@return DefaultSchema<T>

		Wraps this schema so that `nil` yields `fallback` instead of failing.
		Prefer passing a function, since a constant table would be shared by
		every parse.
	]=]
    function self:default(fallback: T | () -> T): DefaultSchema<T>
        return newDefault(function(value)
            return self:safeParse(value)
        end, fallback)
    end

    return (self :: any) :: ObjectSchema<T, S>
end

--[=[
	@type UuidVersion "v4" | "v5" | "v6" | "v7" | "v8"
	@within Vet

	Versions accepted by [Vet.uuid] and [Vet.guid]. Version 4 is random, 5 is
	name-based, 6 is reordered time, 7 is Unix epoch time, and 8 is custom.
]=]
export type UuidVersion = "v4" | "v5" | "v6" | "v7" | "v8"

--[=[
	@interface UuidOptions
	@within Vet
	.version UuidVersion? -- Version the identifier must declare
]=]
export type UuidOptions = {
    version: UuidVersion?,
}

-- 8-4-4-4-12 hexadecimal, the layout shared by UUIDs and GUIDs.
local UUID_PATTERN =
    `^{string.rep("%x", 8)}%-{string.rep("%x", 4)}%-{string.rep("%x", 4)}%-{string.rep("%x", 4)}%-{string.rep("%x", 12)}$`

local VERSION_NIBBLES: { [string]: string } = {
    v4 = "4",
    v5 = "5",
    v6 = "6",
    v7 = "7",
    v8 = "8",
}

-- RFC 9562 spells the variant as the two high bits of nibble 17 being `10`,
-- which is these four hexadecimal digits.
local VARIANT_NIBBLES: { [string]: boolean } = {
    ["8"] = true,
    ["9"] = true,
    a = true,
    b = true,
}

local function summarise(value: string): string
    if #value > 45 then
        return `"{string.sub(value, 1, 42)}..."`
    end

    return `"{value}"`
end

local function versionNibble(options: UuidOptions?, label: string): string?
    if options == nil or options.version == nil then
        return nil
    end

    local nibble = VERSION_NIBBLES[options.version]

    if nibble == nil then
        error(`unknown {label} version "{tostring(options.version)}", expected v4, v5, v6, v7 or v8`, 3)
    end

    return nibble
end

local function identifierCheck(expected: string?, allowBraces: boolean, strict: boolean, label: string): Check<string>
    return function(value)
        local candidate = value

        if allowBraces then
            local unwrapped = string.match(value, "^{(.*)}$")

            if unwrapped ~= nil then
                candidate = unwrapped
            end
        end

        if string.match(candidate, UUID_PATTERN) == nil then
            return `expected a {label}, got {summarise(value)}`
        end

        local version = string.lower(string.sub(candidate, 15, 15))

        if expected ~= nil then
            if version ~= expected then
                return `expected a v{expected} {label}, got v{version}`
            end
        elseif strict and string.match(version, "^[1-8]$") == nil then
            return `expected a {label} with a version of 1 to 8, got v{version}`
        end

        if strict then
            local variant = string.lower(string.sub(candidate, 20, 20))

            if not VARIANT_NIBBLES[variant] then
                return `expected a {label} with an RFC 9562 variant, got nibble {variant}`
            end
        end

        return nil
    end
end

local Vet = {}

--[=[
	@within Vet
	@tag Constructor
	@return StringSchema

	Creates a schema that accepts any string.
]=]
function Vet.string(): StringSchema
    return newString({})
end

--[=[
	@within Vet
	@tag Constructor
	@return NumberSchema

	Creates a schema that accepts any number except NaN.
]=]
function Vet.number(): NumberSchema
    return newNumber({})
end

--[=[
	@within Vet
	@tag Constructor
	@return BooleanSchema

	Creates a schema that accepts `true` or `false`.
]=]
function Vet.boolean(): BooleanSchema
    return newBoolean({})
end

--[=[
	@within Vet
	@tag Constructor
	@param options UuidOptions? -- Pass `{ version = "v4" }` to pin the version
	@return StringSchema
	@error "unknown uuid version ..." -- Thrown when `options.version` is not v4 to v8

	Creates a schema that accepts a UUID: 8-4-4-4-12 hexadecimal digits, in
	either case, carrying a version of 1 to 8 and an RFC 9562 variant.

	```lua
	local Id = v.uuid()
	local SessionId = v.uuid({ version = "v7" })

	Id:parse("01912d68-783e-7cc0-a2f0-5f8b1d3e9a7c") --> ok
	SessionId:parse("6f9619ff-8b86-4d11-b42d-00cf4fc964ff")
	--> errors: expected a v7 uuid, got v4
	```

	Because the version and variant are checked, the nil UUID and the max UUID
	are both rejected. Use [Vet.guid] when you only care about the layout.

	The result is a plain [StringSchema], so `:optional()`, `:default()` and
	`Vet.infer` behave exactly as they do for any other string.
]=]
function Vet.uuid(options: UuidOptions?): StringSchema
    return newString({ identifierCheck(versionNibble(options, "uuid"), false, true, "uuid") })
end

--[=[
	@within Vet
	@tag Constructor
	@param options UuidOptions? -- Pass `{ version = "v4" }` to pin the version
	@return StringSchema
	@error "unknown guid version ..." -- Thrown when `options.version` is not v4 to v8

	Creates a schema that accepts a GUID: the same 8-4-4-4-12 layout as
	[Vet.uuid], optionally wrapped in braces, with no variant requirement.

	```lua
	local Id = v.guid()

	Id:parse("{6F9619FF-8B86-D011-B42D-00CF4FC964FF}") --> ok
	Id:parse("6f9619ff-8b86-d011-b42d-00cf4fc964ff")   --> ok
	```

	This is the shape `HttpService:GenerateGUID` returns, which is braced and
	uppercase by default. Values Microsoft produced do not always follow the
	RFC variant rule, so only the layout is enforced unless you pass a version.
]=]
function Vet.guid(options: UuidOptions?): StringSchema
    return newString({ identifierCheck(versionNibble(options, "guid"), true, false, "guid") })
end

--[=[
	@within Vet
	@tag Constructor
	@param item S -- Schema every element must satisfy
	@return ArraySchema<Vet.infer<S>>

	Creates a schema that accepts an array of `item`.

	```lua
	local Scores = v.array(v.number():integer())

	Scores:parse({ 1, 2, 3 }) --> { 1, 2, 3 }
	Scores:parse({ 1, 1.5 })  --> errors: [2]: expected an integer, got 1.5
	```
]=]
function Vet.array<S>(item: S): ArraySchema<infer<S>>
    local schema = item :: any

    return newArray(function(value)
        return schema:safeParse(value)
    end, {})
end

--[=[
	@within Vet
	@tag Constructor
	@param positions { S } -- One schema per position, in order
	@return TupleSchema<Vet.infer<S>>

	Creates a schema that accepts a fixed sequence, checking each position
	against its own schema.

	```lua
	local Waypoint = v.tuple({ v.string(), v.number():integer() })

	Waypoint:parse({ "spawn", 3 }) --> { "spawn", 3 }
	Waypoint:parse({ "spawn" })    --> errors: [2]: expected number, got nil
	```

	Luau infers a mixed array literal as a union of its element types, so the
	positions are already merged by the time a type function can see them. The
	result is therefore `{ string | number }` rather than a true positional
	type — the runtime check is exact, the static type is not.
]=]
function Vet.tuple<S>(positions: { S }): TupleSchema<infer<S>>
    return newTuple((positions :: any) :: Positions)
end

--[=[
	@within Vet
	@tag Constructor
	@param shape S -- Table mapping field names to schemas
	@return ObjectSchema<Vet.objectOutput<S>, S>

	Creates a schema that validates a table field by field. The field types come
	from the shape, so the schema is the only place they are declared.

	```lua
	local User = v.object({
		name = v.string():min(3),
		nickname = v.string():optional(),
	})

	type User = v.infer<typeof(User)> --> { name: string, nickname: string? }
	```
]=]
function Vet.object<S>(shape: S): ObjectSchema<objectOutput<S>, S>
    return newObject((shape :: any) :: Shape, false)
end

return Vet
