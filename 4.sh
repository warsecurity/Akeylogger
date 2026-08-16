#!/bin/bash

# Lab Log Server Generator
# Creates all server-side files and folders in the current directory

echo "[+] Creating server files..."

# Create public directory if it doesn't exist
mkdir -p public

# ---------- package.json ----------
cat > package.json <<'EOF'
{
  "name": "android-log-server",
  "version": "1.0.0",
  "description": "Lab log server for Android malware analysis",
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

// Middleware
app.use(express.json());
app.use(express.urlencoded({ extended: true }));
app.use(express.static(path.join(__dirname, 'public')));

// CORS for lab flexibility
app.use((req, res, next) => {
  res.header('Access-Control-Allow-Origin', '*');
  res.header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.header('Access-Control-Allow-Headers', 'Content-Type');
  next();
});

// In-memory log store
let logs = [];

// Load existing logs from file if present
if (fs.existsSync(LOG_FILE)) {
  try {
    const raw = fs.readFileSync(LOG_FILE, 'utf8');
    logs = raw.split('\n').filter(line => line.trim() !== '').map(line => JSON.parse(line));
  } catch (err) {
    console.error('Failed to load logs file:', err.message);
  }
}

// Helper to append log to file
function appendLogToFile(entry) {
  fs.appendFile(LOG_FILE, JSON.stringify(entry) + '\n', (err) => {
    if (err) console.error('Failed to write log:', err.message);
  });
}

// POST endpoint for APK to send logs
app.post('/log', (req, res) => {
  const entry = {
    timestamp: new Date().toISOString(),
    ip: req.ip,
    headers: req.headers,
    body: req.body
  };

  logs.push(entry);
  appendLogToFile(entry);

  console.log('[+] New log:', JSON.stringify(entry, null, 2));

  // Send to dashboard in real-time
  io.emit('newLog', entry);

  res.status(200).json({ status: 'ok' });
});

// GET endpoint to fetch all logs
app.get('/logs', (req, res) => {
  res.json(logs);
});

// Clear logs endpoint (optional)
app.delete('/logs', (req, res) => {
  logs = [];
  fs.writeFile(LOG_FILE, '', () => {});
  io.emit('logsCleared');
  res.status(200).json({ status: 'cleared' });
});

// Start server
server.listen(PORT, () => {
  console.log(`[+] Log server running at http://localhost:${PORT}`);
  console.log(`[+] Dashboard: http://localhost:${PORT}`);
  console.log(`[+] APK endpoint: http://localhost:${PORT}/log`);
});
EOF

# ---------- public/index.html ----------
cat > public/index.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Android Log Dashboard</title>
  <style>
    body {
      font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
      background: #1e1e1e;
      color: #e0e0e0;
      margin: 0;
      padding: 20px;
    }
    h1 {
      color: #4fc3f7;
    }
    .controls {
      margin-bottom: 20px;
    }
    button {
      background: #333;
      color: #fff;
      border: 1px solid #555;
      padding: 8px 16px;
      cursor: pointer;
      border-radius: 4px;
    }
    button:hover {
      background: #444;
    }
    #logContainer {
      max-height: 80vh;
      overflow-y: auto;
      background: #2a2a2a;
      padding: 10px;
      border-radius: 6px;
    }
    .log-entry {
      background: #333;
      border-left: 4px solid #4fc3f7;
      margin-bottom: 10px;
      padding: 10px;
      border-radius: 4px;
      font-size: 14px;
    }
    .log-time {
      color: #ffd54f;
      font-weight: bold;
    }
    .log-ip {
      color: #81c784;
    }
    pre {
      margin: 5px 0 0;
      white-space: pre-wrap;
      word-break: break-all;
      color: #e0e0e0;
    }
  </style>
</head>
<body>
  <h1>📡 Android Log Dashboard</h1>
  <div class="controls">
    <button onclick="clearLogs()">Clear Logs</button>
  </div>
  <div id="logContainer">
    <!-- Logs appear here -->
  </div>

  <script src="/socket.io/socket.io.js"></script>
  <script>
    const logContainer = document.getElementById('logContainer');

    // Fetch existing logs on load
    fetch('/logs')
      .then(res => res.json())
      .then(logs => {
        logs.forEach(entry => addLogEntry(entry));
      })
      .catch(err => console.error('Failed to fetch logs:', err));

    // Listen for new logs via Socket.IO
    const socket = io();
    socket.on('newLog', (entry) => {
      addLogEntry(entry, true);
    });

    socket.on('logsCleared', () => {
      logContainer.innerHTML = '';
    });

    function addLogEntry(entry, prepend = false) {
      const div = document.createElement('div');
      div.className = 'log-entry';
      div.innerHTML = `
        <span class="log-time">${entry.timestamp}</span> |
        <span class="log-ip">${entry.ip}</span>
        <pre>${JSON.stringify(entry.body, null, 2)}</pre>
      `;
      if (prepend) {
        logContainer.prepend(div);
      } else {
        logContainer.appendChild(div);
      }
    }

    function clearLogs() {
      fetch('/logs', { method: 'DELETE' })
        .then(res => res.json())
        .then(data => console.log(data))
        .catch(err => console.error('Clear failed:', err));
    }
  </script>
</body>
</html>
EOF

echo "[+] All files created successfully."
echo "[+] Directory structure:"
find . -maxdepth 2 -type f -not -path './node_modules/*' -print
