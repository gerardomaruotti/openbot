import { execFile } from "node:child_process";
import { lstat, readFile, realpath, rename, unlink, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import { isDynamicRecord, isString } from "@openbot/contracts/runtime-values";

/** Real filesystem failure in a fresh UUID simulator app, registered by its runner. */
export function createNativeStorageFaults(root: string) {
  let blocked: { directory: string; saved: string } | null = null;
  const state = { failures: 0, restores: 0 };

  async function failWrites() {
    if (blocked) throw new Error("Native storage fault is already active.");
    const registration = JSON.parse(await readFile(join(root, "native-container.json"), "utf8"));
    if (
      !isDynamicRecord(registration) ||
      !isString(registration.bundleID) ||
      !/^com\.gerardomaruotti\.openbot\.native\.simulator\.run[0-9a-f]{32}$/.test(registration.bundleID) ||
      !isString(registration.deviceID) ||
      !/^[0-9A-F-]{36}$/.test(registration.deviceID) ||
      !isString(registration.container)
    )
      throw new Error("No owned native simulator container.");
    const parent = join(
      homedir(),
      "Library/Developer/CoreSimulator/Devices",
      registration.deviceID,
      "data/Containers/Data/Application",
    );
    // Xcode can replace the data container when test-without-building installs
    // its host app. Resolve metadata now; never launch or drive UI with simctl.
    const { stdout } = await promisify(execFile)(
      "xcrun",
      ["simctl", "get_app_container", registration.deviceID, registration.bundleID, "data"],
      { maxBuffer: 16 * 1024 },
    );
    const currentContainer = stdout.trim();
    const container = await realpath(currentContainer);
    if (
      container !== resolve(currentContainer) ||
      !container.startsWith(`${parent}/`) ||
      !/^[0-9A-F-]{36}$/.test(container.slice(parent.length + 1))
    )
      throw new Error("Unexpected native container path.");
    const directory = join(container, "Library/Application Support/NativeWorkspace");
    const saved = `${directory}.native-fixture-preserved`;
    if (!(await lstat(directory)).isDirectory()) throw new Error("No native workspace to preserve.");
    await rename(directory, saved);
    blocked = { directory, saved };
    try {
      await writeFile(directory, "Synthetic native storage fault", { flag: "wx", mode: 0o600 });
    } catch (error) {
      await rename(saved, directory);
      blocked = null;
      throw error;
    }
    state.failures += 1;
    return { blocked: true };
  }

  async function restoreWrites() {
    if (!blocked) return { blocked: false };
    const { directory, saved } = blocked;
    const obstruction = await lstat(directory);
    if (!obstruction.isFile() || (await readFile(directory, "utf8")) !== "Synthetic native storage fault") {
      throw new Error("Native storage obstruction changed; preserved workspace was not touched.");
    }
    await unlink(directory);
    await rename(saved, directory);
    blocked = null;
    state.restores += 1;
    return { blocked: false };
  }

  return { state, failWrites, restoreWrites };
}
