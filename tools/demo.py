#!/usr/bin/env python3
"""Record and verify real Emacs keystrokes as an asciicast v2.

emacsclient is used only to inspect state and shut down.  Demonstrated commands are sent
as keyboard bytes to Emacs running in a PTY.  Run prepare-demo.py first.
"""

import codecs
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import termios
import time
import traceback

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / ".runtime"
DEMO = RUNTIME / "demo"


class Recording:
    def __init__(self):
        self.started = time.monotonic()
        self.timestamp = int(time.time())
        self.events = []
        self.keys = []
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.server = str(DEMO / "sockets" / "multihost-demo")
        home = DEMO / "home"
        home.mkdir(exist_ok=True)
        self.env = dict(os.environ, HOME=str(home), TERM="xterm-256color", LC_ALL="C.UTF-8",
                        PATH=str(RUNTIME / "lab" / "bin") + os.pathsep + os.environ["PATH"])
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(ROOT)
            os.execvpe(os.environ.get("EMACS", "emacs"),
                       [os.environ.get("EMACS", "emacs"), "-Q", "-nw", "-l", str(ROOT / "tools/demo-init.el")], self.env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 34, 120, 0, 0))
        self.pump(1.5)
        for _ in range(40):
            try:
                assert self.evaluate("(and vertico-mode marginalia-mode ob-multihost-mode)") == "t"
                break
            except (AssertionError, RuntimeError):
                self.pump(0.2)
        else:
            self.close()
            raise RuntimeError("Demo Emacs failed to initialize; inspect the recording")

    def pump(self, duration):
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.fd], [], [], min(0.05, max(0, deadline - time.monotonic())))
            if ready:
                try:
                    data = os.read(self.fd, 65536)
                except OSError:
                    return
                if not data:
                    return
                text = self.decoder.decode(data)
                if text:
                    self.events.append([round(time.monotonic() - self.started, 4), "o", text])

    def key(self, data, label, pause=0.35):
        if isinstance(data, str):
            data = data.encode()
        moment = round(time.monotonic() - self.started, 4)
        self.keys.append({"at": moment, "keys": label, "input_hex": data.hex()})
        self.events.append([moment, "i", data.decode("utf-8", errors="replace")])
        os.write(self.fd, data)
        self.pump(pause)

    def mx(self, command):
        self.key(b"\x1bx", "M-x", 0.3)
        self.key(command, command, 0.65)
        self.key(b"\r", "RET", 0.55)

    def evaluate(self, expression):
        process = subprocess.run(["emacsclient", "-s", self.server, "--eval", expression],
                                 env=self.env, capture_output=True, text=True, timeout=10)
        if process.returncode:
            raise RuntimeError(process.stderr.strip())
        return process.stdout.strip()

    def query(self, expression):
        return json.loads(json.loads(self.evaluate("(json-encode " + expression + ")")))

    def snapshot(self):
        return self.query("""(with-current-buffer (window-buffer (selected-window))
           `((buffer . ,(buffer-name)) (mode . ,(symbol-name major-mode))
             (vertico . ,(if vertico-mode t :json-false))
             (marginalia . ,(if marginalia-mode t :json-false))
             (text . ,(buffer-substring-no-properties (point-min) (point-max)))))""")

    def run(self):
        return self.query("""(with-current-buffer (window-buffer (selected-window))
          (when multihost--run
            (let ((run multihost--run))
              `((id . ,(multihost-run-id run))
                (state . ,(symbol-name (multihost-run-state run)))
                (concurrency . ,(multihost-run-concurrency run))
                (jobs . ,(vconcat (mapcar
                 (lambda (job)
                   `((host . ,(multihost-host-name (multihost-job-host job)))
                     (status . ,(symbol-name (multihost-job-status job)))
                     (exit . ,(multihost-job-exit-code job))
                     (stdout . ,(multihost-job-stdout job))
                     (stderr . ,(multihost-job-stderr job))
                     (error . ,(multihost-job-error job))
                     (started . ,(multihost-job-started-at job))
                     (ended . ,(multihost-job-ended-at job))))
                 (multihost-run-jobs run))))))))""")

    def wait_run(self):
        deadline = time.monotonic() + 35
        while time.monotonic() < deadline:
            state = self.run()
            if state and state["state"] not in ("queued", "running", "created"):
                self.pump(0.5)
                return self.run()
            self.pump(0.25)
        raise AssertionError("Run did not finish within 35 seconds")

    def switch(self, buffer):
        self.key(b"\x18b", "C-x b")
        self.key(buffer, "buffer: " + buffer, 0.3)
        self.key(b"\r", "RET", 0.3)
        self.key(b"\x181", "C-x 1", 0.5)

    def search(self, text):
        self.key(b"\x13", "C-s", 0.2)
        self.key(text, "search: " + text, 0.2)
        self.key(b"\r", "RET", 0.2)

    def execute_org_block(self):
        self.search("#+begin_src sh")
        self.key(b"\x01", "C-a", 0.2)
        self.key(b"\x03\x03", "C-c C-c", 0.6)
        assert self.evaluate("(minibufferp (window-buffer (active-minibuffer-window)))") == "t"
        self.key("yes", "Org execution approval: yes", 0.25)
        self.key(b"\r", "RET", 0.4)
        self.key(b"\x181", "C-x 1", 0.3)
        return self.wait_run()

    def close(self):
        try:
            self.evaluate("(kill-emacs)")
        except (RuntimeError, subprocess.SubprocessError):
            pass
        self.pump(0.2)
        try:
            os.kill(self.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass
        os.close(self.fd)
        header = {"version": 2, "width": 120, "height": 34, "timestamp": self.timestamp,
                  "title": "Multihost: real Emacs, Org, TRAMP, Vertico and Marginalia",
                  "env": {"TERM": "xterm-256color", "SHELL": "/bin/sh"}}
        (ROOT / "recordings").mkdir(exist_ok=True)
        (ROOT / "recordings/demo.cast").write_text("\n".join(json.dumps(item, ensure_ascii=False)
                                                            for item in [header] + self.events) + "\n")
        (ROOT / "docs/demo-keys.json").write_text(json.dumps(self.keys, indent=2) + "\n")


def demonstrate(recording):
    evidence = {"vertico": True, "marginalia": True, "transport": "two loopback SSH endpoints, one kernel",
                "cyberark_tested": False, "checks": [], "runs": [], "snapshots": []}
    recording.evidence = evidence
    source_pattern = re.compile(r"^#\+begin_src[^\n]*\n(.*?)^#\+end_src", re.M | re.S | re.I)
    original_bodies = source_pattern.findall((DEMO / "runbook.org").read_text())
    def capture(label):
        snapshot = recording.snapshot()
        assert snapshot["vertico"] and snapshot["marginalia"]
        evidence["snapshots"].append(dict(label=label, **snapshot))
        return snapshot

    recording.pump(1.5)
    recording.mx("multihost")
    recording.key(b"\x181", "C-x 1")
    inventory = capture("inventory")
    assert "web-01" in inventory["text"] and "db-01" in inventory["text"]
    recording.key("T", "T — mark every inventory host", 0.7)
    assert recording.evaluate("(with-current-buffer (window-buffer (selected-window)) (length multihost--marks))") == "2"
    recording.key("x", "x — run command", 0.4)
    recording.key("cat status.txt", "cat status.txt", 0.6)
    recording.key(b"\r", "RET — execute on marked hosts", 0.3)
    recording.key(b"\x181", "C-x 1")
    parallel = recording.wait_run()
    assert parallel["state"] == "finished" and parallel["concurrency"] == 2
    assert all(job["status"] == "succeeded" for job in parallel["jobs"])
    assert [job["host"] for job in parallel["jobs"]] == ["web-01", "db-01"]
    assert "role=web" in parallel["jobs"][0]["stdout"] and "role=db" in parallel["jobs"][1]["stdout"]
    evidence["runs"].append(dict(label="inventory parallel check", **parallel))
    evidence["checks"].append("Inventory marking and parallel execution on both real SSH endpoints")
    dashboard = capture("parallel dashboard")["buffer"]
    recording.pump(1)
    recording.key(b"\x1b<", "M-<")
    recording.key(b"\r", "RET — separate host output", 0.5)
    recording.key(b"\x181", "C-x 1")
    assert "role=web" in capture("one host output")["text"]
    recording.pump(1)
    recording.switch(dashboard)
    recording.key("a", "a — combined output", 0.5)
    recording.key(b"\x181", "C-x 1")
    combined = capture("combined output")["text"]
    assert "role=web" in combined and "role=db" in combined
    recording.pump(1)
    recording.switch(dashboard)
    recording.key("d", "d — digest", 0.5)
    recording.key(b"\x181", "C-x 1")
    assert "role=web" in capture("digest")["text"]
    evidence["checks"].append("RET, a and d open separate, combined and digest result buffers")

    recording.key(b"\x18\x06", "C-x C-f — open the Org runbook")
    recording.key(str(DEMO / "runbook.org"), "runbook.org", 0.4)
    recording.key(b"\r", "RET", 0.5)
    recording.key(b"\x181", "C-x 1")
    recording.key(b"\x1b<", "M-<")
    capture("runbook before execution")
    serial = recording.execute_org_block()
    assert serial["state"] == "finished" and serial["concurrency"] == 1
    assert all(job["status"] == "succeeded" for job in serial["jobs"])
    assert [job["host"] for job in serial["jobs"]] == ["db-01", "web-01"]
    assert serial["jobs"][0]["ended"] <= serial["jobs"][1]["started"]
    evidence["runs"].append(dict(label="serial Org runbook", **serial))
    capture("serial dashboard")
    recording.pump(1)
    recording.switch("runbook.org")
    recording.key(b"\x1b<", "M-<")
    result = capture("Org inserted combined results")
    assert "#+RESULTS:" in result["text"] and "check completed" in result["text"]
    recording.pump(1)
    recording.search("Intentional failure")
    failure = recording.execute_org_block()
    assert failure["state"] == "finished"
    assert [job["status"] for job in failure["jobs"]] == ["succeeded", "failed"]
    assert failure["jobs"][1]["exit"] == 7 and "database check failed" in failure["jobs"][1]["stderr"]
    evidence["runs"].append(dict(label="intentional Org failure", **failure))
    capture("failure dashboard")
    recording.pump(1)
    recording.key(b"\x1b<", "M-<")
    recording.key(b"\x0e", "C-n — select db-01")
    recording.key(b"\r", "RET — inspect failed host", 0.5)
    recording.key(b"\x181", "C-x 1")
    assert "database check failed" in capture("stderr and exit 7")["text"]
    recording.pump(1.5)
    recording.switch("runbook.org")
    recording.key(b"\x1b>", "M-> — inspect final Org summary", 0.6)
    final = capture("Org final table")
    assert "failed" in final["text"] and "succeeded" in final["text"]
    assert source_pattern.findall(final["text"]) == original_bodies
    evidence["org_source_unchanged"] = True
    evidence["checks"].extend(["C-c C-c preserves Org execution confirmation", "Serial Org execution preserves db-01 then web-01 order",
                                "Combined and table renderers insert results into the originating Org block",
                                "A real remote exit 7 remains failed, with separate stderr"])
    recording.pump(2)
    return evidence


def main():
    subprocess.run(["python3", str(ROOT / "tools/prepare-demo.py")], check=True)
    source_files = list(ROOT.glob("*.el"))
    before = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in source_files}
    recording = None
    evidence = {"passed": False}
    try:
        subprocess.run(["python3", str(ROOT / "tools/lab.py"), "start"], check=True)
        recording = Recording()
        evidence = demonstrate(recording)
        after = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in source_files}
        assert before == after, "Project source changed during the recorded scenario"
        evidence.update(passed=True, source_sha256=after, source_unchanged=True)
    except BaseException as error:
        evidence = getattr(recording, "evidence", evidence)
        evidence.update(passed=False, error=str(error), traceback=traceback.format_exc())
        raise
    finally:
        if recording:
            evidence["duration_seconds"] = round(time.monotonic() - recording.started, 3)
            recording.close()
        subprocess.run(["python3", str(ROOT / "tools/lab.py"), "stop"], check=True)
        (ROOT / "docs/demo-results.json").write_text(json.dumps(evidence, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
