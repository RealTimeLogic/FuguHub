local M = {}
local db = appreq "db"
local validation = appreq "validation"
local REQUIRED_TEMPLATES = {
   "layout", "page", "post", "archive", "fragment", "not-found"
}
local DEFAULT_CONTRACT = {
   rendersContentTitle = false,
   titleElement = "h1",
   titleHasAnchor = false,
   recommendedBodyHeadingStart = 1,
   canSuppressRenderedTitle = false
}

local function compileLsp(io, path)
   local fp, err = io:open(path)
   if not fp then return nil, err end
   local data = fp:read("*a")
   fp:close()
   local lua
   lua, err = ba.parselsp(data)
   if not lua then return nil, err end
   return load(lua, path)
end

local function normalizeThemeName(name)
   return validation.themeName(name)
end

local function closeIo(io)
   if io and io.close then pcall(function() io:close() end) end
end

local function releaseTheme(value)
   if not value then return end
   if value.assets then value.assets:unlink() end
   closeIo(value.io)
end

local function loadContract(themeInfo)
   local stat = themeInfo.io:stat("theme.json")
   if not stat then
      local fallback = {}
      for key, value in pairs(DEFAULT_CONTRACT) do fallback[key] = value end
      fallback.declared = false
      return fallback
   end
   if stat.isdir or tonumber(stat.size or 0) > 64 * 1024 then
      return nil, "Theme " .. themeInfo.name .. " has an invalid theme.json"
   end
   local file, err = themeInfo.io:open("theme.json", "rb")
   if not file then return nil, "Cannot read theme.json: " .. tostring(err) end
   local text = file:read("*a")
   file:close()
   local ok, metadata = pcall(ba.json.decode, text)
   if not ok or type(metadata) ~= "table" or type(metadata.contentContract) ~= "table" then
      return nil, "Theme " .. themeInfo.name .. " theme.json must define contentContract"
   end
   local value = metadata.contentContract
   if type(value.rendersContentTitle) ~= "boolean" or
      type(value.titleElement) ~= "string" or not value.titleElement:match("^h[1-6]$") or
      type(value.titleHasAnchor) ~= "boolean" or
      type(value.recommendedBodyHeadingStart) ~= "number" or
      value.recommendedBodyHeadingStart < 1 or value.recommendedBodyHeadingStart > 6 or
      type(value.canSuppressRenderedTitle) ~= "boolean" then
      return nil, "Theme " .. themeInfo.name .. " has an invalid contentContract"
   end
   return {
      rendersContentTitle = value.rendersContentTitle,
      titleElement = value.titleElement,
      titleHasAnchor = value.titleHasAnchor,
      recommendedBodyHeadingStart = math.floor(value.recommendedBodyHeadingStart),
      canSuppressRenderedTitle = value.canSuppressRenderedTitle,
      declared = true
   }
end

local function themeSource(app, themeName)
   local themesIo = app.themesIo or app.io
   local themePath = themeName
   local source = "directory"
   if themesIo:stat(themeName .. ".zip") then
      themePath = themeName .. ".zip"
      source = "zip"
   end
   local themeIo, err = ba.mkio(themesIo, themePath)
   if not themeIo then
      return nil, "Cannot open theme " .. themeName .. ": " .. tostring(err)
   end
   return {
      name = themeName,
      path = themePath,
      source = source,
      io = themeIo
   }
end

local function compileTemplates(themeInfo)
   local templates = {}
   for _, name in ipairs(REQUIRED_TEMPLATES) do
      local fn, err = compileLsp(themeInfo.io, "templates/" .. name .. ".lsp")
      if not fn then
         return nil, "Theme " .. themeInfo.name .. " cannot load template " .. name .. ": " .. tostring(err)
      end
      templates[name] = fn
   end
   return templates
end

function M.normalizeName(name)
   return normalizeThemeName(name)
end

function M.open(app, name)
   local themeName, err = normalizeThemeName(name)
   if not themeName then return nil, err end
   return themeSource(app, themeName)
end

function M.list(app)
   local byName = {}
   local themesIo = app.themesIo or app.io
   if themesIo and themesIo.files then
      for name, isdir in themesIo:files("", true) do
         if name ~= "." and name ~= ".." then
            if isdir then
               local safeName = normalizeThemeName(name)
               if safeName then
                  byName[safeName] = byName[safeName] or {
                     name = safeName,
                     source = "directory"
                  }
               end
            else
               local base = name:match("^(.-)%.zip$")
               local safeName = base and normalizeThemeName(base)
               if safeName then byName[safeName] = { name = safeName, source = "zip" } end
            end
         end
      end
   end
   local out = {}
   for _, item in pairs(byName) do
      item.active = app.theme and app.theme.name == item.name or false
      out[#out + 1] = item
   end
   table.sort(out, function(a, b) return a.name < b.name end)
   return out
end

function M.validateIo(themeIo, name, source)
   local themeName, err = normalizeThemeName(name)
   if not themeName then return nil, err end
   if not themeIo then return nil, "Theme IO is required" end
   local info = {
      name = themeName,
      source = source or "staged",
      io = themeIo
   }
   local templates
   templates, err = compileTemplates(info)
   if not templates then return nil, err end
   local contract
   contract, err = loadContract(info)
   if not contract then return nil, err end
   return {
      name = info.name,
      source = info.source,
      valid = true,
      templates = REQUIRED_TEMPLATES,
      contentContract = contract
   }
end

function M.validate(app, name)
   local themeName, err = normalizeThemeName(name)
   if not themeName then return nil, err end
   local info
   info, err = themeSource(app, themeName)
   if not info then return nil, err end
   local result
   result, err = M.validateIo(info.io, info.name, info.source)
   closeIo(info.io)
   return result, err
end

function M.deactivate(app)
   local current = app.theme
   if not current then return nil end
   app.theme = nil
   releaseTheme(current)
   return current
end

function M.activate(app, themeName)
   local err
   themeName, err = normalizeThemeName(themeName or app.defaultTheme or "default")
   if not themeName then error(err, 2) end
   local info
   info, err = themeSource(app, themeName)
   if not info then error(err, 2) end
   local themeIo = info.io

   local templates
   templates, err = compileTemplates(info)
   if not templates then closeIo(themeIo) error(err, 2) end
   local contract
   contract, err = loadContract(info)
   if not contract then closeIo(themeIo) error(err, 2) end
   local assets = ba.create.resrdr("theme", themeIo)
   assets:header{
      ["x-content-type-options"] = "nosniff"
   }

   app.themeActivationGeneration = (app.themeActivationGeneration or 0) + 1
   local nextTheme = {
      name = themeName,
      path = info.path,
      source = info.source,
      io = themeIo,
      templates = templates,
      contract = contract,
      assetVersion = tostring(app.runtimeId or os.time()) .. "-" ..
         tostring(app.themeActivationGeneration)
   }

   local previousTheme = app.theme
   releaseTheme(previousTheme)
   app.theme = nextTheme
   local parentDir = app.publicDir or app.dir
   parentDir:insert(assets, true)
   app.theme.assets = assets

   function app.theme.getTemplate(name)
      local cached = app.theme.templates[name]
      if cached ~= nil then return cached end
      local fn
      fn, err = compileLsp(themeIo, "templates/" .. name .. ".lsp")
      if not fn then
         trace("FuguHub theme template load failed: ", name, " ", err)
         app.theme.templates[name] = false
         return nil
      end
      app.theme.templates[name] = fn
      return fn
   end

   function app.theme.hasTemplate(name)
      return themeIo:stat("templates/" .. tostring(name) .. ".lsp") ~= nil
   end

   return app.theme
end

function M.activateAndPersist(app, themeName)
   local previous = app.theme and app.theme.name
   local activated = M.activate(app, themeName)
   local ok, err = pcall(db.withWrite, app, function(conn)
      local saved, saveErr = conn:execute(
         "INSERT OR REPLACE INTO options(key,value) VALUES('active_theme'," ..
         db.quote(activated.name) .. ")")
      if not saved then error(tostring(saveErr), 2) end
   end)
   if not ok then
      if previous then
         local restored, restoreErr = pcall(M.activate, app, previous)
         if not restored then
            error("Persisting active theme failed: " .. tostring(err) ..
               "; restoring the previous runtime theme also failed: " ..
               tostring(restoreErr), 2)
         end
      else
         M.deactivate(app)
      end
      error(err, 2)
   end
   return activated, previous
end

function M.install(app)
   local row = db.readOne(app, "SELECT value FROM options WHERE key='active_theme' OR key='theme' ORDER BY key LIMIT 1")
   local configured = row and row.value or app.defaultTheme or "default"
   local attempted = {}

   local function tryActivate(name)
      if attempted[name] then return nil end
      attempted[name] = true
      local ok, result = pcall(M.activate, app, name)
      if ok then return result end
      trace("FuguHub theme activation failed: ", name, ": ", tostring(result))
      return nil, result
   end

   local activated, configuredErr = tryActivate(configured)
   if activated then return activated end

   local candidates = { "default" }
   for _, item in ipairs(M.list(app)) do
      candidates[#candidates + 1] = item.name
   end

   local failures = { tostring(configured) .. ": " .. tostring(configuredErr) }
   for _, name in ipairs(candidates) do
      local fallback, fallbackErr = tryActivate(name)
      if fallback then
         db.withWrite(app, function(conn)
            local saved, saveErr = conn:execute(
               "INSERT OR REPLACE INTO options(key,value) VALUES('active_theme'," ..
               db.quote(fallback.name) .. ")")
            if not saved then error(tostring(saveErr), 2) end
         end)
         trace("FuguHub selected fallback theme: ", fallback.name,
            " (configured theme: ", tostring(configured), ")")
         return fallback
      end
      if fallbackErr then
         failures[#failures + 1] = tostring(name) .. ": " .. tostring(fallbackErr)
      end
   end

   error("No usable CMS theme found. " .. table.concat(failures, "; "), 2)
end

return M
