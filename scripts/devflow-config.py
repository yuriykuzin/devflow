#!/usr/bin/env python3
"""Devflow config resolver — stdlib only, no PyYAML dependency guaranteed.

Devflow's config files (config.default.yaml, ~/.devflow/config.yaml, project .devflow.yaml)
only ever use a SUBSET of YAML:
  - 2-space block indentation
  - block mappings (`key:` / `key: value`)
  - block sequences, either indented under their key or at the SAME indent as the key
    (`- item`)
  - one-line flow mappings (`{ k: v, k2: v2 }`) and one-line flow lists (`[a, b]`)
  - scalars: quoted strings ('...'/"..."), bare words, ints, floats, and booleans —
    true/false/yes/no/on/off, any case (YAML 1.1) — and null/~
  - a quote character only OPENS a quoted scalar when it is the first non-space character of
    the value (an apostrophe inside a bare word, e.g. `don't`, is never mistaken for one)
  - `#` comments (outside quotes)
This file implements exactly that subset — it is not a general YAML parser. ANY construct
outside it (multi-line flow collections, anchors/aliases, block scalars `|`/`>`, tags, etc.)
is reported as `devflow-config: <path>:<line>: <message>` on stderr and exits 2 — never a
traceback, never partial output.

Subcommands:
  resolve [--project-root <p>] [--global <path>] [--defaults <path>]
      Merge project (.devflow.yaml under --project-root) > global (~/.devflow/config.yaml,
      or --global) > defaults (config.default.yaml next to this script, or --defaults) and
      print the merged config as JSON. Per-key precedence, lists replaced whole. Trusted keys
      (see TRUSTED_PATHS below) found in the project file are dropped before merging, with a
      `WARN ignored untrusted key <k> from .devflow.yaml` line on stderr — including when the
      project file replaces a whole trusted prefix (`roles:`, `review:`) with something that
      isn't a mapping, which would otherwise erase the trusted keys under it instead of just
      failing to set them. Output is buffered and written in one shot at the very end, so a
      failure never leaves a truncated file behind for a caller that redirected stdout.

  fields <path>
      Load a single file (JSON or the YAML subset above, auto-detected), validate it as an
      execution profile (see validate_profile below — an invalid profile prints
      `INVALID_PROFILE <reason>` and exits 6), then print the handful of dotted-path values
      devflow's preflight needs, one `<dotted.path>=<value>` per line: roles.implementer.agent,
      roles.reviewer.agent, roles.reviewer.lens, roles.verifier.agent, review.fallback_to_host,
      _manifest.host. Missing keys default to "" (agents/host/lens) / "false" (fallback).
"""
import json
import os
import sys

SELF_DIR = os.path.dirname(os.path.abspath(__file__))

# Keys a project-level .devflow.yaml can never set (same rule as codex.command_path, which
# predates this resolver and is enforced separately by the runner's own trusted-binary lookup —
# it is listed here too so `resolve`'s merged output honours the identical boundary).
TRUSTED_PATHS = [
    ("codex", "command_path"),
    ("roles", "implementer", "agent"),
    ("roles", "reviewer", "agent"),
    ("roles", "verifier", "agent"),
    ("review", "max_passes"),
    ("review", "fallback_to_host"),
    ("executor_manifest",),
]

# executor_manifest.yaml's own top-level version key (contract: docs/contracts/executor-manifest-v1.md).
EXECUTOR_MANIFEST_SUPPORTED_VERSION = 1


def usage(msg=None):
    if msg:
        print(f"devflow-config: {msg}", file=sys.stderr)
    print(
        "usage: devflow-config.py resolve [--project-root <p>] [--global <path>] [--defaults <path>]\n"
        "       devflow-config.py fields <path>",
        file=sys.stderr,
    )
    raise SystemExit(2)


# ── errors ───────────────────────────────────────────────────────────────────────────────────

class _LineError(ValueError):
    """Raised by the low-level scanners below; carries the 1-based line number within whatever
    single file is currently being parsed. Converted to a DevflowYamlError (which also knows
    the file path) by load_yaml_subset, the only place that has both."""

    def __init__(self, lineno, msg):
        super().__init__(msg)
        self.lineno = lineno
        self.msg = msg


class DevflowYamlError(ValueError):
    """A YAML-subset construct this parser does not support. str(exc) is already the exact
    `<path>:<line>: <msg>` line every caller prints to stderr before exiting 2."""

    def __init__(self, path, lineno, msg):
        super().__init__(f"{path}:{lineno}: {msg}")
        self.path = path
        self.lineno = lineno
        self.msg = msg


# ── the YAML subset parser ──────────────────────────────────────────────────────────────────
#
# `at_value_start` tracks whether the character about to be scanned is the first non-space
# character since the start of the current value (start of line, or just after `:`/`,`/`{`/`[`,
# or just after a block-sequence `-`). A quote character only opens a quoted scalar there — the
# apostrophe bug this fixes: an unquoted value like `don't worry # not a comment` used to have
# its first `'` treated as opening a string, silently swallowing the rest of the line (including
# a real trailing comment, or a real top-level `:`/`,`) until a second `'` that may not exist.

def _strip_comment(line):
    """Cut a line at the first '#' that is not inside a quoted string."""
    out = []
    quote = None
    at_value_start = True
    for ch in line:
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
            continue
        if at_value_start and ch in ("'", '"'):
            quote = ch
            out.append(ch)
            continue
        if ch == "#":
            break
        out.append(ch)
        if ch in (":", ",", "[", "{"):
            at_value_start = True
        elif ch in (" ", "-") and at_value_start:
            pass  # leading spaces / a block-sequence dash don't end "start of value"
        else:
            at_value_start = False
    return "".join(out)


def _split_kv(text):
    """Split 'key: rest' on the first ':' that is not inside quotes/flow braces/brackets."""
    depth = 0
    quote = None
    at_value_start = True
    for i, ch in enumerate(text):
        if quote:
            if ch == quote:
                quote = None
            continue
        if at_value_start and ch in ("'", '"'):
            quote = ch
            continue
        if ch in "{[":
            depth += 1
            at_value_start = True
            continue
        if ch in "}]":
            depth -= 1
            at_value_start = False
            continue
        if ch == ":" and depth == 0:
            key = text[:i].strip()
            rest = text[i + 1 :].strip()
            return key, rest
        if ch == " ":
            continue
        at_value_start = False
    raise ValueError(f"not a 'key: value' line: {text!r}")


# YAML 1.1 booleans, any case — `yes`/`no`/`on`/`off` alongside `true`/`false`.
_BOOL_TRUE = ("true", "yes", "on")
_BOOL_FALSE = ("false", "no", "off")


def _parse_scalar(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ("'", '"'):
        return s[1:-1]
    if s == "":
        return ""
    low = s.lower()
    if low in _BOOL_TRUE:
        return True
    if low in _BOOL_FALSE:
        return False
    if s == "null" or s == "~":
        return None
    try:
        return int(s)
    except ValueError:
        pass
    try:
        return float(s)
    except ValueError:
        pass
    return s


def _split_flow_items(inner):
    """Split the inside of a `{...}`/`[...]` on top-level commas (quotes respected)."""
    items = []
    depth = 0
    quote = None
    at_value_start = True
    cur = []
    for ch in inner:
        if quote:
            cur.append(ch)
            if ch == quote:
                quote = None
            continue
        if at_value_start and ch in ("'", '"'):
            quote = ch
            cur.append(ch)
            continue
        if ch in "{[":
            # This subset supports only ONE level of flow collection (module docstring):
            # a `{`/`[` found while already scanning the inside of one is a nested flow
            # collection, which is out of scope — reject loudly instead of silently
            # degrading the nested value to a string (see docs/contracts/executor-manifest-v1.md).
            raise ValueError(f"nested flow collections are not supported ('{ch}' inside a flow collection)")
        if ch in "}]":
            depth -= 1
            cur.append(ch)
            at_value_start = False
            continue
        if ch == "," and depth == 0:
            items.append("".join(cur))
            cur = []
            at_value_start = True
            continue
        cur.append(ch)
        if ch == ":":
            at_value_start = True
        elif ch != " ":
            at_value_start = False
    if "".join(cur).strip() != "" or cur:
        tail = "".join(cur)
        if tail.strip() != "":
            items.append(tail)
    return [i for i in items if i.strip() != ""]


def _parse_flow_mapping(text):
    assert text.startswith("{") and text.endswith("}")
    result = {}
    for item in _split_flow_items(text[1:-1]):
        key, rest = _split_kv(item)
        result[key] = _parse_scalar(rest)
    return result


def _parse_flow_list(text):
    assert text.startswith("[") and text.endswith("]")
    return [_parse_scalar(i) for i in _split_flow_items(text[1:-1])]


def _parse_value(rest):
    rest = rest.strip()
    if rest.startswith("{") and rest.endswith("}"):
        return _parse_flow_mapping(rest)
    if rest.startswith("[") and rest.endswith("]"):
        return _parse_flow_list(rest)
    return _parse_scalar(rest)


def _tokenize(text):
    """Return [(indent, content, lineno), ...] for every non-blank, non-comment-only line.
    `lineno` is 1-based and matches the SOURCE file, for error messages — blank/comment-only
    lines are dropped so it is not simply the list index."""
    lines = []
    for n, raw in enumerate(text.splitlines(), start=1):
        stripped = _strip_comment(raw).rstrip()
        if stripped.strip() == "":
            continue
        if stripped.strip() in ("---", "..."):
            # Multi-document YAML (a `---`/`...` document marker) is outside this subset —
            # reject loudly rather than silently parsing only the first document.
            raise _LineError(n, "multi-document YAML ('---'/'...' document markers) is not supported")
        indent = len(stripped) - len(stripped.lstrip(" "))
        lines.append((indent, stripped.strip(), n))
    return lines


def _parse_block(lines, i, indent):
    """Parse a block whose items all sit at exactly `indent`. Returns (value, next_i)."""
    if i >= len(lines) or lines[i][0] != indent:
        return {}, i
    if lines[i][1].startswith("- "):
        result = []
        while i < len(lines) and lines[i][0] == indent and lines[i][1].startswith("- "):
            item_text = lines[i][1][2:].strip()
            try:
                result.append(_parse_value(item_text))
            except ValueError as exc:
                raise _LineError(lines[i][2], str(exc)) from exc
            i += 1
        return result, i
    result = {}
    while i < len(lines) and lines[i][0] == indent:
        try:
            key, rest = _split_kv(lines[i][1])
        except ValueError as exc:
            raise _LineError(lines[i][2], str(exc)) from exc
        if rest == "":
            if i + 1 < len(lines) and lines[i + 1][0] > indent:
                value, i = _parse_block(lines, i + 1, lines[i + 1][0])
            elif (
                i + 1 < len(lines)
                and lines[i + 1][0] == indent
                and lines[i + 1][1].startswith("- ")
            ):
                # A block sequence indented at the SAME level as its key, not deeper
                # (`personas:\n- architect`) — equally valid YAML to the indented form.
                value, i = _parse_block(lines, i + 1, indent)
            else:
                value = {}
                i += 1
        else:
            try:
                value = _parse_value(rest)
            except ValueError as exc:
                raise _LineError(lines[i][2], str(exc)) from exc
            i += 1
        result[key] = value
    return result, i


def load_yaml_subset(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    try:
        lines = _tokenize(text)
        if not lines:
            return {}
        value, i = _parse_block(lines, 0, lines[0][0])
        if i != len(lines):
            # _parse_block stopped before consuming every top-level line — e.g. a line
            # mis-indented relative to the block it's meant to belong to. Silently dropping
            # it (the old behaviour) hid real content; report it instead of guessing.
            raise _LineError(lines[i][2], "trailing content after the top-level block")
    except _LineError as exc:
        raise DevflowYamlError(path, exc.lineno, exc.msg) from exc
    except ValueError as exc:
        raise DevflowYamlError(path, lines[0][2], str(exc)) from exc
    return value


def load_any(path):
    """JSON first (devflow-config.py's own `resolve` output, or a hand-written fixture),
    falling back to the YAML subset above."""
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return load_yaml_subset(path)


# ── merge ────────────────────────────────────────────────────────────────────────────────────

def deep_merge(base, override):
    """override wins per-key; nested dicts merge recursively; lists (and everything else)
    are replaced whole — never concatenated."""
    result = dict(base)
    for k, v in override.items():
        if isinstance(v, dict) and isinstance(result.get(k), dict):
            result[k] = deep_merge(result[k], v)
        else:
            result[k] = v
    return result


def filter_trusted(project_cfg):
    """Drop TRUSTED_PATHS from a project-level config, WARNing on stderr for each one found.
    Never mutates the input.

    Design invariant: a project file can never remove or weaken a trusted binding/budget —
    not even by replacing a whole trusted PREFIX (`roles:`, `review:`) with something that
    isn't a mapping at all (a scalar, a list, or an explicit `null`). The naive walk used to
    stop at the first non-dict ancestor and treat that as "not found" (nothing to delete, no
    warning) — but `deep_merge` then replaced the entire prefix wholesale in the merged output,
    silently erasing the trusted keys under it (`roles: junk` wiped roles.*.agent; `review:
    unlimited` wiped review.max_passes/fallback_to_host). So: the first non-dict node found
    along ANY trusted path's prefix is itself untrusted and is deleted (once — deleting it
    removes it for every other TRUSTED_PATHS entry sharing that same prefix, so no duplicate
    WARN)."""
    import copy

    cfg = copy.deepcopy(project_cfg)
    for path in TRUSTED_PATHS:
        node = cfg
        bad_prefix = None
        for depth, key in enumerate(path[:-1]):
            if not isinstance(node, dict) or key not in node:
                bad_prefix = None
                break
            child = node[key]
            if not isinstance(child, dict):
                bad_prefix = path[: depth + 1]
                break
            node = child
        if bad_prefix is not None:
            parent = cfg
            for key in bad_prefix[:-1]:
                parent = parent[key]
            del parent[bad_prefix[-1]]
            print(
                f"WARN ignored untrusted key {'.'.join(bad_prefix)} from .devflow.yaml",
                file=sys.stderr,
            )
            continue
        if isinstance(node, dict) and path[-1] in node:
            del node[path[-1]]
            print(
                f"WARN ignored untrusted key {'.'.join(path)} from .devflow.yaml",
                file=sys.stderr,
            )
    return cfg


def _get_path(cfg, path, default):
    node = cfg
    for key in path:
        if isinstance(node, dict) and key in node:
            node = node[key]
        else:
            return default
    return node


def apply_executor_manifest(merged, manifest_path):
    """Load an executor manifest (docs/contracts/executor-manifest-v1.md) and let it override
    the merged config's `roles`/`review` in place. Prints `ERROR ...` to stderr and returns None
    (caller exits 6) on a missing file or an unsupported major version; otherwise returns the
    updated config with a `_manifest: {path, host, producer}` key added."""
    expanded = os.path.expanduser(manifest_path)
    if not os.path.isabs(expanded):
        # docs/contracts/executor-manifest-v1.md: a relative path resolves against $HOME,
        # not the process cwd.
        expanded = os.path.join(os.path.expanduser("~"), expanded)
    if not os.path.isfile(expanded):
        print(f"ERROR executor_manifest not found {manifest_path}", file=sys.stderr)
        return None
    manifest = load_yaml_subset(expanded)
    version = manifest.get("executor_manifest")
    # isinstance(version, bool) must be checked FIRST: bool is an int subclass in Python, so
    # `True == 1` and a manifest carrying `executor_manifest: true` would otherwise silently
    # pass a check that only compared by value.
    if isinstance(version, bool) or not isinstance(version, int) or version != EXECUTOR_MANIFEST_SUPPORTED_VERSION:
        print(f"ERROR executor_manifest version {version} unsupported", file=sys.stderr)
        return None
    host = manifest.get("host")
    if not host:
        # DECISION-executor-manifest-missing-host: spec names the version/missing-file errors
        # verbatim but not this one; reusing the same "ERROR executor_manifest ..." + exit 6
        # shape (ambiguous wording, safest reversible default) rather than inventing a new code.
        print(f"ERROR executor_manifest missing host {manifest_path}", file=sys.stderr)
        return None

    override = {}
    if "roles" in manifest:
        override["roles"] = manifest["roles"]
    budgets = manifest.get("budgets", {})
    review_override = {}
    if "review_passes" in budgets:
        review_override["max_passes"] = budgets["review_passes"]
    if "fallback_to_host" in budgets:
        review_override["fallback_to_host"] = budgets["fallback_to_host"]
    if review_override:
        override["review"] = review_override

    result = deep_merge(merged, override)
    result["_manifest"] = {
        "path": manifest_path,
        "host": host,
        "producer": manifest.get("producer", ""),
    }
    return result


_KNOWN_ROLES = ("implementer", "reviewer", "verifier")


def _is_strict_int(v):
    """True for a real int, never for a bool (bool is an int subclass in Python: `True == 1`,
    `isinstance(True, int)` — both true — so every check below excludes it explicitly)."""
    return isinstance(v, int) and not isinstance(v, bool)


def validate_profile(cfg):
    """Validate the execution-profile-shaped fields of a resolved config / roles-file. Returns
    None if valid, else a one-line reason for `INVALID_PROFILE <reason>` (caller exits 6).
    Every check is skipped when the key is simply absent — absence is not a profile, only a
    present-but-wrong-shaped value is.

    DECISION-profile-version-validation-scope: the spec's "executor_manifest/profile_version
    not integer 1" bullet names two version-like fields; `executor_manifest`'s OWN int check
    (inside a manifest file) lives in apply_executor_manifest above (it already exits 6 the
    same way). This function validates whichever of the two appears in the roles-file/resolved
    config actually handed to it (a `profile_version: 1` schema tag, or — for a hand-built
    roles-file, as the preflight test fixtures do — an `executor_manifest` value that is
    present but is not a path string, e.g. accidentally `true`)."""
    if "executor_manifest" in cfg and not isinstance(cfg["executor_manifest"], str):
        v = cfg["executor_manifest"]
        if not (_is_strict_int(v) and v == 1):
            return f"executor_manifest={v!r} is not 1"
    if "profile_version" in cfg:
        v = cfg["profile_version"]
        if not (_is_strict_int(v) and v == 1):
            return f"profile_version={v!r} is not 1"

    review = cfg.get("review")
    if isinstance(review, dict):
        if "max_passes" in review:
            v = review["max_passes"]
            if not (_is_strict_int(v) and v >= 0):
                return f"review.max_passes={v!r} is not a non-negative integer"
        if "fallback_to_host" in review:
            v = review["fallback_to_host"]
            if not isinstance(v, bool):
                return f"review.fallback_to_host={v!r} is not true/false"

    roles = cfg.get("roles")
    if roles is not None:
        if not isinstance(roles, dict):
            return f"roles={roles!r} is not a mapping"
        for role_name, role_val in roles.items():
            if role_name not in _KNOWN_ROLES:
                return f"unknown role {role_name!r}"
            if not isinstance(role_val, dict):
                return f"roles.{role_name}={role_val!r} is not a mapping"
            if "agent" in role_val:
                agent = role_val["agent"]
                if not isinstance(agent, str):
                    return f"roles.{role_name}.agent={agent!r} is not a string"
                # DECISION-agent-empty-string-valid: fixwave2_spec.md R8 also lists "agent
                # present but empty/whitespace" as a rejection (done-criteria expects rc 6 for
                # roles: {reviewer: {agent: ""}}), but the task brief for this wave explicitly
                # calls out keeping `agent: ""` valid as the existing "use the default execution
                # path for this role" sentinel (see executor-manifest-v1.md's "Partial manifest"
                # normative case, and cmd_fields' own "" default for a missing agent). Taking the
                # brief's explicit instruction over the spec file's stricter wording here: an
                # empty string stays a valid, meaningful value; only a non-string agent is
                # rejected.
            if "lens" in role_val:
                lens = role_val["lens"]
                if not isinstance(lens, str):
                    return f"roles.{role_name}.lens={lens!r} is not a string"
                # Same reasoning as the agent DECISION just above: config.default.yaml ships
                # `roles.reviewer.lens: ""` as its own shipped default (the "no lens set" form,
                # same convention as `agent: ""`) — rejecting an empty lens would make the
                # shipped default itself an INVALID_PROFILE. Only a wrong-typed lens is rejected.
    return None


# ── subcommands ──────────────────────────────────────────────────────────────────────────────

def cmd_resolve(argv):
    project_root = None
    global_path = None
    defaults_path = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--project-root" and i + 1 < len(argv):
            project_root = argv[i + 1]
            i += 2
        elif a == "--global" and i + 1 < len(argv):
            global_path = argv[i + 1]
            i += 2
        elif a == "--defaults" and i + 1 < len(argv):
            defaults_path = argv[i + 1]
            i += 2
        else:
            usage(f"resolve: unknown or incomplete argument '{a}'")
    project_root = project_root or os.getcwd()
    global_path = global_path or os.path.join(os.path.expanduser("~"), ".devflow", "config.yaml")
    defaults_path = defaults_path or os.path.join(SELF_DIR, "..", "config.default.yaml")

    # Nothing is written to stdout until the single `print(output)` at the very end — a skill
    # redirects stdout straight to resolved-config.json, so any error on any path below (a YAML
    # parse error, an unsupported/missing executor_manifest) must leave that file untouched
    # rather than truncated-then-empty.
    try:
        defaults_cfg = load_yaml_subset(defaults_path) if os.path.isfile(defaults_path) else {}
        global_cfg = load_yaml_subset(global_path) if os.path.isfile(global_path) else {}
        project_file = os.path.join(project_root, ".devflow.yaml")
        project_cfg = load_yaml_subset(project_file) if os.path.isfile(project_file) else {}
    except DevflowYamlError as exc:
        print(f"devflow-config: {exc}", file=sys.stderr)
        return 2

    project_cfg = filter_trusted(project_cfg)

    merged = deep_merge(deep_merge(defaults_cfg, global_cfg), project_cfg)

    manifest_path = merged.get("executor_manifest") or ""
    if manifest_path:
        try:
            merged = apply_executor_manifest(merged, manifest_path)
        except DevflowYamlError as exc:
            print(f"devflow-config: {exc}", file=sys.stderr)
            return 2
        if merged is None:
            return 6

    output = json.dumps(merged, indent=2, sort_keys=True)
    print(output)
    return 0


def cmd_fields(argv):
    if len(argv) != 1:
        usage("fields: requires exactly one <path> argument")
    path = argv[0]
    try:
        cfg = load_any(path)
    except DevflowYamlError as exc:
        print(f"devflow-config: {exc}", file=sys.stderr)
        return 2
    except OSError as exc:
        print(f"devflow-config: {path}: {exc}", file=sys.stderr)
        return 2

    reason = validate_profile(cfg)
    if reason is not None:
        print(f"INVALID_PROFILE {reason}")
        return 6

    fields = [
        (("roles", "implementer", "agent"), ""),
        (("roles", "reviewer", "agent"), ""),
        (("roles", "reviewer", "lens"), ""),
        (("roles", "verifier", "agent"), ""),
        (("review", "fallback_to_host"), False),
        (("_manifest", "host"), ""),
    ]
    for path_tuple, default in fields:
        value = _get_path(cfg, path_tuple, default)
        if isinstance(value, bool):
            value = "true" if value else "false"
        print(f"{'.'.join(path_tuple)}={value}")
    return 0


def main(argv):
    if not argv:
        usage()
    cmd, rest = argv[0], argv[1:]
    if cmd == "resolve":
        return cmd_resolve(rest)
    if cmd == "fields":
        return cmd_fields(rest)
    usage(f"unknown subcommand '{cmd}'")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
