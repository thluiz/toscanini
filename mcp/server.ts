// server.ts — Toscanini MCP sidecar (Bun HTTP server)
import { loadConfig } from "./config";
import { handleMCP } from "./mcp";

const config = loadConfig();

function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

const server = Bun.serve({
  port: config.port,
  async fetch(req) {
    const url = new URL(req.url);
    const path = url.pathname;

    if (path === "/health" && req.method === "GET") {
      return jsonResponse({ ok: true, service: "toscanini-mcp", toscaniniUrl: config.toscaniniUrl });
    }

    if (path === "/mcp") {
      return handleMCP(req, config);
    }

    return jsonResponse({ error: "Not found" }, 404);
  },
});

console.log(`[toscanini-mcp] Running on port ${server.port}`);
console.log(`[toscanini-mcp] Toscanini URL: ${config.toscaniniUrl}`);
