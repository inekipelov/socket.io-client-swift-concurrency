import { createServer } from 'node:http';
import { Server } from 'socket.io';

const port = Number(process.env.SOCKET_IO_TEST_PORT ?? 39091);

const httpServer = createServer();
const io = new Server(httpServer, {
  path: '/socket.io/',
  transports: ['websocket']
});

io.on('connection', (socket) => {
  socket.on('ping', (payload, ack) => {
    const value = Number(payload?.value ?? 0);
    const response = { message: 'pong', value };

    if (typeof ack === 'function') {
      ack(response);
    }

    socket.emit('pongEvent', response);
  });

  socket.on('fetch', (payload) => {
    const value = Number(payload?.value ?? 0);
    socket.emit('fetchResponse', { message: 'pong', value });
  });
});

httpServer.listen(port, '127.0.0.1', () => {
  console.log(`READY:${port}`);
});

const shutdown = () => {
  io.close(() => {
    httpServer.close(() => {
      process.exit(0);
    });
  });
};

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
