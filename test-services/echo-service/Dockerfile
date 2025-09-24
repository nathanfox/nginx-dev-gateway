FROM node:18-alpine

WORKDIR /app

# Create a simple echo server
RUN cat > server.js << 'EOF'
const http = require('http');
const url = require('url');

const PORT = process.env.PORT || 8080;
const SERVICE_NAME = process.env.SERVICE_NAME || 'echo-service';

const server = http.createServer((req, res) => {
    const parsedUrl = url.parse(req.url, true);

    // Collect request data
    let body = '';
    req.on('data', chunk => {
        body += chunk.toString();
    });

    req.on('end', () => {
        const response = {
            service: SERVICE_NAME,
            timestamp: new Date().toISOString(),
            request: {
                method: req.method,
                url: req.url,
                path: parsedUrl.pathname,
                query: parsedUrl.query,
                headers: req.headers,
                body: body || null
            },
            echo: {
                message: `Echo from ${SERVICE_NAME}`,
                received: body || 'No body received'
            }
        };

        // Special endpoints
        if (parsedUrl.pathname === '/health') {
            res.writeHead(200, { 'Content-Type': 'text/plain' });
            res.end('OK\n');
        } else if (parsedUrl.pathname === '/delay') {
            const delay = parseInt(parsedUrl.query.ms) || 1000;
            setTimeout(() => {
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ delayed: delay, ...response }));
            }, delay);
        } else {
            // Normal echo response
            res.writeHead(200, {
                'Content-Type': 'application/json',
                'X-Echo-Service': SERVICE_NAME
            });
            res.end(JSON.stringify(response, null, 2));
        }
    });
});

server.listen(PORT, () => {
    console.log(`Echo service ${SERVICE_NAME} listening on port ${PORT}`);
});
EOF

EXPOSE 8080

USER node

CMD ["node", "server.js"]