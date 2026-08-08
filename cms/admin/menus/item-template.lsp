<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
local esc = admin.html

function adminRenderMenuItem(row, message)
   local id = tostring(row.id)
   local hidden = tostring(row.hidden or "0") ~= "0"
   local depth = math.min(tonumber(row.tree_depth) or 0, 8)
?>
<form id="menu-item-<?lsp= esc(id) ?>" method="post"
      class="item-form menu-tree-item<?lsp if depth > 0 then ?> is-child<?lsp end ?>"
      data-menu-depth="<?lsp= depth ?>" style="--menu-depth:<?lsp= depth ?>"
      action="<?lsp= esc(app.url('/admin/menus/')) ?>"
      hx-post="<?lsp= esc(app.url('/admin/menus/action.lsp')) ?>"
      hx-target="#menu-items" hx-swap="outerHTML">
   <?lsp admin.csrfField(_ENV) ?>
   <input type="hidden" name="id" value="<?lsp= esc(id) ?>">
   <?lsp if depth > 0 then ?>
   <div class="menu-tree-context">Child of <strong><?lsp= esc(row.tree_parent_label or row.parent_id) ?></strong></div>
   <?lsp end ?>
   <?lsp if message then ?><div class="save-confirmation" role="status"><?lsp= esc(message) ?></div><?lsp end ?>
   <div class="item-grid">
      <div>
         <label>ID</label>
         <div class="item-id-value">
            <span class="muted"><?lsp= esc(id) ?></span>
            <?lsp if hidden then ?><span class="tag hidden">hidden</span><?lsp end ?>
         </div>
      </div>
      <div><label>Label</label><input name="label" value="<?lsp= esc(row.label) ?>" required></div>
      <div><label>URL</label><input name="url" value="<?lsp= esc(row.url) ?>" required></div>
      <div><label>Parent ID</label><input name="parent_id" placeholder="0 or blank for top level" value="<?lsp= esc(row.parent_id) ?>"></div>
      <div><label>Position</label><input name="position" value="<?lsp= esc(row.position) ?>"></div>
      <div class="actions item-actions">
         <button type="submit" class="secondary" name="action" value="update">Save</button>
         <button type="submit" class="<?lsp= hidden and 'hidden-toggle' or 'danger' ?>"
                 name="action" value="toggle-hidden"><?lsp= hidden and "Show" or "Hide" ?></button>
         <a class="button danger"
            href="<?lsp= esc(app.url('/admin/menus/delete?id=' .. id)) ?>"
            hx-get="<?lsp= esc(app.url('/admin/menus/delete.lsp?id=' .. id)) ?>"
            hx-target="closest form" hx-swap="outerHTML">Delete</a>
      </div>
   </div>
</form>
<?lsp
end
?>
