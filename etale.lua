-- 把 tex 行内命令 \etale / \Etale 还原为带重音符的 Unicode 字母。
-- 仅处理"整个 RawInline 就是一个命令（可带尾随空格）"的情形，其余原样放行。

local etaleCommands = {
  ["\\etale"] = "étale",
  ["\\Etale"] = "Étale",
}

function RawInline(inline)
  if inline.format ~= "tex" then
    return nil
  end

  local command, trailingSpace = inline.text:match("^(\\%a+)(%s*)$")
  local replacement = etaleCommands[command]
  if not replacement then
    return nil
  end

  local result = { pandoc.Str(replacement) }
  if trailingSpace ~= "" then
    -- 保留原尾随空格，避免与后文粘连
    result[#result + 1] = pandoc.Space()
  end

  return result
end
