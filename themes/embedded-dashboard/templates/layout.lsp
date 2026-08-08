<?lsp
local model=select(6,...)
local app=select(5,...)
local http=app.appreq "cmshttp"
local esc=http.html
local attr=http.htmlAttr
local content=model.content or {}
local title=content.title or model.site.title or "Dashboard"
local current=request:uri():gsub("%?.*$","")
local url=model.url or function(path)return path end
local function selected(item)
 if not item or not item.url or item.url=="" then return false end
 local itemUrl=url(item.url):gsub("%?.*$","")
 if itemUrl=="/" then return current=="/" end
 local prefix=itemUrl:sub(-1)=="/" and itemUrl or itemUrl.."/"
 return current==itemUrl or current:sub(1,#prefix)==prefix
end
local function menu(items)
 if not items or #items==0 then return end
 response:write("<ul class='nav-list'>")
 for _,item in ipairs(items) do
  local hasChildren=item.children and #item.children>0
  response:write("<li")
  if selected(item) then response:write(" class='selected'") end
  response:write("><div class='menu-item-entry'><a class='menu-link' href='",attr(url(item.url)),"'")
  if selected(item) then response:write(" aria-current='page'") end
  response:write(">",esc(item.label),"</a>")
  if hasChildren then response:write("<button type='button' class='submenu-toggle' aria-expanded='false' aria-label='Toggle submenu for ",attr(item.label),"'><span aria-hidden='true'>&#9662;</span></button>") end
  response:write("</div>")
  if hasChildren then menu(item.children) end
  response:write("</li>")
 end
 response:write("</ul>")
end
local function renderContent()
 response:write("<section class='panel content-panel'><div class='content-body'>")
 if model.renderBody then model.renderBody() else response:write("<div class='state-panel state-empty' role='status'><strong>No content available</strong><p>This page does not have body content yet.</p></div>") end
 response:write("</div></section>")
end
?>
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title><?lsp= esc(title) ?></title>
<?lsp if content.meta_description and content.meta_description~="" then ?><meta name="description" content="<?lsp= attr(content.meta_description) ?>"><?lsp end ?>
<link rel="stylesheet" href="<?lsp= attr(url('/theme/style.css')) ?>">
<?lsp if model.smqEnabled then ?><meta name="fuguhub-smq-endpoint" content="<?lsp= attr(model.smqEndpoint) ?>"><meta name="fuguhub-smq-target" content="#cms-main"><?lsp end ?>
<?lsp if content.head_html and content.head_html~="" then response:write(content.head_html) end ?>
</head>
<body>
<div class="site-shell" id="cms-htmx-scope"<?lsp if model.htmxEnabled then ?> hx-boost="true" hx-push-url="true" hx-target="#cms-main" hx-swap="outerHTML show:window:top" hx-history-elt<?lsp end ?>>
<div class="dashboard-shell">
<button class="nav-backdrop" type="button" data-nav-backdrop aria-label="Close navigation" hidden></button>
<aside class="dashboard-sidebar" id="dashboard-sidebar" aria-label="Dashboard navigation">
<div class="sidebar-head"><a class="brand" href="<?lsp= attr(url('/')) ?>"><strong>Embedded</strong></a><button class="nav-close" type="button" data-nav-close aria-label="Close navigation"><span aria-hidden="true">&#215;</span></button></div>
<div class="connection-pill" data-system-status data-state="online" role="status" aria-live="polite"><span class="connection-dot" aria-hidden="true"></span><span data-system-status-text>CMS connected</span></div>
<nav class="dashboard-nav site-nav" aria-label="Primary navigation"><?lsp menu(model.menu) ?></nav>
<div class="theme-controls"><button class="theme-control" type="button" data-contrast-toggle aria-pressed="false">High contrast</button></div>
</aside>
<div class="dashboard-workspace">
<header class="mobile-toolbar"><button class="nav-open" type="button" data-nav-open aria-controls="dashboard-sidebar" aria-expanded="false"><span aria-hidden="true">&#9776;</span><span>Menu</span></button><span class="mobile-brand">Embedded</span></header>
<div class="request-progress" data-request-progress role="status" aria-live="polite" hidden><span class="request-progress-dot" aria-hidden="true"></span>Updating dashboard…</div>
<main id="cms-main" class="site-main" data-cms-title="<?lsp= attr(title) ?>" data-cms-path="<?lsp= attr(current) ?>"><div class="content-shell"><h1><?lsp= esc(title) ?></h1><?lsp renderContent() ?></div></main>
</div></div></div>
<script defer src="<?lsp= attr(url('/theme/cms.js')) ?>"></script>
<?lsp if model.htmxEnabled then ?><script defer src="<?lsp= attr(url('/assets/htmx/htmx.min.js')) ?>"></script><?lsp end ?>
<?lsp if model.smqEnabled then ?>
<script src="/rtl/smq.js"></script><script src="<?lsp= attr(url('/assets/smq/cms-smq.js')) ?>"></script>
<script>if(window.cmsSmq&&typeof window.cmsSmq.mountPage==="function"){window.cmsSmq.mountPage("<?lsp= attr(title) ?>",function(scope){scope.onReady(function(){})})}</script>
<?lsp end ?>
</body></html>
