--[[
  渲染期生成：定理/证明外观 + 右侧目录（On this page）

  为什么放在这里而不放在 JS 里：
  * 定理编号、标题、折叠外壳与目录条目都在 Pandoc AST 上确定，
    _site/*.html 打开即是最终结构，不依赖浏览器事后改写 DOM；
  * 目录条目与正文锚点来自同一次扫描，编号与 id 必然一致；
  * 运行时脚本只保留「点击展开/收起、平滑滚动定位、滚动高亮」这类交互。

  输出约定（与 thm-toc.html / styles.css 的样式钩子对应）：
    <div id="thm-xxx" class="theorem kind-theorem">
      <div class="theorem-header is-clickable"><span><strong>Theorem 22.5.0</strong> (…)</span><svg …/></div>
      <div class="theorem-body">…</div>
    </div>
  目录经 metadata 变量 note-toc 交给 _partials/toc.html 输出到右侧栏。

  三趟过滤器（顺序有意义，Quarto 的 Meta 派发晚于块遍历，必须拆开）：
    1. Meta            —— 读取章节前缀与 toc-depth，重置计数；
    2. 元素回调扫描     —— 按文档顺序编号定理、收集目录条目；
    3. Pandoc          —— 依据扫描结果重写块结构，并写出 note-toc 元数据。
  说明：Theorem/Proof 在 AST 里是带 __quarto_custom_type 的 Div，
        真 id / 标题只存在于自定义节点对象上，所以第 2 趟负责"认领"，第 3 趟负责"重建"。
]]

local KIND_BY_PREFIX = {
  def = "definition",
  lem = "lemma",
  prp = "proposition",
  thm = "theorem",
  cor = "corollary",
  rem = "remark",
  exm = "example",
}

local KIND_LABEL = {
  definition  = { full = "Definition",  short = "Def" },
  lemma       = { full = "Lemma",       short = "Lem" },
  proposition = { full = "Proposition", short = "Prop" },
  theorem     = { full = "Theorem",     short = "Thm" },
  corollary   = { full = "Corollary",   short = "Cor" },
  remark      = { full = "Remark",      short = "Rem" },
  example     = { full = "Example",     short = "Ex" },
}

local CHEVRON = '<svg class="fold-chevron" width="13" height="13" viewBox="0 0 24 24" '
  .. 'fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" '
  .. 'stroke-linejoin="round"><polyline points="6 9 12 15 18 9"></polyline></svg>'

-- Quarto 内部容器：导航副本与 markdown 镜像不参与编号与目录
local SKIP_IDS = {
  ["quarto-navigation-envelope"] = true,
  ["quarto-meta-markdown"] = true,
}

-- 文档级状态
local state = {
  enabled = false,
  sec = "22.0.",
  depth = 3,
  counter = 0,
  shells = 0,       -- 本页生成多少个定理外壳（决定是否需要强制开启目录）
  items = {},       -- 目录条目（与正文同序）
  seq = {},         -- 定理/证明节点（按文档顺序），第 3 趟按同一顺序回填
}

--------------------------------------------------------------------- 工具

local function escape_html(text)
  local escaped = text:gsub("&", "&amp;")
  escaped = escaped:gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
  return escaped
end

local function kind_of(identifier)
  local prefix = identifier:match("^(%a+)%-")
  return prefix and KIND_BY_PREFIX[prefix] or nil
end

-- 标题块（可能含行内公式）转成 HTML，供 header 使用
local function block_to_html(block)
  if not block then
    return ""
  end
  local html = pandoc.write(pandoc.Pandoc({ block }), "html")
  html = html:gsub("^%s*<p>", ""):gsub("</p>%s*$", "")
  return html:gsub("%s+$", "")
end

local function read_sec_prefix(meta)
  local raw = meta.sec and pandoc.utils.stringify(meta.sec) or ""
  raw = raw:gsub('["\']', "")
  if #raw > 0 then
    return raw:sub(-1) == "." and raw or raw .. "."
  end

  local title = meta.title and pandoc.utils.stringify(meta.title) or ""
  local number = title:match("^(%d+(?:%.%d+)*)")
  return number and (number .. ".") or "22.0."
end

-- 正文块：Div[ scaffold > Div > 正文, scaffold > 标题 ]
local function custom_body(node)
  local scaffold = node.content[1]
  if not scaffold then
    return {}
  end
  local inner = scaffold.content[1]
  if inner and inner.t == "Div" then
    return inner.content
  end
  return scaffold.content
end

------------------------------------------------------------------- 目录条目

local function toc_html(items)
  if #items == 0 then
    return ""
  end

  local out = { "<ul>" }
  for _, item in ipairs(items) do
    local classes = item.theorem and "nav-item callout-toc-item" or "nav-item"
    local title_attr = item.tooltip and (' title="' .. escape_html(item.tooltip) .. '"') or ""
    out[#out + 1] = string.format(
      '<li class="%s"><a href="#%s" id="toc-%s" class="nav-link" data-scroll-target="#%s"%s>%s</a></li>',
      classes, item.id, item.id, item.id, title_attr, escape_html(item.label))
  end
  out[#out + 1] = "</ul>"
  return table.concat(out, "\n")
end

--------------------------------------------------------------------- 第 1 趟

local pass_meta = {
  Meta = function(meta)
    state.enabled = FORMAT:match("html") ~= nil
    state.counter = 0
    state.shells = 0
    state.items = {}
    state.seq = {}
    if state.enabled then
      state.sec = read_sec_prefix(meta)
      state.depth = math.floor(tonumber(pandoc.utils.stringify(meta["toc-depth"] or "3")) or 3)
    end
  end,
}

--------------------------------------------------------------------- 第 2 趟

local function scan_theorem(el)
  local kind = kind_of(el.identifier) or "theorem"
  local conf = KIND_LABEL[kind]
  local number = state.sec .. tostring(state.counter)
  state.counter = state.counter + 1

  local name = el.name
  local sub_text = name and pandoc.utils.stringify(name) or ""
  state.shells = state.shells + 1

  state.seq[#state.seq + 1] = {
    id = el.identifier,
    kind = kind,
    number = number,
    name = name,
  }

  state.items[#state.items + 1] = {
    id = el.identifier,
    label = conf.short .. " " .. number,
    tooltip = conf.full .. " " .. number .. (sub_text ~= "" and (" (" .. sub_text .. ")") or ""),
    theorem = true,
  }
end

local pass_scan = {
  Theorem = function(el)
    if state.enabled then scan_theorem(el) end
    return nil
  end,

  Proof = function(el)
    if not state.enabled then
      return nil
    end
    -- rem-* 的证明块在正文里按"注记"呈现，参与编号；普通证明只折叠不编号
    if kind_of(el.identifier) == "remark" then
      scan_theorem(el)
    else
      state.seq[#state.seq + 1] = { id = el.identifier, kind = "proof" }
    end
    return nil
  end,

  Header = function(header)
    if not state.enabled or #header.identifier == 0 or header.level > state.depth then
      return nil
    end
    state.items[#state.items + 1] = {
      id = header.identifier,
      label = pandoc.utils.stringify(header.content),
    }
    return nil
  end,
}

--------------------------------------------------------------------- 第 3 趟

local function rebuild_theorem(node, info, sub_html)
  local conf = KIND_LABEL[info.kind]
  local can_fold = info.kind ~= "remark"

  local header = '<div class="theorem-header' .. (can_fold and " is-clickable" or "") .. '">'
    .. "<span><strong>" .. conf.full .. " " .. info.number .. "</strong>"
    .. (sub_html ~= "" and (" (" .. sub_html .. ")") or "")
    .. "</span>" .. (can_fold and CHEVRON or "") .. "</div>"

  -- remark 原本由 .proof 渲染，保留这两个类，避免边距/边框样式回退
  local classes = { "theorem", "kind-" .. info.kind }
  if info.kind == "remark" then
    table.insert(classes, 1, "remark")
    table.insert(classes, 1, "proof")
  end

  return pandoc.Div({
    pandoc.RawBlock("html", header),
    pandoc.Div(custom_body(node), pandoc.Attr("", { "theorem-body" })),
  }, pandoc.Attr(info.id, classes))
end

local function rebuild_proof(node)
  local header = '<div class="proof-header"><span><em>Proof.</em></span>' .. CHEVRON .. "</div>"

  return pandoc.Div({
    pandoc.RawBlock("html", header),
    pandoc.Div(custom_body(node), pandoc.Attr("", { "proof-body" })),
  }, pandoc.Attr(node.identifier, { "proof", "is-folded" }))
end

local function process_blocks(blocks, cursor)
  local result = {}

  for _, block in ipairs(blocks) do
    local ctype = block.t == "Div" and block.attributes["__quarto_custom_type"] or nil

    if ctype == "Theorem" or ctype == "Proof" then
      cursor.n = cursor.n + 1
      local info = state.seq[cursor.n]
      if info and info.kind ~= "proof" then
        result[#result + 1] = rebuild_theorem(block, info, block_to_html(info.name))
      else
        result[#result + 1] = rebuild_proof(block)
      end
    elseif block.t == "Div"
      and not SKIP_IDS[block.identifier]
      and not block.classes:includes("hidden") then
      block.content = process_blocks(block.content, cursor)
      result[#result + 1] = block
    else
      result[#result + 1] = block
    end
  end

  return result
end

local pass_build = {
  Pandoc = function(doc)
    if not state.enabled or doc.meta.toc == false then
      return nil   -- 非 HTML 输出，或页面显式关闭了目录
    end

    local cursor = { n = 0 }
    doc.blocks = pandoc.Blocks(process_blocks(doc.blocks, cursor))

    local html = toc_html(state.items)
    if html ~= "" then
      doc.meta["note-toc"] = pandoc.MetaBlocks({ pandoc.RawBlock("html", html) })
      doc.meta["toc-title"] = doc.meta["toc-title"] or pandoc.MetaString("On this page")

      -- 只有"本来不会有目录"的定理页才强制开启（这些页面的标题被吃进定理标题里，
      -- Quarto 生成不出目录）；page-layout: full 没有右侧栏，开启反而会把目录挤进正文。
      local layout = doc.meta["page-layout"] and pandoc.utils.stringify(doc.meta["page-layout"]) or ""
      if state.shells > 0 and layout ~= "full" then
        doc.meta.toc = true
      end
    end

    return doc
  end,
}

return { pass_meta, pass_scan, pass_build }
