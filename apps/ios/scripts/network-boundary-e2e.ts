import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import { resolve } from "node:path";
import { createOpenBotLogger } from "@openbot/logging";

const root = resolve(import.meta.dirname, "../../..");
const output = resolve(root, ".openbot-build/native-ios/network-e2e");
const logger = createOpenBotLogger("native-ios-network-e2e");
mkdirSync(output, { recursive: true });

function run(command: string, args: string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: root, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (data) => {
      stdout += String(data);
    });
    child.stderr.on("data", (data) => {
      stderr += String(data);
    });
    child.on("error", reject);
    child.on("exit", (code) =>
      code === 0
        ? resolve(stdout)
        : reject(new Error(`Network E2E process failed (${code}): ${stderr.slice(0, 2000)} ${stdout.slice(0, 500)}`)),
    );
  });
}

function listen(server: Server): Promise<string> {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        reject(new Error("No fixture address"));
        return;
      }
      resolve(`http://127.0.0.1:${address.port}`);
    });
  });
}

const sources = [
  "apps/ios/Sources/Connection/ConnectionTypes.swift",
  "apps/ios/Sources/Connection/AccountHTTPClient.swift",
  "apps/ios/scripts/network-boundary-e2e.swift",
];
const common = [
  "swiftc",
  "-swift-version",
  "6",
  "-default-isolation",
  "MainActor",
  "-target",
  "arm64-apple-macos14.0",
  ...sources,
];
let foreignRequests = 0;
let authorizedSameOrigin = false;
const foreign = createServer((_request, response) => {
  foreignRequests += 1;
  response.end("forbidden destination");
});
let foreignOrigin = "";
const primary = createServer((request, response) => {
  if (request.url === "/same") {
    response.writeHead(302, { location: "/final" });
    response.end();
  } else if (request.url === "/final") {
    authorizedSameOrigin = request.headers.authorization === "Bearer native-synthetic-boundary-fixture";
    response.end("same-origin");
  } else if (request.url === "/cross") {
    response.writeHead(302, { location: `${foreignOrigin}/leak` });
    response.end();
  } else if (request.url === "/large") {
    response.writeHead(200, { "content-length": "2097153" });
    response.end(Buffer.alloc(2_097_153, 120));
  } else {
    response.writeHead(404);
    response.end();
  }
});
try {
  foreignOrigin = await listen(foreign);
  const origin = await listen(primary);
  const debugExecutable = resolve(output, "debug-boundary");
  await run("xcrun", [...common, "-D", "DEBUG", "-o", debugExecutable]);
  const debug = JSON.parse(await run(debugExecutable, [origin, foreignOrigin]));
  if (foreignRequests !== 0 || !authorizedSameOrigin) throw new Error("The live network boundary failed.");
  const releaseExecutable = resolve(output, "release-boundary");
  await run("xcrun", [...common, "-o", releaseExecutable]);
  const release = JSON.parse(await run(releaseExecutable, ["--release-policy"]));
  const report = { passed: true, ...debug, ...release, foreignRequests, authorizedSameOrigin };
  writeFileSync(resolve(output, "report.json"), `${JSON.stringify(report, null, 2)}\n`);
  logger.info("Native account network boundary passed.", report);
} finally {
  primary.closeAllConnections();
  primary.close();
  foreign.closeAllConnections();
  foreign.close();
}
