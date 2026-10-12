#!/usr/bin/env python3
"""Generate lenient Swift models from the upstream TypeScript API types.

    python3 scripts/tsgen/gen_models.py <multica-checkout>/packages/core/types \
        Sources/MulticaCore/Generated/UpstreamTypes.swift

Every `export interface` becomes a `public struct` whose field names and JSON
keys match the TypeScript (and therefore the server) exactly. Decoding is
lenient the same way the web client's zod schemas are: a missing or
mistyped field falls back to a default instead of failing the response.

Hand-written core models (Issue, Agent, ...) keep their names; the generated
full-fidelity version of each is emitted as `<Name>Record`, and references
from other generated types point at the hand-written type.
"""
import re
import sys
from pathlib import Path

# Upstream name -> Swift type used when *referenced* from generated code.
HANDWRITTEN_REFS = {
    "Issue": "Issue",
    "Comment": "Comment",
    "Agent": "Agent",
    "AgentTask": "AgentTask",
    "InboxItem": "InboxItem",
    "TimelineEntry": "TimelineEntry",
    "Workspace": "Workspace",
    "User": "User",
    "MemberWithUser": "Member",
    "IssueStatusEntry": "IssueStatusEntry",
    "Reaction": "Reaction",
    "Label": "IssueLabel",
    "RuntimeDevice": "RuntimeDevice",
    "AgentRuntime": "RuntimeDevice",
    "TaskMessagePayload": "TaskMessage",
    "InboxWorkspaceUnread": "InboxWorkspaceUnread",
    "ListIssuesResponse": "ListIssuesResponse",
    "ListIssueStatusesResponse": "ListIssueStatusesResponse",
    "Member": "Member",
    "LoginResponse": "LoginResponse",
}

# Generated under a `Record` suffix (a hand-written type owns the plain name)
# but referenced as the generated type, because the hand-written one has a
# different (narrower) shape.
RENAME_ONLY = {"CreateIssueRequest", "UpdateIssueRequest"}

# Hand-written types that only decode; generated types that would need to
# encode them stay Decodable.
HANDWRITTEN_DECODE_ONLY = {
    "Issue", "Comment", "Agent", "AgentTask", "InboxItem", "TimelineEntry", "Workspace",
    "User", "Member", "IssueStatusEntry", "Reaction", "IssueLabel", "RuntimeDevice",
    "TaskMessage", "InboxWorkspaceUnread", "ListIssuesResponse", "ListIssueStatusesResponse",
}

# Names that would shadow SwiftUI / Foundation / Swift types in app code.
RESERVED_TYPE_NAMES = {
    "Label", "Section", "Group", "Table", "Text", "Image", "Link", "Menu", "Toggle",
    "Picker", "Form", "List", "Gauge", "Grid", "Color", "Font", "Path", "Shape",
    "Window", "Settings", "Scene", "App", "Commands", "Alert", "Button", "Divider",
    "Spacer", "Canvas", "Animation", "Transaction", "Environment", "Binding", "State",
    "Data", "URL", "Date", "Notification", "Operation", "Process", "Timer", "Task",
    "Error", "Result", "Never", "Character", "Range", "Set", "Array", "Dictionary",
    "Bundle", "Locale", "Calendar", "Duration", "Clock", "Tab", "TabView", "Schema",
    "Selection", "Context", "Event", "Field", "Value", "Key", "Message", "Edge",
    "Unit", "Category", "Tool",
}

SWIFT_KEYWORDS = {
    "default", "protocol", "extension", "operator", "repeat", "internal", "public",
    "private", "static", "self", "Self", "Type", "class", "struct", "enum", "func",
    "var", "let", "in", "is", "as", "case", "return", "where", "if", "else", "for",
    "while", "do", "try", "throw", "import", "init", "deinit", "subscript",
    "typealias", "associatedtype", "true", "false", "nil", "super", "inout",
    "switch", "break", "continue", "fallthrough", "guard", "defer", "catch",
    "rethrows", "throws", "fileprivate", "open", "some", "any", "async", "await",
}

INT_HINT = re.compile(
    r"(^|_)(count|counts|total|number|seq|attempt|attempts|size|bytes|tokens|ms|seconds|"
    r"minutes|hours|days|limit|offset|revision|stage|port|index|max|min|version|"
    r"quantity|seats|seat|credits|cents|amount|rank|depth|level|year|month|week|day|hour|"
    r"position_index|frequency|failures|runs|lines|length|priority)($|_)"
)


def strip_comments(src: str) -> str:
    out, i, n = [], 0, len(src)
    in_str = None
    while i < n:
        c = src[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(src[i + 1])
                i += 2
                continue
            if c == in_str:
                in_str = None
            i += 1
            continue
        if c in "\"'`":
            in_str = c
            out.append(c)
            i += 1
            continue
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def match_brace(src: str, start: int, open_c="{", close_c="}") -> int:
    depth = 0
    for i in range(start, len(src)):
        if src[i] == open_c:
            depth += 1
        elif src[i] == close_c:
            depth -= 1
            if depth == 0:
                return i
    raise ValueError("unbalanced")


def split_top(s: str, sep: str):
    """Split on `sep` at nesting depth 0 (braces, brackets, parens, angles)."""
    parts, depth, cur = [], 0, []
    i = 0
    while i < len(s):
        c = s[i]
        if c in "{[(<":
            depth += 1
        elif c in "}])>":
            depth -= 1
        if depth == 0 and s.startswith(sep, i):
            parts.append("".join(cur))
            cur = []
            i += len(sep)
            continue
        cur.append(c)
        i += 1
    parts.append("".join(cur))
    return [p.strip() for p in parts if p.strip()]


class Field:
    def __init__(self, name, ts_type, optional):
        self.name, self.ts_type, self.optional = name, ts_type.strip(), optional


def parse_body(body: str):
    fields = []
    for member in split_top(body, ";"):
        member = member.strip().rstrip(",")
        if not member or member.startswith("[") or "(" in member.split(":")[0]:
            continue  # index signatures, methods
        m = re.match(r"^(readonly\s+)?([A-Za-z_$][\w$]*|\"[^\"]+\")(\?)?\s*:\s*(.+)$", member, re.S)
        if not m:
            continue
        name = m.group(2).strip('"')
        fields.append(Field(name, " ".join(m.group(4).split()), bool(m.group(3))))
    return fields


def parse_file(src: str, interfaces: dict, aliases: dict):
    src = strip_comments(src)
    for m in re.finditer(r"export\s+interface\s+(\w+)(<[^>{]*>)?\s*(extends\s+([^{]+))?\{", src):
        name, generic, ext = m.group(1), m.group(2), m.group(4)
        start = m.end() - 1
        end = match_brace(src, start)
        if generic:
            continue
        interfaces[name] = {"fields": parse_body(src[start + 1:end]), "extends": split_top(ext, ",") if ext else []}
    for m in re.finditer(r"export\s+type\s+(\w+)(<[^=]*>)?\s*=", src):
        name = m.group(1)
        if m.group(2):
            continue
        i = m.end()
        depth = 0
        j = i
        while j < len(src):
            c = src[j]
            if c in "{[(<":
                depth += 1
            elif c in "}])>":
                depth -= 1
            elif c == ";" and depth == 0:
                break
            elif c == "\n" and depth == 0:
                # A type alias ends at a newline unless the next line continues it.
                rest = src[j + 1:].lstrip()
                if not rest.startswith("|") and not rest.startswith("&") and src[i:j].strip() and not src[i:j].strip().endswith(("|", "&", "=", "<", ",")):
                    break
            j += 1
        aliases[name] = " ".join(src[i:j].split())


class Gen:
    def __init__(self, interfaces, aliases):
        self.interfaces = interfaces
        self.aliases = aliases
        self.out_names = {}
        for name in interfaces:
            if name in HANDWRITTEN_REFS or name in RENAME_ONLY:
                self.out_names[name] = name + "Record"
            elif name in RESERVED_TYPE_NAMES:
                self.out_names[name] = "M" + name
            else:
                self.out_names[name] = name
        self.picked = {}

    def ref_name(self, name):
        if name in HANDWRITTEN_REFS:
            return HANDWRITTEN_REFS[name]
        return self.out_names.get(name)

    # ---- type mapping ------------------------------------------------------
    def swift_type(self, ts: str, field_name: str, depth=0):
        """Returns (swift_type, nullable)."""
        ts = ts.strip()
        if depth > 8:
            return ("JSONValue", False)
        while ts.startswith("(") and ts.endswith(")") and match_brace(ts, 0, "(", ")") == len(ts) - 1:
            ts = ts[1:-1].strip()
        if ts.startswith("readonly "):
            ts = ts[len("readonly "):]
        parts = split_top(ts, "|")
        if len(parts) > 1:
            nullable = any(p in ("null", "undefined") for p in parts)
            rest = [p for p in parts if p not in ("null", "undefined")]
            if not rest:
                return ("JSONValue", True)
            if all(self.is_stringy(p) for p in rest):
                return ("String", nullable)
            if all(re.fullmatch(r"-?\d+", p) for p in rest):
                return ("Int", nullable)
            if len(rest) == 1:
                t, n2 = self.swift_type(rest[0], field_name, depth + 1)
                return (t, nullable or n2)
            if all(p in ("true", "false", "boolean") for p in rest):
                return ("Bool", nullable)
            mapped = {self.swift_type(p, field_name, depth + 1)[0] for p in rest}
            if len(mapped) == 1:
                return (mapped.pop(), nullable)
            return ("JSONValue", nullable)
        if ts.endswith("[]"):
            inner, _ = self.swift_type(ts[:-2], field_name, depth + 1)
            return (f"[{inner}]", False)
        m = re.fullmatch(r"(?:Readonly)?Array<(.+)>", ts)
        if m:
            inner, _ = self.swift_type(m.group(1), field_name, depth + 1)
            return (f"[{inner}]", False)
        m = re.fullmatch(r"Record<\s*(.+?)\s*,\s*(.+)>", ts)
        if m:
            val, _ = self.swift_type(m.group(2), field_name, depth + 1)
            if val in ("String", "Int", "Double", "Bool") or val.startswith("["):
                return (f"[String: {val}]", False)
            if val == "JSONValue":
                return ("[String: JSONValue]", False)
            return (f"[String: {val}]", False)
        if ts in ("string",) or self.is_stringy(ts):
            return ("String", False)
        if ts == "number":
            return ("Int" if INT_HINT.search(field_name) else "Double", False)
        if ts == "boolean" or ts in ("true", "false"):
            return ("Bool", False)
        if ts in ("unknown", "any", "object", "never", "{}"):
            return ("JSONValue", False)
        if ts.startswith("{") or ts.startswith("["):
            return ("JSONValue", False)
        m = re.fullmatch(r'import\("[^"]+"\)\.(\w+)', ts)
        if m:
            ts = m.group(1)
        m = re.fullmatch(r"(Partial|Required|Readonly)<(.+)>", ts)
        if m:
            return ("JSONValue", False)
        if ts in self.interfaces:
            return (self.ref_name(ts), False)
        if ts in HANDWRITTEN_REFS:
            return (HANDWRITTEN_REFS[ts], False)
        if ts in self.aliases:
            alias = self.aliases[ts]
            if alias.startswith("Pick<") or alias.startswith("Omit<"):
                return (self.out_names.get(ts, ts), False) if ts in self.picked else ("JSONValue", False)
            return self.swift_type(alias, field_name, depth + 1)
        return ("JSONValue", False)

    def is_stringy(self, p: str):
        p = p.strip()
        if re.fullmatch(r'"[^"]*"|\'[^\']*\'|`[^`]*`', p):
            return True
        if p in ("string", "(string & {})", "string & {}"):
            return True
        if "typeof" in p or "keyof" in p:
            return True
        if p in self.aliases:
            a = self.aliases[p]
            parts = [x for x in split_top(a, "|") if x not in ("null", "undefined")]
            return bool(parts) and all(self.is_stringy(x) for x in parts if x != p)
        return False

    # ---- field resolution with extends ---------------------------------------
    def resolve_fields(self, name, seen=None):
        seen = seen or set()
        if name in seen:
            return []
        seen.add(name)
        if name in self.interfaces:
            info = self.interfaces[name]
            fields = []
            for base in info["extends"]:
                fields += self.resolve_utility(base, seen)
            own = {f.name for f in info["fields"]}
            fields = [f for f in fields if f.name not in own] + info["fields"]
            return fields
        if name in self.aliases:
            return self.resolve_utility(self.aliases[name], seen)
        return []

    def resolve_utility(self, expr, seen):
        expr = expr.strip()
        m = re.fullmatch(r"(Pick|Omit)<\s*(\w+)\s*,\s*(.+)>", expr, re.S)
        if m:
            kind, base, keys = m.groups()
            keyset = set(re.findall(r'"([^"]+)"', keys))
            fields = self.resolve_fields(base, set(seen))
            if kind == "Pick":
                return [f for f in fields if f.name in keyset]
            return [f for f in fields if f.name not in keyset]
        m = re.fullmatch(r"Partial<\s*(\w+)\s*>", expr)
        if m:
            return [Field(f.name, f.ts_type, True) for f in self.resolve_fields(m.group(1), set(seen))]
        if re.fullmatch(r"\w+", expr):
            return self.resolve_fields(expr, set(seen))
        return []

    # ---- emit --------------------------------------------------------------
    @staticmethod
    def camel(name):
        parts = name.split("_")
        s = parts[0] + "".join(p[:1].upper() + p[1:] for p in parts[1:])
        s = re.sub(r"[^\w]", "_", s)
        if s and s[0].isdigit():
            s = "_" + s
        return f"`{s}`" if s in SWIFT_KEYWORDS else s

    def default_for(self, t):
        if t == "String":
            return '""'
        if t in ("Int", "Double"):
            return "0"
        if t == "Bool":
            return "false"
        if t.startswith("[") and ":" in t:
            return "[:]"
        if t.startswith("["):
            return "[]"
        if t == "JSONValue":
            return ".null"
        return None

    def emit_struct(self, name, out_name):
        fields = self.resolve_fields(name)
        seen, uniq = set(), []
        for f in fields:
            if f.name not in seen:
                seen.add(f.name)
                uniq.append(f)
        is_request = out_name.endswith("Request")
        lines = []
        props, inits, decs, encs, params, assigns, keys = [], [], [], [], [], [], []
        has_id = False
        for f in uniq:
            t, nullable = self.swift_type(f.ts_type, f.name)
            sname = self.camel(f.name)
            plain = sname.strip("`")
            keys.append(f'        case {sname} = "{f.name}"' if plain != f.name else f"        case {sname}")
            default = self.default_for(t)
            optional = nullable or f.optional or default is None
            if f.name == "id" and t == "String" and not f.optional and not nullable:
                has_id = True
                props.append(f"    public var id: String")
                decs.append(f'        id = (try? c.decode(String.self, forKey: .id)) ?? ""')
                params.append("id: String = \"\"")
                assigns.append("        self.id = id")
                encs.append("        try c.encode(id, forKey: .id)")
                continue
            if optional and default is not None and not (nullable or f.optional):
                optional = False
            is_array = t.startswith("[") and ":" not in t
            elem = t[1:-1] if is_array else None
            if optional:
                props.append(f"    public var {sname}: {t}?")
                if is_array:
                    decs.append(f"        {sname} = c.contains(.{plain}) ? c.lossyArray({elem}.self, .{plain}) : nil")
                else:
                    decs.append(f"        {sname} = c.lenient({t}.self, .{plain})")
                params.append(f"{sname}: {t}? = nil")
                encs.append(f"        try c.encodeIfPresent({sname}, forKey: .{plain})")
            else:
                props.append(f"    public var {sname}: {t}")
                if is_array:
                    decs.append(f"        {sname} = c.lossyArray({elem}.self, .{plain})")
                elif default is None:
                    decs.append(f"        {sname} = try c.decode({t}.self, forKey: .{plain})")
                else:
                    decs.append(f"        {sname} = c.lenient({t}.self, .{plain}) ?? {default}")
                params.append(f"{sname}: {t} = {default}")
                encs.append(f"        try c.encode({sname}, forKey: .{plain})")
            assigns.append(f"        self.{sname} = {sname}")
        encodable = out_name in self.encodable
        conformances = "Sendable, Hashable, " + ("Codable" if encodable else "Decodable") + (", Identifiable" if has_id else "")
        lines.append(f"/// `{name}` in packages/core/types.")
        lines.append(f"public struct {out_name}: {conformances} {{")
        lines += props
        if uniq:
            lines.append("")
            lines.append("    enum CodingKeys: String, CodingKey {")
            lines += keys
            lines.append("    }")
        lines.append("")
        lines.append(f"    public init({', '.join(params)}) {{")
        lines += assigns
        lines.append("    }")
        lines.append("")
        lines.append("    public init(from decoder: Decoder) throws {")
        if uniq:
            lines.append("        let c = try decoder.container(keyedBy: CodingKeys.self)")
            lines += decs
        lines.append("    }")
        if encodable:
            lines.append("")
            lines.append("    public func encode(to encoder: Encoder) throws {")
            if uniq:
                lines.append("        var c = encoder.container(keyedBy: CodingKeys.self)")
                lines += encs
            lines.append("    }")
        lines.append("}")
        return "\n".join(lines)

    def referenced_types(self, name):
        out = set()
        for f in self.resolve_fields(name):
            t, _ = self.swift_type(f.ts_type, f.name)
            for tok in re.findall(r"[A-Za-z_]\w*", t):
                out.add(tok)
        return out

    def compute_encodable(self):
        by_out = {self.out_names[n]: n for n in list(self.interfaces) + list(self.picked)}
        roots = [o for o, n in by_out.items() if re.search(r"(Request|Input|Params|Body|Payload)$", n) and not n.endswith("EventPayload")]
        enc, stack = set(), list(roots)
        while stack:
            o = stack.pop()
            if o in enc:
                continue
            enc.add(o)
            for tok in self.referenced_types(by_out[o]):
                if tok in by_out and tok not in enc:
                    stack.append(tok)
        # Drop anything that (transitively) needs a decode-only hand-written type.
        changed = True
        while changed:
            changed = False
            for o in list(enc):
                refs = self.referenced_types(by_out[o])
                if refs & HANDWRITTEN_DECODE_ONLY or any(r in by_out and r not in enc for r in refs):
                    enc.discard(o)
                    changed = True
        self.encodable = enc

    def run(self):
        chunks = [
            "// Generated by scripts/tsgen/gen_models.py from upstream packages/core/types.",
            "// Do not edit by hand; re-run the generator instead.",
            "// swiftlint:disable all",
            "import Foundation",
            "",
        ]
        # Pick/Omit aliases become structs too.
        for name, alias in sorted(self.aliases.items()):
            if re.match(r"(Pick|Omit)<\s*\w+\s*,", alias) and name not in self.interfaces:
                self.picked[name] = True
                self.out_names[name] = "M" + name if name in RESERVED_TYPE_NAMES else name
        self.compute_encodable()
        for name in sorted(self.interfaces) + sorted(self.picked):
            out = self.out_names[name]
            chunks.append(self.emit_struct(name, out))
            chunks.append("")
        return "\n".join(chunks)


def main():
    src_dir, out = Path(sys.argv[1]), Path(sys.argv[2])
    interfaces, aliases = {}, {}
    for p in sorted(src_dir.glob("*.ts")):
        if p.name.endswith(".test.ts"):
            continue
        parse_file(p.read_text(), interfaces, aliases)
    for extra in sys.argv[3:]:
        parse_file(Path(extra).read_text(), interfaces, aliases)
    gen = Gen(interfaces, aliases)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(gen.run())
    print(f"{len(interfaces)} interfaces, {len(gen.picked)} picked aliases -> {out}")


if __name__ == "__main__":
    main()
