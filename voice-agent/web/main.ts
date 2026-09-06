/**
 * Hidden audio shim loaded by cmux's WKWebView.
 *
 * Owns the microphone and the WebRTC connection to the local Pipecat sidecar.
 * Draws nothing. Talks to Swift through `window.webkit.messageHandlers.cmuxVoice`
 * and exposes `window.cmuxVoice` for Swift to call via evaluateJavaScript.
 */
import { PipecatClient, RTVIEvent } from "@pipecat-ai/client-js";
import type { TransportState } from "@pipecat-ai/client-js";
import { SmallWebRTCTransport } from "@pipecat-ai/small-webrtc-transport";

type Outbound =
  | { type: "status"; status: string; message?: string }
  | { type: "transcript"; role: "user" | "agent"; text: string; final: boolean }
  | { type: "tool"; name: string; phase: "started" | "finished"; args?: unknown; result?: unknown }
  | { type: "server"; data: unknown }
  | { type: "error"; message: string }
  | { type: "mic"; muted: boolean };

declare global {
  interface Window {
    webkit?: { messageHandlers?: { cmuxVoice?: { postMessage: (m: Outbound) => void } } };
    cmuxVoice?: { start: () => void; stop: () => void; setMuted: (muted: boolean) => void };
  }
}

const post = (m: Outbound) => {
  try {
    window.webkit?.messageHandlers?.cmuxVoice?.postMessage(m);
  } catch {
    /* not inside cmux */
  }
  if (!window.webkit) console.log("[cmuxVoice]", JSON.stringify(m));
};

// Base path: /<token>/audio.html -> /<token>
const base = location.pathname.replace(/\/[^/]*$/, "");
const offerUrl = `${location.origin}${base}/api/offer`;

let client: PipecatClient | null = null;
let botSpeaking = false;
let muted = false;

function mapTransportState(state: TransportState): string | null {
  switch (state) {
    case "initializing":
    case "initialized":
    case "connecting":
      return "connecting";
    case "connected":
      return "connecting";
    case "ready":
      return "ready";
    case "disconnecting":
    case "disconnected":
      return "disconnected";
    case "error":
      return "error";
    default:
      return null;
  }
}

async function start(): Promise<void> {
  if (client) return;
  post({ type: "status", status: "connecting" });
  const transport = new SmallWebRTCTransport();
  client = new PipecatClient({
    transport,
    enableMic: true,
    enableCam: false,
    callbacks: {
      onTransportStateChanged: (state) => {
        const mapped = mapTransportState(state);
        if (mapped) post({ type: "status", status: mapped });
      },
      onBotReady: () => post({ type: "status", status: "listening" }),
      onBotStartedSpeaking: () => {
        botSpeaking = true;
        post({ type: "status", status: "speaking" });
      },
      onBotStoppedSpeaking: () => {
        botSpeaking = false;
        post({ type: "status", status: "listening" });
      },
      onUserStartedSpeaking: () => post({ type: "status", status: "listening", message: "user-speaking" }),
      onUserStoppedSpeaking: () => {
        if (!botSpeaking) post({ type: "status", status: "thinking" });
      },
      onUserTranscript: (data) => post({ type: "transcript", role: "user", text: data.text, final: !!data.final }),
      onBotOutput: (data) => post({ type: "transcript", role: "agent", text: data.text, final: !!(data as any).final }),
      onLLMFunctionCallStarted: (data) =>
        post({ type: "tool", name: data.function_name, phase: "started", args: (data as any).args }),
      onLLMFunctionCallStopped: (data) =>
        post({ type: "tool", name: data.function_name, phase: "finished", result: (data as any).result }),
      onServerMessage: (data) => post({ type: "server", data }),
      onDeviceError: (err) => post({ type: "error", message: `Microphone error: ${(err as any)?.message ?? err?.type ?? "unknown"}` }),
      onError: (msg) => post({ type: "error", message: String((msg as any)?.data?.message ?? (msg as any)?.data ?? "Connection error") }),
      onDisconnected: () => {
        post({ type: "status", status: "disconnected" });
        client = null;
      },
    },
  });
  try {
    await client.connect({ connection_url: offerUrl } as any);
  } catch (e: any) {
    let message = e?.message ?? String(e);
    if (/503/.test(message)) message = "The voice server is not ready (missing Ultravox API key?)";
    post({ type: "error", message });
    post({ type: "status", status: "error", message });
    try {
      await client?.disconnect();
    } catch {
      /* ignore */
    }
    client = null;
  }
}

async function stop(): Promise<void> {
  const c = client;
  client = null;
  if (!c) return;
  try {
    await c.disconnect();
  } catch {
    /* ignore */
  }
  post({ type: "status", status: "disconnected" });
}

function setMuted(next: boolean): void {
  muted = next;
  try {
    client?.enableMic(!next);
  } catch {
    /* ignore */
  }
  post({ type: "mic", muted });
}

window.cmuxVoice = { start: () => void start(), stop: () => void stop(), setMuted };

if (new URLSearchParams(location.search).get("autostart") === "1") {
  void start();
}
void RTVIEvent; // keep the enum import referenced for tree-shaking clarity
