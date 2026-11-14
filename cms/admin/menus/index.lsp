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
adminMenuItems = admin.menuTreeItems(app)
adminTitle = "Menus"
adminActive = "menus"
response:include(app.url("/admin/includes/start.lsp"), true)
response:include(app.url("/admin/menus/item-template.lsp"), true)
?>
<section class="panel">
   <div class="panel-body">
      <h2>Add Menu Item</h2>
      <form method="post" action="<?lsp= esc(app.url('/admin/menus/')) ?>"
            hx-post="<?lsp= esc(app.url('/admin/menus/action.lsp')) ?>"
            hx-target="#menu-add-status" hx-swap="innerHTML">
         <?lsp admin.csrfField(_ENV) ?>
         <div class="form-grid">
            <div class="field"><label for="menu-add-label">Label</label><input id="menu-add-label" name="label" required></div>
            <div class="field"><label for="menu-add-url">URL</label><input id="menu-add-url" name="url" required></div>
            <div class="field"><label for="menu-add-parent_id">Parent</label><?lsp adminRenderMenuParent(adminMenuItems) ?>
               <small id="menu-parent-help" class="muted">Automatic places the item beneath a matching menu URL. Choose Top level to keep it at the root.</small></div>
            <div class="field"><label for="menu-add-position">Position</label><input type="number" step="1" id="menu-add-position" name="position" value="0"></div>
         </div>
         <div class="actions"><button type="submit" name="action" value="add">Add</button></div>
         <div id="menu-add-status" class="fragment-status" aria-live="polite"></div>
      </form>
   </div>
</section>
<section class="panel">
   <div class="panel-body">
      <h2>Primary Menu</h2>
      <p class="muted">Choose a parent by name to move an item. Lower positions appear first among siblings.</p>
      <?lsp response:include(app.url("/admin/menus/list.lsp"), true) ?>
   </div>
</section>
<?lsp response:include(app.url("/admin/includes/end.lsp"), true) ?>
