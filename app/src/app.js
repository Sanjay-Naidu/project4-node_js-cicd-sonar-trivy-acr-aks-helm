'use strict';

/**
 * Express application wiring.
 *
 * Exported without calling listen() so tests can drive it via supertest and
 * index.js owns the server lifecycle.
 */

const express = require('express');
const helmet = require('helmet');
const compression = require('compression');
const pinoHttp = require('pino-http');

const config = require('./config');
const logger = require('./logger');
const { register, metricsMiddleware } = require('./metrics');
const { requestContext } = require('./middleware/requestContext');
const { notFoundHandler, errorHandler } = require('./middleware/errors');
const healthRoutes = require('./routes/health');
const orderRoutes = require('./routes/orders');

function createApp() {
  const app = express();

  // Behind the NGINX ingress + Azure LB, so X-Forwarded-* must be honoured for
  // req.ip and req.protocol to mean anything. Bounded to the hop count rather
  // than `true`, which would let a client spoof its own source address.
  app.set('trust proxy', 2);
  app.disable('x-powered-by');

  app.use(helmet());
  app.use(compression());
  app.use(requestContext);

  // Probes and metrics are mounted before request logging so the kubelet's
  // multi-per-second polling does not drown the log stream.
  app.use('/healthz', healthRoutes);

  app.get('/metrics', async (req, res, next) => {
    try {
      res.setHeader('Content-Type', register.contentType);
      res.send(await register.metrics());
    } catch (err) {
      next(err);
    }
  });

  app.use(
    pinoHttp({
      logger,
      genReqId: (req) => req.id,
      customLogLevel: (req, res, err) => {
        if (err || res.statusCode >= 500) {
          return 'error';
        }
        if (res.statusCode >= 400) {
          return 'warn';
        }
        return 'info';
      },
      customSuccessMessage: (req, res) => `${req.method} ${req.url} ${res.statusCode}`,
    }),
  );

  app.use(metricsMiddleware);
  app.use(express.json({ limit: config.bodyLimit }));

  app.get('/', (req, res) => {
    res.status(200).json({
      service: config.serviceName,
      version: config.version,
      gitSha: config.gitSha,
      pod: config.pod.name,
      endpoints: ['/healthz', '/healthz/live', '/healthz/ready', '/metrics', '/api/v1/orders'],
    });
  });

  app.use('/api/v1/orders', orderRoutes);

  app.use(notFoundHandler);
  app.use(errorHandler);

  return app;
}

module.exports = { createApp };
