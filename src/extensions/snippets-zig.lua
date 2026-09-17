-- ZIDE Zig snippets. Edit freely; this file is only created when missing.
-- Run reload_extensions after editing. Tab expands an exact trigger and
-- visits fields; Shift+Tab goes back; Escape ends navigation, keeping text.
-- Leading \t represents one indentation level using this document's settings.
local snippets = {
  { "fn", "Function", "fn ${1:name}($2) ${3:void} {\n\t$0\n}" },
  { "if", "If statement", "if (${1:condition}) {\n\t$0\n}" },
  { "ifelse", "If / else statement", "if (${1:condition}) {\n\t$2\n} else {\n\t$0\n}" },
  { "while", "While loop", "while (${1:condition}) {\n\t$0\n}" },
  { "for", "For loop", "for (${1:items}) |${2:item}| {\n\t$0\n}" },
  { "switch", "Switch statement", "switch (${1:value}) {\n\t${2:else} => {\n\t\t$0\n\t},\n}" },
  { "struct", "Struct declaration", "const ${1:Name} = struct {\n\t$0\n};" },
  { "enum", "Enum declaration", "const ${1:Name} = enum {\n\t${2:member},\n\t$0\n};" },
  { "test", "Test declaration", "test \"${1:name}\" {\n\t$0\n}" },
}
for _, snippet in ipairs(snippets) do
  local command, err = zide.register_snippet({
    language = "zig", prefix = snippet[1], description = snippet[2], body = snippet[3],
  })
  assert(command, err)
end
