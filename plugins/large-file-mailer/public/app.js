(function () {
   "use strict";
   var shell = document.querySelector(".mailer-app");
   var root = document.getElementById("mailer-client");
   if (!shell || !root) return;
   var csrf = shell.dataset.csrf;
   var view = shell.dataset.view;
   var settingsUrl = shell.dataset.settingsUrl;
   var state;
   var contactQuery = "";
   var contactPage = 1;
   var contactFilter = "all";
   var currentListId = view === "lists" ?
      Number(new URLSearchParams(window.location.search).get("id")) || null : null;
   var csvFile = null;
   var csvPreview = null;
   var removalText = "";
   var removalPreview = null;
   var composeContacts = {};
   var composeContactSearchSequence = 0;
   var noticeText = "";
   var noticeError = false;

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
      for (var i = 1; i < arguments.length; i += 1) parent.appendChild(arguments[i]);
      return parent;
   }

   function field(label, input) {
      return add(el("label", { className: "field" }),
         el("span", { text: label }), input);
   }

   function button(text, className, handler) {
      var node = el("button", { type: "button", text: text, className: className || "" });
      node.addEventListener("click", handler);
      return node;
   }

   function asArray(value) {
      return Array.isArray(value) ? value : [];
   }

   function normalize(payload) {
      payload.contacts = payload.contacts || { items: [], page: 1, pageSize: 50, total: 0 };
      payload.contacts.items = asArray(payload.contacts.items);
      payload.contacts.items.forEach(function (contact) {
         contact.listIds = asArray(contact.listIds);
         contact.listNames = asArray(contact.listNames);
      });
      payload.lists = asArray(payload.lists);
      payload.lists.forEach(function (list) { list.memberIds = asArray(list.memberIds); });
      payload.templates = asArray(payload.templates);
      if (payload.history) payload.history.items = asArray(payload.history.items);
      if (payload.csvPreview) {
         payload.csvPreview.headers = asArray(payload.csvPreview.headers);
         payload.csvPreview.rows = asArray(payload.csvPreview.rows);
         payload.csvPreview.errors = asArray(payload.csvPreview.errors);
      }
      if (payload.importResult) {
         payload.importResult.duplicates = asArray(payload.importResult.duplicates);
         payload.importResult.suppressed = asArray(payload.importResult.suppressed);
         payload.importResult.errors = asArray(payload.importResult.errors);
      }
      if (payload.removalPreview) {
         payload.removalPreview.matches = asArray(payload.removalPreview.matches);
         payload.removalPreview.notFound = asArray(payload.removalPreview.notFound);
      }
      return payload;
   }

   function read(response) {
      return response.text().then(function (body) {
         var payload;
         try {
            payload = JSON.parse(body);
         } catch (error) {
            throw new Error("Mailer returned an invalid response (HTTP " + response.status + ")");
         }
         if (!response.ok || !payload.ok) throw new Error(payload.error || "Mailer request failed");
         return normalize(payload);
      });
   }

   function request(fields) {
      var body = new FormData();
      body.append("csrf", csrf);
      body.append("_query", contactQuery);
      body.append("_page", String(contactPage));
      body.append("_scope", view);
      if (view === "contacts") body.append("_contact_filter", contactFilter);
      if (currentListId) body.append("_list_id", String(currentListId));
      Object.keys(fields).forEach(function (key) { body.append(key, fields[key]); });
      return fetch("../api/", {
         method: "POST", credentials: "same-origin",
         body: body
      }).then(read);
   }

   function looksLikeEml(value) {
      var source = String(value || "").replace(/^\uFEFF/, "");
      var separator = source.search(/\r?\n\r?\n/);
      if (separator < 1) return false;
      var header = source.slice(0, separator);
      var lines = header.split(/\r?\n/);
      var headerCount = 0;
      for (var index = 0; index < lines.length; index += 1) {
         if (/^[ \t]/.test(lines[index])) continue;
         if (!/^[!#$%&'*+.^_`|~0-9A-Za-z-]+\s*:/.test(lines[index])) return false;
         headerCount += 1;
      }
      return headerCount > 0 &&
         /(?:^|\r?\n)(?:MIME-Version|Content-Type|Subject)\s*:/i.test(header);
   }

   function smartEmlEditor(subject, textBody, htmlBody, template) {
      var sequence = 0;
      var timer = null;
      var lastSource = "";
      var parseError = null;
      var activeParse = false;
      var pending = Promise.resolve();

      function populate(payload, label, currentSequence) {
         if (currentSequence !== sequence || !payload.parsedMessage) return;
         var parsed = payload.parsedMessage;
         if (parsed.subject) subject.value = parsed.subject;
         textBody.value = parsed.textBody || "";
         htmlBody.value = parsed.htmlBody || "";
         message(label + " loaded into editable fields.", false);
      }

      function parse(source, templateId, label) {
         var currentSequence = ++sequence;
         parseError = null;
         activeParse = true;
         if (source) {
            lastSource = source;
            if (template) template.value = "";
         }
         var fields = { action: "parse-eml" };
         if (source) fields.source = source;
         if (templateId) fields.template_id = templateId;
         pending = request(fields).then(function (payload) {
            if (currentSequence === sequence) activeParse = false;
            populate(payload, label, currentSequence);
            return payload;
         }).catch(function (error) {
            if (currentSequence === sequence) {
               activeParse = false;
               parseError = error;
               message(error.message, true);
            }
            return null;
         });
         return pending;
      }

      function importHtmlField() {
         var source = htmlBody.value;
         if (!looksLikeEml(source)) {
            sequence += 1;
            activeParse = false;
            lastSource = "";
            parseError = null;
            return null;
         }
         if (source === lastSource) return null;
         return parse(source, "", "EML message");
      }

      htmlBody.addEventListener("input", function () {
         window.clearTimeout(timer);
         timer = window.setTimeout(importHtmlField, 350);
      });
      htmlBody.addEventListener("paste", function () {
         window.clearTimeout(timer);
         timer = window.setTimeout(importHtmlField, 0);
      });

      if (template) {
         template.addEventListener("change", function () {
            if (!template.value) {
               sequence += 1;
               activeParse = false;
               parseError = null;
               return;
            }
            window.clearTimeout(timer);
            parse("", template.value, "Template");
         });
      }

      return {
         whenReady: function () {
            window.clearTimeout(timer);
            var ready = activeParse ? pending : (importHtmlField() || pending);
            return ready.then(function (payload) {
               if (parseError) throw parseError;
               return payload;
            });
         }
      };
   }

   function loadJob(jobId) {
      return fetch("../api/?scope=job&id=" + encodeURIComponent(jobId), {
         credentials: "same-origin"
      }).then(read);
   }

   function formatTime(value) {
      return value ? new Date(value * 1000).toLocaleString() : "Not set";
   }

   function jobSource(title, value) {
      var section = el("details", { className: "job-source" });
      section.appendChild(el("summary", { text: title }));
      section.appendChild(el("pre", { text: value || "Not stored" }));
      return section;
   }

   function renderJobDetails(job) {
      var detail = el("div", { className: "job-detail" });
      detail.appendChild(el("h3", { text: "Stored job content" }));
      detail.appendChild(el("p", { className: "muted", text:
         "This is the source data saved with the job, not the final personalized email." }));
      var meta = el("dl", { className: "job-meta" });
      [
         ["Created by", job.sender], ["Status", job.status],
         ["Delivery mode", job.deliveryMode], ["Job type", job.jobType],
         ["Created", formatTime(job.createdAt)], ["Queued", formatTime(job.queuedAt)],
         ["Completed", formatTime(job.completedAt)], ["Cancelled", formatTime(job.cancelledAt)]
      ].forEach(function (item) {
         var cell = el("div");
         add(cell, el("dt", { text: item[0] }), el("dd", { text: item[1] || "Not set" }));
         meta.appendChild(cell);
      });
      detail.appendChild(meta);
      detail.appendChild(add(el("div", { className: "job-subject" }),
         el("strong", { text: "Subject" }), el("span", { text: job.subject || "Not stored" })));
      detail.appendChild(jobSource("Stored text body", job.textBody));
      detail.appendChild(jobSource("Stored HTML source", job.htmlBody));
      if (job.templateSnapshot) {
         detail.appendChild(jobSource("Stored EML template snapshot", job.templateSnapshot));
      }

      var files = el("details");
      files.appendChild(el("summary", { text: "Files (" + asArray(job.files).length + ")" }));
      if (asArray(job.files).length) {
         var fileList = el("ul", { className: "job-files" });
         job.files.forEach(function (file) {
            fileList.appendChild(el("li", { text: file.path + " - " + file.name +
               " (" + file.byteLength + " bytes, SHA-256 " + file.sha256 + ")" }));
         });
         files.appendChild(fileList);
      } else {
         files.appendChild(el("p", { className: "muted", text: "No stored files." }));
      }
      detail.appendChild(files);

      var recipients = el("details");
      recipients.appendChild(el("summary", { text: "Recipients (" + job.recipientCount + ")" }));
      if (job.recipientsTruncated) {
         recipients.appendChild(el("p", { className: "muted", text:
            "Showing the first 100 of " + job.recipientCount + " recipients." }));
      }
      var tableHost = el("div", { className: "table-scroll" });
      var table = el("table", { className: "job-recipient-table" });
      var head = el("tr");
      ["Email", "Name", "Status", "Attempts", "Sent", "Error"].forEach(function (label) {
         head.appendChild(el("th", { text: label }));
      });
      table.appendChild(add(el("thead"), head));
      var body = el("tbody");
      asArray(job.recipients).forEach(function (recipient) {
         var row = el("tr");
         [recipient.email, [recipient.firstName, recipient.lastName].filter(Boolean).join(" "),
            recipient.status, recipient.attempts, formatTime(recipient.sentAt),
            recipient.lastError || ""].forEach(function (value) {
            row.appendChild(el("td", { text: value === undefined ? "" : value }));
         });
         body.appendChild(row);
      });
      table.appendChild(body);
      tableHost.appendChild(table);
      recipients.appendChild(tableHost);
      detail.appendChild(recipients);
      return detail;
   }

   function csvRequest(action, file, mapping, restoreUnsubscribed) {
      var headers = {
         "Content-Type": file.type || "text/csv",
         "X-FuguHub-CSRF": csrf
      };
      if (mapping) headers["X-FuguHub-CSV-Mapping"] = JSON.stringify(mapping);
      if (currentListId) headers["X-FuguHub-List-ID"] = String(currentListId);
      if (restoreUnsubscribed) headers["X-FuguHub-Restore-Unsubscribed"] = "1";
      if (action === "import" && csvPreview) {
         headers["X-FuguHub-CSV-Has-Header"] = csvPreview.hasHeader ? "1" : "0";
      }
      var url = "../csv/" + action + "/?query=" + encodeURIComponent(contactQuery) +
         "&page=" + encodeURIComponent(contactPage) + "&scope=" +
          encodeURIComponent(view) + "&list_id=" + encodeURIComponent(currentListId || "") +
          "&contact_filter=" + encodeURIComponent(contactFilter);
      return fetch(url, {
         method: "POST", credentials: "same-origin", headers: headers, body: file
      }).then(read);
   }

   function removalRequest(action, source) {
      return fetch("../remove/" + action + "/", {
         method: "POST",
         credentials: "same-origin",
         headers: {
            "Content-Type": "text/plain; charset=utf-8",
            "X-FuguHub-CSRF": csrf
         },
         body: source
      }).then(read);
   }

   function loadState(query, page, listId) {
      var url = "../api/?query=" + encodeURIComponent(query || "") +
         "&page=" + encodeURIComponent(page || 1) + "&scope=" +
         encodeURIComponent(view) + "&list_id=" + encodeURIComponent(listId || "") +
         "&contact_filter=" + encodeURIComponent(contactFilter);
      return fetch(url, { credentials: "same-origin" }).then(read);
   }

   function searchComposeContacts(query, page) {
      var url = "../api/?query=" + encodeURIComponent(query) +
         "&page=" + encodeURIComponent(page || 1) + "&scope=recipient-search";
      return fetch(url, { credentials: "same-origin" }).then(read);
   }

   function message(text, error) {
      noticeText = text || "";
      noticeError = Boolean(error);
      var target = document.getElementById("client-message");
      if (!target) return;
      target.textContent = noticeText;
      target.classList.toggle("error", noticeError);
   }

   function notice(extraClass) {
      var node = el("p", {
         className: "client-message" + (extraClass ? " " + extraClass : "") +
            (noticeError ? " error" : ""),
         text: noticeText
      });
      node.id = "client-message";
      return node;
   }

   function checkedValues(container) {
      return Array.prototype.map.call(
         container.querySelectorAll("input[type=checkbox]:checked"),
         function (input) { return Number(input.value); }
      );
   }

   function choices(items, label, selectedIds, showDetails) {
      var box = el("fieldset", { className: "choices" });
      var selected = {};
      (selectedIds || []).forEach(function (id) { selected[Number(id)] = true; });
      box.appendChild(el("legend", { text: label }));
      if (!items.length) box.appendChild(el("p", { className: "muted", text: "None available." }));
      items.forEach(function (item) {
         var input = el("input", { type: "checkbox", value: item.id });
         input.checked = Boolean(selected[Number(item.id)]);
         var name = item.name ||
            [item.firstName, item.lastName].filter(Boolean).join(" ") || item.email;
         if (showDetails) {
            var copy = el("span", { className: "choice-details" });
            copy.appendChild(el("strong", { text: name }));
            copy.appendChild(el("small", { text:
               Number(item.members || 0) +
               (Number(item.members || 0) === 1 ? " recipient" : " recipients") }));
            if (item.description) {
               copy.appendChild(el("small", {
                  className: "choice-description", text: item.description
               }));
            }
            box.appendChild(add(el("label", { className: "detailed-choice" }), input, copy));
         } else {
            box.appendChild(add(el("label"), input, document.createTextNode(name)));
         }
      });
      return box;
   }

   function contactName(contact) {
      return [contact.firstName, contact.lastName].filter(Boolean).join(" ") ||
         contact.email;
   }

   function composeContactIds() {
      return Object.keys(composeContacts).map(Number);
   }

   function composeContactPicker() {
      var box = el("fieldset", { className: "choices recipient-picker" });
      box.appendChild(el("legend", { text: "Contacts" }));
      var search = el("input", {
         placeholder: "Search by email, first name, or last name",
         autocomplete: "off"
      });
      search.setAttribute("aria-label", "Search contacts");
      var selected = el("div", { className: "selected-recipients" });
      var results = el("div", { className: "recipient-search-results" });
      var timer;
      var resultState = null;

      function renderResults() {
         results.replaceChildren();
         if (!resultState) {
            results.appendChild(el("p", { className: "muted", text:
               "Type to search " + Number(state.contacts.total || 0) + " contacts." }));
            return;
         }
         var contacts = resultState.contacts;
         results.appendChild(el("p", { className: "muted recipient-result-count", text:
            contacts.total + " matching contacts" }));
         if (!contacts.items.length) {
            results.appendChild(el("p", { className: "muted", text: "No contacts match." }));
            return;
         }
         var list = el("div", { className: "recipient-options" });
         contacts.items.forEach(function (contact) {
            var input = el("input", { type: "checkbox", value: contact.id });
            input.checked = Boolean(composeContacts[String(contact.id)]);
            input.addEventListener("change", function () {
               if (input.checked) composeContacts[String(contact.id)] = contact;
               else delete composeContacts[String(contact.id)];
               renderSelected();
            });
            var details = el("span", { className: "recipient-option-text" });
            details.appendChild(el("strong", { text: contactName(contact) }));
            if (contactName(contact) !== contact.email) {
               details.appendChild(el("small", { text: contact.email }));
            }
            list.appendChild(add(el("label", { className: "recipient-option" }),
               input, details));
         });
         results.appendChild(list);
         var pages = Math.max(1, Math.ceil(contacts.total / contacts.pageSize));
         if (pages > 1) {
            var pager = el("div", { className: "pager compact-pager" });
            var previous = button("Previous", "secondary", function () {
               runSearch(contacts.page - 1);
            });
            var next = button("Next", "secondary", function () {
               runSearch(contacts.page + 1);
            });
            previous.disabled = contacts.page <= 1;
            next.disabled = contacts.page >= pages;
            add(pager, previous,
               el("span", { text: "Page " + contacts.page + " of " + pages }), next);
            results.appendChild(pager);
         }
      }

      function renderSelected() {
         selected.replaceChildren();
         var values = Object.keys(composeContacts).map(function (id) {
            return composeContacts[id];
         }).sort(function (left, right) {
            return left.email.localeCompare(right.email);
         });
         selected.appendChild(el("h3", { text: "Selected contacts (" + values.length + ")" }));
         if (!values.length) {
            selected.appendChild(el("p", { className: "muted", text:
               "No individual contacts selected." }));
            return;
         }
         values.forEach(function (contact) {
            var row = el("div", { className: "selected-recipient" });
            var description = contactName(contact);
            if (description !== contact.email) description += " <" + contact.email + ">";
            add(row, el("span", { text: description }),
               button("Remove", "link-button", function () {
                  delete composeContacts[String(contact.id)];
                  renderSelected();
                  renderResults();
               }));
            selected.appendChild(row);
         });
      }

      function runSearch(page) {
         var query = search.value.trim();
         if (!query) {
            composeContactSearchSequence += 1;
            resultState = null;
            renderResults();
            return;
         }
         var sequence = ++composeContactSearchSequence;
         results.replaceChildren(el("p", { className: "muted", text: "Searching..." }));
         searchComposeContacts(query, page || 1).then(function (payload) {
            if (sequence !== composeContactSearchSequence) return;
            resultState = payload;
            renderResults();
         }).catch(function (error) {
            if (sequence !== composeContactSearchSequence) return;
            results.replaceChildren(el("p", { className: "error", text: error.message }));
         });
      }

      search.addEventListener("input", function () {
         window.clearTimeout(timer);
         timer = window.setTimeout(function () { runSearch(1); }, 220);
      });
      add(box, search, selected, results);
      renderSelected();
      renderResults();
      return box;
   }

   function renderCompose() {
      root.replaceChildren();
      var section = el("section", { className: "workspace" });
      section.appendChild(el("h1", { text: "Compose Delivery" }));
      if (!state.settings.enabled) {
         section.appendChild(el("p", { className: "warning", text: "The mailer is disabled by the CMS administrator." }));
      }
      var form = el("form", { className: "compose-form" });
      form.autocomplete = "off";
      var subject = el("input", {
         required: true, placeholder: "Subject", autocomplete: "off"
      });
      var textBody = el("textarea", { placeholder: "Plain-text message" });
      var htmlBody = el("textarea", {
         placeholder: "Optional HTML message, or paste a complete EML"
      });
      var files = el("textarea", {
         className: "delivery-files",
         placeholder: "/reports/report.pdf\n/exports/data.csv"
      });
      var mode = el("select", { className: "delivery-mode" });
      [
         ["email", "Email only"],
         ["attachment", "File attachments"],
         ["link", "Secure download links"]
      ].forEach(function (option) {
         mode.appendChild(el("option", { value: option[0], text: option[1] }));
      });
      var requirePassword = el("input", { type: "checkbox", value: "1" });
      var template = el("select");
      template.appendChild(el("option", { value: "", text: "No template" }));
      state.templates.forEach(function (item) {
         template.appendChild(el("option", { value: item.id, text: item.name }));
      });
      var templateField = field("Template", template);
      templateField.appendChild(el("small", { text:
         "Selecting a template loads an editable copy into the fields below." }));
      var emlEditor = smartEmlEditor(subject, textBody, htmlBody, template);
      var passwordField = add(el("label", { className: "check-field" }),
         requirePassword,
         document.createTextNode("Require each recipient's confirmed password"));
      var filesField = field("File Services paths, one per line", files);
      var fileLocation = state.fileServices || {};
      var rootText = fileLocation.io === "home" ?
         "Mako home IO at " + (fileLocation.path || "/") :
         (fileLocation.io || "configured") + " IO at " + (fileLocation.path || "/");
      var fileHelp = el("small", { className: "file-path-help" });
      fileHelp.appendChild(document.createTextNode(
         "Start each path with /. Paths are resolved below " + rootText + ". "));
      if (fileLocation.mountUrl) {
         var browseLink = el("a", { text: "Browse File Services" });
         browseLink.href = fileLocation.mountUrl;
         browseLink.target = "_blank";
         browseLink.rel = "noopener noreferrer";
         fileHelp.appendChild(browseLink);
      }
      filesField.appendChild(fileHelp);
      add(form,
         field("Subject", subject),
         templateField,
         field("Delivery mode", mode),
         passwordField,
         field("Plain text", textBody),
         field("HTML", htmlBody),
         filesField
      );
      if (state.manager) {
         var invitationHelp = el("p", { className: "muted password-help" });
         invitationHelp.appendChild(document.createTextNode(
            "Recipients must first create a personal download password. "));
         var invitationLink = el("a", { text: "Send password invitations" });
         invitationLink.href = "../invitations/";
         invitationHelp.appendChild(invitationLink);
         form.appendChild(invitationHelp);
      }
      var linkPlacementHelp = el("p", { className: "muted link-placement-help" });
      linkPlacementHelp.appendChild(document.createTextNode(
         "Download links are appended automatically. Use "));
      linkPlacementHelp.appendChild(el("code", { text: "{{DOWNLOAD_LINKS}}" }));
      linkPlacementHelp.appendChild(document.createTextNode(
         " in the message only when you want to control their position."));
      form.appendChild(linkPlacementHelp);
      var unsubscribeHelp = el("p", { className: "muted unsubscribe-help" });
      unsubscribeHelp.appendChild(document.createTextNode(
         "For bulk email, add "));
      unsubscribeHelp.appendChild(el("code", { text: "{{UNSUBSCRIBE_LINK}}" }));
      unsubscribeHelp.appendChild(document.createTextNode(
         " where recipients can update their contact details or opt out."));
      form.appendChild(unsubscribeHelp);
      function updateDeliveryMode() {
         var fileDelivery = mode.value !== "email";
         filesField.hidden = !fileDelivery;
         passwordField.hidden = mode.value !== "link";
         requirePassword.disabled = mode.value !== "link";
         if (mode.value !== "link") requirePassword.checked = false;
         var help = form.querySelector(".password-help");
         if (help) help.hidden = mode.value !== "link";
         linkPlacementHelp.hidden = mode.value !== "link";
      }
      mode.addEventListener("change", updateDeliveryMode);
      try {
         var handoffKey = "fuguhub.mailer.selection:" + window.location.pathname;
         var handoff = window.sessionStorage.getItem(handoffKey);
         if (handoff) {
            window.sessionStorage.removeItem(handoffKey);
            var selectedPaths = JSON.parse(handoff);
            if (Array.isArray(selectedPaths) && selectedPaths.every(function (path) {
               return typeof path === "string" && path.charAt(0) === "/";
            })) {
               files.value = selectedPaths.join("\n");
               mode.value = "attachment";
            }
         }
      } catch (ignore) {}
      updateDeliveryMode();
      var recipientGrid = el("div", { className: "recipient-grid" });
      var contacts = composeContactPicker();
      var lists = choices(state.lists, "Lists", null, true);
      add(recipientGrid, contacts, lists);
      form.appendChild(recipientGrid);
      var queueButton = button("Queue Delivery", "primary", function () {
         emlEditor.whenReady().then(function () {
            if (!form.reportValidity()) return;
            var paths = mode.value === "email" ? [] :
               files.value.split(/\r?\n/).map(function (value) { return value.trim(); })
                  .filter(Boolean);
            message("Creating delivery...", false);
            return request({
               action: "create-job", queue: "1", subject: subject.value,
               template_id: template.value, delivery_mode: mode.value,
               require_contact_password: requirePassword.checked ? "1" : "0",
               text_body: textBody.value,
               html_body: htmlBody.value, files: JSON.stringify(paths),
               contact_ids: JSON.stringify(composeContactIds()),
               list_ids: JSON.stringify(checkedValues(lists))
            }).then(function (payload) {
               composeContacts = {};
               state = payload;
               renderCompose();
               message("Delivery job " + payload.job.id + " queued.", false);
            });
         }).catch(function (error) { message(error.message, true); });
      });
      var composeActions = el("div", { className: "compose-actions" });
      add(composeActions, queueButton, notice("compose-message"));
      form.appendChild(composeActions);
      section.appendChild(form);
      root.appendChild(section);
   }

   function contactEditor(contact, onClose) {
      var form = el("form", { className: "editor" });
      var email = el("input", { value: contact ? contact.email : "", required: true });
      var first = el("input", { value: contact ? contact.firstName : "" });
      var last = el("input", { value: contact ? contact.lastName : "" });
      var external = el("input", { value: contact ? contact.externalId || "" : "" });
      var selectedLists = contact ? contact.listIds : (currentListId ? [currentListId] : []);
      var memberships = choices(state.lists, "List memberships", selectedLists);
      add(form, field("Email", email), field("First name", first),
         field("Last name", last),
         field("External ID", external), memberships);
      form.appendChild(button(contact ? "Save Contact" : "Add Contact", "primary", function () {
         request({ action: "save-contact", id: contact ? contact.id : "",
            email: email.value, first_name: first.value,
            last_name: last.value, external_id: external.value,
            list_ids: JSON.stringify(checkedValues(memberships)) }).then(function (payload) {
               state = payload;
               if (onClose) onClose();
               else renderView();
               message("Contact saved.", false);
            })
            .catch(function (error) { message(error.message, true); });
      }));
      if (contact && contact.confirmed) {
         form.appendChild(button("Reset password", "danger", function () {
            if (!window.confirm("Reset this contact's download password? Existing protected links will stop working until a new invitation is accepted.")) return;
            request({ action: "reset-contact-password", id: contact.id }).then(function (payload) {
               state = payload;
               if (onClose) onClose();
               else renderView();
               message("Password reset. Send the contact a new invitation.", false);
            }).catch(function (error) { message(error.message, true); });
         }));
      }
      if (contact && contact.unsubscribed) {
         form.appendChild(el("p", { className: "warning", text:
            "This contact has opted out and cannot receive deliveries." }));
         form.appendChild(button("Restore email", "secondary", function () {
            if (!window.confirm("Allow this contact to receive future mail again? " +
               "No list memberships will be restored.")) return;
            request({ action: "resubscribe-contact", id: contact.id }).then(function (payload) {
               state = payload;
               if (onClose) onClose();
               else renderView();
               message("Email restored. Add the contact to lists when appropriate.", false);
            }).catch(function (error) { message(error.message, true); });
         }));
      }
      if (onClose) form.appendChild(button("Cancel", "secondary", onClose));
      return form;
   }

   function listEditor(list, onClose) {
      var form = el("form", { className: "editor" });
      var name = el("input", { value: list ? list.name : "", required: true });
      var description = el("input", { value: list ? list.description : "" });
      add(form, field("Name", name), field("Description", description));
      form.appendChild(button(list ? "Save List" : "Add List", "primary", function () {
         request({ action: "save-list", id: list ? list.id : "", name: name.value,
            description: description.value }).then(function (payload) {
               if (!list && payload.savedListId) {
                  window.location.href = window.location.pathname + "?id=" + payload.savedListId;
                  return;
               }
               state = payload;
               if (onClose) onClose();
               else renderLists();
               message("List saved.", false);
            })
            .catch(function (error) { message(error.message, true); });
      }));
      if (onClose) form.appendChild(button("Cancel", "secondary", onClose));
      return form;
   }

   function templateEditor(template) {
      var form = el("form", { className: "editor wide" });
      var name = el("input", { value: template ? template.name : "", required: true });
      var source = el("textarea", { required: true, placeholder: "Paste an EML message" });
      source.value = template ? template.source : "";
      add(form, field("Name", name), field("EML source", source));
      form.appendChild(button(template ? "Save Template" : "Add Template", "primary", function () {
         request({ action: "save-template", id: template ? template.id : "",
            name: name.value, source: source.value }).then(updateView)
            .catch(function (error) { message(error.message, true); });
      }));
      return form;
   }

   function updateView(payload) {
      state = payload;
      renderView();
      message("Saved.", false);
   }

   function workspace(title, localFeedback) {
      root.replaceChildren();
      if (!localFeedback) root.appendChild(notice());
      var section = el("section", { className: "workspace" });
      section.appendChild(el("h1", { text: title }));
      root.appendChild(section);
      return section;
   }

   function destinationSelect(excludeId) {
      var select = el("select");
      select.appendChild(el("option", { value: "", text: "Select a list" }));
      state.lists.forEach(function (list) {
         if (Number(list.id) !== Number(excludeId)) {
            select.appendChild(el("option", { value: list.id, text: list.name }));
         }
      });
      return select;
   }

   function liveSearch(input, refresh) {
      var timer;
      input.addEventListener("input", function () {
         window.clearTimeout(timer);
         timer = window.setTimeout(function () {
            contactQuery = input.value.trim();
            contactPage = 1;
            refresh();
         }, 220);
      });
   }

   var contactLoadSequence = 0;

   function contactResults(editorHost, listId) {
      var result = el("div", { className: "contact-results" });
      var table = el("table", { className: "contact-table" });
      var head = el("tr");
      var selectAll = el("input", { type: "checkbox" });
      add(head, add(el("th"), selectAll), el("th", { text: "Email" }),
         el("th", { text: "First name" }), el("th", { text: "Last name" }),
         el("th", { text: "Email status" }), el("th", { text: "Password" }),
         el("th", { text: "Lists" }));
      table.appendChild(add(el("thead"), head));
      var body = el("tbody");
      state.contacts.items.forEach(function (contact) {
         var row = el("tr");
         var selected = el("input", { type: "checkbox", value: contact.id });
         var edit = button(contact.email, "link-button", function () {
            editorHost.replaceChildren(contactEditor(contact, function () {
               editorHost.replaceChildren();
               refreshContactResults(result, editorHost, listId);
            }));
            editorHost.scrollIntoView({ behavior: "smooth", block: "nearest" });
         });
         var memberships = el("td");
         if (!contact.listNames.length) {
            memberships.appendChild(el("span", { className: "muted", text: "Unassigned" }));
         } else {
            contact.listNames.forEach(function (name, index) {
               if (index) memberships.appendChild(document.createTextNode(", "));
               var link = el("a", { text: name });
               link.href = "../lists/?id=" + contact.listIds[index];
               memberships.appendChild(link);
            });
         }
          add(row, add(el("td"), selected), add(el("td"), edit),
             el("td", { text: contact.firstName || "" }),
             el("td", { text: contact.lastName || "" }),
             el("td", {
                className: contact.unsubscribed ? "unsubscribed" : "confirmed",
                text: contact.unsubscribed ? "Unsubscribed" : "Subscribed"
             }),
             el("td", {
                className: contact.confirmed ? "confirmed" : "muted",
                text: contact.confirmed ? "Confirmed" :
                   (Number(contact.invitationExpiresAt) > Date.now() / 1000 ?
                      "Invited" : "Not set")
             }),
             memberships);
         body.appendChild(row);
      });
      if (!state.contacts.items.length) {
         body.appendChild(add(el("tr"), add(el("td", {
            className: "empty-row", text: "No contacts match this view."
         }))));
         body.firstChild.firstChild.colSpan = 7;
      }
      table.appendChild(body);
      selectAll.addEventListener("change", function () {
         table.querySelectorAll("tbody input[type=checkbox]").forEach(function (input) {
            input.checked = selectAll.checked;
         });
      });
      result.appendChild(table);
      if (!state.contacts.items.length) return result;

      var pages = Math.max(1, Math.ceil(state.contacts.total / state.contacts.pageSize));
      var pager = add(el("div", { className: "pager" }),
         el("span", { text: "Page " + contactPage + " of " + pages +
            " (" + state.contacts.total + " contacts)" }));
      if (contactPage > 1) pager.insertBefore(button("Previous", "secondary", function () {
         contactPage -= 1;
         refreshContactResults(result, editorHost, listId);
      }), pager.firstChild);
      if (contactPage < pages) pager.appendChild(button("Next", "secondary", function () {
         contactPage += 1;
         refreshContactResults(result, editorHost, listId);
      }));
      result.appendChild(pager);

      var destination = destinationSelect(listId);
      var hasDestination = state.lists.some(function (list) {
         return Number(list.id) !== Number(listId);
      });
      var actions = el("div", { className: "selection-actions" });
      function selectedIds() { return checkedValues(body); }
      function selectionReady(requireDestination) {
         if (!selectedIds().length) {
            message("Select at least one contact.", true);
            return false;
         }
         if (requireDestination && !destination.value) {
            message("Select a destination list.", true);
            return false;
         }
         return true;
      }
      if (listId) {
         if (hasDestination) {
            add(actions, destination,
               button("Move selected", "primary", function () {
                if (!selectionReady(true)) return;
                request({ action: "move-list-members", source_list_id: listId,
                  destination_list_id: destination.value,
                  contact_ids: JSON.stringify(selectedIds()) }).then(function (payload) {
                     state = payload;
                     result.replaceWith(contactResults(editorHost, listId));
                      message("Selected contacts moved.", false);
                   }).catch(function (error) { message(error.message, true); });
               }));
         }
         actions.appendChild(button("Remove selected", "danger", function () {
               if (!selectionReady(false)) return;
               request({ action: "remove-list-members", source_list_id: listId,
                  contact_ids: JSON.stringify(selectedIds()) }).then(function (payload) {
                     state = payload;
                     result.replaceWith(contactResults(editorHost, listId));
                      message("Selected contacts removed from this list.", false);
                   }).catch(function (error) { message(error.message, true); });
            }));
      } else {
         if (hasDestination) {
            add(actions, destination,
               button("Add selected to list", "primary", function () {
                if (!selectionReady(true)) return;
                request({ action: "add-list-members", destination_list_id: destination.value,
                  contact_ids: JSON.stringify(selectedIds()) }).then(function (payload) {
                     state = payload;
                     result.replaceWith(contactResults(editorHost, null));
                      message("Selected contacts added to the list.", false);
                   }).catch(function (error) { message(error.message, true); });
               }));
         }
         if (contactFilter === "unsubscribed") {
            actions.appendChild(button("Restore selected", "secondary", function () {
               if (!selectionReady(false)) return;
               if (!window.confirm("Allow the selected contacts to receive future mail again? " +
                  "Their list memberships will not be restored.")) return;
               request({ action: "resubscribe-contacts",
                  contact_ids: JSON.stringify(selectedIds()) }).then(function (payload) {
                     state = payload;
                     result.replaceWith(contactResults(editorHost, null));
                     message("Selected email addresses restored. Add them to recipient lists when appropriate.", false);
                  }).catch(function (error) { message(error.message, true); });
            }));
         }
         actions.appendChild(button("Delete selected", "danger", function () {
               if (!selectionReady(false)) return;
               if (!window.confirm("Delete the selected contacts from the mailer?")) return;
               request({ action: "delete-contacts",
                  contact_ids: JSON.stringify(selectedIds()) }).then(function (payload) {
                     state = payload;
                     result.replaceWith(contactResults(editorHost, null));
                      message("Selected contacts deleted.", false);
                   }).catch(function (error) { message(error.message, true); });
            }));
      }
      result.appendChild(actions);
      return result;
   }

   function refreshContactResults(result, editorHost, listId) {
      var sequence = ++contactLoadSequence;
      loadState(contactQuery, contactPage, listId).then(function (payload) {
         if (sequence !== contactLoadSequence) return;
         state = payload;
         result.replaceWith(contactResults(editorHost, listId));
      }).catch(function (error) { message(error.message, true); });
   }

   function searchBar(resultHost, editorHost, listId) {
      var search = el("input", {
         value: contactQuery, placeholder: "Search by email, first name, or last name"
      });
      liveSearch(search, function () {
         refreshContactResults(resultHost.firstChild, editorHost, listId);
      });
      return add(el("div", { className: "search-bar" }), search,
         button("Clear", "secondary", function () {
            search.value = "";
            contactQuery = "";
            contactPage = 1;
            refreshContactResults(resultHost.firstChild, editorHost, listId);
            search.focus();
         }));
   }

   function csvImporter() {
      var section = el("section", { className: "subsection" });
      section.appendChild(el("h2", { text: "Import CSV into " + state.list.name }));
      var csvInput = el("input", { type: "file" });
      csvInput.accept = ".csv,text/csv";
      csvInput.addEventListener("change", function () { csvFile = csvInput.files[0] || null; });
      add(section, field("CSV file", csvInput), button("Preview", "secondary", function () {
         if (!csvFile) { message("Select a CSV file.", true); return; }
         csvRequest("preview", csvFile).then(function (payload) {
            state = payload;
            csvPreview = payload.csvPreview;
            renderLists();
            message("Review the detected columns before importing.", false);
         }).catch(function (error) { message(error.message, true); });
      }));
      if (!csvPreview) return section;
      var mapping = {};
      var labels = { email: "Email", firstName: "First name", lastName: "Last name",
         externalId: "External ID" };
      Object.keys(labels).forEach(function (key) {
         var select = el("select");
         select.appendChild(el("option", { value: "", text:
            key === "email" ? "Select" : "Not mapped" }));
         csvPreview.headers.forEach(function (heading, index) {
            var option = el("option", { value: index + 1,
               text: heading || ("Column " + (index + 1)) });
            option.selected = Number(csvPreview.mapping[key]) === index + 1;
            select.appendChild(option);
         });
         mapping[key] = select;
         section.appendChild(field(labels[key], select));
      });
      section.appendChild(el("p", { className: "muted", text:
         csvPreview.totalRows + " data rows; showing the first " +
         csvPreview.rows.length + "." }));
      if (!csvPreview.hasHeader) {
         section.appendChild(el("p", { className: "notice-inline", text:
            "No header row was detected. Every row shown below will be imported." }));
      }
      var previewTable = el("table", { className: "preview-table" });
      var previewHead = el("tr");
      csvPreview.headers.forEach(function (heading) {
         previewHead.appendChild(el("th", { text: heading }));
      });
      previewTable.appendChild(add(el("thead"), previewHead));
      var previewBody = el("tbody");
      csvPreview.rows.forEach(function (row) {
         var tr = el("tr");
         row.forEach(function (value) { tr.appendChild(el("td", { text: value })); });
         previewBody.appendChild(tr);
      });
      previewTable.appendChild(previewBody);
      section.appendChild(previewTable);
      (csvPreview.errors || []).forEach(function (error) {
         section.appendChild(el("p", { className: "error", text:
            "Row " + error.row + ": " + error.error.replace(/^.*: /, "") }));
      });
      var restoreUnsubscribed = el("input", { type: "checkbox" });
      section.appendChild(add(el("label", { className: "restore-option" }),
         restoreUnsubscribed,
         el("span", { text: "Restore unsubscribed contacts found in this CSV" })));
      section.appendChild(el("p", { className: "muted", text:
         "Leave this unchecked to preserve existing opt-outs." }));
      section.appendChild(button("Import Contacts", "primary", function () {
         var selected = {};
         Object.keys(mapping).forEach(function (key) {
            if (mapping[key].value) selected[key] = Number(mapping[key].value);
         });
         if (restoreUnsubscribed.checked && !window.confirm(
            "Restore unsubscribed contacts found in this CSV and add them to this list?")) return;
         csvRequest("import", csvFile, selected, restoreUnsubscribed.checked).then(function (payload) {
            state = payload;
            csvFile = null;
            csvPreview = null;
            renderLists();
            var result = payload.importResult;
             message("Imported " + result.imported + " new contacts, restored " +
                result.restored + " unsubscribed contacts, and added " +
               result.membersAdded + " contacts to this list; " +
               result.duplicates.length + " contacts already existed and " +
               result.suppressed.length + " unsubscribed contacts plus " +
               result.errors.length + " invalid rows were skipped.", false);
         }).catch(function (error) { message(error.message, true); });
      }));
      return section;
   }

   function renderContacts() {
      var page = workspace("All Contacts");
      var editorHost = el("div", { className: "editor-host" });
      var resultHost = el("div");
      resultHost.appendChild(contactResults(editorHost, null));
      var filter = el("select");
      [["all", "All contacts"], ["unassigned", "Unassigned contacts"],
         ["unsubscribed", "Unsubscribed contacts"]].forEach(function (item) {
            var option = el("option", { value: item[0], text: item[1] });
            option.selected = item[0] === contactFilter;
            filter.appendChild(option);
         });
      filter.addEventListener("change", function () {
         contactFilter = filter.value;
         contactQuery = "";
         contactPage = 1;
         loadState("", 1, null).then(function (payload) {
            state = payload;
            renderContacts();
         }).catch(function (error) { message(error.message, true); });
      });
      var toolbar = add(el("div", { className: "view-toolbar" }),
         button("New Contact", "primary", function () {
            editorHost.replaceChildren(contactEditor(null, function () {
               editorHost.replaceChildren();
            }));
         }), field("Show", filter));
      add(page, toolbar, editorHost, searchBar(resultHost, editorHost, null), resultHost);
      if (state.contacts.total > 0) {
         page.appendChild(button("Delete all contacts", "danger", function () {
            if (!window.confirm("Delete all contacts? Recipient lists will remain but become empty.")) return;
            request({ action: "delete-all-contacts" }).then(function (payload) {
               state = payload;
               contactQuery = "";
               contactPage = 1;
               renderContacts();
               message("All contacts deleted.", false);
            }).catch(function (error) { message(error.message, true); });
         }));
      }
   }

   function renderListIndex() {
      var page = workspace("Lists");
      var editorHost = el("div", { className: "editor-host" });
      page.appendChild(add(el("div", { className: "view-toolbar" }),
         button("New List", "primary", function () {
            editorHost.replaceChildren(listEditor(null, function () {
               editorHost.replaceChildren();
            }));
         })));
      page.appendChild(editorHost);
      var table = el("table", { className: "list-table" });
      var head = el("tr");
      add(head, el("th", { text: "Name" }), el("th", { text: "Contacts" }),
         el("th", { text: "Description" }), el("th", { text: "Actions" }));
      table.appendChild(add(el("thead"), head));
      var body = el("tbody");
      state.lists.forEach(function (list) {
         var row = el("tr");
         var detailsHref = window.location.pathname + "?id=" + list.id;
         var link = el("a", { text: list.name });
         link.href = detailsHref;
         var countLink = el("a", { text: list.members });
         countLink.href = detailsHref;
         var manageLink = el("a", { className: "action-link", text: "Manage contacts" });
         manageLink.href = detailsHref;
         add(row, add(el("td"), link), add(el("td"), countLink),
             el("td", { text: list.description || "" }),
             add(el("td", { className: "row-actions" }),
                manageLink,
                button("Edit", "secondary", function () {
                  editorHost.replaceChildren(listEditor(list, function () {
                     editorHost.replaceChildren();
                  }));
               }),
               button("Delete", "danger", function () {
                  if (!window.confirm("Delete " + list.name +
                     "? Contacts will remain in the mailer.")) return;
                  request({ action: "delete-list", id: list.id }).then(function (payload) {
                     state = payload;
                     renderListIndex();
                     message("List deleted.", false);
                  }).catch(function (error) { message(error.message, true); });
               })));
         body.appendChild(row);
      });
      table.appendChild(body);
      page.appendChild(add(el("div", { className: "table-scroll" }), table));
      if (state.lists.length) page.appendChild(button("Delete all lists", "danger", function () {
         if (!window.confirm("Delete all recipient lists? Contacts will not be deleted.")) return;
         request({ action: "delete-all-lists" }).then(function (payload) {
            state = payload;
            renderListIndex();
            message("All lists deleted.", false);
         }).catch(function (error) { message(error.message, true); });
      }));
   }

   function renderListDetail() {
      if (!state.list) {
         var missing = workspace("List not found");
         var missingLink = el("a", { text: "Back to Lists" });
         missingLink.href = window.location.pathname;
         missing.appendChild(missingLink);
         return;
      }
      var page = workspace(state.list.name);
      var back = el("a", { text: "Back to Lists" });
      back.href = window.location.pathname;
      page.insertBefore(back, page.firstChild);
      if (state.list.description) page.appendChild(el("p", {
         className: "list-description", text: state.list.description
      }));
      var editorHost = el("div", { className: "editor-host" });
      var toolbar = el("div", { className: "view-toolbar" });
      toolbar.appendChild(button("Edit List", "secondary", function () {
             editorHost.replaceChildren(listEditor(state.list, function () {
                editorHost.replaceChildren();
             }));
          }));
      var hasDestination = state.lists.some(function (list) {
         return Number(list.id) !== Number(currentListId);
      });
      if (state.list.members > 0 && hasDestination) {
         var transfer = destinationSelect(currentListId);
         add(toolbar, transfer, button("Move all contacts", "secondary", function () {
              if (!transfer.value) { message("Select a destination list.", true); return; }
              request({ action: "move-all-list-members", source_list_id: currentListId,
               destination_list_id: transfer.value }).then(function (payload) {
                  state = payload;
                  renderListDetail();
                   message("All contacts moved. This list is now empty.", false);
                }).catch(function (error) { message(error.message, true); });
            }), button("Merge and delete this list", "danger", function () {
              if (!transfer.value) { message("Select a destination list.", true); return; }
              if (!window.confirm("Move all contacts to the selected list and delete " +
               state.list.name + "?")) return;
            request({ action: "merge-list", source_list_id: currentListId,
               destination_list_id: transfer.value }).then(function () {
                  window.location.href = window.location.pathname;
                }).catch(function (error) { message(error.message, true); });
            }));
      }
      add(page, toolbar, editorHost);
      if (state.list.members > 0) {
         var resultHost = el("div");
         resultHost.appendChild(contactResults(editorHost, currentListId));
         add(page, searchBar(resultHost, editorHost, currentListId), resultHost);
      } else {
         var empty = el("section", { className: "empty-state" });
         empty.appendChild(el("h2", { text: "This list is empty" }));
         empty.appendChild(el("p", { text:
            "Import a CSV below, or select existing contacts from All Contacts." }));
         var contactsLink = el("a", { text: "Open All Contacts" });
         contactsLink.href = "../contacts/";
         empty.appendChild(contactsLink);
         page.appendChild(empty);
      }
      page.appendChild(csvImporter());
   }

   function renderLists() {
      if (currentListId) renderListDetail();
      else renderListIndex();
   }

   function renderRemove() {
      var page = workspace("Remove Contacts");
      page.appendChild(el("p", { className: "muted", text:
         "Paste text containing email addresses. The mailer extracts unique addresses and shows which contacts match before anything is removed." }));
      var input = el("textarea", {
         className: "bulk-email-input",
         placeholder: "Paste email addresses, message headers, logs, or other text"
      });
      input.value = removalText;
      input.addEventListener("input", function () {
         removalText = input.value;
         removalPreview = null;
      });
      add(page, field("Text containing email addresses", input),
         button("Preview matches", "primary", function () {
            removalText = input.value;
            if (!removalText.trim()) { message("Paste text containing email addresses.", true); return; }
            removalRequest("preview", removalText).then(function (payload) {
               removalPreview = payload.removalPreview;
               renderRemove();
               message("Review the matched contacts before removing them.", false);
            }).catch(function (error) { message(error.message, true); });
         }));
      if (!removalPreview) return;

      var preview = el("section", { className: "removal-preview" });
      preview.appendChild(el("h2", { text: "Removal preview" }));
      preview.appendChild(el("p", { text:
         removalPreview.extractedCount + " unique email addresses extracted; " +
         removalPreview.matchCount + " contacts match; " +
         removalPreview.notFoundCount + " addresses are not in the contact database." }));
      if (removalPreview.matches.length) {
         var table = el("table", { className: "contact-table removal-table" });
         var head = el("tr");
         add(head, el("th", { text: "Email" }), el("th", { text: "First name" }),
            el("th", { text: "Last name" }));
         table.appendChild(add(el("thead"), head));
         var body = el("tbody");
         removalPreview.matches.forEach(function (contact) {
            add(body, add(el("tr"), el("td", { text: contact.email }),
               el("td", { text: contact.firstName || "" }),
               el("td", { text: contact.lastName || "" })));
         });
         table.appendChild(body);
         preview.appendChild(add(el("div", { className: "table-scroll" }), table));
         if (removalPreview.matchesTruncated) preview.appendChild(el("p", {
            className: "muted", text: "Showing the first 200 matching contacts."
         }));
         preview.appendChild(button("Remove " + removalPreview.matchCount + " contacts",
            "danger", function () {
               if (!window.confirm("Permanently remove " + removalPreview.matchCount +
                  " matched contacts from the mailer?")) return;
               removalRequest("execute", removalText).then(function (payload) {
                  var result = payload.removalResult;
                  removalText = "";
                  removalPreview = null;
                  renderRemove();
                  message("Removed " + result.removed + " contacts. " +
                     result.notFoundCount + " extracted addresses were not found.", false);
               }).catch(function (error) { message(error.message, true); });
            }));
      } else {
         preview.appendChild(el("p", { className: "warning", text:
            "None of the extracted addresses match a contact." }));
      }
      if (removalPreview.notFound.length) {
         var missing = el("details", { className: "missing-addresses" });
         missing.appendChild(el("summary", { text: "Addresses not found" }));
         missing.appendChild(el("p", { text: removalPreview.notFound.join(", ") }));
         if (removalPreview.notFoundTruncated) missing.appendChild(el("p", {
            className: "muted", text: "Showing the first 100 missing addresses."
         }));
         preview.appendChild(missing);
      }
      page.appendChild(preview);
   }

   function renderTemplates() {
      var page = workspace("Templates");
      var templatesSection = el("section");
      var templateEditorHost = el("div");
      templateEditorHost.appendChild(templateEditor(null));
      add(templatesSection, el("h2", { text: "Message Templates" }), templateEditorHost);
      state.templates.forEach(function (template) {
         var row = el("div", { className: "data-row" });
         add(row, el("span", { text: template.name + " r" + template.revision }),
            button("Edit", "secondary", function () {
               templateEditorHost.replaceChildren(templateEditor(template));
            }),
            button("Delete", "danger", function () {
               if (!window.confirm("Delete " + template.name + "?")) return;
               request({ action: "delete-template", id: template.id }).then(updateView)
                  .catch(function (error) { message(error.message, true); });
            }));
         templatesSection.appendChild(row);
      });
      page.appendChild(templatesSection);
   }

   function renderJobs() {
      var page = workspace("Jobs");
      var history = el("section");
      history.appendChild(el("h2", { text: "Delivery History" }));
      var retentionDays = el("input", { type: "number", value: 90 });
      retentionDays.min = "1";
      history.appendChild(add(el("div", { className: "inline-controls" }),
         field("Delete completed history older than days", retentionDays),
         button("Purge", "danger", function () {
            if (!window.confirm("Permanently delete old completed delivery history?")) return;
            var cutoff = Math.floor(Date.now() / 1000) - Number(retentionDays.value) * 86400;
            request({ action: "purge-history", older_than: cutoff }).then(updateView)
               .catch(function (error) { message(error.message, true); });
         })));
      (state.history ? state.history.items : []).forEach(function (job) {
         var entry = el("article", { className: "job-entry" });
         var historyRow = el("div", { className: "data-row" });
         historyRow.appendChild(el("span", { text:
             "#" + job.id + " " + job.status + " - " +
             (job.jobType === "invitation" ? "Invitation: " : "") + job.subject +
             " - " + job.sent + "/" + job.recipients + " sent" }));
         var detailHost = el("div");
         var viewButton = button("View", "secondary", function () {
            if (detailHost.firstChild) {
               detailHost.replaceChildren();
               viewButton.textContent = "View";
               return;
            }
            viewButton.disabled = true;
            viewButton.textContent = "Loading...";
            loadJob(job.id).then(function (payload) {
               detailHost.replaceChildren(renderJobDetails(payload.job));
               viewButton.textContent = "Hide";
            }).catch(function (error) {
               detailHost.replaceChildren(el("p", { className: "error", text: error.message }));
               viewButton.textContent = "Retry";
            }).finally(function () { viewButton.disabled = false; });
         });
         historyRow.appendChild(viewButton);
         if (["draft", "queued", "sending", "retry"].indexOf(job.status) >= 0) {
            historyRow.appendChild(button("Cancel", "danger", function () {
               if (!window.confirm("Cancel delivery #" + job.id + "?")) return;
               request({ action: "cancel-job", id: job.id }).then(updateView)
                  .catch(function (error) { message(error.message, true); });
            }));
         }
         add(entry, historyRow, detailHost);
         history.appendChild(entry);
      });
      page.appendChild(history);
   }

   function renderInvitations() {
      var page = workspace("Password Invitations", true);
      var stats = state.confirmation || {
         total: 0, confirmed: 0, unconfirmed: 0, invited: 0
      };
      page.appendChild(add(el("div", { className: "summary-grid" }),
         add(el("div", { className: "summary-item" }),
            el("strong", { text: stats.confirmed }), el("span", { text: "Confirmed" })),
         add(el("div", { className: "summary-item" }),
            el("strong", { text: stats.unconfirmed }), el("span", { text: "Unconfirmed" })),
         add(el("div", { className: "summary-item" }),
            el("strong", { text: stats.invited }), el("span", { text: "Invitation active" }))));
      var publicBaseUrl = state.settings && state.settings.publicBaseUrl;
      if (!publicBaseUrl) {
         var baseWarning = el("p", { className: "warning invitation-settings-warning" });
         baseWarning.appendChild(document.createTextNode(
            "Set the Public base URL before sending password invitations. "));
         if (settingsUrl) {
            var settingsLink = el("a", { text: "Open Mailer Settings" });
            settingsLink.href = settingsUrl;
            baseWarning.appendChild(settingsLink);
         } else {
            baseWarning.appendChild(document.createTextNode(
               "Ask a CMS administrator to configure it in Mailer Settings."));
         }
         page.appendChild(baseWarning);
      }
      var form = el("form", { className: "compose-form" });
      var subject = el("input", { required: true, value: "Confirm your email address" });
      var textBody = el("textarea", {
         required: true,
         value: "Hello {{FIRST_NAME}},\n\nSet your personal file-download password using this link:\n{{INVITATION_LINK}}"
      });
      var htmlBody = el("textarea", {
         placeholder: "Optional HTML invitation, or paste a complete EML"
      });
      var emlEditor = smartEmlEditor(subject, textBody, htmlBody, null);
      var linkHelp = el("p", { className: "muted link-placement-help" });
      linkHelp.appendChild(document.createTextNode(
         "The password setup link is appended automatically. Use "));
      linkHelp.appendChild(el("code", { text: "{{INVITATION_LINK}}" }));
      linkHelp.appendChild(document.createTextNode(
         " only when you want to control its position."));
      var contacts = composeContactPicker();
      var lists = choices(state.lists, "Recipient lists", null, true);
      var recipientGrid = add(el("div", { className: "recipient-grid" }), contacts, lists);
      var queueButton = button("Queue Invitations", "primary", function () {
         emlEditor.whenReady().then(function () {
            if (!form.reportValidity()) return;
            var contactIds = composeContactIds();
            var listIds = checkedValues(lists);
            if (listIds.length === 0 && contactIds.length === 0) {
               message("Select contacts or recipient lists.", true);
               return;
            }
            message("Creating invitation job...", false);
            return request({
               action: "create-invitation-job",
               subject: subject.value,
               text_body: textBody.value,
               html_body: htmlBody.value,
               contact_ids: JSON.stringify(contactIds),
               list_ids: JSON.stringify(listIds)
            }).then(function (payload) {
               composeContacts = {};
               state = payload;
               renderInvitations();
               message("Invitation job " + payload.job.id + " queued.", false);
            });
         }).catch(function (error) { message(error.message, true); });
      });
      queueButton.disabled = !publicBaseUrl;
      if (!publicBaseUrl) queueButton.title = "Set the Public base URL first";
      var invitationActions = add(el("div", { className: "compose-actions" }),
         queueButton, notice("invitation-message"));
      add(form,
         field("Subject", subject),
         field("Plain text invitation", textBody),
         field("Optional HTML invitation", htmlBody),
         linkHelp,
         recipientGrid,
         invitationActions
      );
      page.appendChild(form);
   }

   function renderView() {
      if (view === "contacts" && state.manager) renderContacts();
      else if (view === "lists" && state.manager) renderLists();
      else if (view === "remove" && state.manager) renderRemove();
      else if (view === "invitations" && state.manager) renderInvitations();
      else if (view === "templates" && state.manager) renderTemplates();
      else if (view === "jobs" && state.manager) renderJobs();
      else renderCompose();
   }

   loadState("", 1, currentListId).then(function (payload) {
      state = payload;
      renderView();
   }).catch(function (error) { root.textContent = "Mailer could not load: " + error.message; });
}());
