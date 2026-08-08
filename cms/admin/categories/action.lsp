<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
if request:method() ~= "POST" then
   response:senderror(405, "Method not allowed")
   return
end
local data = admin.requestData(_ENV)
local ok, row = pcall(admin.mutateCategory, app, data)
local message
if not ok then
   if type(row) == "table" and row.cmsValidation then
      message = row.message
   else
      trace("admin category action failed:", tostring(row))
      message = "Operation failed. See the server trace for details."
   end
   row = admin.categoryRow(app, data.id)
   if not row then
?>
<span class="notice error compact" role="alert"><?lsp= admin.html(message) ?></span>
<?lsp return end
end

if data.action == "add" then
?>
<span class="save-confirmation" role="status">Category added.</span>
<?lsp
   adminCategoriesOob = true
   response:include(app.url("/admin/categories/list.lsp"), true)
   return
end

adminCategoryMessageId = row.id
adminCategoryMessage = message or "Saved."
response:include(app.url("/admin/categories/list.lsp"), true)
?>
