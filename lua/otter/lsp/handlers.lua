--- Intermediate handlers for otter-ls where the response needs to be modified
--- before being passed on to the default handler
--- docs: https://microsoft.github.io/language-server-protocol/specifications/specification-current/
---@type table<string, lsp.Handler>
local M = {}

local fn = require("otter.tools.functions")
local ms = vim.lsp.protocol.Methods
local modify_position = require("otter.keeper").modify_position

local function filter_one_or_many(response, filter)
  if #response == 0 then
    return filter(response)
  else
    local modified_response = {}
    for _, res in ipairs(response) do
      table.insert(modified_response, filter(res))
    end
    return modified_response
  end
end

--- Rewrite otter uris in a workspace edit back to the main buffer and correct
--- for the leading whitespace otter strips from code chunks.
---@param edit lsp.WorkspaceEdit
---@param ctx lsp.HandlerContext
local function remap_workspace_edit(edit, ctx)
  local main_uri = ctx.params.otter.main_uri
  if edit.changes then
    local changes = {}
    for uri, text_edits in pairs(edit.changes) do
      if fn.is_otterpath(uri) then
        uri = main_uri
      end
      changes[uri] = text_edits
    end
    edit.changes = changes
  end
  if edit.documentChanges then
    for _, change in ipairs(edit.documentChanges) do
      if change.textDocument and fn.is_otterpath(change.textDocument.uri) then
        change.textDocument.uri = main_uri
        -- the otter buffer keeps its own changedtick, which is unrelated to the
        -- main buffer's. Leaving it in place makes nvim discard the edit as stale.
        change.textDocument.version = nil
      end
    end
  end
  modify_position(edit, ctx.params.otter.main_nr)
  return edit
end

--- Is `line` (0-indexed) inside a code chunk of `lang`?
local function line_in_chunks(line, chunks)
  for _, chunk in ipairs(chunks) do
    if line >= chunk.range.from[1] and line <= chunk.range.to[1] then
      return true
    end
  end
  return false
end

--- Refuse workspace edits that would touch anything outside the code chunks of
--- `lang`.
---
--- A language server sees the otter buffer as an ordinary source file and may
--- legitimately propose edits anywhere in it. ruff's "organize imports", for
--- example, hoists imports to the top of the file -- which in the main document
--- is the YAML frontmatter, not code. Applying that verbatim corrupts the
--- document, so such actions are dropped rather than offered.
---@return boolean ok, string? reason
local function edit_within_chunks(edit, main_nr, lang)
  local raft = require("otter.keeper").rafts[main_nr]
  if not raft then
    return false, "no otter buffers for this document"
  end
  local chunks = (raft.code_chunks or {})[lang]
  if not chunks or #chunks == 0 then
    return false, "no " .. tostring(lang) .. " code chunks"
  end

  local function check(text_edits)
    for _, te in ipairs(text_edits or {}) do
      local range = te.range
      if range then
        local last = range["end"]
        -- an edit that replaces a whole final line ends at character 0 of the
        -- *following* line, which is legitimately one past the chunk. This must
        -- not be applied to a range that ends on the line it starts on, such as
        -- the zero-width insertion at character 0 that servers use to prepend a
        -- line -- that still belongs to the line it points at.
        local last_line = last.line
        if last.character == 0 and last.line > range.start.line then
          last_line = last.line - 1
        end
        if not line_in_chunks(range.start.line, chunks) or not line_in_chunks(last_line, chunks) then
          return false, string.format("it edits line %d, outside any %s chunk", range.start.line + 1, lang)
        end
      end
    end
    return true
  end

  if edit.changes then
    for _, text_edits in pairs(edit.changes) do
      local ok, reason = check(text_edits)
      if not ok then
        return false, reason
      end
    end
  end
  if edit.documentChanges then
    for _, change in ipairs(edit.documentChanges) do
      -- create/rename/delete file operations cannot be mapped onto a code chunk
      if change.kind then
        return false, string.format("it performs a '%s' file operation", change.kind)
      end
      local ok, reason = check(change.edits)
      if not ok then
        return false, reason
      end
    end
  end
  return true
end

local function reject(title, reason)
  vim.notify(
    string.format("[otter] dropped code action %q: %s", title or "?", reason or "unsupported"),
    vim.log.levels.DEBUG,
    {}
  )
end

--- see e.g.
--- vim.lsp.handlers.hover(_, result, ctx)
---@param err lsp.ResponseError?
---@param response lsp.Hover
---@param ctx lsp.HandlerContext
M[ms.textDocument_hover] = function(err, response, ctx)
  if not response then
    return err, response, ctx
  end

  -- pretend the response is coming from the main buffer
  ctx.params.textDocument.uri = ctx.params.otter.main_uri

  -- Adjust range for highlighting if present
  -- The hover response may include a range to highlight the hovered symbol
  if response.range then
    modify_position(response, ctx.params.otter.main_nr)
  end

  -- pass modified response on to the default handler
  return err, response, ctx
end

M[ms.textDocument_inlayHint] = function(err, response, ctx)
  if not response then
    return
  end

  -- pretend the response is coming from the main buffer
  ctx.params.textDocument.uri = ctx.params.otter.main_uri

  return err, response, ctx
end

M[ms.textDocument_definition] = function(err, response, ctx)
  if not response then
    return
  end
  local function filter(res)
    if res.uri ~= nil then
      if fn.is_otterpath(res.uri) then
        res.uri = ctx.params.otter.main_uri
      end
    end
    if res.targetUri ~= nil then
      if fn.is_otterpath(res.targetUri) then
        res.targetUri = ctx.params.otter.main_uri
      end
    end
    modify_position(res, ctx.params.otter.main_nr)
    return res
  end
  response = filter_one_or_many(response, filter)
  return err, response, ctx
end

M[ms.textDocument_documentSymbol] = function(err, response, ctx)
  if not response then
    return err, response, ctx
  end

  local function filter(res)
    if not res.location or not res.location.uri then
      return res
    end
    local uri = res.location.uri
    if fn.is_otterpath(uri) then
      res.location.uri = ctx.params.otter.main_uri
    end
    modify_position(res, ctx.params.otter.main_nr)
    return res
  end
  response = filter_one_or_many(response, filter)

  ctx.params.textDocument.uri = fn.otterpath_to_path(ctx.params.textDocument.uri)
  return err, response, ctx
end

M[ms.textDocument_typeDefinition] = function(err, response, ctx)
  if not response then
    return err, response, ctx
  end

  local function filter(res)
    if res.uri ~= nil then
      if fn.is_otterpath(res.uri) then
        res.uri = ctx.params.otter.main_uri
      end
    end
    if res.targetUri ~= nil then
      if fn.is_otterpath(res.targetUri) then
        res.targetUri = ctx.params.otter.main_uri
      end
    end
    modify_position(res, ctx.params.otter.main_nr)
    return res
  end
  response = filter_one_or_many(response, filter)

  return err, response, ctx
end

M[ms.textDocument_rename] = function(err, response, ctx)
  if not response then
    return err, response, ctx
  end

  local function filter(res)
    local changes = res.changes
    if changes ~= nil then
      local new_changes = {}
      for uri, change in pairs(changes) do
        if fn.is_otterpath(uri) then
          uri = ctx.params.otter.main_uri
        end
        new_changes[uri] = change
      end
      res.changes = new_changes
      modify_position(res, ctx.params.otter.main_nr)
      return res
    else
      changes = res.documentChanges
      local new_changes = {}
      for _, change in ipairs(changes) do
        local uri = change.textDocument.uri
        if fn.is_otterpath(uri) then
          change.textDocument.uri = ctx.params.otter.main_uri
        end
        table.insert(new_changes, change)
      end
      res.documentChanges = new_changes
      modify_position(res, ctx.params.otter.main_nr)
      return res
    end
  end
  response = filter_one_or_many(response, filter)
  return err, response, ctx
end

M[ms.textDocument_references] = function(err, response, ctx)
  if not response then
    return err, response, ctx
  end

  local function filter(res)
    local uri = res.uri
    if not res.uri then
      return res
    end
    if fn.is_otterpath(uri) then
      res.uri = ctx.params.otter.main_uri
    end
    modify_position(res, ctx.params.otter.main_nr)
    return res
  end
  response = filter_one_or_many(response, filter)

  -- change the ctx after the otter buffer has responded
  ctx.params.textDocument.uri = fn.otterpath_to_path(ctx.params.textDocument.uri)
  return err, response, ctx
end

M[ms.textDocument_implementation] = function(err, response, ctx)
  if not response then
    return err, response, ctx
  end
  local function filter(res)
    if res.uri ~= nil then
      if fn.is_otterpath(res.uri) then
        res.uri = ctx.params.otter.main_uri
      end
    end
    if res.targetUri ~= nil then
      if fn.is_otterpath(res.targetUri) then
        res.targetUri = ctx.params.otter.main_uri
      end
    end
    modify_position(res, ctx.params.otter.main_nr)
    return res
  end
  response = filter_one_or_many(response, filter)

  return err, response, ctx
end

M[ms.textDocument_declaration] = function(err, response, ctx)
  if not response then
    return err, response, ctx
  end
  local function filter(res)
    if res.uri ~= nil then
      if fn.is_otterpath(res.uri) then
        res.uri = ctx.params.otter.main_uri
      end
    end
    if res.targetUri ~= nil then
      if fn.is_otterpath(res.targetUri) then
        res.targetUri = ctx.params.otter.main_uri
      end
    end
    modify_position(res, ctx.params.otter.main_nr)
    return res
  end
  response = filter_one_or_many(response, filter)
  return err, response, ctx
end

---@param err lsp.ResponseError
---@param response vim.lsp.CompletionResult
---@param ctx lsp.HandlerContext
---@return lsp.ResponseError
---@return vim.lsp.CompletionResult?
---@return lsp.HandlerContext
M[ms.textDocument_completion] = function(err, response, ctx)
  if not response then
    return err, response, ctx
  end
  ctx.params.textDocument.uri = ctx.params.otter.main_uri
  ctx.bufnr = ctx.params.otter.main_nr

  -- treat response as lsp.CompletionItem[] instead of lsp.CompletionList if isIncomplete is missing
  -- see https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#completionParams response
  local is_completion_list = response.isIncomplete ~= nil
  ---@type lsp.CompletionItem[]
  local items = is_completion_list and response.items or response
  local main_nr = ctx.params.otter.main_nr

  for _, item in ipairs(items) do
    if item.data ~= nil and item.data.uri ~= nil then
      item.data.uri = ctx.params.otter.main_uri
    end

    -- Adjust textEdit range for leading whitespace offset
    -- This is needed for blink.cmp and other completion plugins that use textEdit
    if item.textEdit then
      modify_position(item.textEdit, main_nr)
    end

    -- Adjust additionalTextEdits (e.g., auto-imports)
    if item.additionalTextEdits then
      for _, edit in ipairs(item.additionalTextEdits) do
        modify_position(edit, main_nr)
      end
    end
  end
  return err, response, ctx
end

M[ms.completionItem_resolve] = function(err, response, ctx)
  if not response then
    return err, response, ctx
  end
  if ctx.params.data ~= nil then
    ctx.params.data.uri = ctx.params.otter.main_uri
  end
  ctx.params.textDocument.uri = ctx.params.otter.main_uri
  ctx.bufnr = ctx.params.otter.main_nr

  if response.data ~= nil and response.data.uri ~= nil then
    response.data.uri = ctx.params.otter.main_uri
  end

  local main_nr = ctx.params.otter.main_nr

  -- Adjust textEdit if present (may be added during resolve)
  if response.textEdit then
    modify_position(response.textEdit, main_nr)
  end

  -- Adjust additionalTextEdits (may be added during resolve, e.g., auto-imports)
  if response.additionalTextEdits then
    for _, edit in ipairs(response.additionalTextEdits) do
      modify_position(edit, main_nr)
    end
  end

  return err, response, ctx
end

--- Code actions are proxied with two restrictions, both of which exist because
--- the attached server reasons about the otter buffer rather than the document:
---
---  * edits that fall outside the code chunks of the current language are
---    dropped (see edit_within_chunks)
---  * actions carrying a `command` are dropped, because executing it would run
---    `workspace/executeCommand` against the otter buffer and any resulting
---    `workspace/applyEdit` would be applied to the otter path on disk
---
--- `data` is opaque, server-owned, and deliberately passed through untouched so
--- that codeAction/resolve round-trips correctly.
M[ms.textDocument_codeAction] = function(err, response, ctx)
  if not response then
    return err, response, ctx
  end

  local main_nr = ctx.params.otter.main_nr
  local lang = ctx.params.otter.lang
  local kept = {}

  for _, action in ipairs(response) do
    local keep = true

    if action.edit then
      local ok, reason = edit_within_chunks(action.edit, main_nr, lang)
      if ok then
        remap_workspace_edit(action.edit, ctx)
      else
        keep = false
        reject(action.title, reason)
      end
    end

    if keep and action.command and not action.edit then
      keep = false
      reject(action.title, "command-based actions cannot be proxied safely")
    end

    if keep and action.diagnostics then
      for _, diagnostic in ipairs(action.diagnostics) do
        modify_position(diagnostic, main_nr)
      end
    end

    if keep then
      table.insert(kept, action)
    end
  end

  return err, kept, ctx
end

--- Lazily resolved code actions (ruff's fixes, for instance) only carry their
--- edit once resolved, so the same checks have to run again here.
M[ms.codeAction_resolve] = function(err, response, ctx)
  if not response then
    return err, response, ctx
  end

  if response.edit then
    local ok, reason = edit_within_chunks(response.edit, ctx.params.otter.main_nr, ctx.params.otter.lang)
    if not ok then
      reject(response.title, reason)
      -- returning the action without its edit is what nvim expects for a
      -- resolve that yields nothing applicable
      response.edit = nil
      return err, response, ctx
    end
    remap_workspace_edit(response.edit, ctx)
  end

  return err, response, ctx
end

return M
