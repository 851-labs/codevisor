#!/usr/bin/env python3
"""Long-lived Codevisor Computer Use helper for Ubuntu GNOME.

The protocol is newline-delimited JSON over stdin/stdout. Accessibility
inspection and semantic actions use AT-SPI2, which works under both X11 and
Wayland. Screenshots and synthesized pointer/key events are best-effort under
Wayland because compositors intentionally restrict those capabilities.

The AT-SPI and desktop-session recovery approach is derived from
open-codex-computer-use (MIT), commit 460d281c0597ab83e703d0215affd9d89978c506.
"""

import base64
import json
import math
import os
import subprocess
import sys
import time
import traceback
import uuid


MAX_ELEMENTS = 1200
MAX_DEPTH = 64
TEXT_LIMIT = 500
SNAPSHOTS_PER_SESSION = 8


def recover_desktop_environment():
    uid = os.getuid()
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR") or "/run/user/{}".format(uid)
    if os.path.isdir(runtime_dir):
        os.environ.setdefault("XDG_RUNTIME_DIR", runtime_dir)
        bus = os.path.join(runtime_dir, "bus")
        if os.path.exists(bus):
            os.environ.setdefault("DBUS_SESSION_BUS_ADDRESS", "unix:path=" + bus)

    needed = {"DISPLAY", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS"}
    if all(os.environ.get(key) for key in needed):
        return
    candidates = []
    proc = "/proc"
    if not os.path.isdir(proc):
        return
    for entry in os.listdir(proc):
        if not entry.isdigit():
            continue
        try:
            stat = os.stat(os.path.join(proc, entry))
            if stat.st_uid != uid:
                continue
            command = open(
                os.path.join(proc, entry, "comm"), "r", encoding="utf-8"
            ).read().strip().lower()
            if not any(
                marker in command
                for marker in ("gnome-shell", "gnome-session", "systemd", "dbus")
            ):
                continue
            raw = open(os.path.join(proc, entry, "environ"), "rb").read()
            values = {}
            for item in raw.split(b"\0"):
                if b"=" not in item:
                    continue
                key, value = item.split(b"=", 1)
                values[key.decode("utf-8", "ignore")] = value.decode(
                    "utf-8", "ignore"
                )
            candidates.append(values)
        except (OSError, UnicodeError):
            continue
    for key in needed:
        if os.environ.get(key):
            continue
        for values in candidates:
            if values.get(key):
                os.environ[key] = values[key]
                break


recover_desktop_environment()

try:
    import gi

    gi.require_version("Atspi", "2.0")
    gi.require_version("Gio", "2.0")
    from gi.repository import Atspi, Gio

    try:
        gi.require_version("Gdk", "3.0")
        from gi.repository import Gdk
    except (ImportError, ValueError):
        Gdk = None
except Exception as exc:
    sys.stderr.write(
        "Computer Use requires python3-gi, gir1.2-atspi-2.0, and "
        "gir1.2-gtk-3.0: {}\n".format(exc)
    )
    sys.exit(2)


def safe(call, fallback=None):
    try:
        value = call()
        return fallback if value is None else value
    except Exception:
        return fallback


def child_count(node):
    return int(safe(node.get_child_count, 0) or 0)


def child(node, index):
    return safe(lambda: node.get_child_at_index(index))


def node_name(node):
    return str(safe(node.get_name, "") or "")


def node_role(node):
    return str(safe(node.get_role_name, "") or "")


def node_pid(node):
    return int(safe(node.get_process_id, 0) or 0)


def state(node, value):
    states = safe(node.get_state_set)
    return states is not None and bool(safe(lambda: states.contains(value), False))


def bounds(node):
    component = safe(node.get_component_iface)
    if component is None:
        return None
    rect = safe(lambda: Atspi.Component.get_extents(component, Atspi.CoordType.SCREEN))
    if (
        rect is None
        or rect.width <= 0
        or rect.height <= 0
        or rect.width > 100000
        or rect.height > 100000
    ):
        return None
    return {
        "x": float(rect.x),
        "y": float(rect.y),
        "width": float(rect.width),
        "height": float(rect.height),
    }


def desktop_apps():
    root = Atspi.get_desktop(0)
    return [child(root, index) for index in range(child_count(root)) if child(root, index)]


def app_windows(app):
    result = []
    for index in range(child_count(app)):
        item = child(app, index)
        if item is not None and (
            node_role(item).lower() in {"frame", "window", "dialog", "alert"}
            or bounds(item) is not None
        ):
            result.append((index, item))
    return result


def running_app_names(app):
    return [node_name(app)] + [node_name(window) for _, window in app_windows(app)]


def running_app_match_score(query, app):
    normalized = str(query or "").strip().lower()
    if not normalized:
        return None
    if normalized.isdigit() and node_pid(app) == int(normalized):
        return 0
    names = [name.lower() for name in running_app_names(app) if name]
    if normalized in names:
        return 0
    if any(normalized in name for name in names):
        return 1
    return None


def resolve_running_app(query):
    matches = []
    for app in desktop_apps():
        score = running_app_match_score(query, app)
        if score == 0:
            return require_unprotected_app(app)
        if score == 1:
            matches.append(app)
    if len(matches) == 1:
        return require_unprotected_app(matches[0])
    if len(matches) > 1:
        raise RuntimeError("App name is ambiguous; use its PID or exact name")
    return None


def installed_apps():
    result = []
    for info in safe(Gio.AppInfo.get_all, []) or []:
        try:
            if hasattr(info, "should_show") and not info.should_show():
                continue
            display_name = str(info.get_display_name() or info.get_name() or "").strip()
            executable = str(info.get_executable() or "").strip()
            app_id = str(info.get_id() or executable or display_name).strip()
            if not app_id or not display_name:
                continue
            result.append(
                {
                    "id": app_id,
                    "displayName": display_name,
                    "executable": executable,
                    "info": info,
                }
            )
        except Exception:
            continue
    deduplicated = {}
    for app in result:
        deduplicated[app["id"].lower()] = app
    return sorted(
        deduplicated.values(), key=lambda item: (item["displayName"].lower(), item["id"])
    )


def installed_app_match_score(query, app):
    normalized = str(query or "").strip().lower()
    expanded = os.path.expanduser(str(query or "")).lower()
    executable = str(app.get("executable") or "")
    exact = {
        str(app.get("id") or "").lower(),
        str(app.get("displayName") or "").lower(),
        executable.lower(),
        os.path.basename(executable).lower(),
    }
    app_id = str(app.get("id") or "").lower()
    if app_id.endswith(".desktop"):
        exact.add(app_id[: -len(".desktop")])
    if normalized in exact or expanded in exact:
        return 0
    return 1 if normalized and normalized in str(app.get("displayName") or "").lower() else None


def require_unprotected_identity(*values):
    normalized = " ".join(str(value or "") for value in values).lower().replace(" ", "")
    protected = (
        "codevisor",
        "1password",
        "bitwarden",
        "lastpass",
        "dashlane",
        "keeper",
        "keychainaccess",
        "passwords",
    )
    if any(name in normalized for name in protected):
        raise RuntimeError("That app is protected and cannot be controlled by Computer Use")


def launch_installed_app(app):
    require_unprotected_identity(app.get("id"), app.get("displayName"), app.get("executable"))
    before = {(node_pid(candidate), node_name(candidate)) for candidate in desktop_apps()}
    info = app.get("info")
    if info is not None:
        if not bool(info.launch([], None)):
            raise RuntimeError("Unable to launch " + app["displayName"])
    else:
        executable = str(app.get("executable") or "")
        if not executable:
            raise RuntimeError("Unable to launch " + app["displayName"])
        subprocess.Popen(
            [executable],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    for _ in range(100):
        running = resolve_running_app(app["displayName"])
        if running is None and app.get("executable"):
            running = resolve_running_app(os.path.basename(app["executable"]))
        if running is not None:
            return running
        new_apps = [
            candidate
            for candidate in desktop_apps()
            if (node_pid(candidate), node_name(candidate)) not in before
        ]
        if len(new_apps) == 1:
            return require_unprotected_app(new_apps[0])
        time.sleep(0.1)
    raise RuntimeError(app["displayName"] + " launched without an accessible window")


def resolve_app(query):
    running = resolve_running_app(query)
    if running is not None:
        return running
    normalized = str(query or "").strip()
    expanded = os.path.expanduser(normalized)
    candidates = installed_apps()
    if os.path.isabs(expanded) and os.path.isfile(expanded) and os.access(expanded, os.X_OK):
        candidates.insert(
            0,
            {
                "id": expanded,
                "displayName": os.path.basename(expanded),
                "executable": expanded,
                "info": None,
            },
        )
    matches = [
        (app, installed_app_match_score(normalized, app))
        for app in candidates
        if installed_app_match_score(normalized, app) is not None
    ]
    exact = [app for app, score in matches if score == 0]
    if exact:
        return launch_installed_app(exact[0])
    fuzzy = [app for app, score in matches if score == 1]
    if len(fuzzy) == 1:
        return launch_installed_app(fuzzy[0])
    if len(fuzzy) > 1:
        raise RuntimeError("App name is ambiguous; use its application id or exact name")
    raise RuntimeError('App not found: "{}"'.format(query))


def require_unprotected_app(app):
    require_unprotected_identity(node_name(app))
    return app


def main_window(app):
    windows = app_windows(app)
    if not windows:
        raise RuntimeError("No accessible window is available for " + node_name(app))
    for index, window in windows:
        if state(window, Atspi.StateType.ACTIVE):
            return index, window
    for index, window in windows:
        if state(window, Atspi.StateType.SHOWING):
            return index, window
    return windows[0]


def action_names(node):
    result = []
    for index in range(int(safe(node.get_n_actions, 0) or 0)):
        name = str(safe(lambda index=index: node.get_action_name(index), "") or "")
        if name and name not in result:
            result.append(name)
    return result


def element_value(node):
    role = node_role(node).lower()
    if "password" in role:
        return "<redacted>"
    interface = safe(node.get_text_iface)
    if interface is not None:
        length = int(
            safe(lambda: Atspi.Text.get_character_count(interface), 0) or 0
        )
        if length > 0:
            value = str(
                safe(lambda: Atspi.Text.get_text(interface, 0, min(length, TEXT_LIMIT + 1)), "")
                or ""
            )
            return value[:TEXT_LIMIT] + ("…" if len(value) > TEXT_LIMIT else "")
    interface = safe(node.get_value_iface)
    if interface is not None:
        value = safe(lambda: Atspi.Value.get_current_value(interface))
        if value is not None:
            return str(value)
    return ""


def relative_bounds(node, window_bounds):
    value = bounds(node)
    if value is None or window_bounds is None:
        return value
    return {
        "x": value["x"] - window_bounds["x"],
        "y": value["y"] - window_bounds["y"],
        "width": value["width"],
        "height": value["height"],
    }


def snapshot_tree(window, window_bounds, window_index):
    records = []
    lines = []

    def visit(node, depth, path):
        if node is None or depth > MAX_DEPTH or len(records) >= MAX_ELEMENTS:
            return
        element_id = str(len(records))
        role = node_role(node) or "element"
        name = node_name(node)[:TEXT_LIMIT]
        value = element_value(node)
        record = {
            "elementId": element_id,
            "path": path,
            "role": role,
            "name": name,
            "value": value,
            "frame": relative_bounds(node, window_bounds),
            "actions": action_names(node),
        }
        records.append(record)
        extras = []
        if value and value != name:
            extras.append("Value: " + value.replace("\n", "\\n"))
        if record["actions"]:
            extras.append("Actions: " + ", ".join(record["actions"]))
        if record["frame"]:
            extras.append("Frame: " + json.dumps(record["frame"], separators=(",", ":")))
        lines.append(
            "\t" * (depth + 1)
            + "{} {} {}{}".format(
                element_id,
                role,
                name,
                " " + " ".join(extras) if extras else "",
            ).rstrip()
        )
        for index in range(child_count(node)):
            visit(child(node, index), depth + 1, path + [index])

    visit(window, 0, [window_index])
    return records, lines


def capture_png(window_bounds):
    if Gdk is None or window_bounds is None:
        return None
    try:
        screen = Gdk.Screen.get_default()
        root = screen.get_root_window() if screen else None
        if root is None:
            return None
        image = Gdk.pixbuf_get_from_window(
            root,
            int(window_bounds["x"]),
            int(window_bounds["y"]),
            max(1, int(window_bounds["width"])),
            max(1, int(window_bounds["height"])),
        )
        if image is None:
            return None
        ok, data = image.save_to_bufferv("png", [], [])
        return base64.b64encode(bytes(data)).decode("ascii") if ok else None
    except Exception:
        return None


snapshots = {}


def save_snapshot(session_id, app_query, action=None):
    app = resolve_app(app_query)
    window_index, window = main_window(app)
    window_bounds = bounds(window)
    elements, lines = snapshot_tree(window, window_bounds, window_index)
    snapshot_id = str(uuid.uuid4())
    record = {
        "snapshotId": snapshot_id,
        "app": app_query,
        "elements": elements,
        "windowBounds": window_bounds,
    }
    session = snapshots.setdefault(session_id, [])
    session.append(record)
    del session[:-SNAPSHOTS_PER_SESSION]
    screenshot = capture_png(window_bounds)
    metadata = {
        "snapshotId": snapshot_id,
        "app": {
            "name": node_name(app),
            "pid": node_pid(app),
        },
        "windowTitle": node_name(window),
        "windowBounds": (
            {
                "x": 0,
                "y": 0,
                "width": window_bounds["width"],
                "height": window_bounds["height"],
            }
            if window_bounds
            else None
        ),
        "screenWindowBounds": window_bounds,
        "screenshot": "available" if screenshot else "unavailable-under-current-display-server",
        "accessibilityTree": "\n".join(lines),
    }
    if action is not None:
        metadata["action"] = action
    content = [{"type": "text", "text": json.dumps(metadata, separators=(",", ":"))}]
    if screenshot:
        content.append({"type": "image", "mimeType": "image/png", "data": screenshot})
    return {"content": content}


def stored_element(session_id, snapshot_id, element_id):
    for snapshot in reversed(snapshots.get(session_id, [])):
        if snapshot["snapshotId"] != snapshot_id:
            continue
        try:
            return snapshot, snapshot["elements"][int(element_id)]
        except (IndexError, TypeError, ValueError):
            break
    raise RuntimeError("Unknown or expired snapshot/element id; call get_app_state again")


def live_element(app, record):
    node = app
    for index in record["path"]:
        node = child(node, int(index))
        if node is None:
            raise RuntimeError("The accessibility element no longer exists; refresh app state")
    return node


def preferred_action(node):
    fallback = None
    for index in range(int(safe(node.get_n_actions, 0) or 0)):
        name = str(safe(lambda index=index: node.get_action_name(index), "") or "").lower()
        if name in {"click", "press", "activate", "invoke", "select", "toggle", "open"}:
            return index
        if fallback is None and any(word in name for word in ("click", "press", "activate")):
            fallback = index
    return fallback


def do_action(node, index):
    return index is not None and bool(safe(lambda: node.do_action(index), False))


def screen_point(window_bounds, record=None, x=None, y=None):
    if record and record.get("frame"):
        frame = record["frame"]
        return (
            window_bounds["x"] + frame["x"] + frame["width"] / 2,
            window_bounds["y"] + frame["y"] + frame["height"] / 2,
        )
    if window_bounds is None or x is None or y is None:
        raise RuntimeError("A current element id or window-relative x/y coordinates are required")
    return window_bounds["x"] + float(x), window_bounds["y"] + float(y)


def click_at(x, y, button="left", count=1):
    number = {"left": 1, "middle": 2, "right": 3}.get(str(button).lower(), 1)
    for _ in range(max(1, int(count or 1))):
        Atspi.generate_mouse_event(round(x), round(y), "abs")
        Atspi.generate_mouse_event(round(x), round(y), "b{}c".format(number))
        time.sleep(0.05)


KEY_NAMES = {
    "enter": "Return",
    "return": "Return",
    "esc": "Escape",
    "escape": "Escape",
    "backspace": "BackSpace",
    "pageup": "Page_Up",
    "pagedown": "Page_Down",
}


def key_value(name):
    normalized = KEY_NAMES.get(name.lower(), name)
    value = Gdk.keyval_from_name(normalized) if Gdk is not None else 0
    if value:
        return int(value)
    if len(normalized) == 1:
        return ord(normalized)
    raise RuntimeError("Unsupported key: " + name)


def press_key(key):
    parts = [part for part in str(key).replace("-", "+").split("+") if part]
    modifiers = {
        "ctrl": "Control_L",
        "control": "Control_L",
        "shift": "Shift_L",
        "alt": "Alt_L",
        "super": "Super_L",
        "cmd": "Super_L",
    }
    held = []
    for modifier in parts[:-1]:
        if modifier.lower() in modifiers:
            value = key_value(modifiers[modifier.lower()])
            Atspi.generate_keyboard_event(value, None, Atspi.KeySynthType.PRESS)
            held.append(value)
    main = KEY_NAMES.get(parts[-1].lower(), parts[-1])
    if len(main) == 1:
        Atspi.generate_keyboard_event(0, main, Atspi.KeySynthType.STRING)
    else:
        Atspi.generate_keyboard_event(key_value(main), None, Atspi.KeySynthType.PRESSRELEASE)
    for value in reversed(held):
        Atspi.generate_keyboard_event(value, None, Atspi.KeySynthType.RELEASE)


def type_keyboard_text(value):
    chunk = []

    def flush():
        if chunk:
            Atspi.generate_keyboard_event(
                0, "".join(chunk), Atspi.KeySynthType.STRING
            )
            chunk.clear()

    for character in str(value):
        if character in ("\n", "\r"):
            flush()
            press_key("Return")
        elif character == "\t":
            flush()
            press_key("Tab")
        elif character in ("\b", "\x7f"):
            flush()
            press_key("BackSpace")
        else:
            chunk.append(character)
    flush()


def text_selection_range(node, args):
    interface = safe(node.get_text_iface) if node is not None else None
    if interface is None:
        raise RuntimeError("The element does not expose selectable text")
    length = int(safe(lambda: Atspi.Text.get_character_count(interface), 0) or 0)
    value = str(safe(lambda: Atspi.Text.get_text(interface, 0, length), "") or "")
    if args.get("all") is True:
        start, end = 0, len(value)
    elif args.get("text") is not None:
        needle = str(args.get("text"))
        prefix = args.get("prefix")
        suffix = args.get("suffix")
        matches = []
        offset = 0
        while offset <= len(value):
            found = value.find(needle, offset)
            if found < 0:
                break
            before_ok = prefix is None or value[:found].endswith(str(prefix))
            after = found + len(needle)
            after_ok = suffix is None or value[after:].startswith(str(suffix))
            if before_ok and after_ok:
                matches.append((found, after))
            offset = found + max(len(needle), 1)
        if not matches:
            raise RuntimeError("The requested text was not found in the element value")
        if len(matches) != 1:
            raise RuntimeError(
                "The requested text occurs more than once; add prefix or suffix context"
            )
        start, end = matches[0]
    elif args.get("start") is not None and args.get("length") is not None:
        start = int(args.get("start"))
        end = start + int(args.get("length"))
    else:
        raise RuntimeError("select_text requires all, text, or both start and length")
    if start < 0 or end < start or end > len(value):
        raise RuntimeError("The requested selection range is outside the editable value")
    selection_type = str(args.get("selectionType") or args.get("selection_type") or "range")
    if selection_type == "cursor_before":
        end = start
    elif selection_type == "cursor_after":
        start = end
    elif selection_type != "range":
        raise RuntimeError("selectionType must be range, cursor_before, or cursor_after")
    return interface, start, end


def set_text(node, value, replace):
    editable = safe(node.get_editable_text_iface) if node is not None else None
    if editable is None:
        return False
    if replace:
        return bool(safe(lambda: Atspi.EditableText.set_text_contents(editable, str(value)), False))
    text = safe(node.get_text_iface)
    offset = int(safe(lambda: Atspi.Text.get_character_count(text), 0) or 0)
    return bool(
        safe(
            lambda: Atspi.EditableText.insert_text(editable, offset, str(value), len(str(value))),
            False,
        )
    )


def list_apps_result():
    running = desktop_apps()
    apps = []
    seen = set()
    for installed in installed_apps():
        app_id = installed["id"]
        seen.add(app_id.lower())
        apps.append(
            {
                "id": app_id,
                "displayName": installed["displayName"],
                "isRunning": any(
                    running_app_match_score(installed["displayName"], app) == 0
                    or running_app_match_score(installed["executable"], app) == 0
                    for app in running
                ),
            }
        )
    for app in running:
        app_id = node_name(app) or str(node_pid(app))
        if app_id.lower() in seen:
            continue
        seen.add(app_id.lower())
        apps.append(
            {"id": app_id, "displayName": node_name(app) or app_id, "isRunning": True}
        )
    apps.sort(key=lambda item: (item["displayName"].lower(), item["id"]))
    return {"content": [{"type": "text", "text": json.dumps(apps)}]}


def perform_tool(session_id, tool, args):
    if tool == "list_apps":
        return list_apps_result()
    app_query = str(args.get("app") or "")
    if tool == "get_app_state":
        return save_snapshot(session_id, app_query)

    app = resolve_app(app_query)
    _, window = main_window(app)
    window_bounds = bounds(window)
    record = None
    element = None
    element_id = args.get("elementId", args.get("element_index"))
    if element_id is not None:
        session = snapshots.get(session_id, [])
        snapshot_id = args.get("snapshotId", args.get("snapshot_id"))
        if snapshot_id is None and session:
            snapshot_id = session[-1]["snapshotId"]
        _, record = stored_element(session_id, snapshot_id, element_id)
        element = live_element(app, record)

    action_metadata = None
    if tool == "click":
        has_element = element_id is not None
        has_x = args.get("x") is not None
        has_y = args.get("y") is not None
        if has_element and (has_x or has_y):
            raise RuntimeError(
                "Choose one click addressing mode: snapshotId + elementId, or screenshot x + y"
            )
        if has_element:
            if str(args.get("button", args.get("mouse_button", "left"))).lower() != "left":
                raise RuntimeError(
                    "Semantic right/middle click is unavailable on this element; use screenshot x/y"
                )
            action_index = preferred_action(element)
            if action_index is None:
                raise RuntimeError(
                    "The selected element does not advertise a click action. "
                    "Re-snapshot and choose an actionable element, or use screenshot x/y."
                )
            action_name = str(safe(lambda: element.get_action_name(action_index), "action"))
            click_count = int(args.get("clickCount", args.get("click_count", 1)) or 1)
            if click_count not in (1, 2):
                raise RuntimeError("clickCount must be 1 or 2")
            for attempt in range(click_count):
                if not do_action(element, action_index):
                    raise RuntimeError("The selected element rejected " + action_name)
                if attempt + 1 < click_count:
                    time.sleep(0.05)
            action_metadata = {
                "kind": "click",
                "addressing": "element",
                "path": "atspi_action",
                "accessibilityAction": action_name,
                "delivered": True,
                "verified": False,
                "effect": "unverifiable",
                "next": "Confirm the effect in the returned app state and re-snapshot before another action.",
            }
        elif has_x and has_y:
            x, y = screen_point(window_bounds, None, args.get("x"), args.get("y"))
            click_at(
                x,
                y,
                args.get("button", args.get("mouse_button", "left")),
                args.get("clickCount", args.get("click_count", 1)),
            )
            display_server = "wayland" if os.environ.get("WAYLAND_DISPLAY") else "x11"
            action_metadata = {
                "kind": "click",
                "addressing": "pixel",
                "path": "atspi_global_pointer",
                "deliveryMode": "foreground",
                "displayServer": display_server,
                "delivered": True,
                "verified": False,
                "effect": "unverifiable",
                "next": "Confirm the effect in the returned screenshot. Prefer Browser Use for web-page content.",
            }
        else:
            raise RuntimeError(
                "Click requires snapshotId + elementId, or both screenshot x and y coordinates"
            )
    elif tool == "perform_secondary_action":
        requested = str(args.get("action") or "").lower()
        matched = None
        for index, name in enumerate(action_names(element)):
            if name.lower() == requested:
                matched = index
                break
        if not do_action(element, matched):
            raise RuntimeError("That secondary action is no longer available")
    elif tool == "type_text":
        if element is None or not set_text(element, args.get("text", ""), False):
            type_keyboard_text(args.get("text", ""))
        action_metadata = {
            "kind": "type_text",
            "path": "atspi_editable_text" if element is not None else "atspi_keyboard",
            "delivered": True,
            "verified": False,
        }
    elif tool == "set_value":
        if not set_text(element, args.get("value", ""), True):
            value = safe(element.get_value_iface) if element is not None else None
            if value is None or not bool(
                safe(lambda: Atspi.Value.set_current_value(value, float(args.get("value"))), False)
            ):
                raise RuntimeError("The element is not settable")
    elif tool == "press_key":
        press_key(args.get("key", ""))
        action_metadata = {
            "kind": "press_key",
            "path": "atspi_keyboard",
            "delivered": True,
            "verified": False,
        }
    elif tool == "scroll":
        key = {"up": "Page_Up", "left": "Left", "right": "Right"}.get(
            args.get("direction"), "Page_Down"
        )
        for _ in range(max(1, int(math.ceil(float(args.get("pages", 1)))))):
            press_key(key)
    elif tool == "select_text":
        text, start, end = text_selection_range(element, args)
        if not bool(
            safe(
                lambda: Atspi.Text.set_selection(text, 0, start, end),
                False,
            )
        ):
            raise RuntimeError("The element does not support text selection")
        action_metadata = {
            "kind": "select_text",
            "path": "atspi_text_selection",
            "start": start,
            "length": end - start,
            "delivered": True,
            "verified": True,
        }
    elif tool == "drag":
        from_record = to_record = None
        from_element_id = args.get("fromElementId", args.get("from_element_index"))
        to_element_id = args.get("toElementId", args.get("to_element_index"))
        snapshot_id = args.get("snapshotId", args.get("snapshot_id"))
        if snapshot_id is None and snapshots.get(session_id):
            snapshot_id = snapshots[session_id][-1]["snapshotId"]
        if from_element_id is not None:
            _, from_record = stored_element(
                session_id, snapshot_id, from_element_id
            )
        if to_element_id is not None:
            _, to_record = stored_element(
                session_id, snapshot_id, to_element_id
            )
        from_x, from_y = screen_point(
            window_bounds,
            from_record,
            args.get("fromX", args.get("from_x")),
            args.get("fromY", args.get("from_y")),
        )
        to_x, to_y = screen_point(
            window_bounds,
            to_record,
            args.get("toX", args.get("to_x")),
            args.get("toY", args.get("to_y")),
        )
        Atspi.generate_mouse_event(round(from_x), round(from_y), "abs")
        Atspi.generate_mouse_event(round(from_x), round(from_y), "b1p")
        for step in range(1, 13):
            x = from_x + (to_x - from_x) * step / 12
            y = from_y + (to_y - from_y) * step / 12
            Atspi.generate_mouse_event(round(x), round(y), "abs")
            time.sleep(0.02)
        Atspi.generate_mouse_event(round(to_x), round(to_y), "b1r")
    else:
        raise RuntimeError("Unsupported Computer Use tool: " + str(tool))

    time.sleep(0.12)
    return save_snapshot(session_id, app_query, action_metadata)


def handle(message):
    request_type = message.get("type")
    if request_type == "closeSession":
        snapshots.pop(str(message.get("sessionId") or ""), None)
        return {"content": [{"type": "text", "text": "closed"}]}
    if request_type != "tool":
        raise RuntimeError("Unsupported helper request")
    return perform_tool(
        str(message.get("sessionId") or ""),
        str(message.get("tool") or ""),
        message.get("arguments") or {},
    )


def main():
    if not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
        raise RuntimeError("No signed-in desktop D-Bus session could be found")
    Atspi.init()
    for line in sys.stdin:
        if not line.strip():
            continue
        request_id = None
        try:
            message = json.loads(line)
            request_id = message.get("id")
            response = {"id": request_id, "result": handle(message)}
        except Exception as exc:
            response = {"id": request_id, "error": str(exc)}
        sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.stderr.write(traceback.format_exc())
        sys.exit(1)
