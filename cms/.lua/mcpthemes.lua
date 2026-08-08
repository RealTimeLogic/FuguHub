local FastMCP = require "fastmcp.engine"
local mcpassets = appreq "mcpassets"
local mcpconfig = appreq "mcpconfig"
local theme = appreq "theme"
local zipWriter = appreq "zip_writer"

local M = {}
local Manager = {}
Manager.__index = Manager

local util = mcpassets.fileutil
local DRAFT_ROOT = "FuguHub-theme-drafts"
local META_FILE = ".draft.json"
local TICKET_TTL = 5 * 60

local function normalizePath(value, allowEmpty)
   local path, err = util.normalizePath(value, allowEmpty)
   if not path then
      err = tostring(err):gsub("^Asset path", "Theme file path")
      return nil, err
   end
   return path
end

local function normalizeDraftId(value)
   local id = tostring(value or "")
   if #id < 16 or #id > 128 or not id:match("^[A-Za-z0-9_-]+$") then
      return nil, "Theme draft ID is invalid"
   end
   return id
end

local function contentType(path)
   return util.contentTypes[util.extension(path)] or "application/octet-stream"
end

local function closeIo(io)
   if io and io.close then pcall(function() io:close() end) end
end

local function ensureDirectory(io, path)
   local stat = io:stat(path)
   if stat then
      if stat.isdir then return true end
      return nil, path .. " conflicts with a file"
   end
   local ok, err = io:mkdir(path)
   if not ok then return nil, tostring(err) end
   return true
end

local function readJson(io, path)
   local text, err = util.readFile(io, path, 64 * 1024)
   if not text then return nil, err end
   local ok, decoded = pcall(ba.json.decode, text)
   if not ok or type(decoded) ~= "table" then
      return nil, "Theme draft metadata is corrupt"
   end
   return decoded
end

local function writeJson(io, path, value)
   local text = ba.json.encode(value)
   return util.atomicInstall(io, path, function(output)
      local ok, err = output:write(text)
      if not ok then error(err) end
   end)
end

local function collectFiles(io, includeMetadata)
   local raw = {}
   local ok, err = util.collect(io, "", true, raw, util.MAX_ENTRIES + 1)
   if not ok then return nil, err end
   if #raw > util.MAX_ENTRIES then return nil, "Theme exceeds the file-count limit" end
   local out, total = {}, 0
   for _, item in ipairs(raw) do
      if includeMetadata or item.path ~= META_FILE then
         if not item.directory then
            if item.size > util.MAX_ENTRY_BYTES then
               return nil, "Theme file exceeds the size limit: " .. item.path
            end
            total = total + item.size
            if total > util.MAX_EXPANDED_BYTES then
               return nil, "Theme exceeds the expanded-size limit"
            end
         end
         out[#out + 1] = item
      end
   end
   table.sort(out, function(a, b) return a.path < b.path end)
   return out, total
end

local function fingerprint(io)
   local files, err = collectFiles(io, false)
   if not files then return nil, err end
   local hash = ba.crypto.hash"sha256"
   for _, item in ipairs(files) do
      hash(item.directory and "D\0" or "F\0")
      hash(item.path)
      hash("\0")
      if not item.directory then
         local file, openErr = io:open(item.path, "rb")
         if not file then return nil, tostring(openErr) end
         while true do
            local chunk, readErr = file:read(16384)
            if chunk and #chunk > 0 then hash(chunk)
            elseif readErr then file:close() return nil, tostring(readErr)
            else break end
         end
         file:close()
      end
      hash("\0")
   end
   return hash(true, "hex")
end

local function copyTree(sourceIo, destinationIo)
   local files, err = collectFiles(sourceIo, false)
   if not files then return nil, err end
   for _, item in ipairs(files) do
      if item.directory then
         local ok
         ok, err = ensureDirectory(destinationIo, item.path)
         if not ok then return nil, err end
      else
         local source
         source, err = sourceIo:open(item.path, "rb")
         if not source then return nil, tostring(err) end
         local ok
         ok, err = util.atomicInstall(destinationIo, item.path, function(output)
            while true do
               local chunk, readErr = source:read(16384)
               if chunk and #chunk > 0 then
                  local wrote, writeErr = output:write(chunk)
                  if not wrote then error(writeErr) end
               elseif readErr then
                  error(readErr)
               else
                  break
               end
            end
         end)
         source:close()
         if not ok then return nil, err end
      end
   end
   return true
end

local function removeTree(io)
   local files, err = collectFiles(io, true)
   if not files then return nil, err end
   table.sort(files, function(a, b)
      if #a.path == #b.path then return a.path > b.path end
      return #a.path > #b.path
   end)
   for _, item in ipairs(files) do
      local ok
      if item.directory then ok, err = io:rmdir(item.path)
      else ok, err = io:remove(item.path) end
      if not ok then return nil, tostring(err) end
   end
   return true
end

local function fileMetadata(io, path, stat, includeDigest)
   stat = stat or io:stat(path)
   if not stat then return nil end
   local result = {
      path = path,
      directory = stat.isdir == true,
      byteLength = stat.isdir and 0 or tonumber(stat.size or 0),
      modifiedAt = tonumber(stat.mtime or 0),
      text = not stat.isdir and util.isText(path) or false,
      executable = not stat.isdir and util.assetClass(path) == "server-executable" or false
   }
   if not stat.isdir and includeDigest ~= false then
      local digest, size = util.fileDigest(io, path, util.MAX_EXPANDED_BYTES)
      if digest then
         result.sha256 = digest
         result.byteLength = size
      end
   end
   return result
end

function Manager:_draftPath(id)
   return DRAFT_ROOT .. "/" .. id
end

function Manager:_openDraft(value)
   local id, err = normalizeDraftId(value)
   if not id then return nil, err, "invalidThemeDraftId" end
   local path = self:_draftPath(id)
   local stat = self.app.dataIo:stat(path)
   if not stat or not stat.isdir then
      return nil, "Theme draft was not found", "themeDraftNotFound"
   end
   local draftIo
   draftIo, err = ba.mkio(self.app.dataIo, path)
   if not draftIo then return nil, tostring(err), "themeDraftOpenFailed" end
   local metadata
   metadata, err = readJson(draftIo, META_FILE)
   if not metadata then
      closeIo(draftIo)
      return nil, err, "themeDraftCorrupt"
   end
   local name
   name, err = theme.normalizeName(metadata.name)
   if not name then
      closeIo(draftIo)
      return nil, "Theme draft metadata has an invalid name", "themeDraftCorrupt"
   end
   metadata.name = name
   return {
      id = id,
      path = path,
      io = draftIo,
      metadata = metadata
   }
end

function Manager:_installed(name)
   local info, err = theme.open(self.app, name)
   if not info then return nil, err end
   return info
end

function Manager:createDraft(args)
   local name, err = theme.normalizeName(args.name)
   if not name then return nil, err, "invalidThemeName" end
   local fromTheme
   if args.fromTheme ~= nil then
      fromTheme, err = theme.normalizeName(args.fromTheme)
      if not fromTheme then return nil, err, "invalidThemeName" end
   end

   local targetInfo = theme.open(self.app, name)
   if targetInfo and not fromTheme then
      closeIo(targetInfo.io)
      return nil, "Theme already exists; specify fromTheme to create a modification draft",
         "themeAlreadyExists", { name = name }
   end
   if targetInfo and fromTheme ~= name then
      closeIo(targetInfo.io)
      return nil, "Target theme already exists and can only be modified from itself",
         "themeAlreadyExists", { name = name }
   end

   local sourceInfo
   if fromTheme then
      sourceInfo, err = self:_installed(fromTheme)
      if not sourceInfo then
         if targetInfo then closeIo(targetInfo.io) end
         return nil, err, "themeNotFound", { name = fromTheme }
      end
   end

   local sourceFingerprint
   if targetInfo then
      sourceFingerprint, err = fingerprint(targetInfo.io)
      closeIo(targetInfo.io)
      if not sourceFingerprint then
         if sourceInfo then closeIo(sourceInfo.io) end
         return nil, err, "themeFingerprintFailed"
      end
   end

   local ok
   ok, err = ensureDirectory(self.app.dataIo, DRAFT_ROOT)
   if not ok then
      if sourceInfo then closeIo(sourceInfo.io) end
      return nil, err, "themeDraftCreateFailed"
   end
   local id = util.ticketId()
   local path = self:_draftPath(id)
   ok, err = self.app.dataIo:mkdir(path)
   if not ok then
      if sourceInfo then closeIo(sourceInfo.io) end
      return nil, tostring(err), "themeDraftCreateFailed"
   end
   local draftIo
   draftIo, err = ba.mkio(self.app.dataIo, path)
   if not draftIo then
      self.app.dataIo:rmdir(path)
      if sourceInfo then closeIo(sourceInfo.io) end
      return nil, tostring(err), "themeDraftCreateFailed"
   end

   if sourceInfo then
      ok, err = copyTree(sourceInfo.io, draftIo)
      closeIo(sourceInfo.io)
      if not ok then
         removeTree(draftIo)
         closeIo(draftIo)
         self.app.dataIo:rmdir(path)
         return nil, err, "themeDraftCreateFailed"
      end
   end

   local now = os.time()
   local metadata = {
      id = id,
      name = name,
      fromTheme = fromTheme,
      targetExisted = sourceFingerprint ~= nil,
      sourceFingerprint = sourceFingerprint,
      createdAt = now,
      updatedAt = now
   }
   ok, err = writeJson(draftIo, META_FILE, metadata)
   closeIo(draftIo)
   if not ok then
      local cleanupIo = ba.mkio(self.app.dataIo, path)
      if cleanupIo then removeTree(cleanupIo) closeIo(cleanupIo) end
      self.app.dataIo:rmdir(path)
      return nil, err, "themeDraftCreateFailed"
   end
   return metadata
end

function Manager:listDrafts()
   local out = {}
   local root = self.app.dataIo:stat(DRAFT_ROOT)
   if not root or not root.isdir then return { drafts = out } end
   for id, isdir in self.app.dataIo:files(DRAFT_ROOT, true) do
      if isdir and id ~= "." and id ~= ".." then
         local draft = self:_openDraft(id)
         if draft then
            out[#out + 1] = draft.metadata
            closeIo(draft.io)
         end
      end
   end
   table.sort(out, function(a, b)
      if a.createdAt == b.createdAt then return a.id < b.id end
      return tonumber(a.createdAt or 0) < tonumber(b.createdAt or 0)
   end)
   return { drafts = out }
end

local function listIo(io, args)
   local directory, err = normalizePath(args.path or "", true)
   if not directory then return nil, err, "invalidThemePath" end
   local stat = directory ~= "" and io:stat(directory) or { isdir = true }
   if not stat or not stat.isdir then
      return nil, "Theme directory was not found", "themeDirectoryNotFound"
   end
   local limit = math.floor(tonumber(args.limit) or 500)
   if limit < 1 or limit > 2000 then
      return nil, "Theme list limit must be between 1 and 2000", "invalidThemeLimit"
   end
   local found = {}
   local ok
   ok, err = util.collect(io, directory, args.recursive == true, found, limit + 2)
   if not ok then return nil, err, "themeListFailed" end
   local items = {}
   for _, entry in ipairs(found) do
      if entry.path ~= META_FILE then
         items[#items + 1] = fileMetadata(io, entry.path, {
             isdir = entry.directory,
             size = entry.size,
             mtime = entry.mtime
         }, args.includeSha256 == true)
         if #items > limit then break end
      end
   end
   local truncated = #items > limit
   if truncated then items[#items] = nil end
   return { path = directory, items = items, truncated = truncated }
end

function Manager:listInstalled(args)
   local info, err = self:_installed(args.name)
   if not info then return nil, err, "themeNotFound" end
   local result, listErr, code = listIo(info.io, args)
   closeIo(info.io)
   if result then
      result.name = info.name
      result.source = info.source
   end
   return result, listErr, code
end

function Manager:listDraftFiles(args)
   local draft, err, code = self:_openDraft(args.draftId)
   if not draft then return nil, err, code end
   local result, listErr, listCode = listIo(draft.io, args)
   closeIo(draft.io)
   if result then
      result.draftId = draft.id
      result.name = draft.metadata.name
   end
   return result, listErr, listCode
end

local function getIoFile(io, path)
   local normalized, err = normalizePath(path)
   if not normalized then return nil, err, "invalidThemePath" end
   if normalized == META_FILE then return nil, "Theme draft metadata is private", "themePathReserved" end
   local stat = io:stat(normalized)
   if not stat then return nil, "Theme file was not found", "themeFileNotFound" end
   if stat.isdir then return nil, "Theme path is a directory", "themeTypeMismatch" end
   local item = fileMetadata(io, normalized, stat)
   if util.isText(normalized) then
      local content
      content, err = util.readFile(io, normalized, util.MAX_TEXT_BYTES)
      if not content then return nil, err, "themeReadFailed" end
      item.content = content
      item.encoding = "utf-8"
   else
      item.contentAvailableByDownload = true
   end
   return item
end

function Manager:getInstalled(args)
   local info, err = self:_installed(args.name)
   if not info then return nil, err, "themeNotFound" end
   local result, getErr, code = getIoFile(info.io, args.path)
   closeIo(info.io)
   if result then
      result.name = info.name
      result.source = info.source
   end
   return result, getErr, code
end

function Manager:getDraft(args)
   local draft, err, code = self:_openDraft(args.draftId)
   if not draft then return nil, err, code end
   local result, getErr, getCode = getIoFile(draft.io, args.path)
   closeIo(draft.io)
   if result then
      result.draftId = draft.id
      result.name = draft.metadata.name
   end
   return result, getErr, getCode
end

function Manager:writeDraftText(args)
   local draft, err, code = self:_openDraft(args.draftId)
   if not draft then return nil, err, code end
   local path
   path, err = normalizePath(args.path)
   if not path then closeIo(draft.io) return nil, err, "invalidThemePath" end
   if path == META_FILE then
      closeIo(draft.io)
      return nil, "Theme draft metadata is private", "themePathReserved"
   end
   if not util.isText(path) then
      closeIo(draft.io)
      return nil, "writeThemeDraftText accepts text file types only", "themeTypeMismatch"
   end
   local content = tostring(args.content or "")
   if #content > util.MAX_TEXT_BYTES then
      closeIo(draft.io)
      return nil, "Theme text exceeds the size limit", "themeFileTooLarge"
   end
   local executable = util.assetClass(path) == "server-executable"
   if executable and args.confirmedExecutable ~= true then
      closeIo(draft.io)
      return nil, "Executable theme LSP requires explicit confirmation",
         "executableConfirmationRequired"
   end
   local validation, validationErr, validationDetails = util.validateCode(path, content)
   if not validation then
      closeIo(draft.io)
      return nil, validationErr, "themeValidationFailed", validationDetails
   end
   local stat = draft.io:stat(path)
   local previousSha
   if stat then
      if stat.isdir then
         closeIo(draft.io)
         return nil, "Theme path conflicts with a directory", "themePathConflict"
      end
      previousSha = util.fileDigest(draft.io, path, util.MAX_EXPANDED_BYTES)
      if not args.expectedSha256 then
         closeIo(draft.io)
         return nil, "expectedSha256 is required when replacing a theme file", "themeConflict"
      end
      if not mcpconfig.secureEqual(previousSha, tostring(args.expectedSha256):lower()) then
         closeIo(draft.io)
         return nil, "Theme file changed after it was read", "themeConflict", {
            currentSha256 = previousSha
         }
      end
   elseif args.expectedSha256 then
      closeIo(draft.io)
      return nil, "Theme file no longer exists", "themeConflict"
   end
   local proposedSha = ba.crypto.hash"sha256"(content)(true, "hex")
   if args.validateOnly == true then
      closeIo(draft.io)
      return {
         valid = true,
         draftId = draft.id,
         name = draft.metadata.name,
         path = path,
         previousSha256 = previousSha,
         proposedSha256 = proposedSha,
         byteLength = #content,
         validation = validation
      }
   end
   local ok
   ok, err = util.atomicInstall(draft.io, path, function(output)
      local wrote, writeErr = output:write(content)
      if not wrote then error(writeErr) end
   end)
   if not ok then closeIo(draft.io) return nil, err, "themeWriteFailed" end
   draft.metadata.updatedAt = os.time()
   ok, err = writeJson(draft.io, META_FILE, draft.metadata)
   closeIo(draft.io)
   if not ok then return nil, err, "themeDraftMetadataWriteFailed" end
   return {
      draftId = draft.id,
      name = draft.metadata.name,
      path = path,
      previousSha256 = previousSha,
      sha256 = proposedSha,
      byteLength = #content,
      executable = executable,
      validationWarnings = validation.warnings
   }
end

function Manager:deleteDraftFile(args)
   if args.confirmed ~= true then
      return nil, "Deleting a theme draft file requires explicit confirmation",
         "confirmationRequired"
   end
   local draft, err, code = self:_openDraft(args.draftId)
   if not draft then return nil, err, code end
   local path
   path, err = normalizePath(args.path)
   if not path then closeIo(draft.io) return nil, err, "invalidThemePath" end
   if path == META_FILE then
      closeIo(draft.io)
      return nil, "Theme draft metadata is private", "themePathReserved"
   end
   local stat = draft.io:stat(path)
   if not stat then closeIo(draft.io) return nil, "Theme file was not found", "themeFileNotFound" end
   local ok
   if stat.isdir then
      local entries = {}
      util.collect(draft.io, path, false, entries, 1)
      if #entries > 0 then
         closeIo(draft.io)
         return nil, "Only empty theme draft directories may be deleted",
            "themeDirectoryNotEmpty"
      end
      ok, err = draft.io:rmdir(path)
   else
      local current = util.fileDigest(draft.io, path, util.MAX_EXPANDED_BYTES)
      if not args.expectedSha256 or
         not mcpconfig.secureEqual(current, tostring(args.expectedSha256):lower()) then
         closeIo(draft.io)
         return nil, "Theme file changed after it was read", "themeConflict", {
            currentSha256 = current
         }
      end
      ok, err = draft.io:remove(path)
   end
   if not ok then closeIo(draft.io) return nil, tostring(err), "themeDeleteFailed" end
   draft.metadata.updatedAt = os.time()
   ok, err = writeJson(draft.io, META_FILE, draft.metadata)
   closeIo(draft.io)
   if not ok then return nil, err, "themeDraftMetadataWriteFailed" end
   return { deleted = true, draftId = draft.id, name = draft.metadata.name, path = path }
end

function Manager:validateDraft(args)
   local draft, err, code = self:_openDraft(args.draftId)
   if not draft then return nil, err, code end
   local result
   result, err = theme.validateIo(draft.io, draft.metadata.name, "draft")
   local draftFingerprint, fingerprintErr = fingerprint(draft.io)
   closeIo(draft.io)
   if not result then return nil, err, "themeValidationFailed" end
   if not draftFingerprint then return nil, fingerprintErr, "themeFingerprintFailed" end
   result.draftId = draft.id
   result.fingerprint = draftFingerprint
   return result
end

function Manager:_packageIo(sourceIo, name)
   local files, expanded = collectFiles(sourceIo, false)
   if not files then return nil, expanded end
   local entries = {}
   for _, item in ipairs(files) do
      if item.directory then
         entries[#entries + 1] = {
            path = item.path,
            directory = true,
            mtime = item.mtime
         }
      else
         entries[#entries + 1] = {
            path = item.path,
            source = { io = sourceIo, path = item.path },
            mtime = item.mtime
         }
      end
   end
   local tempPath = "FuguHub-theme-package-" .. util.ticketId() .. ".zip"
   local output, err = self.app.dataIo:open(tempPath, "wb")
   if not output then return nil, tostring(err) end
   local hash = ba.crypto.hash"sha256"
   local info
   info, err = zipWriter.write(entries, function(chunk)
      hash(chunk)
      return output:write(chunk)
   end, {
      compress = true,
      maxEntries = util.MAX_ENTRIES,
      maxDepth = util.MAX_DEPTH,
      maxEntryBytes = util.MAX_ENTRY_BYTES,
      maxArchiveBytes = util.MAX_ARCHIVE_BYTES
   })
   local closeOk, closeErr = output:close()
   if not info or closeOk == false then
      self.app.dataIo:remove(tempPath)
      return nil, tostring(err or closeErr)
   end
   local packageIo
   packageIo, err = ba.mkio(self.app.dataIo, tempPath)
   if not packageIo then
      self.app.dataIo:remove(tempPath)
      return nil, "Cannot open staged theme ZIP: " .. tostring(err)
   end
   local validated
   validated, err = theme.validateIo(packageIo, name, "zip")
   closeIo(packageIo)
   if not validated then
      self.app.dataIo:remove(tempPath)
      return nil, err
   end
   return {
      tempPath = tempPath,
      size = info.size,
      sha256 = hash(true, "hex"),
      entryCount = info.entryCount,
      expandedBytes = expanded,
      validation = validated
   }
end

function Manager:_targetState(name)
   local zipExists = self.app.themesIo:stat(name .. ".zip") ~= nil
   local directoryExists = self.app.themesIo:stat(name) ~= nil
   if not zipExists and not directoryExists then return { exists = false } end
   local info, err = theme.open(self.app, name)
   if not info then return nil, err end
   local current
   current, err = fingerprint(info.io)
   closeIo(info.io)
   if not current then return nil, err end
   return {
      exists = true,
      source = info.source,
      fingerprint = current
   }
end

function Manager:_installPackageFile(tempPath, name, source)
   local err
   if not source then source, err = self.app.dataIo:open(tempPath, "rb") end
   if not source then return nil, tostring(err) end
   local ok
   ok, err = util.atomicInstall(self.app.themesIo, name .. ".zip", function(output)
      while true do
         local chunk, readErr = source:read(16384)
         if chunk and #chunk > 0 then
            local wrote, writeErr = output:write(chunk)
            if not wrote then error(writeErr) end
         elseif readErr then error(readErr)
         else break end
      end
   end)
   source:close()
   return ok, err
end

function Manager:_reactivate(name)
   local activated
   local ok, err = pcall(function() activated = theme.activate(self.app, name) end)
   if not ok then return nil, tostring(err) end
   if self.app.invalidateRuntime then self.app.invalidateRuntime() end
   return activated
end

function Manager:_restoreActive(name, previousSource, rollbackPackage)
   local restored, err
   if previousSource == "zip" then
      if not rollbackPackage then return nil, "Active ZIP rollback package is missing" end
      restored, err = self:_installPackageFile(rollbackPackage.tempPath, name)
   else
      restored, err = self.app.themesIo:remove(name .. ".zip")
   end
   if not restored then return nil, tostring(err) end
   local activated
   activated, err = self:_reactivate(name)
   if not activated then return nil, err end
   return true
end

function Manager:_commitDraft(args)
   if args.confirmed ~= true then
      return nil, "Committing a theme draft requires explicit confirmation",
         "confirmationRequired"
   end
   if args.confirmedExecutable ~= true then
      return nil, "Theme packages contain executable LSP and require executable confirmation",
         "executableConfirmationRequired"
   end
   local draft, err, code = self:_openDraft(args.draftId)
   if not draft then return nil, err, code end
   local name = draft.metadata.name
   local isActiveTarget = self.app.theme and self.app.theme.name == name or false
   local currentFingerprint
   currentFingerprint, err = fingerprint(draft.io)
   if not currentFingerprint then
      closeIo(draft.io)
      return nil, err, "themeFingerprintFailed"
   end
   if not args.expectedFingerprint or
      not mcpconfig.secureEqual(currentFingerprint, tostring(args.expectedFingerprint):lower()) then
      closeIo(draft.io)
      return nil, "Theme draft changed after validation", "themeDraftConflict", {
         currentFingerprint = currentFingerprint
      }
   end
   local validated
   validated, err = theme.validateIo(draft.io, name, "draft")
   if not validated then
      closeIo(draft.io)
      return nil, err, "themeValidationFailed"
   end
   local target
   target, err = self:_targetState(name)
   if not target then
      closeIo(draft.io)
      return nil, err, "themeFingerprintFailed"
   end
   local expectedTarget = draft.metadata.targetExisted == true
   if target.exists ~= expectedTarget then
      closeIo(draft.io)
      return nil, "Installed theme existence changed after the draft was created",
         "themeConflict", { targetExists = target.exists }
   end
   if target.exists and
      not mcpconfig.secureEqual(
         tostring(target.fingerprint),
         tostring(draft.metadata.sourceFingerprint or "")
      ) then
      closeIo(draft.io)
      return nil, "Installed theme changed after the draft was created",
         "themeConflict", { currentFingerprint = target.fingerprint }
   end
   local package
   package, err = self:_packageIo(draft.io, name)
   closeIo(draft.io)
   if not package then return nil, err, "themePackageFailed" end

   local rollbackPackage
   if isActiveTarget and target.source == "zip" then
      rollbackPackage, err = self:_packageIo(self.app.theme.io, name)
      if not rollbackPackage then
         self.app.dataIo:remove(package.tempPath)
         return nil, err, "themeRollbackPackageFailed"
      end
   end

   local source
   source, err = self.app.dataIo:open(package.tempPath, "rb")
   if not source then
      self.app.dataIo:remove(package.tempPath)
      if rollbackPackage then self.app.dataIo:remove(rollbackPackage.tempPath) end
      return nil, tostring(err), "themePackageInstallFailed"
   end
   if isActiveTarget then theme.deactivate(self.app) end

   local ok
   ok, err = self:_installPackageFile(package.tempPath, name, source)
   self.app.dataIo:remove(package.tempPath)
   if not ok then
      local restored, restoreErr
      if isActiveTarget then restored, restoreErr = self:_reactivate(name) end
      if rollbackPackage then self.app.dataIo:remove(rollbackPackage.tempPath) end
      return nil, err, "themePackageInstallFailed", {
         previousThemeRestored = isActiveTarget and restored ~= nil or nil,
         restoreError = restoreErr
      }
   end

   local installed
   if isActiveTarget then
      installed, err = self:_reactivate(name)
      if not installed then
         local restored, restoreErr = self:_restoreActive(
            name, target.source, rollbackPackage
         )
         if rollbackPackage then self.app.dataIo:remove(rollbackPackage.tempPath) end
         return nil, "Active theme reload failed: " .. tostring(err),
            "themeActiveReloadFailed", {
               previousThemeRestored = restored == true,
               restoreError = restoreErr
            }
      end
   else
      installed, err = theme.validate(self.app, name)
   end
   if rollbackPackage then self.app.dataIo:remove(rollbackPackage.tempPath) end
   if not installed then
      return nil, "Installed theme failed post-install validation: " .. tostring(err),
         "themePostInstallValidationFailed"
   end
   return {
      committed = true,
      draftId = args.draftId,
      name = name,
      source = "zip",
      sha256 = package.sha256,
      byteLength = package.size,
      expandedBytes = package.expandedBytes,
      entryCount = package.entryCount,
      active = isActiveTarget,
      activationRequired = not isActiveTarget,
      reloaded = isActiveTarget,
      reloadRequired = false
   }
end

function Manager:commitDraft(args)
   if self.mutationActive then
      return nil, "Another theme mutation is active", "themeMutationInProgress"
   end
   self.mutationActive = true
   local result
   local ok, a, b, c, d = xpcall(function()
      return self:_commitDraft(args)
   end, function(value)
      return debug.traceback(value, 2)
   end)
   self.mutationActive = false
   if not ok then return nil, a, "themeCommitFailed" end
   result = a
   return result, b, c, d
end

function Manager:prepareInstalledDownload(args, serverOrigin)
   local info, err = self:_installed(args.name)
   if not info then return nil, err, "themeNotFound" end
   local path
   path, err = normalizePath(args.path)
   if not path then closeIo(info.io) return nil, err, "invalidThemePath" end
   local stat = info.io:stat(path)
   if not stat or stat.isdir then
      closeIo(info.io)
      return nil, "Theme file was not found", "themeFileNotFound"
   end
   local snapshot
   snapshot, err = self:_snapshotDraftFile({ io = info.io }, path)
   closeIo(info.io)
   if not snapshot then return nil, err, "themeDownloadFailed" end
   snapshot.contentType = contentType(path)
   snapshot.path = path
   snapshot.name = args.name
   local id, ticket = self:_newTicket("installed-download", snapshot)
   return {
      downloadUrl = serverOrigin .. self.app.url("/mcp/themes?ticket=" .. id),
      expiresAt = ticket.expiresAt,
      expiresInSeconds = TICKET_TTL,
      expectedBytes = ticket.size,
      digest = "sha256:" .. ticket.sha256,
      contentType = ticket.contentType,
      path = path,
      name = args.name,
      oneUse = true
   }
end

function Manager:prepareExport(args, serverOrigin)
   local info, err = self:_installed(args.name)
   if not info then return nil, err, "themeNotFound" end
   local package
   package, err = self:_packageIo(info.io, info.name)
   closeIo(info.io)
   if not package then return nil, err, "themeExportFailed" end
   local id, ticket = self:_newTicket("theme-export", {
      tempPath = package.tempPath,
      size = package.size,
      sha256 = package.sha256,
      contentType = "application/zip",
      name = args.name,
      entryCount = package.entryCount,
      expandedBytes = package.expandedBytes
   })
   return {
      downloadUrl = serverOrigin .. self.app.url("/mcp/themes?ticket=" .. id),
      expiresAt = ticket.expiresAt,
      expiresInSeconds = TICKET_TTL,
      expectedBytes = ticket.size,
      digest = "sha256:" .. ticket.sha256,
      contentType = ticket.contentType,
      name = args.name,
      entryCount = ticket.entryCount,
      expandedBytes = ticket.expandedBytes,
      oneUse = true
   }
end

function Manager:discardDraft(args)
   if args.confirmed ~= true then
      return nil, "Discarding a theme draft requires explicit confirmation",
         "confirmationRequired"
   end
   local draft, err, code = self:_openDraft(args.draftId)
   if not draft then return nil, err, code end
   local ok
   ok, err = removeTree(draft.io)
   closeIo(draft.io)
   if not ok then return nil, err, "themeDraftDiscardFailed" end
   ok, err = self.app.dataIo:rmdir(draft.path)
   if not ok then return nil, tostring(err), "themeDraftDiscardFailed" end
   return { discarded = true, draftId = draft.id, name = draft.metadata.name }
end

function Manager:_cleanupTickets()
   local now = os.time()
   for id, ticket in pairs(self.tickets) do
      if ticket.expiresAt <= now then
         if ticket.tempPath then pcall(function() self.app.dataIo:remove(ticket.tempPath) end) end
         self.tickets[id] = nil
      end
   end
end

function Manager:_newTicket(kind, data)
   self:_cleanupTickets()
   local id = util.ticketId()
   data.kind = kind
   data.expiresAt = os.time() + TICKET_TTL
   self.tickets[id] = data
   return id, data
end

function Manager:prepareDraftUpload(args, serverOrigin)
   local draft, err, code = self:_openDraft(args.draftId)
   if not draft then return nil, err, code end
   local path
   path, err = normalizePath(args.path)
   if not path then closeIo(draft.io) return nil, err, "invalidThemePath" end
   if path == META_FILE then
      closeIo(draft.io)
      return nil, "Theme draft metadata is private", "themePathReserved"
   end
   if util.isText(path) then
      closeIo(draft.io)
      return nil, "Use writeThemeDraftText for text theme files", "themeTypeMismatch"
   end
   local expectedBytes = tonumber(args.expectedBytes)
   if not expectedBytes or expectedBytes < 1 or expectedBytes % 1 ~= 0 or
      expectedBytes > util.MAX_UPLOAD_BYTES then
      closeIo(draft.io)
      return nil, "expectedBytes is invalid", "invalidThemeUpload"
   end
   local sha = tostring(args.sha256 or ""):lower()
   if not sha:match("^[0-9a-f]+$") or #sha ~= 64 then
      closeIo(draft.io)
      return nil, "sha256 is invalid", "invalidThemeUpload"
   end
   local declaredType = tostring(args.contentType or ""):lower():gsub("%s*;.*$", "")
   local expectedType = contentType(path):lower():gsub("%s*;.*$", "")
   if expectedType ~= "application/octet-stream" and declaredType ~= expectedType then
      closeIo(draft.io)
      return nil, "contentType does not match the theme file extension", "themeTypeMismatch"
   end
   local stat = draft.io:stat(path)
   local current
   if stat then
      if stat.isdir then
         closeIo(draft.io)
         return nil, "Theme path conflicts with a directory", "themePathConflict"
      end
      current = util.fileDigest(draft.io, path, util.MAX_EXPANDED_BYTES)
      if not args.expectedCurrentSha256 or
         not mcpconfig.secureEqual(current, tostring(args.expectedCurrentSha256):lower()) then
         closeIo(draft.io)
         return nil, "Theme file changed after it was read", "themeConflict", {
            currentSha256 = current
         }
      end
   elseif args.expectedCurrentSha256 then
      closeIo(draft.io)
      return nil, "Theme file no longer exists", "themeConflict"
   end
   closeIo(draft.io)
   local id, ticket = self:_newTicket("draft-upload", {
      draftId = args.draftId,
      path = path,
      expectedBytes = expectedBytes,
      sha256 = sha,
      contentType = declaredType,
      previousSha256 = current
   })
   return {
      uploadUrl = serverOrigin .. self.app.url("/mcp/themes?ticket=" .. id),
      expiresAt = ticket.expiresAt,
      expiresInSeconds = TICKET_TTL,
      expectedBytes = expectedBytes,
      digest = "sha256:" .. sha,
      contentType = declaredType,
      path = path,
      draftId = args.draftId,
      method = "POST",
      oneUse = true,
      redirectPolicy = "do-not-follow",
      requiredHeaders = FastMCP.array {
         "Authorization: Bearer <the configured MCP token>",
         "Content-Type: " .. declaredType,
         "Content-Length: " .. tostring(expectedBytes)
      }
   }
end

function Manager:_snapshotDraftFile(draft, path)
   local source, err = draft.io:open(path, "rb")
   if not source then return nil, tostring(err) end
   local tempPath = "FuguHub-theme-file-" .. util.ticketId()
   local output
   output, err = self.app.dataIo:open(tempPath, "wb")
   if not output then source:close() return nil, tostring(err) end
   local size, hash = 0, ba.crypto.hash"sha256"
   local ok, failure = pcall(function()
      while true do
         local chunk, readErr = source:read(16384)
         if chunk and #chunk > 0 then
            size = size + #chunk
            if size > util.MAX_UPLOAD_BYTES then error("Theme file exceeds download limit") end
            hash(chunk)
            local wrote, writeErr = output:write(chunk)
            if not wrote then error(writeErr) end
         elseif readErr then error(readErr)
         else break end
      end
      local closeOk, closeErr = output:close()
      if closeOk == false then error(closeErr) end
      output = nil
   end)
   source:close()
   if output then pcall(function() output:close() end) end
   if not ok then
      self.app.dataIo:remove(tempPath)
      return nil, tostring(failure)
   end
   return {
      tempPath = tempPath,
      size = size,
      sha256 = hash(true, "hex")
   }
end

function Manager:prepareDraftDownload(args, serverOrigin)
   local draft, err, code = self:_openDraft(args.draftId)
   if not draft then return nil, err, code end
   local path
   path, err = normalizePath(args.path)
   if not path then closeIo(draft.io) return nil, err, "invalidThemePath" end
   if path == META_FILE then
      closeIo(draft.io)
      return nil, "Theme draft metadata is private", "themePathReserved"
   end
   local stat = draft.io:stat(path)
   if not stat or stat.isdir then
      closeIo(draft.io)
      return nil, "Theme file was not found", "themeFileNotFound"
   end
   local snapshot
   snapshot, err = self:_snapshotDraftFile(draft, path)
   closeIo(draft.io)
   if not snapshot then return nil, err, "themeDownloadFailed" end
   snapshot.contentType = contentType(path)
   snapshot.path = path
   snapshot.draftId = args.draftId
   local id, ticket = self:_newTicket("draft-download", snapshot)
   return {
      downloadUrl = serverOrigin .. self.app.url("/mcp/themes?ticket=" .. id),
      expiresAt = ticket.expiresAt,
      expiresInSeconds = TICKET_TTL,
      expectedBytes = ticket.size,
      digest = "sha256:" .. ticket.sha256,
      contentType = ticket.contentType,
      path = path,
      draftId = args.draftId,
      oneUse = true
   }
end

function Manager:_saveRequest(request)
   local declared = tonumber(request:header("Content-Length") or "")
   if declared and declared > util.MAX_UPLOAD_BYTES then
      return nil, "Upload exceeds size limit"
   end
   local path = "FuguHub-theme-upload-" .. util.ticketId()
   local file, err = self.app.dataIo:open(path, "wb")
   if not file then return nil, tostring(err) end
   local size, hash = 0, ba.crypto.hash"sha256"
   local ok, failure = pcall(function()
      for chunk in request:rawrdr() do
         size = size + #chunk
         if size > util.MAX_UPLOAD_BYTES then error("Upload exceeds size limit") end
         hash(chunk)
         local wrote, writeErr = file:write(chunk)
         if not wrote then error(writeErr) end
      end
      if size == 0 then error("Upload body is empty") end
      local closeOk, closeErr = file:close()
      if closeOk == false then error(closeErr) end
      file = nil
   end)
   if file then pcall(function() file:close() end) end
   if not ok then
      self.app.dataIo:remove(path)
      return nil, tostring(failure)
   end
   return { path = path, size = size, sha256 = hash(true, "hex") }
end

function Manager:_installDraftUpload(upload, ticket)
   if upload.size ~= ticket.expectedBytes or
      not mcpconfig.secureEqual(upload.sha256, ticket.sha256) then
      return nil, "Uploaded byte count or SHA-256 does not match the prepared descriptor"
   end
   local draft, err = self:_openDraft(ticket.draftId)
   if not draft then return nil, err end
   local stat = draft.io:stat(ticket.path)
   local current
   if stat then
      if stat.isdir then
         closeIo(draft.io)
         return nil, "Theme path conflicts with a directory"
      end
      current = util.fileDigest(draft.io, ticket.path, util.MAX_EXPANDED_BYTES)
   end
   if current ~= ticket.previousSha256 then
      closeIo(draft.io)
      return nil, "Theme file changed after the upload was prepared"
   end
   local source
   source, err = self.app.dataIo:open(upload.path, "rb")
   if not source then closeIo(draft.io) return nil, tostring(err) end
   local ok
   ok, err = util.atomicInstall(draft.io, ticket.path, function(output)
      while true do
         local chunk, readErr = source:read(16384)
         if chunk and #chunk > 0 then
            local wrote, writeErr = output:write(chunk)
            if not wrote then error(writeErr) end
         elseif readErr then error(readErr)
         else break end
      end
   end)
   source:close()
   if not ok then closeIo(draft.io) return nil, err end
   draft.metadata.updatedAt = os.time()
   ok, err = writeJson(draft.io, META_FILE, draft.metadata)
   closeIo(draft.io)
   if not ok then return nil, err end
   return {
      installed = true,
      draftId = ticket.draftId,
      path = ticket.path,
      previousSha256 = ticket.previousSha256,
      sha256 = upload.sha256,
      byteLength = upload.size
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

function Manager:handle(request, response, authorized)
   self:_cleanupTickets()
   if not authorized then
      return jsonResponse(response, 401, { ok = false, error = "Unauthorized" })
   end
   local id = request:data("ticket")
   local ticket = id and self.tickets[id]
   if not ticket then
      return jsonResponse(response, 404, {
         ok = false,
         error = "Theme ticket is invalid, expired, or already used"
      })
   end
   self.tickets[id] = nil
   if ticket.kind == "draft-download" or ticket.kind == "installed-download" or
      ticket.kind == "theme-export" then
      if request:method() ~= "GET" then
         self.app.dataIo:remove(ticket.tempPath)
         return jsonResponse(response, 405, { ok = false, error = "Download ticket requires GET" })
      end
      local file, err = self.app.dataIo:open(ticket.tempPath, "rb")
      if not file then return jsonResponse(response, 500, { ok = false, error = tostring(err) }) end
      response:setstatus(200)
      response:setcontenttype(ticket.contentType)
      response:setheader("Cache-Control", "no-store")
      response:setheader("Content-Length", tostring(ticket.size))
      response:setheader("X-FuguHub-SHA256", ticket.sha256)
      if ticket.kind == "theme-export" then
         response:setheader(
            "Content-Disposition",
            'attachment; filename="' .. ticket.name .. '.zip"'
         )
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
   if request:method() ~= "POST" then
      return jsonResponse(response, 405, { ok = false, error = "Upload ticket requires POST" })
   end
   local receivedType = tostring(request:header("Content-Type") or ""):lower():gsub("%s*;.*$", "")
   if receivedType ~= ticket.contentType then
      return jsonResponse(response, 415, {
         ok = false,
         error = "Content-Type must be " .. tostring(ticket.contentType)
      })
   end
   if self.mutationActive then
      return jsonResponse(response, 409, { ok = false, error = "Another theme mutation is active" })
   end
   self.mutationActive = true
   local upload, result, err
   local ok, failure = xpcall(function()
      upload, err = self:_saveRequest(request)
      if upload then result, err = self:_installDraftUpload(upload, ticket) end
   end, function(value)
      return debug.traceback(value, 2)
   end)
   if upload then self.app.dataIo:remove(upload.path) end
   self.mutationActive = false
   if not ok then err = failure end
   if not result then
      return jsonResponse(response, 400, { ok = false, error = tostring(err) })
   end
   return jsonResponse(response, 200, { ok = true, result = result })
end

function Manager:close()
   for id, ticket in pairs(self.tickets) do
      if ticket.tempPath then pcall(function() self.app.dataIo:remove(ticket.tempPath) end) end
      self.tickets[id] = nil
   end
end

local function mutationResponse(helpers, result, err, code, details)
   if not result then return helpers.toolError(err, code, details) end
   return helpers.arrays(result)
end

function M.register(mcp, app, helpers)
   local manager = setmetatable({ app = app, tickets = {} }, Manager)
   local read = { readOnlyHint = true, idempotentHint = true }
   local destructive = { destructiveHint = true }
   local sha = { type = "string", minLength = 64, maxLength = 64 }
   local draftId = { type = "string", minLength = 16, maxLength = 128 }

   mcp:tool("listThemeFiles", {
      description = "List files in one installed directory or ZIP theme. SHA-256 is opt-in because hashing reads each file.",
      inputSchema = { type = "object", properties = {
         name = { type = "string", minLength = 1, maxLength = 255 },
         path = { type = "string", maxLength = 1024, default = "" },
         recursive = { type = "boolean", default = false },
         limit = { type = "integer", minimum = 1, maximum = 2000, default = 500 },
         includeSha256 = { type = "boolean", default = false }
      }, required = { "name" }, additionalProperties = false },
      annotations = read
   }, function(args)
      return mutationResponse(helpers, manager:listInstalled(args))
   end)

   mcp:tool("getThemeFile", {
      description = "Read one installed text theme file or return metadata for a binary file.",
      inputSchema = { type = "object", properties = {
         name = { type = "string", minLength = 1, maxLength = 255 },
         path = { type = "string", minLength = 1, maxLength = 1024 }
      }, required = { "name", "path" }, additionalProperties = false },
      annotations = read
   }, function(args)
      return mutationResponse(helpers, manager:getInstalled(args))
   end)

   mcp:tool("listThemeDrafts", {
      description = "List persistent staged theme workspaces.",
      inputSchema = { type = "object", properties = {}, additionalProperties = false },
      annotations = read
   }, function()
      return mutationResponse(helpers, manager:listDrafts())
   end)

   mcp:tool("createThemeDraft", {
      description = "Create an empty staged theme or clone an installed theme. Existing targets must be cloned from themselves.",
      inputSchema = { type = "object", properties = {
         name = { type = "string", minLength = 1, maxLength = 255 },
         fromTheme = { type = "string", minLength = 1, maxLength = 255 }
      }, required = { "name" }, additionalProperties = false }
   }, function(args)
      return mutationResponse(helpers, manager:createDraft(args))
   end)

   mcp:tool("listThemeDraftFiles", {
      description = "List files in one staged theme workspace. SHA-256 is opt-in because hashing reads each file.",
      inputSchema = { type = "object", properties = {
         draftId = draftId,
         path = { type = "string", maxLength = 1024, default = "" },
         recursive = { type = "boolean", default = false },
         limit = { type = "integer", minimum = 1, maximum = 2000, default = 500 },
         includeSha256 = { type = "boolean", default = false }
      }, required = { "draftId" }, additionalProperties = false },
      annotations = read
   }, function(args)
      return mutationResponse(helpers, manager:listDraftFiles(args))
   end)

   mcp:tool("getThemeDraftFile", {
      description = "Read one staged text theme file or return metadata for a binary file.",
      inputSchema = { type = "object", properties = {
         draftId = draftId,
         path = { type = "string", minLength = 1, maxLength = 1024 }
      }, required = { "draftId", "path" }, additionalProperties = false },
      annotations = read
   }, function(args)
      return mutationResponse(helpers, manager:getDraft(args))
   end)

   mcp:tool("writeThemeDraftText", {
      description = "Create or replace a staged text theme file using validation and optimistic concurrency. LSP requires confirmedExecutable=true.",
      inputSchema = { type = "object", properties = {
         draftId = draftId,
         path = { type = "string", minLength = 1, maxLength = 1024 },
         content = { type = "string", maxLength = util.MAX_TEXT_BYTES },
         expectedSha256 = sha,
         validateOnly = { type = "boolean", default = false },
         confirmedExecutable = { type = "boolean", default = false }
      }, required = { "draftId", "path", "content" }, additionalProperties = false }
   }, function(args)
      return mutationResponse(helpers, manager:writeDraftText(args))
   end)

   mcp:tool("prepareThemeDraftUpload", {
      description = "Prepare a one-time direct binary upload into a staged theme using exact byte and SHA-256 verification.",
      inputSchema = { type = "object", properties = {
         draftId = draftId,
         path = { type = "string", minLength = 1, maxLength = 1024 },
         expectedBytes = { type = "integer", minimum = 1, maximum = util.MAX_UPLOAD_BYTES },
         sha256 = sha,
         contentType = { type = "string", minLength = 1, maxLength = 255 },
         expectedCurrentSha256 = sha
      }, required = {
         "draftId", "path", "expectedBytes", "sha256", "contentType"
      }, additionalProperties = false }
   }, function(args, ctx)
      return mutationResponse(helpers, manager:prepareDraftUpload(args, ctx.serverOrigin))
   end)

   mcp:tool("prepareThemeDraftDownload", {
      description = "Prepare a bounded immutable one-time download for one staged theme file.",
      inputSchema = { type = "object", properties = {
         draftId = draftId,
         path = { type = "string", minLength = 1, maxLength = 1024 }
      }, required = { "draftId", "path" }, additionalProperties = false },
      annotations = read
   }, function(args, ctx)
      return mutationResponse(helpers, manager:prepareDraftDownload(args, ctx.serverOrigin))
   end)

   mcp:tool("commitThemeDraft", {
      description = "Validate and atomically install a staged ZIP theme. Inactive targets remain inactive; a confirmed same-name active target is replaced and immediately reloaded.",
      inputSchema = { type = "object", properties = {
         draftId = draftId,
         expectedFingerprint = sha,
         confirmed = { type = "boolean" },
         confirmedExecutable = { type = "boolean" },
         replaceActive = { type = "boolean", default = false }
      }, required = {
         "draftId", "expectedFingerprint", "confirmed", "confirmedExecutable"
      }, additionalProperties = false },
      annotations = destructive
   }, function(args)
      return mutationResponse(helpers, manager:commitDraft(args))
   end)

   mcp:tool("prepareThemeFileDownload", {
      description = "Prepare a bounded immutable one-time download for one installed theme file.",
      inputSchema = { type = "object", properties = {
         name = { type = "string", minLength = 1, maxLength = 255 },
         path = { type = "string", minLength = 1, maxLength = 1024 }
      }, required = { "name", "path" }, additionalProperties = false },
      annotations = read
   }, function(args, ctx)
      return mutationResponse(helpers, manager:prepareInstalledDownload(args, ctx.serverOrigin))
   end)

   mcp:tool("prepareThemeExport", {
      description = "Prepare a validated, correctly rooted one-time ZIP snapshot of an installed theme.",
      inputSchema = { type = "object", properties = {
         name = { type = "string", minLength = 1, maxLength = 255 }
      }, required = { "name" }, additionalProperties = false },
      annotations = read
   }, function(args, ctx)
      return mutationResponse(helpers, manager:prepareExport(args, ctx.serverOrigin))
   end)

   mcp:tool("deleteThemeDraftFile", {
      description = "Delete one staged file or empty directory using optimistic concurrency and explicit confirmation.",
      inputSchema = { type = "object", properties = {
         draftId = draftId,
         path = { type = "string", minLength = 1, maxLength = 1024 },
         expectedSha256 = sha,
         confirmed = { type = "boolean" }
      }, required = { "draftId", "path", "confirmed" }, additionalProperties = false },
      annotations = destructive
   }, function(args)
      return mutationResponse(helpers, manager:deleteDraftFile(args))
   end)

   mcp:tool("validateThemeDraft", {
      description = "Compile all required templates and validate theme.json in one staged workspace.",
      inputSchema = { type = "object", properties = {
         draftId = draftId
      }, required = { "draftId" }, additionalProperties = false },
      annotations = read
   }, function(args)
      return mutationResponse(helpers, manager:validateDraft(args))
   end)

   mcp:tool("discardThemeDraft", {
      description = "Permanently discard one staged theme workspace. Requires explicit confirmation.",
      inputSchema = { type = "object", properties = {
         draftId = draftId,
         confirmed = { type = "boolean" }
      }, required = { "draftId", "confirmed" }, additionalProperties = false },
      annotations = destructive
   }, function(args)
      return mutationResponse(helpers, manager:discardDraft(args))
   end)

   return manager
end

return M
