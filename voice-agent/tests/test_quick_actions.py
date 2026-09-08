"""Quick actions: groups, tab naming, lazy git, worktrees, fuzzy switching,
cross-workspace agent callouts, and the event-driven name cache."""
from __future__ import annotations

import asyncio
import json
import os
import subprocess

import pytest

from cmux_voice import shell_context as sc
from cmux_voice.cmux_client import CmuxClient
from cmux_voice.events import AgentCompletion, AgentEventSubscriber
from cmux_voice.policy import ConfirmationPolicy
from cmux_voice.state import UIState, _best_name_match
from cmux_voice.summary import CompletionSummarizer
from cmux_voice.tools import ALLOWED_METHODS, VoiceTools
from tests.conftest import FakeCmux, sample_panes, sample_tree


def _groups():
    return {"groups": [
        {"id": "G1", "ref": "group:1", "name": "Client Work", "member_workspace_ids": ["WS-A"], "is_collapsed": False},
        {"id": "G2", "ref": "group:2", "name": "Side Projects", "member_workspace_ids": ["WS-B"], "is_collapsed": False},
    ]}


@pytest.fixture
def gtools(fake: FakeCmux):
    base = fake.responder

    def responder(m, p):
        if m == "workspace.group.list":
            return _groups()
        if m == "workspace.group.create":
            return {"group_id": "G-NEW"}
        if m == "workspace.group.new_workspace":
            return {"workspace_id": "WS-G"}
        return base(m, p)

    fake.responder = responder
    client = CmuxClient(fake.path, allowed_methods=ALLOWED_METHODS)
    t = VoiceTools(client, ConfirmationPolicy(trust_terminal_input=True))
    yield t
    client.close()


# ------------------------------------------------------------ fuzzy names


def test_spoken_names_match_separators_case_and_partial_words():
    cands = [("Staff-Portal", 1), ("web frontend", 2), ("dmux/cmux", 3), ("Client Work", 4)]
    assert _best_name_match("staff portal", cands) == 1
    assert _best_name_match("the staff portal workspace", cands) == 1
    assert _best_name_match("frontend", cands) == 2
    assert _best_name_match("cmux", cands) == 3
    assert _best_name_match("client", cands) == 4
    assert _best_name_match("zebra", cands) is None


# ---------------------------------------------------------------- groups


async def test_state_loads_groups_and_resolves_them(gtools: VoiceTools):
    st = await gtools.refresh()
    assert [g.name for g in st.groups] == ["Client Work", "Side Projects"]
    assert st.resolve_group("side").name == "Side Projects"
    assert st.resolve_group(None).name == "Side Projects"  # current workspace WS-B is in it


async def test_create_group_with_named_workspaces(gtools: VoiceTools, fake: FakeCmux):
    res = await gtools.create_workspace_group("Backend", workspaces=["api"])
    assert res["ok"] and res["say"] == "Created group Backend with 1 workspace."
    assert {"method": "workspace.group.create", "params": {"name": "Backend", "child_workspace_ids": ["WS-A"]}} in fake.requests


async def test_rename_focus_and_new_workspace_in_group(gtools: VoiceTools, fake: FakeCmux):
    await gtools.refresh()
    assert (await gtools.rename_workspace_group("Clients", "client work"))["ok"]
    assert {"method": "workspace.group.rename", "params": {"group_id": "G1", "name": "Clients"}} in fake.requests
    assert (await gtools.focus_workspace_group("side projects"))["say"] == "Switched to group Side Projects."
    res = await gtools.create_workspace_in_group("client", name="Invoices")
    assert res["ok"] and res["workspace_id"] == "WS-G"
    assert {"method": "workspace.rename", "params": {"workspace_id": "WS-G", "title": "Invoices"}} in fake.requests


# -------------------------------------------------------- naming things


async def test_create_workspace_names_it_afterwards(tools: VoiceTools, fake: FakeCmux):
    res = await tools.create_workspace("Notes")
    assert res["ok"] and res["say"] == "Created workspace Notes."
    assert {"method": "workspace.create", "params": {"focus": True}} in fake.requests
    assert {"method": "workspace.rename", "params": {"workspace_id": "WS-NEW", "title": "Notes"}} in fake.requests


async def test_rename_tab_targets_focused_or_named_surface(tools: VoiceTools, fake: FakeCmux):
    res = await tools.rename_tab("server")
    assert res["ok"] and res["say"] == "Named the tab server."
    assert {"method": "surface.rename", "params": {"surface_id": "S-B1", "title": "server"}} in fake.requests
    await tools.rename_tab("docs", target="github")
    assert {"method": "surface.rename", "params": {"surface_id": "S-B3", "title": "docs"}} in fake.requests


# ------------------------------------------------------------------- git


async def test_git_action_composes_correct_commands(fake: FakeCmux):
    client = CmuxClient(fake.path, allowed_methods=ALLOWED_METHODS)
    t = VoiceTools(client, ConfirmationPolicy(trust_terminal_input=True))
    cases = [
        (("checkout", "develop", None), "git checkout develop"),
        (("create branch", "fix login", None), "git checkout -b 'fix login'"),
        (("merge", "develop", None), "git merge develop"),
        (("commit", None, "fix the login flow"), "git add -A && git commit -m 'fix the login flow'"),
        (("push", None, None), "git push -u origin HEAD"),
        (("status", None, None), "git status"),
        (("pull", None, None), "git pull"),
    ]
    for (action, branch, message), expected in cases:
        fake.requests.clear()
        res = await t.git_action(action, branch=branch, message=message)
        assert res["ok"], (action, res)
        typed = [r["params"]["text"] for r in fake.requests if r["method"] == "surface.send_text"]
        assert typed == [expected], (action, typed)
    res = await t.git_action("commit")
    assert res["ok"] is False and "message" in res["say"]
    res = await t.git_action("frobnicate")
    assert res["ok"] is False
    client.close()


async def test_git_action_respects_confirmation_when_untrusted(tools: VoiceTools, fake: FakeCmux):
    res = await tools.git_action("switch", branch="main")
    assert res["status"] == "needs_confirmation" and "git checkout main" in res["say"]


# ------------------------------------------------------------- worktrees


async def test_create_worktree_creates_branch_dir_and_workspace(tools: VoiceTools, fake: FakeCmux, tmp_path, monkeypatch):
    if subprocess.run(["git", "--version"], capture_output=True).returncode != 0:
        pytest.skip("git not available")
    repo = tmp_path / "proj"; repo.mkdir()
    subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True)
    (repo / "a.txt").write_text("a")
    subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True)
    subprocess.run(["git", "-C", str(repo), "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init"], check=True)
    monkeypatch.setattr(sc, "shell_context", lambda tty, fallback_cwd=None: sc.ShellContext(cwd=str(repo), git_branch="main", git_root=str(repo)))
    res = await tools.create_worktree("feature-x")
    assert res["ok"], res
    assert os.path.isdir(repo / ".claude" / "worktrees" / "feature-x")
    branches = subprocess.run(["git", "-C", str(repo), "branch"], capture_output=True, text=True).stdout
    assert "feature-x" in branches
    assert {"method": "workspace.create", "params": {"focus": True, "working_directory": str(repo / ".claude" / "worktrees" / "feature-x")}} in fake.requests
    assert {"method": "workspace.rename", "params": {"workspace_id": "WS-NEW", "title": "proj · feature-x"}} in fake.requests
    # Second call reuses it.
    res = await tools.create_worktree("feature-x")
    assert res["ok"] and "existing" in res["say"]


async def test_create_worktree_outside_repo_explains(tools: VoiceTools, monkeypatch):
    monkeypatch.setattr(sc, "shell_context", lambda tty, fallback_cwd=None: sc.ShellContext(cwd="/tmp", git_branch=None, git_root=None))
    res = await tools.create_worktree("x")
    assert res["ok"] is False and "not a git repository" in res["say"]


# -------------------------------------------------- lazy folder matching


def test_lazy_folder_names_match_partial_words(tmp_path, monkeypatch):
    for rel in ["Local-Projects/staff-portal", "Local-Projects/dmux/cmux", "Local-Projects/archive/staff-portal-old", "Documents/DropinProjects/Staff-Portal"]:
        (tmp_path / rel).mkdir(parents=True)
    monkeypatch.setattr(sc, "_run", lambda cmd, timeout=3.0: "")
    roots = [str(tmp_path / "Local-Projects"), str(tmp_path / "Documents")]
    assert sc.find_directories("staff portal", roots=roots)[0] == str(tmp_path / "Local-Projects/staff-portal")
    assert sc.find_directories("the staff portal project", roots=roots)[0] == str(tmp_path / "Local-Projects/staff-portal")
    assert sc.find_directories("staff portal", parent="dropin", roots=roots) == [str(tmp_path / "Documents/DropinProjects/Staff-Portal")]
    found = sc.find_directories("cmux", roots=roots)
    assert found[0].endswith("dmux/cmux")
    # archives rank below live projects
    ranked = sc.find_directories("staff", roots=roots)
    assert ranked.index(str(tmp_path / "Local-Projects/staff-portal")) < ranked.index(str(tmp_path / "Local-Projects/archive/staff-portal-old"))


def test_directory_index_is_cached(tmp_path, monkeypatch):
    (tmp_path / "p" / "alpha").mkdir(parents=True)
    monkeypatch.setattr(sc, "_DEFAULT_ROOTS", [str(tmp_path / "p")])
    monkeypatch.setattr(sc, "_run", lambda cmd, timeout=3.0: "")
    sc._INDEX["paths"] = []; sc._INDEX["built_at"] = 0.0
    assert sc.find_directories("alpha")[0].endswith("p/alpha")
    built = sc._INDEX["built_at"]
    (tmp_path / "p" / "beta").mkdir()
    sc.find_directories("alpha")
    assert sc._INDEX["built_at"] == built  # served from cache, not rebuilt


# ------------------------------------- cross-workspace callouts & recaps


def _stop(surface="S-B2", seq=5):
    return AgentCompletion.from_frame({"type": "event", "category": "agent", "name": "agent.hook.Stop", "seq": seq, "source": "claude",
                                       "workspace_id": "WS-B", "surface_id": surface, "payload": {"hook_event_name": "Stop", "phase": "completed"}})


async def test_callout_names_the_terminal_and_offers_a_summary(fake: FakeCmux):
    """Workspace "web frontend" has two terminals, so the name combines
    workspace and tab; workspace "api" has one, so its name alone is used."""
    s = CompletionSummarizer(CmuxClient(fake.path))
    c = _stop("S-B2")
    text = await s.callout_for(c)
    assert '"Terminal web frontend npm run dev is done. Would you like a summary?"' in text
    assert "Interrupt whatever you were saying" in text and "summarize_agent" in text
    assert list(s.pending) == ["S-B2"]  # remembered until the user asks
    single = AgentCompletion.from_frame({"type": "event", "category": "agent", "name": "agent.hook.Stop", "seq": 6, "source": "codex",
                                         "workspace_id": "WS-A", "surface_id": "S-A1", "payload": {"hook_event_name": "Stop", "phase": "completed"}})
    assert '"Terminal api is done. Would you like a summary?"' in await s.callout_for(single)
    # "yes" takes the newest; a name picks that one; nothing left afterwards.
    assert s.take_by_name(None).completion is single
    assert s.take_by_name("the web frontend one").completion is c
    assert s.take_by_name(None) is None


async def test_ui_events_reach_the_ui_callback_and_agent_events_the_other():
    loop = asyncio.get_running_loop()
    ui, agent = [], []

    async def on_ui(f): ui.append(f.get("name"))
    async def on_agent(c): agent.append(c.surface_id)

    sub = AgentEventSubscriber(on_agent, loop, socket_path="/x", on_ui_event=on_ui)
    assert '"workspace"' in sub._request_line().decode() and '"surface"' in sub._request_line().decode()
    sub.handle_line(json.dumps({"type": "ack", "boot_id": "B", "resume": {"latest_seq": 0}}))
    sub.handle_line(json.dumps({"type": "event", "category": "surface", "name": "surface.focused", "seq": 1, "surface_id": "S-B2"}))
    sub.handle_line(json.dumps({"type": "event", "category": "agent", "name": "agent.hook.Stop", "seq": 2, "source": "claude", "surface_id": "S-B2", "payload": {"hook_event_name": "Stop", "phase": "completed"}}))
    await asyncio.sleep(0.05)
    assert ui == ["surface.focused"] and agent == ["S-B2"]


async def test_focus_tab_finds_tabs_in_other_workspaces(tools: VoiceTools, fake: FakeCmux):
    res = await tools.focus_tab("zsh")  # lives in workspace "api", not the current one
    assert res["ok"] and res["say"] == "Focused zsh in api."
    assert {"method": "workspace.select", "params": {"workspace_id": "WS-A"}} in fake.requests
    assert {"method": "surface.focus", "params": {"surface_id": "S-A1"}} in fake.requests


async def test_switch_misses_name_known_options(tools: VoiceTools):
    res = await tools.focus_workspace("zebra")
    assert res["ok"] is False and "I know: api, web frontend" in res["say"]
    res = await tools.focus_tab("zebra")
    assert res["ok"] is False and "Tabs I know" in res["say"]


async def test_completion_flow_calls_out_every_finish_and_summarizes_only_on_request(fake: FakeCmux):
    base = fake.responder
    reads = []

    def responder(m, p):
        if m == "system.identify":
            return {"focused": {"surface_id": "S-B1", "workspace_id": "WS-B"}}
        if m == "surface.read_text":
            reads.append(p.get("surface_id"))
            return {"text": "$ claude\n✔ created three files\n$ "}
        return base(m, p)

    fake.responder = responder
    from cmux_voice.completion_flow import CompletionFlow
    client = CmuxClient(fake.path, allowed_methods=ALLOWED_METHODS)
    tools = VoiceTools(client, ConfirmationPolicy())
    spoken = []

    async def speak(t): spoken.append(t)

    flow = CompletionFlow(tools, CompletionSummarizer(CmuxClient(fake.path)), speak, settle_s=0)
    await flow.on_agent_completion(_stop("S-B1", seq=1))  # the focused terminal: still only a callout
    assert flow.spoken == ["callout"] and "Terminal web frontend vim is done. Would you like a summary?" in spoken[-1]
    await flow.on_agent_completion(_stop("S-B2", seq=2))  # another terminal, same treatment
    assert flow.spoken == ["callout", "callout"] and "Terminal web frontend npm run dev is done" in spoken[-1]
    assert reads == []  # nothing was read or summarized on its own
    # Switching there does not play anything.
    await flow.on_ui_event({"name": "surface.focused", "category": "surface", "surface_id": "S-B2", "workspace_id": "WS-B"})
    assert flow.spoken == ["callout", "callout"] and flow.focused_surface_id == "S-B2"
    # "Yes" -> the newest finished terminal is read and handed to the model with next-step instructions.
    res = await flow.summarize(None)
    assert res["ok"] and res["terminal"] == "web frontend npm run dev" and "created three files" in res["say"]
    assert "Next, you could tell it to" in res["say"] and "Next, you could tell it to" in res["reply"]
    assert reads == ["S-B2"] and flow.spoken == ["callout", "callout", "recap"]
    # The other one is still waiting; asking by name finds it.
    res = await flow.summarize("vim")
    assert res["ok"] and reads == ["S-B2", "S-B1"]
    # Nothing pending: an unnamed request reads the focused terminal; a name that matches nothing says so.
    res = await flow.summarize(None)
    assert res["ok"] and res["terminal"] == "this terminal" and reads[-1] is None
    assert (await flow.summarize("nope"))["ok"] is False
    client.close()


async def test_completion_flow_refreshes_name_cache_on_structure_events(fake: FakeCmux):
    from cmux_voice.completion_flow import CompletionFlow
    client = CmuxClient(fake.path, allowed_methods=ALLOWED_METHODS)
    tools = VoiceTools(client, ConfirmationPolicy())

    async def speak(t): pass

    flow = CompletionFlow(tools, CompletionSummarizer(CmuxClient(fake.path)), speak)
    assert tools.state is None
    await flow.on_ui_event({"name": "workspace.renamed", "category": "workspace"})
    await flow.on_ui_event({"name": "workspace.created", "category": "workspace"})  # coalesced
    await asyncio.sleep(0.4)
    assert tools.state is not None
    assert fake.methods().count("system.tree") == 1
    client.close()


async def test_quit_agent_types_exit_and_waits_for_the_shell(tools: VoiceTools, fake: FakeCmux, monkeypatch):
    import cmux_voice.tools as t

    async def no_sleep(_):
        return None

    monkeypatch.setattr(t.asyncio, "sleep", no_sleep)
    frames = ["────\n❯ \n────\n", "────\n❯ \n────\n", "bye\nuser@host proj % "]
    reads = {"n": 0}
    base = fake.responder

    def responder(m, p):
        if m == "surface.read_text":
            reads["n"] += 1
            return {"text": frames[min(reads["n"] - 1, len(frames) - 1)]}
        return base(m, p)

    fake.responder = responder
    res = await tools.quit_agent()
    assert res["ok"] and "back at the shell" in res["say"]
    sent = [(r["params"].get("key") or r["params"].get("text")) for r in fake.requests if r["method"].startswith("surface.send_")]
    assert sent == ["ctrl-u", "/exit", "enter"]


async def test_quit_agent_when_none_open(tools: VoiceTools, fake: FakeCmux):
    base = fake.responder
    fake.responder = lambda m, p: {"text": "user@host proj % "} if m == "surface.read_text" else base(m, p)
    res = await tools.quit_agent()
    assert res["ok"] and res["already_closed"]


async def test_completion_flow_announces_once_per_turn_and_respects_the_off_switch(fake: FakeCmux):
    from cmux_voice.completion_flow import CompletionFlow
    client = CmuxClient(fake.path, allowed_methods=ALLOWED_METHODS)
    tools = VoiceTools(client, ConfirmationPolicy())
    spoken = []

    async def speak(t): spoken.append(t)

    flow = CompletionFlow(tools, CompletionSummarizer(CmuxClient(fake.path)), speak, settle_s=0)
    await flow.on_agent_completion(_stop("S-B1", seq=9))
    await flow.on_agent_completion(_stop("S-B1", seq=10))  # Stop then SessionEnd within a second: one callout
    assert flow.spoken == ["callout"]
    off = CompletionFlow(tools, CompletionSummarizer(CmuxClient(fake.path), enabled=False), speak, settle_s=0)
    await off.on_agent_completion(_stop("S-B2", seq=11))
    assert off.spoken == []
    client.close()


async def test_callouts_interrupt_the_model():
    """The callout is queued as an urgent user text, which the Ultravox service
    sends with urgency=immediate so it cuts into whatever is being said."""
    from cmux_voice.ultravox_service import CmuxUltravoxService, UrgentTextFrame

    class Stub(CmuxUltravoxService):
        def __init__(self):
            self._socket = object()
            self.sent = []
            self._name = "stub"

        async def _send(self, content):
            self.sent.append(content)

    svc = Stub()
    svc._pending_urgency = "immediate"
    await svc._send_user_text("[Agent finished]")
    svc._pending_urgency = None
    await svc._send_user_text("plain")
    assert svc.sent == [{"type": "user_text_message", "text": "[Agent finished]", "urgency": "immediate"},
                        {"type": "user_text_message", "text": "plain"}]
    assert UrgentTextFrame(text="x").urgency == "immediate"
