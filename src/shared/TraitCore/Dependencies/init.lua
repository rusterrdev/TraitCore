local CollectionService = game:GetService("CollectionService")
local Promise = require(script.Dependencies.promise)
local Signal = require(script.Dependencies.signal)

local uniqueIdentifiers = {}

--[=[
    @class TraitCore

     ```lua
    -- use example
    local traitCore = TraitCore.newTrait("MyTrait", function(self, instance)
        print("Trait applied to instance:", instance.Name)
    end)

    local instance = Instance.new("Part")
    traitCore:fetchAsync(instance)
    ```

    base class
]=]

local TraitCore: TraitCore = {
    _entity_tags = {},
    _query_manager = setmetatable({}, {
        __tostring = function()
            return `QUERY_MANAGER_SUB_CLASS`
        end
    }),
    track = Signal.new(),
} :: TraitCore

setmetatable(TraitCore, {
    __tostring = function()
        return `TRAIT_CORE_CLASS`
    end
})

--[=[
    @param traitIdentifier string
    @param handlerCallback : (selfObject: TraitCore?, entityInstance: Instance) -> ()
    @return Trait
]=]

function TraitCore.newTrait(traitIdentifier, handlerCallback): Trait
    assert(type(traitIdentifier) == "string", "traitIdentifier must be a string")
    assert(type(handlerCallback) == "function", "handlerCallback must be a function")
    assert(not uniqueIdentifiers[traitIdentifier], `Trait with identifier "{traitIdentifier}" already exists.`)

    local self = setmetatable({
        _identifier = traitIdentifier,
        _handlerCallback = handlerCallback,
        _builded_signal = Signal.new(),       

    }, {__index = TraitCore, __mode = "k"})

    local meta = getmetatable(self)

    function meta:__tostring()
        return `TRAIT_CORE TRAIT: '{traitIdentifier}'`
    end

    self._builded_signal:Connect(function(instance)
        self._handlerCallback(self, instance)
    end)

    uniqueIdentifiers[traitIdentifier] = true
    self._entity_tags[traitIdentifier] = {}

    return self
end

--[=[
    @param trait Trait
    @return void
    destroy ```trait```
]=]

function TraitCore:cleanupTrait(trait: Trait)    
    uniqueIdentifiers[trait._identifier] = nil
    trait = nil
    self._entity_tags[trait._identifier] = nil
end

--[=[
    @param instance Instance
    @return void
    remove ```instance``` from trait
]=]


function TraitCore:removeInstance(instance: Instance)
    local instanceIndexTrait = table.find(self._entity_tags[self._identifier], instance)
    if not instanceIndexTrait then return end
    table.remove(self._entity_tags[self._identifier], instanceIndexTrait)
end

--[=[
    @param instance Instance
    @return boolean
    returns whether the ```instance``` is part of the trait.
]=]

function TraitCore:isAssociated(instance: Instance): boolean
    return table.find(self._entity_tags[self._identifier], instance) ~= nil
end

--[=[
    @param identifier string
    @return QueryManager

    ```lua
        local TraitCore = require(PATH_TO_TRAIT_CORE)
        
        local trait = TraitCore.newTrait("example", function(self, instance)
            print(`{part.Name} has been added to the example trait!`)
            part.Size = Vector3.new(3,3,3)
        end)
        
        task.spawn(function()
            trait:await(part)
            print(TraitCore:query("example"):get()) -->> {[1]: Part}

        end)

        TraitCore:query():track(function(self, instance)
             print(`{part.Name} has been added to the {self} trait!`)
        end)

        local part = Instance.new("Part")
        trait:fetchAsync(part):await()
        --part has been added to the trait
    ```
]=]


function TraitCore:query(identifier: string)
    assert(type(identifier) == "string", "identifier must be a string")
    local Self = self

    function self._query_manager:track(listener)
        Self.track:Connect(listener)
    end
    function self._query_manager:get()
        return Self._entity_tags[identifier]
    end

    return self._query_manager
end

--[=[
    @param instance Instance
    @return Promise
    have a promise , to add the ```instance``` to the trait. and also returns such a promise.

    ```lua
        local TraitCore = require(PATH_TO_TRAIT_CORE)
        
        local trait = TraitCore.newTrait("example", function(self, instance)
            print(`{part.Name} has been added to the example trait!`)
            part.Size = Vector3.new(3,3,3)
        end)

        local part = Instance.new("Part")
        trait:fetchAsync(part):await()
        --part has been added to the trait
    ```
]=]

function TraitCore:fetchAsync(instance: Instance)
    assert(instance and instance:IsA("Instance"), "Invalid instance")

    local handleBuild = Promise.try(function()
        CollectionService:AddTag(instance, self._identifier)
        table.insert(self._entity_tags[self._identifier], instance)
    end)

    handleBuild:andThen(function()
        self._builded_signal:Fire(instance)
        self.track:Fire(self, instance)
    end):catch(function(err)
        warn("Failed to fetchAsync: " .. tostring(err))
    end)

   return handleBuild
end

--[=[
    @param instance Instance
    @return ()

    Pauses the current thread, until an instance is linked to Trait.

    ```lua
        local TraitCore = require(PATH_TO_TRAIT_CORE)
        
        local trait = TraitCore.newTrait("example", function(self, instance)

        end)
        
        local part = Instance.new("Part")
        
        task.spawn(function()
            trait:await(part)
            print("part has been added to 'example' trait!")
        end)

        trait:fetchAsync(part):await()        
    ```
]=]

function TraitCore:await(instance: Instance)
    assert(instance and instance:IsA("Instance"), "Invalid instance")

    repeat local entityCreated = CollectionService:GetInstanceAddedSignal(self._identifier):Wait()
    until entityCreated == instance

    while true do
        local entityIndex = table.find(self._entity_tags[self._identifier], instance)
        if entityIndex then return self._entity_tags[self._identifier][entityIndex] end
    end
end


type Promise = typeof(Promise.new())
type Signal = typeof(Signal.new())

--- @type QueryManager {get: () -> {Instance},  track: (self: TraitCore, listener: (selfObject: TraitCore?, entityInstance: Instance) -> ()) -> ()}
--- @within TraitCore
--- Query Manager

export type QueryManager = {
    get: () -> {Instance},
    track: (self: TraitCore, listener: (selfObject: TraitCore?, entityInstance: Instance) -> ()) -> (),
}


--- @type TraitCore { newTrait = (traitIdentifier: string, handlerCallback: (selfObject: TraitCore?, entityInstance: Instance) -> ()) -> Trait, query = (self: TraitCore, identifier: string) -> QueryManager }
--- @within TraitCore


export type TraitCore = {
    newTrait: (traitIdentifier: string, handlerCallback: (selfObject: TraitCore?, entityInstance: Instance) -> ()) -> Trait,
    query: (self: TraitCore, identifier: string) -> QueryManager
}

--- @type Trait = { fetchAsync: (self: Trait, instance: Instance) -> Promise, await: (self: Trait, instance: Instance) -> Instance?, isAssociated: (self: Trait, instance: Instance) -> boolean }
--- @within TraitCore

export type Trait = {
    fetchAsync: (self: Trait, instance: Instance) -> Promise,
    await: (self: Trait, instance: Instance) -> Instance?,
    isAssociated: (self: Trait, instance: Instance) -> boolean,
}   



return table.freeze(TraitCore)