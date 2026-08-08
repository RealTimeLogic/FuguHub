<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
local esc = admin.html
local data = admin.requestData(_ENV)
local rows, filter = admin.contentRows(app, adminFilter or data.type)
local function active(value)
   return filter == value and " active" or ""
end
response:include(app.url("/admin/content/row-template.lsp"), true)
?>
<div id="content-list">
   <section class="panel">
      <div class="panel-body">
         <div class="toolbar">
            <div class="tabs">
               <a class="button secondary<?lsp= active("") ?>"
                  href="<?lsp= esc(app.url('/admin/content/')) ?>"
                  hx-get="<?lsp= esc(app.url('/admin/content/list.lsp')) ?>"
                  hx-target="#content-list" hx-swap="outerHTML"
                  hx-push-url="<?lsp= esc(app.url('/admin/content/')) ?>">All</a>
               <a class="button secondary<?lsp= active("page") ?>"
                  href="<?lsp= esc(app.url('/admin/content/?type=page')) ?>"
                  hx-get="<?lsp= esc(app.url('/admin/content/list.lsp?type=page')) ?>"
                  hx-target="#content-list" hx-swap="outerHTML"
                  hx-push-url="<?lsp= esc(app.url('/admin/content/?type=page')) ?>">Pages</a>
               <a class="button secondary<?lsp= active("post") ?>"
                  href="<?lsp= esc(app.url('/admin/content/?type=post')) ?>"
                  hx-get="<?lsp= esc(app.url('/admin/content/list.lsp?type=post')) ?>"
                  hx-target="#content-list" hx-swap="outerHTML"
                  hx-push-url="<?lsp= esc(app.url('/admin/content/?type=post')) ?>">Posts</a>
            </div>
            <a class="button" href="<?lsp= esc(app.url('/admin/content/new')) ?>">New Content</a>
         </div>
      </div>
   </section>
   <section class="panel admin-table-scroll">
      <table>
         <thead><tr>
            <th>ID</th><th>Type</th><th>Title</th><th>Path</th>
            <th>Render</th><th>Cache</th><th>Status</th><th></th>
         </tr></thead>
         <tbody>
         <?lsp for _, row in ipairs(rows) do adminRenderContentRow(row) end ?>
         </tbody>
      </table>
   </section>
</div>
