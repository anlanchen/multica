// Bundles upstream-entry.ts against the upstream checkout.
//   UPSTREAM=/path/to/multica node build.mjs
import { build } from "esbuild";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const upstream = process.env.UPSTREAM ?? path.resolve(here, "../../../.build/upstream/multica");

await build({
  entryPoints: [path.join(here, "upstream-entry.ts")],
  bundle: true,
  format: "esm",
  platform: "node",
  target: "node22",
  outfile: path.join(here, "dist/upstream.mjs"),
  alias: { "@upstream": upstream },
  nodePaths: [path.join(here, "node_modules")],
  logLevel: "warning",
});
console.log("bundled upstream code from", upstream);
