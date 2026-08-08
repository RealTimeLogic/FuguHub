local M = {}

function M.install(app)
   local function normalizeBaseUri(baseUri)
      baseUri = tostring(baseUri or "/")
      if baseUri == "" then baseUri = "/" end
      if baseUri:sub(1, 1) ~= "/" then baseUri = "/" .. baseUri end
      if baseUri:sub(-1) ~= "/" then baseUri = baseUri .. "/" end
      return baseUri
   end

   app.baseUri = normalizeBaseUri(app.appDir and app.appDir:baseuri() or "/")

   function app.url(path)
      path = tostring(path or "")
      if path == "" or path == "/" then
         return app.baseUri
      end
      if path:find("^[%w][%w%+%-%.]*:") or path:sub(1, 2) == "//" or path:sub(1, 1) == "#" then
         return path
      end
      if app.baseUri ~= "/" and path:sub(1, #app.baseUri) == app.baseUri then
         return path
      end
      if path:sub(1, 1) == "/" then
         path = path:sub(2)
      end
      return app.baseUri .. path
   end

   function app.pathFromUri(uri)
      local path = tostring(uri or ""):gsub("[?#].*$", "")
      local base = app.baseUri
      if base == "/" then
         return path == "" and "/" or path
      end
      local baseNoSlash = base:gsub("/$", "")
      if path == baseNoSlash or path == base then
         return "/"
      end
      if path:sub(1, #base) == base then
         local rel = path:sub(#base + 1)
         return "/" .. rel
      end
      return path
   end

   function app.urlEncode(value)
      value = tostring(value or "")
      return (value:gsub("([^%w%-%._~])", function(ch)
         return string.format("%%%02X", string.byte(ch))
      end))
   end

   function app.redirect(_ENV, path, permanent, return2caller)
      _ENV.response:sendredirect(app.url(path), permanent, return2caller)
      return true
   end

   local EventEmitter = require "EventEmitter"
   local cms = app.cms
   if not cms or type(cms.emit) ~= "function" then
      cms = EventEmitter.create(cms or {})
   end
   app.cms = cms

   if not cms._cmsOnWrapped then
      local emitterOn = cms.on
      function cms:on(event, cb)
         assert(type(event) == "string", "event name required")
         assert(type(cb) == "function", "event callback required")
         emitterOn(self, event, cb)
         return function()
            self:removeListener(event, cb)
         end
      end
      function cms:off(event, cb)
         return self:removeListener(event, cb)
      end
      cms._cmsOnWrapped = true
   end

   app.pageTables = app.pageTables or {}
   app.renderCache = app.renderCache or { lsp = {} }
   app.readCache = app.readCache or {}
   local runtimeId = (tostring({}) .. "-" .. tostring(os.time())):gsub("[^%w%._%-]", "")
   local presentationGeneration = 0
   app.runtimeId = runtimeId
   app.presentationRevision = runtimeId .. "-0"

   function app.pageTable(scope, key)
      scope = tostring(scope or "default")
      key = tostring(key or "")
      local scoped = app.pageTables[scope]
      if not scoped then
         scoped = {}
         app.pageTables[scope] = scoped
      end
      local page = scoped[key]
      if not page then
         page = {}
         scoped[key] = page
      end
      return page
   end

   function app.clearPageTables(scope)
      if scope then
         app.pageTables[tostring(scope)] = {}
      else
         app.pageTables = {}
      end
   end

   function app.clearRenderCache()
      app.renderCache = { lsp = {} }
   end

   function app.clearReadCache()
      app.readCache = {}
   end

   function app.invalidateRuntime()
      app.clearPageTables()
      app.clearRenderCache()
      app.clearReadCache()
      presentationGeneration = presentationGeneration + 1
      app.presentationRevision = runtimeId .. "-" .. presentationGeneration
   end
end

return M
