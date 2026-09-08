// Startup guard for commandcode-bridge (ESM, .mjs).
// 上游 bug:客户端流式请求中途断开时,reply close 触发 AbortController.abort(),
// 下游 Readable destroy 抛出无人监听的 AbortError,整个进程崩溃(server.js:513)。
// 这里兜底:连接中断类错误只记录不退出;其余错误记录并退出(由 watchdog 拉起)。
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const log = (msg) => {
  try {
    fs.appendFileSync(
      path.join(__dirname, "bridge.guard.log"),
      `[guard ${new Date().toISOString()}] ${msg}\n`,
    );
  } catch {}
};

const isAbortLike = (err) =>
  err &&
  (err.name === "AbortError" ||
    err.code === "ECONNRESET" ||
    err.code === "ECONNABORTED" ||
    err.code === "UND_ERR_ABORTED" ||
    err.code === "UND_ERR_SOCKET");

process.on("uncaughtException", (err) => {
  if (isAbortLike(err)) {
    log("swallowed AbortError: " + (err && err.message));
    return; // 连接中断,进程状态健康,继续服务
  }
  log("FATAL uncaughtException: " + (err && err.stack));
  process.exit(1); // 真错误:退出,交给 watchdog 拉起
});

process.on("unhandledRejection", (reason) => {
  if (isAbortLike(reason)) {
    log("swallowed AbortError rejection: " + (reason && reason.message));
    return;
  }
  log("FATAL unhandledRejection: " + (reason && (reason.stack || reason)));
  process.exit(1);
});

await import("./dist/index.js");
