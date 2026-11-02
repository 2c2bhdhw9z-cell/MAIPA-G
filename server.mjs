import http from "node:http";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";

const port = Number(process.env.PORT || 8080);
const token = process.env.MAIPA_G_TOKEN || "";
const sessions = new Set();
const tasks = new Map();

const tools = [
  {
    name: "list_tasks",
    description: "List tasks on this MAIPA-G computer and their status.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    annotations: { readOnlyHint: true, destructiveHint: false },
  },
  {
    name: "get_task",
    description: "Read one task's status and the output it has produced so far.",
    inputSchema: {
      type: "object",
      properties: { id: { type: "string" } },
      required: ["id"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false },
  },
  {
    name: "start_task",
    description: "Start a shell command as a task on this computer. The command keeps running after this call returns.",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string" },
        command: { type: "string" },
      },
      required: ["name", "command"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: false },
  },
];

function result(id, value) {
  return { jsonrpc: "2.0", id, result: value };
}

function failure(id, code, message) {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

function textResult(text, isError = false) {
  return { content: [{ type: "text", text }], isError };
}

function taskView(task) {
  return {
    id: task.id,
    name: task.name,
    status: task.status,
    exitCode: task.exitCode,
    startedAt: task.startedAt,
    finishedAt: task.finishedAt,
    output: task.output,
  };
}

function startTask(name, command) {
  if (!token) {
    throw new Error("This computer will not run a command until MAIPA_G_TOKEN is set.");
  }
  const trimmedName = String(name || "").trim();
  const trimmedCommand = String(command || "").trim();
  if (!trimmedName || trimmedName.length > 120) throw new Error("A task needs a name of 1 to 120 characters.");
  if (!trimmedCommand || trimmedCommand.length > 4000) throw new Error("A task needs a command of 1 to 4000 characters.");
  const id = randomUUID();
  const task = {
    id,
    name: trimmedName,
    status: "running",
    exitCode: null,
    startedAt: new Date().toISOString(),
    finishedAt: null,
    output: "",
  };
  tasks.set(id, task);
  const child = spawn("bash", ["-lc", trimmedCommand], { env: process.env });
  const append = (chunk) => {
    task.output = (task.output + chunk.toString("utf8")).slice(-100_000);
  };
  child.stdout.on("data", append);
  child.stderr.on("data", append);
  const timer = setTimeout(() => child.kill("SIGTERM"), 10 * 60 * 1000);
  child.on("close", (code) => {
    clearTimeout(timer);
    task.status = code === 0 ? "finished" : "failed";
    task.exitCode = code;
    task.finishedAt = new Date().toISOString();
  });
  child.on("error", (error) => {
    clearTimeout(timer);
    task.status = "failed";
    task.finishedAt = new Date().toISOString();
    task.output = (task.output + error.message).slice(-100_000);
  });
  return task;
}

function callTool(name, args) {
  if (name === "list_tasks") {
    const lines = [...tasks.values()].map((task) => `${task.id}  ${task.status}  ${task.name}`);
    return textResult(lines.length ? lines.join("\n") : "No tasks.");
  }
  if (name === "get_task") {
    const task = tasks.get(String(args.id || ""));
    if (!task) return textResult("No task with that id.", true);
    return textResult(JSON.stringify(taskView(task), null, 2));
  }
  if (name === "start_task") {
    const task = startTask(args.name, args.command);
    return textResult(JSON.stringify(taskView(task), null, 2));
  }
  return textResult(`Unknown tool ${name}.`, true);
}

function handleMessage(message) {
  const id = message.id ?? null;
  const method = message.method;
  const params = message.params || {};
  if (id === null) return null;
  if (method === "initialize") {
    const asked = params.protocolVersion;
    const protocolVersion = asked === "2024-11-05" ? asked : "2025-03-26";
    return result(id, {
      protocolVersion,
      capabilities: { tools: { listChanged: false } },
      serverInfo: { name: "maipa-g", version: "1.0.0" },
    });
  }
  if (method === "ping" || method === "notifications/initialized") return result(id, {});
  if (method === "tools/list") return result(id, { tools });
  if (method === "tools/call") {
    try {
      return result(id, callTool(params.name, params.arguments || {}));
    } catch (error) {
      return result(id, textResult(error.message, true));
    }
  }
  return failure(id, -32601, `Method not found: ${method}`);
}

function authorized(request) {
  if (!token) return true;
  const header = request.headers.authorization || "";
  const presented = header.toLowerCase().startsWith("bearer ") ? header.slice(7).trim() : header.trim();
  return presented === token;
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    request.on("data", (chunk) => {
      size += chunk.length;
      if (size > 1_000_000) {
        reject(new Error("Request is too large."));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    request.on("error", reject);
  });
}

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url || "/", "http://localhost");
  if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/health")) {
    response.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
    response.end("maipa-g task server\n");
    return;
  }
  if (url.pathname !== "/mcp") {
    response.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    response.end("Not found\n");
    return;
  }
  if (!authorized(request)) {
    response.writeHead(401, { "content-type": "application/json", "www-authenticate": "Bearer" });
    response.end(JSON.stringify(failure(null, -32001, "Unauthorized")));
    return;
  }
  if (request.method === "DELETE") {
    const session = request.headers["mcp-session-id"];
    if (typeof session === "string") sessions.delete(session);
    response.writeHead(204);
    response.end();
    return;
  }
  if (request.method === "GET") {
    const session = request.headers["mcp-session-id"];
    if (typeof session !== "string" || !sessions.has(session)) {
      response.writeHead(400, { "content-type": "text/plain; charset=utf-8" });
      response.end("Missing session\n");
      return;
    }
    response.writeHead(200, {
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
      connection: "keep-alive",
    });
    const timer = setInterval(() => response.write(": ping\n\n"), 15000);
    request.on("close", () => clearInterval(timer));
    return;
  }
  if (request.method !== "POST") {
    response.writeHead(405, { allow: "GET, POST, DELETE" });
    response.end();
    return;
  }
  let message;
  try {
    message = JSON.parse(await readBody(request));
  } catch {
    response.writeHead(400, { "content-type": "application/json" });
    response.end(JSON.stringify(failure(null, -32700, "Parse error")));
    return;
  }
  if (!message.id) {
    response.writeHead(202);
    response.end();
    return;
  }
  const body = handleMessage(message);
  const headers = { "content-type": "application/json" };
  if (message.method === "initialize") {
    const session = randomUUID();
    sessions.add(session);
    headers["mcp-session-id"] = session;
  }
  response.writeHead(200, headers);
  response.end(JSON.stringify(body));
});

server.listen(port, "0.0.0.0");
