import { Activity, Download, Play, RotateCcw, ScanLine, Settings2, Square } from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { AppleTraceAPI, type AgentStatus, type Artifact, type DaemonAgent } from "./api";
import { Badge, Button, Card, Metric } from "./components";
import { formatBytes } from "./lib";

type View = "overview" | "traces" | "settings";
type Mode = "detecting" | "embedded" | "daemon";

const captureStates = ["idle", "starting", "recording", "stopping", "finalizing"];

function statusFromAgent(agent: DaemonAgent): AgentStatus {
  return {
    protocolVersion: 1,
    processId: agent.pid,
    processName: agent.processName,
    bundleIdentifier: agent.bundleIdentifier,
    architecture: agent.architecture,
    captureState: captureStates[agent.captureState] ?? "unknown",
    objcHookInstalled: agent.objcHookInstalled,
    traceDirectory: agent.traceDirectory,
    metrics: {
      acceptedEvents: agent.acceptedEvents,
      pendingBytes: agent.pendingBytes,
      writeFailures: agent.writeFailures,
    },
  };
}

function artifactDate(value: string | number): Date {
  return new Date(typeof value === "number" ? value * 1000 : value);
}

export default function App() {
  const api = useMemo(() => new AppleTraceAPI(), []);
  const [mode, setMode] = useState<Mode>("detecting");
  const [view, setView] = useState<View>("overview");
  const [status, setStatus] = useState<AgentStatus>();
  const [agents, setAgents] = useState<DaemonAgent[]>([]);
  const [selectedAgentId, setSelectedAgentId] = useState("");
  const [artifacts, setArtifacts] = useState<Artifact[]>([]);
  const [allow, setAllow] = useState("");
  const [deny, setDeny] = useState("");
  const [error, setError] = useState("");

  const refreshEmbedded = useCallback(async () => {
    const [nextStatus, nextArtifacts] = await Promise.all([api.status(), api.artifacts()]);
    setStatus(nextStatus);
    setArtifacts(nextArtifacts);
    setError("");
  }, [api]);

  const refreshDaemon = useCallback(async () => {
    const listing = await api.agents();
    setAgents(listing.agents);
    const selected = listing.agents.find((agent) => agent.id === selectedAgentId) ?? listing.agents[0];
    if (!selected) {
      setSelectedAgentId("");
      setStatus(undefined);
      setArtifacts([]);
      setError("");
      return;
    }
    if (selected.id !== selectedAgentId) setSelectedAgentId(selected.id);
    setStatus(statusFromAgent(selected));
    setArtifacts(await api.agentArtifacts(selected.id));
    setError("");
  }, [api, selectedAgentId]);

  useEffect(() => {
    void api.agents().then((listing) => {
      setMode("daemon");
      setAgents(listing.agents);
      if (listing.agents[0]) setSelectedAgentId(listing.agents[0].id);
    }).catch(() => setMode("embedded"));
  }, [api]);

  useEffect(() => {
    if (mode !== "embedded") return;
    void refreshEmbedded().catch(() => setError("Disconnected"));
    let stream: WebSocket | undefined;
    let reconnectTimer: number | undefined;
    let disposed = false;
    const connect = () => {
      stream = api.statusStream();
      stream.onopen = () => setError("");
      stream.onmessage = (event) => {
        try { setStatus(JSON.parse(String(event.data)) as AgentStatus); setError(""); }
        catch (caught) { console.debug("AppleTrace stream payload failed", caught); }
      };
      stream.onerror = () => setError("Disconnected");
      stream.onclose = () => {
        if (!disposed) {
          setError("Disconnected");
          reconnectTimer = window.setTimeout(connect, 1500);
        }
      };
    };
    connect();
    const artifactTimer = window.setInterval(() => {
      void api.artifacts().then(setArtifacts).catch(() => {});
    }, 5000);
    return () => {
      disposed = true;
      stream?.close();
      if (reconnectTimer !== undefined) window.clearTimeout(reconnectTimer);
      window.clearInterval(artifactTimer);
    };
  }, [api, mode, refreshEmbedded]);

  useEffect(() => {
    if (mode !== "daemon") return;
    const update = () => void refreshDaemon().catch((caught) => {
      console.debug("appletraced refresh failed", caught);
      setError("Disconnected");
    });
    update();
    const timer = window.setInterval(update, 1000);
    return () => window.clearInterval(timer);
  }, [mode, refreshDaemon]);

  async function command(action: "start" | "stop") {
    try {
      if (mode === "daemon" && selectedAgentId) {
        await api.agentCommand(selectedAgentId, action);
        window.setTimeout(() => void refreshDaemon(), 100);
      } else {
        setStatus(action === "start" ? await api.start() : await api.stop());
        await refreshEmbedded();
      }
    } catch (caught) {
      console.debug("AppleTrace command failed", caught);
      setError("Disconnected");
    }
  }

  async function saveFilters() {
    const split = (value: string) => value.split(",").map((item) => item.trim()).filter(Boolean);
    const filters = { allowClassPrefixes: split(allow), denyClassPrefixes: split(deny) };
    if (mode === "daemon" && selectedAgentId) await api.setAgentFilters(selectedAgentId, filters);
    else await api.setFilters(filters);
  }

  async function refresh() {
    try {
      if (mode === "daemon") await refreshDaemon();
      else await refreshEmbedded();
    } catch { setError("Disconnected"); }
  }

  const recording = status?.captureState === "recording";
  const selectedAgent = agents.find((agent) => agent.id === selectedAgentId);

  return <div className="shell">
    <aside>
      <div className="brand"><ScanLine size={18} /><span>AppleTrace</span></div>
      <nav>
        <button className={view === "overview" ? "active" : ""} onClick={() => setView("overview")}><Activity />Overview</button>
        <button className={view === "traces" ? "active" : ""} onClick={() => setView("traces")}><Download />Traces</button>
        <button className={view === "settings" ? "active" : ""} onClick={() => setView("settings")}><Settings2 />Settings</button>
      </nav>
      <div className="sidebar-foot">{mode === "daemon" ? `${agents.length} connected processes` : `Protocol v${status?.protocolVersion ?? 1}`}</div>
    </aside>

    <main>
      <header>
        <div><h1>{status?.processName ?? (mode === "daemon" ? "No connected apps" : "Waiting for agent")}</h1><p>{status?.bundleIdentifier ?? (mode === "daemon" ? "appletraced control session" : "Local control session")}</p></div>
        <div className="header-actions">
          {mode === "daemon" && <select aria-label="Target process" value={selectedAgentId} onChange={(event) => setSelectedAgentId(event.target.value)}>
            {agents.map((agent) => <option value={agent.id} key={agent.id}>{agent.processName} · {agent.pid}</option>)}
          </select>}
          <Badge tone={error ? "warn" : "good"}>{error || (mode === "detecting" ? "Connecting" : selectedAgent?.connected === false ? "Offline" : "Connected")}</Badge>
        </div>
      </header>

      {view === "overview" && <>
        <section className="hero card">
          <div><span className="eyebrow">Capture</span><h2>{recording ? "Recording" : status?.captureState ?? "Idle"}</h2><p>{status?.architecture ?? "—"} · PID {status?.processId ?? "—"} · objc hook {status?.objcHookInstalled ? "active" : "inactive"}</p></div>
          <Button disabled={!status} onClick={() => void command(recording ? "stop" : "start")} className={recording ? "danger" : "primary"}>
            {recording ? <Square /> : <Play />}{recording ? "Stop capture" : "Start capture"}
          </Button>
        </section>
        <section className="metrics">
          <Metric label="Accepted events" value={(status?.metrics.acceptedEvents ?? 0).toLocaleString()} />
          <Metric label="Pending" value={formatBytes(status?.metrics.pendingBytes ?? 0)} />
          <Metric label="Write failures" value={(status?.metrics.writeFailures ?? 0).toLocaleString()} />
          <Metric label="Artifacts" value={String(artifacts.length)} />
        </section>
      </>}

      {view === "traces" && <Card>
        <div className="section-title"><div><h2>Trace artifacts</h2><p>Download and open in Perfetto.</p></div><Button onClick={() => void refresh()}><RotateCcw />Refresh</Button></div>
        <div className="table">
          {artifacts.length === 0 && <div className="empty">No trace artifacts yet.</div>}
          {artifacts.map((artifact) => <div className="row" key={artifact.name}>
            <div><strong>{artifact.name}</strong><span>{artifactDate(artifact.modifiedAt).toLocaleString()}</span></div>
            <span>{formatBytes(artifact.size)}</span>
            <Button onClick={() => void (mode === "daemon" && selectedAgentId ? api.downloadAgentArtifact(selectedAgentId, artifact.name) : api.download(artifact.name))}><Download />Download</Button>
          </div>)}
        </div>
      </Card>}

      {view === "settings" && <Card className="settings">
        <div className="section-title"><div><h2>Class filters</h2><p>Comma-separated Objective-C class prefixes for the selected process.</p></div></div>
        <label>Allow prefixes<input value={allow} onChange={(event) => setAllow(event.target.value)} placeholder="MyApp, Checkout" /></label>
        <label>Deny prefixes<input value={deny} onChange={(event) => setDeny(event.target.value)} placeholder="UIKit, SwiftUI" /></label>
        <Button disabled={!status} className="primary" onClick={() => void saveFilters()}>Save filters</Button>
        <div className="path"><span>Trace directory</span><code>{status?.traceDirectory ?? "—"}</code></div>
      </Card>}
    </main>
  </div>;
}
