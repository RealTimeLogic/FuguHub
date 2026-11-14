<?lsp
local admin = app.appreq "admin"
if not admin.guardLsp(_ENV, app, true) then return end
local model, esc = adminMcp, admin.html
if not model then response:senderror(404, "Not found"); return end
?>
<?lsp if model.message then ?><div class='notice error' role='alert'><?lsp= esc(model.message) ?></div><?lsp end ?>
<section class='panel'><div class='panel-body'><h2>MCP HTTP Server</h2>
   <label for='mcp-endpoint'>MCP connection URL</label><input id='mcp-endpoint' readonly value='<?lsp= esc(app.url("/mcp/")) ?>'>
   <p class='muted'>Use the full URL in your MCP client. This uses the address open in this browser; replace the host if your client reaches the site at a different address. MCP remains disabled until a bearer token is saved. The token is stored encrypted and is never displayed again.</p>
   <p>Status: <span class='tag<?lsp if not model.enabled then ?> hidden<?lsp end ?>'><?lsp= model.enabled and "enabled" or "disabled" ?></span></p>
   <?lsp if app.mcpTokenError then ?><div class='notice error' role='alert'>Stored token error: <?lsp= esc(app.mcpTokenError) ?></div><?lsp end ?>
   <form method='post'><?lsp admin.csrfField(_ENV) ?>
      <div class='field'><label for='field-token'>Bearer Token</label><input id='field-token' type='password' name='token' minlength='16' autocomplete='new-password' required></div>
      <div class='actions'><button type='submit' name='action' value='save'>Save Token</button>
         <?lsp if model.enabled then ?><button class='danger' type='submit' name='action' value='disable' formnovalidate>Disable MCP</button><?lsp end ?>
      </div>
   </form>
</div></section>
