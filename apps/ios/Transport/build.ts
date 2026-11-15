import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

const result = await Bun.build({
  entrypoints: [resolve(import.meta.dirname, "team-peer.ts")],
  target: "browser",
  format: "iife",
  minify: true,
  define: { "process.env.NODE_ENV": JSON.stringify("production") },
  plugins: [
    {
      name: "native-without-translations",
      setup(build) {
        build.onLoad({ filter: /packages[\\/]i18n[\\/]src[\\/]source-catalogs\.ts$/ }, () => ({
          contents: "export function sourceTranslation() { return undefined; }",
          loader: "ts",
        }));
      },
    },
  ],
});
if (!result.success || !result.outputs[0]) throw new Error("The native transport bundle did not build.");
const script = (await result.outputs[0].text()).replaceAll("</script", "<\\/script");
const output = resolve(import.meta.dirname, "../Resources/Transport/team-peer.html");
mkdirSync(dirname(output), { recursive: true });
writeFileSync(
  output,
  `<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; connect-src wss: ws:"></head><body><script>${script}</script></body></html>\n`,
);
