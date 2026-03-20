local DataVault = {}

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local requestEvent = ReplicatedStorage:FindFirstChild("DataVaultRequest")
if not requestEvent then
	requestEvent = Instance.new("RemoteEvent")
	requestEvent.Name = "DataVaultRequest"
	requestEvent.Parent = ReplicatedStorage
end

local updateEvent = ReplicatedStorage:FindFirstChild("DataVaultUpdate")
if not updateEvent then
	updateEvent = Instance.new("RemoteEvent")
	updateEvent.Name = "DataVaultUpdate"
	updateEvent.Parent = ReplicatedStorage
end

local errorEvent = ReplicatedStorage:FindFirstChild("DataVaultError")
if not errorEvent then
	errorEvent = Instance.new("RemoteEvent")
	errorEvent.Name = "DataVaultError"
	errorEvent.Parent = ReplicatedStorage
end

local profiles = setmetatable({}, { __mode = "k" })
local globals = {}
local dirtyObjects = setmetatable({}, { __mode = "v" })
local saveQueue = {}
local saveThreadRunning = false
local validators = {}
local requestTimestamps = {}
local dataStoreCache = {}  -- кэш успешных DataStore

-- Базовая функция получения DataStore с возможностью fallback
local function getDataStoreWithFallback(baseName, scope, maxAttempts)
	maxAttempts = maxAttempts or 3
	local cacheKey = baseName .. "_" .. scope
	if dataStoreCache[cacheKey] then
		return dataStoreCache[cacheKey]
	end

	local namesToTry = { baseName }
	-- добавляем варианты на случай удаления
	for i = 1, maxAttempts - 1 do
		table.insert(namesToTry, baseName .. "_" .. tostring(os.time() + i))
	end

	for _, name in ipairs(namesToTry) do
		local ds = DataStoreService:GetDataStore(name, scope)
		-- пробуем выполнить простую операцию, чтобы проверить доступ
		local success, err = pcall(function()
			ds:GetAsync("__test__")
		end)
		if success or not string.find(err or "", "deleted") then
			dataStoreCache[cacheKey] = ds
			return ds
		end
		warn(`DataStore {name} is deleted, trying next...`)
	end
	error("No available DataStore found for " .. baseName)
end

-- Обёртка для получения DataStore с фиксированным именем на основе GameId
local function getDataStore(scope)
	local baseName = "DataVault_" .. game.GameId  -- уникальное для каждой игры
	return getDataStoreWithFallback(baseName, scope)
end

local function deepClone(t)
	if type(t) ~= "table" then return t end
	local copy = {}
	for k, v in pairs(t) do
		copy[k] = deepClone(v)
	end
	return copy
end

local function loadFromDataStore(dataStore, key, default)
	local attempts = 0
	while attempts < 3 do
		local success, data = pcall(function()
			return dataStore:GetAsync(key)
		end)
		if success then
			if data then
				return data
			else
				-- данных нет, создаём новую запись
				local newData = deepClone(default)
				pcall(function()
					dataStore:SetAsync(key, newData)
				end)
				return newData
			end
		else
			attempts = attempts + 1
			if attempts < 3 then
				task.wait(1)
			else
				warn("Failed to load data for key:", key, data)
				return deepClone(default)
			end
		end
	end
end

local function saveToDataStore(dataStore, key, data)
	local attempts = 0
	while attempts < 3 do
		local success, err = pcall(function()
			dataStore:SetAsync(key, data)
		end)
		if success then
			return true
		else
			attempts = attempts + 1
			if attempts < 3 then
				task.wait(1)
			else
				warn("Failed to save data for key:", key, err)
				return false
			end
		end
	end
end

local function splitPath(path)
	if type(path) ~= "string" then return {} end
	local parts = {}
	for part in path:gmatch("[^.]+") do
		local num = tonumber(part)
		table.insert(parts, num or part)
	end
	return parts
end

local function processSaveQueue()
	if saveThreadRunning then return end
	saveThreadRunning = true
	task.spawn(function()
		while next(saveQueue) do
			local obj = next(saveQueue)
			saveQueue[obj] = nil
			local success = saveToDataStore(obj.dataStore, obj.key, obj.data)
			if success then
				obj.dirty = false
				dirtyObjects[obj] = nil
			else
				warn("Failed to save data for key:", obj.key)
				saveQueue[obj] = true
			end
			task.wait()
		end
		saveThreadRunning = false
	end)
end

local function checkRateLimit(player, action)
	local key = player.UserId .. "_" .. action
	local now = os.clock()
	local last = requestTimestamps[key] or 0
	if now - last < 0.1 then
		return false
	end
	requestTimestamps[key] = now
	return true
end

local function validateValue(player, path, value, profile)
	local validator = validators[path]
	if validator then
		local ok, newValue = pcall(validator, player, profile:get(path), value)
		if not ok then return false, "Validation error" end
		if newValue == nil then return false, "Value rejected by validator" end
		return true, newValue
	end
	return true, value
end

local DataObject = {}
DataObject.__index = DataObject

function DataObject.new(dataStore, key, default, autoSave)
	return setmetatable({
		dataStore = dataStore,
		key = key,
		data = loadFromDataStore(dataStore, key, default),
		autoSave = autoSave,
		dirty = false,
	}, DataObject)
end

function DataObject:get(path)
	local parts = splitPath(path)
	local current = self.data
	for _, part in ipairs(parts) do
		if current == nil then return nil end
		current = current[part]
	end
	return current
end

function DataObject:set(path, value)
	local parts = splitPath(path)
	local current = self.data
	for i = 1, #parts - 1 do
		local part = parts[i]
		if current[part] == nil then
			current[part] = {}
		end
		current = current[part]
	end
	current[parts[#parts]] = value

	if self.autoSave then
		saveQueue[self] = true
		processSaveQueue()
	else
		self.dirty = true
		dirtyObjects[self] = true
	end
end

function DataObject:update(changes)
	for path, value in pairs(changes) do
		self:set(path, value)
	end
end

function DataObject:increment(path, amount)
	if type(amount) ~= "number" then return end
	local current = self:get(path)
	if current == nil then current = 0 end
	if type(current) == "number" then
		self:set(path, current + amount)
	end
end

function DataObject:addToArray(path, value, unique)
	local arr = self:get(path)
	if arr == nil then
		arr = {}
		self:set(path, arr)
	end
	if type(arr) == "table" then
		if unique then
			for _, v in ipairs(arr) do
				if v == value then return end
			end
		end
		table.insert(arr, value)
		self:set(path, arr)
	end
end

function DataObject:addToSet(path, value)
	self:addToArray(path, value, true)
end

function DataObject:removeFromArray(path, predicate)
	local arr = self:get(path)
	if type(arr) == "table" then
		local newArr = {}
		for _, item in ipairs(arr) do
			if not predicate(item) then
				table.insert(newArr, item)
			end
		end
		self:set(path, newArr)
	end
end

function DataObject:save()
	saveQueue[self] = true
	processSaveQueue()
end

function DataObject:setAutoSave(enabled)
	self.autoSave = enabled
end

local PlayerDataObject = setmetatable({}, { __index = DataObject })
PlayerDataObject.__index = PlayerDataObject

function PlayerDataObject.new(player, dataStore, key, default, autoSave)
	local self = DataObject.new(dataStore, key, default, autoSave)
	setmetatable(self, PlayerDataObject)
	self.player = player
	updateEvent:FireClient(player, "full", self.data)
	return self
end

function PlayerDataObject:set(path, value)
	DataObject.set(self, path, value)
	updateEvent:FireClient(self.player, "update", path, value)
end

local GlobalObject = setmetatable({}, { __index = DataObject })
GlobalObject.__index = GlobalObject

function GlobalObject.new(name, dataStore, default, autoSave)
	local self = DataObject.new(dataStore, "Global_" .. name, default, autoSave)
	setmetatable(self, GlobalObject)
	self.name = name
	return self
end

if RunService:IsServer() then
	function DataVault.getProfile(player, defaultData, autoSave)
		if autoSave == nil then autoSave = true end
		local profile = profiles[player]
		if profile then return profile end

		local dataStore = getDataStore("Profile")
		local key = "Profile_" .. player.UserId
		if type(defaultData) == "table" and defaultData.default then
			defaultData = defaultData.default
		end
		profile = PlayerDataObject.new(player, dataStore, key, defaultData, autoSave)
		profiles[player] = profile

		local removeConn
		removeConn = Players.PlayerRemoving:Connect(function(plr)
			if plr == player then
				if profile.dirty then
					profile:save()
				end
				profiles[plr] = nil
				removeConn:Disconnect()
			end
		end)

		return profile
	end

	function DataVault.getGlobal(name, defaultData, autoSave)
		if autoSave == nil then autoSave = true end
		local global = globals[name]
		if global then return global end

		local dataStore = getDataStore("Global")
		global = GlobalObject.new(name, dataStore, defaultData, autoSave)
		globals[name] = global
		return global
	end

	function DataVault.requestSave()
		for obj in pairs(dirtyObjects) do
			obj:save()
		end
	end

	function DataVault.registerValidator(path, validator)
		validators[path] = validator
	end

	requestEvent.OnServerEvent:Connect(function(player, action, path, value)
		local profile = profiles[player]
		if not profile then
			errorEvent:FireClient(player, "Profile not loaded")
			return
		end

		if not checkRateLimit(player, action) then
			errorEvent:FireClient(player, "Too many requests")
			return
		end

		local success, err = pcall(function()
			if action == "set" then
				local ok, validatedValue = validateValue(player, path, value, profile)
				if not ok then
					error(validatedValue or "Validation failed")
				end
				profile:set(path, validatedValue)
			elseif action == "increment" then
				if type(value) ~= "number" then
					error("Increment amount must be a number")
				end
				local current = profile:get(path)
				if current ~= nil and type(current) ~= "number" then
					error("Cannot increment non-number")
				end
				local newValue = (current or 0) + value
				local ok, validatedValue = validateValue(player, path, newValue, profile)
				if not ok then
					error(validatedValue or "Validation failed")
				end
				profile:set(path, validatedValue)
			elseif action == "addToArray" then
				profile:addToArray(path, value)
			elseif action == "addToSet" then
				profile:addToSet(path, value)
			elseif action == "removeFromArray" then
				profile:removeFromArray(path, function(item) return item == value end)
			else
				error("Unknown action: " .. tostring(action))
			end
		end)

		if not success then
			errorEvent:FireClient(player, "Error: " .. err)
		end
	end)

	game:BindToClose(function()
		for obj in pairs(dirtyObjects) do
			obj:save()
		end
		wait(2)
	end)
end

if RunService:IsClient() then
	local dataCache = nil
	local subscribers = {}

	function DataVault.getData()
		return dataCache
	end

	function DataVault.getValue(path)
		if not dataCache then return nil end
		local parts = splitPath(path)
		local current = dataCache
		for _, part in ipairs(parts) do
			if current == nil then return nil end
			current = current[part]
		end
		return current
	end

	function DataVault.subscribe(path, callback)
		if not subscribers[path] then
			subscribers[path] = {}
		end
		table.insert(subscribers[path], callback)
		if dataCache then
			local value = DataVault.getValue(path)
			callback(value, nil)
		end
	end

	updateEvent.OnClientEvent:Connect(function(updateType, ...)
		if updateType == "full" then
			dataCache = ...
			for path, callbacks in pairs(subscribers) do
				local newValue = DataVault.getValue(path)
				for _, cb in ipairs(callbacks) do
					cb(newValue, nil)
				end
			end
		elseif updateType == "update" then
			local path, newValue = ...
			local oldValue = DataVault.getValue(path)
			local parts = splitPath(path)
			local current = dataCache
			for i = 1, #parts - 1 do
				local part = parts[i]
				if not current[part] then
					current[part] = {}
				end
				current = current[part]
			end
			current[parts[#parts]] = newValue
			if subscribers[path] then
				for _, cb in ipairs(subscribers[path]) do
					cb(newValue, oldValue)
				end
			end
		end
	end)

	errorEvent.OnClientEvent:Connect(function(message)
		warn("DataVault error:", message)
	end)

	function DataVault.requestSet(path, value)
		requestEvent:FireServer("set", path, value)
	end

	function DataVault.requestIncrement(path, amount)
		requestEvent:FireServer("increment", path, amount)
	end

	function DataVault.requestAddToArray(path, value)
		requestEvent:FireServer("addToArray", path, value)
	end

	function DataVault.requestAddToSet(path, value)
		requestEvent:FireServer("addToSet", path, value)
	end

	function DataVault.requestRemoveFromArray(path, value)
		requestEvent:FireServer("removeFromArray", path, value)
	end
end

return DataVault
