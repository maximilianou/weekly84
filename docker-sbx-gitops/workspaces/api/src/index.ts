import express from 'express';
import { dbHealth, initDb, pool } from './db.js';

const app = express();
app.use(express.json());

// Dev CORS. The Vite dev server proxies /api (same origin), so this only
// matters when the frontend calls the API cross-origin directly.
app.use((req, res, next) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,DELETE,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') {
    res.sendStatus(204);
    return;
  }
  next();
});

app.get('/api/health', async (_req, res) => {
  res.json({
    status: 'ok',
    service: 'devstack-api',
    db: await dbHealth(),
    uptimeSec: Math.round(process.uptime()),
  });
});

app.get('/api/todos', async (_req, res) => {
  const { rows } = await pool.query(
    'SELECT id, title, done, created_at FROM todos ORDER BY id',
  );
  res.json(rows);
});

app.post('/api/todos', async (req, res) => {
  const title = String(req.body?.title ?? '').trim();
  if (!title) {
    res.status(400).json({ error: 'title is required' });
    return;
  }
  const { rows } = await pool.query(
    'INSERT INTO todos (title) VALUES ($1) RETURNING *',
    [title],
  );
  res.status(201).json(rows[0]);
});

app.delete('/api/todos/:id', async (req, res) => {
  const { rowCount } = await pool.query('DELETE FROM todos WHERE id = $1', [
    Number(req.params.id),
  ]);
  res.json({ deleted: rowCount ?? 0 });
});

const port = Number(process.env.API_PORT ?? 4000);

initDb()
  .then(() => {
    // 0.0.0.0 so connections forwarded by the sbx runtime are accepted.
    app.listen(port, '0.0.0.0', () => {
      console.log(`[api] listening on 0.0.0.0:${port} (db: ${process.env.DATABASE_URL ? 'configured' : 'missing!'})`);
    });
  })
  .catch((err) => {
    console.error('[api] postgres unreachable during init', err);
    process.exit(1);
  });
