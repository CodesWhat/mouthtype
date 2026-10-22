// Turns GitHub-flavored Markdown conventions into fumadocs components. fumadocs-mdx compiles
// .md files in "md" format: no JSX, and raw HTML is stripped. So the sources stay plain
// Markdown that reads fine on GitHub, and this plugin upgrades the constructs on the site:
//   > [!NOTE] / [!TIP] / [!IMPORTANT] / [!WARNING] / [!CAUTION]  -> <Callout>
//   <kbd>Fn</kbd>                                                -> <kbd>
//   <details><summary>Title</summary> ... </details>             -> <details>
//   <!-- docs:cards --> followed by a list of "[Title](href) text" -> <Cards>
const ALERTS = {
  NOTE: { type: "info", title: "Note" },
  TIP: { type: "idea", title: "Tip" },
  IMPORTANT: { type: "warning", title: "Important" },
  WARNING: { type: "warning", title: "Warning" },
  CAUTION: { type: "error", title: "Caution" },
};

const jsx = (name, attrs, children) => ({
  type: "mdxJsxFlowElement",
  name,
  attributes: Object.entries(attrs).map(([k, value]) => ({
    type: "mdxJsxAttribute",
    name: k,
    value,
  })),
  children,
});

function alertOf(node) {
  if (node.type !== "blockquote") return null;
  const p = node.children[0];
  const t = p?.type === "paragraph" ? p.children[0] : null;
  if (t?.type !== "text") return null;
  const m = /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\][ \t]*\n?/i.exec(t.value);
  if (!m) return null;
  const spec = ALERTS[m[1].toUpperCase()];
  t.value = t.value.slice(m[0].length);
  if (!t.value) p.children.shift();
  if (p.children.length === 0) node.children.shift();
  return jsx("Callout", { type: spec.type, title: spec.title }, node.children);
}

// <kbd>Fn</kbd> arrives as html("<kbd>"), text("Fn"), html("</kbd>") siblings.
function inlineKbd(children) {
  const out = [];
  for (let i = 0; i < children.length; i++) {
    const c = children[i];
    const close = children.findIndex((n, j) => j > i && n.type === "html" && n.value === "</kbd>");
    if (c.type === "html" && c.value === "<kbd>" && close !== -1) {
      out.push({
        type: "emphasis",
        data: { hName: "kbd" },
        children: children.slice(i + 1, close),
      });
      i = close;
    } else {
      out.push(c);
    }
  }
  return out;
}

function detailsOf(children, start) {
  const open = /^<details(\s+open)?>\s*<summary>([\s\S]*?)<\/summary>\s*$/.exec(
    children[start].type === "html" ? children[start].value : "",
  );
  if (!open) return null;
  const end = children.findIndex(
    (n, j) => j > start && n.type === "html" && n.value.trim() === "</details>",
  );
  if (end === -1) return null;
  const summary = {
    type: "mdxJsxFlowElement",
    name: "summary",
    attributes: [],
    children: [{ type: "text", value: open[2] }],
  };
  const attrs = open[1] ? { open: null } : {};
  return { node: jsx("details", attrs, [summary, ...children.slice(start + 1, end)]), end };
}

function cardsOf(list) {
  if (list?.type !== "list") return null;
  const cards = [];
  for (const item of list.children) {
    const p = item.children[0];
    const link = p?.children?.find((n) => n.type === "link");
    if (!link) return null;
    const rest = p.children
      .filter((n) => n !== link)
      .map((n) => n.value ?? "")
      .join("")
      .replace(/^[\s:\u2013-]+/, "")
      .trim();
    cards.push(
      jsx(
        "Card",
        {
          title: link.children.map((n) => n.value ?? "").join(""),
          href: link.url,
          ...(rest ? { description: rest } : {}),
        },
        [],
      ),
    );
  }
  return jsx("Cards", {}, cards);
}

function transform(children) {
  const out = [];
  for (let i = 0; i < children.length; i++) {
    let c = children[i];
    if (c.type === "html" && c.value.trim() === "<!-- docs:cards -->") {
      const cards = cardsOf(children[i + 1]);
      if (cards) {
        out.push(cards);
        i++;
        continue;
      }
    }
    if (c.type === "html") {
      const d = detailsOf(children, i);
      if (d) {
        out.push(d.node);
        i = d.end;
        continue;
      }
    }
    c = alertOf(c) ?? c;
    out.push(c);
  }
  return out;
}

function walk(node) {
  if (!node.children) return;
  node.children =
    node.type === "paragraph" || node.type === "heading" || node.type === "tableCell"
      ? inlineKbd(node.children)
      : transform(node.children);
  for (const c of node.children) walk(c);
}

export default function remarkDocsBlocks() {
  return (tree) => walk(tree);
}
