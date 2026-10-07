#!/usr/bin/env python3
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


FRAME_MAGIC = 0x41505431


def send_frame(connection, message_type, payload, magic=FRAME_MAGIC):
    data = json.dumps(payload).encode()
    connection.sendall(struct.pack("!IHHI", magic, 1, message_type, len(data)) + data)


def fake_status(instance_id, trace_directory):
    return {
        "instanceId": instance_id,
        "connectionSequence": 1,
        "pid": 4242,
        "processName": "Fake Agent",
        "bundleIdentifier": "com.example.fake",
        "architecture": "arm64e",
        "objcHookInstalled": True,
        "captureState": 0,
        "acceptedEvents": 0,
        "pendingBytes": 0,
        "writeFailures": 0,
        "traceDirectory": trace_directory,
    }


def raw_http(port, request_bytes):
    with socket.create_connection(("127.0.0.1", port), timeout=2) as connection:
        connection.sendall(request_bytes)
        response = bytearray()
        while True:
            try:
                chunk = connection.recv(8192)
            except ConnectionResetError:
                break
            if not chunk:
                break
            response.extend(chunk)
    status = int(response.split(b" ", 2)[1])
    body = bytes(response).split(b"\r\n\r\n", 1)[1]
    return status, json.loads(body) if body else None


def request(base, token, path, method="GET", payload=None, expected=200):
    data = None if payload is None else json.dumps(payload).encode()
    headers = {"Authorization": f"Bearer {token}"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=3) as response:
            assert response.status == expected, (response.status, expected)
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        assert error.code == expected, (error.code, expected, error.read())
        return json.loads(error.read())


def wait_until(predicate, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError("timed out waiting for daemon state")


def download(base, token, path):
    req = urllib.request.Request(base + path, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=3) as response:
        assert response.status == 200
        assert response.headers.get_content_type() == "application/octet-stream"
        return response.read()


def main():
    daemon_binary, agent_binary, console_path = sys.argv[1:]
    token = "host-control-test-token"
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]

    with tempfile.TemporaryDirectory() as directory:
        socket_path = os.path.join(directory, "appletraced.sock")
        daemon_log_path = os.path.join(directory, "daemon.log")
        with open(daemon_log_path, "wb") as daemon_log:
            environment = os.environ | {
                "APPLETRACE_DAEMON_SOCKET": socket_path,
                "APPLETRACE_CONTROL_PORT": str(port),
                "APPLETRACE_CONTROL_TOKEN": token,
                "APPLETRACE_CONSOLE_PATH": console_path,
                "APPLETRACE_AGENT_IDLE_TIMEOUT": "0.6",
                "APPLETRACE_AGENT_SEND_TIMEOUT": "0.3",
                "APPLETRACE_AGENT_MAX_SESSIONS": "2",
                "APPLETRACE_ARTIFACT_QUOTA_BYTES": "30",
                "APPLETRACE_ARTIFACT_MAX_FILES": "2",
                "APPLETRACE_ARTIFACT_SWEEP_INTERVAL": "0.2",
                "APPLETRACE_CONTROL_MAX_CLIENTS": "4",
            }
            daemon = subprocess.Popen([daemon_binary], env=environment, stdout=daemon_log, stderr=subprocess.STDOUT)
            agents = []
            try:
                base = f"http://127.0.0.1:{port}"

                def server_ready():
                    try:
                        with urllib.request.urlopen(base + "/", timeout=0.2) as response:
                            return response.status == 200 and b"AppleTrace" in response.read()
                    except Exception:
                        return False

                wait_until(server_ready)
                unauthorized = request(base, "wrong-token", "/api/v1/agents", expected=401)
                assert unauthorized == {"error": "unauthorized", "message": "A valid control token is required"}

                oversized_status, oversized = raw_http(
                    port, b"POST /api/v1/agents/x/filters HTTP/1.1\r\nContent-Length: 65537\r\n\r\n")
                assert oversized_status == 413 and oversized["error"] == "body_too_large"
                malformed_status, malformed = raw_http(
                    port, b"POST /api/v1/agents/x/filters HTTP/1.1\r\nContent-Length: nope\r\n\r\n")
                assert malformed_status == 400 and malformed["error"] == "invalid_content_length"
                header_status, header_error = raw_http(
                    port, b"GET / HTTP/1.1\r\nX-Fill: " + b"a" * 33000 + b"\r\n\r\n")
                assert header_status == 431 and header_error["error"] == "headers_too_large"

                blockers = []
                for _ in range(4):
                    blocker = socket.create_connection(("127.0.0.1", port), timeout=2)
                    blocker.sendall(b"GET /api/v1/agents HTTP/1.1\r\n")
                    blockers.append(blocker)
                time.sleep(0.1)
                busy_status, busy = raw_http(
                    port, b"GET /api/v1/agents HTTP/1.1\r\nAuthorization: Bearer " + token.encode() + b"\r\n\r\n")
                assert busy_status == 503 and busy["error"] == "server_busy"
                for blocker in blockers:
                    blocker.close()

                def client_capacity_recovered():
                    try:
                        return request(base, token, "/api/v1/agents") is not None
                    except AssertionError:
                        return False

                wait_until(client_capacity_recovered)

                for index in range(2):
                    trace_directory = os.path.join(directory, f"trace-{index}")
                    os.makedirs(trace_directory)
                    trace_bytes = f"trace-agent-{index}".encode()
                    with open(os.path.join(trace_directory, "trace.appletrace"), "wb") as trace_file:
                        trace_file.write(trace_bytes)
                    for name, age in (("old.appletrace", 30), ("middle.appletrace", 20)):
                        path = os.path.join(trace_directory, name)
                        with open(path, "wb") as trace_file:
                            trace_file.write(b"0123456789")
                        timestamp = time.time() - age
                        os.utime(path, (timestamp, timestamp))
                    agent_environment = os.environ | {
                        "APPLETRACE_DAEMON_SOCKET": socket_path,
                        "APPLETRACE_TEST_BUNDLE_ID": f"com.example.agent{index}",
                        "APPLETRACE_TEST_PROCESS_NAME": f"Agent {index}",
                        "APPLETRACE_TEST_TRACE_DIR": trace_directory,
                        "APPLETRACE_AGENT_HEARTBEAT_INTERVAL": "0.15",
                        "APPLETRACE_TEST_MIN_RUNTIME": "1.2",
                    }
                    agents.append(subprocess.Popen([agent_binary], env=agent_environment))

                def two_agents():
                    payload = request(base, token, "/api/v1/agents")
                    return payload if len(payload["agents"]) == 2 else None

                listing = wait_until(two_agents)
                assert listing["protocolVersion"] == 1
                assert {agent["bundleIdentifier"] for agent in listing["agents"]} == {
                    "com.example.agent0", "com.example.agent1"
                }
                assert all(agent["architecture"] in {"arm64", "arm64e", "x86_64"}
                           for agent in listing["agents"])
                assert all(agent["objcHookInstalled"] is True for agent in listing["agents"])
                first_seen = {agent["id"]: agent["lastSeenAt"] for agent in listing["agents"]}
                time.sleep(0.4)
                heartbeat_listing = request(base, token, "/api/v1/agents")["agents"]
                assert all(agent["lastSeenAt"] > first_seen[agent["id"]] for agent in heartbeat_listing)
                assert all(agent["connectionCount"] == 1 for agent in heartbeat_listing)

                for agent in listing["agents"]:
                    identifier = agent["id"]
                    detail = request(base, token, f"/api/v1/agents/{identifier}")
                    assert detail["connected"] is True, detail
                    artifacts = request(base, token, f"/api/v1/agents/{identifier}/artifacts")
                    assert {artifact["name"] for artifact in artifacts} == {
                        "middle.appletrace", "trace.appletrace"
                    }
                    assert not os.path.exists(os.path.join(detail["traceDirectory"], "old.appletrace"))
                    expected_trace = f"trace-agent-{detail['bundleIdentifier'][-1]}".encode()
                    assert download(base, token, f"/api/v1/agents/{identifier}/artifacts/trace.appletrace") == expected_trace
                    for action in ("start", "filters", "flush", "stop"):
                        payload = ({"allowClassPrefixes": ["APTAllowed"], "denyClassPrefixes": ["APTDeny"]}
                                   if action == "filters" else None)
                        accepted = request(base, token, f"/api/v1/agents/{identifier}/{action}",
                                           method="POST", payload=payload, expected=202)
                        assert accepted == {"accepted": True, "agentId": identifier}
                    invalid = request(base, token, f"/api/v1/agents/{identifier}/filters",
                                      method="POST", payload={"allowClassPrefixes": "not-an-array"},
                                      expected=400)
                    assert invalid["error"] == "invalid_filters"

                for agent in agents:
                    assert agent.wait(timeout=8) == 0
                agents.clear()
                wait_until(lambda: len(request(base, token, "/api/v1/agents")["agents"]) == 0)
                request(base, token, "/api/v1/agents/missing", expected=404)

                agent_blockers = []
                for _ in range(2):
                    blocker = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    blocker.connect(socket_path)
                    agent_blockers.append(blocker)
                time.sleep(0.1)
                overflow = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                overflow.connect(socket_path)
                try:
                    send_frame(overflow, 1, fake_status("overflow-agent", directory))
                except BrokenPipeError:
                    pass
                time.sleep(0.1)
                assert all(agent["id"] != "overflow-agent"
                           for agent in request(base, token, "/api/v1/agents")["agents"])
                overflow.close()
                for blocker in agent_blockers:
                    blocker.close()
                time.sleep(0.1)

                stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                stale.connect(socket_path)
                send_frame(stale, 1, fake_status("stale-agent", directory))
                wait_until(lambda: any(agent["id"] == "stale-agent"
                                       for agent in request(base, token, "/api/v1/agents")["agents"]))
                wait_until(lambda: all(agent["id"] != "stale-agent"
                                       for agent in request(base, token, "/api/v1/agents")["agents"]), timeout=3)
                stale.close()

                reconnect = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                reconnect.connect(socket_path)
                send_frame(reconnect, 1, fake_status("reconnect-agent", directory))
                first = wait_until(lambda: next((agent for agent in request(base, token, "/api/v1/agents")["agents"]
                                                 if agent["id"] == "reconnect-agent"), None))
                assert first["connectionCount"] == 1
                reconnect.close()
                wait_until(lambda: all(agent["id"] != "reconnect-agent"
                                       for agent in request(base, token, "/api/v1/agents")["agents"]))
                reconnect = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                reconnect.connect(socket_path)
                send_frame(reconnect, 1, fake_status("reconnect-agent", directory))
                second = wait_until(lambda: next((agent for agent in request(base, token, "/api/v1/agents")["agents"]
                                                  if agent["id"] == "reconnect-agent"), None))
                assert second["connectionCount"] == 2
                reconnect.close()

                blocked = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                blocked.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
                blocked.connect(socket_path)
                send_frame(blocked, 1, fake_status("blocked-agent", directory))
                wait_until(lambda: any(agent["id"] == "blocked-agent"
                                       for agent in request(base, token, "/api/v1/agents")["agents"]))
                large_filters = {"allowClassPrefixes": ["A" * 240 for _ in range(240)],
                                 "denyClassPrefixes": []}
                started = time.monotonic()
                unavailable = request(base, token, "/api/v1/agents/blocked-agent/filters",
                                      method="POST", payload=large_filters, expected=503)
                assert unavailable["error"] == "agent_unavailable"
                assert time.monotonic() - started < 1.5
                blocked.close()

                malformed_agent = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                malformed_agent.connect(socket_path)
                send_frame(malformed_agent, 1, {}, magic=0xDEADBEEF)
                malformed_agent.close()
                assert request(base, token, "/api/v1/agents")["protocolVersion"] == 1
            finally:
                for agent in agents:
                    agent.terminate()
                    agent.wait(timeout=3)
                daemon.terminate()
                daemon.wait(timeout=3)

    print("jailbreak multi-Agent control server test passed")


if __name__ == "__main__":
    main()
