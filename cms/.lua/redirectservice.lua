local db = appreq "db"

local M = {}

local function graph(conn)
   local targets, count = {}, 0
   for _, row in ipairs(db.rows(conn, "SELECT from_path,to_path FROM redirects")) do
      targets[row.from_path] = row.to_path
      count = count + 1
   end
   return targets, count
end

local function loopFrom(targets, source, limit)
   local seen, current = {}, source
   for _ = 1, limit do
      current = targets[current]
      if not current then return false end
      if current == source or seen[current] then return true end
      seen[current] = true
   end
   return targets[current] ~= nil
end

function M.validateConn(conn, fromPath, toPath)
   if fromPath == toPath then
      return nil, "Redirect cannot point to itself"
   end
   local targets, count = graph(conn)
   if not targets[fromPath] then count = count + 1 end
   targets[fromPath] = toPath
   if loopFrom(targets, fromPath, count + 1) then
      return nil, "Redirect would create or enter a loop"
   end
   return true
end

function M.saveConn(conn, fromPath, toPath, status)
   local valid, err = M.validateConn(conn, fromPath, toPath)
   if not valid then return nil, err end
   local ok
   ok, err = conn:execute("INSERT OR REPLACE INTO redirects(from_path,to_path,status_code) VALUES(" ..
      db.quote(fromPath) .. "," .. db.quote(toPath) .. "," .. tonumber(status) .. ")")
   if not ok then return nil, tostring(err) end
   return true
end

function M.issues(app)
   return db.withRead(app, function(conn)
      local targets, count = graph(conn)
      local issues = {}
      for source, target in pairs(targets) do
         if source == target then
            issues[#issues + 1] = {
               code = "redirectSelfLoop",
               message = "Redirect points to itself",
               entity = source
            }
         elseif loopFrom(targets, source, count + 1) then
            issues[#issues + 1] = {
               code = "redirectLoop",
               message = "Redirect participates in or enters a loop",
               entity = source
            }
         end
      end
      table.sort(issues, function(a, b) return a.entity < b.entity end)
      return issues
   end)
end

return M
