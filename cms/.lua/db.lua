local sqlutil = require "sqlutil"

local M = {}
local BUSY_TIMEOUT_MS = 2000
local WRITE_TIMEOUT_MS = 5000

local function logDb(message)
   trace("CMS DB:", message)
   mako.log(message)
end

local function configureConnection(conn)
   conn:setbusytimeout(BUSY_TIMEOUT_MS)
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
      local ok, err = pcall(configureConnection, conn)
      if not ok then
         pcall(conn.close, conn)
         pcall(env.close, env)
         error(err, 2)
      end
      return env, conn
   end

   local dbthread = ba.thread.create()
   db.thread = dbthread
   local writeEnv
   local writeConn
   local writerCoroutine
   local writerError
   local closing = false
   local closeJob

   local function expired(job)
      return (ba.clock() - job.queuedAt) % 4294967296 >= WRITE_TIMEOUT_MS
   end

   local function execute(conn, sql)
      local ok, err = conn:execute(sql)
      if not ok then
         error("SQLite " .. sql .. (err == "BUSY" and
            " timed out waiting for the database lock (BUSY)" or
            " failed: " .. tostring(err)), 0)
      end
   end

   local function closeWriteConn()
      local conn, env = writeConn, writeEnv
      writeConn, writeEnv = nil, nil
      local ok, err = pcall(function()
         if conn then assert(conn:close(), "SQLite connection did not close") end
      end)
      local envOk, envErr = pcall(function()
         if env then assert(env:close(), "SQLite environment did not close") end
      end)
      if not ok then error(err, 0) end
      if not envOk then error(envErr, 0) end
   end

   local function stopWriter(err)
      writerError = "SQLite writer unavailable; restart the application: " .. tostring(err)
      logDb(writerError)
      local ok, closeErr = pcall(closeWriteConn)
      if not ok then logDb("CMS DB close failed: " .. tostring(closeErr)) end
   end

   local function ensureWriteConn()
      if closing then error("SQLite writer is closed", 0) end
      if writerError then error(writerError, 0) end
      if not writeConn then
         local ok, err = pcall(function()
            writeEnv, writeConn = sqlutil.open(app.dbName or "cms")
            configureConnection(writeConn)
            execute(writeConn, "BEGIN IMMEDIATE")
         end)
         if not ok then
            stopWriter(err)
            error(err, 0)
         end
      end
      return writeConn
   end

   local function checkJob(job)
      if closing then error("SQLite writer is closed", 0) end
      if writerError then error(writerError, 0) end
      if job.cancelled or expired(job) then
         error("SQLite write timed out before commit; no changes were saved", 0)
      end
   end

   local function writeOnDbThread(fn, job)
      checkJob(job)
      local conn = ensureWriteConn()
      checkJob(job)
      local ok, a, b, c = pcall(function()
         local a, b, c = fn(conn)
         checkJob(job)
         -- Once COMMIT starts, wait for its bounded native lock wait and report
         -- its actual result. A caller timeout must not misreport a saved write.
         job.finishing = true
         execute(conn, "COMMIT")
         return a, b, c
      end)
      job.finishing = true
      if not ok then
         local rolledBack, rollbackErr = pcall(execute, conn, "ROLLBACK")
         if not rolledBack then stopWriter(rollbackErr) end
      end
      -- LuaSQL commit/rollback combine two SQL statements. Keep them separate
      -- so losing the next write reservation cannot turn a saved write into an error.
      if not writerError and not closing then
         local reserved, reserveErr = pcall(execute, conn, "BEGIN IMMEDIATE")
         if not reserved then stopWriter(reserveErr) end
      end
      if not ok then error(a, 0) end
      return a, b, c
   end

   local function enqueue(fn, resultFn)
      -- Keep the native owner alive if unload returns before queued cleanup runs.
      local job = { queuedAt = ba.clock(), owner = dbthread }
      dbthread:run(function()
         writerCoroutine = coroutine.running()
         if not job.cancelled then
            job.result = table.pack(pcall(fn, job))
            if resultFn then resultFn(table.unpack(job.result, 1, job.result.n)) end
         end
         job.owner = nil
      end)
      return job
   end

   local function checkWaitContext()
      if coroutine.running() == writerCoroutine then
         error("Cannot wait for the SQLite writer from its own callback", 3)
      end
   end

   local function awaitJob(job, cleanup)
      while not job.result do
         if not job.finishing and expired(job) then
            -- Expired writes must never run later. Cleanup stays queued on its owner.
            if not cleanup then job.cancelled = true end
            error(cleanup and "SQLite writer close timed out; cleanup remains queued" or
               "SQLite write timed out before commit; no changes were saved", 0)
         end
         ba.sleep(10)
      end
      if not job.result[1] then error(job.result[2], 3) end
      return table.unpack(job.result, 2, job.result.n)
   end

   function db.writeAsync(writeFn, resultFn)
      assert(type(writeFn) == "function", "writeFn must be a function")
      assert(resultFn == nil or type(resultFn) == "function", "resultFn must be a function")
      enqueue(function(job) return writeOnDbThread(writeFn, job) end, function(ok, a, b, c)
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
            logDb("CMS DB async write committed with a falsy result: " .. tostring(b))
         end
      end)
   end

   function db.writeSync(fn)
      assert(type(fn) == "function", "writeFn must be a function")
      checkWaitContext()
      if closing then error("SQLite writer is closed", 2) end
      if writerError then error(writerError, 2) end
      return awaitJob(enqueue(function(job) return writeOnDbThread(fn, job) end))
   end

   function db.acquireWriteOwner()
      checkWaitContext()
      return awaitJob(enqueue(function(job)
         checkJob(job)
         ensureWriteConn()
         return true
      end))
   end

   function db.close()
      checkWaitContext()
      closing = true
      closeJob = closeJob or enqueue(closeWriteConn)
      local ok, err = pcall(awaitJob, closeJob, true)
      if not ok then
         logDb("CMS DB close failed: " .. tostring(err))
         return nil, err
      end
      return true
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
