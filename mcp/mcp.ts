// mcp.ts — MCP Server (Streamable HTTP transport, MCP 2024-11-05)
// Exposes Toscanini orchestrator operations as MCP tools for Claude Code.
//
// Endpoint: POST /mcp  (JSON-RPC 2.0, single or batch)
//           GET  /mcp  (SSE keep-alive)
//
// Tools:
//   submit_job       — Submit a podcast job (URL + optional params)
//   submit_batch     — Submit multiple URLs as a batch
//   get_job          — Get status/results of a job
//   get_batch        — Get status/progress of a batch
//   wait_job         — Poll until job completes (default timeout 30min)
//   wait_batch       — Poll until batch completes
//   publish_podcast  — Publish episode from pre-processed JSON (skips collect/transcribe/summarize)
//   subscribe_feed   — Subscribe to a podcast feed for auto-download of new episodes
//   list_feeds       — List feed subscriptions
//   check_feed_now   — Force a feed check now
//   unsubscribe_feed — Remove a feed subscription
//   get_feeds_config  — Get feeds runtime config (safety_hour_utc)
//   set_feeds_config  — Set feeds runtime config live (no restart)

import type { Config } from "./config";

// ── MCP JSON-RPC types ────────────────────────────────────────────────────────

interface MCPRequest {
  jsonrpc: "2.0";
  id?: string | number | null;
  method: string;
  params?: Record<string, unknown>;
}

interface MCPResponse {
  jsonrpc: "2.0";
  id: string | number | null;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}

// ── Tool registry ─────────────────────────────────────────────────────────────

const TOOLS = [
  {
    name: "submit_job",
    description:
      "Submit a podcast episode job to Toscanini for processing. " +
      "The job will go through: collect → transcribe → summarize → enrich_tags → publish → notify. " +
      "Returns a job ID that can be used to track progress with get_job or wait_job.",
    inputSchema: {
      type: "object",
      properties: {
        url: {
          type: "string",
          description: "Podcast episode URL (PocketCasts share URL or direct audio URL)",
        },
        collector: {
          type: "string",
          description: "Collector to use (default: pocketcasts)",
        },
        force_retranscribe: {
          type: "boolean",
          description: "Force re-transcription even if transcript already exists",
        },
      },
      required: ["url"],
    },
  },
  {
    name: "submit_batch",
    description:
      "Submit multiple podcast episode URLs as a batch job to Toscanini. " +
      "Returns a batch ID for tracking progress with get_batch or wait_batch.",
    inputSchema: {
      type: "object",
      properties: {
        urls: {
          type: "array",
          items: { type: "string" },
          description: "List of podcast episode URLs to process",
        },
        collector: {
          type: "string",
          description: "Collector to use for all URLs (default: pocketcasts)",
        },
        force_retranscribe: {
          type: "boolean",
          description: "Force re-transcription for all episodes",
        },
      },
      required: ["urls"],
    },
  },
  {
    name: "get_job",
    description:
      "Get the current status and results of a Toscanini job. " +
      "Status can be: pending, running, completed, failed. " +
      "When completed, returns the full episode data including transcript and summary.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Job ID returned by submit_job",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "get_batch",
    description:
      "Get the current status and progress of a Toscanini batch job. " +
      "Returns overall status plus per-job details.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Batch ID returned by submit_batch",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "wait_job",
    description:
      "Wait for a Toscanini job to complete by polling every 10 seconds. " +
      "Returns the final job result when done, or an error if it fails or times out. " +
      "Use this after submit_job to get results without manual polling.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Job ID to wait for",
        },
        timeout_seconds: {
          type: "number",
          description: "Max wait time in seconds (default: 1800 = 30 minutes)",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "wait_batch",
    description:
      "Wait for a Toscanini batch to complete by polling every 10 seconds. " +
      "Returns the final batch result when all jobs finish (or any fail). " +
      "Use this after submit_batch to get results without manual polling.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Batch ID to wait for",
        },
        timeout_seconds: {
          type: "number",
          description: "Max wait time in seconds (default: 1800 = 30 minutes)",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "find_job_by_url",
    description: "Find a Toscanini pipeline by episode URL. Returns pipeline_id, status and current step.",
    inputSchema: {
      type: "object",
      properties: {
        url: { type: "string", description: "Episode URL to search for" },
      },
      required: ["url"],
    },
  },
  {
    name: "prioritize_job",
    description:
      "Move a Toscanini pipeline job to the front of the transcription queue. " +
      "Sets the Oban job priority to 0 (highest) so it is processed before lower-priority jobs.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Pipeline job ID to prioritize",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "publish_podcast",
    description:
      "Publish a podcast episode from pre-processed JSON data. " +
      "Bypasses collect/transcribe/summarize — starts directly at enrich_tags. " +
      "Use this when you have the episode JSON ready and just need to publish to Vox.",
    inputSchema: {
      type: "object",
      properties: {
        path: {
          type: "string",
          description: "Vox content path (e.g. '2025/02/W06/episode-slug.md')",
        },
        json: {
          type: "object",
          description: "Episode JSON data (Vox JSON schema v1.0 with frontmatter, summary, etc.)",
        },
      },
      required: ["path", "json"],
    },
  },
  {
    name: "get_scheduler_config",
    description:
      "Get the current scheduler configuration for a Toscanini queue. " +
      "Returns the time windows with concurrency limits and GPU flags.",
    inputSchema: {
      type: "object",
      properties: {
        queue: {
          type: "string",
          description: "Queue name (e.g. 'transcribe')",
        },
      },
      required: ["queue"],
    },
  },
  {
    name: "set_scheduler_config",
    description:
      "Update the scheduler configuration for a Toscanini queue. " +
      "Replaces the time windows for the specified queue and immediately applies " +
      "the current window's concurrency limit via Oban.scale_queue.",
    inputSchema: {
      type: "object",
      properties: {
        queue: {
          type: "string",
          description: "Queue name (e.g. 'transcribe')",
        },
        windows: {
          type: "array",
          description: "Array of time windows: [{from: 0, to: 9, limit: 3, gpu: true, cores: 14}, ...]",
          items: {
            type: "object",
            properties: {
              from:  { type: "number", description: "Start hour (0-23)" },
              to:    { type: "number", description: "End hour (1-24)" },
              limit: { type: "number", description: "Max concurrent jobs" },
              gpu:   { type: "boolean", description: "Whether GPU is used in this window" },
              cores: { type: "number", description: "CPU threads for whisper transcription (default: 14)" },
            },
            required: ["from", "to", "limit"],
          },
        },
      },
      required: ["queue", "windows"],
    },
  },
  {
    name: "subscribe_feed",
    description:
      "Subscribe to a podcast feed so Toscanini auto-downloads NEW episodes on a schedule. " +
      "Backfill is off: only episodes published AFTER subscribing are processed (a watermark is " +
      "recorded at subscribe time). Provide either a PocketCasts URL (short pca.st/CODE links are " +
      "resolved once and only the podcast UUID is stored) or the podcast UUID directly via feed_ref. " +
      "check_days sets the hot window (hourly polling on those weekdays); outside it a daily safety " +
      "poll runs. Conditional GET (ETag) keeps polling cheap.",
    inputSchema: {
      type: "object",
      properties: {
        url: {
          type: "string",
          description: "PocketCasts podcast/episode URL (incl. short pca.st/CODE). Alternative to feed_ref.",
        },
        feed_ref: {
          type: "string",
          description: "Podcast UUID (PocketCasts). Alternative to url; more robust than short links.",
        },
        title: {
          type: "string",
          description: "Display title for the subscription (optional; inferred from the feed if omitted).",
        },
        check_days: {
          type: "array",
          items: { type: "string" },
          description: "Weekday abbreviations for the hot window, e.g. ['mon','fri']. Empty/omitted = hot always on.",
        },
        hot_interval_min: {
          type: "number",
          description: "Minutes between checks inside the hot window (default 60).",
        },
        idle_interval_min: {
          type: "number",
          description: "Minutes between safety checks outside the hot window (default 1440 = daily).",
        },
        auto_annotate: {
          type: "boolean",
          description:
            "When true, each new episode is auto-annotated (suggest-annotations → annotate) before " +
            "publishing, filling the episode's `annotations` field. Default false. Toggle later with update_feed.",
        },
      },
    },
  },
  {
    name: "update_feed",
    description:
      "Update an existing feed subscription (from list_feeds). Any provided field is changed; omitted " +
      "fields are left as-is. Use to toggle auto_annotate on/off for a program, pause it (active), or " +
      "adjust the check schedule.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string", description: "Subscription ID (from list_feeds)." },
        auto_annotate: {
          type: "boolean",
          description: "Enable/disable auto-annotation before publishing for this feed.",
        },
        active: { type: "boolean", description: "Enable/disable checking this subscription." },
        title: { type: "string", description: "Display title." },
        check_days: {
          type: "array",
          items: { type: "string" },
          description: "Weekday abbreviations for the hot window, e.g. ['mon','fri']. [] = hot always on.",
        },
        hot_interval_min: { type: "number", description: "Minutes between checks inside the hot window." },
        idle_interval_min: { type: "number", description: "Minutes between safety checks outside the hot window." },
      },
      required: ["id"],
    },
  },
  {
    name: "list_feeds",
    description: "List all feed subscriptions with their UUID (feed_ref), watermark and check schedule.",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "check_feed_now",
    description:
      "Force an immediate check of a feed subscription for new episodes (bypasses the schedule). " +
      "New episodes above the watermark are queued as a batch.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Subscription ID (from subscribe_feed or list_feeds).",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "unsubscribe_feed",
    description: "Remove a feed subscription so it is no longer checked.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Subscription ID to remove.",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "get_feeds_config",
    description:
      "Get the feeds runtime config. Currently: safety_hour_utc — the UTC hour (0-23) of the " +
      "daily safety-net feed check that runs outside a podcast's hot window (check_days).",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "set_feeds_config",
    description:
      "Update the feeds runtime config live (no restart). safety_hour_utc: UTC hour 0-23 of the daily " +
      "safety-net check. hot_grace_min: grace minutes 0-59 on the hot-window threshold. Persisted to data/feeds_config.json.",
    inputSchema: {
      type: "object",
      properties: {
        safety_hour_utc: { type: "number", description: "UTC hour 0-23 of the daily safety-net check" },
        hot_grace_min: { type: "number", description: "Grace minutes 0-59 on the hot-window threshold (default 10)" },
      },
    },
  },
];

// ── JSON-RPC helpers ──────────────────────────────────────────────────────────

function ok(id: string | number | null, result: unknown): MCPResponse {
  return { jsonrpc: "2.0", id, result };
}

function err(id: string | number | null, code: number, message: string): MCPResponse {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

// ── Toscanini API helpers ─────────────────────────────────────────────────────

async function toscaniniPost(baseUrl: string, path: string, body: unknown): Promise<unknown> {
  const res = await fetch(`${baseUrl}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`Toscanini ${path} returned ${res.status}: ${text}`);
  }
  return res.json();
}

async function toscaniniGet(baseUrl: string, path: string): Promise<unknown> {
  const res = await fetch(`${baseUrl}${path}`);
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`Toscanini GET ${path} returned ${res.status}: ${text}`);
  }
  return res.json();
}

async function toscaniniPut(baseUrl: string, path: string, body: unknown): Promise<unknown> {
  const res = await fetch(`${baseUrl}${path}`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`Toscanini PUT ${path} returned ${res.status}: ${text}`);
  }
  return res.json();
}

async function toscaniniDelete(baseUrl: string, path: string): Promise<unknown> {
  const res = await fetch(`${baseUrl}${path}`, { method: "DELETE" });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`Toscanini DELETE ${path} returned ${res.status}: ${text}`);
  }
  return res.json();
}

function isTerminal(status: string): boolean {
  return status === "completed" || status === "failed" || status === "error";
}

async function pollUntilDone(
  getter: () => Promise<unknown>,
  timeoutSeconds: number,
  intervalMs = 10_000,
): Promise<unknown> {
  const deadline = Date.now() + timeoutSeconds * 1000;
  while (Date.now() < deadline) {
    const data = await getter() as Record<string, unknown>;
    const status = (data.status as string) || "";
    if (isTerminal(status)) return data;
    const remaining = Math.round((deadline - Date.now()) / 1000);
    console.log(`[toscanini-mcp] Polling... status=${status}, remaining=${remaining}s`);
    await Bun.sleep(intervalMs);
  }
  throw new Error(`Timed out after ${timeoutSeconds}s waiting for job to complete`);
}

// ── Method dispatcher ─────────────────────────────────────────────────────────

async function dispatch(
  method: string,
  params: Record<string, unknown> | undefined,
  id: string | number | null,
  config: Config,
): Promise<MCPResponse | null> {
  const base = config.toscaniniUrl;

  switch (method) {
    // ── Lifecycle ──────────────────────────────────────────────────────────
    case "initialize":
      return ok(id, {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: "toscanini-mcp", version: "1.0.0" },
      });

    case "notifications/initialized":
      return null; // notification — no response

    case "ping":
      return ok(id, {});

    // ── Tool discovery ─────────────────────────────────────────────────────
    case "tools/list":
      return ok(id, { tools: TOOLS });

    // ── Tool invocation ────────────────────────────────────────────────────
    case "tools/call": {
      const toolName = params?.name as string | undefined;
      const args = (params?.arguments ?? {}) as Record<string, unknown>;

      try {
        let resultData: unknown;

        if (toolName === "submit_job") {
          if (!args.url) return err(id, -32602, "Missing required arg: url");
          const body: Record<string, unknown> = { url: args.url };
          if (args.collector) body.collector = args.collector;
          if (args.force_retranscribe !== undefined) body.force_retranscribe = args.force_retranscribe;
          resultData = await toscaniniPost(base, "/jobs", body);

        } else if (toolName === "submit_batch") {
          const urls = args.urls;
          if (!Array.isArray(urls) || urls.length === 0) {
            return err(id, -32602, "Missing required arg: urls (non-empty array)");
          }
          const body: Record<string, unknown> = { urls: urls.join(",") };
          if (args.collector) body.collector = args.collector;
          if (args.force_retranscribe !== undefined) body.force_retranscribe = args.force_retranscribe;
          resultData = await toscaniniPost(base, "/batch", body);

        } else if (toolName === "get_job") {
          if (!args.id) return err(id, -32602, "Missing required arg: id");
          resultData = await toscaniniGet(base, `/jobs/${args.id}`);

        } else if (toolName === "get_batch") {
          if (!args.id) return err(id, -32602, "Missing required arg: id");
          resultData = await toscaniniGet(base, `/batch/${args.id}`);

        } else if (toolName === "wait_job") {
          if (!args.id) return err(id, -32602, "Missing required arg: id");
          const timeout = (args.timeout_seconds as number) || 1800;
          resultData = await pollUntilDone(
            () => toscaniniGet(base, `/jobs/${args.id}`) as Promise<unknown>,
            timeout,
          );

        } else if (toolName === "wait_batch") {
          if (!args.id) return err(id, -32602, "Missing required arg: id");
          const timeout = (args.timeout_seconds as number) || 1800;
          resultData = await pollUntilDone(
            () => toscaniniGet(base, `/batch/${args.id}`) as Promise<unknown>,
            timeout,
          );

        } else if (toolName === "find_job_by_url") {
          if (!args.url) return err(id, -32602, "Missing required arg: url");
          resultData = await toscaniniGet(base, "/pipelines/find?url=" + encodeURIComponent(args.url as string));

        } else if (toolName === "prioritize_job") {
          if (!args.id) return err(id, -32602, "Missing required arg: id");
          resultData = await toscaniniPost(base, "/pipelines/" + args.id + "/prioritize", {});

        } else if (toolName === "publish_podcast") {
          if (!args.path || !args.json) {
            return err(id, -32602, "Missing required args: path, json");
          }
          resultData = await toscaniniPost(base, "/publish/podcast", {
            path: args.path,
            json: args.json,
          });

        } else if (toolName === "get_scheduler_config") {
          if (!args.queue) return err(id, -32602, "Missing required arg: queue");
          resultData = await toscaniniGet(base, `/scheduler/configs/${args.queue}`);

        } else if (toolName === "set_scheduler_config") {
          if (!args.queue || !args.windows) return err(id, -32602, "Missing required args: queue, windows");
          const res = await fetch(`${base}/scheduler/configs/${args.queue}`, {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ windows: args.windows }),
          });
          if (!res.ok) {
            const text = await res.text().catch(() => "");
            throw new Error(`Toscanini PUT /scheduler/configs/${args.queue} returned ${res.status}: ${text}`);
          }
          resultData = await res.json();

        } else if (toolName === "subscribe_feed") {
          if (!args.url && !args.feed_ref) {
            return err(id, -32602, "Missing required arg: url or feed_ref");
          }
          const body: Record<string, unknown> = {};
          if (args.url) body.url = args.url;
          if (args.feed_ref) body.feed_ref = args.feed_ref;
          if (args.title) body.title = args.title;
          if (args.check_days !== undefined) body.check_days = args.check_days;
          if (args.hot_interval_min !== undefined) body.hot_interval_min = args.hot_interval_min;
          if (args.idle_interval_min !== undefined) body.idle_interval_min = args.idle_interval_min;
          if (args.auto_annotate !== undefined) body.auto_annotate = args.auto_annotate;
          resultData = await toscaniniPost(base, "/subscriptions", body);

        } else if (toolName === "update_feed") {
          if (!args.id) return err(id, -32602, "Missing required arg: id");
          const body: Record<string, unknown> = {};
          if (args.auto_annotate !== undefined) body.auto_annotate = args.auto_annotate;
          if (args.active !== undefined) body.active = args.active;
          if (args.title !== undefined) body.title = args.title;
          if (args.check_days !== undefined) body.check_days = args.check_days;
          if (args.hot_interval_min !== undefined) body.hot_interval_min = args.hot_interval_min;
          if (args.idle_interval_min !== undefined) body.idle_interval_min = args.idle_interval_min;
          if (Object.keys(body).length === 0) return err(id, -32602, "Provide at least one field to update");
          resultData = await toscaniniPut(base, "/subscriptions/" + args.id, body);

        } else if (toolName === "list_feeds") {
          resultData = await toscaniniGet(base, "/subscriptions");

        } else if (toolName === "check_feed_now") {
          if (!args.id) return err(id, -32602, "Missing required arg: id");
          resultData = await toscaniniPost(base, "/subscriptions/" + args.id + "/check", {});

        } else if (toolName === "unsubscribe_feed") {
          if (!args.id) return err(id, -32602, "Missing required arg: id");
          resultData = await toscaniniDelete(base, "/subscriptions/" + args.id);

        } else if (toolName === "get_feeds_config") {
          resultData = await toscaniniGet(base, "/feeds/config");

        } else if (toolName === "set_feeds_config") {
          const cfgBody: Record<string, unknown> = {};
          if (args.safety_hour_utc !== undefined) cfgBody.safety_hour_utc = args.safety_hour_utc;
          if (args.hot_grace_min !== undefined) cfgBody.hot_grace_min = args.hot_grace_min;
          if (Object.keys(cfgBody).length === 0) return err(id, -32602, "Provide safety_hour_utc and/or hot_grace_min");
          const cfgRes = await fetch(`${base}/feeds/config`, {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(cfgBody),
          });
          if (!cfgRes.ok) {
            const text = await cfgRes.text().catch(() => "");
            throw new Error(`Toscanini PUT /feeds/config returned ${cfgRes.status}: ${text}`);
          }
          resultData = await cfgRes.json();

        } else {
          return err(id, -32601, `Unknown tool: ${toolName ?? "(none)"}`);
        }

        return ok(id, {
          content: [{ type: "text", text: JSON.stringify(resultData, null, 2) }],
        });

      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        return ok(id, {
          content: [{ type: "text", text: `Error: ${msg}` }],
          isError: true,
        });
      }
    }

    default:
      return err(id, -32601, `Method not found: ${method}`);
  }
}

// ── HTTP handler (export) ─────────────────────────────────────────────────────

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Accept, Mcp-Session-Id",
};

export async function handleMCP(req: Request, config: Config): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS });
  }

  // GET /mcp — minimal SSE keep-alive
  if (req.method === "GET") {
    const body = new ReadableStream({
      start(ctrl) {
        ctrl.enqueue(new TextEncoder().encode(": toscanini-mcp MCP ready\n\n"));
      },
    });
    return new Response(body, {
      headers: { ...CORS, "Content-Type": "text/event-stream", "Cache-Control": "no-cache" },
    });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { ...CORS, "Content-Type": "application/json" },
    });
  }

  // POST /mcp — JSON-RPC 2.0
  let body: MCPRequest | MCPRequest[];
  try {
    body = await req.json();
  } catch {
    return new Response(
      JSON.stringify(err(null, -32700, "Parse error: invalid JSON")),
      { status: 400, headers: { ...CORS, "Content-Type": "application/json" } },
    );
  }

  const isBatch = Array.isArray(body);
  const requests: MCPRequest[] = isBatch ? body : [body as MCPRequest];

  const settled = await Promise.all(
    requests.map(r => dispatch(r.method, r.params, r.id ?? null, config)),
  );

  const responses = settled.filter((r): r is MCPResponse => r !== null);

  if (responses.length === 0) {
    return new Response(null, { status: 202, headers: CORS });
  }

  const responseBody = isBatch ? responses : responses[0];
  return new Response(JSON.stringify(responseBody), {
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}
