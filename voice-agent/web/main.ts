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
    cmuxVoice?: { start: () => void; stop: () => void; setMuted: (muted: boolean) => void; recap: (surfaceId: string | null) => void };
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
// ?session=fresh|resume: whether the chat log was empty when this call started.
// The sidecar picks the greeting from it ("Hi there, what should we build?" / "Hey.").
const sessionKind = new URLSearchParams(location.search).get("session") === "resume" ? "resume" : "fresh";


/** RTVI errors arrive as { data: { error, fatal } }; pipecat sometimes nests further. */
function describeError(msg: unknown): string {
  const seen = new Set<unknown>();
  const walk = (v: unknown): string | null => {
    if (v == null) return null;
    if (typeof v === "string") return v;
    if (typeof v !== "object" || seen.has(v)) return null;
    seen.add(v);
    const o = v as Record<string, unknown>;
    for (const key of ["error", "message", "detail", "reason", "data"]) {
      const found = walk(o[key]);
      if (found) return found;
    }
    return null;
  };
  const text = walk(msg);
  if (text) {
    // Pipecat wraps service errors as "Service#0 exception (/path/file.py:123): <cause>"; keep the cause.
    const m = text.match(/exception \([^)]*\):\s*(.+)$/s);
    return m ? m[1].trim() : text;
  }
  try {
    return JSON.stringify(msg);
  } catch {
    return "Connection error";
  }
}

let client: PipecatClient | null = null;
let botSpeaking = false;
let muted = false;

// The SmallWebRTC transport hands us the bot's audio track but does not play
// it; the app is expected to attach it to an element. Without this the whole
// pipeline runs (transcripts, tool calls) and the user hears nothing.
let botAudio: HTMLAudioElement | null = null;

function playBotTrack(track: MediaStreamTrack): void {
  if (track.kind !== "audio") return;
  if (!botAudio) {
    botAudio = document.createElement("audio");
    botAudio.autoplay = true;
    (botAudio as any).playsInline = true;
    botAudio.setAttribute("playsinline", "true");
    document.body.appendChild(botAudio);
  }
  botAudio.srcObject = new MediaStream([track]);
  botAudio.muted = false;
  botAudio.volume = 1.0;
  const attempt = () =>
    botAudio!.play().then(
      () => post({ type: "status", status: "audio-playing" }),
      (e: any) => {
        post({ type: "error", message: `Speaker playback blocked: ${describeError(e)}` });
        // Retry shortly; WebKit sometimes rejects the first play() right after srcObject is set.
        setTimeout(() => void botAudio!.play().catch(() => undefined), 500);
      },
    );
  void attempt();
}

function stopBotTrack(): void {
  if (botAudio) {
    try {
      botAudio.pause();
      botAudio.srcObject = null;
    } catch {
      /* ignore */
    }
  }
}

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
      onTrackStarted: (track, participant) => {
        if (!participant || !(participant as any).local) playBotTrack(track);
      },
      onTrackStopped: (track, participant) => {
        if (!participant || !(participant as any).local) stopBotTrack();
      },
      onServerMessage: (data) => post({ type: "server", data }),
      onDeviceError: (err) => post({ type: "error", message: `Microphone error: ${describeError(err)}` }),
      onError: (msg) => post({ type: "error", message: describeError(msg) }),
      onDisconnected: () => {
        stopBotTrack();
        post({ type: "status", status: "disconnected" });
        client = null;
      },
    },
  });
  try {
    await client.connect({ webrtcRequestParams: { endpoint: offerUrl, requestData: { session: sessionKind } } } as any);
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

async function recap(surfaceId: string | null): Promise<void> {
  if (!client) {
    post({ type: "error", message: "Start a voice session first, then press Recap." });
    return;
  }
  try {
    const res = (await client.sendClientRequest("recap", { surface_id: surfaceId }, 15000)) as any;
    if (res && res.ok === false) post({ type: "error", message: res.error ?? "Recap failed." });
  } catch (e: any) {
    post({ type: "error", message: `Recap failed: ${describeError(e)}` });
  }
}

window.cmuxVoice = { start: () => void start(), stop: () => void stop(), setMuted, recap: (id: string | null) => void recap(id) };

if (new URLSearchParams(location.search).get("autostart") === "1") {
  void start();
}
void RTVIEvent; // keep the enum import referenced for tree-shaking clarity
