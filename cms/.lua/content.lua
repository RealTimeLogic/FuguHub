local db = appreq "db"
local contentpath = appreq "contentpath"

local M = {}

local function rowSize(row)
   local size = 0
   for key, value in pairs(row) do
      if type(key) == "string" then size = size + #key end
      if type(value) == "string" then size = size + #value end
   end
   return size
end

local function contentCache(app)
   local cache = app.readCache.contentRows
   if not cache then
      cache = {
         entries = {},
         count = 0,
         bytes = 0,
         tick = 0,
         maxEntries = tonumber(app.contentCacheMaxEntries) or 128,
         maxBytes = tonumber(app.contentCacheMaxBytes) or 4 * 1024 * 1024,
      }
      app.readCache.contentRows = cache
   end
   return cache
end

local function cachedRow(app, path)
   local cache = contentCache(app)
   local entry = cache.entries[path]
   if not entry then return nil end
   cache.tick = cache.tick + 1
   entry.used = cache.tick
   return entry.row
end

local function cacheRow(app, path, row)
   if not row then return end
   local cache = contentCache(app)
   if cache.maxEntries < 1 or cache.maxBytes < 1 then return end
   local size = rowSize(row)
   if size > cache.maxBytes then return end

   local previous = cache.entries[path]
   if previous then
      cache.bytes = cache.bytes - previous.size
   else
      cache.count = cache.count + 1
   end
   cache.tick = cache.tick + 1
   cache.entries[path] = { row = row, size = size, used = cache.tick }
   cache.bytes = cache.bytes + size

   while cache.count > cache.maxEntries or cache.bytes > cache.maxBytes do
      local oldestKey, oldest
      for key, entry in pairs(cache.entries) do
         if not oldest or entry.used < oldest.used then
            oldestKey, oldest = key, entry
         end
      end
      if not oldest then break end
      cache.entries[oldestKey] = nil
      cache.count = cache.count - 1
      cache.bytes = cache.bytes - oldest.size
   end
end

function M.byPath(app, path)
   local row = cachedRow(app, path)
   if row then
      return contentpath.decorate(app, row)
   end

   row = db.withRead(app, function(conn)
      local postPath = contentpath.postStoragePath(app, path)
      local found
      if postPath then
         found = db.one(conn, "SELECT * FROM content WHERE type='post' AND path=" ..
            db.quote(postPath) .. " AND status='published' LIMIT 1")
      end
      if not found then
         found = db.one(conn, "SELECT * FROM content WHERE type='page' AND path=" ..
            db.quote(path) .. " AND status='published' LIMIT 1")
      end
      if not found then
         found = db.one(conn, [[SELECT * FROM content WHERE type<>'post'
            AND type<>'page' AND path=]] .. db.quote(path) ..
            " AND status='published' LIMIT 1")
      end
      return found
   end)
   cacheRow(app, path, row)
   return contentpath.decorate(app, row)
end

function M.byId(app, id)
   id = tonumber(id)
   if not id then return nil end
   return db.withRead(app, function(conn)
      return contentpath.decorate(app,
         db.one(conn, "SELECT * FROM content WHERE id=" .. id .. " LIMIT 1"))
   end)
end

function M.redirectByPath(app, path)
   local cache = app.readCache
   local redirects = cache.redirects
   if not redirects then
      redirects = db.withRead(app, function(conn)
         local indexed = {}
         for _, row in ipairs(db.rows(conn, "SELECT * FROM redirects")) do
            indexed[row.from_path] = row
         end
         return indexed
      end)
      cache.redirects = redirects
   end
   return redirects[path]
end

function M.recentPosts(app, limit)
   limit = tonumber(limit) or 10
   return db.withRead(app, function(conn)
      local out = {}
      for _, row in ipairs(db.rows(conn,
         "SELECT * FROM content WHERE type='post' AND status='published' ORDER BY updated_at DESC LIMIT " ..
         limit)) do
         out[#out + 1] = contentpath.decorate(app, row)
      end
      return out
   end)
end

M.storagePath = contentpath.storagePath
M.publicPath = contentpath.publicPath
M.decorate = contentpath.decorate

return M
