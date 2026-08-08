local db = appreq "db"
local content = appreq "mcpcontent"
local mcpconfig = appreq "mcpconfig"
local validation = appreq "validation"
local zipWriter = appreq "zip_writer"
local contentpath = appreq "contentpath"

local M = {}
local Archive = {}
Archive.__index = Archive

local MANIFEST_NAME = ".fuguhub-content.json"
local FORMAT_NAME = "fuguhub-content"
local FORMAT_VERSION = 2
local MAX_ITEMS = 100
local MAX_ARCHIVE_BYTES = 8 * 1024 * 1024
local MAX_MANIFEST_BYTES = 6 * 1024 * 1024

local function ticketId()
   return ba.b64urlencode(ba.rndbs(24))
end

local function removeFile(io, path)
   if io and path then pcall(function() io:remove(path) end) end
end

local function readFile(io, path, maxBytes)
   local file, err = io:open(path, "rb")
   if not file then return nil, tostring(err) end
   local chunks, size = {}, 0
   while true do
      local chunk, readErr = file:read(16384)
      if chunk and #chunk > 0 then
         size = size + #chunk
         if size > maxBytes then
            file:close()
            return nil, "file exceeds size limit"
         end
         chunks[#chunks + 1] = chunk
      elseif readErr then
         file:close()
         return nil, tostring(readErr)
      else
         break
      end
   end
   file:close()
   return table.concat(chunks)
end

local function jsonResponse(response, status, value)
   local encoded = ba.json.encode(value)
   response:setstatus(status)
   response:setcontenttype("application/json; charset=utf-8")
   response:setheader("Cache-Control", "no-store")
   response:setheader("Content-Length", tostring(#encoded))
   response:send(encoded)
end

local function validIpv4(host)
   local count = 0
   for octet in host:gmatch("[^.]+") do
      count = count + 1
      if not octet:match("^%d+$") or (#octet > 1 and octet:sub(1, 1) == "0") or tonumber(octet) > 255 then
         return false
      end
   end
   return count == 4 and host:sub(1, 1) ~= "." and host:sub(-1) ~= "." and not host:find("..", 1, true)
end

local function validIpv6(host)
   if host == "" or not host:match("^[0-9A-Fa-f:%.]+$") then return false end
   local first = host:find("::", 1, true)
   if first and host:find("::", first + 2, true) then return false end
   local groups, sawIpv4 = 0, false
   for group in host:gmatch("[^:]+") do
      if group:find(".", 1, true) then
         if sawIpv4 or not validIpv4(group) or group ~= host:match("([^:]+)$") then return false end
         sawIpv4 = true
         groups = groups + 2
      else
         if #group < 1 or #group > 4 or not group:match("^[0-9A-Fa-f]+$") then return false end
         groups = groups + 1
      end
   end
   return first and groups < 8 or not first and groups == 8
end

local function parseTransferUrl(url)
   if type(url) ~= "string" or #url < 1 or #url > 2048 then
      return nil, "transferUrl must contain 1 to 2048 characters"
   end
   if url:find("[%z%c%s\\#%?]") then
      return nil, "transferUrl contains a forbidden character, query, or fragment"
   end
   local scheme, authority, path = url:match("^(https?)://([^/]+)(/.*)$")
   if not scheme then
      scheme, authority = url:match("^(https?)://([^/]+)$")
      path = "/"
   end
   if not scheme or not authority or authority:find("@", 1, true) then
      return nil, "transferUrl must be HTTP or HTTPS without user-info"
   end
   local host, port
   if authority:sub(1, 1) == "[" then
      host, port = authority:match("^%[([0-9A-Fa-f:%.]+)%]:(%d+)$")
      if not host then host = authority:match("^%[([0-9A-Fa-f:%.]+)%]$") end
      if not host or not validIpv6(host) then return nil, "transferUrl has an invalid IPv6 host" end
      host = "[" .. host:lower() .. "]"
   else
      host, port = authority:match("^([^:]+):(%d+)$")
      host = host or authority
      if #host > 253 or host:find(":", 1, true) or not host:match("^[A-Za-z0-9%.%-]+$") or
         host:sub(1, 1) == "." or host:sub(-1) == "." or host:find("..", 1, true) then
         return nil, "transferUrl has an invalid host"
      end
      if host:match("^[%d%.]+$") and not validIpv4(host) then return nil, "transferUrl has an invalid IPv4 host" end
      for label in host:gmatch("[^.]+") do
         if #label > 63 or label:sub(1, 1) == "-" or label:sub(-1) == "-" then
            return nil, "transferUrl has an invalid host"
         end
      end
      host = host:lower()
   end
   port = port and tonumber(port) or (scheme == "https" and 443 or 80)
   if not port or port < 1 or port > 65535 then return nil, "transferUrl has an invalid port" end
   local explicitPort = authority:match(":%d+$") ~= nil
   local origin = scheme .. "://" .. host .. (explicitPort and ":" .. port or "")
   return { url = url, scheme = scheme, host = host, port = port, path = path, origin = origin }
end

local function selectionRows(app, args)
   local ids, paths, seen = args.ids or {}, args.paths or {}, {}
   if #ids + #paths == 0 then return nil, "Select at least one content id or path" end
   if #ids + #paths > MAX_ITEMS then return nil, "At most " .. MAX_ITEMS .. " content items may be transferred" end
   local out, missing = {}, {}
   for _, id in ipairs(ids) do
      id = tonumber(id)
      if not id or id % 1 ~= 0 or id < 1 then return nil, "Content ids must be positive integers" end
      if not seen["id:" .. id] then
         seen["id:" .. id] = true
         local item = content.get(app, { id = id })
         if item then
            seen["content:" .. item.id] = true
            out[#out + 1] = item
         else
            missing[#missing + 1] = "id:" .. id
         end
      end
   end
   for _, value in ipairs(paths) do
      local path, err = validation.path(value)
      if not path then return nil, err end
      if not seen["path:" .. path] then
         seen["path:" .. path] = true
         local item, itemErr = content.get(app, { path = path })
         if itemErr then return nil, itemErr end
         if item then
            if not seen["content:" .. item.id] then
               seen["content:" .. item.id] = true
               out[#out + 1] = item
            end
         else
            missing[#missing + 1] = "path:" .. path
         end
      end
   end
   if #missing > 0 then
      table.sort(missing)
      return nil, "Selected content was not found: " .. table.concat(missing, ", ")
   end
   table.sort(out, function(a, b)
      if a.type == b.type then return a.path < b.path end
      return a.type < b.type
   end)
   return out
end

local function summaries(items)
   local out = {}
   for _, item in ipairs(items) do
      out[#out + 1] = {
         path = item.path,
         type = item.type,
         title = item.title,
         status = item.status
      }
   end
   return out
end

function Archive:_cleanup()
   local now = os.time()
   for id, ticket in pairs(self.tickets) do
      if ticket.expiresAt <= now then
         removeFile(self.dataIo, ticket.path)
         self.tickets[id] = nil
      end
   end
end

function Archive:_writeArchive(items)
   local createdAt = os.time()
   local manifest = {
      format = FORMAT_NAME,
      version = FORMAT_VERSION,
      createdAt = createdAt,
      items = items
   }
   local manifestText = ba.json.encode(manifest)
   if #manifestText > MAX_MANIFEST_BYTES then return nil, "Content archive manifest exceeds size limit" end
   local id = ticketId()
   local path = "FuguHub-export-" .. id .. ".zip"
   local output, err = self.dataIo:open(path, "wb")
   if not output then return nil, tostring(err) end
   local hash = ba.crypto.hash"sha256"
   local info
   info, err = zipWriter.write({
      { path = MANIFEST_NAME, content = manifestText, mtime = createdAt }
   }, function(chunk)
      hash(chunk)
      return output:write(chunk)
   end, {
      compress = true,
      maxEntries = 1,
      maxDepth = 1,
      maxEntryBytes = MAX_MANIFEST_BYTES,
      maxArchiveBytes = MAX_ARCHIVE_BYTES,
      mtime = createdAt
   })
   local closeOk, closeErr = output:close()
   if not info or closeOk == false then
      removeFile(self.dataIo, path)
      return nil, tostring(err or closeErr)
   end
   return {
      id = id,
      path = path,
      size = info.size,
      sha256 = hash(true, "hex"),
      items = summaries(items)
   }
end

function Archive:prepareExport(app, args, serverOrigin)
   self:_cleanup()
   local items, err = selectionRows(app, args or {})
   if not items then return nil, err, "contentSelectionInvalid" end
   local snapshot
   snapshot, err = self:_writeArchive(items)
   if not snapshot then return nil, err, "contentExportFailed" end
   snapshot.kind = "export"
   snapshot.expiresAt = os.time() + self.ticketTtl
   self.tickets[snapshot.id] = snapshot
   return {
      downloadUrl = serverOrigin .. app.url("/mcp/archive?ticket=" .. snapshot.id),
      expiresAt = snapshot.expiresAt,
      expiresInSeconds = self.ticketTtl,
      expectedBytes = snapshot.size,
      digest = "sha256:" .. snapshot.sha256,
      items = snapshot.items,
      compression = "none"
   }
end

function Archive:prepareTransfer(app, args, serverOrigin)
   self:_cleanup()
   local items, err = selectionRows(app, args or {})
   if not items then return nil, err, "contentSelectionInvalid" end
   local snapshot
   snapshot, err = self:_writeArchive(items)
   if not snapshot then return nil, err, "prepareContentTransferFailed" end
   snapshot.kind = "transfer"
   snapshot.expiresAt = os.time() + self.transferTtl
   self.tickets[snapshot.id] = snapshot
   return {
      transferUrl = serverOrigin .. app.url("/mcp/transfer"),
      transferTicket = snapshot.id,
      expiresAt = snapshot.expiresAt,
      expiresInSeconds = self.transferTtl,
      expectedBytes = snapshot.size,
      digest = "sha256:" .. snapshot.sha256,
      items = snapshot.items,
      compression = "none"
   }
end

function Archive:_stream(ticket, response, transfer)
   local file, err = self.dataIo:open(ticket.path, "rb")
   if not file then return nil, tostring(err) end
   response:setstatus(200)
   response:setcontenttype("application/zip")
   response:setheader("Cache-Control", "no-store")
   response:setheader("Content-Length", tostring(ticket.size))
   response:setheader("X-FuguHub-SHA256", ticket.sha256)
   if not transfer then
      response:setheader("Content-Disposition", 'attachment; filename="fuguhub-content.zip"')
   end
   local ok, streamErr = pcall(function()
      while true do
         local chunk = file:read(16384)
         if not chunk or #chunk == 0 then break end
         response:write(chunk)
      end
   end)
   file:close()
   removeFile(self.dataIo, ticket.path)
   if not ok then return nil, tostring(streamErr) end
   return true
end

function Archive:handleArchive(request, response, authorized)
   self:_cleanup()
   if not authorized then return jsonResponse(response, 401, { ok = false, error = "Unauthorized" }) end
   local id = request:data("ticket")
   local ticket = id and self.tickets[id]
   if not ticket or ticket.kind ~= "export" then
      return jsonResponse(response, 404, { ok = false, error = "Archive ticket is invalid, expired, or already used" })
   end
   self.tickets[id] = nil
   if request:method() ~= "GET" then
      removeFile(self.dataIo, ticket.path)
      return jsonResponse(response, 405, { ok = false, error = "Archive ticket requires GET" })
   end
   local ok, err = self:_stream(ticket, response, false)
   if not ok then error(err, 2) end
end

function Archive:handleTransfer(request, response)
   self:_cleanup()
   if request:header("Authorization") then
      return jsonResponse(response, 400, {
         ok = false,
         error = "Persistent authorization credentials are forbidden on the transfer endpoint"
      })
   end
   local candidate = request:header("X-FuguHub-Transfer-Ticket")
   local foundId, ticket
   for id, value in pairs(self.tickets) do
      if value.kind == "transfer" and mcpconfig.secureEqual(id, candidate) then
         foundId, ticket = id, value
      end
   end
   if not ticket then
      return jsonResponse(response, 404, {
         ok = false,
         error = "Transfer ticket is invalid, expired, or already used",
         code = "transferExpired"
      })
   end
   self.tickets[foundId] = nil
   if request:method() ~= "GET" then
      removeFile(self.dataIo, ticket.path)
      return jsonResponse(response, 405, { ok = false, error = "Transfer ticket requires GET" })
   end
   local ok, err = self:_stream(ticket, response, true)
   if not ok then error(err, 2) end
end

local function descriptorItems(args)
   if type(args.items) ~= "table" or #args.items < 1 or #args.items > MAX_ITEMS then
      return nil, "items must contain 1 to " .. MAX_ITEMS .. " content summaries"
   end
   local out, seen = {}, {}
   for _, item in ipairs(args.items) do
      if type(item) ~= "table" then return nil, "Each descriptor item must be an object" end
      local path, err = validation.path(item.path)
      if not path then return nil, err end
      local kind = tostring(item.type or "")
      local key = contentpath.key(kind, path)
      if seen[key] then return nil, "Descriptor contains duplicate " .. kind .. " path " .. path end
      seen[key] = true
      out[#out + 1] = {
         path = path,
         type = kind,
         title = tostring(item.title or ""),
         status = tostring(item.status or "")
      }
   end
   return out
end

local function conflictPlan(app, items, decisions)
   local decisionByPath = {}
   for _, decision in ipairs(decisions or {}) do
      if type(decision) ~= "table" then return nil, "Each conflict decision must be an object" end
      local path, err = validation.path(decision.path)
      if not path then return nil, err end
      local kind = tostring(decision.type or "")
      if kind ~= "page" and kind ~= "post" then
         return nil, "Each conflict decision must identify type as page or post"
      end
      local key = contentpath.key(kind, path)
      if decisionByPath[key] then return nil, "Duplicate conflict decision for " .. kind .. " " .. path end
      decisionByPath[key] = {
         action = decision.action,
         newPath = decision.newPath
      }
   end

   local conflicts, plan, reserved = {}, {}, {}
   for _, item in ipairs(items) do reserved[contentpath.key(item.type, item.path)] = true end
   for _, item in ipairs(items) do
      local key = contentpath.key(item.type, item.path)
      local existing = db.readOne(app, "SELECT id,title,type,status,updated_at FROM content WHERE type=" ..
         db.quote(item.type) .. " AND path=" .. db.quote(item.path))
      if existing then
         local decision = decisionByPath[key]
         if not decision then
            conflicts[#conflicts + 1] = {
               path = item.path,
               type = item.type,
               incomingTitle = item.title,
                existingTitle = existing.title,
                existingId = tonumber(existing.id),
                existingUpdatedAt = tonumber(existing.updated_at),
                allowedActions = { "skip", "replace", "importDraft" }
            }
         elseif decision.action == "skip" or decision.action == "replace" then
            plan[key] = {
               action = decision.action,
               existingId = tonumber(existing.id),
               expectedUpdatedAt = tonumber(existing.updated_at)
            }
         elseif decision.action == "importDraft" then
            local newPath, err = validation.path(decision.newPath)
            if not newPath then return nil, "New draft path for " .. item.path .. ": " .. tostring(err) end
            local newKey = contentpath.key(item.type, newPath)
            if reserved[newKey] or db.readOne(app, "SELECT id FROM content WHERE type=" ..
               db.quote(item.type) .. " AND path=" .. db.quote(newPath)) then
               return nil, "New draft path already exists or is reserved: " .. newPath
            end
            reserved[newKey] = true
            plan[key] = { action = "importDraft", newPath = newPath }
         else
            return nil, "Conflict action for " .. item.path .. " must be skip, replace, or importDraft"
         end
      else
         if decisionByPath[key] then
            return nil, "A conflict decision was supplied for a path that does not conflict: " .. item.path
         end
         plan[key] = { action = "create" }
      end
   end
   if #conflicts > 0 then
      return nil, "Content conflicts require user choices", "contentConflictsRequireDecision", {
         conflicts = conflicts,
         question = "The destination already has content at these paths. For each path, should it be skipped, replaced, or imported as a draft under a new path you provide?"
      }
   end
   return plan
end

function Archive:_fetch(parsed, args)
   local path = "FuguHub-transfer-" .. ticketId() .. ".zip"
   local output, err = self.dataIo:open(path, "wb")
   if not output then return nil, tostring(err), "transferDownloadFailed" end
   local http, total, hash = nil, 0, ba.crypto.hash"sha256"
   local failureCode = "transferDownloadFailed"
   local ok, result = pcall(function()
      http = require"httpc".create { persistent = false }
      http:timeout(self.transferReadTimeoutMs)
      local requested, requestErr = http:request {
         url = parsed.url,
         method = "GET",
         trusted = parsed.scheme == "https",
         header = {
            ["Accept"] = "application/zip",
            ["X-FuguHub-Transfer-Ticket"] = args.transferTicket
         }
      }
      if not requested then error("Source request failed: " .. tostring(requestErr)) end
      local status, statusErr = http:status()
      if not status then error("Source response failed: " .. tostring(statusErr)) end
      if status == 404 or status == 410 then failureCode = "transferExpired" end
      if status >= 300 and status < 400 then failureCode = "transferRedirectForbidden" end
      if status ~= 200 then error("Source returned HTTP " .. tostring(status) .. "; redirects are not allowed") end
      local contentLength = tonumber(http:header"Content-Length" or "")
      if contentLength ~= args.expectedBytes then error("Source Content-Length differs from descriptor") end
      local digestHeader = tostring(http:header"X-FuguHub-SHA256" or ""):lower()
      if not mcpconfig.secureEqual(digestHeader, args.digest:sub(8)) then
         failureCode = "transferDigestMismatch"
         error("Source digest header differs from descriptor")
      end
      local contentType = tostring(http:header"Content-Type" or ""):lower()
      if contentType ~= "application/zip" and not contentType:match("^application/zip%s*;") then
         error("Source response is not application/zip")
      end
      local started = os.time()
      while true do
         if os.time() - started > self.transferTotalTimeoutSeconds then error("Source transfer timed out") end
         local chunk, readErr = http:read(16384)
         if chunk and #chunk > 0 then
            total = total + #chunk
            if total > MAX_ARCHIVE_BYTES then error("Source archive exceeds size limit") end
            hash(chunk)
            local wrote, writeErr = output:write(chunk)
            if not wrote then error(tostring(writeErr)) end
         elseif readErr then
            error("Source transfer read failed: " .. tostring(readErr))
         else
            break
         end
      end
      if total ~= args.expectedBytes then error("Downloaded byte count differs from descriptor") end
      local digest = hash(true, "hex"):lower()
      if not mcpconfig.secureEqual(digest, args.digest:sub(8)) then
         failureCode = "transferDigestMismatch"
         error("Downloaded archive digest mismatch")
      end
      output:close()
      output = nil
      return { path = path, size = total, sha256 = digest }
   end)
   if output then pcall(function() output:close() end) end
   if http then pcall(function() http:close() end) end
   if not ok then
      removeFile(self.dataIo, path)
      return nil, tostring(result), failureCode
   end
   return result
end

function Archive:_readManifest(path, descriptor)
   local zipIo, err = ba.mkio(self.dataIo, path)
   if not zipIo then return nil, "Cannot open transferred ZIP: " .. tostring(err) end
   local ok, result = pcall(function()
      local count = 0
      for name, isDirectory in zipIo:files("", true) do
         if isDirectory then
            error("Archive contains an unexpected directory")
         else
            count = count + 1
            if name ~= MANIFEST_NAME then error("Archive contains an unexpected entry") end
         end
      end
      if count ~= 1 then error("Archive must contain exactly one manifest") end
      local stat = zipIo:stat(MANIFEST_NAME)
      if not stat or tonumber(stat.size or 0) > MAX_MANIFEST_BYTES then error("Archive manifest exceeds size limit") end
      local text, readErr = readFile(zipIo, MANIFEST_NAME, MAX_MANIFEST_BYTES)
      if not text then error(readErr) end
      local manifest = ba.json.decode(text)
      if type(manifest) ~= "table" or manifest.format ~= FORMAT_NAME or manifest.version ~= FORMAT_VERSION or
         type(manifest.items) ~= "table" or #manifest.items ~= #descriptor then
         error("Archive manifest format, version, or item count is invalid")
      end
      for index, summary in ipairs(descriptor) do
         local item = manifest.items[index]
         if type(item) ~= "table" or item.path ~= summary.path or item.type ~= summary.type or
            item.title ~= summary.title or item.status ~= summary.status then
            error("Archive content differs from the prepared descriptor")
         end
      end
      return manifest
   end)
   if zipIo.close then pcall(function() zipIo:close() end) end
   if not ok then return nil, tostring(result) end
   return result
end

function Archive:importTransfer(app, args)
   args = args or {}
   local parsed, err = parseTransferUrl(args.transferUrl)
   if not parsed then return nil, err, "invalidTransferUrl" end
   if args.confirmedSourceOrigin ~= parsed.origin then
      return nil, "Explicit confirmation of the exact source origin is required",
         "transferSourceRequiresConfirmation", {
            sourceOrigin = parsed.origin,
            question = "Allow the destination CMS to fetch the content archive from exactly " .. parsed.origin .. "?"
         }
   end
   if type(args.transferTicket) ~= "string" or #args.transferTicket ~= 32 or
      not args.transferTicket:match("^[A-Za-z0-9_-]+$") then
      return nil, "Transfer ticket is invalid", "invalidTransferTicket"
   end
   args.expectedBytes = tonumber(args.expectedBytes)
   if not args.expectedBytes or args.expectedBytes < 1 or args.expectedBytes % 1 ~= 0 or
      args.expectedBytes > MAX_ARCHIVE_BYTES then
      return nil, "expectedBytes is invalid", "invalidTransferDescriptor"
   end
   if type(args.digest) ~= "string" or not args.digest:match("^sha256:[0-9a-fA-F]+$") or #args.digest ~= 71 then
      return nil, "digest must be a SHA-256 descriptor", "invalidTransferDescriptor"
   end
   args.digest = args.digest:lower()
   local items
   items, err = descriptorItems(args)
   if not items then return nil, err, "invalidTransferDescriptor" end
   local plan, planErr, planCode, planData = conflictPlan(app, items, args.decisions)
   if not plan then return nil, planErr, planCode or "invalidConflictDecision", planData end

   local upload, fetchErr, fetchCode = self:_fetch(parsed, args)
   if not upload then return nil, fetchErr, fetchCode end
   local manifest, manifestErr = self:_readManifest(upload.path, items)
   removeFile(self.dataIo, upload.path)
   if not manifest then return nil, manifestErr, "invalidContentArchive" end
   local imported, importErr, importCode, importDetails =
      content.importBatch(app, manifest.items, plan, args.publish == true)
   if not imported then
      return nil, importErr, importCode or "contentImportFailed", importDetails
   end
   imported.sourceOrigin = parsed.origin
   imported.digest = "sha256:" .. upload.sha256
   imported.publishedSourceContent = args.publish == true
   return imported
end

function Archive:close()
   for id, ticket in pairs(self.tickets) do
      removeFile(self.dataIo, ticket.path)
      self.tickets[id] = nil
   end
end

function M.create(app)
   return setmetatable({
      dataIo = assert(app.dataIo, "app.dataIo is required"),
      tickets = {},
      ticketTtl = 5 * 60,
      transferTtl = 60,
      transferReadTimeoutMs = 5000,
      transferTotalTimeoutSeconds = 30
   }, Archive)
end

M.format = FORMAT_NAME
M.version = FORMAT_VERSION
M.manifestName = MANIFEST_NAME
M.parseTransferUrl = parseTransferUrl

return M
