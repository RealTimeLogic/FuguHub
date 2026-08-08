local db = appreq "db"
local contentpath = appreq "contentpath"

local M = {}

local function loadFlat(app, conn, slug)
   local sql = [[
SELECT mi.*,c.type content_type,c.path content_path FROM menu_items mi
JOIN menus m ON m.id = mi.menu_id
LEFT JOIN content c ON c.id=mi.content_id
WHERE m.slug=]] .. db.quote(slug) .. [[
AND COALESCE(mi.hidden, 0)=0
ORDER BY COALESCE(mi.parent_id, 0), mi.position, mi.id]]
   return db.rows(conn, sql, function(row)
      if row.content_type and row.content_path then
         row.url = assert(contentpath.publicPath(app, row.content_type, row.content_path))
      end
      row.children = {}
   end)
end

function M.tree(app, slug)
   slug = slug or "primary"
   local menus = app.readCache.menus
   if not menus then
      menus = {}
      app.readCache.menus = menus
   end
   if menus[slug] then
      return menus[slug]
   end

   local tree = db.withRead(app, function(conn)
      local rows = loadFlat(app, conn, slug)
      local byId = {}
      local roots = {}
      for _, row in ipairs(rows) do
         byId[tostring(row.id)] = row
      end
      for _, row in ipairs(rows) do
         local parent = row.parent_id and byId[tostring(row.parent_id)]
         if parent then
            table.insert(parent.children, row)
         else
            table.insert(roots, row)
         end
      end
      return roots
   end)
   menus[slug] = tree
   return tree
end

return M
