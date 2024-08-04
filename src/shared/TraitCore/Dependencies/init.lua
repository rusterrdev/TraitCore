local CollectionService = game:GetService("CollectionService")
local LocalizationService = game:GetService("LocalizationService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local Promise = require(script.Dependencies.promise)
local Signal = require(script.Dependencies.signal)

local uniqueIdentifiers = {}

--> Constants


local LogLevels = {
    DEBUG = 1,
    INFO = 2,
    WARNING = 3,
    ERROR = 4,
}


--> Classes



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

    Super Class
]=]


local TraitCore: TraitCore = {
    _entity_tags = {},
    _query_manager = setmetatable({
        QueryPropsFilter = {'identifier'}
    }, {
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



--> Functions




local function log(info: string, level: number, err: string?)
    err = if err then err else ""

    local level_tags = {
        --[LogLevels.DEBUG] = "DEBUG",
        [LogLevels.INFO] = "INFO",
        [LogLevels.WARNING] = "WARNING",
        --[LogLevels.ERROR] = "ERROR",
    }

    local level_tag = level_tags[level] or "UNKNOWN"
    print(`"[{level_tag}]": {info}\n`, err)
end

local function checkSingleProp(instance: Instance, prop: string) 
    return Promise.try(function()
        return instance[prop] ~= nil
    end)
end


local function checkProps(
    instance: Instance,
    info,
    object
)
    local okay = false
    
    for property, value in info do
        if value == nil then continue end
        if typeof(value) == 'table' then continue end
        if table.find(object._query_manager.QueryPropsFilter, property) then continue end
        if not checkSingleProp(instance, property) then return end
        if instance[property] ~= value then return end
    end

    okay = true

    return okay
end


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
        _builded = false,

    }, {__index = TraitCore, __mode = "k"})

    local meta = getmetatable(self)

    --[[function meta:__tostring()
        return `TRAIT_CORE TRAIT: '{traitIdentifier}'`
    end]]

    local function build(instance)
        if self._builded then return end
        self._handlerCallback(self, instance)
        self._builded = true

        if not self._entity_tags[self._identifier] then self._entity_tags[self._identifier] = {} end
    end

    self._builded_signal:Connect(function(instance)
        build(instance)
    end)

    coroutine.wrap(function()

        CollectionService:GetInstanceAddedSignal(self._identifier):Connect(function(instance)
            build(instance)
            if table.find(self._entity_tags[self._identifier], instance) then return end
            CollectionService:AddTag(instance, self._identifier)
            table.insert(self._entity_tags[self._identifier], instance)
        end)

        local withTagInstances = CollectionService:GetTagged(self._identifier)

        for _, taggedInstance in withTagInstances do
            build(taggedInstance)
            if table.find(self._entity_tags[self._identifier], taggedInstance) then continue end
            CollectionService:AddTag(taggedInstance, self._identifier)
            table.insert(self._entity_tags[self._identifier], taggedInstance)
        end

    end)()


    uniqueIdentifiers[traitIdentifier] = true
    self._entity_tags[traitIdentifier] = {}

    return self
end


--> Methods


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

function TraitCore:find(instance: Instance): Instance
    assert(instance and instance:IsA("Instance"), "Invalid instance")
    local result, index = self:isAssociated(instance)
    if not index then return end

    return self._entity_tags[self._identifier][index]
end

--[=[
    @param instance Instance
    @return void
    :::caution
    this method will remove the ```Trait``` instance.
    :::

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
    :::info
      ```Trait:isAssociated()``` is similar to ```Trait:find()```. except that ```Trait:isAssociated()```, returns a tuple. containing a ```boolean``` and a ```number?```, which is the index of the instance in the Trait.
    :::

    returns whether the ```instance``` is part of the trait.
]=]

function TraitCore:isAssociated(instance: Instance): (boolean, number?)
    local index = table.find(self._entity_tags[self._identifier], instance)
    return  index ~= nil, index
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




function TraitCore:query(info: {})
    local identifier = info.identifier
    assert(typeof(info.tags) == "table", "identifier must be a table.")
    
    for _, tag in info.tags do
        assert(self._entity_tags[tag], `query for non-existent tag: "{tag}"`)
    end

    local Self = self

    function self._query_manager:track(listener)
        Self.track:Connect(listener)
    end
   

    function self._query_manager:get()
        local entityArray = {}
        for index, entityTag in Self._entity_tags do
            for _, entity in entityTag do
                if table.find(info.tags, index) and checkProps(entity, info, Self) and not table.find(entityArray, entity) then table.insert(entityArray, entity) end 
            end
        end
        return table.clone(entityArray) or {}
    end

    return table.freeze(self._query_manager)
end

--[=[
    @param instance Instance
    @return Promise
    @within TraitCore

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
        log("failed to fetchAsync", 2, err)
    end)

   return handleBuild
end


--[=[
    @param instance Instance
    @return ()
    @yields
    
    Pauses the current thread, until an instance is linked to Trait.

    ```lua
        local TraitCore = require(PATH_TO_TRAIT_CORE)
        
        local trait = TraitCore.newTrait("example", function(self, instance) end)
        
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


--> Types


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
    isAssociated: (self: Trait, instance: Instance) -> (boolean, number?),
    find: (self: Trait, instance: Instance) -> Instance?,
}   



return table.freeze(TraitCore)
