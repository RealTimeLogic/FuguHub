<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
local model = adminSettings
if not model then response:senderror(404, "Not found"); return end
local values, esc = model.values, admin.html
?>
<?lsp if model.message then ?>
<div class='notice error' role='alert'><?lsp= esc(model.message) ?></div>
<?lsp elseif model.saved then ?>
<p class='save-confirmation' role='status'>Settings saved.</p>
<?lsp end ?>
<section class='panel'><div class='panel-body'><h2>Public Site</h2>
   <form method='post' action='<?lsp= esc(app.url("/admin/settings/")) ?>'>
      <?lsp admin.csrfField(_ENV) ?>
      <div class='form-grid'><div class='field'>
         <label for='field-blog_base_path'>Blog URL prefix</label><input id='field-blog_base_path' name='blog_base_path' value='<?lsp= esc(values.blogBasePath) ?>' placeholder='/blog/' required>
         <span class='muted'>For example, /blog/ puts posts under /blog/post-name/. Changing this changes public post addresses.</span>
      </div></div>
      <label class='check-row'><input id='setting-htmx' type='checkbox' name='htmx_enabled' value='1'<?lsp if values.htmxEnabled then ?> checked<?lsp end ?>>
         <span><strong>Update pages without a full reload (HTMX)</strong><span class='muted'>Keep navigation in place while loading new page content. Requires a theme that supports HTMX.</span></span></label>
      <label class='check-row'><input id='setting-smq' type='checkbox' name='smq_enabled' value='1'<?lsp if values.smqEnabled then ?> checked<?lsp end ?><?lsp if not values.htmxEnabled then ?> disabled<?lsp end ?>>
         <span><strong>Enable live application updates (SMQ)</strong><span class='muted'>For applications such as live dashboards or chat. Requires HTMX and application code that uses SMQ.</span></span></label>
      <div class='form-grid' style='margin-top:16px'><div class='field'>
         <label for='field-not_found_path'>Page for missing URLs</label><input id='field-not_found_path' name='not_found_path' value='<?lsp= esc(values.notFoundPath) ?>' placeholder='/404/' required>
      </div></div>
      <label class='check-row'><input type='checkbox' name='not_found_enabled' value='1'<?lsp if values.notFoundEnabled then ?> checked<?lsp end ?>>
         <span><strong>Show a custom page for missing URLs</strong><span class='muted'>Use the CMS page above when a requested address does not exist. Edit that page in Content. Browsers and search engines still receive a 404 status.</span></span></label>
      <div class='actions'><button type='submit'>Save Settings</button></div>
   </form>
</div></section>
<script defer src='<?lsp= esc(app.url("/admin/settings.js")) ?>'></script>
