import type { BrowserTab } from "@openbot/contracts/ipc";
import { Effect } from "effect";
import type { Browser, BrowserContext, Page } from "playwright-core";
import type { AgentBrowserHost } from "../../../../src/backend/agent/turn-lifecycle";
import type { BrowserScreencastFrame, BrowserViewportInput } from "../../../../src/backend/browser-cdp";
import { browserCall, browserSync } from "../../../../src/backend/browser-effects";
import type { BrowserViewOptions, PreparedBrowserSecret } from "../../../../src/backend/browser-host";
import { parseBrowserToolCall } from "../../../../src/backend/browser-tools";
import type { DynamicToolResult } from "../../../../src/backend/protocol";
import { BrowserViewGateway } from "../../../../src/main/browser-view-gateway";
import type { TeamApiBrowser } from "../../../../src/main/team-api/dependencies";

/** Public test data. This is never a website or account credential. */
export const SYNTHETIC_BROWSER_SECRET = "NATIVE-SYNTHETIC-ONLY";
export const SYNTHETIC_BROWSER_URL = "https://example.invalid/sign-in";
export const SYNTHETIC_BROWSER_RELOAD_URL = "https://example.invalid/sign-in-reload";

type InputMetadata =
  | { type: "pointer"; action: string; x: number; y: number; deltaX: number; deltaY: number }
  | { type: "key"; action: string; key: string; textLength: number }
  | { type: "paste" | "cut"; textLength: number };

interface View {
  frame: (frame: BrowserScreencastFrame) => void;
  ended?: (reason: string) => void;
  options: BrowserViewOptions;
  sequence: number;
}

interface SurfaceTab {
  tab: BrowserTab;
  context: BrowserContext | null;
  page: Page | null;
  views: Set<View>;
  operations: Promise<void>;
}

const unavailable = () =>
  browserSync(() => {
    throw new Error("This operation is outside the synthetic browser fixture.");
  });
const controlKeys = new Set([
  "Tab",
  "Enter",
  "Backspace",
  "Delete",
  "Escape",
  "ArrowUp",
  "ArrowDown",
  "ArrowLeft",
  "ArrowRight",
  "Home",
  "End",
  "PageUp",
  "PageDown",
  "Shift",
  "Control",
  "Alt",
  "Meta",
]);

/**
 * The external page adapter only. TeamApiServer, BrowserViewGateway, WebRTC and AttentionRegistry
 * still own admission, authentication, frame-point expansion, pending requests and completion.
 * This local Chromium page does not prove Electron BrowserHost/CDP or real website behavior.
 */
export function createSimulatorBrowserSurface(options: {
  getBrowser: () => Browser | null;
  authenticate: (token: string) => { id: string } | null;
}) {
  const tabs = new Map<string, SurfaceTab>();
  const changed = new Set<Parameters<AgentBrowserHost["onChanged"]>[0]>();
  let activeTabId: string | null = null;
  const secretLengths: number[] = [];
  const inputs: InputMetadata[] = [];
  const state = {
    opened: 0,
    prepared: 0,
    secretCancels: 0,
    released: 0,
    secretSubmitAttempts: 0,
    secretSubmitted: 0,
    secretTakeovers: 0,
    secretLengths,
    completedTakeovers: 0,
    viewsStarted: 0,
    viewsStopped: 0,
    frames: 0,
    pointerDowns: 0,
    wheels: 0,
    keys: 0,
    typedTextLength: 0,
    pageClicks: 0,
    pageKeys: 0,
    pageWheels: 0,
    pageTextLength: 0,
    inputs,
  };
  const listTabs = () => [...tabs.values()].map(({ tab }) => ({ ...tab }));
  const emitChanged = () => {
    for (const listener of changed) listener(listTabs(), activeTabId);
  };
  const requireTab = (id: string) => {
    const tab = tabs.get(id);
    if (!tab) throw new Error("Unknown synthetic browser tab.");
    return tab;
  };
  function openTab(url: string, threadId: string | null, agentId: string | null): BrowserTab {
    if (url !== SYNTHETIC_BROWSER_URL && url !== SYNTHETIC_BROWSER_RELOAD_URL)
      throw new Error("Only the labelled synthetic page can open in this fixture.");
    const tab: BrowserTab = {
      id: `native-simulator-tab-${++state.opened}`,
      title: "Synthetic browser test",
      url,
      loading: false,
      ownerThreadId: threadId,
      ownerAgentId: agentId,
      canGoBack: false,
      canGoForward: false,
    };
    tabs.set(tab.id, { tab, context: null, page: null, views: new Set(), operations: Promise.resolve() });
    activeTabId = tab.id;
    emitChanged();
    return { ...tab };
  }
  function queue<A>(tab: SurfaceTab, operation: () => Promise<A>): Promise<A> {
    const pending = tab.operations.then(operation);
    tab.operations = pending.then(
      () => undefined,
      () => undefined,
    );
    return pending;
  }
  async function pageFor(tab: SurfaceTab): Promise<Page> {
    if (tab.page) return tab.page;
    const browser = options.getBrowser();
    if (!browser) throw new Error("The real host WebRTC browser has not started.");
    const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1 });
    tab.context = context;
    // No fixture action, redirect, resource, download or form can reach an external service.
    await context.route("**/*", (route) => route.abort());
    const page = await context.newPage();
    tab.page = page;
    await page.setContent(`<!doctype html><html><head><meta charset="utf-8"><title>Synthetic browser test</title>
      <style>body{margin:0;background:#edf2f6;color:#17242e;font:24px system-ui,sans-serif}main{padding:40px}h1{font-size:34px;margin:0 0 12px}.note{font-size:20px;color:#4b5c68}button,input{box-sizing:border-box;font:24px system-ui;height:72px;border:2px solid #426477;border-radius:12px}button{position:absolute;left:25%;top:36%;width:50%;background:#e0eaf2}input{position:absolute;left:25%;top:57%;width:50%;padding:12px}#status{position:absolute;left:25%;top:73%;width:60%;font-size:22px}#footer{margin-top:1000px}button[data-clicked]{background:#b9e6c4}</style>
      </head><body><main><h1>Synthetic browser test</h1><p class="note">Local fixture only. No real sign-in or reservation.</p>
      <button id="target">Click the synthetic target</button><input id="notes" aria-label="Synthetic notes" placeholder="Type test text only" autocomplete="off">
      <div id="status">Waiting for browser input</div><p id="footer">Synthetic page end</p></main>
      <script>let clicks=0,keys=0,wheels=0,characters=0;const status=document.getElementById('status');
      function update(){status.textContent='Clicks: '+clicks+' · Keys: '+keys+' · Wheel: '+wheels+' · Text length: '+characters;Object.assign(document.body.dataset,{clicks:String(clicks),keys:String(keys),wheels:String(wheels),characters:String(characters)})}
      document.getElementById('target').addEventListener('click',event=>{clicks++;event.currentTarget.dataset.clicked='1';update()});
      document.addEventListener('keydown',()=>{keys++;update()});document.addEventListener('wheel',()=>{wheels++;update()});
      document.getElementById('notes').addEventListener('input',event=>{characters+=event.currentTarget.value.length;event.currentTarget.value='';update()});
      </script></body></html>`);
    return page;
  }
  async function capture(tab: SurfaceTab) {
    if (tab.views.size === 0) return;
    const page = await pageFor(tab);
    const view = [...tab.views].at(-1);
    const viewport = view?.options.viewport ?? { width: 1280, height: 800 };
    await page.setViewportSize(viewport);
    const image = await page.screenshot({ type: "jpeg", quality: 75 });
    const observed = await page.evaluate(() => ({
      clicks: Number(document.body.dataset.clicks ?? 0),
      keys: Number(document.body.dataset.keys ?? 0),
      wheels: Number(document.body.dataset.wheels ?? 0),
      characters: Number(document.body.dataset.characters ?? 0),
    }));
    state.pageClicks = observed.clicks;
    state.pageKeys = observed.keys;
    state.pageWheels = observed.wheels;
    state.pageTextLength = observed.characters;
    for (const current of tab.views) {
      current.frame({ sequence: ++current.sequence, width: viewport.width, height: viewport.height, image });
      state.frames++;
    }
  }
  const closeTab = (id: string) =>
    browserCall(async () => {
      const tab = requireTab(id);
      tabs.delete(id);
      for (const view of [...tab.views]) view.ended?.("The synthetic browser tab was closed.");
      tab.views.clear();
      await tab.operations;
      await tab.context?.close();
      if (activeTabId === id) activeTabId = [...tabs.keys()].at(-1) ?? null;
      emitChanged();
    });
  const endTakeover: AgentBrowserHost["endTakeover"] = (id, completed) => {
    const surface = tabs.get(id);
    if (!surface) return;
    state.released++;
    if (completed) state.completedTakeovers++;
    const { userControl: _control, ...released } = surface.tab;
    surface.tab = released;
    emitChanged();
  };
  const beginTakeover: AgentBrowserHost["beginTakeover"] = (id) =>
    browserSync(() => {
      const tab = requireTab(id);
      tab.tab = { ...tab.tab, userControl: true };
      emitChanged();
    });
  const agentBrowser: AgentBrowserHost = {
    listTabs,
    beginTakeover,
    endTakeover,
    onChanged: (listener) => {
      changed.add(listener);
      return () => {
        changed.delete(listener);
      };
    },
    onControlChanged: () => () => {},
    onDocumentChanged: () => () => {},
    clearControls: () => {},
    endControl: () => {},
    resolveUploadTarget: unavailable,
    userControlTabFor: () => null,
    awaitUserControlRelease: () => Effect.die(new Error("Agent tool waiting is outside this fixture.")),
    shareTab: () => {},
    unshareThread: () => {},
    close: closeTab,
    clearAgentSession: (agentId) =>
      Effect.forEach(
        listTabs().filter((tab) => tab.ownerAgentId === agentId),
        (tab) => closeTab(tab.id),
      ).pipe(Effect.asVoid),
    agentTab: (id, owner) => {
      const tab = tabs.get(id)?.tab;
      return tab?.ownerAgentId === owner ? { title: tab.title, url: tab.url } : null;
    },
    handleDynamicTool: (params) =>
      browserSync(() => {
        const call = parseBrowserToolCall(params.tool, params.arguments);
        if (call.tool !== "open" || !params.ownerAgentId) throw new Error("Unsupported synthetic agent browser call.");
        const tab = openTab(call.args.url, params.threadId, params.ownerAgentId);
        const result: DynamicToolResult = {
          success: true,
          contentItems: [{ type: "inputText", text: JSON.stringify({ tabId: tab.id }) }],
        };
        return result;
      }),
    prepareSecret: (params) =>
      browserSync(() => {
        const call = parseBrowserToolCall(params.tool, params.arguments);
        if (call.tool !== "submit_secret" || call.args.method !== "password")
          throw new Error("Unsupported synthetic secret call.");
        const surface = requireTab(call.args.tabId);
        if (surface.tab.ownerAgentId !== params.ownerAgentId || surface.tab.ownerThreadId !== params.threadId)
          throw new Error("Synthetic browser owner mismatch.");
        state.prepared++;
        let cancelled = false;
        const prepared: PreparedBrowserSecret = {
          request: { method: "password", origin: "https://example.invalid", digits: 6 },
          agentScriptedOrigin: false,
          vaultFillable: false,
          submit: (secret, vault) =>
            browserSync(() => {
              if (cancelled || vault || !tabs.has(surface.tab.id))
                throw new Error("Synthetic secret request is unavailable.");
              state.secretSubmitAttempts++;
              // Inspect only the public sentinel. No value, hash, prefix or derived token is retained.
              if (secret !== SYNTHETIC_BROWSER_SECRET) throw new Error("Use the labelled synthetic test value only.");
              state.secretLengths.push(secret.length);
              if (surface.tab.url === SYNTHETIC_BROWSER_RELOAD_URL) {
                state.secretTakeovers++;
                return "takeover" as const;
              }
              state.secretSubmitted++;
              return "submitted" as const;
            }),
          cancel: () => {
            if (!cancelled) state.secretCancels++;
            cancelled = true;
          },
        };
        return prepared;
      }),
  };
  const browser: TeamApiBrowser = {
    listTabs,
    getDisplayState: () => ({ tabs: listTabs(), activeTabId }),
    getControlState: () => ({ sessions: [] }),
    open: (url, threadId = null, agentId = null) => browserSync(() => openTab(url, threadId, agentId)),
    activate: (id) =>
      browserSync(() => {
        requireTab(id);
        activeTabId = id;
        emitChanged();
      }),
    navigate: unavailable,
    reload: unavailable,
    stop: unavailable,
    loadUrl: unavailable,
    close: closeTab,
    setVisible: () => Effect.void,
    isPrivate: () => false,
    takeUserControl: (id) => beginTakeover(id),
    releaseUserControl: (id) => endTakeover(id),
    releaseUserControlHeldBy: () => {},
    startTeach: unavailable,
    stopTeach: () => [],
    importSignIn: unavailable,
    capturePreview: (id) =>
      browserCall(async () => {
        const tab = requireTab(id);
        return queue(tab, async () => {
          const page = await pageFor(tab);
          const image = await page.screenshot({ type: "jpeg", quality: 75 });
          const size = page.viewportSize() ?? { width: 1280, height: 800 };
          return { dataUrl: `data:image/jpeg;base64,${image.toString("base64")}`, ...size };
        });
      }),
    startView: (id, frame, ended, viewOptions = {}) =>
      browserCall(async () => {
        const tab = requireTab(id);
        const view: View = { frame, ...(ended ? { ended } : {}), options: viewOptions, sequence: 0 };
        tab.views.add(view);
        state.viewsStarted++;
        try {
          await queue(tab, () => capture(tab));
        } catch (cause) {
          tab.views.delete(view);
          throw cause;
        }
        viewOptions.onCursor?.("default");
        return () =>
          Effect.sync(() => {
            if (tab.views.delete(view)) state.viewsStopped++;
          });
      }),
    dispatchViewInput: (id, input) =>
      browserCall(async () => {
        const tab = requireTab(id);
        await queue(tab, async () => {
          const page = await pageFor(tab);
          await dispatch(page, input);
          let metadata: InputMetadata;
          if (input.type === "pointer") {
            metadata = {
              type: "pointer",
              action: input.action,
              x: input.x,
              y: input.y,
              deltaX: input.deltaX,
              deltaY: input.deltaY,
            };
            if (input.action === "down") state.pointerDowns++;
            if (input.action === "wheel") state.wheels++;
          } else if (input.type === "key") {
            metadata = {
              type: "key",
              action: input.action,
              key: controlKeys.has(input.key) ? input.key : "character",
              textLength: input.text.length,
            };
            state.keys++;
            if (input.action === "char") state.typedTextLength += input.text.length;
          } else {
            metadata = { type: input.type, textLength: input.text.length };
            if (input.type === "paste") state.typedTextLength += input.text.length;
          }
          state.inputs.push(metadata);
          if (state.inputs.length > 256) state.inputs.shift();
          await capture(tab);
        });
      }),
    copyViewSelection: () => Effect.succeed(""),
  };
  const browserView = new BrowserViewGateway({ browser, authenticate: options.authenticate });
  const close = Effect.gen(function* () {
    yield* browserView.stop();
    for (const id of [...tabs.keys()]) yield* closeTab(id);
    changed.clear();
  });
  return { agentBrowser, browser, browserView, state, close };
}

/** These values reach a local, network-blocked page. The adapter retains only lengths and actions. */
async function dispatch(page: Page, input: BrowserViewportInput): Promise<void> {
  if (input.type === "pointer") {
    await page.mouse.move(input.x, input.y);
    if (input.action === "down") await page.mouse.down({ button: input.button, clickCount: input.clickCount });
    else if (input.action === "up") await page.mouse.up({ button: input.button, clickCount: input.clickCount });
    else if (input.action === "wheel") await page.mouse.wheel(input.deltaX, input.deltaY);
  } else if (input.type === "key") {
    if (input.action === "char") {
      if (input.text) await page.keyboard.insertText(input.text);
    }
    // Printable down/up messages carry no text; the following char message inserts it once.
    else if (controlKeys.has(input.key)) {
      if (input.action === "down") await page.keyboard.down(input.key);
      else await page.keyboard.up(input.key);
    }
  } else if (input.type === "paste") await page.keyboard.insertText(input.text);
  else await page.keyboard.press("Backspace");
}
