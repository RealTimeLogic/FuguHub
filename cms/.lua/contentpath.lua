local settings = appreq "settings"
local validation = appreq "validation"

local M = {}

local function startsWith(value, prefix)
   return value:sub(1, #prefix) == prefix
end

local function normalize(path)
   return validation.path(path)
end

function M.storagePath(app, contentType, path)
   local normalized, err = normalize(path)
   if not normalized then return nil, err end
   if contentType ~= "post" then return normalized end

   local base = settings.blogBasePath(app)
   if normalized == base or normalized == "/" then
      return nil, "Post path must identify a post below the blog archive"
   end
   if startsWith(normalized, base) then
      normalized = "/" .. normalized:sub(#base + 1):gsub("^/+", "")
      normalized, err = normalize(normalized)
      if not normalized then return nil, err end
   end
   return normalized
end

function M.publicPath(app, contentType, storedPath)
   local normalized, err = normalize(storedPath)
   if not normalized then return nil, err end
   if contentType ~= "post" then return normalized end
   if normalized == "/" then return nil, "Post path cannot be the blog archive" end
   return normalize(settings.blogBasePath(app) .. normalized:gsub("^/+", ""))
end

function M.postStoragePath(app, publicPath)
   local normalized, err = normalize(publicPath)
   if not normalized then return nil, err end
   local base = settings.blogBasePath(app)
   if normalized == base or not startsWith(normalized, base) then return nil end
   return normalize("/" .. normalized:sub(#base + 1):gsub("^/+", ""))
end

function M.key(contentType, path)
   return tostring(contentType or "") .. "\0" .. tostring(path or "")
end

function M.decorate(app, row)
   if not row then return nil end
   local out = {}
   for key, value in pairs(row) do out[key] = value end
   out.stored_path = row.path
   out.public_path = assert(M.publicPath(app, row.type, row.path))
   out.path = out.public_path
   return out
end

return M
