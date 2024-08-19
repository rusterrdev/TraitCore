--!native
--!nolint 
--!nocheck

local CollectionService = game:GetService("CollectionService")
local LocalizationService = game:GetService("LocalizationService")
local ProximityPromptService = game:GetService("ProximityPromptService")

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

    Super Class
]=]


local TraitCore: TraitCore = {
    _tagged_entities = {},
    _query_manager = setmetatable({
        QueryPropsFilter = {'identifier'},
        _track_listeners = {},
    }, {
    
    }),
    track = Signal.new(),
} :: TraitCore


--> Functions




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

    }, {__index = TraitCore})

    local function buildInstanceWithTag(instance)
        if self._builded then return end
        task.spawn(self._handlerCallback, self, instance)
        self._builded = true

        if not self._tagged_entities[self._identifier] then self._tagged_entities[self._identifier] = {} end
    end

    self._builded_signal:Connect(function(instance)
        buildInstanceWithTag(instance)
    end)

    task.spawn(function()

        CollectionService:GetInstanceAddedSignal(self._identifier):Connect(function(instance)
            buildInstanceWithTag(instance)
            
            if table.find(self._tagged_entities[self._identifier], instance) then return end
            
            CollectionService:AddTag(instance, self._identifier)
            table.insert(self._tagged_entities[self._identifier], instance)
        end)

        CollectionService:GetInstanceRemovedSignal(self._identifier):Connect(function(instance)
            if not instance then return end

            local index = table.find(self._tagged_entities[self._identifier], instance) 
            
            if not index then return end

            self._tagged_entities[self._identifier][index] = nil
        end)

        local taggedInstances = CollectionService:GetTagged(self._identifier)

        for _, taggedInstance in taggedInstances do
            
            buildInstanceWithTag(taggedInstance)

            if table.find(self._tagged_entities[self._identifier], taggedInstance) then continue end
            
            CollectionService:AddTag(taggedInstance, self._identifier)
            table.insert(self._tagged_entities[self._identifier], taggedInstance)
        end

    end)

    uniqueIdentifiers[traitIdentifier] = true
    self._tagged_entities[traitIdentifier] = {}

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
    self._tagged_entities[trait._identifier] = nil
end

function TraitCore:find(instance: Instance): Instance
    assert(instance and instance:IsA("Instance"), "Invalid instance")
    local result, index = self:isAssociated(instance)
    if not index then return end

    return self._tagged_entities[self._identifier][index]
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
    local instanceIndexTrait = table.find(self._tagged_entities[self._identifier], instance)
    if not instanceIndexTrait then return end
    return table.remove(self._tagged_entities[self._identifier], instanceIndexTrait)
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
    local index = table.find(self._tagged_entities[self._identifier], instance)
    return  index ~= nil, index
end

--[=[
    @param info (info: {[string?] : any?} & {tags: {string}})
    @return QueryManager

    ```lua
        local TraitCore = require(PATH_TO_TRAIT_CORE)
        
        local trait = TraitCore.newTrait("example", function(self, instance)
            print(`{part.Name} has been added to the example trait!`)
            part.Size = Vector3.new(3,3,3)
        end)
        
        local requirements = {"example", Color = Color3.new(1,0,0)}

        local QueryManager = TraitCore:query(requirements)

        task.spawn(function()
            trait:await(part)
           print(QueryManager:get()) --> returns instances with the specified requirements

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
        assert(self._tagged_entities[tag], `query for non-existent tag: "{tag}"`)
    end

    local Self = self

    function self._query_manager:track(listener)
        Self.track:Connect(function(_, instance)
            if not checkProps(instance, info, Self) then return end
            task.spawn(listener, Self, instance)
            --makeConn()
            print(_, instance, "   track")
        end)  
    end

    function self._query_manager:get()
        local entityArray = {}
        for index, entityTag in Self._tagged_entities do
            for _, entity in entityTag do
                if table.find(info.tags, index) and checkProps(entity, info, Self) and not entityArray[entity] then entityArray[entity] = entity end 
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

    local wrapBuildPromise = Promise.try(function()
        CollectionService:AddTag(instance, self._identifier)
        table.insert(self._tagged_entities[self._identifier], instance)
    end)

    wrapBuildPromise:andThen(function()
        self._builded_signal:Fire(instance)
        self.track:Fire(self, instance)

    end):catch(function(err)
    end)

   return wrapBuildPromise
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
        local entityIndex = table.find(self._tagged_entities[self._identifier], instance)
        if entityIndex then return self._tagged_entities[self._identifier][entityIndex] end
    end
end


--> Types


type Promise = typeof(Promise.new())
type Signal = typeof(Signal.new())


export type QueryManager = {
    get: () -> {Instance?},
    track: (self: QueryManager, listener: (selfObject: Trait, entityInstance: Instance) -> ()) -> (),
}

export type TraitCore = {
    newTrait: (identifier: string, listener: (selfObject: Trait, entityInstance: Instance) -> ()) -> (),
    query: <prop>(self: {}, info: {[prop] : any} & {tags: {string}}) -> QueryManager,
}

export type Trait = {
    fetchAsync: (self: Trait, instance: Instance) -> Promise,
    await: (self: Trait, instance: Instance) -> Instance?,
    isAssociated: (self: Trait, instance: Instance) -> (boolean, number?),
    find: (self: Trait, instance: Instance) -> Instance?,
}   


return table.freeze(TraitCore) :: TraitCore
