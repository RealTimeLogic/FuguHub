local M = {}

local function requestApp(app)
   return app.assetsApp or app
end

local function requestIo(app, activeApp)
   return activeApp.io or app.io
end

local function callWithRequestApp(_ENV, activeApp, fn)
   local oldApp = _ENV.app
   _ENV.app = activeApp
   local ok, result = pcall(fn)
   if oldApp == nil then
      _ENV.app = nil
   else
      _ENV.app = oldApp
   end
   return ok, result
end

function M.renderBody(_ENV, app, content, pageState)
   local response = _ENV.response
   if content.render_mode == "lsp" then
      local body = content.body_html or ""
      local cache = app.renderCache and app.renderCache.lsp
      local key = tostring(content.id or content.path or "")
      local cached = cache and cache[key]
      local lua, err
      if cached and cached.body == body then
         lua = cached.lua
      else
         lua, err = ba.parselsp(body)
         if lua and cache then cache[key] = { body = body, lua = lua } end
      end
      if not lua then
         error("Compiling LSP failed: " .. tostring(err), 2)
      end
      local fn
      fn, err = load(lua, content.path or "cms-content", "t", _ENV)
      if not fn then
         error("Loading LSP failed: " .. tostring(err), 2)
      end
      local activeApp = requestApp(app)
      local ok
      ok, err = callWithRequestApp(_ENV, activeApp, function()
         if activeApp.configureLspEnv then
            activeApp.configureLspEnv(_ENV, content)
         end
         return fn(_ENV, content.path or _ENV.request:uri(), requestIo(app, activeApp), pageState or {}, activeApp)
      end)
      if not ok then
         error("Executing LSP failed: " .. tostring(err), 2)
      end
      return true
   end

   response:write(content.body_html or "")
   return true
end

function M.renderTemplate(_ENV, app, templateName, model)
   local template = app.theme.getTemplate(templateName)
   if not template then
      return nil, "Theme template missing: " .. tostring(templateName)
   end
   local activeApp = requestApp(app)
   local ok, result = callWithRequestApp(_ENV, activeApp, function()
      return template(_ENV, _ENV.request:uri(), requestIo(app, activeApp), model.pageState or {}, activeApp, model)
   end)
   if not ok then
      return nil, "Theme template failed: " .. tostring(result)
   end
   return true, result
end

return M
