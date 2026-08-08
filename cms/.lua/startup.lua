local M = {}

local function esc(value)
   value = tostring(value or "")
   value = value:gsub("&", "&amp;")
   value = value:gsub("<", "&lt;")
   value = value:gsub(">", "&gt;")
   value = value:gsub('"', "&quot;")
   value = value:gsub("'", "&#39;")
   return value
end

function M.fatal(app, opts)
   opts = opts or {}
   local startup = {
      ok = false,
      fatal = true,
      status = opts.status or 503,
      title = opts.title or "CMS startup failed",
      message = opts.message or "The CMS application could not initialize.",
      detail = opts.detail or "",
      action = opts.action or "Review the server trace output and restart the CMS after correcting the startup problem."
   }
   app.startup = startup
   trace("CMS fatal startup error:", startup.title, startup.message, startup.detail)
   return startup
end

function M.installFatalDir(app)
   if not app.startup or not app.startup.fatal then
      return nil
   end
   if app.startup.dir then
      return app.startup.dir
   end

   local dir = ba.create.dir(127)
   dir:setfunc(function(_ENV)
      local response = _ENV.response
      response:setstatus(app.startup.status or 503)
      response:setheader("Content-Type", "text/html; charset=utf-8")
      response:setheader("Cache-Control", "no-store")
      response:write("<!doctype html><html lang='en'><head><meta charset='utf-8'>")
      response:write("<meta name='viewport' content='width=device-width, initial-scale=1'>")
      response:write("<title>", esc(app.startup.title), "</title>")
      response:write([[<style>
:root{color-scheme:dark;--bg:#202124;--panel:#303134;--line:#5f6368;--text:#f8f9fa;--muted:#bdc1c6;--yellow:#ffcf43;--red:#f28b82}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
main{min-height:100vh;display:grid;place-items:center;padding:32px}.panel{width:min(920px,100%);background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:28px;box-shadow:0 18px 50px rgba(0,0,0,.32)}
.eyebrow{margin:0 0 10px;color:var(--red);font-weight:800;text-transform:uppercase;letter-spacing:.08em;font-size:12px}h1{margin:0 0 12px;font-size:28px;line-height:1.15}
p{margin:0 0 14px}.muted{color:var(--muted)}.action{margin-top:18px;padding:14px 16px;border:1px solid rgba(255,207,67,.42);border-radius:6px;background:rgba(255,207,67,.12);color:var(--yellow);font-weight:700}
pre{margin:18px 0 0;max-height:42vh;overflow:auto;white-space:pre-wrap;background:#171717;border:1px solid #454545;border-radius:6px;padding:14px;color:#f1f3f4}
code{color:var(--yellow)}
</style>]])
      response:write("</head><body><main><section class='panel'>")
      response:write("<p class='eyebrow'>Fatal startup error</p>")
      response:write("<h1>", esc(app.startup.title), "</h1>")
      response:write("<p>", esc(app.startup.message), "</p>")
      response:write("<p class='muted'>Mako Server is still running, but this CMS application was not mounted normally because initialization failed.</p>")
      response:write("<div class='action'>", esc(app.startup.action), "</div>")
      if app.startup.detail and app.startup.detail ~= "" then
         response:write("<pre>", esc(app.startup.detail), "</pre>")
      end
      response:write("</section></main></body></html>")
      return true
   end)

   local parentDir = app.publicDir or app.dir
   parentDir:insert(dir, true)
   app.startup.dir = dir
   return dir
end

return M
