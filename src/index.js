/*
  demo-12-factor-app
  Node.js + Express minimal API to demonstrate 12-Factor principles
*/
const express = require('express');

const app = express();
app.use(express.json());

// Config from environment (12-Factor: Config)
const PORT = process.env.PORT || 3000;
const APP_NAME = process.env.APP_NAME || 'demo-12-factor-app';
const LOG_LEVEL = process.env.LOG_LEVEL || 'info';

// In-memory data store (will be replaced by Postgres later)
const quotes = [
  { id: 1, text: 'Simplicity is the soul of efficiency.' },
  { id: 2, text: 'Premature optimization is the root of all evil.' },
];
let nextId = quotes.length + 1;

// Health endpoint for liveness/readiness probes
app.get('/healthz', (_req, res) => {
  res.status(200).json({ status: 'ok', app: APP_NAME, uptime: process.uptime() });
});

// Basic routes
app.get('/', (_req, res) => {
  res.json({ app: APP_NAME, message: 'Welcome to the 12-Factor demo app FIAP - New Version!! Agora vaiii! PORTA 80' });
});

app.get('/quotes', (_req, res) => {
  res.json(quotes);
});

app.post('/quotes', (req, res) => {
  const { text } = req.body || {};
  if (!text) return res.status(400).json({ error: 'text is required' });
  const item = { id: nextId++, text };
  quotes.push(item);
  res.status(201).json(item);
});

app.delete('/quotes/:id', (req, res) => {
  const id = Number(req.params.id);
  const idx = quotes.findIndex(q => q.id === id);
  if (idx === -1) return res.status(404).json({ error: 'not found' });
  const removed = quotes.splice(idx, 1)[0];
  res.json(removed);
});

const server = app.listen(PORT, () => {
  console.log(`[${LOG_LEVEL}] ${APP_NAME} listening on port ${PORT}`);
});

// Disposability: graceful shutdown on signals
function shutdown(signal) {
  console.log(`[info] Received ${signal}, shutting down gracefully...`);
  server.close(() => {
    console.log('[info] HTTP server closed');
    process.exit(0);
  });
  // Force exit if not closed in time
  setTimeout(() => {
    console.warn('[warn] Force exiting after timeout');
    process.exit(1);
  }, 10000).unref();
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
