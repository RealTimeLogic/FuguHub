<?lsp
-- Login uses the native challenge instead of the authenticated admin-page guard.
local authinfo = adminLogin
if not response:isinclude() or not authinfo then
   response:senderror(404, "Not found")
   return
end
local admin = app.appreq "admin"
local esc = admin.html
?>
<!doctype html>
<html lang="en">
<head>
   <meta charset='utf-8'>
   <meta name='viewport' content='width=device-width, initial-scale=1'>
   <title>Admin Login - CMS Admin</title>
   <link rel='stylesheet' href='<?lsp= esc(app.url("/admin/admin.css?v=" .. admin.cssVersion)) ?>'>
   <script src='/rtl/jquery.js'></script>
   <script src='/rtl/sha1.js'></script>
</head>
<body><main class='login-shell'>
   <section class='login-panel'><h1>CMS Admin</h1>
      <p class='muted'>Sign in to manage content, themes, and settings.</p>
      <?lsp if authinfo.username then ?>
      <div class='notice error' id='login-error' role='alert'>Login failed for <?lsp= esc(authinfo.username) ?>.</div>
      <?lsp end ?>
      <form method='post'>
         <div class='field'><label for='login-username'>Username</label><input id='login-username' name='ba_username' value='<?lsp= esc(authinfo.username) ?>' autocomplete='username' autofocus required<?lsp if authinfo.username then ?> aria-describedby='login-error'<?lsp end ?>></div>
         <div class='field'><label for='login-password'>Password</label><input id='login-password' name='ba_password' type='password' autocomplete='current-password' required></div>
         <input type='hidden' name='ba_seed' value='<?lsp= esc(authinfo.seed) ?>'>
         <input type='hidden' name='ba_seedkey' value='<?lsp= esc(authinfo.seedkey) ?>'>
         <div class='actions'><input class='button' type='submit' id='ba_loginbut' value='Login'></div>
      </form>
   </section>
</main></body>
</html>
