(function () {
   "use strict";

   var root = document.getElementById("mailer-app");
   var token = document.querySelector(".mailer-shell input[name='_csrf']");
   if (!root || !token) return;
   var csrf = token.value;

   function el(tag, options) {
      var node = document.createElement(tag);
      options = options || {};
      if (options.className) node.className = options.className;
      if (options.text !== undefined) node.textContent = options.text;
      if (options.name) node.name = options.name;
      if (options.type) node.type = options.type;
      if (options.value !== undefined) node.value = options.value;
      if (options.required) node.required = true;
      if (options.placeholder) node.placeholder = options.placeholder;
      if (options.autocomplete) node.autocomplete = options.autocomplete;
      return node;
   }

   function add(parent) {
      for (var i = 1; i < arguments.length; i += 1) {
         parent.appendChild(arguments[i]);
      }
      return parent;
   }

   function field(label, input) {
      return add(el("div", { className: "field" }),
         el("label", { text: label }), input);
   }

   function read(response) {
      return window.FuguHubAdmin.readJson(response, "Mailer request failed");
   }

   function message(text, error) {
      var target = document.getElementById("mailer-message");
      if (!target) return;
      target.textContent = text || "";
      target.className = "mailer-message" +
         (error ? " error" : (text ? " success" : ""));
   }

   function save(form, action) {
      var data = new FormData(form);
      data.set("_csrf", csrf);
      data.set("action", action);
      return fetch("api/", {
         method: "POST", credentials: "same-origin", body: data
      }).then(read);
   }

   function render(payload, previousTestRecipient) {
      var settings = payload.settings;
      root.replaceChildren();
      root.appendChild(el("p", {
         className: "mailer-state",
         text: settings.enabled ? "Mailer is enabled." : "Mailer is disabled."
      }));
      var form = el("form", { className: "mailer-form" });
      form.autocomplete = "off";
      var fromAddress = el("input", {
         name: "from_address", value: settings.fromAddress, required: true
      });
      var testRecipient = el("input", {
         name: "test_recipient",
         value: previousTestRecipient || settings.fromAddress,
         required: true
      });
      var testRecipientChanged = Boolean(previousTestRecipient);
      testRecipient.addEventListener("input", function () {
         testRecipientChanged = true;
      });
      fromAddress.addEventListener("input", function () {
         if (!testRecipientChanged) testRecipient.value = fromAddress.value;
      });
      var security = el("select", { name: "smtp_security" });
      ["none", "tls", "starttls"].forEach(function (value) {
         var option = el("option", { value: value, text: value });
         option.selected = settings.smtpSecurity === value;
         security.appendChild(option);
      });
      var grid = el("div", { className: "mailer-grid" });
      add(grid,
         field("SMTP server", el("input", {
            name: "smtp_server", value: settings.smtpServer, required: true
         })),
         field("SMTP port", el("input", {
            name: "smtp_port", type: "number", value: settings.smtpPort, required: true
         })),
         field("Security", security),
         field("Username", el("input", {
            name: "smtp_username", value: settings.smtpUsername,
            autocomplete: "off"
         })),
         field("Password", el("input", {
            name: "password", type: "password",
            value: "", autocomplete: "new-password",
            placeholder: settings.passwordConfigured ? "Saved; leave blank to keep" : ""
         })),
         field("From address", fromAddress),
         field("Test recipient", testRecipient),
         field("Reply-to", el("input", {
            name: "reply_to", value: settings.replyTo
         })),
         field("Public base URL", el("input", {
            name: "public_base_url", value: settings.publicBaseUrl,
            placeholder: "https://example.com"
         })),
         field("Attachment limit (bytes)", el("input", {
            name: "attachment_limit", type: "number", value: settings.attachmentLimit
         })),
         field("Link lifetime (seconds)", el("input", {
            name: "grant_ttl", type: "number", value: settings.grantTtl
         })),
         field("Maximum attempts", el("input", {
            name: "max_attempts", type: "number", value: settings.maxAttempts
         })),
         field("Retry delay (seconds)", el("input", {
            name: "retry_base", type: "number", value: settings.retryBase
         })),
         field("Send interval (seconds)", el("input", {
            name: "send_interval", type: "number", value: settings.sendInterval
         }))
      );
      form.appendChild(grid);
      var flags = el("div", { className: "mailer-flags" });
      var enabled = el("input", { name: "enabled", type: "checkbox", value: "1" });
      enabled.checked = settings.enabled;
      var https = el("input", {
         name: "require_https", type: "checkbox", value: "1"
      });
      https.checked = settings.requireHttps;
      var clear = el("input", {
         name: "clear_password", type: "checkbox", value: "1"
      });
      add(flags,
         add(el("label"), enabled, document.createTextNode("Enabled")),
         add(el("label"), https, document.createTextNode("Require HTTPS downloads")),
         add(el("label"), clear, document.createTextNode("Clear saved password"))
      );
      form.appendChild(flags);
      var saveButton = el("button", { type: "button", text: "Save Settings" });
      saveButton.addEventListener("click", function () {
         if (!form.reportValidity()) return;
         message("Saving...", false);
         save(form, "save-settings").then(function (next) {
            render(next, testRecipient.value);
            message("Settings saved.", false);
         }).catch(function (error) { message(error.message, true); });
      });
      var testButton = el("button", { type: "button", text: "Save and Test" });
      testButton.addEventListener("click", function () {
         if (!form.reportValidity()) return;
         message("Saving and sending test message...", false);
         save(form, "save-and-test").then(function (next) {
            render(next, testRecipient.value);
            message("Settings saved. Test message sent to " +
               next.testRecipient + ".", false);
         }).catch(function (error) { message(error.message, true); });
      });
      add(form, add(el("div", { className: "mailer-actions" }),
         saveButton, testButton));
      var actionMessage = el("p", { className: "mailer-message" });
      actionMessage.id = "mailer-message";
      actionMessage.setAttribute("role", "status");
      actionMessage.setAttribute("aria-live", "polite");
      form.appendChild(actionMessage);
      root.appendChild(form);
   }

   fetch("api/", { credentials: "same-origin" })
      .then(read).then(render)
      .catch(function (error) {
         root.textContent = "Mailer settings could not be loaded: " + error.message;
      });
}());
