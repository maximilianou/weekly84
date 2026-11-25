import { Pool } from 'pg';

// Connection string is composed by the kit bootstrap from etc.env values
// (see kit/devstack/files/.devstack_env -> DATABASE_URL) and written to .env.
export const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
});

export async function initDb(retries = 5, delayMs = 3000): Promise<void> {
  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      await pool.query(`
        CREATE TABLE IF NOT EXISTS todos (
          id         SERIAL PRIMARY KEY,
          title      TEXT NOT NULL,
          done       BOOLEAN NOT NULL DEFAULT FALSE,
          created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
      `);
      return;
    } catch (err) {
      if (attempt === retries) throw err;
      console.warn(`[db] init attempt ${attempt}/${retries} failed -- retrying...`);
      await new Promise((r) => setTimeout(r, delayMs));
    }
  }
}

/** Round-trip used by GET /api/health -- proves api <-> postgres connectivity. */
export async function dbHealth(): Promise<{
  up: boolean;
  latencyMs: number;
  version: string;
}> {
  const started = Date.now();
  try {
    const res = await pool.query('SELECT version()');
    return {
      up: true,
      latencyMs: Date.now() - started,
      version: String(res.rows[0].version).split(' ').slice(0, 2).join(' '),
    };
  } catch {
    return { up: false, latencyMs: Date.now() - started, version: 'n/a' };
  }
}
