FROM node:18-alpine

WORKDIR /app

# Install ws library
RUN npm init -y && npm install ws

# Create WebSocket echo server
RUN cat > server.js << 'EOF'
const http = require('http');
const WebSocket = require('ws');

const PORT = process.env.PORT || 8080;
const SERVICE_NAME = process.env.SERVICE_NAME || 'websocket-service';

// Create HTTP server
const server = http.createServer((req, res) => {
    if (req.url === '/health') {
        res.writeHead(200, { 'Content-Type': 'text/plain' });
        res.end('OK\n');
    } else if (req.url === '/') {
        // Serve a simple WebSocket test page
        res.writeHead(200, { 'Content-Type': 'text/html' });
        res.end(`
<!DOCTYPE html>
<html>
<head>
    <title>WebSocket Echo Test</title>
</head>
<body>
    <h1>WebSocket Echo Service</h1>
    <div id="status">Connecting...</div>
    <input type="text" id="message" placeholder="Enter message" />
    <button onclick="sendMessage()">Send</button>
    <div id="messages"></div>
    <script>
        const ws = new WebSocket('ws://' + window.location.host + '/ws');
        const status = document.getElementById('status');
        const messages = document.getElementById('messages');

        ws.onopen = () => {
            status.textContent = 'Connected';
            status.style.color = 'green';
        };

        ws.onmessage = (event) => {
            const msg = document.createElement('div');
            msg.textContent = 'Echo: ' + event.data;
            messages.appendChild(msg);
        };

        ws.onerror = (error) => {
            status.textContent = 'Error: ' + error;
            status.style.color = 'red';
        };

        ws.onclose = () => {
            status.textContent = 'Disconnected';
            status.style.color = 'orange';
        };

        function sendMessage() {
            const input = document.getElementById('message');
            if (input.value && ws.readyState === WebSocket.OPEN) {
                ws.send(input.value);
                const msg = document.createElement('div');
                msg.textContent = 'Sent: ' + input.value;
                messages.appendChild(msg);
                input.value = '';
            }
        }
    </script>
</body>
</html>
        `);
    } else {
        res.writeHead(404);
        res.end('Not found');
    }
});

// Create WebSocket server
const wss = new WebSocket.Server({ server, path: '/ws' });

wss.on('connection', (ws, req) => {
    console.log(`New WebSocket connection from ${req.socket.remoteAddress}`);

    // Send welcome message
    ws.send(JSON.stringify({
        type: 'welcome',
        service: SERVICE_NAME,
        timestamp: new Date().toISOString(),
        message: 'Connected to WebSocket echo service'
    }));

    // Echo messages back
    ws.on('message', (message) => {
        console.log(`Received: ${message}`);

        // Parse message if it's JSON
        let response;
        try {
            const parsed = JSON.parse(message);
            response = {
                type: 'echo',
                service: SERVICE_NAME,
                timestamp: new Date().toISOString(),
                received: parsed,
                echo: parsed
            };
        } catch (e) {
            // Plain text message
            response = {
                type: 'echo',
                service: SERVICE_NAME,
                timestamp: new Date().toISOString(),
                received: message.toString(),
                echo: message.toString()
            };
        }

        ws.send(JSON.stringify(response));
    });

    ws.on('close', () => {
        console.log('WebSocket connection closed');
    });

    ws.on('error', (error) => {
        console.error('WebSocket error:', error);
    });

    // Send ping every 30 seconds to keep connection alive
    const pingInterval = setInterval(() => {
        if (ws.readyState === WebSocket.OPEN) {
            ws.ping();
        } else {
            clearInterval(pingInterval);
        }
    }, 30000);
});

server.listen(PORT, () => {
    console.log(`WebSocket echo service ${SERVICE_NAME} listening on port ${PORT}`);
});
EOF

EXPOSE 8080

USER node

CMD ["node", "server.js"]