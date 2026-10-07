export interface TraceMetrics {
  acceptedEvents: number;
  pendingBytes: number;
  writeFailures: number;
}

export interface AgentStatus {
  protocolVersion: number;
  processId: number;
  processName: string;
  bundleIdentifier?: string;
  architecture: string;
  captureState: string;
  objcHookInstalled: boolean;
  traceDirectory: string;
  metrics: TraceMetrics;
}

export interface Artifact {
  name: string;
  size: number;
  modifiedAt: string | number;
}

export interface DaemonAgent {
  id: string;
  instanceId: string;
  connectionSequence: number;
  connectionCount: number;
  connected: boolean;
  connectedAt: number;
  lastSeenAt: number;
  pid: number;
  processName: string;
  bundleIdentifier: string;
  architecture: string;
  objcHookInstalled: boolean;
  captureState: number;
  acceptedEvents: number;
  pendingBytes: number;
  writeFailures: number;
  traceDirectory: string;
}

export interface AgentList { protocolVersion: number; agents: DaemonAgent[]; }

export interface Filters {
  allowClassPrefixes: string[];
  denyClassPrefixes: string[];
}

function tokenFromLocation(): string {
  const hash = new URLSearchParams(window.location.hash.replace(/^#/, ""));
  const supplied = hash.get("token");
  if (supplied) {
    sessionStorage.setItem("appletrace-token", supplied);
    history.replaceState(null, "", window.location.pathname);
    return supplied;
  }
  return sessionStorage.getItem("appletrace-token") ?? "";
}

export class AppleTraceAPI {
  token = tokenFromLocation();

  private async request<T>(path: string, init: RequestInit = {}): Promise<T> {
    const response = await fetch(path, {
      ...init,
      headers: {
        "Authorization": `Bearer ${this.token}`,
        "Content-Type": "application/json",
        ...init.headers,
      },
    });
    if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
    return response.json() as Promise<T>;
  }

  status() { return this.request<AgentStatus>("/api/v1/status"); }
  agents() { return this.request<AgentList>("/api/v1/agents"); }
  artifacts() { return this.request<Artifact[]>("/api/v1/artifacts"); }
  start() { return this.request<AgentStatus>("/api/v1/capture/start", { method: "POST" }); }
  stop() { return this.request<AgentStatus>("/api/v1/capture/stop", { method: "POST" }); }
  setFilters(filters: Filters) {
    return this.request<Filters>("/api/v1/filters", { method: "POST", body: JSON.stringify(filters) });
  }

  agentCommand(id: string, command: "start" | "stop" | "flush") {
    return this.request<{ accepted: boolean; agentId: string }>(
      `/api/v1/agents/${encodeURIComponent(id)}/${command}`,
      { method: "POST" },
    );
  }

  setAgentFilters(id: string, filters: Filters) {
    return this.request<{ accepted: boolean; agentId: string }>(
      `/api/v1/agents/${encodeURIComponent(id)}/filters`,
      { method: "POST", body: JSON.stringify(filters) },
    );
  }

  agentArtifacts(id: string) {
    return this.request<Artifact[]>(`/api/v1/agents/${encodeURIComponent(id)}/artifacts`);
  }

  statusStream(): WebSocket {
    const scheme = window.location.protocol === "https:" ? "wss:" : "ws:";
    const url = `${scheme}//${window.location.host}/api/v1/stream`;
    return new WebSocket(url, ["appletrace-v1", `appletrace-token.${this.token}`]);
  }

  async download(name: string) {
    return this.downloadAt(`/api/v1/artifacts/${encodeURIComponent(name)}`, name);
  }

  async downloadAgentArtifact(id: string, name: string) {
    return this.downloadAt(
      `/api/v1/agents/${encodeURIComponent(id)}/artifacts/${encodeURIComponent(name)}`,
      name,
    );
  }

  private async downloadAt(path: string, name: string) {
    const response = await fetch(path, {
      headers: { "Authorization": `Bearer ${this.token}` },
    });
    if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
    const blob = await response.blob();
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = name;
    anchor.click();
    URL.revokeObjectURL(url);
  }
}
