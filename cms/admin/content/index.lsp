<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, false) then return end
adminTitle = "Content"
adminActive = "content"
response:include(app.url("/admin/includes/start.lsp"), true)
response:include(app.url("/admin/content/list.lsp"), true)
response:include(app.url("/admin/includes/end.lsp"), true)
?>
