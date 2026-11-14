<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, false) then return end
if request:method() == "POST" then
   local ok, err = pcall(admin.mutateCategory, app, admin.requestData(_ENV))
   if not ok then
      if type(err) == "table" and err.cmsValidation then
         response:senderror(400, err.message)
         return
      end
      error(err)
   end
   app.redirect(_ENV, "/admin/categories/")
   return
end
local esc = admin.html
adminTitle = "Categories"
adminActive = "categories"
response:include(app.url("/admin/includes/start.lsp"), true)
?>
<section class="panel">
   <div class="panel-body">
      <h2>Add Category</h2>
      <form method="post" action="<?lsp= esc(app.url('/admin/categories/')) ?>"
            hx-post="<?lsp= esc(app.url('/admin/categories/action.lsp')) ?>"
            hx-target="#category-add-status" hx-swap="innerHTML">
         <?lsp admin.csrfField(_ENV) ?>
         <div class="form-grid">
            <div class="field"><label for="category-add-name">Name</label><input id="category-add-name" name="name" required></div>
            <div class="field"><label for="category-add-slug">Slug</label><input id="category-add-slug" name="slug" placeholder="Generated from name"></div>
            <div class="field full"><label for="category-add-description">Description</label><textarea id="category-add-description" class="short" name="description"></textarea></div>
         </div>
         <div class="actions"><button type="submit" name="action" value="add">Add Category</button></div>
         <div id="category-add-status" class="fragment-status" aria-live="polite"></div>
      </form>
   </div>
</section>
<section class="panel">
   <div class="panel-body">
      <h2>Blog Categories</h2>
      <?lsp response:include(app.url("/admin/categories/list.lsp"), true) ?>
   </div>
</section>
<?lsp response:include(app.url("/admin/includes/end.lsp"), true) ?>
