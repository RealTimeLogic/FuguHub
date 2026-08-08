local db = appreq "db"

local M = {}

local function optionValue(app, key)
   local row = db.readOne(app, "SELECT value FROM options WHERE key=" .. db.quote(key))
   return row and row.value or nil
end

local function normalizePath(path, default)
   path = tostring(path or ""):gsub("^%s+", ""):gsub("%s+$", "")
   if path == "" then path = default or "/" end
   path = path:gsub("[?#].*$", "")
   if path:sub(1, 1) ~= "/" then path = "/" .. path end
   if path:sub(-1) ~= "/" then path = path .. "/" end
   return path
end

local function postPublicPath(basePath, storedPath)
   return normalizePath(basePath .. tostring(storedPath or ""):gsub("^/+", ""))
end

local function rebasePostReferences(conn, oldBasePath, newBasePath)
   if oldBasePath == newBasePath then return end
   for _, row in ipairs(db.rows(conn,
      "SELECT id,path FROM content WHERE type='post' ORDER BY id")) do
      local oldPath = postPublicPath(oldBasePath, row.path)
      local newPath = postPublicPath(newBasePath, row.path)
      local ok, err = conn:execute("UPDATE menu_items SET url=" .. db.quote(newPath) ..
         " WHERE content_id=" .. tonumber(row.id) .. " OR url=" .. db.quote(oldPath))
      if not ok then error("Updating post menu URLs failed: " .. tostring(err), 2) end
      ok, err = conn:execute("UPDATE redirects SET to_path=" .. db.quote(newPath) ..
         " WHERE to_path=" .. db.quote(oldPath))
      if not ok then error("Updating post redirect targets failed: " .. tostring(err), 2) end
   end
end

function M.normalizePath(path, default)
   return normalizePath(path, default)
end

function M.load(app)
   app.settings = app.settings or {}
   app.settings.htmxEnabled = optionValue(app, "htmx_enabled") == "1"
   app.settings.smqEnabled = app.settings.htmxEnabled and
      optionValue(app, "smq_enabled") == "1"
   app.settings.blogBasePath = normalizePath(optionValue(app, "blog_base_path"), "/blog/")
   app.settings.notFoundEnabled = optionValue(app, "not_found_enabled") == "1"
   app.settings.notFoundPath = normalizePath(optionValue(app, "not_found_path"), "/404/")
   return app.settings
end

function M.isHtmxEnabled(app)
   if not app.settings or app.settings.htmxEnabled == nil then
      M.load(app)
   end
   return app.settings.htmxEnabled == true
end

function M.isSmqEnabled(app)
   if not app.settings or app.settings.smqEnabled == nil then
      M.load(app)
   end
   return app.settings.htmxEnabled == true and app.settings.smqEnabled == true
end

function M.blogBasePath(app)
   if not app.settings or not app.settings.blogBasePath then
      M.load(app)
   end
   return app.settings.blogBasePath or "/blog/"
end

function M.isNotFoundEnabled(app)
   if not app.settings or app.settings.notFoundEnabled == nil then
      M.load(app)
   end
   return app.settings.notFoundEnabled == true
end

function M.notFoundPath(app)
   if not app.settings or not app.settings.notFoundPath then
      M.load(app)
   end
   return app.settings.notFoundPath or "/404/"
end

function M.setHtmxEnabled(app, enabled)
   return M.update(app, { htmxEnabled = enabled }).htmxEnabled
end

function M.setSmqEnabled(app, enabled)
   return M.update(app, { smqEnabled = enabled }).smqEnabled
end

function M.setBlogBasePath(app, path)
   return M.update(app, { blogBasePath = path }).blogBasePath
end

function M.setNotFound(app, enabled, path)
   return M.update(app, {
      notFoundEnabled = enabled,
      notFoundPath = path
   }).notFoundPath
end

function M.update(app, values)
   values = values or {}
   local oldBlogBasePath = M.blogBasePath(app)
   local htmxEnabled = values.htmxEnabled
   if htmxEnabled == nil then htmxEnabled = M.isHtmxEnabled(app) end
   local smqEnabled = values.smqEnabled
   if smqEnabled == nil then smqEnabled = M.isSmqEnabled(app) end
   smqEnabled = htmxEnabled == true and smqEnabled == true
   local blogBasePath = normalizePath(values.blogBasePath, oldBlogBasePath)
   local notFoundEnabled = values.notFoundEnabled
   if notFoundEnabled == nil then notFoundEnabled = M.isNotFoundEnabled(app) end
   local notFoundPath = normalizePath(values.notFoundPath, M.notFoundPath(app))
   db.withWrite(app, function(conn)
      rebasePostReferences(conn, oldBlogBasePath, blogBasePath)
      local statements = {
         "INSERT OR REPLACE INTO options(key,value) VALUES('htmx_enabled'," ..
            db.quote(htmxEnabled and "1" or "0") .. ")",
         "INSERT OR REPLACE INTO options(key,value) VALUES('smq_enabled'," ..
            db.quote(smqEnabled and "1" or "0") .. ")",
         "INSERT OR REPLACE INTO options(key,value) VALUES('blog_base_path'," ..
            db.quote(blogBasePath) .. ")",
         "INSERT OR REPLACE INTO options(key,value) VALUES('not_found_enabled'," ..
            db.quote(notFoundEnabled and "1" or "0") .. ")",
         "INSERT OR REPLACE INTO options(key,value) VALUES('not_found_path'," ..
            db.quote(notFoundPath) .. ")"
      }
      for _, sql in ipairs(statements) do
         local ok, err = conn:execute(sql)
         if not ok then error(tostring(err), 2) end
      end
   end)
   app.settings = {
      htmxEnabled = htmxEnabled == true,
      smqEnabled = smqEnabled,
      blogBasePath = blogBasePath,
      notFoundEnabled = notFoundEnabled == true,
      notFoundPath = notFoundPath
   }
   return app.settings
end

function M.updateWithRuntime(app, values, applyRuntime)
   local previous = {
      htmxEnabled = M.isHtmxEnabled(app),
      smqEnabled = M.isSmqEnabled(app),
      blogBasePath = M.blogBasePath(app),
      notFoundEnabled = M.isNotFoundEnabled(app),
      notFoundPath = M.notFoundPath(app)
   }
   local ok, updated = pcall(M.update, app, values)
   if not ok then
      return nil, tostring(updated), { committed = false, rolledBack = false }
   end
   local runtimeOk, runtimeErr = pcall(applyRuntime, updated)
   if runtimeOk then return updated end

   local rollbackOk, rollbackErr = pcall(function()
      M.update(app, previous)
      applyRuntime(previous)
   end)
   if rollbackOk then
      return nil, tostring(runtimeErr), {
         committed = false,
         rolledBack = true
      }
   end
   return nil, tostring(runtimeErr), {
      committed = true,
      rolledBack = false,
      rollbackError = tostring(rollbackErr)
   }
end

return M
