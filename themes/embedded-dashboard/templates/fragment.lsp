<?lsp
local model=select(6,...)
local app=select(5,...)
local http=app.appreq "cmshttp"
local esc=http.html
local attr=http.htmlAttr
local content=model.content or {}
local title=content.title or model.site.title or "Dashboard"
local current=request:uri():gsub("%?.*$","")
?>
<main id="cms-main" class="site-main" data-cms-title="<?lsp= attr(title) ?>" data-cms-path="<?lsp= attr(current) ?>">
<div class="content-shell"><h1><?lsp= esc(title) ?></h1><section class="panel content-panel"><div class="content-body">
<?lsp if model.renderBody then model.renderBody() else ?><div class="state-panel state-empty" role="status"><strong>No content available</strong><p>This page does not have body content yet.</p></div><?lsp end ?>
</div></section></div>
</main>
