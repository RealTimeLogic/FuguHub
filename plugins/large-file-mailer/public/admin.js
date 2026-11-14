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

   var field = window.FuguHubAdmin.field;

   function number(name, value, min, max, step) {
      var input = el("input", { name: name, type: "number", value: value, required: true });
      input.min = min;
      input.max = max;
      input.step = step || "1";
      return input;
   }

   function group(title, fields) {
      var section = el("fieldset");
      var grid = el("div", { className: "mailer-grid" });
      fields.forEach(function (item) { grid.appendChild(item); });
      return add(section, el("legend", { text: title }), grid);
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
      // The wire format remains integer bytes/seconds; the form uses MiB/days.
      data.set("attachment_limit", String(Math.round(Number(data.get("attachment_limit")) * 1048576)));
      data.set("grant_ttl", String(Math.round(Number(data.get("grant_ttl")) * 86400)));
      data.set("_csrf", csrf);
      data.set("action", action);
      return fetch("api/", {
         method: "POST", credentials: "same-origin", body: data
      }).then(read);
   }

   function render(payload, previousTestRecipient, focusTest) {
      var settings = payload.settings;
      root.replaceChildren();
      root.appendChild(el("p", {
         className: "mailer-state",
         text: settings.enabled ? "Mailer is enabled." : "Mailer is disabled."
      }));
      var form = el("form", { className: "mailer-form" });
      form.autocomplete = "off";
      var saving = false;
      var fromAddress = el("input", {
         name: "from_address", value: settings.fromAddress
      });
      var testRecipient = el("input", {
         name: "test_recipient",
         value: previousTestRecipient === undefined ? settings.fromAddress : previousTestRecipient
      });
      var testRecipientChanged = Boolean(previousTestRecipient);
      testRecipient.addEventListener("input", function () {
         testRecipientChanged = true;
      });
      fromAddress.addEventListener("input", function () {
         if (!testRecipientChanged) testRecipient.value = fromAddress.value;
      });
      var security = el("select", { name: "smtp_security" });
      [["none", "None (unencrypted)"], ["tls", "TLS from connection start"],
         ["starttls", "STARTTLS (upgrade connection)"]].forEach(function (item) {
         var option = el("option", { value: item[0], text: item[1] });
         option.selected = settings.smtpSecurity === item[0];
         security.appendChild(option);
      });
      var smtpServer = el("input", { name: "smtp_server", value: settings.smtpServer });
      form.appendChild(group("SMTP connection", [
         field("SMTP server", smtpServer, "Hostname or IP address supplied by your email provider."),
         field("SMTP port", number("smtp_port", settings.smtpPort, 1, 65535)),
         field("Security", security),
         field("Username", el("input", {
            name: "smtp_username", value: settings.smtpUsername,
            autocomplete: "off"
         })),
         field("Password", el("input", {
            name: "password", type: "password",
            value: "", autocomplete: "new-password",
            placeholder: settings.passwordConfigured ? "Saved; leave blank to keep" : ""
         }))
      ]));
      form.appendChild(group("Sender", [
         field("From address", fromAddress, "An email address, or Name <address@example.com>."),
         field("Reply-to", el("input", {
            name: "reply_to", value: settings.replyTo
         }), "Optional. Replies go here instead of the From address.")
      ]));
      form.appendChild(group("Files and download links", [
         field("Public base URL", el("input", {
            name: "public_base_url", value: settings.publicBaseUrl,
            placeholder: "https://example.com"
         }), "The address recipients can reach, including a port if needed. Omit application paths."),
         field("Attachment limit (MiB)", number("attachment_limit", settings.attachmentLimit / 1048576,
            0, 1024, "any"), "1 MiB = 1,048,576 bytes. Maximum 1,024 MiB."),
         field("Link lifetime (days)", number("grant_ttl", settings.grantTtl / 86400,
            60 / 86400, 365, "any"), "Fractions are allowed; minimum 1 minute, maximum 365 days.")
      ]));
      var advanced = el("details", { className: "mailer-advanced" });
      add(advanced, el("summary", { text: "Advanced delivery settings" }),
         group("Delivery retries", [
            field("Maximum attempts", number("max_attempts", settings.maxAttempts, 1, 20)),
            field("Initial retry delay (seconds)", number("retry_base", settings.retryBase, 1, 86400),
               "The delay doubles after each failed attempt."),
            field("Send interval (seconds)", number("send_interval", settings.sendInterval, 1, 3600))
         ]));
      form.appendChild(advanced);
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
         add(el("label"), enabled, document.createTextNode("Enable mail delivery")),
         add(el("label"), https, document.createTextNode("Require HTTPS downloads")),
         add(el("label"), clear, document.createTextNode("Clear saved password"))
      );
      form.appendChild(flags);
      form.appendChild(field("Test recipient", testRecipient,
         "Used only by Save and Test, which saves these settings and sends one test email."));
      var saveButton = el("button", { type: "button", text: "Save Settings" });
      var testButton = el("button", { type: "button", text: "Save and Test" });
      function submit(test) {
         if (saving) return;
         smtpServer.required = fromAddress.required = enabled.checked || test;
         testRecipient.required = test;
         form.querySelectorAll(":invalid").forEach(function (input) {
            var details = input.closest("details");
            if (details) details.open = true;
         });
         var valid = form.reportValidity();
         testRecipient.required = false;
         if (!valid) return;
         saving = true;
         saveButton.disabled = testButton.disabled = true;
         message(test ? "Saving and sending test message..." : "Saving...", false);
         save(form, test ? "save-and-test" : "save-settings").then(function (next) {
            render(next, testRecipient.value, test);
            message(test ? "Settings saved. Test message sent to " + next.testRecipient + "." :
               "Settings saved.", false);
         }).catch(function (error) {
            if (error.payload && error.payload.saved) render(error.payload, testRecipient.value, test);
            message(error.message, true);
         }).finally(function () {
            saving = false;
            saveButton.disabled = testButton.disabled = false;
         });
      }
      saveButton.addEventListener("click", function () { submit(false); });
      testButton.addEventListener("click", function () { submit(true); });
      form.addEventListener("submit", function (event) {
         event.preventDefault();
         submit(false);
      });
      add(form, add(el("div", { className: "mailer-actions" }),
         saveButton, testButton));
      var actionMessage = el("p", { className: "mailer-message" });
      actionMessage.id = "mailer-message";
      actionMessage.setAttribute("role", "status");
      actionMessage.setAttribute("aria-live", "polite");
      form.appendChild(actionMessage);
      root.appendChild(form);
      if (focusTest !== undefined) (focusTest ? testButton : saveButton).focus();
   }

   fetch("api/", { credentials: "same-origin" })
      .then(read).then(render)
      .catch(function (error) {
         root.textContent = "Mailer settings could not be loaded: " + error.message;
      });
}());
