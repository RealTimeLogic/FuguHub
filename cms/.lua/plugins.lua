local admin = appreq "admin"
local pathio = require "pathio"
local M = {}
local NIL = {}
local RESERVED_MOUNTS = {
   admin = true,
   assets = true,
   mcp = true,
   plugins = true,
   smq = true,
   theme = true
}

local function errh(message)
   return debug and debug.traceback and debug.traceback(message, 2) or message
end

local function fail(record, message)
   record.state = "failed"
   record.error = tostring(message or "Plugin failed")
   trace("FuguHub plugin failed:", record.source, record.error)
   return record
end

local function modulePath(name)
   name = tostring(name or "")
   if name == "" or name:sub(1, 1) == "/" or
      name:find("\\", 1, true) or name:find(":", 1, true) then
      return nil, "Invalid plugin module name"
   end
   name = name:gsub("%.", "/")
   for segment in name:gmatch("[^/]+") do
      if segment == "" or segment == "." or segment == ".." or
         not segment:match("^[%w_%-]+$") then
         return nil, "Invalid plugin module name"
      end
   end
   if name:find("//", 1, true) or name:sub(-1) == "/" then
      return nil, "Invalid plugin module name"
   end
   return ".lua/" .. name .. ".lua"
end

local function createEnvironment(cmsApp, pluginIo)
   local env = {
      io = pluginIo,
      homeIo = cmsApp.homeIo
   }
   env.app = env
   setmetatable(env, { __index = cmsApp })

   local loaded = {}
   local values = {}
   local parentRequire = cmsApp.require or require

   local function pluginreq(name)
      local path, pathErr = modulePath(name)
      if not path then error(pathErr, 3) end
      if loaded[path] then
         if values[path] == NIL then return nil end
         return values[path]
      end
      if not pluginIo:stat(path) then
         error(tostring(name) .. " not found", 3)
      end

      local fn, loadErr = pluginIo:loadfile(path, env)
      if not fn then
         error(tostring(name) .. " failed: " .. tostring(loadErr or "?"), 3)
      end
      local ok, result = xpcall(fn, errh)
      if not ok then
         error(tostring(name) .. " failed: " .. tostring(result), 3)
      end
      loaded[path] = true
      values[path] = result == nil and NIL or result
      return result
   end

   env.pluginreq = pluginreq
   env.require = function(name)
      local path, pathErr = modulePath(name)
      if not path then error(pathErr, 2) end
      if pluginIo:stat(path) then return pluginreq(name) end
      return parentRequire(name)
   end
   return env
end

local function validPluginId(value)
   value = tostring(value or "")
   return value:match("^[a-z0-9][a-z0-9-]*$") and value or nil
end

local function packageId(name, isDirectory)
   if isDirectory then return name end
   if name:lower():sub(-4) ~= ".zip" then return nil end
   return name:sub(1, -5)
end

local function ignoredPackage(name)
   local lower = name:lower()
   return name:sub(1, 1) == "." or lower:match("%.tmp$") or
      lower:match("%.part$") or lower:match("%.partial$") or
      lower:match("~$")
end

local function loadDescriptor(cmsApp, source, expectedId, pluginIo)
   local record = {
      source = source,
      expectedId = expectedId,
      io = pluginIo,
      state = "discovered"
   }
   if not pluginIo:stat(".preload") then
      return fail(record, "Package root is missing .preload")
   end

   local env = createEnvironment(cmsApp, pluginIo)
   local fn, loadErr = pluginIo:loadfile(".preload", env)
   if not fn then return fail(record, loadErr) end
   local ok, descriptor = xpcall(fn, errh)
   if not ok then return fail(record, descriptor) end
   if type(descriptor) ~= "table" then
      return fail(record, ".preload must return a plugin descriptor table")
   end

   local id = validPluginId(descriptor.id)
   if not id then return fail(record, "Invalid plugin ID") end
   if id ~= expectedId then
      return fail(record, "Plugin ID must match package name " .. expectedId)
   end

   local requires = descriptor.requires or {}
   if type(requires) ~= "table" then
      return fail(record, "requires must be an array of plugin IDs")
   end
   local dependencySet = {}
   local dependencyList = {}
   for _, dependency in ipairs(requires) do
      dependency = validPluginId(dependency)
      if not dependency then
         return fail(record, "Invalid dependency ID")
      end
      if dependency == id then
         return fail(record, "Plugin cannot depend on itself")
      end
      if dependencySet[dependency] then
         return fail(record, "Duplicate dependency: " .. dependency)
      end
      dependencySet[dependency] = true
      dependencyList[#dependencyList + 1] = dependency
   end
   for key in pairs(requires) do
      if type(key) ~= "number" or key < 1 or key > #dependencyList or key % 1 ~= 0 then
         return fail(record, "requires must be an array of plugin IDs")
      end
   end

   if descriptor.start ~= nil and type(descriptor.start) ~= "function" then
      return fail(record, "start must be a function")
   end
   if descriptor.stop ~= nil and type(descriptor.stop) ~= "function" then
      return fail(record, "stop must be a function")
   end

   record.id = id
   record.env = env
   record.descriptor = descriptor
   record.requires = dependencyList
   record.dependencySet = dependencySet
   record.state = "loaded"
   return record
end

local function discover(cmsApp)
   local found = {}
   local disabled = cmsApp.disabledPlugins or {}
   local function scan(rootIo, sourcePrefix)
      if not rootIo:stat("plugins") then return end
      local iterator = rootIo:files("plugins", true)
      if not iterator then return end
      for name, isDirectory in iterator do
         local id = not ignoredPackage(name) and packageId(name, isDirectory)
         if id and validPluginId(id) then
            if disabled[id] then
               trace("FuguHub plugin intentionally disabled:", id)
            else
               found[#found + 1] = {
                  name = name,
                  id = id,
                  rootIo = rootIo,
                  path = "plugins/" .. name,
                  isDirectory = isDirectory,
                  source = sourcePrefix .. "plugins/" .. name
               }
            end
         end
      end
   end
   local engineIo = cmsApp.engineIo or cmsApp.io
   scan(engineIo, "cms:")
   if cmsApp.homeIo ~= engineIo then scan(cmsApp.homeIo, "") end
   table.sort(found, function(a, b) return a.source < b.source end)

   local records = {}
   for _, item in ipairs(found) do
      local pluginIo, openErr
      if item.isDirectory then
         pluginIo = pathio(item.rootIo, item.path)
      else
         pluginIo, openErr = ba.mkio(item.rootIo, item.path)
      end
      if not pluginIo then
         records[#records + 1] = fail({
            source = item.source,
            expectedId = item.id
         }, "Cannot open package: " .. tostring(openErr or "?"))
      else
         records[#records + 1] =
            loadDescriptor(cmsApp, item.source, item.id, pluginIo)
      end
   end
   return records
end

local function resolve(records)
   local groups = {}
   for _, record in ipairs(records) do
      if record.id then
         local group = groups[record.id] or {}
         groups[record.id] = group
         group[#group + 1] = record
      end
   end

   local byId = {}
   for id, group in pairs(groups) do
      if #group > 1 then
         for _, record in ipairs(group) do
            fail(record, "Duplicate plugin ID: " .. id)
         end
      elseif group[1].state ~= "failed" then
         byId[id] = group[1]
      end
   end

   local changed = true
   while changed do
      changed = false
      for _, record in pairs(byId) do
         if record.state == "loaded" then
            for _, dependency in ipairs(record.requires) do
               local required = byId[dependency]
               if not required or required.state == "failed" then
                  fail(record, "Missing or failed dependency: " .. dependency)
                  changed = true
                  break
               end
            end
         end
      end
   end

   local indegree = {}
   local dependants = {}
   for id, record in pairs(byId) do
      if record.state == "loaded" then
         indegree[id] = #record.requires
         for _, dependency in ipairs(record.requires) do
            local list = dependants[dependency] or {}
            dependants[dependency] = list
            list[#list + 1] = id
         end
      end
   end

   local ready = {}
   for id, count in pairs(indegree) do
      if count == 0 then ready[#ready + 1] = id end
   end
   table.sort(ready)

   local ordered = {}
   while #ready > 0 do
      local id = table.remove(ready, 1)
      ordered[#ordered + 1] = byId[id]
      local children = dependants[id] or {}
      table.sort(children)
      for _, child in ipairs(children) do
         indegree[child] = indegree[child] - 1
         if indegree[child] == 0 then
            ready[#ready + 1] = child
            table.sort(ready)
         end
      end
      indegree[id] = nil
   end

   for id in pairs(indegree) do
      fail(byId[id], "Dependency cycle")
   end
   return ordered, byId
end

local function ensureDataIo(cmsApp, id)
   if not cmsApp.dataIo:stat("plugins") then
      local ok, err = cmsApp.dataIo:mkdir("plugins")
      if not ok then return nil, err end
   end
   local path = "plugins/" .. id
   if not cmsApp.dataIo:stat(path) then
      local ok, err = cmsApp.dataIo:mkdir(path)
      if not ok then return nil, err end
   end
   return ba.mkio(cmsApp.dataIo, path)
end

local function cleanup(record)
   local ctx = record.ctx
   if not ctx then return end
   for index = #ctx._owned, 1, -1 do
      local ok, err = pcall(ctx._owned[index])
      if not ok then
         trace("FuguHub plugin cleanup failed:", record.id, tostring(err))
      end
   end
   ctx._owned = {}
end

local function createContext(manager, record, dataIo)
   local cmsApp = manager.app
   local ctx = {
      id = record.id,
      io = record.io,
      dataIo = dataIo,
      db = cmsApp.db,
      identity = cmsApp.identity,
      app = cmsApp,
      _owned = {}
   }

   function ctx:trace(...)
      trace("FuguHub plugin " .. record.id .. ":", ...)
   end

   function ctx:own(fn)
      assert(type(fn) == "function", "Plugin cleanup must be a function")
      local active = true
      local function remove()
         if not active then return end
         active = false
         return fn()
      end
      self._owned[#self._owned + 1] = remove
      return remove
   end

   function ctx:requirePlugin(id)
      id = assert(validPluginId(id), "Invalid dependency ID")
      if not record.dependencySet[id] then
         error("Plugin dependency was not declared: " .. id, 2)
      end
      local dependency = manager.byId[id]
      if not dependency or dependency.state ~= "running" then
         error("Plugin dependency is not running: " .. id, 2)
      end
      return dependency.service
   end

   function ctx:mount(name, dir)
      name = assert(validPluginId(name), "Invalid plugin mount name")
      local key = name:lower()
      if RESERVED_MOUNTS[key] or manager.mounts[key] then
         error("Plugin mount name is reserved or already used: " .. name, 2)
      end
      assert(dir, "Plugin VFS directory is required")
      manager.mounts[key] = record.id
      local ok, insertErr = pcall(function()
         cmsApp.publicDir:insert(dir, true)
      end)
      if not ok then
         manager.mounts[key] = nil
         error("Plugin VFS mount failed: " .. tostring(insertErr), 2)
      end
      local unmount = self:own(function()
         dir:unlink()
         if manager.mounts[key] == record.id then manager.mounts[key] = nil end
      end)
      return dir, unmount
   end

   local adminApi = {}
   ctx.admin = adminApi

   local function wrapAdmin(handler, active)
      return function(env)
         env.cmsPluginAdminActive = active
         return handler(env, record.env, ctx)
      end
   end

   function adminApi:addRoute(path, handler)
      assert(type(handler) == "function", "Plugin admin handler must be a function")
      local remove, addErr =
         manager.admin.addRoute(record.id, path, wrapAdmin(handler))
      if not remove then error(addErr, 2) end
      ctx:own(remove)
      return remove
   end

   function adminApi:addPage(spec)
      assert(type(spec) == "table", "Plugin admin page must be a table")
      local handler = spec.handler
      assert(type(handler) == "function", "Plugin admin handler must be a function")
      local active
      local copy = {}
      for key, value in pairs(spec) do copy[key] = value end
      copy.handler = function(env)
         env.cmsPluginAdminActive = active
         return handler(env, record.env, ctx)
      end
      local remove, activeOrErr = manager.admin.addPage(record.id, copy)
      if not remove then error(activeOrErr, 2) end
      active = activeOrErr
      ctx:own(remove)
      return remove
   end

   function adminApi:layout(env, title, body)
      assert(type(body) == "function", "Plugin admin body must be a function")
      return manager.admin.layout(
         env, title, env.cmsPluginAdminActive, body)
   end

   function adminApi:postData(env)
      return manager.admin.postData(env)
   end

   function adminApi:csrfField(env)
      return manager.admin.csrfField(env)
   end

   adminApi.html = manager.admin.html

   return ctx
end

local function start(manager, ordered)
   for _, record in ipairs(ordered) do
      local blocked
      for _, dependency in ipairs(record.requires) do
         if manager.byId[dependency].state ~= "running" then
            blocked = dependency
            break
         end
      end
      if blocked then
         fail(record, "Dependency did not start: " .. blocked)
      else
         local dataIo, dataErr = ensureDataIo(manager.app, record.id)
         if not dataIo then
            fail(record, "Cannot create plugin data directory: " ..
               tostring(dataErr or "?"))
         else
            local ctx = createContext(manager, record, dataIo)
            record.ctx = ctx
            record.env.dataIo = dataIo
            record.env.plugin = ctx
            local ok, service = true, true
            if record.descriptor.start then
               ok, service = xpcall(function()
                  return record.descriptor.start(ctx)
               end, errh)
            end
            if ok then
               record.service = service == nil and true or service
               record.state = "running"
               manager.started[#manager.started + 1] = record
               trace("FuguHub plugin started:", record.id)
            else
               fail(record, service)
               cleanup(record)
            end
         end
      end
   end
end

function M.loadInstalled(cmsApp)
   local records = discover(cmsApp)
   local ordered, byId = resolve(records)
   local manager = {
      app = cmsApp,
      records = records,
      byId = byId,
      started = {},
      mounts = {},
      admin = admin.installPluginApi(cmsApp)
   }
   start(manager, ordered)
   cmsApp.plugins = byId

   function manager:stopAll()
      for index = #self.started, 1, -1 do
         local record = self.started[index]
         if record.state == "running" and record.descriptor.stop then
            local ok, stopErr = xpcall(function()
               return record.descriptor.stop(record.ctx)
            end, errh)
            if not ok then
               trace("FuguHub plugin stop failed:", record.id, tostring(stopErr))
            end
         end
         cleanup(record)
         record.state = "stopped"
      end
      self.started = {}
   end

   return manager
end

return M
