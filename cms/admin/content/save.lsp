<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
if request:method() ~= "POST" then
   response:senderror(405, "Method not allowed")
   return
end
local ok, result = pcall(admin.persistContent, app, admin.requestData(_ENV), false)
if not ok then
   local message
   if type(result) == "table" and result.cmsValidation then
      message = result.message
   else
      trace("admin content save failed:", tostring(result))
      message = "Save failed. See the server trace for details."
   end
?>
<span class="notice error compact" role="alert"><?lsp= admin.html(message) ?></span>
<?lsp return end ?>
<span class="save-confirmation" role="status">Saved <strong><?lsp= admin.html(result.title) ?></strong>.</span>
