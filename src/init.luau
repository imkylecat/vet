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
	@type Failure { success: false, issues: { Issue } }
	@within Vet

	The unsuccessful arm of [Vet.Result]. Naming it lets a helper return a
	failure that fits any `Result<T>` without widening `T` to `any`.
]=]
export type Failure = { success: false, issues: { Issue } }

--[=[
	@type Result<T> { success: true, value: T } | Failure
	@within Vet

	Returned by `safeParse`. Narrow it with `if result.success then` to get a
	typed `result.value`.
]=]
export type Result<T> = { success: true, value: T } | Failure

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
    local INDEX = types.singleton("__index")

    -- Closure-based schemas hold `parse` directly; metatable-based ones keep it
    -- on the metatable, either as a property or behind __index.
    local function parseOf(candidate)
        if not candidate:is("table") then
            return nil
        end

        local parse = candidate:readproperty(PARSE)

        if parse == nil then
            local metatable = candidate:metatable()

            if metatable ~= nil then
                parse = metatable:readproperty(PARSE)

                if parse == nil then
                    local index = metatable:readproperty(INDEX)

                    if index ~= nil and index:is("table") then
                        parse = index:readproperty(PARSE)
                    end
                end
            end
        end

        return parse
    end

    local function outputOf(candidate)
        local parse = parseOf(candidate)

        -- Reading a plain property off a schema, such as `shape.level.minimum`,
        -- can leave the solver holding the schema intersected with what that
        -- read implied. The schema is still one of the parts, so it is looked
        -- for rather than refused.
        if parse == nil and candidate:is("intersection") then
            for _, part in candidate:components() do
                parse = parseOf(part)

                if parse ~= nil then
                    break
                end
            end
        end

        if parse == nil then
            if candidate:is("table") or candidate:is("intersection") then
                error("expected a schema with a `parse` method")
            end

            error(`expected a schema, got a {candidate.tag}`)
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

	A field wrapped by [ReadonlySchema] or [WriteonlySchema] carries an `access`
	marker, which becomes a `read` or `write` qualifier on the property it
	produces:

	```lua
	local PlayerData = v.object({
		id = v.number():readonly(),
		name = v.string(),
		secretToken = v.string():writeonly(),
	})

	type PlayerData = v.infer<typeof(PlayerData)>
	--> { read id: number, name: string, write secretToken: string }
	```

	The property walk duplicates the one in [Vet.infer] because a type function
	cannot call another type function.
]=]
export type function objectOutput(shape)
    if not shape:is("table") then
        error(`expected a table of schemas, got a {shape.tag}`)
    end

    local PARSE = types.singleton("parse")
    local ACCESS = types.singleton("access")
    local INDEX = types.singleton("__index")
    local output = types.newtable()

    -- Closure-based schemas hold their fields directly; metatable-based ones
    -- keep them on the metatable, either as a property or behind __index.
    local function readFrom(candidate, key)
        if not candidate:is("table") then
            return nil
        end

        local found = candidate:readproperty(key)

        if found == nil then
            local metatable = candidate:metatable()

            if metatable ~= nil then
                found = metatable:readproperty(key)

                if found == nil then
                    local index = metatable:readproperty(INDEX)

                    if index ~= nil and index:is("table") then
                        found = index:readproperty(key)
                    end
                end
            end
        end

        return found
    end

    -- Reading a plain property off a field schema can leave the solver holding
    -- an intersection rather than the schema itself, so each part is tried.
    local function lookup(candidate, key)
        local found = readFrom(candidate, key)

        if found == nil and candidate:is("intersection") then
            for _, part in candidate:components() do
                found = readFrom(part, key)

                if found ~= nil then
                    break
                end
            end
        end

        return found
    end

    for key, property in shape:properties() do
        local candidate = property.read

        if candidate == nil or not (candidate:is("table") or candidate:is("intersection")) then
            error("expected every field to be a schema")
        end

        local parse = lookup(candidate, PARSE)

        if parse == nil or not parse:is("function") then
            error("expected every field to be a schema with a `parse` method")
        end

        local head = parse:returns().head

        if head == nil or #head == 0 then
            error("expected `parse` to return a value")
        end

        -- A marker only reads as read-only or write-only when it is the
        -- singleton the wrapper declares; anything else stays read-write.
        local access = lookup(candidate, ACCESS)
        local marker = if access ~= nil and access:is("singleton") then access:value() else nil

        if marker == "read" then
            output:setreadproperty(key, head[1])
        elseif marker == "write" then
            output:setwriteproperty(key, head[1])
        else
            output:setproperty(key, head[1])
        end
    end

    return output
end

type Check<T> = (value: T) -> string?

local function append<T>(list: { T }, item: T): { T }
    local copy = table.clone(list)
    table.insert(copy, item)
    return copy
end

--[=[
	@type AnySchema<T> { parse: (self, unknown) -> T, safeParse: (self, unknown) -> Result<T> }
	@within Vet

	The shape every schema shares. Constructors that take another schema accept
	this, so passing something that is not a schema is a type error at the call
	site rather than a failure at parse time.
]=]
export type AnySchema<T> = {
    parse: (self: any, value: unknown) -> T,
    safeParse: (self: any, value: unknown) -> Result<T>,
    _validate: (self: any, value: unknown) -> (T?, { Issue }?),
}

-- Shared by every issue that failed at the top level. Frozen because issues are
-- handed to callers, and because prependPath copies rather than mutating.
local EMPTY_PATH: { string | number } = table.freeze({} :: { string | number })

local function runChecks<T>(value: T, checks: { Check<T> }): { Issue }?
    -- Allocated only once something fails, so a passing parse allocates nothing
    -- here at all.
    local issues: { Issue }? = nil

    for _, check in checks do
        local message = check(value)

        if message ~= nil then
            if issues == nil then
                issues = { { path = EMPTY_PATH, message = message } }
            else
                table.insert(issues :: { Issue }, { path = EMPTY_PATH, message = message })
            end
        end
    end

    return issues
end

local function failure(message: string): { Issue }
    return { { path = EMPTY_PATH, message = message } }
end

local function prependPath(key: string | number, path: { string | number }): { string | number }
    local combined = table.clone(path)
    table.insert(combined, 1, key)
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
	@class ReadonlySchema

	Marks a field as read-only, so the record an [ObjectSchema] parses to
	declares it `read`. Created by calling `:readonly()` on any schema, or by
	wrapping one with [Vet.readonly]. It comes last in a chain, after the
	refinements and after `:optional()` or `:default()`.

	```lua
	local PlayerData = v.object({
		id = v.number():integer():readonly(),
		name = v.string(),
	})

	type PlayerData = v.infer<typeof(PlayerData)>
	--> { read id: number, name: string }

	local data = PlayerData:parse(payload)

	print(data.id) --> fine
	data.id = 2    --> analysis error: `id` is read-only
	```

	Validation is untouched: the field is parsed exactly as the wrapped schema
	would parse it, and the value is there at runtime. Only the type differs, so
	the restriction is caught during analysis rather than enforced by a
	metatable on every write.
]=]
export type ReadonlySchema<T> = {
    access: "read",
    minimum: number?,
    maximum: number?,
    isOptional: boolean,
    _validate: (self: ReadonlySchema<T>, value: unknown) -> (T?, { Issue }?),
    safeParse: (self: ReadonlySchema<T>, value: unknown) -> Result<T>,
    parse: (self: ReadonlySchema<T>, value: unknown) -> T,
    readonly: (self: ReadonlySchema<T>) -> ReadonlySchema<T>,
    writeonly: (self: ReadonlySchema<T>) -> WriteonlySchema<T>,
}

--[=[
	@class WriteonlySchema

	Marks a field as write-only, so the record an [ObjectSchema] parses to
	declares it `write`. Created by calling `:writeonly()` on any schema, or by
	wrapping one with [Vet.writeonly].

	```lua
	local PlayerData = v.object({
		name = v.string(),
		secretToken = v.string():writeonly(),
	})

	type PlayerData = v.infer<typeof(PlayerData)>
	--> { name: string, write secretToken: string }

	local data = PlayerData:parse(payload)

	data.secretToken = "rotated" --> fine
	print(data.secretToken)      --> analysis error: `secretToken` is write-only
	```

	Use it for a field that has to be validated on the way in but must not be
	read back out by accident — a token, a password, a nonce. Like
	[ReadonlySchema] this is a type-level restriction, so the value is still
	present at runtime and still reachable through a cast.
]=]
export type WriteonlySchema<T> = {
    access: "write",
    minimum: number?,
    maximum: number?,
    isOptional: boolean,
    _validate: (self: WriteonlySchema<T>, value: unknown) -> (T?, { Issue }?),
    safeParse: (self: WriteonlySchema<T>, value: unknown) -> Result<T>,
    parse: (self: WriteonlySchema<T>, value: unknown) -> T,
    readonly: (self: WriteonlySchema<T>) -> ReadonlySchema<T>,
    writeonly: (self: WriteonlySchema<T>) -> WriteonlySchema<T>,
}

--[=[
	@type Access "read" | "write" | "readwrite"
	@within Vet

	What a schema's `access` property holds. Every schema carries one, so a
	shape can be inspected without knowing which kind of schema a field is:

	```lua
	local Player = v.object({ id = v.number():readonly(), name = v.string() })

	Player.shape.id.access   --> "read"
	Player.shape.name.access --> "readwrite"
	```

	Each schema type declares the single value it can hold rather than this
	union, which is what lets [Vet.objectOutput] read the marker during
	analysis.
]=]
export type Access = "read" | "write" | "readwrite"

-- One factory backs both wrappers, since they differ only by the marker they
-- carry and the qualifier that marker becomes.
local function newAccess<T>(
    marker: "read" | "write",
    inner: (value: unknown) -> (T?, { Issue }?),
    isOptional: boolean,
    minimum: number?,
    maximum: number?
): ReadonlySchema<T>
    local self = {}
    local this = (self :: any) :: ReadonlySchema<T>

    --[=[
		@within ReadonlySchema
		@prop access "read"
		@tag Reflection
		@readonly

		Always `"read"`.
	]=]

    --[=[
		@within WriteonlySchema
		@prop access "write"
		@tag Reflection
		@readonly

		Always `"write"`.
	]=]
    self.access = marker

    --[=[
		@within ReadonlySchema
		@prop isOptional boolean
		@tag Reflection
		@readonly

		Forwarded from the wrapped schema, so `v.string():optional():readonly()`
		still reports itself as optional.
	]=]

    --[=[
		@within WriteonlySchema
		@prop isOptional boolean
		@tag Reflection
		@readonly

		Forwarded from the wrapped schema.
	]=]
    self.isOptional = isOptional

    --[=[
		@within ReadonlySchema
		@prop minimum number?
		@tag Reflection
		@readonly

		Forwarded from the wrapped schema.
	]=]

    --[=[
		@within WriteonlySchema
		@prop minimum number?
		@tag Reflection
		@readonly

		Forwarded from the wrapped schema.
	]=]
    self.minimum = minimum

    --[=[
		@within ReadonlySchema
		@prop maximum number?
		@tag Reflection
		@readonly

		Forwarded from the wrapped schema.
	]=]

    --[=[
		@within WriteonlySchema
		@prop maximum number?
		@tag Reflection
		@readonly

		Forwarded from the wrapped schema.
	]=]
    self.maximum = maximum

    self._validate = function(_self: any, value: unknown): (T?, { Issue }?)
        return inner(value)
    end

    --[=[
		@within ReadonlySchema
		@method safeParse
		@tag Parsing
		@param value unknown
		@return Result<T>

		Defers to the wrapped schema. The marker changes the type a surrounding
		object produces, never what is accepted.
	]=]

    --[=[
		@within WriteonlySchema
		@method safeParse
		@tag Parsing
		@param value unknown
		@return Result<T>

		Defers to the wrapped schema.
	]=]
    function self:safeParse(value: unknown): Result<T>
        local parsed, issues = inner(value)

        if issues ~= nil then
            return { success = false, issues = issues }
        end

        return { success = true, value = parsed :: T }
    end

    --[=[
		@within ReadonlySchema
		@method parse
		@tag Parsing
		@param value unknown
		@return T
		@error "expected ..." -- Thrown when `value` fails the wrapped schema

		Validates `value` and returns it, throwing on failure.
	]=]

    --[=[
		@within WriteonlySchema
		@method parse
		@tag Parsing
		@param value unknown
		@return T
		@error "expected ..." -- Thrown when `value` fails the wrapped schema

		Validates `value` and returns it, throwing on failure.
	]=]
    function self:parse(value: unknown): T
        local parsed, issues = inner(value)

        if issues ~= nil then
            error(describe(issues), 2)
        end

        return parsed :: T
    end

    --[=[
		@within ReadonlySchema
		@method readonly
		@tag Wrapper
		@return ReadonlySchema<T>

		Returns the same schema, since it is already read-only.
	]=]

    --[=[
		@within WriteonlySchema
		@method readonly
		@tag Wrapper
		@return ReadonlySchema<T>

		Returns a read-only wrapper around the same schema, replacing the
		write-only marker.
	]=]
    function self:readonly(): ReadonlySchema<T>
        if marker == "read" then
            return this
        end

        return newAccess("read", inner, isOptional, minimum, maximum)
    end

    --[=[
		@within ReadonlySchema
		@method writeonly
		@tag Wrapper
		@return WriteonlySchema<T>

		Returns a write-only wrapper around the same schema, replacing the
		read-only marker.
	]=]

    --[=[
		@within WriteonlySchema
		@method writeonly
		@tag Wrapper
		@return WriteonlySchema<T>

		Returns the same schema, since it is already write-only.
	]=]
    function self:writeonly(): WriteonlySchema<T>
        if marker == "write" then
            return (this :: any) :: WriteonlySchema<T>
        end

        return (newAccess("write", inner, isOptional, minimum, maximum) :: any) :: WriteonlySchema<T>
    end

    return this
end

local function newReadonly<T>(
    inner: (value: unknown) -> (T?, { Issue }?),
    isOptional: boolean,
    minimum: number?,
    maximum: number?
): ReadonlySchema<T>
    return newAccess("read", inner, isOptional, minimum, maximum)
end

-- newAccess is typed as the read-only wrapper because the two shapes differ
-- only in the singleton they declare, so the write-only name is put back here.
local function newWriteonly<T>(
    inner: (value: unknown) -> (T?, { Issue }?),
    isOptional: boolean,
    minimum: number?,
    maximum: number?
): WriteonlySchema<T>
    return (newAccess("write", inner, isOptional, minimum, maximum) :: any) :: WriteonlySchema<T>
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
    access: "readwrite",
    minimum: number?,
    maximum: number?,
    isOptional: boolean,
    _validate: (self: OptionalSchema<T>, value: unknown) -> (T?, { Issue }?),
    safeParse: (self: OptionalSchema<T>, value: unknown) -> Result<T?>,
    parse: (self: OptionalSchema<T>, value: unknown) -> T?,
    optional: (self: OptionalSchema<T>) -> OptionalSchema<T>,
    readonly: (self: OptionalSchema<T>) -> ReadonlySchema<T?>,
    writeonly: (self: OptionalSchema<T>) -> WriteonlySchema<T?>,
}

local function newOptional<T>(
    inner: (value: unknown) -> (T?, { Issue }?),
    minimum: number?,
    maximum: number?
): OptionalSchema<T>
    local self = {}
    local this = (self :: any) :: OptionalSchema<T>

    --[=[
		@within OptionalSchema
		@prop isOptional boolean
		@tag Reflection
		@readonly

		Always `true`.
	]=]
    self.isOptional = true

    --[=[
		@within OptionalSchema
		@prop access "readwrite"
		@tag Reflection
		@readonly

		Always `"readwrite"`. Chain `:readonly()` or `:writeonly()` to change it.
	]=]
    self.access = "readwrite"

    --[=[
		@within OptionalSchema
		@prop minimum number?
		@tag Reflection
		@readonly

		Forwarded from the wrapped schema, so `v.string():min(3):optional()`
		still reports a minimum of 3.
	]=]
    self.minimum = minimum

    --[=[
		@within OptionalSchema
		@prop maximum number?
		@tag Reflection
		@readonly

		Forwarded from the wrapped schema.
	]=]
    self.maximum = maximum

    --[=[
		@within OptionalSchema
		@method safeParse
		@tag Parsing
		@param value unknown
		@return Result<T?>

		Succeeds with `nil` when `value` is `nil`, and otherwise defers to the
		wrapped schema.
	]=]
    local function validate(value: unknown): (T?, { Issue }?)
        if value == nil then
            return nil, nil
        end

        return inner(value)
    end

    self._validate = function(_self: any, value: unknown): (T?, { Issue }?)
        return validate(value)
    end

    function self:safeParse(value: unknown): Result<T?>
        if value == nil then
            return { success = true, value = nil }
        end

        local parsed, issues = validate(value)

        if issues ~= nil then
            return { success = false, issues = issues }
        end

        return { success = true, value = parsed }
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
        local parsed, issues = validate(value)

        if issues ~= nil then
            error(describe(issues), 2)
        end

        return parsed
    end

    --[=[
		@within OptionalSchema
		@method optional
		@tag Wrapper
		@return OptionalSchema<T>

		Returns the same schema, since it already accepts `nil`.
	]=]
    function self:optional(): OptionalSchema<T>
        return this
    end

    --[=[
		@within OptionalSchema
		@method readonly
		@tag Wrapper
		@return ReadonlySchema<T?>

		Wraps this schema so that a field using it is typed `read`. The value
		type keeps the `?`, so the field reads as `read name: string?`.
	]=]
    function self:readonly(): ReadonlySchema<T?>
        -- newReadonly binds its type parameter from the non-nil half of what
        -- validate returns, so the optional half is named again here.
        return (newReadonly(validate, true, minimum, maximum) :: any) :: ReadonlySchema<T?>
    end

    --[=[
		@within OptionalSchema
		@method writeonly
		@tag Wrapper
		@return WriteonlySchema<T?>

		Wraps this schema so that a field using it is typed `write`.
	]=]
    function self:writeonly(): WriteonlySchema<T?>
        return (newWriteonly(validate, true, minimum, maximum) :: any) :: WriteonlySchema<T?>
    end

    return this
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
    access: "readwrite",
    minimum: number?,
    maximum: number?,
    isOptional: boolean,
    _validate: (self: DefaultSchema<T>, value: unknown) -> (T?, { Issue }?),
    safeParse: (self: DefaultSchema<T>, value: unknown) -> Result<T>,
    parse: (self: DefaultSchema<T>, value: unknown) -> T,
    readonly: (self: DefaultSchema<T>) -> ReadonlySchema<T>,
    writeonly: (self: DefaultSchema<T>) -> WriteonlySchema<T>,
}

local function newDefault<T>(
    inner: (value: unknown) -> (T?, { Issue }?),
    produce: () -> T,
    validateOnce: boolean,
    minimum: number?,
    maximum: number?
): DefaultSchema<T>
    local self = {}
    local this = (self :: any) :: DefaultSchema<T>

    --[=[
		@within DefaultSchema
		@prop isOptional boolean
		@tag Reflection
		@readonly

		Always `false`. A defaulted schema accepts a missing value but never
		produces `nil`, so callers do not have to handle one.
	]=]
    self.isOptional = false

    --[=[
		@within DefaultSchema
		@prop access "readwrite"
		@tag Reflection
		@readonly

		Always `"readwrite"`. Chain `:readonly()` or `:writeonly()` to change it.
	]=]
    self.access = "readwrite"

    --[=[
		@within DefaultSchema
		@prop minimum number?
		@tag Reflection
		@readonly

		Forwarded from the wrapped schema.
	]=]
    self.minimum = minimum

    --[=[
		@within DefaultSchema
		@prop maximum number?
		@tag Reflection
		@readonly

		Forwarded from the wrapped schema.
	]=]
    self.maximum = maximum

    local constant: T = nil :: any

    if validateOnce then
        -- Validate a constant fallback up front, so a mistake surfaces where
        -- the schema is written rather than on some later parse of nil.
        local parsed, issues = inner(produce())

        if issues ~= nil then
            error(`default value is invalid: {describe(issues)}`, 3)
        end

        constant = parsed :: T
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
    local function validate(value: unknown): (T?, { Issue }?)
        if value == nil then
            if validateOnce then
                return constant, nil
            end

            -- Built fresh each time, so it is validated each time.
            return inner(produce())
        end

        return inner(value)
    end

    self._validate = function(_self: any, value: unknown): (T?, { Issue }?)
        return validate(value)
    end

    function self:safeParse(value: unknown): Result<T>
        if value == nil and validateOnce then
            return { success = true, value = constant }
        end

        local parsed, issues = validate(value)

        if issues ~= nil then
            return { success = false, issues = issues }
        end

        return { success = true, value = parsed :: T }
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
        local parsed, issues = validate(value)

        if issues ~= nil then
            error(describe(issues), 2)
        end

        return parsed :: T
    end

    --[=[
		@within DefaultSchema
		@method readonly
		@tag Wrapper
		@return ReadonlySchema<T>

		Wraps this schema so that a field using it is typed `read`. The fallback
		is still filled in, so the field is read-only but never missing.
	]=]
    function self:readonly(): ReadonlySchema<T>
        return newReadonly(validate, false, minimum, maximum)
    end

    --[=[
		@within DefaultSchema
		@method writeonly
		@tag Wrapper
		@return WriteonlySchema<T>

		Wraps this schema so that a field using it is typed `write`.
	]=]
    function self:writeonly(): WriteonlySchema<T>
        return newWriteonly(validate, false, minimum, maximum)
    end

    return this
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
    _validate: (self: StringSchema, value: unknown) -> (string?, { Issue }?),
    safeParse: (self: StringSchema, value: unknown) -> Result<string>,
    parse: (self: StringSchema, value: unknown) -> string,
    min: (self: StringSchema, n: number) -> StringSchema,
    max: (self: StringSchema, n: number) -> StringSchema,
    length: (self: StringSchema, n: number) -> StringSchema,
    optional: (self: StringSchema) -> OptionalSchema<string>,
    default: (self: StringSchema, fallback: string) -> DefaultSchema<string>,
    defaultWith: (self: StringSchema, produce: () -> string) -> DefaultSchema<string>,
    readonly: (self: StringSchema) -> ReadonlySchema<string>,
    writeonly: (self: StringSchema) -> WriteonlySchema<string>,
}

export type StringSchema = typeof(setmetatable(
    {} :: {
        _checks: { Check<string> },
        minimum: number?,
        maximum: number?,
        isOptional: boolean,
        access: "readwrite",
    },
    {} :: StringImpl
))

local StringSchema = {} :: StringImpl
StringSchema.__index = StringSchema

--[=[
	@within StringSchema
	@prop minimum number?
	@tag Reflection
	@readonly

	Shortest length this schema accepts, or `nil` if it is unbounded. Set by
	[StringSchema:min] and [StringSchema:length].
]=]

--[=[
	@within StringSchema
	@prop maximum number?
	@tag Reflection
	@readonly

	Longest length this schema accepts, or `nil` if it is unbounded. Set by
	[StringSchema:max] and [StringSchema:length].
]=]

--[=[
	@within StringSchema
	@prop isOptional boolean
	@tag Reflection
	@readonly

	Always `false`. Reading it on any schema tells you whether `nil` is
	accepted without having to know which kind of schema you hold.
]=]

--[=[
	@within StringSchema
	@prop access "readwrite"
	@tag Reflection
	@readonly

	Always `"readwrite"`. Chain [StringSchema:readonly] or
	[StringSchema:writeonly] to change it.
]=]
local function newString(checks: { Check<string> }, minimum: number?, maximum: number?): StringSchema
    return setmetatable({
        _checks = checks,
        minimum = minimum,
        maximum = maximum,
        isOptional = false,
        access = "readwrite" :: "readwrite",
    }, StringSchema)
end

--[=[
	@within StringSchema
	@tag Parsing
	@param value unknown
	@return Result<string>

	Validates `value` without throwing. All refinements run, so the returned
	issues describe every failure rather than only the first.
]=]
function StringSchema:_validate(value: unknown): (string?, { Issue }?)
    if type(value) ~= "string" then
        return nil, failure(`expected string, got {typeof(value)}`)
    end
    return value, runChecks(value, self._checks)
end

function StringSchema:safeParse(value: unknown): Result<string>
    local parsed, issues = self:_validate(value)

    if issues ~= nil then
        return { success = false, issues = issues }
    end

    return { success = true, value = parsed :: string }
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
    local parsed, issues = self:_validate(value)

    if issues ~= nil then
        error(describe(issues), 2)
    end

    return parsed :: string
end

--[=[
	@within StringSchema
	@tag Refinement
	@param n number -- Minimum length, inclusive
	@return StringSchema

	Requires the string to be at least `n` characters long.
]=]
function StringSchema:min(n: number): StringSchema
    return newString(
        append(self._checks, function(value: string)
            return if #value < n then `expected at least {n} characters, got {#value}` else nil
        end),
        n,
        self.maximum
    )
end

--[=[
	@within StringSchema
	@tag Refinement
	@param n number -- Maximum length, inclusive
	@return StringSchema

	Requires the string to be at most `n` characters long.
]=]
function StringSchema:max(n: number): StringSchema
    return newString(
        append(self._checks, function(value: string)
            return if #value > n then `expected at most {n} characters, got {#value}` else nil
        end),
        self.minimum,
        n
    )
end

--[=[
	@within StringSchema
	@tag Refinement
	@param n number -- Exact length
	@return StringSchema

	Requires the string to be exactly `n` characters long.
]=]
function StringSchema:length(n: number): StringSchema
    return newString(
        append(self._checks, function(value: string)
            return if #value ~= n then `expected exactly {n} characters, got {#value}` else nil
        end),
        n,
        n
    )
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
        return inner:_validate(value)
    end, self.minimum, self.maximum)
end

--[=[
	@within StringSchema
	@tag Wrapper
	@param fallback string -- Value used when parsing `nil`
	@return DefaultSchema<string>

	Wraps this schema so that `nil` yields `fallback` instead of failing.
]=]
function StringSchema:default(fallback: string): DefaultSchema<string>
    local inner = self
    return newDefault(function(value)
        return inner:_validate(value)
    end, function()
        return fallback
    end, true, self.minimum, self.maximum)
end

--[=[
	@within StringSchema
	@tag Wrapper
	@param produce () -> string -- Builds the value used when parsing `nil`
	@return DefaultSchema<string>

	Like [StringSchema:default], but calls `produce` on every parse instead of
	reusing one value. Use it when the fallback is a table, since a single
	table would otherwise be shared by every caller and mutable through any
	of them.

	The produced value is validated each time, so a producer that returns
	something invalid fails at parse rather than silently passing through.
]=]
function StringSchema:defaultWith(produce: () -> string): DefaultSchema<string>
    local inner = self
    return newDefault(function(value)
        return inner:_validate(value)
    end, produce, false, self.minimum, self.maximum)
end

--[=[
	@within StringSchema
	@tag Wrapper
	@return ReadonlySchema<string>

	Wraps this schema so that a field using it is typed `read`.
]=]
function StringSchema:readonly(): ReadonlySchema<string>
    local inner = self
    return newReadonly(function(value)
        return inner:_validate(value)
    end, false, self.minimum, self.maximum)
end

--[=[
	@within StringSchema
	@tag Wrapper
	@return WriteonlySchema<string>

	Wraps this schema so that a field using it is typed `write`.
]=]
function StringSchema:writeonly(): WriteonlySchema<string>
    local inner = self
    return newWriteonly(function(value)
        return inner:_validate(value)
    end, false, self.minimum, self.maximum)
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
    _validate: (self: NumberSchema, value: unknown) -> (number?, { Issue }?),
    safeParse: (self: NumberSchema, value: unknown) -> Result<number>,
    parse: (self: NumberSchema, value: unknown) -> number,
    min: (self: NumberSchema, n: number) -> NumberSchema,
    max: (self: NumberSchema, n: number) -> NumberSchema,
    integer: (self: NumberSchema) -> NumberSchema,
    optional: (self: NumberSchema) -> OptionalSchema<number>,
    default: (self: NumberSchema, fallback: number) -> DefaultSchema<number>,
    defaultWith: (self: NumberSchema, produce: () -> number) -> DefaultSchema<number>,
    readonly: (self: NumberSchema) -> ReadonlySchema<number>,
    writeonly: (self: NumberSchema) -> WriteonlySchema<number>,
}

export type NumberSchema = typeof(setmetatable(
    {} :: {
        _checks: { Check<number> },
        minimum: number?,
        maximum: number?,
        isOptional: boolean,
        access: "readwrite",
    },
    {} :: NumberImpl
))

local NumberSchema = {} :: NumberImpl
NumberSchema.__index = NumberSchema

--[=[
	@within NumberSchema
	@prop minimum number?
	@tag Reflection
	@readonly

	Smallest value this schema accepts, or `nil` if it is unbounded. Set by
	[NumberSchema:min].
]=]

--[=[
	@within NumberSchema
	@prop maximum number?
	@tag Reflection
	@readonly

	Largest value this schema accepts, or `nil` if it is unbounded. Set by
	[NumberSchema:max].
]=]

--[=[
	@within NumberSchema
	@prop isOptional boolean
	@tag Reflection
	@readonly

	Always `false`.
]=]

--[=[
	@within NumberSchema
	@prop access "readwrite"
	@tag Reflection
	@readonly

	Always `"readwrite"`. Chain [NumberSchema:readonly] or
	[NumberSchema:writeonly] to change it.
]=]
local function newNumber(checks: { Check<number> }, minimum: number?, maximum: number?): NumberSchema
    return setmetatable({
        _checks = checks,
        minimum = minimum,
        maximum = maximum,
        isOptional = false,
        access = "readwrite" :: "readwrite",
    }, NumberSchema)
end

--[=[
	@within NumberSchema
	@tag Parsing
	@param value unknown
	@return Result<number>

	Validates `value` without throwing. All refinements run, so the returned
	issues describe every failure rather than only the first.
]=]
function NumberSchema:_validate(value: unknown): (number?, { Issue }?)
    if type(value) ~= "number" then
        return nil, failure(`expected number, got {typeof(value)}`)
    end

    if value ~= value then
        return nil, failure("expected number, got nan")
    end
    return value, runChecks(value, self._checks)
end

function NumberSchema:safeParse(value: unknown): Result<number>
    local parsed, issues = self:_validate(value)

    if issues ~= nil then
        return { success = false, issues = issues }
    end

    return { success = true, value = parsed :: number }
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
    local parsed, issues = self:_validate(value)

    if issues ~= nil then
        error(describe(issues), 2)
    end

    return parsed :: number
end

--[=[
	@within NumberSchema
	@tag Refinement
	@param n number -- Minimum value, inclusive
	@return NumberSchema

	Requires the number to be greater than or equal to `n`.
]=]
function NumberSchema:min(n: number): NumberSchema
    return newNumber(
        append(self._checks, function(value: number)
            return if value < n then `expected at least {n}, got {value}` else nil
        end),
        n,
        self.maximum
    )
end

--[=[
	@within NumberSchema
	@tag Refinement
	@param n number -- Maximum value, inclusive
	@return NumberSchema

	Requires the number to be less than or equal to `n`.
]=]
function NumberSchema:max(n: number): NumberSchema
    return newNumber(
        append(self._checks, function(value: number)
            return if value > n then `expected at most {n}, got {value}` else nil
        end),
        self.minimum,
        n
    )
end

--[=[
	@within NumberSchema
	@tag Refinement
	@return NumberSchema

	Requires the number to have no fractional part. Infinities are rejected.
]=]
function NumberSchema:integer(): NumberSchema
    return newNumber(
        append(self._checks, function(value: number)
            return if value % 1 ~= 0 then `expected an integer, got {value}` else nil
        end),
        self.minimum,
        self.maximum
    )
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
        return inner:_validate(value)
    end, self.minimum, self.maximum)
end

--[=[
	@within NumberSchema
	@tag Wrapper
	@param fallback number -- Value used when parsing `nil`
	@return DefaultSchema<number>

	Wraps this schema so that `nil` yields `fallback` instead of failing.
]=]
function NumberSchema:default(fallback: number): DefaultSchema<number>
    local inner = self
    return newDefault(function(value)
        return inner:_validate(value)
    end, function()
        return fallback
    end, true, self.minimum, self.maximum)
end

--[=[
	@within NumberSchema
	@tag Wrapper
	@param produce () -> number -- Builds the value used when parsing `nil`
	@return DefaultSchema<number>

	Like [NumberSchema:default], but calls `produce` on every parse instead of
	reusing one value. Use it when the fallback is a table, since a single
	table would otherwise be shared by every caller and mutable through any
	of them.

	The produced value is validated each time, so a producer that returns
	something invalid fails at parse rather than silently passing through.
]=]
function NumberSchema:defaultWith(produce: () -> number): DefaultSchema<number>
    local inner = self
    return newDefault(function(value)
        return inner:_validate(value)
    end, produce, false, self.minimum, self.maximum)
end

--[=[
	@within NumberSchema
	@tag Wrapper
	@return ReadonlySchema<number>

	Wraps this schema so that a field using it is typed `read`.
]=]
function NumberSchema:readonly(): ReadonlySchema<number>
    local inner = self
    return newReadonly(function(value)
        return inner:_validate(value)
    end, false, self.minimum, self.maximum)
end

--[=[
	@within NumberSchema
	@tag Wrapper
	@return WriteonlySchema<number>

	Wraps this schema so that a field using it is typed `write`.
]=]
function NumberSchema:writeonly(): WriteonlySchema<number>
    local inner = self
    return newWriteonly(function(value)
        return inner:_validate(value)
    end, false, self.minimum, self.maximum)
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
    _validate: (self: BooleanSchema, value: unknown) -> (boolean?, { Issue }?),
    safeParse: (self: BooleanSchema, value: unknown) -> Result<boolean>,
    parse: (self: BooleanSchema, value: unknown) -> boolean,
    optional: (self: BooleanSchema) -> OptionalSchema<boolean>,
    default: (self: BooleanSchema, fallback: boolean) -> DefaultSchema<boolean>,
    defaultWith: (self: BooleanSchema, produce: () -> boolean) -> DefaultSchema<boolean>,
    readonly: (self: BooleanSchema) -> ReadonlySchema<boolean>,
    writeonly: (self: BooleanSchema) -> WriteonlySchema<boolean>,
}

export type BooleanSchema = typeof(setmetatable(
    {} :: {
        _checks: { Check<boolean> },
        isOptional: boolean,
        access: "readwrite",
    },
    {} :: BooleanImpl
))

local BooleanSchema = {} :: BooleanImpl
BooleanSchema.__index = BooleanSchema

--[=[
	@within BooleanSchema
	@prop isOptional boolean
	@tag Reflection
	@readonly

	Always `false`. Booleans carry no `minimum` or `maximum`, since neither
	means anything for two values.
]=]

--[=[
	@within BooleanSchema
	@prop access "readwrite"
	@tag Reflection
	@readonly

	Always `"readwrite"`. Chain [BooleanSchema:readonly] or
	[BooleanSchema:writeonly] to change it.
]=]
local function newBoolean(checks: { Check<boolean> }): BooleanSchema
    return setmetatable({
        _checks = checks,
        isOptional = false,
        access = "readwrite" :: "readwrite",
    }, BooleanSchema)
end

--[=[
	@within BooleanSchema
	@tag Parsing
	@param value unknown
	@return Result<boolean>

	Validates `value` without throwing.
]=]
function BooleanSchema:_validate(value: unknown): (boolean?, { Issue }?)
    if type(value) ~= "boolean" then
        return nil, failure(`expected boolean, got {typeof(value)}`)
    end
    return value, runChecks(value, self._checks)
end

function BooleanSchema:safeParse(value: unknown): Result<boolean>
    local parsed, issues = self:_validate(value)

    if issues ~= nil then
        return { success = false, issues = issues }
    end

    return { success = true, value = parsed :: boolean }
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
    local parsed, issues = self:_validate(value)

    if issues ~= nil then
        error(describe(issues), 2)
    end

    return parsed :: boolean
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
        return inner:_validate(value)
    end, nil, nil)
end

--[=[
	@within BooleanSchema
	@tag Wrapper
	@param fallback boolean -- Value used when parsing `nil`
	@return DefaultSchema<boolean>

	Wraps this schema so that `nil` yields `fallback` instead of failing.
]=]
function BooleanSchema:default(fallback: boolean): DefaultSchema<boolean>
    local inner = self
    return newDefault(function(value)
        return inner:_validate(value)
    end, function()
        return fallback
    end, true, nil, nil)
end

--[=[
	@within BooleanSchema
	@tag Wrapper
	@param produce () -> boolean -- Builds the value used when parsing `nil`
	@return DefaultSchema<boolean>

	Like [BooleanSchema:default], but calls `produce` on every parse instead of
	reusing one value. Use it when the fallback is a table, since a single
	table would otherwise be shared by every caller and mutable through any
	of them.

	The produced value is validated each time, so a producer that returns
	something invalid fails at parse rather than silently passing through.
]=]
function BooleanSchema:defaultWith(produce: () -> boolean): DefaultSchema<boolean>
    local inner = self
    return newDefault(function(value)
        return inner:_validate(value)
    end, produce, false, nil, nil)
end

--[=[
	@within BooleanSchema
	@tag Wrapper
	@return ReadonlySchema<boolean>

	Wraps this schema so that a field using it is typed `read`.
]=]
function BooleanSchema:readonly(): ReadonlySchema<boolean>
    local inner = self
    return newReadonly(function(value)
        return inner:_validate(value)
    end, false, nil, nil)
end

--[=[
	@within BooleanSchema
	@tag Wrapper
	@return WriteonlySchema<boolean>

	Wraps this schema so that a field using it is typed `write`.
]=]
function BooleanSchema:writeonly(): WriteonlySchema<boolean>
    local inner = self
    return newWriteonly(function(value)
        return inner:_validate(value)
    end, false, nil, nil)
end
--[=[
	@class DatatypeSchema

	Validates a Roblox datatype by its `typeof` name, so a table that merely
	carries the same fields is rejected — useful when the value arrived over a
	remote, where anything can be sent.

	Reached through the named constructors rather than built directly:
	[Vet.color3] and [Vet.udim2] both return one of these.

	```lua
	local Tint = v.color3()
	local Size = v.udim2()

	Tint:parse(Color3.new(1, 0, 0))      --> Color3(1, 0, 0)
	Tint:parse({ R = 1, G = 0, B = 0 })  --> errors: expected Color3, got table
	Size:parse(UDim2.fromScale(1, 1))    --> UDim2
	```

	Each datatype schema holds no state beyond the name it checks, so the
	constructors hand out one frozen shared instance rather than allocating.
]=]
export type DatatypeSchema<T> = {
    typeName: string,
    isOptional: boolean,
    access: "readwrite",
    _validate: (self: DatatypeSchema<T>, value: unknown) -> (T?, { Issue }?),
    safeParse: (self: DatatypeSchema<T>, value: unknown) -> Result<T>,
    parse: (self: DatatypeSchema<T>, value: unknown) -> T,
    optional: (self: DatatypeSchema<T>) -> OptionalSchema<T>,
    default: (self: DatatypeSchema<T>, fallback: T) -> DefaultSchema<T>,
    defaultWith: (self: DatatypeSchema<T>, produce: () -> T) -> DefaultSchema<T>,
    readonly: (self: DatatypeSchema<T>) -> ReadonlySchema<T>,
    writeonly: (self: DatatypeSchema<T>) -> WriteonlySchema<T>,
}

--[=[
	@type Color3Schema DatatypeSchema<Color3>
	@within Vet

	What [Vet.color3] returns.
]=]
export type Color3Schema = DatatypeSchema<Color3>

--[=[
	@type UDim2Schema DatatypeSchema<UDim2>
	@within Vet

	What [Vet.udim2] returns.
]=]
export type UDim2Schema = DatatypeSchema<UDim2>

local function newDatatype<T>(typeName: string): DatatypeSchema<T>
    local self = {}
    local this = (self :: any) :: DatatypeSchema<T>

    --[=[
		@within DatatypeSchema
		@prop typeName string
		@tag Reflection
		@readonly

		The `typeof` name this schema accepts, such as `"Color3"`.
	]=]
    self.typeName = typeName

    --[=[
		@within DatatypeSchema
		@prop isOptional boolean
		@tag Reflection
		@readonly

		Always `false`. Datatypes carry no `minimum` or `maximum`.
	]=]
    self.isOptional = false

    --[=[
		@within DatatypeSchema
		@prop access "readwrite"
		@tag Reflection
		@readonly

		Always `"readwrite"`. Chain `:readonly()` or `:writeonly()` to change it.
	]=]
    self.access = "readwrite"

    local function validate(value: unknown): (T?, { Issue }?)
        if typeof(value) ~= typeName then
            return nil, failure(`expected {typeName}, got {typeof(value)}`)
        end

        return value :: any, nil
    end

    self._validate = function(_self: any, value: unknown): (T?, { Issue }?)
        return validate(value)
    end

    --[=[
		@within DatatypeSchema
		@method safeParse
		@tag Parsing
		@param value unknown
		@return Result<T>

		Validates `value` without throwing.
	]=]
    function self:safeParse(value: unknown): Result<T>
        local parsed, issues = validate(value)

        if issues ~= nil then
            return { success = false, issues = issues }
        end

        return { success = true, value = parsed :: T }
    end

    --[=[
		@within DatatypeSchema
		@method parse
		@tag Parsing
		@param value unknown
		@return T
		@error "expected ..." -- Thrown when `value` is a different type

		Validates `value` and returns it, throwing on failure.
	]=]
    function self:parse(value: unknown): T
        local parsed, issues = validate(value)

        if issues ~= nil then
            error(describe(issues), 2)
        end

        return parsed :: T
    end

    --[=[
		@within DatatypeSchema
		@method optional
		@tag Wrapper
		@return OptionalSchema<T>

		Wraps this schema so that `nil` is also accepted.
	]=]
    function self:optional(): OptionalSchema<T>
        return newOptional(function(value)
            return this:_validate(value)
        end, nil, nil)
    end

    --[=[
		@within DatatypeSchema
		@method default
		@tag Wrapper
		@param fallback T -- Value used when parsing `nil`
		@return DefaultSchema<T>

		Wraps this schema so that `nil` yields `fallback` instead of failing.
	]=]
    function self:default(fallback: T): DefaultSchema<T>
        return newDefault(function(value)
            return this:_validate(value)
        end, function()
            return fallback
        end, true, nil, nil)
    end

    --[=[
		@within DatatypeSchema
		@method defaultWith
		@tag Wrapper
		@param produce () -> T -- Builds the value used when parsing `nil`
		@return DefaultSchema<T>

		Like [DatatypeSchema:default], but calls `produce` on every parse.
	]=]
    function self:defaultWith(produce: () -> T): DefaultSchema<T>
        return newDefault(function(value)
            return this:_validate(value)
        end, produce, false, nil, nil)
    end

    --[=[
		@within DatatypeSchema
		@method readonly
		@tag Wrapper
		@return ReadonlySchema<T>

		Wraps this schema so that a field using it is typed `read`.
	]=]
    function self:readonly(): ReadonlySchema<T>
        return newReadonly(function(value)
            return this:_validate(value)
        end, false, nil, nil)
    end

    --[=[
		@within DatatypeSchema
		@method writeonly
		@tag Wrapper
		@return WriteonlySchema<T>

		Wraps this schema so that a field using it is typed `write`.
	]=]
    function self:writeonly(): WriteonlySchema<T>
        return newWriteonly(function(value)
            return this:_validate(value)
        end, false, nil, nil)
    end

    -- Freezing turns the properties read-only in the type system, so the type
    -- is named again on the way out.
    return (table.freeze(this) :: any) :: DatatypeSchema<T>
end

-- newDatatype has nothing to infer its type parameter from, so each datatype
-- names its own on construction.
local COLOR3 = (newDatatype("Color3") :: any) :: Color3Schema
local UDIM2 = (newDatatype("UDim2") :: any) :: UDim2Schema

--[=[
	@class LiteralSchema

	Accepts exactly one value, compared with `==`. Use it where a field may only
	hold a specific constant, and combine several through [ObjectSchema] fields
	to describe a tagged shape.

	```lua
	local Consented = v.literal(true)
	local Kind = v.literal("player")

	Consented:parse(true)  --> true
	Consented:parse(false) --> errors: expected true, got false
	Kind:parse("npc")      --> errors: expected "player", got "npc"
	```
]=]
export type LiteralSchema<T> = {
    value: T,
    isOptional: boolean,
    access: "readwrite",
    _validate: (self: LiteralSchema<T>, value: unknown) -> (T?, { Issue }?),
    safeParse: (self: LiteralSchema<T>, value: unknown) -> Result<T>,
    parse: (self: LiteralSchema<T>, value: unknown) -> T,
    optional: (self: LiteralSchema<T>) -> OptionalSchema<T>,
    default: (self: LiteralSchema<T>, fallback: T) -> DefaultSchema<T>,
    defaultWith: (self: LiteralSchema<T>, produce: () -> T) -> DefaultSchema<T>,
    readonly: (self: LiteralSchema<T>) -> ReadonlySchema<T>,
    writeonly: (self: LiteralSchema<T>) -> WriteonlySchema<T>,
}

-- Quoted so that "1" and 1 do not read the same in an error message.
local function showLiteral(value: unknown): string
    if type(value) == "string" then
        return `"{value}"`
    end

    return tostring(value)
end

local function newLiteral<T>(expected: T): LiteralSchema<T>
    local self = {}
    local this = (self :: any) :: LiteralSchema<T>

    --[=[
		@within LiteralSchema
		@prop value T
		@tag Reflection
		@readonly

		The one value this schema accepts.
	]=]
    self.value = expected

    --[=[
		@within LiteralSchema
		@prop isOptional boolean
		@tag Reflection
		@readonly

		Always `false`.
	]=]
    self.isOptional = false

    --[=[
		@within LiteralSchema
		@prop access "readwrite"
		@tag Reflection
		@readonly

		Always `"readwrite"`. Chain `:readonly()` or `:writeonly()` to change it.
	]=]
    self.access = "readwrite"

    local function validate(value: unknown): (T?, { Issue }?)
        if value ~= expected then
            return nil, failure(`expected {showLiteral(expected)}, got {showLiteral(value)}`)
        end

        return expected, nil
    end

    self._validate = function(_self: any, value: unknown): (T?, { Issue }?)
        return validate(value)
    end

    --[=[
		@within LiteralSchema
		@method safeParse
		@tag Parsing
		@param value unknown
		@return Result<T>

		Validates `value` without throwing.
	]=]
    function self:safeParse(value: unknown): Result<T>
        local parsed, issues = validate(value)

        if issues ~= nil then
            return { success = false, issues = issues }
        end

        return { success = true, value = parsed :: T }
    end

    --[=[
		@within LiteralSchema
		@method parse
		@tag Parsing
		@param value unknown
		@return T
		@error "expected ..." -- Thrown when `value` is anything else

		Validates `value` and returns it, throwing on failure.
	]=]
    function self:parse(value: unknown): T
        local parsed, issues = validate(value)

        if issues ~= nil then
            error(describe(issues), 2)
        end

        return parsed :: T
    end

    --[=[
		@within LiteralSchema
		@method optional
		@tag Wrapper
		@return OptionalSchema<T>

		Wraps this schema so that `nil` is also accepted.
	]=]
    function self:optional(): OptionalSchema<T>
        return newOptional(function(value)
            return this:_validate(value)
        end, nil, nil)
    end

    --[=[
		@within LiteralSchema
		@method default
		@tag Wrapper
		@param fallback T -- Value used when parsing `nil`
		@return DefaultSchema<T>

		Wraps this schema so that `nil` yields `fallback` instead of failing.
	]=]
    function self:default(fallback: T): DefaultSchema<T>
        return newDefault(function(value)
            return this:_validate(value)
        end, function()
            return fallback
        end, true, nil, nil)
    end

    --[=[
		@within LiteralSchema
		@method defaultWith
		@tag Wrapper
		@param produce () -> T -- Builds the value used when parsing `nil`
		@return DefaultSchema<T>

		Like `:default`, but calls `produce` on every parse.
	]=]
    function self:defaultWith(produce: () -> T): DefaultSchema<T>
        return newDefault(function(value)
            return this:_validate(value)
        end, produce, false, nil, nil)
    end

    --[=[
		@within LiteralSchema
		@method readonly
		@tag Wrapper
		@return ReadonlySchema<T>

		Wraps this schema so that a field using it is typed `read`. Pairing it
		with a singleton annotation gives an object a tag that cannot be
		overwritten after parsing.
	]=]
    function self:readonly(): ReadonlySchema<T>
        return newReadonly(function(value)
            return this:_validate(value)
        end, false, nil, nil)
    end

    --[=[
		@within LiteralSchema
		@method writeonly
		@tag Wrapper
		@return WriteonlySchema<T>

		Wraps this schema so that a field using it is typed `write`.
	]=]
    function self:writeonly(): WriteonlySchema<T>
        return newWriteonly(function(value)
            return this:_validate(value)
        end, false, nil, nil)
    end

    return this
end

--[=[
	@class ArraySchema

	Validates a contiguous array where every element matches one inner schema.
	Tables carrying non-array keys are rejected outright.

	The array you pass in is returned untouched unless an element fills a value
	in, which only a nested [DefaultSchema] does. In that case the input is
	shallow copied and the filled values written to the copy, so parsing never
	modifies what it was given and never allocates a copy it does not need.

	```lua
	local Scores = v.array(v.number():integer()):max(4)
	```
]=]
export type ArraySchema<T> = {
    minimum: number?,
    maximum: number?,
    isOptional: boolean,
    access: "readwrite",
    _validate: (self: ArraySchema<T>, value: unknown) -> ({ T }?, { Issue }?),
    safeParse: (self: ArraySchema<T>, value: unknown) -> Result<{ T }>,
    parse: (self: ArraySchema<T>, value: unknown) -> { T },
    min: (self: ArraySchema<T>, n: number) -> ArraySchema<T>,
    max: (self: ArraySchema<T>, n: number) -> ArraySchema<T>,
    optional: (self: ArraySchema<T>) -> OptionalSchema<{ T }>,
    default: (self: ArraySchema<T>, fallback: { T }) -> DefaultSchema<{ T }>,
    defaultWith: (self: ArraySchema<T>, produce: () -> { T }) -> DefaultSchema<{ T }>,
    readonly: (self: ArraySchema<T>) -> ReadonlySchema<{ T }>,
    writeonly: (self: ArraySchema<T>) -> WriteonlySchema<{ T }>,
}

type LengthCheck = (length: number) -> string?

local function newArray<T>(
    inner: (value: unknown) -> (T?, { Issue }?),
    checks: { LengthCheck },
    minimum: number?,
    maximum: number?
): ArraySchema<T>
    local self = {}
    local this = (self :: any) :: ArraySchema<T>

    --[=[
		@within ArraySchema
		@prop minimum number?
		@tag Reflection
		@readonly

		Fewest elements this schema accepts, or `nil` if it is unbounded. Set
		by [ArraySchema:min].
	]=]
    self.minimum = minimum

    --[=[
		@within ArraySchema
		@prop maximum number?
		@tag Reflection
		@readonly

		Most elements this schema accepts, or `nil` if it is unbounded. Set by
		[ArraySchema:max].
	]=]
    self.maximum = maximum

    --[=[
		@within ArraySchema
		@prop isOptional boolean
		@tag Reflection
		@readonly

		Always `false`.
	]=]
    self.isOptional = false

    --[=[
		@within ArraySchema
		@prop access "readwrite"
		@tag Reflection
		@readonly

		Always `"readwrite"`. Chain `:readonly()` or `:writeonly()` to change it.
	]=]
    self.access = "readwrite"

    --[=[
		@within ArraySchema
		@method safeParse
		@tag Parsing
		@param value unknown
		@return Result<{ T }>

		Validates every element, reporting each failure with its index in the
		issue path.
	]=]
    local function validate(value: unknown): ({ T }?, { Issue }?)
        if type(value) ~= "table" then
            return nil, failure(`expected an array, got {typeof(value)}`)
        end

        local items = value :: { unknown }
        local length = #items
        local total = 0

        for _ in items do
            total += 1
        end

        if total ~= length then
            return nil, failure(`expected an array, got a table with {total - length} non-array keys`)
        end

        local issues: { Issue }? = nil
        local output = items
        local copied = false

        for _, check in checks do
            local message = check(length)

            if message ~= nil then
                if issues == nil then
                    issues = { { path = EMPTY_PATH, message = message } }
                else
                    table.insert(issues :: { Issue }, { path = EMPTY_PATH, message = message })
                end
            end
        end

        for index = 1, length do
            local raw = items[index]
            local parsed, elementIssues = inner(raw)

            if elementIssues == nil then
                -- Only a nested default produces a different value, so the copy
                -- is paid for by schemas that fill something in.
                if parsed ~= raw then
                    if not copied then
                        output = table.clone(items)
                        copied = true
                    end

                    output[index] = parsed :: any
                end
            else
                if issues == nil then
                    issues = {}
                end

                local list = issues :: { Issue }

                for _, issue in elementIssues do
                    table.insert(list, { path = prependPath(index, issue.path), message = issue.message })
                end
            end
        end

        if issues ~= nil then
            return nil, issues
        end

        return output :: any, nil
    end

    self._validate = function(_self: any, value: unknown): ({ T }?, { Issue }?)
        return validate(value)
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
    function self:safeParse(value: unknown): Result<{ T }>
        local parsed, issues = validate(value)

        if issues ~= nil then
            return { success = false, issues = issues }
        end

        return { success = true, value = parsed :: { T } }
    end

    function self:parse(value: unknown): { T }
        local parsed, issues = validate(value)

        if issues ~= nil then
            error(describe(issues), 2)
        end

        return parsed :: { T }
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
            end),
            n,
            maximum
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
            end),
            minimum,
            n
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
            return this:_validate(value)
        end, self.minimum, self.maximum)
    end

    --[=[
		@within ArraySchema
		@method default
		@tag Wrapper
		@param fallback { T } -- Value used when parsing `nil`
		@return DefaultSchema<{ T }>

		Wraps this schema so that `nil` yields `fallback` instead of failing.
		Prefer passing a function, since a constant array would be shared by
		every parse.
	]=]
    function self:default(fallback: { T }): DefaultSchema<{ T }>
        return newDefault(function(value)
            return this:_validate(value)
        end, function()
            return fallback
        end, true, self.minimum, self.maximum)
    end

    --[=[
		@within ArraySchema
		@method defaultWith
		@tag Wrapper
		@param produce () -> { T } -- Builds the value used when parsing `nil`
		@return DefaultSchema<{ T }>

		Like `:default`, but calls `produce` on every parse instead of reusing
		one value. Prefer it here, since a single table would otherwise be
		shared by every caller and mutable through any of them.

		The produced value is validated each time.
	]=]
    function self:defaultWith(produce: () -> { T }): DefaultSchema<{ T }>
        return newDefault(function(value)
            return this:_validate(value)
        end, produce, false, self.minimum, self.maximum)
    end

    --[=[
		@within ArraySchema
		@method readonly
		@tag Wrapper
		@return ReadonlySchema<{ T }>

		Wraps this schema so that a field using it is typed `read`. The array
		itself stays mutable; it is the field that cannot be reassigned.
	]=]
    function self:readonly(): ReadonlySchema<{ T }>
        return newReadonly(function(value)
            return this:_validate(value)
        end, false, self.minimum, self.maximum)
    end

    --[=[
		@within ArraySchema
		@method writeonly
		@tag Wrapper
		@return WriteonlySchema<{ T }>

		Wraps this schema so that a field using it is typed `write`.
	]=]
    function self:writeonly(): WriteonlySchema<{ T }>
        return newWriteonly(function(value)
            return this:_validate(value)
        end, false, self.minimum, self.maximum)
    end

    return this
end

--[=[
	@class TupleSchema

	Validates a fixed sequence where each position has its own schema. Use it
	for packed argument lists and other positional payloads, where [ArraySchema]
	would only let you say that every element is the same shape.

	Like [ArraySchema], the input is returned untouched unless a position fills
	a value in, in which case it is shallow copied first.

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
    minimum: number?,
    maximum: number?,
    isOptional: boolean,
    access: "readwrite",
    _validate: (self: TupleSchema<T>, value: unknown) -> ({ T }?, { Issue }?),
    safeParse: (self: TupleSchema<T>, value: unknown) -> Result<{ T }>,
    parse: (self: TupleSchema<T>, value: unknown) -> { T },
    optional: (self: TupleSchema<T>) -> OptionalSchema<{ T }>,
    default: (self: TupleSchema<T>, fallback: { T }) -> DefaultSchema<{ T }>,
    defaultWith: (self: TupleSchema<T>, produce: () -> { T }) -> DefaultSchema<{ T }>,
    readonly: (self: TupleSchema<T>) -> ReadonlySchema<{ T }>,
    writeonly: (self: TupleSchema<T>) -> WriteonlySchema<{ T }>,
}

type Positions<T> = { AnySchema<T> }

local function newTuple<T>(positions: Positions<T>): TupleSchema<T>
    local self = {}
    local this = (self :: any) :: TupleSchema<T>

    --[=[
		@within TupleSchema
		@prop minimum number?
		@tag Reflection
		@readonly

		Always `nil`. How few values a tuple accepts depends on how many of its
		trailing positions tolerate `nil`, so there is no single number.
	]=]
    self.minimum = nil

    --[=[
		@within TupleSchema
		@prop maximum number?
		@tag Reflection
		@readonly

		The number of positions, which is the most values this schema accepts.
	]=]
    self.maximum = #positions

    --[=[
		@within TupleSchema
		@prop isOptional boolean
		@tag Reflection
		@readonly

		Always `false`.
	]=]
    self.isOptional = false

    --[=[
		@within TupleSchema
		@prop access "readwrite"
		@tag Reflection
		@readonly

		Always `"readwrite"`. Chain `:readonly()` or `:writeonly()` to change it.
	]=]
    self.access = "readwrite"

    --[=[
		@within TupleSchema
		@method safeParse
		@tag Parsing
		@param value unknown
		@return Result<{ T }>

		Validates each position against its own schema, reporting failures with
		the index in the issue path.
	]=]
    local function validate(value: unknown): ({ T }?, { Issue }?)
        if type(value) ~= "table" then
            return nil, failure(`expected a tuple, got {typeof(value)}`)
        end

        local items = value :: { unknown }
        local length = #items
        local total = 0

        for _ in items do
            total += 1
        end

        if total ~= length then
            return nil, failure(`expected a tuple, got a table with {total - length} non-array keys`)
        end

        if length > #positions then
            return nil, failure(`expected a tuple of {#positions} values, got {length}`)
        end

        local issues: { Issue }? = nil
        local output = items
        local copied = false

        -- Positions past the end are parsed as nil, so an optional or defaulted
        -- tail still succeeds while a required one reports the missing index.
        for index, schema in positions do
            local raw = items[index]
            local parsed, elementIssues = schema:_validate(raw)

            if elementIssues == nil then
                if parsed ~= raw then
                    if not copied then
                        output = table.clone(items)
                        copied = true
                    end

                    output[index] = parsed :: any
                end
            else
                if issues == nil then
                    issues = {}
                end

                local list = issues :: { Issue }

                for _, issue in elementIssues do
                    table.insert(list, { path = prependPath(index, issue.path), message = issue.message })
                end
            end
        end

        if issues ~= nil then
            return nil, issues
        end

        return output :: any, nil
    end

    self._validate = function(_self: any, value: unknown): ({ T }?, { Issue }?)
        return validate(value)
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
    function self:safeParse(value: unknown): Result<{ T }>
        local parsed, issues = validate(value)

        if issues ~= nil then
            return { success = false, issues = issues }
        end

        return { success = true, value = parsed :: { T } }
    end

    function self:parse(value: unknown): { T }
        local parsed, issues = validate(value)

        if issues ~= nil then
            error(describe(issues), 2)
        end

        return parsed :: { T }
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
            return this:_validate(value)
        end, self.minimum, self.maximum)
    end

    --[=[
		@within TupleSchema
		@method default
		@tag Wrapper
		@param fallback { T } -- Value used when parsing `nil`
		@return DefaultSchema<{ T }>

		Wraps this schema so that `nil` yields `fallback` instead of failing.
		Prefer passing a function, since a constant table would be shared by
		every parse.
	]=]
    function self:default(fallback: { T }): DefaultSchema<{ T }>
        return newDefault(function(value)
            return this:_validate(value)
        end, function()
            return fallback
        end, true, self.minimum, self.maximum)
    end

    --[=[
		@within TupleSchema
		@method defaultWith
		@tag Wrapper
		@param produce () -> { T } -- Builds the value used when parsing `nil`
		@return DefaultSchema<{ T }>

		Like `:default`, but calls `produce` on every parse instead of reusing
		one value. Prefer it here, since a single table would otherwise be
		shared by every caller and mutable through any of them.

		The produced value is validated each time.
	]=]
    function self:defaultWith(produce: () -> { T }): DefaultSchema<{ T }>
        return newDefault(function(value)
            return this:_validate(value)
        end, produce, false, self.minimum, self.maximum)
    end

    --[=[
		@within TupleSchema
		@method readonly
		@tag Wrapper
		@return ReadonlySchema<{ T }>

		Wraps this schema so that a field using it is typed `read`.
	]=]
    function self:readonly(): ReadonlySchema<{ T }>
        return newReadonly(function(value)
            return this:_validate(value)
        end, false, self.minimum, self.maximum)
    end

    --[=[
		@within TupleSchema
		@method writeonly
		@tag Wrapper
		@return WriteonlySchema<{ T }>

		Wraps this schema so that a field using it is typed `write`.
	]=]
    function self:writeonly(): WriteonlySchema<{ T }>
        return newWriteonly(function(value)
            return this:_validate(value)
        end, false, self.minimum, self.maximum)
    end

    return this
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
    isOptional: boolean,
    access: "readwrite",
    _validate: (self: ObjectSchema<T, S>, value: unknown) -> (T?, { Issue }?),
    safeParse: (self: ObjectSchema<T, S>, value: unknown) -> Result<T>,
    parse: (self: ObjectSchema<T, S>, value: unknown) -> T,
    strict: (self: ObjectSchema<T, S>) -> ObjectSchema<T, S>,
    optional: (self: ObjectSchema<T, S>) -> OptionalSchema<T>,
    default: (self: ObjectSchema<T, S>, fallback: T) -> DefaultSchema<T>,
    defaultWith: (self: ObjectSchema<T, S>, produce: () -> T) -> DefaultSchema<T>,
    readonly: (self: ObjectSchema<T, S>) -> ReadonlySchema<T>,
    writeonly: (self: ObjectSchema<T, S>) -> WriteonlySchema<T>,
}

type Shape = { [string]: AnySchema<any> }

local function newObject<S>(shape: S, strict: boolean): ObjectSchema<objectOutput<S>, S>
    local self = {}
    local this = (self :: any) :: ObjectSchema<objectOutput<S>, S>

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
    local fields = table.freeze(table.clone(shape :: any)) :: Shape

    self.shape = fields

    --[=[
		@within ObjectSchema
		@prop isOptional boolean
		@tag Reflection
		@readonly

		Always `false`. Objects carry no `minimum` or `maximum`; read
		[ObjectSchema.shape] to reach a field's own limits.
	]=]
    self.isOptional = false

    --[=[
		@within ObjectSchema
		@prop access "readwrite"
		@tag Reflection
		@readonly

		Always `"readwrite"`, and describes this schema as a field of some other
		object rather than its own fields. Read `shape[field].access` for those.
	]=]
    self.access = "readwrite"

    --[=[
		@within ObjectSchema
		@method safeParse
		@tag Parsing
		@param value unknown
		@return Result<objectOutput<S>>

		Validates every field in the shape, reporting each failure with its
		field name in the issue path.
	]=]
    local function validate(value: unknown): (objectOutput<S>?, { Issue }?)
        if type(value) ~= "table" then
            return nil, failure(`expected an object, got {typeof(value)}`)
        end

        local record = value :: { [string]: unknown }
        local issues: { Issue }? = nil
        local output = record
        local copied = false

        for key, schema in fields do
            local raw = record[key]
            local parsed, fieldIssues = schema:_validate(raw)

            if fieldIssues == nil then
                -- A field only produces a different value when something filled
                -- it in, so the copy is paid for only by schemas using defaults.
                if parsed ~= raw then
                    if not copied then
                        output = table.clone(record)
                        copied = true
                    end

                    output[key] = parsed
                end
            else
                if issues == nil then
                    issues = {}
                end

                local list = issues :: { Issue }

                for _, issue in fieldIssues do
                    table.insert(list, { path = prependPath(key, issue.path), message = issue.message })
                end
            end
        end

        if strict then
            for key in record do
                if fields[key] == nil then
                    if issues == nil then
                        issues = {}
                    end

                    table.insert(issues :: { Issue }, { path = { key }, message = "unexpected key" })
                end
            end
        end

        if issues ~= nil then
            return nil, issues
        end

        return output :: any, nil
    end

    self._validate = function(_self: any, value: unknown): (objectOutput<S>?, { Issue }?)
        return validate(value)
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
    function self:safeParse(value: unknown): Result<objectOutput<S>>
        local parsed, issues = validate(value)

        if issues ~= nil then
            return { success = false, issues = issues }
        end

        return { success = true, value = parsed :: objectOutput<S> }
    end

    function self:parse(value: unknown): objectOutput<S>
        local parsed, issues = validate(value)

        if issues ~= nil then
            error(describe(issues), 2)
        end

        return parsed :: objectOutput<S>
    end

    --[=[
		@within ObjectSchema
		@method strict
		@tag Refinement
		@return ObjectSchema<objectOutput<S>, S>

		Returns a schema that also rejects keys absent from the shape. Use it
		for data crossing a trust boundary, where an unexpected field is more
		likely a mistake than a spare.
	]=]
    function self:strict(): ObjectSchema<objectOutput<S>, S>
        -- Rebuilt from the original shape rather than the frozen copy, so the
        -- shape type parameter stays bound to what the caller passed in.
        return newObject(shape, true)
    end

    --[=[
		@within ObjectSchema
		@method optional
		@tag Wrapper
		@return OptionalSchema<objectOutput<S>>

		Wraps this schema so that `nil` is also accepted.
	]=]
    function self:optional(): OptionalSchema<objectOutput<S>>
        return newOptional(function(value)
            return this:_validate(value)
        end, nil, nil)
    end

    --[=[
		@within ObjectSchema
		@method default
		@tag Wrapper
		@param fallback T -- Value used when parsing `nil`
		@return DefaultSchema<objectOutput<S>>

		Wraps this schema so that `nil` yields `fallback` instead of failing.
		Prefer passing a function, since a constant table would be shared by
		every parse.
	]=]
    function self:default(fallback: objectOutput<S>): DefaultSchema<objectOutput<S>>
        return newDefault(function(value)
            return this:_validate(value)
        end, function()
            return fallback
        end, true, nil, nil)
    end

    --[=[
		@within ObjectSchema
		@method defaultWith
		@tag Wrapper
		@param produce () -> T -- Builds the value used when parsing `nil`
		@return DefaultSchema<objectOutput<S>>

		Like `:default`, but calls `produce` on every parse instead of reusing
		one value. Prefer it here, since a single table would otherwise be
		shared by every caller and mutable through any of them.

		The produced value is validated each time.
	]=]
    function self:defaultWith(produce: () -> objectOutput<S>): DefaultSchema<objectOutput<S>>
        return newDefault(function(value)
            return this:_validate(value)
        end, produce, false, nil, nil)
    end

    --[=[
		@within ObjectSchema
		@method readonly
		@tag Wrapper
		@return ReadonlySchema<objectOutput<S>>

		Wraps this schema so that a field using it is typed `read`. Only the
		field is affected; the nested record keeps whatever access its own
		fields declare.
	]=]
    function self:readonly(): ReadonlySchema<objectOutput<S>>
        return newReadonly(function(value)
            return this:_validate(value)
        end, false, nil, nil)
    end

    --[=[
		@within ObjectSchema
		@method writeonly
		@tag Wrapper
		@return WriteonlySchema<objectOutput<S>>

		Wraps this schema so that a field using it is typed `write`.
	]=]
    function self:writeonly(): WriteonlySchema<objectOutput<S>>
        return newWriteonly(function(value)
            return this:_validate(value)
        end, false, nil, nil)
    end

    return this
end

--[=[
	@class UnionSchema

	Accepts a value that matches any one of several schemas. Options are tried
	in order and the first that succeeds decides the result, so when two options
	overlap the earlier one wins — put the narrower option first if you want it
	to be the one that parses.

	```lua
	local Id = v.union({ v.string():min(1), v.number():integer() })

	Id:parse("player_1") --> "player_1"
	Id:parse(7)          --> 7
	Id:parse(true)       --> errors
	```

	A tagged shape falls out of combining [LiteralSchema] with [ObjectSchema],
	which is how a union of message kinds is usually written. Annotate each tag
	as a singleton, since [Vet.literal] otherwise widens it to `string` and the
	arms become indistinguishable to Luau:

	```lua
	local Join: v.LiteralSchema<"join"> = v.literal("join")
	local Chat: v.LiteralSchema<"chat"> = v.literal("chat")

	local Event = v.union({
		v.object({ kind = Join, userId = v.number() }),
		v.object({ kind = Chat, text = v.string() }),
	})

	local event = Event:parse(payload)

	if event.kind == "chat" then
		print(event.text) -- narrowed to the chat arm
	end
	```

	Nothing matching is a failure of the union as a whole rather than of any one
	option, so the issue sits at the union's own path and its message names each
	option and why that option rejected the value.
]=]
export type UnionSchema<T> = {
    options: { AnySchema<any> },
    isOptional: boolean,
    access: "readwrite",
    _validate: (self: UnionSchema<T>, value: unknown) -> (T?, { Issue }?),
    safeParse: (self: UnionSchema<T>, value: unknown) -> Result<T>,
    parse: (self: UnionSchema<T>, value: unknown) -> T,
    optional: (self: UnionSchema<T>) -> OptionalSchema<T>,
    default: (self: UnionSchema<T>, fallback: T) -> DefaultSchema<T>,
    defaultWith: (self: UnionSchema<T>, produce: () -> T) -> DefaultSchema<T>,
    readonly: (self: UnionSchema<T>) -> ReadonlySchema<T>,
    writeonly: (self: UnionSchema<T>) -> WriteonlySchema<T>,
}

local function newUnion<T>(options: { AnySchema<any> }): UnionSchema<T>
    if #options == 0 then
        error("expected at least one option", 3)
    end

    local self = {}
    local this = (self :: any) :: UnionSchema<T>

    --[=[
		@within UnionSchema
		@prop options { AnySchema<any> }
		@tag Reflection
		@readonly

		The schemas this union was built from, in the order they are tried:

		```lua
		local Id = v.union({ v.string(), v.number() })

		#Id.options             --> 2
		Id.options[1]:parse("") --> ""
		```

		The table is a frozen copy of the one passed to [Vet.union], so mutating
		it fails loudly rather than corrupting the schema.
	]=]
    local branches = table.freeze(table.clone(options))

    self.options = branches

    --[=[
		@within UnionSchema
		@prop isOptional boolean
		@tag Reflection
		@readonly

		`true` when any option accepts `nil`, since then the union does too.
		A [DefaultSchema] option does not count: it accepts a missing value but
		fills one in, so the union still never produces `nil`.
	]=]
    local optional = false

    for _, option in branches do
        if (option :: any).isOptional then
            optional = true
            break
        end
    end

    self.isOptional = optional

    --[=[
		@within UnionSchema
		@prop access "readwrite"
		@tag Reflection
		@readonly

		Always `"readwrite"`, whatever the options carry. An option's marker
		says how that option would sit in an object, not how the union does.
	]=]
    self.access = "readwrite"

    --[=[
		@within UnionSchema
		@method safeParse
		@tag Parsing
		@param value unknown
		@return Result<T>

		Tries each option in order and returns what the first match parsed to.
		When none match, the single issue reports every option's rejection.
	]=]
    local function validate(value: unknown): (T?, { Issue }?)
        -- Allocated only once an option has been rejected, so a value that the
        -- first option accepts costs nothing here at all.
        local reasons: { string }? = nil

        for index, option in branches do
            local parsed, issues = option:_validate(value)

            -- Read from the issues rather than the value, so an option that
            -- accepts nil still counts as the match it is.
            if issues == nil then
                return parsed :: T, nil
            end

            -- A union of one has nothing to choose between, so its rejection is
            -- the option's own, paths and all.
            if #branches == 1 then
                return nil, issues
            end

            local reason = `option {index}: {describe(issues)}`

            if reasons == nil then
                reasons = { reason }
            else
                table.insert(reasons :: { string }, reason)
            end
        end

        return nil, failure(`expected one of {#branches} options ({table.concat(reasons :: { string }, "; ")})`)
    end

    self._validate = function(_self: any, value: unknown): (T?, { Issue }?)
        return validate(value)
    end

    function self:safeParse(value: unknown): Result<T>
        local parsed, issues = validate(value)

        if issues ~= nil then
            return { success = false, issues = issues }
        end

        return { success = true, value = parsed :: T }
    end

    --[=[
		@within UnionSchema
		@method parse
		@tag Parsing
		@param value unknown
		@return T
		@error "expected one of ..." -- Thrown when no option accepts `value`

		Validates `value` and returns it, throwing on failure.
	]=]
    function self:parse(value: unknown): T
        local parsed, issues = validate(value)

        if issues ~= nil then
            error(describe(issues), 2)
        end

        return parsed :: T
    end

    --[=[
		@within UnionSchema
		@method optional
		@tag Wrapper
		@return OptionalSchema<T>

		Wraps this schema so that `nil` is also accepted.
	]=]
    function self:optional(): OptionalSchema<T>
        return newOptional(function(value)
            return this:_validate(value)
        end, nil, nil)
    end

    --[=[
		@within UnionSchema
		@method default
		@tag Wrapper
		@param fallback T -- Value used when parsing `nil`
		@return DefaultSchema<T>

		Wraps this schema so that `nil` yields `fallback` instead of failing.
		Prefer passing a function when the fallback is a table, since a constant
		one would be shared by every parse.
	]=]
    function self:default(fallback: T): DefaultSchema<T>
        return newDefault(function(value)
            return this:_validate(value)
        end, function()
            return fallback
        end, true, nil, nil)
    end

    --[=[
		@within UnionSchema
		@method defaultWith
		@tag Wrapper
		@param produce () -> T -- Builds the value used when parsing `nil`
		@return DefaultSchema<T>

		Like `:default`, but calls `produce` on every parse instead of reusing
		one value.

		The produced value is validated each time.
	]=]
    function self:defaultWith(produce: () -> T): DefaultSchema<T>
        return newDefault(function(value)
            return this:_validate(value)
        end, produce, false, nil, nil)
    end

    --[=[
		@within UnionSchema
		@method readonly
		@tag Wrapper
		@return ReadonlySchema<T>

		Wraps this schema so that a field using it is typed `read`.
	]=]
    function self:readonly(): ReadonlySchema<T>
        return newReadonly(function(value)
            return this:_validate(value)
        end, false, nil, nil)
    end

    --[=[
		@within UnionSchema
		@method writeonly
		@tag Wrapper
		@return WriteonlySchema<T>

		Wraps this schema so that a field using it is typed `write`.
	]=]
    function self:writeonly(): WriteonlySchema<T>
        return newWriteonly(function(value)
            return this:_validate(value)
        end, false, nil, nil)
    end

    return this
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
    return function(value: string): string?
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
	@return Color3Schema

	Creates a schema that accepts a `Color3`.

	```lua
	local Tint = v.color3()

	Tint:parse(Color3.fromRGB(255, 0, 0)) --> Color3(1, 0, 0)
	Tint:parse({ R = 1, G = 0, B = 0 })   --> errors: expected Color3, got table
	```

	The schema holds no state, so every call returns the same frozen instance.
]=]
function Vet.color3(): Color3Schema
    return COLOR3
end

--[=[
	@within Vet
	@tag Constructor
	@return UDim2Schema

	Creates a schema that accepts a `UDim2`.

	```lua
	local Size = v.udim2()

	Size:parse(UDim2.fromScale(1, 0.5)) --> UDim2
	Size:parse({ X = 1, Y = 0.5 })      --> errors: expected UDim2, got table
	```

	The schema holds no state, so every call returns the same frozen instance.
]=]
function Vet.udim2(): UDim2Schema
    return UDIM2
end
--[=[
	@within Vet
	@tag Constructor
	@param value T -- The only value the schema accepts
	@return LiteralSchema<T>

	Creates a schema that accepts exactly `value`, compared with `==`.

	```lua
	local Consented = v.literal(true)

	Consented:parse(true)  --> true
	Consented:parse(false) --> errors: expected true, got false
	```

	Luau widens a literal argument when it infers a generic, so the result is
	typed `boolean` rather than `true`. Annotate the schema if you need the
	singleton: `local Kind: LiteralSchema<"player"> = v.literal("player")`.
]=]
function Vet.literal<T>(value: T): LiteralSchema<T>
    return newLiteral(value)
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
    local schema = item :: AnySchema<infer<S>>

    return newArray(function(value)
        return schema:_validate(value)
    end, {}, nil, nil)
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
    -- newTuple cannot bind its element type from an erased position list, so
    -- the result is named here instead.
    return (newTuple(positions :: any) :: any) :: TupleSchema<infer<S>>
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
    return newObject(shape, false)
end

--[=[
	@within Vet
	@tag Constructor
	@param options { S } -- Schemas to try, in order
	@return UnionSchema<Vet.infer<S>>
	@error "expected at least one option" -- Thrown when `options` is empty

	Creates a schema that accepts a value matching any one of `options`, trying
	them in order and keeping what the first match parsed to.

	```lua
	local Id = v.union({ v.string():min(1), v.number():integer() })

	type Id = v.infer<typeof(Id)> --> string | number

	Id:parse("player_1") --> "player_1"
	Id:parse(7)          --> 7
	Id:parse(1.5)        --> errors: expected one of 2 options
	                     --  (option 1: expected string, got number;
	                     --   option 2: expected an integer, got 1.5)
	```

	Luau infers a mixed array literal as a union of its element types, which is
	exactly what a union needs, so the inferred output is the union of what each
	option parses to.
]=]
function Vet.union<S>(options: { S }): UnionSchema<infer<S>>
    -- newUnion cannot bind its output type from an erased option list, so the
    -- result is named here instead.
    return (newUnion(options :: any) :: any) :: UnionSchema<infer<S>>
end

--[=[
	@within Vet
	@tag Constructor
	@param schema S -- Schema the field is validated against
	@return ReadonlySchema<Vet.infer<S>>

	Marks a schema read-only, so a field using it is declared `read` in the
	record [Vet.object] parses to.

	```lua
	local PlayerData = v.object({
		id = v.readonly(v.number():integer()),
		name = v.string(),
	})

	type PlayerData = v.infer<typeof(PlayerData)>
	--> { read id: number, name: string }
	```

	Every schema also has a `:readonly()` method, which reads better at the end
	of a chain: `v.number():integer():readonly()`. Use this form when the schema
	arrives from somewhere else and there is no chain to put it on.
]=]
function Vet.readonly<S>(schema: S): ReadonlySchema<infer<S>>
    local inner = schema :: AnySchema<infer<S>>
    local reflection = schema :: any

    return newReadonly(function(value)
        return inner:_validate(value)
    end, reflection.isOptional == true, reflection.minimum, reflection.maximum)
end

--[=[
	@within Vet
	@tag Constructor
	@param schema S -- Schema the field is validated against
	@return WriteonlySchema<Vet.infer<S>>

	Marks a schema write-only, so a field using it is declared `write` in the
	record [Vet.object] parses to.

	```lua
	local PlayerData = v.object({
		name = v.string(),
		secretToken = v.writeonly(v.string():length(32)),
	})

	type PlayerData = v.infer<typeof(PlayerData)>
	--> { name: string, write secretToken: string }
	```

	The token is still validated on the way in and still present at runtime —
	what changes is that reading it back is an analysis error, so it cannot be
	logged or replicated by accident.
]=]
function Vet.writeonly<S>(schema: S): WriteonlySchema<infer<S>>
    local inner = schema :: AnySchema<infer<S>>
    local reflection = schema :: any

    return newWriteonly(function(value)
        return inner:_validate(value)
    end, reflection.isOptional == true, reflection.minimum, reflection.maximum)
end

return Vet
