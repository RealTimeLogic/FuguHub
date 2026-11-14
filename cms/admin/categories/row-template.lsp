<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
local esc = admin.html

function adminRenderCategory(row, message)
   local id = tostring(row.id)
?>
<form id="category-<?lsp= esc(id) ?>" method="post" class="item-form category-item"
      action="<?lsp= esc(app.url('/admin/categories/')) ?>"
      hx-post="<?lsp= esc(app.url('/admin/categories/action.lsp')) ?>"
      hx-target="#categories-list" hx-swap="outerHTML">
   <?lsp admin.csrfField(_ENV) ?>
   <input type="hidden" name="id" value="<?lsp= esc(id) ?>">
   <?lsp if message then ?><div class="save-confirmation" role="status"><?lsp= esc(message) ?></div><?lsp end ?>
   <div class="category-grid">
      <div><label>ID</label><span class="muted"><?lsp= esc(id) ?></span></div>
      <div><label for="category-<?lsp= id ?>-name">Name</label><input id="category-<?lsp= id ?>-name" name="name" value="<?lsp= esc(row.name) ?>" required></div>
      <div><label for="category-<?lsp= id ?>-slug">Slug</label><input id="category-<?lsp= id ?>-slug" name="slug" value="<?lsp= esc(row.slug) ?>" required></div>
      <div><label>Posts</label><span class="tag"><?lsp= esc(row.publishedPostCount) ?></span></div>
      <div class="category-description"><label for="category-<?lsp= id ?>-description">Description</label><textarea id="category-<?lsp= id ?>-description" class="short" name="description"><?lsp= esc(row.description) ?></textarea></div>
      <div class="actions item-actions">
         <a class="button secondary" href="<?lsp= esc(app.url(row.path)) ?>">View</a>
         <button type="submit" class="secondary" name="action" value="update">Save</button>
         <a class="button danger"
            href="<?lsp= esc(app.url('/admin/categories/delete?id=' .. id)) ?>"
            hx-get="<?lsp= esc(app.url('/admin/categories/delete.lsp?id=' .. id)) ?>"
            hx-target="closest form" hx-swap="outerHTML">Delete</a>
      </div>
   </div>
</form>
<?lsp
end
?>
