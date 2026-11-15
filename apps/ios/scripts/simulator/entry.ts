import { mkdirSync, mkdtempSync } from "node:fs";
import { join, resolve } from "node:path";
import { plugin } from "bun";

const parent = resolve(".openbot-build/native-ios");
mkdirSync(parent, { recursive: true });
const root = process.argv[2] ? resolve(process.argv[2]) : mkdtempSync(join(parent, "simulator-service-"));
mkdirSync(root, { recursive: true });
plugin({
  name: "native-fixture-electron-boundary",
  setup(build) {
    class Unavailable {
      constructor() {
        throw new Error("Electron UI is unavailable in the native simulator fixture.");
      }
    }
    build.module("electron", () => ({
      loader: "object",
      exports: {
        app: {
          getPath: (name: string) => resolve(root, name),
          getVersion: () => "0.0.0-native-fixture",
          isPackaged: false,
          on: () => undefined,
        },
        BrowserWindow: Object.assign(Unavailable, { getAllWindows: () => [] }),
        MessageChannelMain: Unavailable,
        Notification: Object.assign(Unavailable, { isSupported: () => false }),
        clipboard: {},
        dialog: {},
        ipcMain: { handle: () => undefined, removeHandler: () => undefined, on: () => undefined },
        nativeImage: {},
        net: {},
        powerMonitor: { on: () => undefined },
        safeStorage: { isEncryptionAvailable: () => false },
        screen: {},
        session: {},
        shell: {
          openExternal: () => {
            throw new Error("External navigation is disabled in fixture.");
          },
        },
        systemPreferences: {},
        webContents: { getAllWebContents: () => [] },
      },
    }));
  },
});
const { startFixture } = await import("./service");
await startFixture(root);
