'use strict';

/**
 * Structured JSON logging.
 *
 * Container stdout is the log transport: no files, no rotation, no sidecar
 * shipping config in the app itself. Azure Monitor / Container Insights picks
 * these up from the node's container runtime.
 */

const pino = require('pino');
const config = require('./config');

const logger = pino({
  level: config.logLevel,
  // `pino` defaults to `time` in epoch ms; ISO is far easier to correlate with
  // kubectl logs --timestamps and Log Analytics.
  timestamp: pino.stdTimeFunctions.isoTime,
  base: {
    service: config.serviceName,
    version: config.version,
    gitSha: config.gitSha,
    pod: config.pod.name,
    namespace: config.pod.namespace,
    node: config.pod.node,
  },
  formatters: {
    // Emit `"level":"info"` rather than `"level":30` so log queries read well.
    level: (label) => ({ level: label }),
  },
  redact: {
    paths: [
      'req.headers.authorization',
      'req.headers.cookie',
      'req.headers["x-api-key"]',
      'res.headers["set-cookie"]',
    ],
    censor: '[redacted]',
  },
  // Tests assert on behaviour, not on log noise.
  enabled: !config.isTest,
});

module.exports = logger;
