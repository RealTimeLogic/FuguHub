---
name: cms-smq
description: Use when building real-time FuguHub pages with the CMS-owned SMQ broker, HTMX page scopes, direct messaging, events, or page-scoped RPC.
---

# FuguHub SMQ Applications

## Remote MCP Boundary

When this guide is delivered by a remote FuguHub server, use only its HTTP MCP
tools, resources, and prompts. Do not open or infer server filesystem paths,
inspect the SQLite database directly, or bypass MCP with another server-side
access method. Call `getCapabilities` before relying on optional operations.
Read related guidance with `getGuide`; use `getReference` with `id="smq"` for
the authoritative native SMQ API source. If the required operation is not
exposed, report it as unsupported instead of creating a workaround.

FuguHub can keep one SMQ connection in the public HTMX shell while page
fragments mount and unmount temporary messaging behavior. Use this guide for
real-time database pages and LSP applications under `assets/`.

This guide defines the CMS lifecycle layered on the native SMQ APIs.

Read the `assets` guide before creating browser or server application files.
SMQ application code belongs in site assets, not in a page-specific theme.

## Enablement

SMQ is disabled by default. Enable HTMX first, then enable SMQ under
`/admin/settings/`. Disabling HTMX also disables SMQ.

MCP discovery reports this under `getCapabilities.realTimeMessaging.smq`.
`available` means the CMS runtime API exists; `enabled` reports the current
site setting. SMQ does not add a standalone MCP mutation tool.

When enabled:

- the CMS starts one application-local `smq.hub` broker;
- the mount-aware endpoint is `app.url("/SMQ/")`;
- the full theme shell loads Mako's `/rtl/smq.js`;
- the shell loads the CMS client manager from
  `app.url("/assets/smq/cms-smq.js")`;
- HTMX fragment requests do not create additional clients.

The broker can be enabled or disabled without restarting Mako.

## Browser Page Scopes

Page fragments must not call `SMQ.Client(...)`. The shell owns that client.
Mount page behavior with `window.cmsSmq.mountPage(...)`:

```html
<section id="device-status">
  <output id="state">Waiting</output>
</section>
<script>
window.cmsSmq.mountPage("Device status", function (scope) {
  var output = document.getElementById("state");

  scope.subscribeToEvent("DeviceState", function (message) {
    output.textContent = message.state;
  });

  scope.onReady(async function () {
    try {
      var status = await scope.rpc.getDeviceStatus();
      output.textContent = status.state;
    } catch (error) {
      output.textContent = error.message;
    }
  });

  scope.onCleanup(function () {
    // Stop page-owned timers and remove non-SMQ listeners here.
  });
});
</script>
```

Use one consistent event envelope. Do not send `senderId` and then attempt to
read `clientId`, or omit the channel and identity from transient events such as
typing notifications:

```json
{
  "kind": "typing",
  "channel": "lobby",
  "clientId": "browser-instance",
  "name": "Guest",
  "active": true,
  "at": 1785255000000
}
```

The scope API is:

- `scope.subscribeToEvent(topic, handler, datatype)`: subscribe to a broadcast
  topic. The default datatype is `json`.
- `scope.subscribeToDirectMessage(subtopic, handler, datatype)`: subscribe to
  a direct message addressed to this browser's ephemeral TID.
- `scope.sendToBroker(subtopic, payload)`: publish JSON to broker TID `1`.
- `scope.sendToPeer(peerTid, subtopic, payload)`: direct JSON publish to a
  known peer.
- `scope.publishEvent(topic, payload)`: broadcast JSON on a named topic.
- `scope.callRpc(name, ...args)`: correlated Promise-based RPC.
- `scope.rpc.methodName(...args)`: proxy for `callRpc`.
- `scope.onReady(callback)`: run after the page's subscription barrier is
  acknowledged.
- `scope.onCleanup(callback)`: run before HTMX replaces the theme's configured
  fragment target.

Pending RPC calls are rejected when the page unloads or SMQ disconnects.
Reconnect rebuilds active subscriptions and reruns `onReady` after a new
barrier acknowledgment. This applies after a transport outage, an in-process
CMS reload, and a Mako restart on the same origin. Keep initialization in
`onReady`: it may run more than once during the lifetime of a page scope.

The CMS intentionally closes broker sockets without a terminal SMQ
`DISCONNECT` frame when the CMS unloads. This lets Mako's SMQ browser client
retry until the CMS is available again. Explicitly disabling SMQ remains a
terminal disconnect and does not reconnect.

## Server API In `assets/.preload`

The CMS installs `app.smq` before executing `assets/.preload`. The API exists
even while SMQ is disabled, so application registrations are ready if an
administrator enables it later.

Register an RPC method:

```lua
local remove, err = app.smq:registerRpcMethod("getDeviceStatus", function()
   return { state = "ready" }
end)
if not remove then error(err) end
```

RPC callbacks may return `result` or `nil, errorMessage`. Lua errors are caught
and returned as rejected browser Promises.

Register native broker subscriptions or setup:

```lua
local remove, err = app.smq:onBrokerStart(function(broker)
   broker:subscribe("self", {
      subtopic = "SetOutput",
      json = true,
      onmsg = function(data, ptid)
         -- Validate authorization and payload before changing state.
         broker:publish({ ok = true }, ptid, "SetOutputResp")
      end
   })
end)
if not remove then error(err) end
```

The callback runs immediately if the broker is active and runs again whenever
the broker is recreated. Use the native broker argument only inside this
callback or code whose lifetime is bounded by it; do not retain it across
broker restarts.

Publish from application code:

```lua
local queued, err = app.smq:publish({ state = "ready" }, "DeviceState")
if queued == nil then
   mako.log("SMQ publish failed: " .. tostring(err))
end
```

Additional state methods:

- `app.smq:isEnabled()`
- `app.smq:isRunning()`
- `app.smq:broker()`: current native broker or `nil`

RPC methods and broker-start callbacks registered while `assets/.preload`
executes belong to that assets application. `restartAssetsApplication` removes
the old registrations, runs `onunload`, loads the replacement application, and
recreates an active broker so native subscriptions cannot remain stale.

## RPC Wire Contract

The browser sends this JSON directly to broker TID `1` on `"$RpcReq"`:

```json
{"id":"page-id:1","name":"getDeviceStatus","args":[]}
```

The CMS replies directly to that browser on `"$RpcResp"`:

```json
{"id":"page-id:1","rsp":{"state":"ready"}}
```

Failures use the same id and an `err` field.

Use RPC for bounded request/response work. Use event topics for shared state,
explicit request/response subtopics for command protocols, and HTTP for large
payloads or file transfer.

## Theme Contract

The full shell receives:

- `model.smqEnabled`
- `model.smqEndpoint`

When `model.smqEnabled` is true, the shell must emit endpoint and swap-target
metadata before loading the two scripts:

```lsp
<meta name="fuguhub-smq-endpoint" content="<?lsp= attr(model.smqEndpoint) ?>">
<meta name="fuguhub-smq-target" content="#cms-main">
<script src="/rtl/smq.js"></script>
<script src="<?lsp= attr(model.url('/assets/smq/cms-smq.js')) ?>"></script>
```

The target must be the same element replaced by HTMX fragments. The default
theme uses `#cms-main`. `/rtl/smq.js` is a server-root Mako resource and must
not be prefixed with the CMS mount path.

The theme provides this generic shell only. Put the page's SMQ client in a site
asset. Do not conditionally embed it in `layout.lsp` for one content path:
HTMX navigation into that path uses `fragment.lsp` and will not rerun the
document head or full-shell script list.

## Security

Admin authentication protects the CMS admin directory only. It does not
authenticate public SMQ clients.

Application code must validate every command and RPC argument and must add
broker authentication/authorization appropriate for the deployed application.
Prefer browser-to-broker commands followed by validated server broadcasts.
Avoid privileged direct browser-to-device commands unless peer authorization
is explicitly designed.

## Verification

Test all of the following:

1. SMQ cannot be enabled while HTMX is disabled.
2. An ordinary HTTP request to the active SMQ endpoint returns an error.
3. A full page creates one connection.
4. HTMX navigation keeps that connection and cleans the old page scope.
5. Broadcast, direct, and RPC paths work.
6. Concurrent RPC responses correlate by id.
7. Pending RPC rejects on page cleanup and disconnect.
8. In-process CMS reload and Mako stop/restart restore subscriptions and rerun
   `onReady` without reloading the browser page.
9. Root and named CMS mounts use the correct endpoint.
10. Assets application restart removes old RPC and broker registrations.
11. The application page works when opened directly and when entered through
    HTMX from another page.
12. Event sender and receiver use identical field names, and queued UI state is
    cleared after successful delivery.
