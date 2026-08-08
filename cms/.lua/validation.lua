local db = appreq "db"

local M = {}

function M.fail(message)
   error({ cmsValidation = true, message = tostring(message) }, 2)
end

function M.trim(value)
   return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.required(value, label, maxLength)
   value = M.trim(value)
   if value == "" then return nil, tostring(label or "Value") .. " is required" end
   if maxLength and #value > maxLength then
      return nil, tostring(label or "Value") .. " is too long"
   end
   return value
end

function M.slug(value, label)
   local out, err = M.required(value, label or "Slug", 255)
   if not out then return nil, err end
   if not out:match("^[%w][%w%-_]*$") then
      return nil, tostring(label or "Slug") .. " contains invalid characters"
   end
   return out
end

function M.path(value, default)
   local path = M.trim(value)
   if path == "" then path = default or "/" end
   if path:find("[?#]") then
      return nil, "Paths cannot contain a query string or fragment"
   end
   if path:find("\\", 1, true) or path:find("[%z\1-\31\127]") then
      return nil, "Path contains invalid characters"
   end
   if path:sub(1, 1) ~= "/" then path = "/" .. path end
   path = path:gsub("/+", "/")
   if path ~= "/" and path:sub(-1) ~= "/" then path = path .. "/" end
   return path
end

function M.url(value, allowExternal)
   local url = M.trim(value)
   if url == "" then return nil, "URL is required" end
   local scheme = url:match("^([%w][%w%+%-%.]*):")
   if scheme then
      scheme = scheme:lower()
      if not allowExternal or
         (scheme ~= "http" and scheme ~= "https" and scheme ~= "mailto" and scheme ~= "tel") then
         return nil, "URL scheme is not allowed"
      end
      if url:find("[%z\1-\31\127]") then return nil, "URL contains invalid characters" end
      return url
   end
   if allowExternal and url:sub(1, 2) == "//" then
      if url:find("[%z\1-\31\127]") then return nil, "URL contains invalid characters" end
      return url
   end
   return M.path(url)
end

function M.themeName(value)
   local name = M.trim(value):gsub("%.zip$", "")
   if name == "" then return nil, "Theme name is required" end
   if name == "." or name == ".." or not name:match("^[%w][%w._%-]*$") then
      return nil, "Theme name must be one safe path component"
   end
   return name
end

function M.redirectStatus(value)
   local status = tonumber(value)
   if status ~= 301 and status ~= 302 then
      return nil, "Redirect status must be 301 or 302"
   end
   return status
end

function M.menuParent(conn, menuId, parentId, currentId)
   parentId = tonumber(parentId)
   currentId = tonumber(currentId)
   menuId = tonumber(menuId)
   if not parentId or parentId == 0 then return nil end
   if currentId and parentId == currentId then
      return nil, "A menu item cannot be its own parent"
   end

   local seen = {}
   local id = parentId
   while id do
      if seen[id] then return nil, "The selected parent is already part of a cycle" end
      seen[id] = true
      if currentId and id == currentId then
         return nil, "The selected parent would create a menu cycle"
      end
      local row = db.one(conn, "SELECT menu_id,parent_id FROM menu_items WHERE id=" .. id)
      if not row then return nil, "Parent menu item does not exist" end
      if tonumber(row.menu_id) ~= menuId then
         return nil, "Parent menu item belongs to another menu"
      end
      id = tonumber(row.parent_id)
   end
   return parentId
end

return M
