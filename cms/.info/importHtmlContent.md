Import saved or legacy HTML into FuguHub for this request:

{{userRequest}}

1. Use only this server's HTTP MCP tools. Call `getCapabilities`,
   `getContentAuthoringContract`, and
   `getAssetCapabilities`. Read existing content if the target may already
   exist, and ask whether to create or update when ambiguous.
2. Determine the source charset from the HTTP `Content-Type`, BOM, and
   `<meta charset>` declarations. Decode strictly before transforming HTML.
   Do not replace undecodable bytes silently. Stop and ask when declarations
   conflict or the encoding cannot be determined.
3. Check decoded text for mojibake before saving. Text such as `Ã`, `Â`,
   `â€™`, or `ðŸ` is evidence to recheck decoding, not content to normalize
   blindly.
4. Parse the source document and inventory linked stylesheets, scripts,
   images, fonts, media, and generated widget markup before removing
   `<html>`, `<head>`, and `<body>`.
5. Separate safe static dependencies from executable JavaScript. Use MCP asset
   tools for required files. Do not import scripts, event handlers, or
   executable LSP unless the user explicitly requests trusted executable code.
   Replace script-generated widgets with safe static markup when practical.
6. Adapt the article to the active theme. Scope retained CSS under a unique
   article wrapper or deliberately restyle the markup; do not rely on source
   page global styles. Rewrite asset references to the mount-aware public URLs
   returned by the asset API.
7. Apply the theme title contract, heading rules, and anchor preservation.
   Extract only a valid body fragment and explicitly selected safe head
   metadata. Call `validateContent`.
8. Create as a draft, or update with the latest `expectedUpdatedAt`. A
   successful structural validation does not prove correct character encoding,
   complete dependencies, or acceptable visual design.
9. Render the draft through the active theme using the authenticated admin
   Preview action. Perform browser checks at desktop and mobile breakpoints:
   text contrast, horizontal overflow, heading hierarchy, code blocks,
   tables, lazy-loaded media after scrolling, missing assets, and console or
   network errors.
10. Correct import defects and repeat validation and visual checks. Publish
    only when the user explicitly requests publication.
