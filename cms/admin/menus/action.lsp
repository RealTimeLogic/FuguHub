<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
if request:method() ~= "POST" then
   response:senderror(405, "Method not allowed")
   return
end
local data = admin.requestData(_ENV)
local ok, row = pcall(admin.mutateMenu, app, data)
local message
if not ok then
   adminMenuError = true
   adminMenuDraft = data.action == "update" and data or nil
   if type(row) == "table" and row.cmsValidation then
      message = row.message
   else
      trace("admin menu action failed:", tostring(row))
      message = "Operation failed. See the server trace for details."
   end
   row = admin.menuItem(app, data.id)
   if not row then
?>
<span class="notice error compact" role="alert"><?lsp= admin.html(message) ?></span>
<?lsp return end
end

if data.action == "add" then
?>
<span class="save-confirmation" role="status">Menu item added.</span>
<?lsp
   adminMenuOob = true
   response:include(app.url("/admin/menus/list.lsp"), true)
   return
end

adminMenuMessageId = row.id
adminMenuMessage = message or (data.action == "toggle-hidden" and "Visibility updated." or "Saved.")
response:include(app.url("/admin/menus/list.lsp"), true)
?>
