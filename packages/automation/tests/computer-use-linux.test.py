"""Exercise the shipped helper against a fake AT-SPI boundary, without a desktop."""
import ast
import json
from pathlib import Path
from types import SimpleNamespace
import unittest

SOURCE = Path(__file__).parents[1] / "resources/computer-use-linux.py"


def helper():
    tree = ast.parse(SOURCE.read_text())
    # Keep the production definitions; omit desktop discovery, GI imports and stdin loop.
    tree.body = [node for node in tree.body if isinstance(node, (ast.FunctionDef, ast.Assign))]
    namespace = {"json": json}
    exec(compile(tree, str(SOURCE), "exec"), namespace)
    return namespace


class ComputerUseLinuxTests(unittest.TestCase):
    def test_coordinates_require_current_pixels_and_unchanged_window(self):
        h = helper()
        box = dict(x=400, y=800, width=500, height=300)
        snapshot = dict(windowBounds=box, screenshotSize=dict(width=1000, height=600))
        self.assertEqual(h["screen_point"](box, x=500, y=300, snapshot=snapshot), (650, 950))
        for x, y in [(-1, 0), (1000, 0), (0, 600), (float("nan"), 0)]:
            with self.assertRaises(RuntimeError):
                h["screen_point"](box, x=x, y=y, snapshot=snapshot)
        with self.assertRaises(RuntimeError):
            h["screen_point"]({**box, "y": 900}, x=1, y=1, snapshot=snapshot)
        with self.assertRaises(RuntimeError):
            h["screen_point"](box, x=1, y=1, snapshot={**snapshot, "screenshotSize": None})

    def test_snapshot_ids_cannot_cross_apps_windows_or_observations(self):
        h = helper()
        app = SimpleNamespace(get_process_id=lambda: 7)
        h["snapshots"]["session"] = [dict(pid=7, windowId=2, snapshotId="old"),
                                      dict(pid=8, windowId=2, snapshotId="other"),
                                      dict(pid=7, windowId=2, snapshotId="current")]
        self.assertEqual(h["current_snapshot"]("session", app, 2, {})["snapshotId"], "current")
        for identifier in ["old", "other"]:
            with self.assertRaises(RuntimeError):
                h["current_snapshot"]("session", app, 2, {"snapshot_id": identifier})
        with self.assertRaises(RuntimeError):
            h["current_snapshot"]("session", app, 3, {})

    def test_recycled_element_path_is_rejected(self):
        h = helper()
        node = SimpleNamespace(get_role_name=lambda: "menu item", get_name=lambda: "Delete")
        app = SimpleNamespace(get_child_at_index=lambda _: node)
        with self.assertRaisesRegex(RuntimeError, "element changed"):
            h["live_element"](app, dict(path=[0], role="menu item", name="Add to Playlist"))

    def test_invalid_key_sequences_send_nothing_and_modifiers_are_released(self):
        h = helper()
        events = []
        h["Gdk"] = SimpleNamespace(keyval_from_name=lambda key: {"Control_L": 1, "Return": 2}.get(key, 0))
        def event(value, text, kind):
            events.append((value, kind))
            if kind == "tap":
                raise RuntimeError("Input disconnected")
        h["Atspi"] = SimpleNamespace(generate_keyboard_event=event,
                                      KeySynthType=SimpleNamespace(PRESS="down", RELEASE="up", PRESSRELEASE="tap"))
        for key in ["unknown+a", "ctrl+NoSuchKey", ""]:
            with self.assertRaises(RuntimeError):
                h["press_key"](key)
        self.assertEqual(events, [])
        with self.assertRaisesRegex(RuntimeError, "Input disconnected"):
            h["press_key"]("ctrl+Return")
        self.assertEqual(events, [(1, "down"), (2, "tap"), (1, "up")])

    def test_semantic_action_does_not_capture_or_remap_state(self):
        h = helper()
        app = object()
        target = SimpleNamespace(get_action_name=lambda _: "press")
        h.update(resolve_running_app=lambda _: app, require_unprotected_app=lambda _: None,
                 session_window=lambda *_: (2, object()), bounds=lambda _: None,
                 current_snapshot=lambda *_: {"snapshotId": "s"},
                 stored_element=lambda *_: (None, {}), live_element=lambda *_: target,
                 preferred_action=lambda _: 0, do_action=lambda *_: True,
                 save_snapshot=lambda *_: self.fail("An action must not observe"))
        result = h["perform_tool"]("s", "click", {"app": "Music", "element_index": 4})
        self.assertEqual(len(result["content"]), 1)
        self.assertEqual(json.loads(result["content"][0]["text"])["status"], "delivered")
        with self.assertRaisesRegex(RuntimeError, "requires delivery_mode foreground"):
            h["perform_tool"]("s", "press_key", {"app": "Music", "key": "Return"})


if __name__ == "__main__":
    unittest.main()
