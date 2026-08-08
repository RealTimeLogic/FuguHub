<?lsp
local admin = app.appreq "admin"
local adminauth = app.appreq "adminauth"
if not admin.guardLsp(_ENV, app, true) then return end
local esc = admin.html
local title = adminTitle or "CMS Admin"
local active = adminActive or ""
local authInfo = adminauth.info(app)
local identityAccessInstalled = app.identityAccessUi ~= nil
local externalIdentityAccess = authInfo.borrowed and authInfo.managementUrl
?>
<!doctype html>
<html>
<head>
   <meta charset="utf-8">
   <meta name="viewport" content="width=device-width, initial-scale=1">
   <title><?lsp= esc(title) ?> - CMS Admin</title>
   <link rel="stylesheet" href="<?lsp= esc(app.url('/admin/admin.css')) ?>">
   <script defer src="<?lsp= esc(app.url('/admin/admin.js')) ?>"></script>
   <script defer src="<?lsp= esc(app.url('/assets/htmx/htmx.min.js')) ?>"></script>
</head>
<body>
<div class="admin-shell">
   <aside class="sidebar">
      <h1 class="brand">CMS Admin</h1>
      <nav class="nav">
      <?lsp for _, item in ipairs(admin.nav) do ?>
         <?lsp if item.id ~= "users" or (not identityAccessInstalled and not externalIdentityAccess) then ?>
         <a href="<?lsp= esc(app.url(item.href)) ?>"<?lsp if item.id == active then ?> class="active"<?lsp end ?>><?lsp= esc(item.label) ?></a>
         <?lsp end ?>
      <?lsp end ?>
      <?lsp if externalIdentityAccess then ?>
         <a href="<?lsp= esc(externalIdentityAccess) ?>">Users &amp; Access</a>
      <?lsp end ?>
      <?lsp if app.pluginAdmin then for _, item in ipairs(app.pluginAdmin.nav) do ?>
         <a href="<?lsp= esc(app.url(item.href)) ?>"><?lsp= esc(item.label) ?></a>
      <?lsp end end ?>
      </nav>
   </aside>
   <main class="content">
      <div class="topbar">
         <h1><?lsp= esc(title) ?></h1>
         <a href="<?lsp= esc(app.url('/')) ?>" class="button secondary">View Site</a>
      </div>
      <?lsp if not adminauth.available(app) then ?>
      <div class="notice">Admin authentication is unavailable: <?lsp= esc(adminauth.reason(app) or "Identity service error") ?>.</div>
      <?lsp elseif not adminauth.enabled(app) then ?>
      <?lsp
      local setupUrl = app.identityAccessUi and
         (app.identityAccessUi.managementUrl or app.url('/admin/plugins/identity-access/')) or
         externalIdentityAccess or app.url('/admin/users/')
      local setupLabel = (app.identityAccessUi or externalIdentityAccess) and
         "Configure a CMS administrator" or "Add an admin user"
      ?>
      <div class="notice">Admin authentication is disabled. <a href="<?lsp= esc(setupUrl) ?>"><?lsp= esc(setupLabel) ?></a> to enable it.</div>
      <?lsp end ?>
