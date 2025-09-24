FROM node:18-alpine

WORKDIR /app

# Create a slow response service for timeout testing
RUN cat > server.js << 'EOF'
const http = require('http');
const url = require('url');

const PORT = process.env.PORT || 8080;
const SERVICE_NAME = process.env.SERVICE_NAME || 'slow-service';
const DEFAULT_DELAY = parseInt(process.env.DEFAULT_DELAY) || 5000;

const server = http.createServer((req, res) => {
    const parsedUrl = url.parse(req.url, true);
    const path = parsedUrl.pathname;

    // Health check (immediate response)
    if (path === '/health') {
        res.writeHead(200, { 'Content-Type': 'text/plain' });
        res.end('OK\n');
        return;
    }

    // Parse delay from query params or use default
    let delay = parseInt(parsedUrl.query.delay) || DEFAULT_DELAY;

    // Different delay endpoints
    if (path === '/slow') {
        // Configurable slow response
        console.log(`Delaying response for ${delay}ms`);
        setTimeout(() => {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({
                service: SERVICE_NAME,
                delayed: delay,
                timestamp: new Date().toISOString(),
                message: `Response delayed by ${delay}ms`
            }, null, 2));
        }, delay);
    } else if (path === '/timeout') {
        // Extremely slow (will likely timeout)
        const timeoutDelay = 120000; // 2 minutes
        console.log(`Delaying response for ${timeoutDelay}ms (will likely timeout)`);
        setTimeout(() => {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({
                service: SERVICE_NAME,
                delayed: timeoutDelay,
                timestamp: new Date().toISOString(),
                message: 'This response probably never made it'
            }, null, 2));
        }, timeoutDelay);
    } else if (path === '/stream') {
        // Slow streaming response
        res.writeHead(200, {
            'Content-Type': 'text/plain',
            'Transfer-Encoding': 'chunked'
        });

        let count = 0;
        const chunks = parseInt(parsedUrl.query.chunks) || 10;
        const chunkDelay = parseInt(parsedUrl.query.chunkDelay) || 1000;

        const sendChunk = () => {
            if (count < chunks) {
                res.write(`Chunk ${count + 1}/${chunks} from ${SERVICE_NAME}\n`);
                count++;
                setTimeout(sendChunk, chunkDelay);
            } else {
                res.end('Stream complete\n');
            }
        };

        sendChunk();
    } else if (path === '/flaky') {
        // Randomly slow or fast response
        const isSlowh = Math.random() > 0.5;
        const flakeDelay = isSlow ? 5000 + Math.random() * 5000 : 100;

        console.log(`Flaky response: ${isSlow ? 'slow' : 'fast'} (${flakeDelay}ms)`);
        setTimeout(() => {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({
                service: SERVICE_NAME,
                type: 'flaky',
                wasSlow: isSlow,
                delayed: flakeDelay,
                timestamp: new Date().toISOString()
            }, null, 2));
        }, flakeDelay);
    } else if (path === '/') {
        // Service info
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
            service: SERVICE_NAME,
            purpose: 'Timeout and slow response testing',
            endpoints: [
                'GET /health - Immediate health check',
                'GET /slow?delay=5000 - Configurable slow response',
                'GET /timeout - 2-minute delay (will timeout)',
                'GET /stream?chunks=10&chunkDelay=1000 - Slow streaming',
                'GET /flaky - Randomly slow or fast'
            ],
            defaultDelay: DEFAULT_DELAY
        }, null, 2));
    } else {
        // Default slow response for any other path
        console.log(`Default slow response for ${path} (${DEFAULT_DELAY}ms)`);
        setTimeout(() => {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({
                service: SERVICE_NAME,
                path: path,
                delayed: DEFAULT_DELAY,
                timestamp: new Date().toISOString()
            }, null, 2));
        }, DEFAULT_DELAY);
    }
});

server.listen(PORT, () => {
    console.log(`Slow service ${SERVICE_NAME} listening on port ${PORT}`);
    console.log(`Default delay: ${DEFAULT_DELAY}ms`);
});
EOF

# Fix typo in the script
RUN sed -i 's/isSlowh/isSlow/g' server.js

EXPOSE 8080

USER node

CMD ["node", "server.js"]