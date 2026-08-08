local FastMCP = require "fastmcp.engine"
local db = appreq "db"
local mcpconfig = appreq "mcpconfig"
local zipWriter = appreq "zip_writer"

local M = {}
local Manager = {}
Manager.__index = Manager

local MAX_TEXT_BYTES = 4 * 1024 * 1024
local MAX_UPLOAD_BYTES = 32 * 1024 * 1024
local MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
local MAX_EXPANDED_BYTES = 64 * 1024 * 1024
local MAX_ENTRY_BYTES = 16 * 1024 * 1024
local MAX_ENTRIES = 2048
local MAX_DEPTH = 32

local textExtensions = {
   css = true, csv = true, html = true, htm = true, js = true, json = true,
   lsp = true, lua = true, md = true, svg = true, txt = true, xml = true,
   yaml = true, yml = true
}

local contentTypes = {
   css = "text/css; charset=utf-8",
   csv = "text/csv; charset=utf-8",
   gif = "image/gif",
   html = "text/html; charset=utf-8",
   htm = "text/html; charset=utf-8",
   ico = "image/x-icon",
   jpeg = "image/jpeg",
   jpg = "image/jpeg",
   js = "text/javascript; charset=utf-8",
   json = "application/json; charset=utf-8",
   lsp = "text/html; charset=utf-8",
   lua = "text/plain; charset=utf-8",
   md = "text/markdown; charset=utf-8",
   mp3 = "audio/mpeg",
   mp4 = "video/mp4",
   pdf = "application/pdf",
   png = "image/png",
   svg = "image/svg+xml",
   txt = "text/plain; charset=utf-8",
   webp = "image/webp",
   woff = "font/woff",
   woff2 = "font/woff2",
   xml = "application/xml; charset=utf-8",
   zip = "application/zip"
}

local function ticketId()
   return ba.b64urlencode(ba.rndbs(24))
end

local function extension(path)
   return tostring(path):match("%.([%w]+)$") and tostring(path):match("%.([%w]+)$"):lower() or ""
end

local function assetClass(path)
   if path == ".preload" then return "server-executable" end
   local ext = extension(path)
   if ext == "lsp" or ext == "lua" then return "server-executable" end
   if ext == "js" or ext == "html" or ext == "htm" or ext == "svg" then return "browser-executable" end
   return "static"
end

local function isText(path)
   return path == ".preload" or textExtensions[extension(path)] == true
end

local function normalizePath(value, allowEmpty)
   local path = tostring(value or "")
   if allowEmpty and path == "" then return "" end
   if path == "" or #path > 1024 then return nil, "Asset path must contain 1 to 1024 characters" end
   if path:find("\\", 1, true) or path:find("[%z\1-\31\127]") or
      path:sub(1, 1) == "/" or path:match("^[A-Za-z]:") or path:find(":", 1, true) then
      return nil, "Asset path must be a safe relative path"
   end
   local parts, depth = {}, 0
   for part in path:gmatch("[^/]+") do
      if part == "." or part == ".." or part == "" then return nil, "Asset path contains an unsafe segment" end
      depth = depth + 1
      if depth > MAX_DEPTH then return nil, "Asset path exceeds the nesting limit" end
      parts[#parts + 1] = part
   end
   path = table.concat(parts, "/")
   if path == "" or path:find("//", 1, true) then return nil, "Asset path is invalid" end
   if path:sub(-1) == "/" then return nil, "Asset path must not end with a slash" end
   return path
end

local function executablePathValid(path)
   if path == ".preload" then return true end
   if extension(path) == "lua" then
      return path:sub(1, 5) == ".lua/" and #path > 5,
         "Lua modules must be stored under assets/.lua/"
   end
   return true
end

local function readFile(io, path, maxBytes)
   local file, err = io:open(path, "rb")
   if not file then return nil, tostring(err) end
   local chunks, size, hash = {}, 0, ba.crypto.hash"sha256"
   while true do
      local chunk, readErr = file:read(16384)
      if chunk and #chunk > 0 then
         size = size + #chunk
         if size > maxBytes then file:close() return nil, "Asset exceeds size limit" end
         hash(chunk)
         chunks[#chunks + 1] = chunk
      elseif readErr then
         file:close()
         return nil, tostring(readErr)
      else
         break
      end
   end
   file:close()
   return table.concat(chunks), nil, hash(true, "hex"), size
end

local function fileDigest(io, path, maxBytes)
   local file, err = io:open(path, "rb")
   if not file then return nil, tostring(err) end
   local size, hash = 0, ba.crypto.hash"sha256"
   while true do
      local chunk, readErr = file:read(16384)
      if chunk and #chunk > 0 then
         size = size + #chunk
         if size > maxBytes then file:close() return nil, "Asset exceeds size limit" end
         hash(chunk)
      elseif readErr then file:close() return nil, tostring(readErr)
      else break end
   end
   file:close()
   return hash(true, "hex"), size
end

local function metadata(app, io, path, stat, includeDigest)
   stat = stat or io:stat(path)
   if not stat then return nil end
   local item = {
      path = path,
      directory = stat.isdir == true,
      byteLength = stat.isdir and 0 or tonumber(stat.size or 0),
      modifiedAt = tonumber(stat.mtime or 0),
      assetClass = stat.isdir and "directory" or assetClass(path),
      text = not stat.isdir and isText(path) or false
   }
   if not stat.isdir then
      item.contentType = contentTypes[extension(path)] or "application/octet-stream"
      if includeDigest ~= false then
         local digest, size = fileDigest(io, path, MAX_EXPANDED_BYTES)
         if digest then
            item.sha256 = digest
            item.byteLength = size
         end
      end
      if item.assetClass ~= "server-executable" and path:sub(1, 1) ~= "." then
         item.publicUrl = app.url("/" .. path)
      elseif extension(path) == "lsp" then
         item.publicUrl = app.url("/" .. path)
      end
   end
   return item
end

local function collect(io, directory, recursive, out, limit)
   local ok, err = pcall(function()
      for name, isdir, mtime, size in io:files(directory, true) do
         if name ~= "." and name ~= ".." then
            local path = directory == "" and name or directory .. "/" .. name
            out[#out + 1] = {
               path = path,
               directory = isdir == true,
               mtime = tonumber(mtime or 0),
               size = tonumber(size or 0)
            }
            if #out >= limit then return end
            if recursive and isdir then
               local childOk, childErr = collect(io, path, true, out, limit)
               if not childOk then error(childErr, 0) end
               if #out >= limit then return end
            end
         end
      end
   end)
   if not ok then return nil, tostring(err) end
   return true
end

local function ensureParents(io, path)
   local current = ""
   local parent = path:match("^(.*)/[^/]+$")
   if not parent then return true end
   for part in parent:gmatch("[^/]+") do
      current = current == "" and part or current .. "/" .. part
      local stat = io:stat(current)
      if stat and not stat.isdir then return nil, current .. " conflicts with a file" end
      if not stat then
         local ok, err = io:mkdir(current)
         if not ok then return nil, tostring(err) end
      end
   end
   return true
end

local function atomicInstall(io, path, producer)
   local parent, name = path:match("^(.*)/([^/]+)$")
   if not name then parent, name = "", path end
   local suffix = ticketId()
   local safeName = name:gsub("^%.+", "")
   local temp = (parent ~= "" and parent .. "/" or "") .. "mcp-" .. suffix .. "-" .. safeName .. ".tmp"
   local backup = (parent ~= "" and parent .. "/" or "") .. "mcp-" .. suffix .. "-" .. safeName .. ".bak"
   local ok, err = ensureParents(io, path)
   if not ok then return nil, err end
   local output
   output, err = io:open(temp, "wb")
   if not output then return nil, tostring(err) end
   local produced, produceErr = pcall(producer, output)
   local closeOk, closeErr = output:close()
   if not produced or closeOk == false then
      pcall(function() io:remove(temp) end)
      return nil, tostring(produceErr or closeErr)
   end
   local existing = io:stat(path)
   if existing then
      local renamed, renameErr = io:rename(path, backup)
      if not renamed then io:remove(temp) return nil, tostring(renameErr) end
   end
   local installed, installErr = io:rename(temp, path)
   if not installed then
      if existing then pcall(function() io:rename(backup, path) end) end
      pcall(function() io:remove(temp) end)
      return nil, tostring(installErr)
   end
   if existing then pcall(function() io:remove(backup) end) end
   return true
end

local function sourceDiagnostic(kind, path, message, content, byteOffset)
   message = tostring(message or "Validation failed"):gsub("[\r\n]+", " ")
   if #message > 1024 then message = message:sub(1, 1024) end
   local details = {
      kind = kind,
      path = path,
      message = message
   }
   local line = tonumber(message:match(":(%d+):"))
   local column = tonumber(message:match("[Cc]olumn%s+(%d+)"))
   byteOffset = tonumber(byteOffset) or tonumber(message:match("[Bb]yte%s+(%d+)")) or
      tonumber(message:match("[Oo]ffset%s+(%d+)"))
   if byteOffset and byteOffset >= 0 then
      local oneBased = math.min(#content + 1, byteOffset + 1)
      local prefix = content:sub(1, oneBased - 1)
      local _, newlineCount = prefix:gsub("\n", "\n")
      details.byteOffset = byteOffset
      line = line or newlineCount + 1
      column = column or oneBased - (prefix:match(".*()\n") or 0)
   elseif not line and not content:find("\n", 1, true) then
      line = 1
   end
   if line then details.line = line end
   if column then details.column = column end
   return details
end

local function validateCode(path, content)
   local class = assetClass(path)
   if class ~= "server-executable" then
      if extension(path) == "json" then
         local ok, decoded, decodeErr, decodeOffset = pcall(ba.json.decode, content)
         if not ok or decoded == nil then
            local nativeError = ok and decodeErr or decoded
            local message = "JSON parsing failed: " .. tostring(nativeError or "invalid JSON")
            return nil, message, sourceDiagnostic("json", path, message, content, decodeOffset)
         end
      end
      return { valid = true, executable = false, compiled = false, warnings = FastMCP.array() }
   end
   local validPath, pathErr = executablePathValid(path)
   if not validPath then
      return nil, pathErr, sourceDiagnostic("pathPolicy", path, pathErr, content)
   end
   local source = content
   if extension(path) == "lsp" then
      local ok, parsed, parseErr = pcall(ba.parselsp, content)
      if not ok then
         local message = "LSP parsing failed: " .. tostring(parsed)
         return nil, message, sourceDiagnostic("lsp", path, message, content)
      end
      if not parsed then
         local message = "LSP parsing failed: " .. tostring(parseErr)
         return nil, message, sourceDiagnostic("lsp", path, message, content)
      end
      source = parsed
   end
   local fn, err = load(source, "=(MCP asset validation: " .. path .. ")")
   if not fn then
      local kind = extension(path) == "lsp" and "lsp" or "lua"
      local message = "Lua compilation failed: " .. tostring(err)
      return nil, message, sourceDiagnostic(kind, path, message, content)
   end
   return {
      valid = true,
      executable = true,
      compiled = true,
      warnings = FastMCP.array(),
      restartRequired = path == ".preload" or extension(path) == "lua"
   }
end

local function mutationResult(app, path, previousSha, validation)
   local item = metadata(app, app.assetsIo, path)
   return {
      path = path,
      previousSha256 = previousSha,
      sha256 = item and item.sha256,
      byteLength = item and item.byteLength,
      publicUrl = item and item.publicUrl,
      assetClass = assetClass(path),
      validationWarnings = validation and validation.warnings or FastMCP.array(),
      cacheInvalidated = true,
      restartRequired = path == ".preload" or extension(path) == "lua",
      active = not (path == ".preload" or extension(path) == "lua")
   }
end

local function jsonResponse(response, status, value)
   local encoded = ba.json.encode(value)
   response:setstatus(status)
   response:setcontenttype("application/json; charset=utf-8")
   response:setheader("Cache-Control", "no-store")
   response:setheader("Content-Length", tostring(#encoded))
   response:send(encoded)
end

local function le16(data, at)
   local a, b = data:byte(at, at + 1)
   if not b then return nil end
   return a + b * 0x100
end

local function le32(data, at)
   local a, b, c, d = data:byte(at, at + 3)
   if not d then return nil end
   return a + b * 0x100 + c * 0x10000 + d * 0x1000000
end

local function hasFlag(value, flag)
   return math.floor(value / flag) % 2 == 1
end

local function inspectRawZip(data)
   if type(data) ~= "string" or #data < 22 then return nil, "ZIP is truncated" end
   local eocd
   local first = math.max(1, #data - 65557)
   for index = #data - 21, first, -1 do
      if data:sub(index, index + 3) == "PK\5\6" then eocd = index break end
   end
   if not eocd then return nil, "ZIP end-of-central-directory record is missing" end
   local disk = le16(data, eocd + 4)
   local centralDisk = le16(data, eocd + 6)
   local diskEntries = le16(data, eocd + 8)
   local entryCount = le16(data, eocd + 10)
   local centralSize = le32(data, eocd + 12)
   local centralOffset = le32(data, eocd + 16)
   local commentLength = le16(data, eocd + 20)
   if not commentLength or eocd + 22 + commentLength - 1 ~= #data then
      return nil, "ZIP has trailing data or an invalid comment length"
   end
   if disk ~= 0 or centralDisk ~= 0 or diskEntries ~= entryCount then
      return nil, "Multi-disk ZIP archives are not supported"
   end
   if entryCount == 0xffff or centralSize == 0xffffffff or centralOffset == 0xffffffff then
      return nil, "ZIP64 archives are not supported"
   end
   if entryCount > MAX_ENTRIES then return nil, "Archive exceeds entry limit" end
   local centralAt = centralOffset + 1
   local centralEnd = centralAt + centralSize
   if centralAt < 1 or centralEnd - 1 > eocd - 1 then return nil, "ZIP central directory bounds are invalid" end

   local seen, total = {}, 0
   for _ = 1, entryCount do
      if data:sub(centralAt, centralAt + 3) ~= "PK\1\2" then
         return nil, "ZIP central directory entry is invalid"
      end
      local madeBy = le16(data, centralAt + 4)
      local flags = le16(data, centralAt + 8)
      local method = le16(data, centralAt + 10)
      local compressed = le32(data, centralAt + 20)
      local expanded = le32(data, centralAt + 24)
      local nameLength = le16(data, centralAt + 28)
      local extraLength = le16(data, centralAt + 30)
      local entryCommentLength = le16(data, centralAt + 32)
      local diskStart = le16(data, centralAt + 34)
      local externalAttributes = le32(data, centralAt + 38)
      local localOffset = le32(data, centralAt + 42)
      if not localOffset then return nil, "ZIP central directory entry is truncated" end
      if hasFlag(flags, 1) then return nil, "Encrypted ZIP entries are not supported" end
      if method ~= 0 and method ~= 8 then return nil, "ZIP compression method is not supported" end
      if compressed == 0xffffffff or expanded == 0xffffffff or localOffset == 0xffffffff then
         return nil, "ZIP64 entries are not supported"
      end
      if diskStart ~= 0 then return nil, "Multi-disk ZIP entries are not supported" end
      if expanded > MAX_ENTRY_BYTES then return nil, "Archive entry exceeds size limit" end
      total = total + expanded
      if total > MAX_EXPANDED_BYTES then return nil, "Archive exceeds expanded size limit" end
      if compressed == 0 and expanded > 0 then return nil, "ZIP entry has an invalid compression size" end
      if compressed > 0 and expanded / compressed > 100 then
         return nil, "ZIP entry exceeds the compression-ratio limit"
      end

      local nameAt = centralAt + 46
      local rawName = data:sub(nameAt, nameAt + nameLength - 1)
      if #rawName ~= nameLength or rawName == "" or rawName:find("\\", 1, true) then
         return nil, "ZIP entry has an invalid name"
      end
      local directory = rawName:sub(-1) == "/"
      local candidate = directory and rawName:sub(1, -2) or rawName
      local normalized, pathErr = normalizePath(candidate)
      if not normalized then return nil, "Unsafe ZIP entry " .. rawName .. ": " .. tostring(pathErr) end
      local key = normalized:lower()
      if seen[key] then return nil, "ZIP contains a duplicate entry path: " .. normalized end
      seen[key] = true

      local osType = math.floor(madeBy / 0x100)
      local unixMode = math.floor(externalAttributes / 0x10000)
      if osType == 3 and math.floor(unixMode / 0x1000) % 0x10 == 0xA then
         return nil, "ZIP symbolic links are not supported"
      end

      local localAt = localOffset + 1
      if data:sub(localAt, localAt + 3) ~= "PK\3\4" then return nil, "ZIP local header is invalid" end
      local localFlags = le16(data, localAt + 6)
      local localMethod = le16(data, localAt + 8)
      local localNameLength = le16(data, localAt + 26)
      local localExtraLength = le16(data, localAt + 28)
      local localName = data:sub(localAt + 30, localAt + 30 + localNameLength - 1)
      if localFlags ~= flags or localMethod ~= method or localName ~= rawName then
         return nil, "ZIP local and central entry metadata differ"
      end
      local dataEnd = localAt + 30 + localNameLength + localExtraLength + compressed - 1
      if dataEnd > #data then return nil, "ZIP entry data exceeds archive bounds" end

      centralAt = nameAt + nameLength + extraLength + entryCommentLength
      if centralAt > centralEnd then return nil, "ZIP central directory entry exceeds bounds" end
   end
   if centralAt ~= centralEnd then return nil, "ZIP central directory size does not match its entries" end
   return { entryCount = entryCount, expandedBytes = total }
end

function Manager:isWritable()
   return self.app.assetsSource == "directory"
end

function Manager:_mutate(fn)
   local done, result = false
   self.mutationThread:run(function()
      result = table.pack(pcall(fn))
      done = true
   end)
   while not done do ba.sleep(10) end
   if not result[1] then error(result[2], 3) end
   return table.unpack(result, 2, result.n)
end

function Manager:capabilities()
   local app = self.app
   local result = {
      source = app.assetsSource,
      logicalSource = app.assetsSource == "zip" and app.assetsZipName or app.assetsDirName,
      writable = self:isWritable(),
      shadowedDirectoryExists = app.homeIo:stat(app.assetsDirName) ~= nil,
      packageExists = app.homeIo:stat(app.assetsZipName) ~= nil,
      publicBaseUrl = app.baseUri,
      publicPathRule = "The source directory name is not a URL prefix. MCP path chat/chat.js is public at the mount-aware /chat/chat.js, not /assets/chat/chat.js.",
      cmsOwnedPublicPrefix = app.url("/assets/"),
      guideId = "assets",
      executablePolicy = {
         confirmationRequired = true,
         preloadPath = ".preload",
         luaModulePrefix = ".lua/",
         lspSupported = true,
         genericReloadSupported = true,
         assetsApplicationRestartSupported = true,
         restartTool = "restartAssetsApplication"
      },
      activation = {
         staticImmediate = true,
         lspImmediate = true,
         luaRestartRequired = true,
         preloadRestartRequired = true,
         restartMethod = "restartAssetsApplication",
         luaPreloadMakoRestartRequired = false,
         assetsZipRestartRequired = true
      },
      limits = {
         textBytes = MAX_TEXT_BYTES,
         uploadBytes = MAX_UPLOAD_BYTES,
         archiveBytes = MAX_ARCHIVE_BYTES,
         expandedArchiveBytes = MAX_EXPANDED_BYTES,
         entryBytes = MAX_ENTRY_BYTES,
         entries = MAX_ENTRIES,
         depth = MAX_DEPTH
      }
   }
   if not result.writable then
      result.readOnlyReason = "The active assets.zip source is immutable"
   end
   return result
end

function Manager:list(args)
   args = args or {}
   local directory, err = normalizePath(args.path or "", true)
   if not directory then return nil, err end
   local stat = directory ~= "" and self.app.assetsIo:stat(directory) or { isdir = true }
   if not stat or not stat.isdir then return nil, "Asset directory was not found" end
   local limit = math.floor(tonumber(args.limit) or 500)
   if limit < 1 or limit > 2000 then return nil, "Asset list limit must be between 1 and 2000" end
   local found = {}
   local ok
   ok, err = collect(self.app.assetsIo, directory, args.recursive == true, found, limit + 1)
   if not ok then return nil, err end
   local truncated = #found > limit
   if truncated then found[#found] = nil end
   local items = {}
   for _, entry in ipairs(found) do
      items[#items + 1] = metadata(self.app, self.app.assetsIo, entry.path, {
         isdir = entry.directory, size = entry.size, mtime = entry.mtime
      }, args.includeSha256 == true)
   end
   return { path = directory, items = items, truncated = truncated, source = self.app.assetsSource }
end

function Manager:get(path)
   local normalized, err = normalizePath(path)
   if not normalized then return nil, err, "invalidAssetPath" end
   local stat = self.app.assetsIo:stat(normalized)
   if not stat then
      return nil, "Asset file was not found: " .. normalized, "assetNotFound", { path = normalized }
   end
   if stat.isdir then
      return nil, "Asset path is a directory: " .. normalized, "assetTypeMismatch", {
         path = normalized, existingType = "directory"
      }
   end
   local item = metadata(self.app, self.app.assetsIo, normalized, stat)
   if isText(normalized) then
      local value
      value, err = readFile(self.app.assetsIo, normalized, MAX_TEXT_BYTES)
      if not value then return nil, err end
      item.content = value
      item.encoding = "utf-8"
   else
      item.contentAvailableByDownload = true
   end
   return item
end

function Manager:dependencies(path)
   local normalized, err = normalizePath(path)
   if not normalized then return nil, err, "invalidAssetPath" end
   if not self.app.assetsIo:stat(normalized) then
      return nil, "Asset was not found: " .. normalized, "assetNotFound", { path = normalized }
   end
   local references, scannedBytes, maxScan = {}, 0, 4 * 1024 * 1024
   local needles = { normalized, "/" .. normalized }
   local function inspect(sourceType, sourcePath, text)
      if scannedBytes >= maxScan then return end
      text = tostring(text or "")
      scannedBytes = scannedBytes + #text
      for _, needle in ipairs(needles) do
         if text:find(needle, 1, true) then
            references[#references + 1] = { sourceType = sourceType, source = sourcePath, match = needle }
            return
         end
      end
   end
   db.withRead(self.app, function(conn)
      for _, row in ipairs(db.rows(conn, "SELECT path,body_html,head_html FROM content")) do
         inspect("content", row.path, tostring(row.body_html or "") .. "\n" .. tostring(row.head_html or ""))
      end
   end)
   local files = {}
   local collected, collectErr = collect(self.app.assetsIo, "", true, files, MAX_ENTRIES)
   if not collected then return nil, collectErr, "assetDependencyScanFailed" end
   for _, entry in ipairs(files) do
      if not entry.directory and entry.path ~= normalized and isText(entry.path) and entry.size <= 512 * 1024 then
         local text, readErr = readFile(self.app.assetsIo, entry.path, 512 * 1024)
         if not text then return nil, readErr, "assetDependencyScanFailed" end
         inspect("asset", entry.path, text)
      end
   end
   if self.app.theme and self.app.theme.io then
      local themeFiles = {}
      collected, collectErr = collect(self.app.theme.io, "", true, themeFiles, MAX_ENTRIES)
      if not collected then return nil, collectErr, "assetDependencyScanFailed" end
      for _, entry in ipairs(themeFiles) do
         if not entry.directory and isText(entry.path) and entry.size <= 512 * 1024 then
            local text, readErr = readFile(self.app.theme.io, entry.path, 512 * 1024)
            if not text then return nil, readErr, "assetDependencyScanFailed" end
            inspect("theme", entry.path, text)
         end
      end
   end
   return {
      path = normalized,
      references = references,
      referenceCount = #references,
      complete = false,
      scannedBytes = scannedBytes,
      limitations = "Dynamic Lua, LSP, CSS, and JavaScript references cannot be discovered completely"
   }
end

function Manager:_writeText(args)
   if not self:isWritable() then return nil, "Active ZIP assets are read-only", "assetsReadOnly" end
   local path, err = normalizePath(args.path)
   if not path then return nil, err, "invalidAssetPath" end
   if not isText(path) then return nil, "writeTextAsset accepts text asset types only", "assetTypeMismatch" end
   local content = tostring(args.content or "")
   if #content > MAX_TEXT_BYTES then return nil, "Text asset exceeds size limit", "assetTooLarge" end
   if assetClass(path) == "server-executable" and args.confirmedExecutable ~= true then
      return nil, "Executable assets require explicit confirmation", "executableConfirmationRequired"
   end
   local validation, validationErr, validationDetails = validateCode(path, content)
   if not validation then
      return nil, validationErr, "assetValidationFailed", validationDetails
   end
   local stat = self.app.assetsIo:stat(path)
   local previousSha
   if stat then
      if stat.isdir then return nil, "Asset path conflicts with a directory", "assetPathConflict" end
      previousSha = fileDigest(self.app.assetsIo, path, MAX_EXPANDED_BYTES)
      if not args.expectedSha256 then
         return nil, "expectedSha256 is required when replacing an asset", "assetConflict"
      end
      if not mcpconfig.secureEqual(previousSha:lower(), tostring(args.expectedSha256):lower()) then
         return nil, "Asset changed after it was read", "assetConflict", { currentSha256 = previousSha }
      end
   elseif args.expectedSha256 then
      return nil, "Asset no longer exists", "assetConflict"
   end
   if args.validateOnly == true then
      return {
         valid = true, path = path, previousSha256 = previousSha,
         proposedSha256 = ba.crypto.hash"sha256"(content)(true, "hex"),
         byteLength = #content, validation = validation,
         restartRequired = path == ".preload" or extension(path) == "lua"
      }
   end
   local ok
   ok, err = atomicInstall(self.app.assetsIo, path, function(output)
      assert(output:write(content))
   end)
   if not ok then return nil, err, "assetWriteFailed" end
   if self.app.invalidateRuntime then
      self.app.invalidateRuntime()
   else
      if self.app.clearPageTables then self.app.clearPageTables() end
      if self.app.clearRenderCache then self.app.clearRenderCache() end
   end
   return mutationResult(self.app, path, previousSha, validation)
end

function Manager:_createDirectory(args)
   if not self:isWritable() then return nil, "Active ZIP assets are read-only", "assetsReadOnly" end
   local path, err = normalizePath(args.path)
   if not path then return nil, err, "invalidAssetPath" end
   local existing = self.app.assetsIo:stat(path)
   if existing then
      if existing.isdir then
         return { created = false, exists = true, directory = true, path = path }
      end
      return nil, "Asset path already exists as a file: " .. path, "assetPathConflict", {
         path = path, existingType = "file"
      }
   end
   local ok
   ok, err = ensureParents(self.app.assetsIo, path .. "/placeholder")
   if not ok then return nil, err, "assetDirectoryCreateFailed" end
   if not self.app.assetsIo:stat(path) then
      ok, err = self.app.assetsIo:mkdir(path)
      if not ok then return nil, tostring(err), "assetDirectoryCreateFailed" end
   end
   return { created = true, path = path }
end

function Manager:_move(args)
   if not self:isWritable() then return nil, "Active ZIP assets are read-only", "assetsReadOnly" end
   if args.confirmed ~= true then return nil, "Moving an asset requires explicit confirmation", "confirmationRequired" end
   local source, err = normalizePath(args.path)
   if not source then return nil, err, "invalidAssetPath" end
   local destination
   destination, err = normalizePath(args.newPath)
   if not destination then return nil, err, "invalidAssetPath" end
   local stat = self.app.assetsIo:stat(source)
   if not stat then return nil, "Source asset was not found", "assetNotFound" end
   if self.app.assetsIo:stat(destination) then return nil, "Destination asset already exists", "assetPathConflict" end
   if assetClass(destination) == "server-executable" then
      if args.confirmedExecutable ~= true then
         return nil, "Moving to an executable path requires explicit executable confirmation",
            "executableConfirmationRequired"
      end
      local validPath, pathErr = executablePathValid(destination)
      if not validPath then return nil, pathErr, "invalidAssetPath" end
      if stat.isdir then return nil, "A directory cannot be moved to an executable file path", "assetTypeMismatch" end
      local sourceText, readErr = readFile(self.app.assetsIo, source, MAX_TEXT_BYTES)
      if not sourceText then return nil, readErr, "assetValidationFailed" end
      local validated, validationErr, validationDetails = validateCode(destination, sourceText)
      if not validated then
         return nil, validationErr, "assetValidationFailed", validationDetails
      end
   end
   if not stat.isdir then
      local current = fileDigest(self.app.assetsIo, source, MAX_EXPANDED_BYTES)
      if not args.expectedSha256 or not mcpconfig.secureEqual(current, tostring(args.expectedSha256):lower()) then
         return nil, "Asset changed after it was read", "assetConflict", { currentSha256 = current }
      end
   end
   local ok
   ok, err = ensureParents(self.app.assetsIo, destination)
   if not ok then return nil, err, "assetMoveFailed" end
   ok, err = self.app.assetsIo:rename(source, destination)
   if not ok then return nil, tostring(err), "assetMoveFailed" end
   return {
      moved = true,
      path = source,
      newPath = destination,
      restartRequired = source == ".preload" or destination == ".preload" or
         extension(source) == "lua" or extension(destination) == "lua"
   }
end

function Manager:_delete(args)
   if not self:isWritable() then return nil, "Active ZIP assets are read-only", "assetsReadOnly" end
   if args.confirmed ~= true then return nil, "Deleting an asset requires explicit confirmation", "confirmationRequired" end
   local path, err = normalizePath(args.path)
   if not path then return nil, err, "invalidAssetPath" end
   local stat = self.app.assetsIo:stat(path)
   if not stat then return nil, "Asset was not found", "assetNotFound" end
   if stat.isdir then
      local entries = {}
      local collected, collectErr = collect(self.app.assetsIo, path, false, entries, 1)
      if not collected then return nil, collectErr, "assetDeleteFailed" end
      if #entries > 0 then return nil, "Only empty asset directories may be deleted", "assetDirectoryNotEmpty" end
      local ok
      ok, err = self.app.assetsIo:rmdir(path)
      if not ok then return nil, tostring(err), "assetDeleteFailed" end
   else
      local current = fileDigest(self.app.assetsIo, path, MAX_EXPANDED_BYTES)
      if not args.expectedSha256 or not mcpconfig.secureEqual(current, tostring(args.expectedSha256):lower()) then
         return nil, "Asset changed after it was read", "assetConflict", { currentSha256 = current }
      end
      local ok
      ok, err = self.app.assetsIo:remove(path)
      if not ok then return nil, tostring(err), "assetDeleteFailed" end
   end
   if self.app.invalidateRuntime then
      self.app.invalidateRuntime()
   else
      if self.app.clearPageTables then self.app.clearPageTables() end
      if self.app.clearRenderCache then self.app.clearRenderCache() end
   end
   return { deleted = true, path = path, restartRequired = path == ".preload" or extension(path) == "lua" }
end

function Manager:_cleanup()
   local now = os.time()
   for id, ticket in pairs(self.tickets) do
      if ticket.expiresAt <= now then
         if ticket.tempPath then pcall(function() self.app.dataIo:remove(ticket.tempPath) end) end
         self.tickets[id] = nil
      end
   end
end

function Manager:_newTicket(kind, data)
   self:_cleanup()
   local id = ticketId()
   data = data or {}
   data.kind = kind
   data.expiresAt = os.time() + self.ticketTtl
   self.tickets[id] = data
   return id, data
end

function Manager:_snapshotAsset(path)
   local source, err = self.app.assetsIo:open(path, "rb")
   if not source then return nil, tostring(err) end
   local id = ticketId()
   local tempPath = "FuguHub-asset-" .. id
   local output
   output, err = self.app.dataIo:open(tempPath, "wb")
   if not output then source:close() return nil, tostring(err) end
   local size, hash = 0, ba.crypto.hash"sha256"
   local ok, result = pcall(function()
      while true do
         local chunk, readErr = source:read(16384)
         if chunk and #chunk > 0 then
            size = size + #chunk
            assert(size <= MAX_UPLOAD_BYTES, "Asset exceeds download limit")
            hash(chunk)
            assert(output:write(chunk))
         elseif readErr then error(readErr)
         else break end
      end
      assert(output:close())
      output = nil
   end)
   source:close()
   if output then pcall(function() output:close() end) end
   if not ok then self.app.dataIo:remove(tempPath) return nil, tostring(result) end
   return { tempPath = tempPath, size = size, sha256 = hash(true, "hex") }
end

function Manager:prepareDownload(args, serverOrigin)
   local path, err = normalizePath(args.path)
   if not path then return nil, err, "invalidAssetPath" end
   local stat = self.app.assetsIo:stat(path)
   if not stat or stat.isdir then return nil, "Asset file was not found", "assetNotFound" end
   local snapshot
   snapshot, err = self:_snapshotAsset(path)
   if not snapshot then return nil, err, "assetDownloadFailed" end
   snapshot.path = path
   snapshot.contentType = contentTypes[extension(path)] or "application/octet-stream"
   local id, ticket = self:_newTicket("download", snapshot)
   return {
      downloadUrl = serverOrigin .. self.app.url("/mcp/assets?ticket=" .. id),
      expiresAt = ticket.expiresAt,
      expiresInSeconds = self.ticketTtl,
      expectedBytes = snapshot.size,
      digest = "sha256:" .. snapshot.sha256,
      contentType = snapshot.contentType,
      path = path
   }
end

function Manager:prepareUpload(args, serverOrigin)
   if not self:isWritable() then return nil, "Active ZIP assets are read-only", "assetsReadOnly" end
   local path, err = normalizePath(args.path)
   if not path then return nil, err, "invalidAssetPath" end
   if assetClass(path) == "server-executable" then
      return nil, "Use writeTextAsset for executable LSP and Lua assets", "assetTypeMismatch"
   end
   local expectedBytes = tonumber(args.expectedBytes)
   if not expectedBytes or expectedBytes < 1 or expectedBytes % 1 ~= 0 or expectedBytes > MAX_UPLOAD_BYTES then
      return nil, "expectedBytes is invalid", "invalidAssetUpload"
   end
   local sha = tostring(args.sha256 or ""):lower()
   if not sha:match("^[0-9a-f]+$") or #sha ~= 64 then return nil, "sha256 is invalid", "invalidAssetUpload" end
   local declaredType = tostring(args.contentType or ""):lower():gsub("%s*;.*$", "")
   local expectedType = tostring(contentTypes[extension(path)] or "application/octet-stream"):lower():gsub("%s*;.*$", "")
   if expectedType ~= "application/octet-stream" and declaredType ~= expectedType then
      return nil, "contentType does not match the asset extension", "assetTypeMismatch"
   end
   local existing = self.app.assetsIo:stat(path)
   local current
   if existing then
      if existing.isdir then return nil, "Asset path conflicts with a directory", "assetPathConflict" end
      current = fileDigest(self.app.assetsIo, path, MAX_EXPANDED_BYTES)
      if not args.expectedCurrentSha256 or
         not mcpconfig.secureEqual(current, tostring(args.expectedCurrentSha256):lower()) then
         return nil, "Asset changed after it was read", "assetConflict", { currentSha256 = current }
      end
   elseif args.expectedCurrentSha256 then
      return nil, "Asset no longer exists", "assetConflict"
   end
   local id, ticket = self:_newTicket("upload", {
      path = path,
      expectedBytes = expectedBytes,
      sha256 = sha,
      contentType = declaredType,
      previousSha256 = current
   })
   return {
      uploadUrl = serverOrigin .. self.app.url("/mcp/assets?ticket=" .. id),
      expiresAt = ticket.expiresAt,
      expiresInSeconds = self.ticketTtl,
      expectedBytes = expectedBytes,
      digest = "sha256:" .. sha,
      contentType = ticket.contentType,
      path = path,
      method = "POST",
      oneUse = true,
      redirectPolicy = "do-not-follow",
      requiredHeaders = FastMCP.array {
         "Authorization: Bearer <the configured MCP token>",
         "Content-Type: " .. ticket.contentType,
         "Content-Length: " .. tostring(expectedBytes)
      },
      authorization = "Use the same MCP bearer token without logging or exposing it"
   }
end

function Manager:_collectArchive()
   local raw = {}
   local ok, err = collect(self.app.assetsIo, "", true, raw, MAX_ENTRIES + 1)
   if not ok then return nil, err end
   if #raw > MAX_ENTRIES then return nil, "Assets exceed archive entry limit" end
   local entries, total = {}, 0
   for _, item in ipairs(raw) do
      if item.directory then
         entries[#entries + 1] = { path = item.path, directory = true, mtime = item.mtime }
      else
         if item.size > MAX_ENTRY_BYTES then return nil, "Asset exceeds archive entry limit: " .. item.path end
         total = total + item.size
         if total > MAX_EXPANDED_BYTES then return nil, "Assets exceed expanded archive limit" end
         entries[#entries + 1] = {
            path = item.path,
            source = { io = self.app.assetsIo, path = item.path },
            mtime = item.mtime
         }
      end
   end
   return entries, total
end

function Manager:prepareExport(serverOrigin)
   local entries, expanded = self:_collectArchive()
   if not entries then return nil, expanded, "assetsExportFailed" end
   local id, tempPath = ticketId(), "FuguHub-assets-export-" .. ticketId() .. ".zip"
   local output, err = self.app.dataIo:open(tempPath, "wb")
   if not output then return nil, tostring(err), "assetsExportFailed" end
   local hash = ba.crypto.hash"sha256"
   local info
   info, err = zipWriter.write(entries, function(chunk)
      hash(chunk)
      return output:write(chunk)
   end, {
      compress = true,
      maxEntries = MAX_ENTRIES,
      maxDepth = MAX_DEPTH,
      maxEntryBytes = MAX_ENTRY_BYTES,
      maxArchiveBytes = MAX_ARCHIVE_BYTES
   })
   local closeOk, closeErr = output:close()
   if not info or closeOk == false then
      self.app.dataIo:remove(tempPath)
      return nil, tostring(err or closeErr), "assetsExportFailed"
   end
   local ticket
   id, ticket = self:_newTicket("assets-export", {
      tempPath = tempPath,
      size = info.size,
      sha256 = hash(true, "hex"),
      contentType = "application/zip"
   })
   return {
      downloadUrl = serverOrigin .. self.app.url("/mcp/assets?ticket=" .. id),
      expiresAt = ticket.expiresAt,
      expiresInSeconds = self.ticketTtl,
      expectedBytes = ticket.size,
      digest = "sha256:" .. ticket.sha256,
      expandedBytes = expanded,
      entryCount = info.entryCount,
      source = self.app.assetsSource
   }
end

function Manager:prepareImport(args, serverOrigin)
   if args.confirmed ~= true then return nil, "Assets ZIP activation requires explicit confirmation", "confirmationRequired" end
   local expectedBytes = tonumber(args.expectedBytes)
   if not expectedBytes or expectedBytes < 1 or expectedBytes % 1 ~= 0 or expectedBytes > MAX_ARCHIVE_BYTES then
      return nil, "expectedBytes is invalid", "invalidAssetsArchive"
   end
   local sha = tostring(args.sha256 or ""):lower()
   if not sha:match("^[0-9a-f]+$") or #sha ~= 64 then return nil, "sha256 is invalid", "invalidAssetsArchive" end
   local current
   if self.app.homeIo:stat(self.app.assetsZipName) then
      current = fileDigest(self.app.homeIo, self.app.assetsZipName, MAX_ARCHIVE_BYTES)
      if not args.expectedCurrentSha256 or
         not mcpconfig.secureEqual(current, tostring(args.expectedCurrentSha256):lower()) then
         return nil, "assets.zip changed after it was inspected", "assetConflict", { currentSha256 = current }
      end
   end
   local id, ticket = self:_newTicket("assets-import", {
      expectedBytes = expectedBytes,
      sha256 = sha,
      previousSha256 = current
   })
   return {
      uploadUrl = serverOrigin .. self.app.url("/mcp/assets?ticket=" .. id),
      expiresAt = ticket.expiresAt,
      expiresInSeconds = self.ticketTtl,
      expectedBytes = expectedBytes,
      digest = "sha256:" .. sha,
      contentType = "application/zip",
      method = "POST",
      oneUse = true,
      redirectPolicy = "do-not-follow",
      requiredHeaders = FastMCP.array {
         "Authorization: Bearer <the configured MCP token>",
         "Content-Type: application/zip",
         "Content-Length: " .. tostring(expectedBytes)
      },
      restartRequired = true,
      activationSource = self.app.assetsZipName
   }
end

local safeResponseHeaders = {
   ["cache-control"] = true,
   ["content-encoding"] = true,
   ["content-length"] = true,
   ["content-type"] = true,
   ["etag"] = true,
   ["last-modified"] = true,
   ["location"] = true
}

local function normalizePublicPath(app, value)
   local path = tostring(value or "")
   if path == "" or #path > 2048 or path:sub(1, 1) ~= "/" or
      path:find("[%z\1-\31\127]") or path:find("\\", 1, true) or
      path:find("?", 1, true) or path:find("#", 1, true) or
      path:find("//", 1, true) or path:lower():find("%%2e", 1, true) or
      path:lower():find("%%5c", 1, true) then
      return nil, "Public path must be a safe absolute path without a query or fragment"
   end
   for segment in path:gmatch("[^/]+") do
      if segment == "." or segment == ".." then
         return nil, "Public path contains an unsafe segment"
      end
   end
   local base = app.baseUri or "/"
   if base ~= "/" and path:sub(1, #base) ~= base then
      return nil, "Public path is outside this CMS mount"
   end
   local relative = base == "/" and path:sub(2) or path:sub(#base + 1)
   if relative == "mcp" or relative:sub(1, 4) == "mcp/" or
      relative == "admin" or relative:sub(1, 6) == "admin/" then
      return nil, "Public-path tests cannot target the MCP or admin API"
   end
   return path
end

function Manager:testPublicPath(args, serverOrigin)
   if not serverOrigin then return nil, "Cannot derive this server origin", "serverOriginUnavailable" end
   local path, err = normalizePublicPath(self.app, args.path)
   if not path then return nil, err, "invalidPublicPath", { path = tostring(args.path or "") } end
   local method = tostring(args.method or "GET"):upper()
   if method ~= "GET" and method ~= "HEAD" then
      return nil, "Only GET and HEAD are supported", "invalidPublicMethod"
   end
   local maxBytes = math.floor(tonumber(args.maxBytes) or 32768)
   if maxBytes < 0 or maxBytes > 262144 then
      return nil, "maxBytes must be between 0 and 262144", "invalidPublicResponseLimit"
   end

   local http = require"httpc".create { persistent = false }
   http:timeout(5000)
   local ok, requestErr = http:request {
      url = serverOrigin .. path,
      method = method,
      header = {
         ["Accept"] = "*/*",
         ["Accept-Encoding"] = "identity",
         ["User-Agent"] = "FuguHub-MCP-public-path-test"
      }
   }
   if not ok then
      http:close()
      return nil, "Public request failed: " .. tostring(requestErr),
         "publicRequestFailed", { path = path }
   end

   local status = tonumber(http:status())
   local headers, contentType = {}, ""
   for key, value in pairs(http:header() or {}) do
      local normalized = tostring(key):lower()
      if safeResponseHeaders[normalized] then
         headers[normalized] = tostring(value)
      end
   end
   contentType = headers["content-type"] or ""
   local chunks, bytesRead, truncated = {}, 0, false
   local hash = ba.crypto.hash"sha256"
   if method == "GET" then
      while bytesRead < maxBytes do
         local chunk, readErr = http:read(math.min(8192, maxBytes - bytesRead))
         if not chunk then
            if readErr then
               http:close()
               return nil, "Public response read failed: " .. tostring(readErr),
                  "publicResponseReadFailed", { path = path, status = status }
            end
            break
         end
         bytesRead = bytesRead + #chunk
         hash(chunk)
         chunks[#chunks + 1] = chunk
      end
      if bytesRead == maxBytes then
         local extra, readErr = http:read(1)
         if readErr then
            http:close()
            return nil, "Public response read failed: " .. tostring(readErr),
               "publicResponseReadFailed", { path = path, status = status }
         end
         truncated = extra ~= nil
      end
   end
   http:close()

   local body = table.concat(chunks)
   local result = {
      path = path,
      method = method,
      status = status,
      headers = headers,
      bytesRead = bytesRead,
      truncated = truncated
   }
   if method == "GET" then
      local digest = hash(true, "hex")
      if truncated then result.excerptSha256 = digest else result.sha256 = digest end
      if contentType:lower():match("^text/") or
         contentType:lower():find("json", 1, true) or
         contentType:lower():find("xml", 1, true) or
         contentType:lower():find("javascript", 1, true) then
         result.bodyExcerpt = body
      end
   end
   return result
end

function Manager:_saveRequest(request, maxBytes)
   local declared = tonumber(request:header("Content-Length") or "")
   if declared and declared > maxBytes then return nil, "Upload exceeds size limit" end
   local path = "FuguHub-upload-" .. ticketId()
   local file, err = self.app.dataIo:open(path, "wb")
   if not file then return nil, tostring(err) end
   local size, hash = 0, ba.crypto.hash"sha256"
   local ok, result = pcall(function()
      for chunk in request:rawrdr() do
         size = size + #chunk
         assert(size <= maxBytes, "Upload exceeds size limit")
         hash(chunk)
         assert(file:write(chunk))
      end
      assert(size > 0, "Upload body is empty")
      assert(file:close())
      file = nil
   end)
   if file then pcall(function() file:close() end) end
   if not ok then self.app.dataIo:remove(path) return nil, tostring(result) end
   return { path = path, size = size, sha256 = hash(true, "hex") }
end

function Manager:_installUploadedAssetUnlocked(upload, ticket)
   if upload.size ~= ticket.expectedBytes or not mcpconfig.secureEqual(upload.sha256, ticket.sha256) then
      return nil, "Uploaded byte count or SHA-256 does not match the prepared descriptor"
   end
   local existing = self.app.assetsIo:stat(ticket.path)
   local current, digestErr
   if existing then
      if existing.isdir then return nil, "Asset path now conflicts with a directory" end
      current, digestErr = fileDigest(self.app.assetsIo, ticket.path, MAX_EXPANDED_BYTES)
      if not current then return nil, "Cannot verify current asset: " .. tostring(digestErr) end
   end
   if current ~= ticket.previousSha256 then
      return nil, "Asset changed after the upload was prepared"
   end
   local source, err = self.app.dataIo:open(upload.path, "rb")
   if not source then return nil, tostring(err) end
   local ok
   ok, err = atomicInstall(self.app.assetsIo, ticket.path, function(output)
      while true do
         local chunk, readErr = source:read(16384)
         if chunk and #chunk > 0 then assert(output:write(chunk))
         elseif readErr then error(readErr)
         else break end
      end
   end)
   source:close()
   if not ok then return nil, err end
   return mutationResult(self.app, ticket.path, ticket.previousSha256)
end

function Manager:_inspectZip(upload)
   local raw, rawErr = readFile(self.app.dataIo, upload.path, MAX_ARCHIVE_BYTES)
   if not raw then return nil, rawErr end
   local rawInfo
   rawInfo, rawErr = inspectRawZip(raw)
   if not rawInfo then return nil, rawErr end
   local zipIo, err = ba.mkio(self.app.dataIo, upload.path)
   if not zipIo then return nil, "Cannot open uploaded ZIP: " .. tostring(err) end
   local files, count, total = {}, 0, 0
   local ok, result = pcall(function()
      assert(collect(zipIo, "", true, files, MAX_ENTRIES + 1))
      assert(#files <= MAX_ENTRIES, "Archive exceeds entry limit")
      for _, item in ipairs(files) do
         local path, pathErr = normalizePath(item.path)
         assert(path, pathErr)
         count = count + 1
         if not item.directory then
            assert(item.size <= MAX_ENTRY_BYTES, "Archive entry exceeds size limit: " .. path)
            total = total + item.size
            assert(total <= MAX_EXPANDED_BYTES, "Archive exceeds expanded size limit")
            if assetClass(path) == "server-executable" then
               local text, readErr = readFile(zipIo, path, MAX_ENTRY_BYTES)
               assert(text, readErr)
               local valid, validationErr = validateCode(path, text)
               assert(valid, validationErr)
            end
         end
      end
      return true
   end)
   if zipIo.close then pcall(function() zipIo:close() end) end
   if not ok then return nil, tostring(result) end
   if count ~= rawInfo.entryCount or total ~= rawInfo.expandedBytes then
      return nil, "ZIP IO contents differ from the validated central directory"
   end
   return { entryCount = count, expandedBytes = total }
end

function Manager:_installAssetsZipUnlocked(upload, ticket)
   if upload.size ~= ticket.expectedBytes or not mcpconfig.secureEqual(upload.sha256, ticket.sha256) then
      return nil, "Uploaded byte count or SHA-256 does not match the prepared descriptor"
   end
   local current, digestErr
   if self.app.homeIo:stat(self.app.assetsZipName) then
      current, digestErr = fileDigest(self.app.homeIo, self.app.assetsZipName, MAX_ARCHIVE_BYTES)
      if not current then return nil, "Cannot verify current assets.zip: " .. tostring(digestErr) end
   end
   if current ~= ticket.previousSha256 then
      return nil, "assets.zip changed after the upload was prepared"
   end
   local inspected, err = self:_inspectZip(upload)
   if not inspected then return nil, err end
   local source
   source, err = self.app.dataIo:open(upload.path, "rb")
   if not source then return nil, tostring(err) end
   local ok
   ok, err = atomicInstall(self.app.homeIo, self.app.assetsZipName, function(output)
      while true do
         local chunk, readErr = source:read(16384)
         if chunk and #chunk > 0 then assert(output:write(chunk))
         elseif readErr then error(readErr)
         else break end
      end
   end)
   source:close()
   if not ok then return nil, err end
   return {
      installed = true,
      source = self.app.assetsZipName,
      sha256 = upload.sha256,
      byteLength = upload.size,
      entryCount = inspected.entryCount,
      expandedBytes = inspected.expandedBytes,
      restartRequired = true,
      activeSource = self.app.assetsSource
   }
end

function Manager:handle(request, response, authorized)
   self:_cleanup()
   if not authorized then return jsonResponse(response, 401, { ok = false, error = "Unauthorized" }) end
   local id = request:data("ticket")
   local ticket = id and self.tickets[id]
   if not ticket then return jsonResponse(response, 404, { ok = false, error = "Asset ticket is invalid, expired, or already used" }) end
   self.tickets[id] = nil
   if ticket.kind == "download" or ticket.kind == "assets-export" then
      if request:method() ~= "GET" then
         if ticket.tempPath then self.app.dataIo:remove(ticket.tempPath) end
         return jsonResponse(response, 405, { ok = false, error = "Download ticket requires GET" })
      end
      local file, err = self.app.dataIo:open(ticket.tempPath, "rb")
      if not file then return jsonResponse(response, 500, { ok = false, error = tostring(err) }) end
      response:setstatus(200)
      response:setcontenttype(ticket.contentType)
      response:setheader("Cache-Control", "no-store")
      response:setheader("Content-Length", tostring(ticket.size))
      response:setheader("X-FuguHub-SHA256", ticket.sha256)
      if ticket.kind == "assets-export" then
         response:setheader("Content-Disposition", 'attachment; filename="assets.zip"')
      end
      while true do
         local chunk = file:read(16384)
         if not chunk or #chunk == 0 then break end
         response:write(chunk)
      end
      file:close()
      self.app.dataIo:remove(ticket.tempPath)
      return
   end
   if request:method() ~= "POST" then return jsonResponse(response, 405, { ok = false, error = "Upload ticket requires POST" }) end
   local receivedType = tostring(request:header("Content-Type") or ""):lower():gsub("%s*;.*$", "")
   local requiredType = ticket.kind == "assets-import" and "application/zip" or ticket.contentType
   if receivedType ~= requiredType then
      return jsonResponse(response, 415, {
         ok = false,
         error = "Content-Type must be " .. tostring(requiredType)
      })
   end
   local upload, result, err
   local ok, failure = xpcall(function()
      upload, err = self:_saveRequest(request,
         ticket.kind == "assets-import" and MAX_ARCHIVE_BYTES or MAX_UPLOAD_BYTES)
      if upload then
         if ticket.kind == "assets-import" then result, err = self:_installAssetsZip(upload, ticket)
         else result, err = self:_installUploadedAsset(upload, ticket) end
      end
   end, function(value)
      return debug.traceback(value, 2)
   end)
   if upload then self.app.dataIo:remove(upload.path) end
   if not ok then err = failure end
   if not result then return jsonResponse(response, 400, { ok = false, error = tostring(err) }) end
   return jsonResponse(response, 200, { ok = true, result = result })
end

function Manager:writeText(args)
   return self:_mutate(function() return self:_writeText(args) end)
end

function Manager:createDirectory(args)
   return self:_mutate(function() return self:_createDirectory(args) end)
end

function Manager:move(args)
   return self:_mutate(function() return self:_move(args) end)
end

function Manager:delete(args)
   return self:_mutate(function() return self:_delete(args) end)
end

function Manager:_installUploadedAsset(upload, ticket)
   return self:_mutate(function() return self:_installUploadedAssetUnlocked(upload, ticket) end)
end

function Manager:_installAssetsZip(upload, ticket)
   return self:_mutate(function() return self:_installAssetsZipUnlocked(upload, ticket) end)
end

function Manager:close()
   for id, ticket in pairs(self.tickets) do
      if ticket.tempPath then pcall(function() self.app.dataIo:remove(ticket.tempPath) end) end
      self.tickets[id] = nil
   end
end

local function toolError(message, code, details)
   details = details or {}
   details.code = code or "assetOperationFailed"
   return FastMCP.error(message, details)
end

local function mutationResponse(result, err, code, details)
   if not result then return toolError(err, code, details) end
   return result
end

function M.register(mcp, app)
   local manager = setmetatable({
      app = app,
      tickets = {},
      ticketTtl = 5 * 60,
      mutationThread = ba.thread.create()
   }, Manager)
   local empty = { type = "object", properties = {}, additionalProperties = false }
   local read = { readOnlyHint = true, idempotentHint = true }
   local sha = { type = "string", minLength = 64, maxLength = 64 }

   mcp:tool("getAssetCapabilities", {
      description = "Report the active site assets source, writability, public path rule, limits, executable policy, and activation behavior. Site asset contents mount at the CMS root, not below /assets.",
      inputSchema = empty, annotations = read
   }, function() return manager:capabilities() end)

   mcp:tool("listAssets", {
      description = "List logical paths relative to the active site assets root. Files include their exact mount-aware publicUrl; use it instead of prepending /assets. SHA-256 is opt-in because hashing reads each file.",
      inputSchema = { type = "object", properties = {
         path = { type = "string", maxLength = 1024, default = "" },
         recursive = { type = "boolean", default = false },
         limit = { type = "integer", minimum = 1, maximum = 2000, default = 500 },
         includeSha256 = { type = "boolean", default = false }
      }, additionalProperties = false }, annotations = read
   }, function(args)
      local result, err = manager:list(args)
      return mutationResponse(result, err, "assetListFailed")
   end)

   mcp:tool("getAsset", {
      description = "Read one logical site asset and return its exact mount-aware publicUrl, or return metadata and a download hint for binary data.",
      inputSchema = { type = "object", properties = {
         path = { type = "string", minLength = 1, maxLength = 1024 }
      }, required = { "path" }, additionalProperties = false }, annotations = read
   }, function(args)
      local result, err, code, details = manager:get(args.path)
      return mutationResponse(result, err, code or "assetReadFailed", details)
   end)

   mcp:tool("getAssetDependencies", {
      description = "Perform bounded best-effort reference discovery before moving or deleting an asset. Dynamic references make this result incomplete.",
      inputSchema = { type = "object", properties = {
         path = { type = "string", minLength = 1, maxLength = 1024 }
      }, required = { "path" }, additionalProperties = false }, annotations = read
   }, function(args)
      local result, err, code, details = manager:dependencies(args.path)
      return mutationResponse(result, err, code or "assetDependencyScanFailed", details)
   end)

   mcp:tool("prepareAssetDownload", {
      description = "Prepare a bounded immutable one-time download for one active asset.",
      inputSchema = { type = "object", properties = {
         path = { type = "string", minLength = 1, maxLength = 1024 }
      }, required = { "path" }, additionalProperties = false }, annotations = read
   }, function(args, ctx)
      local result, err, code = manager:prepareDownload(args, ctx.serverOrigin)
      return mutationResponse(result, err, code)
   end)

   mcp:tool("validateAssetCode", {
      description = "Compile-validate proposed LSP, Lua module, .preload, or JSON text without saving or executing it.",
      inputSchema = { type = "object", properties = {
         path = { type = "string", minLength = 1, maxLength = 1024 },
         content = { type = "string", maxLength = MAX_TEXT_BYTES }
      }, required = { "path", "content" }, additionalProperties = false }, annotations = read
   }, function(args)
      local path, err = normalizePath(args.path)
      if not path then return toolError(err, "invalidAssetPath") end
      local result, details
      result, err, details = validateCode(path, args.content)
      return mutationResponse(result, err, "assetValidationFailed", details)
   end)

   mcp:tool("writeTextAsset", {
      description = "Create or replace a directory-backed text site asset using validation and optimistic concurrency. The result includes the exact publicUrl; do not prepend /assets. Server-executable LSP/Lua requires confirmedExecutable=true. Activate .lua and .preload changes with restartAssetsApplication.",
      inputSchema = { type = "object", properties = {
         path = { type = "string", minLength = 1, maxLength = 1024 },
         content = { type = "string", maxLength = MAX_TEXT_BYTES },
         expectedSha256 = sha,
         validateOnly = { type = "boolean", default = false },
         confirmedExecutable = { type = "boolean", default = false }
      }, required = { "path", "content" }, additionalProperties = false }
   }, function(args)
      local result, err, code, details = manager:writeText(args)
      return mutationResponse(result, err, code, details)
   end)

   mcp:tool("restartAssetsApplication", {
      description = "Unload the current assets application, discard its private module cache, rerun assets/.preload when present, and refresh the public LSP environment. Requires explicit confirmation.",
      inputSchema = { type = "object", properties = {
         confirmed = { type = "boolean" }
      }, required = { "confirmed" }, additionalProperties = false },
      annotations = { destructiveHint = true }
   }, function(args)
      if args.confirmed ~= true then
         return toolError(
            "Explicit confirmation is required to restart the assets application",
            "confirmationRequired"
         )
      end
      if type(app.restartAssetsApplication) ~= "function" then
         return toolError(
            "The assets application restart function is unavailable",
            "assetsRestartUnavailable"
         )
      end

      local result = app.restartAssetsApplication()
      if not result.ok then
         return toolError(
            result.loadError or "assets/.preload failed",
            "assetsPreloadFailed",
            result
         )
      end
      return result
   end)

   mcp:tool("prepareAssetUpload", {
      description = "Prepare a one-time direct binary upload with exact byte and SHA-256 verification. Use writeTextAsset for executable code.",
      inputSchema = { type = "object", properties = {
         path = { type = "string", minLength = 1, maxLength = 1024 },
         expectedBytes = { type = "integer", minimum = 1, maximum = MAX_UPLOAD_BYTES },
         sha256 = sha,
         contentType = { type = "string", minLength = 1, maxLength = 255 },
         expectedCurrentSha256 = sha
      }, required = { "path", "expectedBytes", "sha256", "contentType" }, additionalProperties = false }
   }, function(args, ctx)
      local result, err, code, details = manager:prepareUpload(args, ctx.serverOrigin)
      return mutationResponse(result, err, code, details)
   end)

   mcp:tool("createAssetDirectory", {
      description = "Idempotently create a directory and any missing parent directories under writable assets. An existing directory returns created=false and exists=true.",
      inputSchema = { type = "object", properties = {
         path = { type = "string", minLength = 1, maxLength = 1024 }
      }, required = { "path" }, additionalProperties = false }
   }, function(args)
      local result, err, code, details = manager:createDirectory(args)
      return mutationResponse(result, err, code, details)
   end)

   mcp:tool("testPublicPath", {
      description = "Perform a bounded same-origin GET or HEAD against one mount-aware public CMS path. For site assets, pass the exact publicUrl returned by an asset read/write tool. The request never targets admin/MCP routes, follows redirects, forwards credentials, or accesses another origin.",
      inputSchema = { type = "object", properties = {
         path = { type = "string", minLength = 1, maxLength = 2048 },
         method = { type = "string", enum = { "GET", "HEAD" }, default = "GET" },
         maxBytes = { type = "integer", minimum = 0, maximum = 262144, default = 32768 }
      }, required = { "path" }, additionalProperties = false }, annotations = read
   }, function(args, ctx)
      local result, err, code, details = manager:testPublicPath(args, ctx.serverOrigin)
      return mutationResponse(result, err, code, details)
   end)

   mcp:tool("moveAsset", {
      description = "Move one asset after dependency inspection and explicit user confirmation.",
      inputSchema = { type = "object", properties = {
         path = { type = "string", minLength = 1, maxLength = 1024 },
         newPath = { type = "string", minLength = 1, maxLength = 1024 },
         expectedSha256 = sha,
         confirmed = { type = "boolean" },
         confirmedExecutable = { type = "boolean", default = false }
      }, required = { "path", "newPath", "confirmed" }, additionalProperties = false },
      annotations = { destructiveHint = true }
   }, function(args)
      local result, err, code, details = manager:move(args)
      return mutationResponse(result, err, code, details)
   end)

   mcp:tool("deleteAsset", {
      description = "Delete one file or empty directory after dependency inspection and explicit user confirmation.",
      inputSchema = { type = "object", properties = {
         path = { type = "string", minLength = 1, maxLength = 1024 },
         expectedSha256 = sha,
         confirmed = { type = "boolean" }
      }, required = { "path", "confirmed" }, additionalProperties = false },
      annotations = { destructiveHint = true }
   }, function(args)
      local result, err, code, details = manager:delete(args)
      return mutationResponse(result, err, code, details)
   end)

   mcp:tool("prepareAssetsExport", {
      description = "Prepare a correctly rooted one-time ZIP snapshot of the active assets source.",
      inputSchema = empty, annotations = read
   }, function(_, ctx)
      local result, err, code = manager:prepareExport(ctx.serverOrigin)
      return mutationResponse(result, err, code)
   end)

   mcp:tool("prepareAssetsImport", {
      description = "Prepare a one-time assets.zip upload. The archive is validated and installed only after explicit confirmation; activation requires Mako restart.",
      inputSchema = { type = "object", properties = {
         expectedBytes = { type = "integer", minimum = 1, maximum = MAX_ARCHIVE_BYTES },
         sha256 = sha,
         expectedCurrentSha256 = sha,
         confirmed = { type = "boolean" }
      }, required = { "expectedBytes", "sha256", "confirmed" }, additionalProperties = false }
   }, function(args, ctx)
      local result, err, code, details = manager:prepareImport(args, ctx.serverOrigin)
      return mutationResponse(result, err, code, details)
   end)

   return manager
end

M.fileutil = {
   MAX_TEXT_BYTES = MAX_TEXT_BYTES,
   MAX_UPLOAD_BYTES = MAX_UPLOAD_BYTES,
   MAX_ARCHIVE_BYTES = MAX_ARCHIVE_BYTES,
   MAX_EXPANDED_BYTES = MAX_EXPANDED_BYTES,
   MAX_ENTRY_BYTES = MAX_ENTRY_BYTES,
   MAX_ENTRIES = MAX_ENTRIES,
   MAX_DEPTH = MAX_DEPTH,
   ticketId = ticketId,
   extension = extension,
   assetClass = assetClass,
   isText = isText,
   normalizePath = normalizePath,
   readFile = readFile,
   fileDigest = fileDigest,
   collect = collect,
   ensureParents = ensureParents,
   atomicInstall = atomicInstall,
   validateCode = validateCode,
   contentTypes = contentTypes,
   inspectRawZip = inspectRawZip
}

return M
