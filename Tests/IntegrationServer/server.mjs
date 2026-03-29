import { createServer } from 'node:http';
import { Server } from 'socket.io';

const port = Number(process.env.SOCKET_IO_TEST_PORT ?? 39091);

const httpServer = createServer();
const io = new Server(httpServer, {
  path: '/socket.io/',
  transports: ['websocket']
});

io.on('connection', (socket) => {
  socket.on('echo', (...args) => {
    socket.emit('echoResponse', ...args);
  });

  socket.on('ackPing', (...args) => {
    const ack = args.at(-1);
    if (typeof ack === 'function') {
      ack('pong', 7);
    }
  });

  socket.on('noAck', (...args) => {
    void args;
  });

  socket.on('delayedAck', (...args) => {
    const ack = args.at(-1);
    if (typeof ack === 'function') {
      setTimeout(() => ack('late'), 1500);
    }
  });

  socket.on('ping', (...args) => {
    const ack = args.at(-1);
    if (typeof ack === 'function') {
      ack('pong', 42);
    }
    socket.emit('pongEvent', ...args.slice(0, -1));
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
