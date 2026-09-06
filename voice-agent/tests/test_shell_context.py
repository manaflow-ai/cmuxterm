from __future__ import annotations

import os
import subprocess

import pytest

from cmux_voice import shell_context as sc


@pytest.fixture
def tree(tmp_path):
    for rel in ["work/staff-portal", "work/archive/Staff-Portal", "work/dmux/cmux/voice-agent", "work/dmux/cmux/node_modules/junk", "other/notes"]:
        (tmp_path / rel).mkdir(parents=True)
    return tmp_path


def test_find_exact_beats_substring_and_skips_node_modules(tree, monkeypatch):
    monkeypatch.setattr(sc, "_run", lambda cmd, timeout=3.0: "")  # no Spotlight in tests
    found = sc.find_directories("staff-portal", roots=[str(tree)])
    assert found[0] == str(tree / "work/staff-portal")
    assert str(tree / "work/archive/Staff-Portal") in found
    assert not any("node_modules" in p for p in found)
    assert sc.find_directories("junk", roots=[str(tree)]) == []


def test_find_prefers_cwd_relative(tree, monkeypatch):
    monkeypatch.setattr(sc, "_run", lambda cmd, timeout=3.0: "")
    found = sc.find_directories("voice agent", cwd=str(tree / "work/dmux/cmux"), roots=[str(tree)])
    assert found[0] == str(tree / "work/dmux/cmux/voice-agent")


def test_parent_filter_disambiguates(tree, monkeypatch):
    monkeypatch.setattr(sc, "_run", lambda cmd, timeout=3.0: "")
    found = sc.find_directories("staff portal", parent="archive", roots=[str(tree)])
    assert found == [str(tree / "work/archive/Staff-Portal")]


def test_absolute_and_tilde_paths(tree, monkeypatch):
    monkeypatch.setattr(sc, "_run", lambda cmd, timeout=3.0: "")
    found = sc.find_directories(str(tree / "other/notes"), roots=[str(tree)])
    assert found[0] == str(tree / "other/notes")


def test_cd_command_quotes():
    assert sc.cd_command("/a b/c's") == "cd '/a b/c'\"'\"'s'"


def test_cwd_for_tty_uses_lsof(monkeypatch):
    calls = []

    def fake_run(cmd, timeout=3.0):
        calls.append(cmd)
        if cmd[0] == "ps":
            return "100\n101\n"
        if cmd[0] == "lsof" and cmd[3] == "101":
            return "p101\nfcwd\nn/Users/me/proj\n"
        return ""

    monkeypatch.setattr(sc, "_run", fake_run)
    assert sc.cwd_for_tty("ttys021") == "/Users/me/proj"
    assert sc.cwd_for_tty(None) is None


def test_shell_context_git_branch(tmp_path):
    if subprocess.run(["git", "--version"], capture_output=True).returncode != 0:
        pytest.skip("git not available")
    subprocess.run(["git", "init", "-q", "-b", "feature/x", str(tmp_path)], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"], check=True)
    ctx = sc.shell_context(None, fallback_cwd=str(tmp_path))
    assert ctx.cwd == str(tmp_path)
    assert ctx.git_branch == "feature/x"
    assert "feature/x" in ctx.summary()
