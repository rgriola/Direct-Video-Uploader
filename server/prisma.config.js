// Last updated: May 13, 2026 - 2:14pm - GitHub Copilot (GPT-5.3-Codex)
import "dotenv/config";
import { spawnSync } from "node:child_process";
import { defineConfig } from "prisma/config";

function isMigrateDeployInvocation(argv = process.argv) {
  return argv.includes("migrate") && argv.includes("deploy");
}

function runBaselinePreflight() {
  const result = spawnSync("node", ["scripts/prisma-baseline-if-needed.js"], {
    stdio: "inherit",
    env: {
      ...process.env,
      PRISMA_BASELINE_PREFLIGHT_RUNNING: "1",
    },
  });

  if (result.status !== 0) {
    throw new Error(`Prisma baseline preflight failed with exit code ${result.status ?? "unknown"}`);
  }
}

if (isMigrateDeployInvocation() && process.env.PRISMA_BASELINE_PREFLIGHT_RUNNING !== "1") {
  runBaselinePreflight();
}

export default defineConfig({
  schema: "prisma/schema.prisma",
  migrations: {
    path: "prisma/migrations",
  },
  datasource: {
    url: process.env["DATABASE_URL"],
  },
});
