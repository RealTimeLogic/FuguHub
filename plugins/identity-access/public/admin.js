(function () {
   "use strict";

   var root = document.getElementById("identity-app");
   var tokenInput = document.querySelector(
      ".identity-shell input[name='_csrf']"
   );
   if (!root || !tokenInput) return;

   var csrf = tokenInput.value;
   var state = { users: [], roles: [] };
   var busy = false;

   function normalizeState(payload) {
      payload.users = Array.isArray(payload.users) ? payload.users : [];
      payload.roles = Array.isArray(payload.roles) ? payload.roles : [];
      payload.cmsAdmin = payload.cmsAdmin || { enabled: false };
      return payload;
   }

   function element(tag, options) {
      var node = document.createElement(tag);
      options = options || {};
      if (options.id) node.id = options.id;
      if (options.className) node.className = options.className;
      if (options.text !== undefined) node.textContent = options.text;
      if (options.type) node.type = options.type;
      if (options.name) node.name = options.name;
      if (options.value !== undefined) node.value = options.value;
      if (options.placeholder) node.placeholder = options.placeholder;
      if (options.required) node.required = true;
      return node;
   }

   function add(parent) {
      for (var i = 1; i < arguments.length; i += 1) {
         parent.appendChild(arguments[i]);
      }
      return parent;
   }

   var field = window.FuguHubAdmin.field;

   function button(text, className, action) {
      var node = element("button", {
         text: text,
         type: "button",
         className: className || ""
      });
      node.addEventListener("click", function () { if (!busy) action(); });
      return node;
   }

   function submitButton(form, text, action) {
      form.addEventListener("submit", function (event) {
         event.preventDefault();
         if (!busy) action();
      });
      return element("button", { text: text, type: "submit" });
   }

   function setMessage(message, error) {
      var target = document.getElementById("identity-message");
      if (!target) return;
      target.textContent = message || "";
      target.className = "identity-message" + (error ? " error" : "");
      target.setAttribute("role", error ? "alert" : "status");
      target.setAttribute("aria-label", target.textContent);
      if (!busy) {
         target.tabIndex = -1;
         target.focus({ preventScroll: true });
         target.scrollIntoView({ block: "nearest" });
      }
   }

   function post(fields) {
      fields._csrf = csrf;
      var body = new URLSearchParams();
      Object.keys(fields).forEach(function (key) {
         body.set(key, fields[key]);
      });
      busy = true;
      var buttons = Array.from(root.querySelectorAll("button:not(:disabled)"));
      buttons.forEach(function (node) { node.disabled = true; });
      root.setAttribute("aria-busy", "true");
      setMessage(fields.action === "reset-identity" ? "Resetting..." :
         fields.action.indexOf("delete-") === 0 ? "Deleting..." : "Saving...", false);
      return fetch("api/", {
         method: "POST",
         headers: { "Content-Type": "application/x-www-form-urlencoded" },
         body: body.toString(),
         credentials: "same-origin"
      }).then(readResponse).finally(function () {
         busy = false;
         buttons.forEach(function (node) { node.disabled = false; });
         root.removeAttribute("aria-busy");
      });
   }

   function readResponse(response) {
      return window.FuguHubAdmin.readJson(response, "Identity request failed");
   }

   function roleFields(container, selected) {
      var selectedSet = {};
      (selected || []).forEach(function (name) { selectedSet[name] = true; });
      state.roles.forEach(function (role) {
         var label = element("label");
         var checkbox = element("input", {
            type: "checkbox",
            name: "role_" + role.name,
            value: "1"
         });
         checkbox.checked = Boolean(selectedSet[role.name]);
         if (role.name === "authenticated") {
            checkbox.checked = true;
            checkbox.disabled = true;
         }
         add(label, checkbox, document.createTextNode(role.name));
         container.appendChild(label);
      });
   }

   function collect(form, action) {
      var fields = { action: action };
      new FormData(form).forEach(function (value, name) {
         fields[name] = String(value);
      });
      return fields;
   }

   function userForm(user) {
      var form = element("form", { className: "identity-form" });
      var username = element("input", {
         name: "username",
         value: user ? user.username : "",
         required: true
      });
      if (user) username.readOnly = true;
      var displayName = element("input", {
         name: "display_name",
         value: user ? user.displayName : ""
      });
      var email = element("input", {
         name: "email",
         type: "email",
         value: user ? user.email : ""
      });
      var password = element("input", {
         name: "password",
         type: "password",
         placeholder: user && !user.disabled ? "Leave blank to keep password" : "Required when enabled"
      });
      var maxUsers = element("input", {
         name: "max_users",
         type: "number",
         value: user ? user.maxUsers : 3
      });
      maxUsers.min = "1";
      maxUsers.max = "1000";
      var inactive = element("input", {
         name: "inactive",
         type: "number",
         value: user ? user.inactive : 1200
      });
      inactive.min = "0";
      inactive.max = "31536000";

      var grid = element("div", { className: "identity-form-grid" });
      add(grid,
         field("Username", username),
         field("Display name", displayName),
         field("Email", email),
         field("New password", password, "Required for new or re-enabled users. Leave blank to keep an existing password. Unavailable while Disabled is checked."),
         field("Maximum sessions", maxUsers),
         field("Inactive timeout (seconds)", inactive)
      );
      form.appendChild(grid);

      var flags = element("div", { className: "identity-role-grid" });
      var recycleLabel = element("label");
      var recycle = element("input", {
         type: "checkbox", name: "recycle", value: "1"
      });
      recycle.checked = user ? user.recycle : false;
      add(recycleLabel, recycle, document.createTextNode("Recycle sessions"));
      var disabledLabel = element("label");
      var disabled = element("input", {
         type: "checkbox", name: "disabled", value: "1"
      });
      disabled.checked = user ? user.disabled : false;
      add(disabledLabel, disabled, document.createTextNode("Disabled"));
      add(flags, recycleLabel, disabledLabel);
      form.appendChild(flags);
      function syncPassword() {
         password.required = !disabled.checked && (!user || user.disabled);
         password.disabled = disabled.checked;
      }
      disabled.addEventListener("change", syncPassword);
      syncPassword();

      form.appendChild(element("h3", { text: "Roles" }));
      var roles = element("div", { className: "identity-role-grid" });
      roleFields(roles, user ? user.roles : ["authenticated"]);
      form.appendChild(roles);

      var actions = element("div", { className: "identity-actions" });
      actions.appendChild(submitButton(form, user ? "Save User" : "Create User", function () {
         post(collect(form, "save-user")).then(function (payload) {
            state = normalizeState(payload);
            render();
            setMessage("User saved.", false);
         }).catch(function (error) {
            setMessage(error.message, true);
         });
      }));
      if (user) {
         actions.appendChild(button("Delete", "danger", function () {
            if (!window.confirm("Delete user " + user.username + "?")) return;
            post({ action: "delete-user", username: user.username })
               .then(function (payload) {
                  state = normalizeState(payload);
                  render();
                  setMessage("User deleted.", false);
               }).catch(function (error) {
                  setMessage(error.message, true);
               });
         }));
      }
      form.appendChild(actions);
      return form;
   }

   function roleCard(role) {
      var card = element("article", { className: "identity-card" });
      add(card,
         element("h3", { text: role.name }),
         element("p", {
            className: "muted",
            text: role.description || "No description"
         })
      );
      var actions = element("div", { className: "identity-actions" });
      actions.appendChild(button("Edit", "secondary", function () {
         showRoleForm(role);
      }));
      if (!role.systemRole) {
         actions.appendChild(button("Delete", "danger", function () {
            if (!window.confirm("Delete role " + role.name + "?")) return;
            post({ action: "delete-role", name: role.name })
               .then(function (payload) {
                  state = normalizeState(payload);
                  render();
                  setMessage("Role deleted.", false);
               }).catch(function (error) {
                  setMessage(error.message, true);
               });
         }));
      }
      card.appendChild(actions);
      return card;
   }

   function focusEditor() {
      var editor = document.getElementById("identity-editor");
      editor.querySelector("input:not([readonly]):not(:disabled)").focus({ preventScroll: true });
      editor.scrollIntoView({ block: "start" });
   }

   function showUserForm(user, focus) {
      var editor = document.getElementById("identity-editor");
      editor.replaceChildren(
         element("h2", { text: user ? "Edit User" : "New User" }),
         userForm(user)
      );
      if (focus) focusEditor();
   }

   function showRoleForm(role) {
      var editor = document.getElementById("identity-editor");
      var form = element("form", { className: "identity-form" });
      var name = element("input", {
         name: "name", value: role ? role.name : "", required: true
      });
      if (role) name.readOnly = true;
      var description = element("input", {
         name: "description", value: role ? role.description : ""
      });
      add(form,
         field("Role name", name),
         field("Description", description)
      );
      var actions = element("div", { className: "identity-actions" });
      actions.appendChild(submitButton(form, role ? "Save Role" : "Create Role", function () {
         post(collect(form, "save-role")).then(function (payload) {
            state = normalizeState(payload);
            render();
            setMessage("Role saved.", false);
         }).catch(function (error) {
            setMessage(error.message, true);
         });
      }));
      form.appendChild(actions);
      editor.replaceChildren(
         element("h2", { text: role ? "Edit Role" : "New Role" }),
         form
      );
      focusEditor();
   }

   function cmsAdminPanel() {
      var panel = element("section", { className: "identity-section" });
      panel.appendChild(element("h2", { text: "CMS Administration" }));
      if (!state.users.length) {
         panel.appendChild(element("h3", {
            text: "Create First CMS Administrator"
         }));
         panel.appendChild(element("p", {
            className: "muted",
            text: "No identity users exist. Create the first administrator to enable protected CMS administration."
         }));
         var bootstrapForm = element("form", { className: "identity-form" });
         var bootstrapUsername = element("input", {
            name: "username", required: true, placeholder: "CMS administrator"
         });
         var bootstrapPassword = element("input", {
            name: "password", type: "password", required: true
         });
         add(bootstrapForm,
            field("Username", bootstrapUsername),
            field("Password", bootstrapPassword)
         );
         var bootstrapActions = element("div", { className: "identity-actions" });
         bootstrapActions.appendChild(submitButton(bootstrapForm, "Create and Enable", function () {
            post(collect(bootstrapForm, "bootstrap-cms-admin")).then(function () {
               window.location.assign("../../");
            }).catch(function (error) {
               setMessage(error.message, true);
            });
         }));
         bootstrapForm.appendChild(bootstrapActions);
         panel.appendChild(bootstrapForm);
         return panel;
      }
      panel.appendChild(element("p", {
         className: "muted",
         text: state.cmsAdmin.enabled ?
            "Enabled users with the cms-admin role can manage the CMS." :
            "Assign the cms-admin role to an enabled user to protect CMS administration."
      }));
      var actions = element("div", { className: "identity-actions" });
      actions.appendChild(button("Reset All Users", "danger", function () {
         if (!window.confirm("Remove every user and disable authentication?")) return;
         post({ action: "reset-identity" }).then(function () {
            window.location.reload();
         }).catch(function (error) {
            setMessage(error.message, true);
         });
      }));
      panel.appendChild(actions);
      return panel;
   }

   function render() {
      root.replaceChildren();
      var toolbar = element("div", { className: "identity-toolbar" });
      toolbar.appendChild(element("p", {
         id: "identity-message",
         className: "identity-message"
      }));
      toolbar.firstChild.setAttribute("role", "status");
      var toolbarActions = element("div", { className: "identity-actions" });
      if (state.users.length) {
         add(toolbarActions,
            button("New User", "", function () { showUserForm(null, true); }),
            button("New Role", "secondary", function () { showRoleForm(null); })
         );
      }
      toolbar.appendChild(toolbarActions);
      root.appendChild(toolbar);
      root.appendChild(cmsAdminPanel());
      if (!state.users.length) return;

      var columns = element("div", { className: "identity-columns" });
      var lists = element("div", { className: "identity-section" });
      lists.appendChild(element("h2", { text: "Users" }));
      var users = element("div", { className: "identity-list" });
      if (!state.users.length) {
         users.appendChild(element("p", {
            className: "identity-empty", text: "No identity users configured."
         }));
      }
      state.users.forEach(function (user) {
         var card = element("article", { className: "identity-card" });
         add(card,
            element("h3", {
               text: user.username + (user.disabled ? " (disabled)" : "")
            }),
            element("p", {
               className: "muted",
               text: user.displayName || user.email || user.roles.join(", ")
            })
         );
         card.appendChild(button("Edit", "secondary", function () {
            showUserForm(user, true);
         }));
         users.appendChild(card);
      });
      lists.appendChild(users);
      lists.appendChild(element("h2", { text: "Roles" }));
      var roles = element("div", { className: "identity-list" });
      state.roles.forEach(function (role) {
         roles.appendChild(roleCard(role));
      });
      lists.appendChild(roles);

      var editor = element("div", {
         id: "identity-editor",
         className: "identity-section"
      });
      columns.appendChild(lists);
      columns.appendChild(editor);
      root.appendChild(columns);
      showUserForm(null);
   }

   fetch("api/", { credentials: "same-origin" })
      .then(readResponse)
      .then(function (payload) {
         state = normalizeState(payload);
         render();
      })
      .catch(function (error) {
         root.textContent = "Identity data could not be loaded: " + error.message;
      });
}());
