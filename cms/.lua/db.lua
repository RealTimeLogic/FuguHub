local sqlutil = require "sqlutil"

local M = {}

local function logDb(message, op)
   mako.log(message, op or "cms-db")
end

local function setBusyTimeout(conn)
   if conn and conn.setbusytimeout then
      pcall(function() conn:setbusytimeout(2000) end)
   end
end

local function configureConnection(conn)
   setBusyTimeout(conn)
   local ok, err = conn:execute("PRAGMA foreign_keys=ON")
   if not ok then
      error("Enabling SQLite foreign keys failed: " .. tostring(err), 2)
   end
end

function M.quote(value)
   value = tostring(value or "")
   if luasql and luasql.quotestr then
      return luasql.quotestr(value)
   end
   return "'" .. value:gsub("'", "''") .. "'"
end

function M.nextRevision(previous, proposed)
   return math.max(
      os.time(),
      (tonumber(previous) or 0) + 1,
      tonumber(proposed) or 0
   )
end

function M.one(conn, sql)
   local cur = assert(conn:execute(sql))
   local row = cur:fetch({}, "a")
   cur:close()
   return row
end

function M.rows(conn, sql, eachRow)
   local cur = assert(conn:execute(sql))
   local out = {}
   while true do
      local row = cur:fetch({}, "a")
      if not row then break end
      if eachRow then eachRow(row) end
      table.insert(out, row)
   end
   cur:close()
   return out
end

function M.readOne(app, sql)
   return M.withRead(app, function(conn)
      return M.one(conn, sql)
   end)
end

function M.readRows(app, sql, eachRow)
   return M.withRead(app, function(conn)
      return M.rows(conn, sql, eachRow)
   end)
end

function M.configure(app)
   local db = {}
   app.db = db

   function db.openRead()
      local env, conn = sqlutil.open(app.dbName or "cms")
      configureConnection(conn)
      return env, conn
   end

   local dbthread = ba.thread.create()
   db.thread = dbthread
   local writeEnv
   local writeConn

   local function sqliteRetry(op, label)
      while true do
         local ok, err = op()
         if ok then
            return ok
         end
         if err ~= "BUSY" then
            error((label or "DB operation") .. " failed: " .. tostring(err), 2)
         end
         logDb("CMS DB BUSY during " .. tostring(label or "write") .. "; retrying")
         ba.sleep(50)
      end
   end

   local function closeWriteConn()
      if writeConn then
         writeConn:close()
         writeConn = nil
      end
      if writeEnv then
         writeEnv:close()
         writeEnv = nil
      end
   end

   local function ensureWriteConn(retry)
      if not writeConn then
         writeEnv, writeConn = sqlutil.open(app.dbName or "cms")
         configureConnection(writeConn)
         if retry == false then
            local ok, err = writeConn:setautocommit("IMMEDIATE")
            if not ok then
               closeWriteConn()
               error("setautocommit(IMMEDIATE) failed: " .. tostring(err), 2)
            end
         else
            sqliteRetry(function()
               return writeConn:setautocommit("IMMEDIATE")
            end, "setautocommit(IMMEDIATE)")
         end
      end
      return writeConn
   end

   local function acquireWriteOwner()
      local conn = ensureWriteConn(false)
      local ok, err = conn:commit("IMMEDIATE")
      if not ok then
         closeWriteConn()
         error("commit(IMMEDIATE) failed: " .. tostring(err), 2)
      end
      return true
   end

   local function writeOnDbThread(fn)
      local conn = ensureWriteConn()
      local ok, a, b, c = pcall(fn, conn)
      if ok then
         sqliteRetry(function()
            return conn:commit("IMMEDIATE")
         end, "commit(IMMEDIATE)")
         return a, b, c
      end
      pcall(function() conn:rollback("IMMEDIATE") end)
      error(a, 2)
   end

   local function runWrite(fn)
      local done = false
      local result
      dbthread:run(function()
         result = table.pack(pcall(writeOnDbThread, fn))
         done = true
      end)
      while not done do
         ba.sleep(10)
      end
      if not result[1] then
         error(result[2], 3)
      end
      return table.unpack(result, 2, result.n)
   end

   function db.writeAsync(writeFn, resultFn)
      dbthread:run(function()
         local ok, a, b, c = pcall(writeOnDbThread, writeFn)
         if resultFn then
            local cbOk, cbErr = pcall(resultFn, ok, a, b, c)
            if not cbOk then
               logDb("CMS DB async callback failed: " .. tostring(cbErr))
            end
            return
         end
         if not ok then
            logDb("CMS DB async write failed: " .. tostring(a))
         elseif not a then
            logDb("CMS DB async write failed: " .. tostring(b))
         end
      end)
   end

   function db.writeSync(fn)
      return runWrite(fn)
   end

   function db.acquireWriteOwner()
      local done = false
      local result
      dbthread:run(function()
         result = table.pack(pcall(acquireWriteOwner))
         done = true
      end)
      while not done do
         ba.sleep(10)
      end
      if not result[1] then
         error(result[2], 2)
      end
      return table.unpack(result, 2, result.n)
   end

   function db.close()
      local done = false
      local result
      dbthread:run(function()
         local ok, err = pcall(closeWriteConn)
         result = { ok, err }
         done = true
      end)
      while not done do
         ba.sleep(10)
      end
      if not result[1] then
         logDb("CMS DB close failed: " .. tostring(result[2]))
      end
   end
   return db
end

function M.withRead(app, fn)
   local env, conn = app.db.openRead()
   local ok, a, b, c = pcall(fn, conn)
   conn:close()
   env:close()
   if not ok then error(a, 2) end
   return a, b, c
end

function M.withWrite(app, fn)
   return app.db.writeSync(fn)
end

return M
