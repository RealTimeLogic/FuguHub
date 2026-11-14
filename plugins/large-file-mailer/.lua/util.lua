local function trim(value)
   return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function quote(value)
   return luasql.quotestr(tostring(value or ""))
end

local function execute(conn, sql)
   local result, err = conn:execute(sql)
   if result == nil then error(tostring(err or "SQL execution failed"), 2) end
   if type(result) == "userdata" and result.close then result:close() end
end

local function integer(value, minimum, maximum, label)
   value = tonumber(value)
   if not value or value % 1 ~= 0 or value < minimum or value > maximum then
      error(label .. " must be an integer from " .. minimum .. " to " .. maximum, 3)
   end
   return value
end

local function rows(ctx, sql)
   local env, conn = ctx.db.openRead()
   local ok, result = pcall(function()
      local cursor, err = conn:execute(sql)
      if not cursor then error(tostring(err or "SQL query failed"), 2) end
      local values = {}
      while true do
         local row = cursor:fetch({}, "a")
         if not row then break end
         values[#values + 1] = row
      end
      cursor:close()
      return values
   end)
   conn:close()
   env:close()
   if not ok then error(result, 2) end
   return result
end

local function one(ctx, sql)
   return rows(ctx, sql)[1]
end

local function sqlRow(conn, sql)
   local cursor, err = conn:execute(sql)
   if not cursor then error(tostring(err or "SQL query failed"), 2) end
   local row = cursor:fetch({}, "a")
   cursor:close()
   return row
end

local function insertId(conn)
   return tonumber(sqlRow(conn, "SELECT last_insert_rowid() AS id").id)
end

local function emailAddress(value)
   value = trim(value)
   if #value > 254 or not value:match("^[^%s@]+@[^%s@]+%.[^%s@]+$") then
      error("Invalid recipient email address", 3)
   end
   return value
end

local function mailboxAddress(value, field, optional)
   value = trim(value)
   field = field or "email address"
   if value == "" and optional then return "" end
   if value == "" or #value > 320 or value:find("[\r\n]") then
      error("Invalid " .. field, 3)
   end
   local display, address = value:match("^([^<>]*)<([^<>]+)>$")
   if not address then
      if value:find("[<>]") then error("Invalid " .. field, 3) end
      address = value
   end
   address = trim(address)
   if #address > 254 or not address:match("^[^%s@]+@[^%s@]+%.[^%s@]+$") then
      error("Invalid " .. field, 3)
   end
   display = trim(display)
   return display ~= "" and (display .. " <" .. address .. ">") or address
end

return {
   trim = trim,
   quote = quote,
   execute = execute,
   integer = integer,
   rows = rows,
   one = one,
   sqlRow = sqlRow,
   insertId = insertId,
   emailAddress = emailAddress,
   mailboxAddress = mailboxAddress,
}
