(function (window, document) {
   "use strict";

   var endpointMeta = document.querySelector('meta[name="fuguhub-smq-endpoint"]');
   var targetMeta = document.querySelector('meta[name="fuguhub-smq-target"]');
   var endpoint = endpointMeta && endpointMeta.content;
   var targetSelector = targetMeta && targetMeta.content || "#cms-main";
   if (!endpoint) return;

   var brokerTid = 1;
   var smq = SMQ.Client(SMQ.wsURL(endpoint), { cleanstart: true });
   var routes = new Map();
   var connected = false;
   var hasConnected = false;
   var currentScope = null;
   var connectionGeneration = 0;

   function formatError(error) {
      if (error instanceof Error) return error.message;
      return String(error || "SMQ RPC failed");
   }

   function routeKey(topic, subtopic) {
      return topic + "\u001f" + (subtopic || "");
   }

   function routeHasHandlers(route) {
      return route.handlers.size > 0;
   }

   function topicHasHandlers(topic) {
      return Array.from(routes.values()).some(function (route) {
         return route.topic === topic && routeHasHandlers(route);
      });
   }

   function subscribeRoute(route) {
      if (route.subscribedGeneration === connectionGeneration) return;

      var options = {
         datatype: route.datatype,
         onmsg: function (message, ptid, tid, subtid) {
            route.handlers.forEach(function (handler) {
               handler(message, ptid, tid, subtid);
            });
         }
      };

      if (route.subtopic) {
         smq.subscribe(route.topic, route.subtopic, options);
      } else {
         smq.subscribe(route.topic, options);
      }
      route.subscribedGeneration = connectionGeneration;
   }

   function ensureRoute(topic, subtopic, datatype, handler, scope) {
      var key = routeKey(topic, subtopic);
      var route = routes.get(key);
      if (!route) {
         route = {
            topic: topic,
            subtopic: subtopic,
            datatype: datatype || "json",
            handlers: new Map(),
            subscribedGeneration: -1
         };
         routes.set(key, route);
      }

      route.handlers.set(scope.id, handler);
      scope.routes.add(key);
      subscribeRoute(route);
   }

   function failPendingRpc(scope, error) {
      if (!scope || !scope.rpcPending || scope.rpcPending.size === 0) return;
      scope.rpcPending.forEach(function (pending) {
         pending.reject(error);
      });
      scope.rpcPending.clear();
   }

   function cleanupScope(scope) {
      if (!scope || !scope.active) return;

      failPendingRpc(scope, new Error("Page unloaded before SMQ RPC response"));
      scope.active = false;
      scope.cleanups.forEach(function (cleanup) {
         cleanup();
      });

      scope.routes.forEach(function (key) {
         var route = routes.get(key);
         if (!route) return;

         route.handlers.delete(scope.id);
         if (!routeHasHandlers(route)) {
            routes.delete(key);
            if (route.topic !== "self" && !topicHasHandlers(route.topic)) {
               smq.unsubscribe(route.topic);
            }
         }
      });

      if (currentScope === scope) currentScope = null;
   }

   function handleRpcResponse(scope, response) {
      if (!response || !Object.prototype.hasOwnProperty.call(response, "id")) return;
      var pending = scope.rpcPending.get(response.id);
      if (!pending) return;

      scope.rpcPending.delete(response.id);
      if (response.err) {
         pending.reject(new Error(formatError(response.err)));
      } else {
         pending.resolve(response.rsp);
      }
   }

   function callRpc(scope, methodName, args) {
      if (!scope.active) {
         return Promise.reject(new Error("Page scope is no longer active"));
      }

      var id = scope.id + ":" + (++scope.rpcCounter);
      var payload = { id: id, name: methodName, args: args };
      return new Promise(function (resolve, reject) {
         scope.rpcPending.set(id, { resolve: resolve, reject: reject });
         try {
            window.cmsSmq.sendToBroker("$RpcReq", payload);
         } catch (error) {
            scope.rpcPending.delete(id);
            reject(error);
         }
      });
   }

   function readyScope(scope) {
      if (!scope || !scope.active || scope.readyCallbacks.length === 0) return;

      var readyGeneration = connectionGeneration;
      smq.subscribe("$cmsReady", {
         onack: function (accepted) {
            if (!accepted || !scope.active ||
                readyGeneration !== connectionGeneration) return;
            scope.readyCallbacks.forEach(function (callback) {
               callback(smq);
            });
         }
      });
   }

   function reconnectScope(scope) {
      if (!scope || !scope.active) return;
      scope.routes.forEach(function (key) {
         var route = routes.get(key);
         if (route && routeHasHandlers(route)) subscribeRoute(route);
      });
      readyScope(scope);
   }

   function emit(name, detail) {
      document.dispatchEvent(new CustomEvent(name, { detail: detail || {} }));
   }

   function onConnect() {
      connected = true;
      if (hasConnected) {
         connectionGeneration += 1;
         reconnectScope(currentScope);
      } else {
         hasConnected = true;
      }
      emit("cms:smq-connect", {
         generation: connectionGeneration,
         reconnect: connectionGeneration > 0
      });
   }

   smq.onconnect = onConnect;
   smq.onreconnect = onConnect;
   smq.onclose = function (message, canreconnect) {
      connected = false;
      failPendingRpc(currentScope, new Error(message || "SMQ disconnected"));
      emit("cms:smq-close", {
         message: message || "SMQ disconnected",
         canReconnect: Boolean(canreconnect)
      });
      if (canreconnect) return 3000;
      return undefined;
   };

   window.cmsSmq = {
      brokerTid: brokerTid,
      client: smq,

      isConnected: function () {
         return connected;
      },

      sendToBroker: function (messageName, payload) {
         smq.pubjson(payload || {}, brokerTid, messageName);
      },

      sendToPeer: function (peerTid, messageName, payload) {
         smq.pubjson(payload || {}, peerTid, messageName);
      },

      publishEvent: function (eventName, payload) {
         smq.pubjson(payload || {}, eventName);
      },

      mountPage: function (name, init) {
         var scope = {
            id: name + ":" + Date.now() + ":" + Math.random(),
            name: name,
            active: true,
            cleanups: [],
            routes: new Set(),
            readyCallbacks: [],
            rpcPending: new Map(),
            rpcCounter: 0,

            onCleanup: function (cleanup) {
               scope.cleanups.push(cleanup);
            },

            onReady: function (callback) {
               scope.readyCallbacks.push(callback);
            },

            subscribeToEvent: function (eventName, handler, datatype) {
               ensureRoute(eventName, null, datatype, handler, scope);
            },

            subscribeToDirectMessage: function (messageName, handler, datatype) {
               ensureRoute("self", messageName, datatype, handler, scope);
            },

            sendToBroker: function (messageName, payload) {
               window.cmsSmq.sendToBroker(messageName, payload);
            },

            sendToPeer: function (peerTid, messageName, payload) {
               window.cmsSmq.sendToPeer(peerTid, messageName, payload);
            },

            publishEvent: function (eventName, payload) {
               window.cmsSmq.publishEvent(eventName, payload);
            },

            callRpc: function (methodName) {
               return callRpc(scope, methodName,
                  Array.prototype.slice.call(arguments, 1));
            },

            rpc: new Proxy({}, {
               get: function (target, property) {
                  if (typeof property !== "string") return undefined;
                  return function () {
                     return callRpc(scope, property,
                        Array.prototype.slice.call(arguments));
                  };
               }
            }),

            failPendingRpc: function (error) {
               failPendingRpc(scope, error);
            }
         };

         cleanupScope(currentScope);
         currentScope = scope;
         ensureRoute("self", "$RpcResp", "json", function (response) {
            handleRpcResponse(scope, response);
         }, scope);
         init(scope);
         readyScope(scope);
         return function () {
            cleanupScope(scope);
         };
      },

      cleanupPage: function () {
         cleanupScope(currentScope);
      }
   };

   function installHtmxCleanupHandler() {
      document.body.addEventListener("htmx:beforeSwap", function (event) {
         var target = event.detail && event.detail.target;
         if (target && target.matches && target.matches(targetSelector)) {
            window.cmsSmq.cleanupPage();
         }
      });
   }

   if (document.body) {
      installHtmxCleanupHandler();
   } else {
      document.addEventListener("DOMContentLoaded", installHtmxCleanupHandler,
         { once: true });
   }
}(this, this.document));
