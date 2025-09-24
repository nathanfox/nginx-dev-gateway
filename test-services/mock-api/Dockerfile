FROM node:18-alpine

WORKDIR /app

# Create a mock REST API server
RUN cat > server.js << 'EOF'
const http = require('http');
const url = require('url');

const PORT = process.env.PORT || 8080;
const SERVICE_NAME = process.env.SERVICE_NAME || 'mock-api';

// Mock data store
let users = [
    { id: 1, name: 'Alice', email: 'alice@example.com' },
    { id: 2, name: 'Bob', email: 'bob@example.com' },
    { id: 3, name: 'Charlie', email: 'charlie@example.com' }
];

let nextUserId = 4;

const server = http.createServer((req, res) => {
    const parsedUrl = url.parse(req.url, true);
    const path = parsedUrl.pathname;
    const method = req.method;

    // Set CORS headers
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

    // Handle preflight requests
    if (method === 'OPTIONS') {
        res.writeHead(204);
        res.end();
        return;
    }

    // Collect request body
    let body = '';
    req.on('data', chunk => {
        body += chunk.toString();
    });

    req.on('end', () => {
        // Health check
        if (path === '/health') {
            res.writeHead(200, { 'Content-Type': 'text/plain' });
            res.end('OK\n');
            return;
        }

        // API info
        if (path === '/' || path === '/api') {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({
                service: SERVICE_NAME,
                version: '1.0.0',
                endpoints: [
                    'GET /api/users - List all users',
                    'GET /api/users/:id - Get user by ID',
                    'POST /api/users - Create new user',
                    'PUT /api/users/:id - Update user',
                    'DELETE /api/users/:id - Delete user',
                    'GET /api/status - Service status',
                    'POST /api/echo - Echo request body'
                ]
            }, null, 2));
            return;
        }

        // Service status
        if (path === '/api/status') {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({
                service: SERVICE_NAME,
                status: 'healthy',
                timestamp: new Date().toISOString(),
                uptime: process.uptime(),
                memory: process.memoryUsage(),
                users_count: users.length
            }, null, 2));
            return;
        }

        // Echo endpoint
        if (path === '/api/echo' && method === 'POST') {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({
                service: SERVICE_NAME,
                echo: body ? JSON.parse(body) : null,
                headers: req.headers,
                timestamp: new Date().toISOString()
            }, null, 2));
            return;
        }

        // Users API
        if (path === '/api/users') {
            if (method === 'GET') {
                // List users
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify(users, null, 2));
            } else if (method === 'POST') {
                // Create user
                try {
                    const newUser = JSON.parse(body);
                    newUser.id = nextUserId++;
                    users.push(newUser);
                    res.writeHead(201, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify(newUser, null, 2));
                } catch (e) {
                    res.writeHead(400, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ error: 'Invalid JSON' }, null, 2));
                }
            } else {
                res.writeHead(405, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'Method not allowed' }, null, 2));
            }
            return;
        }

        // User by ID
        const userMatch = path.match(/^\/api\/users\/(\d+)$/);
        if (userMatch) {
            const userId = parseInt(userMatch[1]);
            const userIndex = users.findIndex(u => u.id === userId);

            if (method === 'GET') {
                if (userIndex >= 0) {
                    res.writeHead(200, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify(users[userIndex], null, 2));
                } else {
                    res.writeHead(404, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ error: 'User not found' }, null, 2));
                }
            } else if (method === 'PUT') {
                if (userIndex >= 0) {
                    try {
                        const updatedUser = JSON.parse(body);
                        updatedUser.id = userId;
                        users[userIndex] = updatedUser;
                        res.writeHead(200, { 'Content-Type': 'application/json' });
                        res.end(JSON.stringify(updatedUser, null, 2));
                    } catch (e) {
                        res.writeHead(400, { 'Content-Type': 'application/json' });
                        res.end(JSON.stringify({ error: 'Invalid JSON' }, null, 2));
                    }
                } else {
                    res.writeHead(404, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ error: 'User not found' }, null, 2));
                }
            } else if (method === 'DELETE') {
                if (userIndex >= 0) {
                    users.splice(userIndex, 1);
                    res.writeHead(204);
                    res.end();
                } else {
                    res.writeHead(404, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ error: 'User not found' }, null, 2));
                }
            } else {
                res.writeHead(405, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'Method not allowed' }, null, 2));
            }
            return;
        }

        // 404 for unknown paths
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Not found', path: path }, null, 2));
    });
});

server.listen(PORT, () => {
    console.log(`Mock API service ${SERVICE_NAME} listening on port ${PORT}`);
});
EOF

EXPOSE 8080

USER node

CMD ["node", "server.js"]