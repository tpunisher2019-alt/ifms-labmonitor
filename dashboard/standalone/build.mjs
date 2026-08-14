import { mkdir, copyFile } from "node:fs/promises";
await mkdir(new URL("../dist/server/", import.meta.url), { recursive: true });
await mkdir(new URL("../dist/client/", import.meta.url), { recursive: true });
await copyFile(new URL("worker.js", import.meta.url), new URL("../dist/server/index.js", import.meta.url));
await copyFile(new URL("../public/og.png", import.meta.url), new URL("../dist/client/og.png", import.meta.url));
console.log("LabMonitor dashboard build complete");
