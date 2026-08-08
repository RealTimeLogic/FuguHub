local app = app
local settings = appreq "settings"

local M = {}

local function cleanPath(path)
   return tostring(path or ""):gsub("%?.*$", "")
end

function M.new()
   return function(_ENV)
      local method = _ENV.request:method()
      if method == "OPTIONS" or method == "PROPFIND" then
         return false
      end
      if _ENV.cmsNotFoundForwarding then
         return false
      end
      if _ENV.response:committed() or not settings.isNotFoundEnabled(app) then
         return false
      end

      local notFoundPath = settings.notFoundPath(app)
      local currentPath = app.pathFromUri and app.pathFromUri(cleanPath(_ENV.request:uri())) or cleanPath(_ENV.request:uri())
      if currentPath == notFoundPath then
         return false
      end

      _ENV.cmsNotFoundForwarding = true
      local router = app.appreq "router"
      local ok = router.renderContentPath(_ENV, app, notFoundPath, "not-found", 404)
      _ENV.cmsNotFoundForwarding = nil
      return ok
   end
end

function M.install(app)
   if app.notFoundDir then
      return app.notFoundDir
   end
   if not settings.isNotFoundEnabled(app) then
      return nil
   end
   local dir = ba.create.dir(-127)
   dir:setfunc(M.new())
   local parentDir = app.appDir or app.dir
   parentDir:insert(dir, true)
   app.notFoundDir = dir
   return dir
end

function M.uninstall(app)
   if app.notFoundDir then
      app.notFoundDir:unlink()
      app.notFoundDir = nil
   end
end

function M.configure(app)
   if settings.isNotFoundEnabled(app) then
      return M.install(app)
   end
   M.uninstall(app)
   return nil
end

return M
