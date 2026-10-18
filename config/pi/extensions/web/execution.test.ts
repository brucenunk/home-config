import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { createAssistantMessageEventStream, type AssistantMessage } from "@earendil-works/pi-ai";
import { createAgentSession, createExtensionRuntime, DefaultResourceLoader, ModelRuntime, SessionManager, SettingsManager, type ExtensionAPI, type ResourceLoader, type ToolDefinition } from "@earendil-works/pi-coding-agent";
import webExtension from "./index.ts";

test("packaged web extension loads through pinned Pi with its sibling parser bundle", async () => {
  const dir = await mkdtemp(join(tmpdir(), "pi-web-loader-"));
  try {
    const loader = new DefaultResourceLoader({
      cwd: dir, agentDir: dir, settingsManager: SettingsManager.inMemory(),
      additionalExtensionPaths: [fileURLToPath(new URL("./index.ts", import.meta.url))],
      noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
      agentsFilesOverride: () => ({ agentsFiles: [] }),
      systemPromptOverride: () => "Local loader fixture.", appendSystemPromptOverride: () => [],
    });
    await loader.reload();
    const result = loader.getExtensions();
    assert.deepEqual(result.errors, []);
    assert.equal(result.extensions.length, 1);
    assert.deepEqual([...result.extensions[0].tools.keys()].sort(), ["web_fetch", "web_search"]);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

// Exercise Pi's actual parent loop, tool validation/wrapper/context and transcript.
// Both parent and nested provider behavior are local fixtures: no network or real auth.
for (const mode of ["setup throw", "result rejection"] as const) {
  test(`Pi parent continues after sanitized nested ${mode}`, { timeout: 15000 }, async () => {
    const dir = await mkdtemp(join(tmpdir(), "pi-web-execution-"));
    const raw = "SENTINEL_PRIVATE_PROVIDER_BODY " + "x".repeat(100000) + " secret-credential";
    const reported = { input: 7, output: 2, cacheRead: 0, cacheWrite: 0, totalTokens: 9, cost: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, total: 2 } };
    const error = Object.assign(new Error(raw), { status: 403, ...(mode === "result rejection" ? { usage: reported } : {}) });
    let session: Awaited<ReturnType<typeof createAgentSession>>["session"] | undefined;
    try {
      const runtime = await ModelRuntime.create({ authPath: join(dir, "auth.json"), modelsPath: null, modelsStorePath: join(dir, "models-store.json"), refreshOnCreate: false });
      runtime.registerProvider("web-fixture", { api: "openai-responses", baseUrl: "https://fixture.invalid", apiKey: "unused-fixture", models: [{ id: "fixture", name: "Fixture", reasoning: false, input: ["text"], contextWindow: 64000, maxTokens: 1024, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }] });
      const model = runtime.getModel("web-fixture", "fixture")!;
      const tools: ToolDefinition[] = [];
      webExtension({ registerTool: (tool: ToolDefinition) => tools.push(tool) } as unknown as ExtensionAPI);
      let parentCalls = 0, nestedCalls = 0;
      runtime.streamSimple = (_model, context) => {
        if (context.messages.some(m => m.role === "user" && m.content === "fixture lookup")) {
          nestedCalls++;
          if (mode === "setup throw") throw error;
          const stream = createAssistantMessageEventStream();
          stream.result = async () => { throw error; };
          return stream;
        }
        parentCalls++;
        assert.equal(JSON.stringify(context).includes("SENTINEL_PRIVATE_PROVIDER_BODY"), false);
        assert.equal(JSON.stringify(context).includes("secret-credential"), false);
        const toolResult = context.messages.find(m => m.role === "toolResult");
        if (parentCalls > 1) {
          assert.ok(toolResult && toolResult.role === "toolResult");
          assert.equal(toolResult.isError, true);
          assert.ok(JSON.stringify(toolResult).length < 2000);
        }
        const message: AssistantMessage = { role: "assistant", api: model.api, provider: model.provider, model: model.id, timestamp: Date.now(), usage: { ...reported, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
          stopReason: toolResult ? "stop" : "toolUse",
          content: toolResult ? [{ type: "text", text: "PARENT_CONTINUED" }] : [{ type: "toolCall", id: "fixture-call", name: "web_search", arguments: { query: "fixture lookup" } }],
        };
        const stream = createAssistantMessageEventStream();
        stream.push({ type: "start", partial: message });
        stream.push({ type: "done", reason: message.stopReason as "stop" | "toolUse", message });
        return stream;
      };
      const resources: ResourceLoader = {
        getExtensions: () => ({ extensions: [], errors: [], runtime: createExtensionRuntime() }),
        getSkills: () => ({ skills: [], diagnostics: [] }), getPrompts: () => ({ prompts: [], diagnostics: [] }), getThemes: () => ({ themes: [], diagnostics: [] }),
        getAgentsFiles: () => ({ agentsFiles: [] }), getSystemPrompt: () => "Local fixture parent.", getSystemPromptSource: () => undefined,
        getAppendSystemPrompt: () => [], getAppendSystemPromptSources: () => [], extendResources: () => {}, reload: async () => {},
      };
      ({ session } = await createAgentSession({ cwd: dir, agentDir: dir, modelRuntime: runtime, model, thinkingLevel: "off", tools: ["web_search"], customTools: tools, resourceLoader: resources, sessionManager: SessionManager.inMemory(dir), settingsManager: SettingsManager.inMemory({ compaction: { enabled: false }, retry: { enabled: false } }) }));
      await session.prompt("Start parent fixture.");
      assert.equal(session.getLastAssistantText(), "PARENT_CONTINUED");
      assert.equal(parentCalls, 2);
      assert.equal(nestedCalls, 1);
      assert.equal(JSON.stringify(session.messages).includes("SENTINEL_PRIVATE_PROVIDER_BODY"), false);
      const result = session.messages.find(m => m.role === "toolResult");
      assert.ok(result && result.role === "toolResult");
      assert.deepEqual(result.usage, mode === "result rejection" ? reported : undefined);
    } finally {
      session?.dispose();
      await rm(dir, { recursive: true, force: true });
    }
  });
}