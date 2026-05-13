// Last updated: May 13, 2026 - 2:05pm - GitHub Copilot (GPT-5.3-Codex)
import 'dotenv/config';
import { execFileSync } from 'node:child_process';
import { Client } from 'pg';

const BASELINE_MIGRATION = process.env.PRISMA_BASELINE_MIGRATION || '20260512132446_baseline';
const SCHEMA_NAME = process.env.PRISMA_SCHEMA || 'public';

function quoteIdent(identifier) {
  return `"${identifier.replace(/"/g, '""')}"`;
}

async function hasNonMigrationTables(client) {
  const result = await client.query(
    `SELECT table_name
     FROM information_schema.tables
     WHERE table_schema = $1
       AND table_type = 'BASE TABLE'`,
    [SCHEMA_NAME],
  );

  return result.rows.some((row) => row.table_name !== '_prisma_migrations');
}

async function isBaselineRecorded(client) {
  const migrationTableExists = await client.query(
    `SELECT 1
     FROM information_schema.tables
     WHERE table_schema = $1
       AND table_name = '_prisma_migrations'
     LIMIT 1`,
    [SCHEMA_NAME],
  );

  if (migrationTableExists.rowCount === 0) {
    return false;
  }

  const schemaIdent = quoteIdent(SCHEMA_NAME);
  const baselineResult = await client.query(
    `SELECT 1
     FROM ${schemaIdent}."_prisma_migrations"
     WHERE migration_name = $1
     LIMIT 1`,
    [BASELINE_MIGRATION],
  );

  return baselineResult.rowCount > 0;
}

async function main() {
  if (!process.env.DATABASE_URL) {
    console.log('[baseline] DATABASE_URL is not set; skipping baseline check.');
    return;
  }

  const client = new Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();

  let shouldResolveBaseline = false;

  try {
    const hasExistingSchema = await hasNonMigrationTables(client);

    if (!hasExistingSchema) {
      console.log('[baseline] Schema is empty or migration-only; baseline resolve not required.');
      return;
    }

    const baselineRecorded = await isBaselineRecorded(client);
    if (baselineRecorded) {
      console.log(`[baseline] Migration ${BASELINE_MIGRATION} already marked as applied.`);
      return;
    }

    shouldResolveBaseline = true;
  } finally {
    await client.end();
  }

  if (!shouldResolveBaseline) {
    return;
  }

  console.log(`[baseline] Existing schema detected without ${BASELINE_MIGRATION}; marking baseline as applied.`);
  execFileSync('npx', ['prisma', 'migrate', 'resolve', '--applied', BASELINE_MIGRATION], {
    stdio: 'inherit',
  });
  console.log('[baseline] Baseline resolve complete.');
}

main().catch((error) => {
  console.error({
    event: 'prisma.baselineCheck.failed',
    message: error instanceof Error ? error.message : String(error),
  });
  process.exit(1);
});