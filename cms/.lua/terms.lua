local db = appreq "db"
local contentpath = appreq "contentpath"
local settings = appreq "settings"
local validation = appreq "validation"

local M = {}

local function categoryPath(app, slug)
   return assert(validation.path(settings.blogBasePath(app) .. "category/" .. slug))
end

local function decorateCategory(app, row)
   if not row then return nil end
   row.id = tonumber(row.id)
   row.assignmentCount = tonumber(row.assignment_count or row.assignmentCount or 0)
   row.publishedPostCount = tonumber(
      row.published_post_count or row.publishedPostCount or 0)
   row.assignment_count = nil
   row.published_post_count = nil
   row.path = categoryPath(app, row.slug)
   return row
end

local function categoryBySelector(conn, selector)
   local id = tonumber(selector)
   if id then
      return db.one(conn, "SELECT * FROM terms WHERE type='category' AND id=" .. id)
   end
   local slug, err = validation.slug(selector, "Category slug")
   if not slug then return nil, err end
   return db.one(conn, "SELECT * FROM terms WHERE type='category' AND slug=" ..
      db.quote(slug))
end

function M.categoryPath(app, slug)
   slug = assert(validation.slug(slug, "Category slug"))
   return categoryPath(app, slug)
end

function M.category(app, selector)
   return db.withRead(app, function(conn)
      local row, err = categoryBySelector(conn, selector)
      if err then return nil, err end
      if not row then return nil, "Category was not found" end
      return decorateCategory(app, row)
   end)
end

function M.categories(app, options)
   options = options or {}
   local limit = math.min(math.max(math.floor(tonumber(options.limit) or 100), 1), 500)
   local includeEmpty = options.includeEmpty ~= false
   return db.withRead(app, function(conn)
      local rows = db.rows(conn, [[SELECT t.*,
         COUNT(ct.content_id) assignment_count,
         COALESCE(SUM(CASE WHEN c.type='post' AND c.status='published' THEN 1 ELSE 0 END),0)
            published_post_count
         FROM terms t
         LEFT JOIN content_terms ct ON ct.term_id=t.id
         LEFT JOIN content c ON c.id=ct.content_id
         WHERE t.type='category'
         GROUP BY t.id]] ..
         (includeEmpty and "" or
            " HAVING SUM(CASE WHEN c.type='post' AND c.status='published' THEN 1 ELSE 0 END)>0") ..
         " ORDER BY t.name,t.id LIMIT " .. limit)
      for _, row in ipairs(rows) do decorateCategory(app, row) end
      return rows
   end)
end

function M.forContentConn(conn, contentId, kind)
   kind = kind or "category"
   return db.rows(conn, [[SELECT t.* FROM terms t
      JOIN content_terms ct ON ct.term_id=t.id
      WHERE ct.content_id=]] .. tonumber(contentId) ..
      " AND t.type=" .. db.quote(kind) .. " ORDER BY t.name,t.id")
end

function M.forContent(app, contentId, kind)
   contentId = tonumber(contentId)
   if not contentId then return {} end
   kind = kind or "category"
   local cache = app.readCache.contentTerms
   if not cache then
      cache = {}
      app.readCache.contentTerms = cache
   end
   local cacheKey = tostring(contentId) .. ":" .. kind
   if cache[cacheKey] then
      return cache[cacheKey]
   end

   local rows = db.withRead(app, function(conn)
      local rows = M.forContentConn(conn, contentId, kind)
      if kind == "category" then
         for _, row in ipairs(rows) do decorateCategory(app, row) end
      end
      return rows
   end)
   cache[cacheKey] = rows
   return rows
end

function M.replaceContentCategoriesConn(conn, contentId, categoryIds)
   contentId = assert(tonumber(contentId), "Content id is required")
   local selected = {}
   for _, value in ipairs(categoryIds or {}) do
      local id = tonumber(value)
      if id and id > 0 then selected[id] = true end
   end

   local ok, err = conn:execute([[DELETE FROM content_terms
      WHERE content_id=]] .. contentId .. [[ AND term_id IN(
         SELECT id FROM terms WHERE type='category')]])
   if not ok then error(tostring(err), 2) end

   for id in pairs(selected) do
      local row = db.one(conn,
         "SELECT id FROM terms WHERE type='category' AND id=" .. id)
      if not row then
         error("Category does not exist: " .. id, 2)
      end
      ok, err = conn:execute("INSERT INTO content_terms(content_id,term_id) VALUES(" ..
         contentId .. "," .. id .. ")")
      if not ok then error(tostring(err), 2) end
   end
end

function M.postsByCategory(app, selector, options)
   options = options or {}
   local limit = math.min(math.max(math.floor(tonumber(options.limit) or 20), 1), 100)
   local offset = math.max(math.floor(tonumber(options.offset) or 0), 0)
   return db.withRead(app, function(conn)
      local category, err = categoryBySelector(conn, selector)
      if err then return nil, err end
      if not category then return nil, "Category was not found" end
      local rows = db.rows(conn, [[SELECT c.* FROM content c
         JOIN content_terms ct ON ct.content_id=c.id
         WHERE ct.term_id=]] .. tonumber(category.id) ..
         [[ AND c.type='post' AND c.status='published'
         ORDER BY COALESCE(c.updated_at,c.created_at,0) DESC,c.id DESC
         LIMIT ]] .. limit .. " OFFSET " .. offset)
      for index, row in ipairs(rows) do
         rows[index] = contentpath.decorate(app, row)
      end
      return rows
   end)
end

function M.install(app)
   local cms = assert(app.cms, "CMS runtime is not installed")
   function cms:categories(options)
      return M.categories(app, options)
   end
   function cms:category(selector)
      return M.category(app, selector)
   end
   function cms:categoriesForContent(contentId)
      return M.forContent(app, contentId, "category")
   end
   function cms:postsByCategory(selector, options)
      return M.postsByCategory(app, selector, options)
   end
end

return M
