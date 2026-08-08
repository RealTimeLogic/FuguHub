Create or update FuguHub content for this request:

{{userRequest}}

1. Call `getCapabilities`, then read existing content if the target may exist.
2. Ask whether to create or update when intent or target is ambiguous.
3. Call `getContentAuthoringContract`. Convert Markdown to HTML and promote or
   retain its first H1 according to the active theme's title contract. Preserve
   any referenced title anchor.
4. Validate HTML snippets and repair only harmless structural issues.
5. Reject document wrappers, scripts, inline event handlers, unsafe URL
   schemes, and unsolicited LSP tags.
6. Create as a draft unless publication was explicitly requested.
7. Preserve status on ordinary updates and send `expectedUpdatedAt` from the
   latest read.
8. Use `setContentStatus` only when publication or unpublication is explicit.
9. Read the resulting content and report its path, status, and warnings.
