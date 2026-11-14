<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
local esc = admin.html
local data = admin.requestData(_ENV)
local id = tonumber(data.id)
if not id then response:senderror(400, "Missing menu item id"); return end
local fullPage = not admin.isHtmx(_ENV)
local message
local info, infoErr = admin.menuDeleteInfo(app, id)
if not info then
   response:senderror(404, infoErr or "Menu item not found")
   return
end

if request:method() == "POST" then
   local ok, err = pcall(admin.deleteMenuItem, app, data)
   if ok then
      if fullPage then app.redirect(_ENV, "/admin/menus/")
      else response:include(app.url("/admin/menus/list.lsp"), true) end
      return
   end
   if type(err) == "table" and err.cmsValidation then
      message = err.message
   else
      trace("admin menu delete failed:", tostring(err))
      message = "Delete failed. See the server trace for details."
   end
   if not fullPage then
      adminMenuMessageId = id
      adminMenuMessage = message
      adminMenuError = true
      response:include(app.url("/admin/menus/list.lsp"), true)
      return
   end
   response:setstatus(type(err) == "table" and err.cmsValidation and 400 or 500)
end
if fullPage then
   adminTitle, adminActive = "Delete Menu Item", "menus"
   response:include(app.url("/admin/includes/start.lsp"), true)
end
local depth = fullPage and 0 or math.min(tonumber(info.item.tree_depth) or 0, 8)
?>
<div id="menu-item-<?lsp= esc(id) ?>"
     class="inline-confirmation menu-tree-confirmation<?lsp if depth > 0 then ?> is-child<?lsp end ?>"
     data-menu-depth="<?lsp= depth ?>" style="--menu-depth:<?lsp= depth ?>">
   <h2>Delete Menu Item</h2>
   <?lsp if message then ?><div class="notice error" role="alert"><?lsp= esc(message) ?></div><?lsp end ?>
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
         <?lsp if not fullPage then ?>
         hx-post="<?lsp= esc(app.url('/admin/menus/delete.lsp')) ?>"
         hx-target="#menu-items" hx-swap="outerHTML"<?lsp end ?>>
      <?lsp admin.csrfField(_ENV) ?>
      <input type="hidden" name="id" value="<?lsp= esc(id) ?>">
      <input type="hidden" name="confirmed" value="true">
      <div class="actions">
         <button class="danger" type="submit">Delete Menu Item</button>
         <a class="button secondary" href="<?lsp= esc(app.url('/admin/menus/')) ?>"
                 <?lsp if not fullPage then ?>
                 hx-get="<?lsp= esc(app.url('/admin/menus/list.lsp')) ?>"
                 hx-target="#menu-items" hx-swap="outerHTML"<?lsp end ?>>Cancel</a>
      </div>
   </form>
</div>
<?lsp if fullPage then response:include(app.url("/admin/includes/end.lsp"), true) end ?>
