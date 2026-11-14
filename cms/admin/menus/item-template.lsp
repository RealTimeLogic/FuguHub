<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
local esc = admin.html

function adminRenderMenuParent(items, row, oob)
   local fieldId = row and "menu-" .. row.id .. "-parent_id" or "menu-add-parent_id"
   local parent = row and tostring(row.parent_id or "0") or ""
   local choices, found = {}, parent == "0" or not row
   for _, candidate in ipairs(items) do
      if candidate.tree_valid_parent and (not row or
         candidate.tree_start < row.tree_start or candidate.tree_start > row.tree_end) then
         choices[#choices + 1] = candidate
         if tostring(candidate.id) == parent then found = true end
      end
   end
?>
<select id="<?lsp= esc(fieldId) ?>" name="parent_id"<?lsp if row then ?> required<?lsp else ?> aria-describedby="menu-parent-help"<?lsp end ?><?lsp if oob then ?> hx-swap-oob="outerHTML"<?lsp end ?>>
   <?lsp if not row then ?><option value="">Automatic (from URL)</option><?lsp end ?>
   <?lsp if not found then ?><option value="" selected disabled>Choose a valid parent</option><?lsp end ?>
   <option value="0"<?lsp if parent == "0" then ?> selected<?lsp end ?>>Top level</option>
   <?lsp for _, candidate in ipairs(choices) do ?>
   <option value="<?lsp= esc(candidate.id) ?>"<?lsp if tostring(candidate.id) == parent then ?> selected<?lsp end ?>><?lsp= esc(candidate.tree_path .. " (" .. candidate.url .. ")" .. (tonumber(candidate.hidden) == 1 and " [hidden]" or "")) ?></option>
   <?lsp end ?>
</select>
<?lsp
end

function adminRenderMenuItem(row, message, items, isError)
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
   <?lsp if message then ?><div class="<?lsp= isError and 'notice error compact' or 'save-confirmation' ?>" role="<?lsp= isError and 'alert' or 'status' ?>"><?lsp= esc(message) ?></div><?lsp end ?>
   <div class="item-grid">
      <div>
         <label>ID</label>
         <div class="item-id-value">
            <span class="muted"><?lsp= esc(id) ?></span>
            <?lsp if hidden then ?><span class="tag hidden">hidden</span><?lsp end ?>
         </div>
      </div>
      <div><label for="menu-<?lsp= id ?>-label">Label</label><input id="menu-<?lsp= id ?>-label" name="label" value="<?lsp= esc(row.label) ?>" required></div>
      <div><label for="menu-<?lsp= id ?>-url">URL</label><input id="menu-<?lsp= id ?>-url" name="url" value="<?lsp= esc(row.url) ?>" required></div>
      <div><label for="menu-<?lsp= id ?>-parent_id">Parent</label><?lsp adminRenderMenuParent(items, row) ?></div>
      <div><label for="menu-<?lsp= id ?>-position">Position</label><input type="number" step="1" id="menu-<?lsp= id ?>-position" name="position" value="<?lsp= esc(row.position) ?>"></div>
      <div class="actions item-actions">
         <button type="submit" class="secondary" name="action" value="update">Save</button>
         <button type="submit" formnovalidate class="<?lsp= hidden and 'hidden-toggle' or 'danger' ?>"
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
