export default function mailerFiles(api) {
   return api.add("command", {
      id: "email-selected-files",
      label: "Email selected files",
      toolbar: true,
      menu: true,
      showDisabled: false,
      when(context) {
         return context.selection.length > 0 && context.selection.every(function (entry) {
            return entry.s !== -1 && typeof entry.path === "string";
         });
      },
      run(context) {
         const composeUrl = new URL("./compose/", import.meta.url);
         const key = "fuguhub.mailer.selection:" + composeUrl.pathname;
         try {
            sessionStorage.setItem(key, JSON.stringify(
               context.selection.map(function (entry) { return entry.path; })
            ));
            location.assign(composeUrl.href);
         } catch (error) {
            const message = document.createElement("p");
            message.textContent = "The selected files could not be transferred to the mailer.";
            api.ui.open({ title: "Email selected files", content: message });
         }
      }
   });
}
