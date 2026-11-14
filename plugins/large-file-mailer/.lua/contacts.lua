local util = pluginreq "util"
local trim = util.trim
local quote = util.quote
local execute = util.execute
local integer = util.integer
local rows = util.rows
local one = util.one
local sqlRow = util.sqlRow
local insertId = util.insertId
local emailAddress = util.emailAddress

local function extractEmailAddresses(source)
   source = tostring(source or "")
   if #source > 2 * 1024 * 1024 then error("Email input exceeds 2 MiB", 3) end
   local values, seen = {}, {}
   for extracted in source:gmatch("[%w!#$%%&'*+/=?^_`{|}~%.%-]+@[%w%.%-]+") do
      local candidate = extracted:gsub("^%.+", ""):gsub("%.+$", "")
      local localPart, domain = candidate:match("^([^@]+)@([^@]+)$")
      local valid = localPart and domain and #candidate <= 254 and
         localPart:sub(1, 1) ~= "." and localPart:sub(-1) ~= "." and
         not localPart:find("..", 1, true) and
         not domain:find("..", 1, true) and domain:find(".", 1, true) and
         domain:sub(1, 1) ~= "-" and domain:sub(-1) ~= "-"
      if valid then
         for label in domain:gmatch("[^.]+") do
            if label:sub(1, 1) == "-" or label:sub(-1) == "-" then
               valid = false
               break
            end
         end
      end
      if valid then
         local key = candidate:lower()
         if not seen[key] then
            seen[key] = true
            values[#values + 1] = candidate
            if #values > 10000 then
               error("Email input exceeds 10000 unique addresses", 3)
            end
         end
      end
   end
   if #values == 0 then error("No email addresses were found", 3) end
   return values
end

local cp1252 = {
   [0x80] = 0x20AC, [0x82] = 0x201A, [0x83] = 0x0192,
   [0x84] = 0x201E, [0x85] = 0x2026, [0x86] = 0x2020,
   [0x87] = 0x2021, [0x88] = 0x02C6, [0x89] = 0x2030,
   [0x8A] = 0x0160, [0x8B] = 0x2039, [0x8C] = 0x0152,
   [0x8E] = 0x017D, [0x91] = 0x2018, [0x92] = 0x2019,
   [0x93] = 0x201C, [0x94] = 0x201D, [0x95] = 0x2022,
   [0x96] = 0x2013, [0x97] = 0x2014, [0x98] = 0x02DC,
   [0x99] = 0x2122, [0x9A] = 0x0161, [0x9B] = 0x203A,
   [0x9C] = 0x0153, [0x9E] = 0x017E, [0x9F] = 0x0178
}

local function normalizeCsvEncoding(source)
   if source:sub(1, 2) == "\255\254" or source:sub(1, 2) == "\254\255" then
      error("UTF-16 CSV is not supported; export as UTF-8 or Windows-1252", 3)
   end
   if utf8.len(source) then return source end
   local converted = {}
   for index = 1, #source do
      local byte = source:byte(index)
      if byte < 0x80 then
         converted[#converted + 1] = string.char(byte)
      elseif byte >= 0xA0 then
         converted[#converted + 1] = utf8.char(byte)
      else
         local codepoint = cp1252[byte]
         if not codepoint then
            error("CSV is neither valid UTF-8 nor supported Windows-1252", 3)
         end
         converted[#converted + 1] = utf8.char(codepoint)
      end
   end
   return table.concat(converted)
end

local function parseCsv(source)
   source = tostring(source or "")
   if #source > 2097152 then error("CSV input exceeds 2 MiB", 3) end
   source = normalizeCsvEncoding(source)
   source = source:gsub("^\239\187\191", "")
   local records, record, field = {}, {}, {}
   local quoted, index, length = false, 1, #source
   local function finishField()
      record[#record + 1] = table.concat(field)
      field = {}
   end
   local function finishRecord()
      finishField()
      local nonempty = false
      for _, value in ipairs(record) do
         if value ~= "" then nonempty = true break end
      end
      if nonempty then
         records[#records + 1] = record
         if #records > 5001 then error("CSV input exceeds 5000 contacts", 3) end
      end
      record = {}
   end
   while index <= length do
      local char = source:sub(index, index)
      if quoted then
         if char == '"' then
            if source:sub(index + 1, index + 1) == '"' then
               field[#field + 1] = '"'
               index = index + 1
            else
               quoted = false
            end
         else
            field[#field + 1] = char
         end
      elseif char == '"' and #field == 0 then
         quoted = true
      elseif char == "," then
         finishField()
      elseif char == "\r" or char == "\n" then
         if char == "\r" and source:sub(index + 1, index + 1) == "\n" then
            index = index + 1
         end
         finishRecord()
      else
         field[#field + 1] = char
      end
      index = index + 1
   end
   if quoted then error("CSV input has an unterminated quoted field", 3) end
   if #field > 0 or #record > 0 then finishRecord() end
   if #records < 1 then error("CSV input must contain at least one row", 3) end
   return records
end

local function csvMapping(headers, requested, requireEmail)
   local aliases = {
      email = { email = true, emailaddress = true, primaryemail = true,
         primaryemailaddress = true, email1 = true, emailaddress1 = true },
      firstName = { firstname = true, first = true, givenname = true },
      lastName = { lastname = true, last = true, surname = true, familyname = true },
      externalId = { externalid = true, contactid = true, id = true }
   }
   local mapping = {}
   for fieldName, names in pairs(aliases) do
      local selected = requested and tonumber(requested[fieldName])
      if selected and selected >= 1 and selected <= #headers then
         mapping[fieldName] = selected
      elseif not requested then
         for column, heading in ipairs(headers) do
            local normalized = trim(heading):lower():gsub("[^a-z0-9]", "")
            if names[normalized] then mapping[fieldName] = column break end
         end
      end
   end
   if requireEmail and not mapping.email then error("Select an email column", 3) end
   return mapping
end

local function csvLayout(records, forcedHasHeader)
   local detected = csvMapping(records[1])
   local firstEmailColumn
   for column, value in ipairs(records[1]) do
      if pcall(emailAddress, value) then
         firstEmailColumn = column
         break
      end
   end
   local hasHeader = forcedHasHeader
   if hasHeader == nil then
      hasHeader = next(detected) ~= nil or firstEmailColumn == nil
   end
   if hasHeader then
      if #records < 2 then
         error("CSV input must contain at least one contact row", 3)
      end
      if #records - 1 > 5000 then error("CSV input exceeds 5000 contacts", 3) end
      return records[1], detected, 2, true
   end
   if #records > 5000 then error("CSV input exceeds 5000 contacts", 3) end
   local columnCount = 0
   for _, row in ipairs(records) do columnCount = math.max(columnCount, #row) end
   local headers = {}
   for column = 1, columnCount do headers[column] = "Column " .. column end
   return headers, { email = firstEmailColumn }, 1, false
end

local M = {}

function M.install(ctx, service)
   function service.contacts(query, page, pageSize, listId, includeUnsubscribed,
      contactFilter)
      query = trim(query)
      page = integer(page or 1, 1, 1000000, "Page")
      pageSize = integer(pageSize or 50, 1, 200, "Page size")
      if listId ~= nil then
         listId = integer(listId, 1, 9007199254740991, "List ID")
      end
      local filters = {}
      if query ~= "" then
         local pattern = quote("%" .. query .. "%")
         filters[#filters + 1] = "(email LIKE " .. pattern ..
             " OR first_name LIKE " .. pattern ..
             " OR last_name LIKE " .. pattern ..
             " OR external_id LIKE " .. pattern .. ")"
      end
      if listId then
         filters[#filters + 1] = string.format([[EXISTS(
 SELECT 1 FROM mailer_list_members filter_members
 WHERE filter_members.contact_id=mailer_contacts.id AND filter_members.list_id=%d
)]], listId)
      end
      if includeUnsubscribed == false then
         filters[#filters + 1] = "mailer_contacts.unsubscribed_at IS NULL"
      end
      contactFilter = tostring(contactFilter or "all")
      if contactFilter == "unassigned" then
         filters[#filters + 1] = [[NOT EXISTS(
 SELECT 1 FROM mailer_list_members status_members
 WHERE status_members.contact_id=mailer_contacts.id
)]]
      elseif contactFilter == "unsubscribed" then
         filters[#filters + 1] = "mailer_contacts.unsubscribed_at IS NOT NULL"
      elseif contactFilter ~= "all" then
         error("Unknown contact filter", 2)
      end
      local where = #filters > 0 and " WHERE " .. table.concat(filters, " AND ") or ""
      local count = one(ctx, "SELECT COUNT(*) AS count FROM mailer_contacts" .. where)
      local values, byId, ids = {}, {}, {}
      for _, row in ipairs(rows(ctx, [[
SELECT mailer_contacts.id,external_id,email,first_name,last_name,
       mailer_contacts.unsubscribed_at,created_at,
       mailer_contacts.updated_at,credentials.confirmed_at,
       credentials.invitation_sent_at,credentials.invitation_expires_at
FROM mailer_contacts
LEFT JOIN mailer_contact_credentials credentials
  ON credentials.contact_id=mailer_contacts.id]] .. where ..
         " ORDER BY email LIMIT " .. pageSize ..
         " OFFSET " .. ((page - 1) * pageSize))) do
         local value = {
             id = tonumber(row.id), externalId = row.external_id,
             email = row.email, firstName = row.first_name,
              lastName = row.last_name,
              unsubscribed = row.unsubscribed_at ~= nil,
              unsubscribedAt = tonumber(row.unsubscribed_at),
             createdAt = tonumber(row.created_at), updatedAt = tonumber(row.updated_at),
             confirmed = row.confirmed_at ~= nil,
             confirmedAt = tonumber(row.confirmed_at),
             invitationSentAt = tonumber(row.invitation_sent_at),
             invitationExpiresAt = tonumber(row.invitation_expires_at),
             listIds = {}, listNames = {}
          }
         values[#values + 1] = value
         byId[value.id] = value
         ids[#ids + 1] = value.id
      end
      if #ids > 0 then
         for _, membership in ipairs(rows(ctx, string.format([[
SELECT m.contact_id,m.list_id,l.name
FROM mailer_list_members m JOIN mailer_lists l ON l.id=m.list_id
WHERE m.contact_id IN (%s) ORDER BY l.name
]], table.concat(ids, ",")))) do
            local contact = byId[tonumber(membership.contact_id)]
            contact.listIds[#contact.listIds + 1] = tonumber(membership.list_id)
            contact.listNames[#contact.listNames + 1] = membership.name
         end
      end
      return { items = values, page = page, pageSize = pageSize,
         total = tonumber(count.count) }
   end

   function service.previewContactsCsv(source)
      local records = parseCsv(source)
      local headers, mapping, firstRow, hasHeader = csvLayout(records)
      local preview, previewErrors = {}, {}
      for index = firstRow, math.min(#records, firstRow + 9) do
         preview[#preview + 1] = records[index]
         if mapping.email then
            local ok, err = pcall(emailAddress, records[index][mapping.email])
            if not ok then previewErrors[#previewErrors + 1] = {
               row = index, error = tostring(err)
            } end
         end
      end
      return {
         headers = headers,
         mapping = mapping,
         rows = preview,
         errors = previewErrors,
         totalRows = #records - firstRow + 1,
         hasHeader = hasHeader
      }
   end

   function service.importContactsCsv(source, requestedMapping, destinationListId,
      restoreUnsubscribed, hasHeader)
      destinationListId = integer(destinationListId, 1, 9007199254740991,
         "Destination list")
      if not one(ctx, "SELECT id FROM mailer_lists WHERE id=" .. destinationListId) then
         error("Destination list not found", 2)
      end
      local records = parseCsv(source)
      local headers, _, firstRow = csvLayout(records, hasHeader)
      local mapping = csvMapping(headers, requestedMapping, true)
      local candidates, sourceSeen, errors = {}, {}, {}
      for rowNumber = firstRow, #records do
         local row = records[rowNumber]
         local ok, email = pcall(emailAddress, row[mapping.email])
         if not ok then
            errors[#errors + 1] = { row = rowNumber, error = tostring(email) }
         else
            local key = email:lower()
            if sourceSeen[key] then
               errors[#errors + 1] = { row = rowNumber, error = "Duplicate email in CSV" }
            else
               sourceSeen[key] = true
               local candidate = {
                  row = rowNumber,
                  email = email,
                  firstName = trim(row[mapping.firstName]),
                  lastName = trim(row[mapping.lastName]),
                  externalId = trim(row[mapping.externalId])
               }
               if #candidate.externalId > 200 or #candidate.firstName > 160 or
                  #candidate.lastName > 160 then
                  errors[#errors + 1] = { row = rowNumber,
                     error = "A contact field is too long" }
               else
                  candidates[#candidates + 1] = candidate
               end
            end
         end
      end
      local imported, membersAdded, restored, duplicates, suppressed, now =
         0, 0, 0, {}, {}, os.time()
      for startIndex = 1, #candidates, 100 do
         ctx.db.writeSync(function(conn)
            for index = startIndex, math.min(startIndex + 99, #candidates) do
               local contact = candidates[index]
               execute(conn, string.format([[
INSERT OR IGNORE INTO mailer_contacts(
 external_id,email,first_name,last_name,created_at,updated_at
) VALUES(%s,%s,%s,%s,%d,%d)
]], contact.externalId ~= "" and quote(contact.externalId) or "NULL",
                  quote(contact.email), quote(contact.firstName), quote(contact.lastName),
                  now, now))
               if tonumber(sqlRow(conn, "SELECT changes() AS count").count) == 1 then
                  imported = imported + 1
               else
                  duplicates[#duplicates + 1] = {
                     row = contact.row, email = contact.email
                  }
               end
               local saved = sqlRow(conn,
                  "SELECT id,unsubscribed_at FROM mailer_contacts WHERE email=" ..
                  quote(contact.email))
                if saved.unsubscribed_at and restoreUnsubscribed == true then
                   execute(conn, "UPDATE mailer_contacts SET unsubscribed_at=NULL," ..
                      "updated_at=" .. now .. " WHERE id=" .. tonumber(saved.id))
                   execute(conn, "DELETE FROM mailer_unsubscribe_tokens WHERE contact_id=" ..
                      tonumber(saved.id))
                   restored = restored + 1
                   execute(conn, string.format(
                      "INSERT OR IGNORE INTO mailer_list_members(list_id,contact_id) " ..
                      "VALUES(%d,%d)", destinationListId, tonumber(saved.id)))
                   membersAdded = membersAdded +
                      tonumber(sqlRow(conn, "SELECT changes() AS count").count)
                elseif saved.unsubscribed_at then
                   suppressed[#suppressed + 1] = {
                      row = contact.row, email = contact.email
                  }
               else
                  execute(conn, string.format(
                     "INSERT OR IGNORE INTO mailer_list_members(list_id,contact_id) " ..
                     "VALUES(%d,%d)", destinationListId, tonumber(saved.id)))
                  membersAdded = membersAdded +
                     tonumber(sqlRow(conn, "SELECT changes() AS count").count)
               end
            end
         end)
      end
      return { imported = imported, membersAdded = membersAdded, restored = restored,
         listId = destinationListId, duplicates = duplicates,
         suppressed = suppressed, errors = errors,
         totalRows = #records - firstRow + 1 }
   end

   function service.saveContact(input)
      input = input or {}
      local id = input.id and integer(input.id, 1, 9007199254740991, "Contact ID")
      local email = emailAddress(input.email)
      local externalId = trim(input.externalId)
      local firstName, lastName = trim(input.firstName), trim(input.lastName)
      if #externalId > 200 or #firstName > 160 or #lastName > 160 then
         error("A contact field is too long", 2)
      end
      local listIds
      if input.listIds ~= nil then
         listIds = {}
         local seen = {}
         for _, value in ipairs(input.listIds) do
            local listId = integer(value, 1, 9007199254740991, "List ID")
            if not seen[listId] then
               seen[listId] = true
               listIds[#listIds + 1] = listId
            end
         end
      end
      local now, resultId = os.time()
      ctx.db.writeSync(function(conn)
         if id then
            execute(conn, string.format([[
UPDATE mailer_contacts SET external_id=%s,email=%s,first_name=%s,last_name=%s,
 updated_at=%d WHERE id=%d
]], externalId ~= "" and quote(externalId) or "NULL", quote(email),
               quote(firstName), quote(lastName), now, id))
            resultId = id
         else
            execute(conn, string.format([[
INSERT INTO mailer_contacts(
 external_id,email,first_name,last_name,created_at,updated_at
) VALUES(%s,%s,%s,%s,%d,%d)
]], externalId ~= "" and quote(externalId) or "NULL", quote(email),
               quote(firstName), quote(lastName), now, now))
            resultId = insertId(conn)
         end
         if listIds then
            execute(conn, "DELETE FROM mailer_list_members WHERE contact_id=" .. resultId)
            local saved = sqlRow(conn,
               "SELECT unsubscribed_at FROM mailer_contacts WHERE id=" .. resultId)
            if not saved.unsubscribed_at then
               for _, listId in ipairs(listIds) do
                  execute(conn, string.format(
                     "INSERT INTO mailer_list_members(list_id,contact_id) VALUES(%d,%d)",
                     listId, resultId))
               end
            end
         end
      end)
      return resultId
   end

   function service.resubscribeContact(id)
      id = integer(id, 1, 9007199254740991, "Contact ID")
      ctx.db.writeSync(function(conn)
         execute(conn, "UPDATE mailer_contacts SET unsubscribed_at=NULL,updated_at=" ..
            os.time() .. " WHERE id=" .. id)
         execute(conn, "DELETE FROM mailer_unsubscribe_tokens WHERE contact_id=" .. id)
      end)
      return true
   end

   function service.resubscribeContacts(contactIds)
      local selected, seen = {}, {}
      for _, value in ipairs(contactIds or {}) do
         local contactId = integer(value, 1, 9007199254740991, "Contact ID")
         if not seen[contactId] then
            seen[contactId] = true
            selected[#selected + 1] = contactId
         end
      end
      if #selected == 0 then error("Select at least one contact", 2) end
      local restored = 0
      ctx.db.writeSync(function(conn)
         local ids = table.concat(selected, ",")
         execute(conn, "UPDATE mailer_contacts SET unsubscribed_at=NULL,updated_at=" ..
            os.time() .. " WHERE unsubscribed_at IS NOT NULL AND id IN (" .. ids .. ")")
         restored = tonumber(sqlRow(conn, "SELECT changes() AS count").count)
         execute(conn, "DELETE FROM mailer_unsubscribe_tokens WHERE contact_id IN (" ..
            ids .. ")")
      end)
      return { restored = restored }
   end

   function service.deleteContact(id)
      id = integer(id, 1, 9007199254740991, "Contact ID")
      ctx.db.writeSync(function(conn)
         execute(conn, "DELETE FROM mailer_contacts WHERE id=" .. id)
      end)
      return true
   end

   function service.resetContactPassword(id)
      id = integer(id, 1, 9007199254740991, "Contact ID")
      ctx.db.writeSync(function(conn)
         execute(conn, string.format([[
INSERT INTO mailer_contact_credentials(contact_id,updated_at)
VALUES(%d,%d)
ON CONFLICT(contact_id) DO UPDATE SET
 password_salt=NULL,password_hash=NULL,password_iterations=NULL,confirmed_at=NULL,
 invitation_token_hash=NULL,invitation_expires_at=NULL,updated_at=excluded.updated_at
]], id, os.time()))
      end)
      return true
   end

   function service.deleteContacts(contactIds)
      local selected, seen = {}, {}
      for _, value in ipairs(contactIds or {}) do
         local contactId = integer(value, 1, 9007199254740991, "Contact ID")
         if not seen[contactId] then
            seen[contactId] = true
            selected[#selected + 1] = contactId
         end
      end
      if #selected == 0 then error("Select at least one contact", 2) end
      local removed = 0
      ctx.db.writeSync(function(conn)
         execute(conn, "DELETE FROM mailer_contacts WHERE id IN (" ..
            table.concat(selected, ",") .. ")")
         removed = tonumber(sqlRow(conn, "SELECT changes() AS count").count)
      end)
      return { removed = removed }
   end

   local function contactRemovalMatches(source)
      local emails = extractEmailAddresses(source)
      local found = {}
      for startIndex = 1, #emails, 200 do
         local quoted = {}
         for index = startIndex, math.min(startIndex + 199, #emails) do
            quoted[#quoted + 1] = quote(emails[index])
         end
         for _, row in ipairs(rows(ctx, [[
SELECT id,email,first_name,last_name FROM mailer_contacts
WHERE email IN (]] .. table.concat(quoted, ",") .. ")")) do
            found[row.email:lower()] = {
               id = tonumber(row.id), email = row.email,
               firstName = row.first_name, lastName = row.last_name
            }
         end
      end
      local matches, notFound = {}, {}
      for _, email in ipairs(emails) do
         local contact = found[email:lower()]
         if contact then matches[#matches + 1] = contact
         else notFound[#notFound + 1] = email end
      end
      return emails, matches, notFound
   end

   function service.previewContactRemoval(source)
      local emails, matches, notFound = contactRemovalMatches(source)
      local shownMatches, shownMissing = {}, {}
      for index = 1, math.min(#matches, 200) do shownMatches[index] = matches[index] end
      for index = 1, math.min(#notFound, 100) do shownMissing[index] = notFound[index] end
      return {
         extractedCount = #emails,
         matchCount = #matches,
         notFoundCount = #notFound,
         matches = shownMatches,
         notFound = shownMissing,
         matchesTruncated = #matches > #shownMatches,
         notFoundTruncated = #notFound > #shownMissing
      }
   end

   function service.removeContactsFromText(source)
      local emails, matches, notFound = contactRemovalMatches(source)
      local removed = 0
      if #matches > 0 then
         ctx.db.writeSync(function(conn)
            for startIndex = 1, #matches, 200 do
               local ids = {}
               for index = startIndex, math.min(startIndex + 199, #matches) do
                  ids[#ids + 1] = matches[index].id
               end
               execute(conn, "DELETE FROM mailer_contacts WHERE id IN (" ..
                  table.concat(ids, ",") .. ")")
               removed = removed +
                  tonumber(sqlRow(conn, "SELECT changes() AS count").count)
            end
         end)
      end
      return {
         extractedCount = #emails,
         matchedCount = #matches,
         removed = removed,
         notFoundCount = #notFound
      }
   end

   function service.deleteAllContacts()
      ctx.db.writeSync(function(conn)
         execute(conn, "DELETE FROM mailer_contacts")
      end)
      return true
   end

   function service.lists(includeMemberIds)
      local values, membersByList = {}, {}
      if includeMemberIds ~= false then
         for _, member in ipairs(rows(ctx, [[
SELECT m.list_id,m.contact_id
FROM mailer_list_members m
JOIN mailer_lists l ON l.id=m.list_id
JOIN mailer_contacts c ON c.id=m.contact_id
ORDER BY m.list_id,m.contact_id
]])) do
            local listId = tonumber(member.list_id)
            local memberIds = membersByList[listId] or {}
            memberIds[#memberIds + 1] = tonumber(member.contact_id)
            membersByList[listId] = memberIds
         end
      end
      for _, row in ipairs(rows(ctx, [[
SELECT l.id,l.name,l.description,l.created_at,l.updated_at,COUNT(c.id) AS members
FROM mailer_lists l
LEFT JOIN mailer_list_members m ON m.list_id=l.id
LEFT JOIN mailer_contacts c ON c.id=m.contact_id
GROUP BY l.id ORDER BY l.name
]])) do
         local listId = tonumber(row.id)
         values[#values + 1] = {
            id = listId, name = row.name, description = row.description,
            members = tonumber(row.members), createdAt = tonumber(row.created_at),
            updatedAt = tonumber(row.updated_at)
          }
         if includeMemberIds ~= false then
            values[#values].memberIds = membersByList[listId] or {}
         end
      end
      return values
   end

   function service.list(id)
      id = integer(id, 1, 9007199254740991, "List ID")
      local row = one(ctx, [[
SELECT l.id,l.name,l.description,l.created_at,l.updated_at,COUNT(c.id) AS members
FROM mailer_lists l
LEFT JOIN mailer_list_members m ON m.list_id=l.id
LEFT JOIN mailer_contacts c ON c.id=m.contact_id
WHERE l.id=]] .. id .. " GROUP BY l.id")
      if not row then return nil end
      return { id = tonumber(row.id), name = row.name, description = row.description,
         members = tonumber(row.members), createdAt = tonumber(row.created_at),
         updatedAt = tonumber(row.updated_at) }
   end

   function service.saveList(input)
      input = input or {}
      local id = input.id and integer(input.id, 1, 9007199254740991, "List ID")
      local name, description = trim(input.name), trim(input.description)
      if name == "" or #name > 160 then error("A valid list name is required", 2) end
      if #description > 1000 then error("List description is too long", 2) end
      local memberIds
      if input.contactIds ~= nil then
         memberIds = {}
         local seen = {}
         for _, value in ipairs(input.contactIds) do
            local contactId = integer(value, 1, 9007199254740991, "Contact ID")
            if not seen[contactId] then
               seen[contactId] = true
               memberIds[#memberIds + 1] = contactId
            end
         end
      end
      local now, resultId = os.time()
      ctx.db.writeSync(function(conn)
         if id then
            execute(conn, string.format(
               "UPDATE mailer_lists SET name=%s,description=%s,updated_at=%d WHERE id=%d",
               quote(name), quote(description), now, id))
            resultId = id
         else
            execute(conn, string.format([[
INSERT INTO mailer_lists(name,description,created_at,updated_at)
VALUES(%s,%s,%d,%d)
]], quote(name), quote(description), now, now))
            resultId = insertId(conn)
         end
         if memberIds then
            execute(conn, "DELETE FROM mailer_list_members WHERE list_id=" .. resultId)
            for _, contactId in ipairs(memberIds) do
               execute(conn, string.format(
                  "INSERT INTO mailer_list_members(list_id,contact_id) VALUES(%d,%d)",
                  resultId, contactId))
            end
         end
      end)
      return resultId
   end

   function service.transferListMembers(sourceListId, destinationListId,
                                         contactIds, deleteSource)
      sourceListId = integer(sourceListId, 1, 9007199254740991, "Source list")
      destinationListId = integer(destinationListId, 1, 9007199254740991,
         "Destination list")
      if sourceListId == destinationListId then
         error("Select a different destination list", 2)
      end
      if not service.list(sourceListId) then error("Source list not found", 2) end
      if not service.list(destinationListId) then error("Destination list not found", 2) end
      local selected
      if contactIds ~= nil then
         selected = {}
         local seen = {}
         for _, value in ipairs(contactIds) do
            local contactId = integer(value, 1, 9007199254740991, "Contact ID")
            if not seen[contactId] then
               seen[contactId] = true
               selected[#selected + 1] = contactId
            end
         end
         if #selected == 0 then error("Select at least one contact", 2) end
         if deleteSource then error("A partial transfer cannot delete the source list", 2) end
      end
      local filter = selected and
         " AND contact_id IN (" .. table.concat(selected, ",") .. ")" or ""
      local moved, added = 0, 0
      ctx.db.writeSync(function(conn)
         moved = tonumber(sqlRow(conn, string.format(
            "SELECT COUNT(*) AS count FROM mailer_list_members WHERE list_id=%d%s",
            sourceListId, filter)).count)
         execute(conn, string.format([[
INSERT OR IGNORE INTO mailer_list_members(list_id,contact_id)
SELECT %d,contact_id FROM mailer_list_members WHERE list_id=%d%s
]], destinationListId, sourceListId, filter))
         added = tonumber(sqlRow(conn, "SELECT changes() AS count").count)
         execute(conn, string.format(
            "DELETE FROM mailer_list_members WHERE list_id=%d%s", sourceListId, filter))
         if deleteSource then
            execute(conn, "DELETE FROM mailer_lists WHERE id=" .. sourceListId)
         end
      end)
      return { moved = moved, added = added, sourceListId = sourceListId,
         destinationListId = destinationListId, sourceDeleted = deleteSource == true }
   end

   function service.addListMembers(listId, contactIds)
      listId = integer(listId, 1, 9007199254740991, "List ID")
      if not service.list(listId) then error("Destination list not found", 2) end
      local selected, seen = {}, {}
      for _, value in ipairs(contactIds or {}) do
         local contactId = integer(value, 1, 9007199254740991, "Contact ID")
         if not seen[contactId] then
            seen[contactId] = true
            selected[#selected + 1] = contactId
         end
      end
      if #selected == 0 then error("Select at least one contact", 2) end
      local added = 0
      ctx.db.writeSync(function(conn)
         for _, contactId in ipairs(selected) do
            execute(conn, string.format(
               "INSERT OR IGNORE INTO mailer_list_members(list_id,contact_id) " ..
               "SELECT %d,id FROM mailer_contacts WHERE id=%d", listId, contactId))
            added = added + tonumber(sqlRow(conn, "SELECT changes() AS count").count)
         end
      end)
      return { added = added, listId = listId }
   end

   function service.removeListMembers(listId, contactIds)
      listId = integer(listId, 1, 9007199254740991, "List ID")
      local selected, seen = {}, {}
      for _, value in ipairs(contactIds or {}) do
         local contactId = integer(value, 1, 9007199254740991, "Contact ID")
         if not seen[contactId] then
            seen[contactId] = true
            selected[#selected + 1] = contactId
         end
      end
      if #selected == 0 then error("Select at least one contact", 2) end
      local removed = 0
      ctx.db.writeSync(function(conn)
         execute(conn, string.format(
            "DELETE FROM mailer_list_members WHERE list_id=%d AND contact_id IN (%s)",
            listId, table.concat(selected, ",")))
         removed = tonumber(sqlRow(conn, "SELECT changes() AS count").count)
      end)
      return { removed = removed, listId = listId }
   end

   function service.deleteList(id)
      id = integer(id, 1, 9007199254740991, "List ID")
      ctx.db.writeSync(function(conn)
         execute(conn, "DELETE FROM mailer_lists WHERE id=" .. id)
      end)
      return true
   end

   function service.deleteAllLists()
      ctx.db.writeSync(function(conn)
         execute(conn, "DELETE FROM mailer_lists")
      end)
      return true
   end

   function service.resolveRecipients(contactIds, listIds)
      local selected = {}
      for _, value in ipairs(contactIds or {}) do
         selected[integer(value, 1, 9007199254740991, "Contact ID")] = true
      end
      local normalizedListIds = {}
      for _, value in ipairs(listIds or {}) do
         normalizedListIds[#normalizedListIds + 1] =
            integer(value, 1, 9007199254740991, "List ID")
      end
      if #normalizedListIds > 0 then
         for _, row in ipairs(rows(ctx,
            "SELECT contact_id FROM mailer_list_members WHERE list_id IN (" ..
            table.concat(normalizedListIds, ",") .. ")")) do
            selected[tonumber(row.contact_id)] = true
         end
      end
      local result = {}
      local selectedIds = {}
      for contactId in pairs(selected) do selectedIds[#selectedIds + 1] = contactId end
      table.sort(selectedIds)
      if #selectedIds > 0 then
         for _, row in ipairs(rows(ctx,
            "SELECT * FROM mailer_contacts WHERE id IN (" ..
            table.concat(selectedIds, ",") .. ")")) do
            result[#result + 1] = {
               contactId = tonumber(row.id), email = row.email,
               firstName = row.first_name, lastName = row.last_name
            }
         end
      end
      table.sort(result, function(a, b) return a.email:lower() < b.email:lower() end)
      return result
   end

end

return M
