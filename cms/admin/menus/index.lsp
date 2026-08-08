<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, false) then return end
if request:method() == "POST" then
   local ok, err = pcall(admin.mutateMenu, app, admin.requestData(_ENV))
   if not ok then
      if type(err) == "table" and err.cmsValidation then
         response:senderror(400, err.message)
         return
      end
      error(err)
   end
   app.redirect(_ENV, "/admin/menus/")
   return
end
local esc = admin.html
adminTitle = "Menus"
adminActive = "menus"
response:include(app.url("/admin/includes/start.lsp"), true)
?>
<section class="panel">
   <div class="panel-body">
      <h2>Add Menu Item</h2>
      <form method="post" action="<?lsp= esc(app.url('/admin/menus/')) ?>"
            hx-post="<?lsp= esc(app.url('/admin/menus/action.lsp')) ?>"
            hx-target="#menu-add-status" hx-swap="innerHTML">
         <?lsp admin.csrfField(_ENV) ?>
         <div class="form-grid">
            <div class="field"><label>Label</label><input name="label" required></div>
            <div class="field"><label>URL</label><input name="url" required></div>
            <div class="field"><label>Parent ID</label><input name="parent_id" placeholder="Auto select; 0 for top level"></div>
            <div class="field"><label>Position</label><input name="position" value="0"></div>
         </div>
         <div class="actions"><button type="submit" name="action" value="add">Add</button></div>
         <div id="menu-add-status" class="fragment-status" aria-live="polite"></div>
      </form>
   </div>
</section>
<section class="panel">
   <div class="panel-body">
      <h2>Primary Menu</h2>
      <?lsp response:include(app.url("/admin/menus/list.lsp"), true) ?>
   </div>
</section>
<?lsp response:include(app.url("/admin/includes/end.lsp"), true) ?>
