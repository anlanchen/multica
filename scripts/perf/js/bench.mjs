// Runs upstream Multica's own hot-path JavaScript in V8 on the fixtures
// written by `multica-bench --dump <dir>`, mirroring what the Electron
// renderer does on its single main thread.
//
//   node build.mjs && node --expose-gc bench.mjs <fixture-dir> [--json out.json]
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { performance } from "node:perf_hooks";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import Markdown from "react-markdown";
import { unified } from "unified";
import remarkParse from "remark-parse";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import remarkBreaks from "remark-breaks";
import remarkCjkFriendly from "remark-cjk-friendly/parseOnly";
import remarkRehype from "remark-rehype";
import rehypeRaw from "rehype-raw";
import rehypeSanitize from "rehype-sanitize";
import rehypeKatex from "rehype-katex";
import * as up from "./dist/upstream.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const dir = process.argv[2] ?? path.resolve(here, "../../../.build/perf/fixtures");
const jsonOut = process.argv.includes("--json") ? process.argv[process.argv.indexOf("--json") + 1] : null;
const lines = (name) => fs.readFileSync(path.join(dir, name), "utf8").split("\n").filter(Boolean);

function best(runs, fn) {
  fn();
  let min = Infinity;
  for (let i = 0; i < runs; i++) {
    globalThis.gc?.();
    const t0 = performance.now();
    fn();
    min = Math.min(min, performance.now() - t0);
  }
  return min;
}
const fmtMs = (v) => (v < 1 ? v.toFixed(3) : v.toFixed(1)) + " ms";
const fmtUs = (v, n) => ((v * 1000) / n).toFixed(2) + " µs";
const out = [];
const results = {};
const row = (...c) => out.push("| " + c.join(" | ") + " |");

// 1. task:message fan-out: ws-client JSON.parses every frame, then the
// realtime sync drops frames for tasks nobody is viewing (MUL-6396).
{
  const frames = lines("fanout.jsonl");
  const bytes = frames.reduce((n, f) => n + Buffer.byteLength(f), 0);
  const watched = new Set(["task-0"]);
  let kept = 0;
  const t = best(3, () => {
    kept = 0;
    for (const f of frames) {
      const msg = JSON.parse(f);
      if (msg.type === "task:message" && watched.has(msg.payload.task_id)) kept++;
    }
  });
  results.fanout = { frames: frames.length, bytes, totalMs: t, perFrameUs: (t * 1000) / frames.length, kept };
  out.push(`### 1. \`task:message\` fan-out — ${frames.length} frames, ${Math.round(bytes / 1024)} KiB, 1 run on screen`, "");
  row("Strategy", "Total", "Per frame", "Messages kept");
  row("---", "---", "---", "---");
  row("Upstream (V8): JSON.parse every frame, drop unwatched tasks", fmtMs(t), fmtUs(t, frames.length), String(kept));
  out.push("");
}

// 2. Live transcript: each 100 ms flush JSON.parses the new frames, then the
// run view rebuilds buildTimeline → buildSteps → groupSteps over the whole
// run (inline-comment-run.tsx). Redaction is memoized per message object
// (MUL-7227), so message objects stay stable across flushes here too.
{
  const frames = lines("transcript.jsonl");
  const flush = 10;
  const checkpoints = [500, 1000, 3000];
  const perFlush = [];
  const runOnce = () => {
    const msgs = [];
    const times = [];
    for (let i = 0; i < frames.length; i += flush) {
      const t0 = performance.now();
      for (const f of frames.slice(i, i + flush)) msgs.push(JSON.parse(f).payload);
      const rows = up.groupSteps(up.buildSteps(up.buildTimeline(msgs)));
      if (rows.length === 0) throw new Error("no rows");
      times.push(performance.now() - t0);
    }
    return times;
  };
  runOnce();
  const runs = [runOnce(), runOnce(), runOnce()];
  for (let k = 0; k < runs[0].length; k++) perFlush.push(Math.min(...runs.map((r) => r[k])));
  const avgEnding = (n) => {
    const end = n / flush;
    const s = perFlush.slice(Math.max(0, end - 10), end);
    return s.reduce((a, b) => a + b, 0) / s.length;
  };
  results.transcript = Object.fromEntries(checkpoints.map((n) => [n, avgEnding(n)]));
  out.push(`### 2. Live transcript — one flush (${flush} new messages) by transcript length`, "");
  row("Strategy", "@500 msgs", "@1000 msgs", "@3000 msgs");
  row("---", "---", "---", "---");
  row("Upstream (V8), main thread: parse + buildTimeline/buildSteps/groupSteps", ...checkpoints.map((n) => fmtMs(avgEnding(n))));
  out.push("");
}

// 4. Timestamps: the UI parses API timestamps with `new Date(...)`.
{
  const stamps = lines("timestamps.txt");
  let acc = 0;
  const t = best(3, () => {
    acc = 0;
    for (const s of stamps) acc += new Date(s).getTime();
  });
  results.timestamps = { count: stamps.length, totalMs: t, perValueUs: (t * 1000) / stamps.length };
  out.push(`### 4. RFC 3339 parsing — ${stamps.length} timestamps`, "");
  row("Parser", "Total", "Per value");
  row("---", "---", "---");
  row("Upstream (V8): new Date(s)", fmtMs(t), fmtUs(t, stamps.length));
  out.push("");
}

// 5. Markdown: RichContent = preprocessMarkdown → react-markdown with the
// same remark/rehype plugin lists (rich-content.tsx).
{
  const docs = lines("markdown.jsonl").map((l) => JSON.parse(l));
  const bytes = docs.reduce((n, d) => n + Buffer.byteLength(d), 0);
  const preprocess = (md) =>
    up.preprocessFileCards(up.preprocessLinks(up.preprocessIssueIdentifiers(up.preprocessMentionShortcodes(up.stripChannelMediaMarkers(md)))), "");
  const remarkPlugins = [[remarkMath, { singleDollarTextMath: false }], remarkBreaks, [remarkGfm, { singleTilde: false }], remarkCjkFriendly, up.remarkRepairCjkStrongTrailingWhitespace];
  const rehypePlugins = [rehypeRaw, [rehypeSanitize, up.markdownSanitizeSchema], rehypeKatex];
  const processor = unified().use(remarkParse).use(remarkPlugins).use(remarkRehype, { allowDangerousHtml: true }).use(rehypePlugins);
  const toTree = best(5, () => {
    for (const d of docs) processor.runSync(processor.parse(preprocess(d)));
  });
  const toMarkup = best(3, () => {
    for (const d of docs) {
      renderToStaticMarkup(createElement(Markdown, { remarkPlugins, rehypePlugins, urlTransform: up.markdownUrlTransform, children: preprocess(d) }));
    }
  });
  results.markdown = { docs: docs.length, bytes, toTreeMs: toTree, toMarkupMs: toMarkup };
  out.push(`### 5. Markdown — ${docs.length} comments (${Math.round(bytes / 1024)} KiB), preprocess + parse to a render tree`, "");
  row("Pipeline", "Total", "Per comment");
  row("---", "---", "---");
  row("Upstream (V8): preprocessMarkdown + remark/rehype → hast", fmtMs(toTree), fmtUs(toTree, docs.length));
  row("Upstream (V8): … + react-markdown → React elements → static markup", fmtMs(toMarkup), fmtUs(toMarkup, docs.length));
  out.push("");
}

console.log(`## upstream JS on V8 (Node ${process.versions.node}, V8 ${process.versions.v8})\n`);
console.log(out.join("\n"));
if (jsonOut) fs.writeFileSync(jsonOut, JSON.stringify({ node: process.versions.node, v8: process.versions.v8, ...results }, null, 2));
