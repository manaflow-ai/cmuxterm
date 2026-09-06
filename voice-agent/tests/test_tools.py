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
    assert fake.methods() == ["system.tree", "pane.list", "workspace.list"]


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
        "which_pane", "focus_terminal", "dictate", "set_dictation", "choose_option", "menu_navigate", "scroll",
        "shell_context", "go_to_directory", "run_shell", "compose_and_type", "press_enter", "open_agent",
    }
    confirming = {s.name for s in tools.specs() if "Requires confirmation" in s.description}
    assert confirming == {"close_workspace", "close_tab", "run_command", "run_shell"}
    assert all(s.cancel_on_interruption for s in tools.specs())


# ------------------------------------------------------- focus / where am I


async def test_which_pane_reports_position(tools: VoiceTools, fake: FakeCmux):
    res = await tools.which_pane()
    assert res["ok"]
    assert res["say"] == 'You are in pane 1 of 2 on the left, in workspace web frontend, on terminal "vim".'


async def test_focus_terminal_calls_focus_input(tools: VoiceTools, fake: FakeCmux):
    fake.responder = lambda m, p: {"surface_id": "S-B2", "input_focused": True} if m == "surface.focus_input" else FakeCmux.default_responder(fake, m, p)
    res = await tools.focus_terminal("npm")
    assert res["ok"] and res["say"] == "Cursor is in npm run dev."
    assert {"method": "surface.focus_input", "params": {"surface_id": "S-B2"}} in fake.requests


async def test_focus_terminal_default_uses_focused(tools: VoiceTools, fake: FakeCmux):
    await tools.focus_terminal()
    assert {"method": "surface.focus_input", "params": {}} in fake.requests


# -------------------------------------------------------------- dictation


async def test_dictate_types_verbatim_without_enter(tools: VoiceTools, fake: FakeCmux):
    res = await tools.dictate("git commit -m 'fix the thing'")
    assert res["ok"] and res["typed"] == "git commit -m 'fix the thing'"
    assert {"method": "surface.send_text", "params": {"surface_id": "S-B1", "text": "git commit -m 'fix the thing'"}} in fake.requests
    assert "surface.send_key" not in fake.methods()


async def test_dictation_mode_toggle(tools: VoiceTools):
    assert tools.dictation_active is False
    res = await tools.set_dictation(True)
    assert res["dictation"] is True and tools.dictation_active
    res = await tools.set_dictation(False)
    assert res["dictation"] is False and not tools.dictation_active


# ------------------------------------------------------------ menus


async def test_choose_option_moves_down_then_enter_after_confirm(tools: VoiceTools, fake: FakeCmux):
    res = await tools.choose_option(3)
    assert res["status"] == "needs_confirmation"
    res = await tools.confirm("yes")
    assert res["ok"] and res["say"] == "Chose option 3."
    keys = [r["params"]["key"] for r in fake.requests if r["method"] == "surface.send_key"]
    assert keys == ["down", "down", "enter"]


async def test_choose_option_trusted_is_immediate(fake: FakeCmux):
    client = CmuxClient(fake.path, allowed_methods=ALLOWED_METHODS)
    t = VoiceTools(client, ConfirmationPolicy(trust_terminal_input=True))
    res = await t.choose_option(1)
    assert res["ok"]
    assert [r["params"]["key"] for r in fake.requests if r["method"] == "surface.send_key"] == ["enter"]
    client.close()


async def test_menu_navigate_next_and_cancel_are_immediate(tools: VoiceTools, fake: FakeCmux):
    res = await tools.menu_navigate("next", times=2)
    assert res["ok"] and res["say"] == "Next."
    res = await tools.menu_navigate("cancel")
    assert res["ok"] and res["say"] == "Cancelled."
    keys = [r["params"]["key"] for r in fake.requests if r["method"] == "surface.send_key"]
    assert keys == ["down", "down", "escape"]


async def test_menu_navigate_confirm_requires_confirmation(tools: VoiceTools, fake: FakeCmux):
    res = await tools.menu_navigate("confirm")
    assert res["status"] == "needs_confirmation"
    assert "surface.send_key" not in fake.methods()


# ------------------------------------------------------------- scroll


async def test_scroll_pages_and_edges(tools: VoiceTools, fake: FakeCmux):
    res = await tools.scroll("up", pages=2)
    assert res["ok"] and res["say"] == "Scrolled up 2 pages."
    assert {"method": "surface.scroll", "params": {"surface_id": "S-B1", "direction": "up", "pages": 2}} in fake.requests
    res = await tools.scroll("end")
    assert res["say"] == "At the bottom."
    assert {"method": "surface.scroll", "params": {"surface_id": "S-B1", "direction": "bottom", "pages": 1}} in fake.requests


async def test_scroll_rejects_nonsense(tools: VoiceTools, fake: FakeCmux):
    res = await tools.scroll("sideways")
    assert res["ok"] is False
    assert "surface.scroll" not in fake.methods()


# --------------------------------------------------------- generalized shell


async def test_go_to_directory_cds_into_unique_match(tools: VoiceTools, fake: FakeCmux, monkeypatch, tmp_path):
    from cmux_voice import shell_context as sc
    target = tmp_path / "staff-portal"; target.mkdir()
    monkeypatch.setattr(sc, "shell_context", lambda tty, fallback_cwd=None: sc.ShellContext(cwd=str(tmp_path), git_branch=None, git_root=None))
    monkeypatch.setattr(sc, "find_directories", lambda name, parent=None, cwd=None, roots=None, limit=6: [str(target)])
    res = await tools.go_to_directory("staff portal")
    assert res["ok"] and res["path"] == str(target)
    sent = [r for r in fake.requests if r["method"].startswith("surface.send_")]
    assert sent[0]["params"]["text"] == f"cd {str(target)}"
    assert sent[1]["params"]["key"] == "enter"


async def test_go_to_directory_asks_when_ambiguous(tools: VoiceTools, fake: FakeCmux, monkeypatch):
    from cmux_voice import shell_context as sc
    monkeypatch.setattr(sc, "shell_context", lambda tty, fallback_cwd=None: sc.ShellContext(cwd="/tmp", git_branch=None, git_root=None))
    monkeypatch.setattr(sc, "find_directories", lambda name, parent=None, cwd=None, roots=None, limit=6: ["/a/Staff-Portal", "/b/archive/Staff-Portal"])
    res = await tools.go_to_directory("staff portal")
    assert res["status"] == "ambiguous"
    assert "Which one?" in res["say"]
    assert "surface.send_text" not in fake.methods()


async def test_go_to_directory_not_found(tools: VoiceTools, fake: FakeCmux, monkeypatch):
    from cmux_voice import shell_context as sc
    monkeypatch.setattr(sc, "shell_context", lambda tty, fallback_cwd=None: sc.ShellContext(cwd="/tmp", git_branch=None, git_root=None))
    monkeypatch.setattr(sc, "find_directories", lambda *a, **k: [])
    res = await tools.go_to_directory("nowhere")
    assert res["ok"] is False and "couldn't find" in res["say"]


async def test_shell_context_tool_reports_branch(tools: VoiceTools, monkeypatch):
    from cmux_voice import shell_context as sc
    monkeypatch.setattr(sc, "shell_context", lambda tty, fallback_cwd=None: sc.ShellContext(cwd="/Users/me/proj", git_branch="main", git_root="/Users/me/proj"))
    res = await tools.shell_context()
    assert res["ok"] and res["say"] == "You are in /Users/me/proj, on branch main."


async def test_run_shell_confirms_then_runs(tools: VoiceTools, fake: FakeCmux):
    res = await tools.run_shell("git checkout develop")
    assert res["status"] == "needs_confirmation" and "git checkout develop" in res["say"]
    res = await tools.confirm("yes")
    assert res["ok"] and res["command"] == "git checkout develop"
    sent = [r for r in fake.requests if r["method"].startswith("surface.send_")]
    assert sent[-2]["params"]["text"] == "git checkout develop" and sent[-1]["params"]["key"] == "enter"


async def test_run_shell_trusted_skips_confirm_but_not_for_risky(fake: FakeCmux):
    client = CmuxClient(fake.path, allowed_methods=ALLOWED_METHODS)
    t = VoiceTools(client, ConfirmationPolicy(trust_terminal_input=True))
    res = await t.run_shell("git status")
    assert res["ok"]
    res = await t.run_shell("git push --force origin main")
    assert res["status"] == "needs_confirmation"
    res = await t.run_shell("rm -rf build")
    assert res["status"] == "needs_confirmation"
    client.close()


async def test_compose_then_enter_needs_no_confirmation(tools: VoiceTools, fake: FakeCmux):
    res = await tools.compose_and_type("Please refactor the login handler to use async/await and add tests.")
    assert res["ok"] and res["say"] == "Written. Say enter to send it."
    assert "surface.send_key" not in fake.methods()
    res = await tools.press_enter()
    assert res["ok"] and res["say"] == "Sent."
    assert {"method": "surface.send_key", "params": {"surface_id": "S-B1", "key": "enter"}} in fake.requests


async def test_press_enter_alone_confirms(tools: VoiceTools, fake: FakeCmux):
    res = await tools.press_enter()
    assert res["status"] == "needs_confirmation"
    assert "surface.send_key" not in fake.methods()


# ---------------------------------------------------------------- agents


async def test_open_agent_launches_claude_without_confirmation(tools: VoiceTools, fake: FakeCmux):
    res = await tools.open_agent()
    assert res["ok"] and res["say"] == "Opened Claude Code." and res["agent"] == "claude"
    sent = [r for r in fake.requests if r["method"].startswith("surface.send_")]
    assert sent[0]["params"]["text"] == "claude" and sent[1]["params"]["key"] == "enter"


async def test_open_agent_with_prompt_types_but_does_not_send(tools: VoiceTools, fake: FakeCmux, monkeypatch):
    import cmux_voice.tools as t

    async def no_sleep(_):
        return None

    monkeypatch.setattr(t.asyncio, "sleep", no_sleep)
    # The CLI's input box appears on the second screen read.
    reads = {"n": 0}
    base = fake.responder

    def responder(m, p):
        if m == "surface.read_text":
            reads["n"] += 1
            return {"text": "starting…\n" if reads["n"] < 2 else "Welcome\n❯ \n? for shortcuts\n"}
        return base(m, p)

    fake.responder = responder
    res = await tools.open_agent("codex", prompt="Add tests for the login handler.")
    assert reads["n"] >= 2
    assert res["ok"] and "Say enter to send it" in res["say"]
    sent = [r for r in fake.requests if r["method"].startswith("surface.send_")]
    assert [x["params"].get("text") or x["params"].get("key") for x in sent] == ["codex", "enter", "Add tests for the login handler."]
    res = await tools.press_enter()
    assert res["ok"] and res["say"] == "Sent."


async def test_open_agent_unknown(tools: VoiceTools, fake: FakeCmux):
    res = await tools.open_agent("emacs")
    assert res["ok"] is False and "don't know" in res["say"]
