import { useCallback, useEffect, useState } from 'react';

type Health = {
  status: string;
  db: { up: boolean; latencyMs: number; version: string };
  uptimeSec: number;
};
type Todo = { id: number; title: string; done: boolean };

// All calls go to /api — Vite proxies them to the API inside the sandbox,
// which in turn talks to Postgres. web → api → postgres, one browser origin.
export default function App() {
  const [health, setHealth] = useState<Health | null>(null);
  const [todos, setTodos] = useState<Todo[]>([]);
  const [title, setTitle] = useState('');
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      const [h, t] = await Promise.all([
        fetch('/api/health').then((r) => r.json()),
        fetch('/api/todos').then((r) => r.json()),
      ]);
      setHealth(h as Health);
      setTodos(t as Todo[]);
      setError(null);
    } catch (e) {
      setError(String(e));
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const add = async () => {
    const t = title.trim();
    if (!t) return;
    await fetch('/api/todos', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title: t }),
    });
    setTitle('');
    void refresh();
  };

  const remove = async (id: number) => {
    await fetch(`/api/todos/${id}`, { method: 'DELETE' });
    void refresh();
  };

  return (
    <main style={{ fontFamily: 'system-ui', maxWidth: 560, margin: '3rem auto', padding: '0 1rem' }}>
      <h1>devstack · web</h1>

      <section style={{ padding: '.75rem 1rem', border: '1px solid #ddd', borderRadius: 8 }}>
        <strong>API health</strong>
        {health ? (
          <ul>
            <li>api: {health.status} · uptime {health.uptimeSec}s</li>
            <li>
              postgres: {health.db.up ? 'up' : 'DOWN'} · {health.db.latencyMs}ms ·{' '}
              {health.db.version}
            </li>
          </ul>
        ) : (
          <p>{error ?? 'connecting…'}</p>
        )}
      </section>

      <form
        onSubmit={(e) => {
          e.preventDefault();
          void add();
        }}
        style={{ display: 'flex', gap: 8, margin: '1rem 0' }}
      >
        <input
          value={title}
          onChange={(e) => setTitle(e.target.value)}
          placeholder="new todo (stored in postgres)"
          style={{ flex: 1, padding: '.5rem' }}
        />
        <button type="submit">add</button>
      </form>

      <ul style={{ listStyle: 'none', padding: 0 }}>
        {todos.map((t) => (
          <li key={t.id} style={{ display: 'flex', gap: 8, alignItems: 'center', padding: '.35rem 0' }}>
            <span style={{ flex: 1 }}>{t.title}</span>
            <button onClick={() => void remove(t.id)}>delete</button>
          </li>
        ))}
      </ul>
    </main>
  );
}
