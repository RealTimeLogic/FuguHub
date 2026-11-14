<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
local model = adminContentEditor
if not model then response:senderror(404, "Not found"); return end
local row, isNew = model.row, model.isNew
local esc = admin.html
local function selected(value, option)
   return value == option and " selected" or ""
end
?>
<section class='panel'><div class='panel-body'>
   <form method='post' enctype='multipart/form-data'
         action='<?lsp= esc(app.url(isNew and "/admin/content/new" or "/admin/content/edit")) ?>'
         <?lsp if not isNew then ?>hx-post='<?lsp= esc(app.url("/admin/content/save.lsp")) ?>'
         hx-encoding='multipart/form-data' hx-target='#content-save-status' hx-swap='innerHTML'<?lsp end ?>>
      <?lsp admin.csrfField(_ENV) ?>
      <?lsp if not isNew then ?><input type='hidden' name='id' value='<?lsp= esc(row.id) ?>'><?lsp end ?>
      <div class='form-grid'>
         <div class='field'><label for='field-type'>Type</label><select id='field-type' name='type'>
            <option value='page'<?lsp= selected(row.type, "page") ?>>Page</option>
            <option value='post'<?lsp= selected(row.type, "post") ?>>Post</option>
         </select></div>
         <div class='field'><label for='field-status'>Status</label><select id='field-status' name='status'>
            <option value='published'<?lsp= selected(row.status, "published") ?>>Published</option>
            <option value='draft'<?lsp= selected(row.status, "draft") ?>>Draft</option>
         </select></div>
         <div class='field full'><label for='field-title'>Title</label><input id='field-title' name='title' value='<?lsp= esc(row.title) ?>' required></div>
         <div class='field'><label for='field-path'>Path</label><input id='field-path' name='path' value='<?lsp= esc(row.path) ?>' required><span class='muted'>For posts, enter only the article path. The configured Blog URL prefix is added automatically.</span></div>
         <div class='field'><label for='field-render_mode'>Render Mode</label><select id='field-render_mode' name='render_mode'>
            <option value='html'<?lsp= selected(row.render_mode, "html") ?>>HTML</option>
            <option value='lsp'<?lsp= selected(row.render_mode, "lsp") ?>>LSP</option>
         </select></div>
         <div class='field'><label for='field-cache_policy'>Browser Cache</label><select id='field-cache_policy' name='cache_policy'>
            <option value='default'<?lsp= selected(row.cache_policy, "default") ?>>Default</option>
            <option value='revalidate'<?lsp= selected(row.cache_policy, "revalidate") ?>>Revalidate</option>
            <option value='no-cache'<?lsp= selected(row.cache_policy, "no-cache") ?>>No cache</option>
            <option value='no-store'<?lsp= selected(row.cache_policy, "no-store") ?>>No store</option>
         </select></div>
         <div class='field full'><label for='field-meta_description'>Meta Description</label><textarea id='field-meta_description' class='short' name='meta_description'><?lsp= esc(row.meta_description) ?></textarea></div>
         <div class='field full'><label for='field-head_html'>Extra Head HTML</label><textarea id='field-head_html' class='short' name='head_html'><?lsp= esc(row.head_html) ?></textarea></div>
         <fieldset class='field full'><legend>Categories</legend>
            <?lsp if #model.categories == 0 then ?>
            <p class='muted'>No categories exist. <a href='<?lsp= esc(app.url("/admin/categories/")) ?>'>Create a category</a>.</p>
            <?lsp else ?>
            <div class='category-options'>
               <?lsp for _, category in ipairs(model.categories) do ?>
               <label class='choice-row'><input type='checkbox' name='category_<?lsp= esc(category.id) ?>' value='1'<?lsp if model.assignedCategories[tonumber(category.id)] then ?> checked<?lsp end ?>><strong><?lsp= esc(category.name) ?></strong></label>
               <?lsp end ?>
            </div><p class='muted'>Category assignments apply to posts.</p>
            <?lsp end ?>
         </fieldset>
         <div class='field full'><label for='field-body_html'>Body</label><textarea id='field-body_html' name='body_html'><?lsp= esc(row.body_html) ?></textarea></div>
      </div>
      <div class='actions'>
         <button type='submit'>Save</button>
         <?lsp if not isNew then ?><a class='button secondary' href='<?lsp= esc(app.url("/admin/content/preview?id=" .. row.id)) ?>'>Preview</a><?lsp end ?>
         <a class='button secondary' href='<?lsp= esc(app.url("/admin/content/")) ?>'>Cancel</a>
      </div>
      <?lsp if not isNew then ?><div id='content-save-status' class='fragment-status' aria-live='polite'></div><?lsp end ?>
   </form>
</div></section>
<?lsp if not isNew then ?>
<section class='panel danger-zone'><div class='panel-body'>
   <h2>Delete Content</h2>
   <p class='muted'>Permanently delete this content after reviewing its dependencies.</p>
   <a class='button danger' href='<?lsp= esc(app.url("/admin/content/delete?id=" .. row.id)) ?>'>Delete Permanently</a>
</div></section>
<?lsp end ?>
