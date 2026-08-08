local settings = appreq "settings"
local nativeHub = require "smq.hub"

local M = {}

local function traceback(message)
   if debug and debug.traceback then
      return debug.traceback(message, 2)
   end
   return tostring(message)
end

local function rpcError(id, message)
   return {
      id = id,
      rsp = nil,
      err = tostring(message or "RPC failed")
   }
end

local function validRpcName(name)
   return type(name) == "string" and #name <= 128 and
      name:match("^[%a_][%w_%.:%-]*$") ~= nil
end

function M.install(app)
   if app.smq then return app.smq end

   local service = {
      _app = app,
      _broker = nil,
      _registrationOwner = nil,
      _rpcMethods = {},
      _brokerStartCallbacks = {}
   }

   local function owner()
      return service._registrationOwner or app
   end

   local function dispatchRpc(request, ptid)
      local broker = service._broker
      if not broker then return end
      if type(request) ~= "table" then
         broker:publish(rpcError(nil, "Invalid RPC request"), ptid, "$RpcResp")
         return
      end

      local id = request.id
      local name = request.name
      local args = request.args or {}
      if id == nil or not validRpcName(name) or type(args) ~= "table" then
         broker:publish(rpcError(id, "Invalid RPC request"), ptid, "$RpcResp")
         return
      end

      local registration = service._rpcMethods[name]
      if not registration then
         broker:publish(rpcError(id, "RPC function not found"), ptid, "$RpcResp")
         return
      end

      local ok, rsp, err = pcall(registration.callback, table.unpack(args))
      if not ok then
         err = rsp
         rsp = nil
      elseif rsp ~= nil then
         err = nil
      end
      broker:publish({ id = id, rsp = rsp, err = err }, ptid, "$RpcResp")
   end

   function service:_start()
      if self._broker then return true end

      local broker = nativeHub.create {
         onconnect = function(tid, info, peer)
            if app.cms and app.cms.emit then
               app.cms:emit("smq:connect", tid, info, peer)
            end
         end,
         onclose = function(tid, sock, peer, err)
            if app.cms and app.cms.emit then
               app.cms:emit("smq:close", tid, sock, peer, err)
            end
         end
      }
      self._broker = broker
      broker:subscribe("self", {
         subtopic = "$RpcReq",
         json = true,
         onmsg = dispatchRpc
      })

      for _, registration in ipairs(self._brokerStartCallbacks) do
         if registration.active then
            local ok, err = xpcall(function()
               registration.callback(broker)
            end, traceback)
            if not ok then
               self._broker = nil
               pcall(function() broker:shutdown() end)
               return nil, "SMQ broker-start callback failed: " .. tostring(err)
            end
         end
      end
      return true
   end

   function service:_stop(message)
      local broker = self._broker
      self._broker = nil
      if not broker then return true end
      local ok, err = pcall(function()
         broker:shutdown(message)
      end)
      if not ok then return nil, tostring(err) end
      return true
   end

   function service:configure()
      if settings.isSmqEnabled(app) then
         return self:_start()
      end
      return self:_stop("SMQ disabled")
   end

   function service:restart()
      if not settings.isSmqEnabled(app) then
         return self:_stop("SMQ disabled")
      end
      local ok, err = self:_stop()
      if not ok then return nil, err end
      return self:_start()
   end

   function service:shutdown()
      return self:_stop()
   end

   function service:isEnabled()
      return settings.isSmqEnabled(app)
   end

   function service:isRunning()
      return self._broker ~= nil
   end

   function service:broker()
      return self._broker
   end

   function service:publish(data, topic, subtopic)
      local broker = self._broker
      if not broker then return nil, "SMQ is disabled" end
      local ok, result = pcall(function()
         return broker:publish(data, topic, subtopic)
      end)
      if not ok then return nil, tostring(result) end
      return result
   end

   function service:registerRpcMethod(name, callback)
      if not validRpcName(name) then
         return nil, "Invalid SMQ RPC method name"
      end
      if type(callback) ~= "function" then
         return nil, "SMQ RPC callback must be a function"
      end
      local existing = self._rpcMethods[name]
      local registrationOwner = owner()
      if existing and existing.owner ~= registrationOwner then
         return nil, "SMQ RPC method is already registered: " .. name
      end
      local registration = {
         owner = registrationOwner,
         callback = callback
      }
      self._rpcMethods[name] = registration
      return function()
         if self._rpcMethods[name] == registration then
            self._rpcMethods[name] = nil
         end
      end
   end

   function service:onBrokerStart(callback)
      if type(callback) ~= "function" then
         return nil, "SMQ broker-start callback must be a function"
      end
      local registration = {
         owner = owner(),
         callback = callback,
         active = true
      }
      self._brokerStartCallbacks[#self._brokerStartCallbacks + 1] = registration
      if self._broker then
         local ok, err = xpcall(function()
            callback(self._broker)
         end, traceback)
         if not ok then
            registration.active = false
            return nil, tostring(err)
         end
      end
      return function()
         registration.active = false
      end
   end

   function service:_beginOwner(value)
      self._registrationOwner = value
   end

   function service:_endOwner(value)
      if self._registrationOwner == value then
         self._registrationOwner = nil
      end
   end

   function service:_removeOwner(value)
      for name, registration in pairs(self._rpcMethods) do
         if registration.owner == value then
            self._rpcMethods[name] = nil
         end
      end
      for _, registration in ipairs(self._brokerStartCallbacks) do
         if registration.owner == value then
            registration.active = false
         end
      end
   end

   function service:handle(_ENV)
      if not settings.isSmqEnabled(app) or not self._broker then
         _ENV.response:senderror(404, "SMQ is disabled")
         return true
      end
      if not nativeHub.isSMQ(_ENV.request) then
         _ENV.response:senderror(400, "Not an SMQ connection request")
         return true
      end
      self._broker:connect(_ENV.request)
      _ENV.response:abort()
      return true
   end

   app.smq = service
   return service
end

function M.configure(app)
   local service = app.smq or M.install(app)
   return service:configure()
end

function M.newEndpoint(app)
   local service = app.smq or M.install(app)
   return function(_ENV)
      return service:handle(_ENV)
   end
end

return M
