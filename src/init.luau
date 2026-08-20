--!strict

--[=[
	@class Vet

	Lua-first schema validation with type inference.

	```luau
	local Vet = require(ReplicatedStorage.Packages.Vet)

	local Name = Vet.string():min(3):max(22)

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

	```luau
	local Username = Vet.string():min(3)
	type Username = Vet.infer<typeof(Username)> --> string

	local Nickname = Vet.string():optional()
	type Nickname = Vet.infer<typeof(Nickname)> --> string?
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

	```luau
	local Nickname = Vet.string():max(20):optional()

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
		@param value unknown
		@return Result<T?>

		Succeeds with `nil` when `value` is `nil`, and otherwise defers to the
		wrapped schema.
	]=]
    function self.safeParse(_self: any, value: unknown): Result<T?>
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
		@param value unknown
		@return T?
		@error "expected ..." -- Thrown when a non-nil `value` fails validation

		Validates `value` and returns it, throwing on failure.
	]=]
    function self.parse(selfRef: any, value: unknown): T?
        local result = self.safeParse(selfRef, value)
        if result.success then
            return result.value
        end

        error(describe(result.issues), 2)
    end

    --[=[
		@within OptionalSchema
		@return OptionalSchema<T>

		Returns the same schema, since it already accepts `nil`.
	]=]
    function self.optional(selfRef: any): OptionalSchema<T>
        return selfRef
    end

    return (self :: any) :: OptionalSchema<T>
end

--[=[
	@class StringSchema

	Validates strings. Every refinement returns a new schema, so a base schema
	can be shared and specialised without being modified.

	```luau
	local Base = Vet.string()
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
}

export type StringSchema = typeof(setmetatable({} :: { _checks: { Check<string> } }, {} :: StringImpl))

local StringSchema = {} :: StringImpl
StringSchema.__index = StringSchema

local function newString(checks: { Check<string> }): StringSchema
    return setmetatable({ _checks = checks }, StringSchema)
end

--[=[
	@within StringSchema
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
	@class NumberSchema

	Validates numbers. NaN is rejected before any refinement runs.

	```luau
	local Level = Vet.number():integer():min(1):max(100)
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
}

export type NumberSchema = typeof(setmetatable({} :: { _checks: { Check<number> } }, {} :: NumberImpl))

local NumberSchema = {} :: NumberImpl
NumberSchema.__index = NumberSchema

local function newNumber(checks: { Check<number> }): NumberSchema
    return setmetatable({ _checks = checks }, NumberSchema)
end

--[=[
	@within NumberSchema
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
	@class BooleanSchema

	Validates booleans. Truthy values that are not booleans, such as `1` or
	`"true"`, are rejected.

	```luau
	local Enabled = Vet.boolean()
	```
]=]
type BooleanImpl = {
    __index: BooleanImpl,
    safeParse: (self: BooleanSchema, value: unknown) -> Result<boolean>,
    parse: (self: BooleanSchema, value: unknown) -> boolean,
    isTrue: (self: BooleanSchema) -> BooleanSchema,
    isFalse: (self: BooleanSchema) -> BooleanSchema,
    optional: (self: BooleanSchema) -> OptionalSchema<boolean>,
}

export type BooleanSchema = typeof(setmetatable({} :: { _checks: { Check<boolean> } }, {} :: BooleanImpl))

local BooleanSchema = {} :: BooleanImpl
BooleanSchema.__index = BooleanSchema

local function newBoolean(checks: { Check<boolean> }): BooleanSchema
    return setmetatable({ _checks = checks }, BooleanSchema)
end

--[=[
	@within BooleanSchema
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
	@class ArraySchema

	Validates a contiguous array where every element matches one inner schema.
	Tables carrying non-array keys are rejected outright.

	```luau
	local Scores = Vet.array(Vet.number():integer()):max(4)
	```
]=]
export type ArraySchema<T> = {
    safeParse: (self: ArraySchema<T>, value: unknown) -> Result<{ T }>,
    parse: (self: ArraySchema<T>, value: unknown) -> { T },
    min: (self: ArraySchema<T>, n: number) -> ArraySchema<T>,
    max: (self: ArraySchema<T>, n: number) -> ArraySchema<T>,
    optional: (self: ArraySchema<T>) -> OptionalSchema<{ T }>,
}

type LengthCheck = (length: number) -> string?

local function newArray<T>(inner: (value: unknown) -> Result<T>, checks: { LengthCheck }): ArraySchema<T>
    local self = {}

    --[=[
		@within ArraySchema
		@param value unknown
		@return Result<{ T }>

		Validates every element, reporting each failure with its index in the
		issue path.
	]=]
    function self.safeParse(_self: any, value: unknown): Result<{ T }>
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
		@param value unknown
		@return { T }
		@error "expected ..." -- Thrown when `value` fails validation

		Validates `value` and returns it, throwing on failure.
	]=]
    function self.parse(selfRef: any, value: unknown): { T }
        local result = self.safeParse(selfRef, value)
        if result.success then
            return result.value
        end

        error(describe(result.issues), 2)
    end

    --[=[
		@within ArraySchema
		@param n number -- Minimum element count, inclusive
		@return ArraySchema<T>

		Requires the array to hold at least `n` elements.
	]=]
    function self.min(_self: any, n: number): ArraySchema<T>
        return newArray(
            inner,
            append(checks, function(length)
                return if length < n then `expected at least {n} elements, got {length}` else nil
            end)
        )
    end

    --[=[
		@within ArraySchema
		@param n number -- Maximum element count, inclusive
		@return ArraySchema<T>

		Requires the array to hold at most `n` elements.
	]=]
    function self.max(_self: any, n: number): ArraySchema<T>
        return newArray(
            inner,
            append(checks, function(length)
                return if length > n then `expected at most {n} elements, got {length}` else nil
            end)
        )
    end

    --[=[
		@within ArraySchema
		@return OptionalSchema<{ T }>

		Wraps this schema so that `nil` is also accepted.
	]=]
    function self.optional(selfRef: any): OptionalSchema<{ T }>
        return newOptional(function(value)
            return selfRef:safeParse(value)
        end)
    end

    return (self :: any) :: ArraySchema<T>
end

--[=[
	@class ObjectSchema

	Validates a table field by field. Fields absent from the shape are ignored
	unless the schema is made [ObjectSchema:strict], and the original table is
	returned rather than a copy.

	```luau
	local User = Vet.object({
		name = Vet.string():min(3),
		level = Vet.number():integer(),
	})
	```
]=]
export type ObjectSchema<T> = {
    safeParse: (self: ObjectSchema<T>, value: unknown) -> Result<T>,
    parse: (self: ObjectSchema<T>, value: unknown) -> T,
    strict: (self: ObjectSchema<T>) -> ObjectSchema<T>,
    optional: (self: ObjectSchema<T>) -> OptionalSchema<T>,
}

type Shape = { [string]: { safeParse: (any, unknown) -> Result<any> } }

local function newObject<T>(shape: Shape, strict: boolean): ObjectSchema<T>
    local self = {}

    --[=[
		@within ObjectSchema
		@param value unknown
		@return Result<T>

		Validates every field in the shape, reporting each failure with its
		field name in the issue path.
	]=]
    function self.safeParse(_self: any, value: unknown): Result<T>
        if type(value) ~= "table" then
            return fail(`expected an object, got {typeof(value)}`)
        end

        local issues: { Issue } = {}

        for key, schema in shape do
            local result = schema:safeParse((value :: any)[key])

            if not result.success then
                for _, issue in result.issues do
                    table.insert(issues, { path = prependPath(key, issue.path), message = issue.message })
                end
            end
        end

        if strict then
            for key in value :: any do
                if shape[key] == nil then
                    table.insert(issues, { path = { key }, message = "unexpected key" })
                end
            end
        end

        if #issues > 0 then
            return { success = false, issues = issues }
        end

        return { success = true, value = (value :: any) :: T }
    end

    --[=[
		@within ObjectSchema
		@param value unknown
		@return T
		@error "expected ..." -- Thrown when `value` fails validation

		Validates `value` and returns it, throwing on failure.
	]=]
    function self.parse(selfRef: any, value: unknown): T
        local result = self.safeParse(selfRef, value)
        if result.success then
            return result.value
        end

        error(describe(result.issues), 2)
    end

    --[=[
		@within ObjectSchema
		@return ObjectSchema<T>

		Returns a schema that also rejects keys absent from the shape. Use it
		for data crossing a trust boundary, where an unexpected field is more
		likely a mistake than a spare.
	]=]
    function self.strict(_self: any): ObjectSchema<T>
        return newObject(shape, true)
    end

    --[=[
		@within ObjectSchema
		@return OptionalSchema<T>

		Wraps this schema so that `nil` is also accepted.
	]=]
    function self.optional(selfRef: any): OptionalSchema<T>
        return newOptional(function(value)
            return selfRef:safeParse(value)
        end)
    end

    return (self :: any) :: ObjectSchema<T>
end

local Vet = {}

--[=[
	@within Vet
	@return StringSchema

	Creates a schema that accepts any string.
]=]
function Vet.string(): StringSchema
    return newString({})
end

--[=[
	@within Vet
	@return NumberSchema

	Creates a schema that accepts any number except NaN.
]=]
function Vet.number(): NumberSchema
    return newNumber({})
end

--[=[
	@within Vet
	@return BooleanSchema

	Creates a schema that accepts `true` or `false`.
]=]
function Vet.boolean(): BooleanSchema
    return newBoolean({})
end

--[=[
	@within Vet
	@param item S -- Schema every element must satisfy
	@return ArraySchema<Vet.infer<S>>

	Creates a schema that accepts an array of `item`.

	```luau
	local Scores = Vet.array(Vet.number():integer())

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
	@param shape S -- Table mapping field names to schemas
	@return ObjectSchema<Vet.objectOutput<S>>

	Creates a schema that validates a table field by field. The field types come
	from the shape, so the schema is the only place they are declared.

	```luau
	local User = Vet.object({
		name = Vet.string():min(3),
		nickname = Vet.string():optional(),
	})

	type User = Vet.infer<typeof(User)> --> { name: string, nickname: string? }
	```
]=]
function Vet.object<S>(shape: S): ObjectSchema<objectOutput<S>>
    return newObject((shape :: any) :: Shape, false)
end

return Vet
