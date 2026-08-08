<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
local esc = admin.html
local data = admin.requestData(_ENV)
local id = tonumber(data.id)
local info, infoErr = admin.menuDeleteInfo(app, id)
if not info then
   response:senderror(404, infoErr or "Menu item not found")
   return
end

if request:method() == "POST" then
   local ok, err = pcall(admin.deleteMenuItem, app, data)
   if ok then
      response:include(app.url("/admin/menus/list.lsp"), true)
      return
   end
   local message
   if type(err) == "table" and err.cmsValidation then
      message = err.message
   else
      trace("admin menu delete failed:", tostring(err))
      message = "Delete failed. See the server trace for details."
   end
   adminMenuMessageId = id
   adminMenuMessage = message
   response:include(app.url("/admin/menus/list.lsp"), true)
   return
end
local depth = math.min(tonumber(info.item.tree_depth) or 0, 8)
?>
<div id="menu-item-<?lsp= esc(id) ?>"
     class="inline-confirmation menu-tree-confirmation<?lsp if depth > 0 then ?> is-child<?lsp end ?>"
     data-menu-depth="<?lsp= depth ?>" style="--menu-depth:<?lsp= depth ?>">
   <h2>Delete Menu Item</h2>
   <p>Permanently delete <strong><?lsp= esc(info.item.label) ?></strong> from
      <?lsp= esc(info.item.menu_name) ?>?</p>
   <p class="muted">The content at <code><?lsp= esc(info.item.url) ?></code> will not be deleted.</p>
   <?lsp if #info.children > 0 then ?>
   <div class="notice">
      <strong>Child items will become top-level menu items.</strong>
      <ul class="dependency-list">
      <?lsp for _, child in ipairs(info.children) do ?>
         <li><?lsp= esc(child.label) ?> (<code><?lsp= esc(child.url) ?></code>)</li>
      <?lsp end ?>
      </ul>
   </div>
   <?lsp end ?>
   <form method="post"
         action="<?lsp= esc(app.url('/admin/menus/delete?id=' .. id)) ?>"
         hx-post="<?lsp= esc(app.url('/admin/menus/delete.lsp')) ?>"
         hx-target="#menu-items" hx-swap="outerHTML">
      <?lsp admin.csrfField(_ENV) ?>
      <input type="hidden" name="id" value="<?lsp= esc(id) ?>">
      <input type="hidden" name="confirmed" value="true">
      <div class="actions">
         <button class="danger" type="submit">Delete Menu Item</button>
         <button class="secondary" type="button"
                 hx-get="<?lsp= esc(app.url('/admin/menus/list.lsp')) ?>"
                 hx-target="#menu-items" hx-swap="outerHTML">Cancel</button>
      </div>
   </form>
</div>
