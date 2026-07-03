#!/usr/bin/env node
// Local NemoClaw/Ollama auth proxy fix for OpenClaw tool-call conversations.

const crypto = require("crypto");
const http = require("http");
const { URL } = require("url");

const TOKEN = process.env.OLLAMA_PROXY_TOKEN;
if (!TOKEN) {
  console.error("OLLAMA_PROXY_TOKEN required");
  process.exit(1);
}

const LISTEN_PORT = parsePositiveInt(process.env.OLLAMA_PROXY_PORT, 11435);
const BACKEND_PORT = parsePositiveInt(process.env.OLLAMA_BACKEND_PORT, 11434);
const DEFAULT_NUM_CTX = parsePositiveInt(process.env.OLLAMA_PROXY_NUM_CTX, 32768);

function parsePositiveInt(value, fallback) {
  const parsed = Number.parseInt(String(value || ""), 10);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(body),
  });
  res.end(body);
}

function collectJson(req, res, callback) {
  const chunks = [];
  let size = 0;

  req.on("data", (chunk) => {
    size += chunk.length;
    if (size > 16 * 1024 * 1024) {
      sendJson(res, 413, { error: { message: "request body too large" } });
      req.destroy();
      return;
    }
    chunks.push(chunk);
  });

  req.on("end", () => {
    try {
      callback(JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}"));
    } catch {
      sendJson(res, 400, { error: { message: "invalid JSON body" } });
    }
  });
}

function normalizeContent(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((part) => {
      if (typeof part === "string") return part;
      if (part && typeof part === "object" && typeof part.text === "string") return part.text;
      return "";
    })
    .filter(Boolean)
    .join("\n");
}

function parseToolCallArguments(value) {
  if (value && typeof value === "object" && !Array.isArray(value)) return value;
  if (typeof value !== "string" || !value.trim()) return {};
  try {
    const parsed = JSON.parse(value);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

function toOllamaToolCalls(toolCalls) {
  if (!Array.isArray(toolCalls)) return undefined;
  return toolCalls.map((call) => ({
    function: {
      name: call.function?.name || call.name || "",
      arguments: parseToolCallArguments(call.function?.arguments || call.arguments),
    },
  }));
}

function toOllamaMessage(message) {
  const toolCalls = toOllamaToolCalls(message.tool_calls);
  return {
    role: message.role || "user",
    content: normalizeContent(message.content),
    ...(toolCalls ? { tool_calls: toolCalls } : {}),
  };
}

function toOpenAiToolCalls(toolCalls) {
  if (!Array.isArray(toolCalls)) return undefined;
  return toolCalls.map((call, index) => ({
    id: call.id || `call_${index}`,
    type: "function",
    function: {
      name: call.function?.name || call.name || "",
      arguments:
        typeof call.function?.arguments === "string"
          ? call.function.arguments
          : JSON.stringify(call.function?.arguments || call.arguments || {}),
    },
  }));
}

function buildOllamaChatRequest(body) {
  const options = {
    ...(body.options && typeof body.options === "object" ? body.options : {}),
  };

  if (!Number.isSafeInteger(options.num_ctx) || options.num_ctx <= 0) {
    options.num_ctx = DEFAULT_NUM_CTX;
  }

  const maxTokens = parsePositiveInt(body.max_completion_tokens ?? body.max_tokens, 0);
  if (maxTokens > 0 && (!Number.isSafeInteger(options.num_predict) || options.num_predict <= 0)) {
    options.num_predict = maxTokens;
  }

  return {
    model: body.model,
    messages: Array.isArray(body.messages) ? body.messages.map(toOllamaMessage) : [],
    stream: body.stream !== false,
    think: false,
    options,
    ...(body.tools ? { tools: body.tools } : {}),
    ...(body.keep_alive ? { keep_alive: body.keep_alive } : {}),
    ...(body.format ? { format: body.format } : {}),
  };
}

function openAiCompletionFromOllama(payload, model) {
  const message = payload.message || {};
  const toolCalls = toOpenAiToolCalls(message.tool_calls);
  return {
    id: `chatcmpl-${Date.now()}`,
    object: "chat.completion",
    created: Math.floor(Date.now() / 1000),
    model: payload.model || model,
    system_fingerprint: "fp_ollama_native_proxy",
    choices: [
      {
        index: 0,
        message: {
          role: message.role || "assistant",
          content: message.content || "",
          ...(toolCalls ? { tool_calls: toolCalls } : {}),
        },
        finish_reason: toolCalls ? "tool_calls" : payload.done_reason || "stop",
      },
    ],
    usage: {
      prompt_tokens: payload.prompt_eval_count || 0,
      completion_tokens: payload.eval_count || 0,
      total_tokens: (payload.prompt_eval_count || 0) + (payload.eval_count || 0),
    },
  };
}

function proxyV1ChatCompletions(clientReq, clientRes) {
  collectJson(clientReq, clientRes, (body) => {
    const ollamaRequest = buildOllamaChatRequest(body);
    const requestBody = JSON.stringify(ollamaRequest);

    const upstreamReq = http.request(
      {
        hostname: "127.0.0.1",
        port: BACKEND_PORT,
        path: "/api/chat",
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Content-Length": Buffer.byteLength(requestBody),
        },
      },
      (upstreamRes) => {
        if (!ollamaRequest.stream) {
          proxyNonStreamingChat(upstreamRes, clientRes, body.model);
          return;
        }
        proxyStreamingChat(upstreamRes, clientRes, body.model);
      },
    );

    upstreamReq.on("error", (err) => {
      if (!clientRes.headersSent) {
        sendJson(clientRes, 502, { error: { message: `Ollama backend error: ${err.message}` } });
      } else {
        clientRes.end();
      }
    });

    upstreamReq.end(requestBody);
  });
}

function proxyNonStreamingChat(upstreamRes, clientRes, model) {
  const chunks = [];
  upstreamRes.on("data", (chunk) => chunks.push(chunk));
  upstreamRes.on("end", () => {
    if ((upstreamRes.statusCode || 500) >= 400) {
      clientRes.writeHead(upstreamRes.statusCode || 500, upstreamRes.headers);
      clientRes.end(Buffer.concat(chunks));
      return;
    }

    try {
      const payload = JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
      sendJson(clientRes, 200, openAiCompletionFromOllama(payload, model));
    } catch (err) {
      sendJson(clientRes, 502, { error: { message: `invalid Ollama response: ${err.message}` } });
    }
  });
}

function proxyStreamingChat(upstreamRes, clientRes, model) {
  clientRes.writeHead(upstreamRes.statusCode || 200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
  });

  const responseId = `chatcmpl-${Date.now()}`;
  let buffer = "";
  let sentRole = false;

  const writeChunk = (payload, delta, finishReason = null, usage = undefined) => {
    clientRes.write(
      `data: ${JSON.stringify({
        id: responseId,
        object: "chat.completion.chunk",
        created: Math.floor(Date.now() / 1000),
        model: payload.model || model,
        system_fingerprint: "fp_ollama_native_proxy",
        choices: [{ index: 0, delta, finish_reason: finishReason }],
        ...(usage ? { usage } : {}),
      })}\n\n`,
    );
  };

  upstreamRes.on("data", (chunk) => {
    buffer += chunk.toString("utf8");
    let newline;
    while ((newline = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, newline).trim();
      buffer = buffer.slice(newline + 1);
      if (!line) continue;

      let payload;
      try {
        payload = JSON.parse(line);
      } catch {
        continue;
      }

      const message = payload.message || {};
      if (!sentRole) {
        writeChunk(payload, { role: message.role || "assistant" });
        sentRole = true;
      }

      if (typeof message.content === "string" && message.content) {
        writeChunk(payload, { content: message.content });
      }

      const toolCalls = toOpenAiToolCalls(message.tool_calls);
      if (toolCalls) {
        writeChunk(payload, { tool_calls: toolCalls });
      }

      if (payload.done) {
        writeChunk(
          payload,
          {},
          message.tool_calls ? "tool_calls" : payload.done_reason || "stop",
          {
            prompt_tokens: payload.prompt_eval_count || 0,
            completion_tokens: payload.eval_count || 0,
            total_tokens: (payload.prompt_eval_count || 0) + (payload.eval_count || 0),
          },
        );
        clientRes.write("data: [DONE]\n\n");
        clientRes.end();
      }
    }
  });

  upstreamRes.on("end", () => {
    if (!clientRes.writableEnded) clientRes.end();
  });
}

function tokenMatches(authHeader) {
  const expectedBuf = Buffer.from(`Bearer ${TOKEN}`);
  const authBuf = typeof authHeader === "string" ? Buffer.from(authHeader) : null;
  return (
    authBuf !== null &&
    authBuf.length === expectedBuf.length &&
    crypto.timingSafeEqual(authBuf, expectedBuf)
  );
}

const server = http.createServer((clientReq, clientRes) => {
  if (!tokenMatches(clientReq.headers.authorization)) {
    clientRes.writeHead(401, { "Content-Type": "text/plain" });
    clientRes.end("Unauthorized");
    return;
  }

  const pathname = new URL(clientReq.url || "/", "http://localhost").pathname;
  if (clientReq.method === "POST" && pathname === "/v1/chat/completions") {
    proxyV1ChatCompletions(clientReq, clientRes);
    return;
  }

  const headers = { ...clientReq.headers };
  delete headers.authorization;
  delete headers.host;

  const proxyReq = http.request(
    {
      hostname: "127.0.0.1",
      port: BACKEND_PORT,
      path: clientReq.url,
      method: clientReq.method,
      headers,
    },
    (proxyRes) => {
      clientRes.writeHead(proxyRes.statusCode || 500, proxyRes.headers);
      proxyRes.pipe(clientRes);
    },
  );

  proxyReq.on("error", (err) => {
    clientRes.writeHead(502, { "Content-Type": "text/plain" });
    clientRes.end(`Ollama backend error: ${err.message}`);
  });

  clientReq.pipe(proxyReq);
});

server.on("error", (err) => {
  if (err && err.code === "EADDRINUSE") {
    console.error(`Ollama auth proxy: port ${LISTEN_PORT} is already in use`);
  } else {
    console.error(`Ollama auth proxy failed to start: ${err && err.message ? err.message : err}`);
  }
  process.exit(1);
});

server.listen(LISTEN_PORT, "0.0.0.0", () => {
  console.log(`Ollama auth proxy listening on 0.0.0.0:${LISTEN_PORT} -> 127.0.0.1:${BACKEND_PORT}`);
});

