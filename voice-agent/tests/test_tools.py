from __future__ import annotations

import pytest

from cmux_voice.cmux_client import CmuxClient, CmuxError
from cmux_voice.policy import ConfirmationPolicy
from cmux_voice.state import UIState
from cmux_voice.tools import ALLOWED_METHODS, VoiceTools
from tests.conftest import FakeCmux, sample_panes, sample_tree


# ---------------------------------------------------------------- state model


def test_summary_numbers_workspaces_and_panes():
    st = UIState.from_tree(sample_tree(), sample_panes()["panes"])
    s = st.summary()
    assert 'Workspaces (2): 1 "api" | 2 "web frontend" (current)' in s
    assert "pane 1 left:" in s and "pane 2 right:" in s
    assert 'browser "GitHub" [https://github.com]' in s
    assert 'terminal "vim" (focused)' in s


def test_resolve_workspace_by_number_name_and_ref():
    st = UIState.from_tree(sample_tree())
    assert st.resolve_workspace("1").title == "api"
    assert st.resolve_workspace("front").title == "web frontend"
    assert st.resolve_workspace("workspace:3").title == "web frontend"
    assert st.resolve_workspace(None).title == "web frontend"
    assert st.resolve_workspace("nope") is None


def test_resolve_pane_by_direction_uses_frames():
    st = UIState.from_tree(sample_tree(), sample_panes()["panes"])
    assert st.resolve_pane("right").id == "P-B2"
    assert st.resolve_pane("to the right").id == "P-B2"
    assert st.resolve_pane("left") is None  # nothing left of the focused pane
    assert st.resolve_pane("2").id == "P-B2"
    assert st.resolve_pane(None).id == "P-B1"


def test_resolve_surface_kinds():
    st = UIState.from_tree(sample_tree())
    assert st.resolve_surface(None).id == "S-B1"
    assert st.resolve_surface(None, kind="browser").id == "S-B3"
    assert st.resolve_surface("github").id == "S-B3"
    assert st.resolve_surface("npm").id == "S-B2"


# ------------------------------------------------------------- client wiring


def test_allowlist_refuses_unknown_methods(fake: FakeCmux):
    client = CmuxClient(fake.path, allowed_methods=ALLOWED_METHODS)
    with pytest.raises(CmuxError) as e:
        client.call("debug.app.activate")
    assert e.value.code == "method_not_allowed"
    assert fake.requests == []


def test_capability_envelope_is_prefixed(fake: FakeCmux):
    client = CmuxClient(fake.path, capability="CAPTOKEN")
    client.call("system.tree")
    assert fake.raw_lines[0].startswith("_cmux_capability_v1 CAPTOKEN {")
    assert fake.methods() == ["system.tree"]


def test_error_response_raises_with_code(fake: FakeCmux):
    def responder(method, params):
        raise ValueError("boom")

    fake.responder = responder
    client = CmuxClient(fake.path)
    with pytest.raises(CmuxError) as e:
        client.call("system.tree")
    assert "boom" in str(e.value)


# ---------------------------------------------------------------- tools: read


async def test_get_ui_state_calls_tree_and_panes(tools: VoiceTools, fake: FakeCmux):
    res = await tools.get_ui_state()
    assert res["ok"] and "web frontend" in res["say"]
    assert fake.methods() == ["system.tree", "pane.list"]


async def test_read_terminal_returns_tail(tools: VoiceTools, fake: FakeCmux):
    res = await tools.read_terminal(lines=2)
    assert res["ok"]
    assert res["text"] == "README.md  src\n$"
    call = [r for r in fake.requests if r["method"] == "surface.read_text"][0]
    assert call["params"] == {"surface_id": "S-B1", "lines": 2}


# ------------------------------------------------------------ tools: navigate


async def test_focus_workspace_by_name(tools: VoiceTools, fake: FakeCmux):
    res = await tools.focus_workspace("api")
    assert res["ok"] and res["say"] == "Switched to api."
    assert {"method": "workspace.select", "params": {"workspace_id": "WS-A"}} in fake.requests


async def test_focus_workspace_next(tools: VoiceTools, fake: FakeCmux):
    await tools.focus_workspace("next")
    assert "workspace.next" in fake.methods()


async def test_focus_pane_right(tools: VoiceTools, fake: FakeCmux):
    res = await tools.focus_pane("right")
    assert res["ok"]
    assert {"method": "pane.focus", "params": {"pane_id": "P-B2"}} in fake.requests


async def test_focus_pane_unknown_direction_fails_softly(tools: VoiceTools, fake: FakeCmux):
    res = await tools.focus_pane("left")
    assert res["ok"] is False
    assert "pane.focus" not in fake.methods()


# ------------------------------------------------------ tools: create/arrange


async def test_split_terminal(tools: VoiceTools, fake: FakeCmux):
    res = await tools.split("down")
    assert res["ok"] and res["say"] == "Split down."
    assert {"method": "surface.split", "params": {"direction": "down", "type": "terminal", "focus": True}} in fake.requests
    assert {"method": "surface.trigger_flash", "params": {"surface_id": "S-NEW"}} in fake.requests


async def test_split_browser_with_url(tools: VoiceTools, fake: FakeCmux):
    res = await tools.split("right", "browser", "github.com")
    assert res["ok"]
    assert {"method": "browser.open_split", "params": {"direction": "right", "url": "https://github.com"}} in fake.requests


async def test_create_and_rename_workspace(tools: VoiceTools, fake: FakeCmux):
    res = await tools.create_workspace("notes")
    assert res["ok"] and res["workspace_id"] == "WS-NEW"
    assert {"method": "workspace.create", "params": {"focus": True, "title": "notes"}} in fake.requests
    res = await tools.rename_workspace("docs", "api")
    assert res["ok"]
    assert {"method": "workspace.rename", "params": {"workspace_id": "WS-A", "title": "docs"}} in fake.requests


# ---------------------------------------------------------- confirmation flow


async def test_close_workspace_requires_confirmation(tools: VoiceTools, fake: FakeCmux):
    res = await tools.close_workspace("api")
    assert res["status"] == "needs_confirmation"
    assert "Close workspace api with 1 tab?" in res["say"]
    assert "workspace.close" not in fake.methods()

    res = await tools.confirm("yes")
    assert res["ok"] and res["say"] == "Closed api."
    assert {"method": "workspace.close", "params": {"workspace_id": "WS-A"}} in fake.requests


async def test_confirm_no_cancels(tools: VoiceTools, fake: FakeCmux):
    await tools.close_tab("github")
    res = await tools.confirm("no")
    assert res["status"] == "cancelled"
    assert "surface.close" not in fake.methods()
    res = await tools.confirm("yes")
    assert res["status"] == "nothing_pending"


async def test_confirmation_expires(tools: VoiceTools, fake: FakeCmux):
    tools.policy.ttl_seconds = 0.0
    await tools.close_tab("github")
    res = await tools.confirm("yes")
    assert res["status"] == "nothing_pending"
    assert "surface.close" not in fake.methods()


async def test_run_command_confirms_then_sends_text_and_enter(tools: VoiceTools, fake: FakeCmux):
    res = await tools.run_command("ls -la")
    assert res["status"] == "needs_confirmation"
    assert "Run ls -la in vim?" in res["say"]
    res = await tools.confirm("yes")
    assert res["ok"] and res["say"] == "Ran ls -la."
    sent = [r for r in fake.requests if r["method"].startswith("surface.send_")]
    assert sent == [
        {"method": "surface.send_text", "params": {"surface_id": "S-B1", "text": "ls -la"}},
        {"method": "surface.send_key", "params": {"surface_id": "S-B1", "key": "enter"}},
    ]


async def test_run_command_trusted_skips_confirmation(fake: FakeCmux):
    client = CmuxClient(fake.path, allowed_methods=ALLOWED_METHODS)
    t = VoiceTools(client, ConfirmationPolicy(trust_terminal_input=True))
    res = await t.run_command("pwd")
    assert res["ok"] and res["say"] == "Ran pwd."
    assert "surface.send_key" in fake.methods()
    client.close()


async def test_type_text_does_not_press_enter(tools: VoiceTools, fake: FakeCmux):
    res = await tools.type_text("echo hi", target="npm")
    assert res["ok"]
    assert {"method": "surface.send_text", "params": {"surface_id": "S-B2", "text": "echo hi"}} in fake.requests
    assert "surface.send_key" not in fake.methods()


async def test_press_key_aliases_and_enter_gate(tools: VoiceTools, fake: FakeCmux):
    res = await tools.press_key("control c")
    assert res["ok"]
    assert {"method": "surface.send_key", "params": {"surface_id": "S-B1", "key": "ctrl-c"}} in fake.requests
    res = await tools.press_key("enter")
    assert res["status"] == "needs_confirmation"


async def test_type_into_browser_target_fails(tools: VoiceTools, fake: FakeCmux):
    res = await tools.type_text("hello", target="github")
    assert res["ok"] is False and res["say"] == "GitHub is a browser, not a terminal."


# ------------------------------------------------------------- tools: browser


async def test_browser_navigate_existing_browser(tools: VoiceTools, fake: FakeCmux):
    res = await tools.browser_navigate("vercel.com")
    assert res["ok"]
    assert {"method": "browser.navigate", "params": {"surface_id": "S-B3", "url": "https://vercel.com"}} in fake.requests


async def test_browser_navigate_search_fallback(tools: VoiceTools, fake: FakeCmux):
    await tools.browser_navigate("pipecat docs")
    call = [r for r in fake.requests if r["method"] == "browser.navigate"][0]
    assert call["params"]["url"] == "https://www.google.com/search?q=pipecat+docs"


async def test_browser_history_back(tools: VoiceTools, fake: FakeCmux):
    res = await tools.browser_history("back")
    assert res["ok"] and res["say"] == "Went back."
    assert {"method": "browser.back", "params": {"surface_id": "S-B3"}} in fake.requests


async def test_browser_navigate_without_browser_opens_split(fake: FakeCmux):
    tree = sample_tree()
    # Remove the browser surface from the current workspace.
    tree["windows"][0]["workspaces"][1]["panes"][1]["surfaces"].pop()

    def responder(method, params):
        if method == "system.tree":
            return tree
        return FakeCmux.default_responder(fake, method, params)

    fake.responder = responder
    client = CmuxClient(fake.path, allowed_methods=ALLOWED_METHODS)
    t = VoiceTools(client)
    res = await t.browser_navigate("github.com")
    assert res["ok"]
    assert {"method": "browser.open_split", "params": {"url": "https://github.com", "direction": "right"}} in fake.requests
    client.close()


# -------------------------------------------------------------- registry


def test_specs_cover_v1_catalog(tools: VoiceTools):
    names = {s.name for s in tools.specs()}
    assert names == {
        "get_ui_state", "read_terminal", "focus_workspace", "focus_pane", "focus_tab",
        "create_workspace", "rename_workspace", "close_workspace", "split", "new_tab", "close_tab",
        "equalize_splits", "type_text", "press_key", "run_command", "interrupt",
        "browser_navigate", "browser_history", "confirm", "end_session",
    }
    confirming = {s.name for s in tools.specs() if "Requires confirmation" in s.description}
    assert confirming == {"close_workspace", "close_tab", "run_command"}
    assert all(s.cancel_on_interruption for s in tools.specs())
