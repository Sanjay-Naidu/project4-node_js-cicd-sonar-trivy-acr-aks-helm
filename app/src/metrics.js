'use strict';

/**
 * Prometheus instrumentation.
 *
 * Exposed on /metrics and scraped in-cluster. The HTTP histogram uses the
 * matched Express *route* rather than the raw URL, otherwise every distinct
 * order id would mint a new time series and blow up cardinality.
 */

const client = require('prom-client');
const config = require('./config');

const register = new client.Registry();

register.setDefaultLabels({
  service: config.serviceName,
  version: config.version,
});

client.collectDefaultMetrics({ register });

const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request latency in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
  registers: [register],
});

const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total number of HTTP requests',
  labelNames: ['method', 'route', 'status_code'],
  registers: [register],
});

const ordersTotal = new client.Gauge({
  name: 'orders_current_total',
  help: 'Number of orders currently held by the service',
  registers: [register],
});

/** Express middleware recording latency and request counts. */
function metricsMiddleware(req, res, next) {
  const stop = httpRequestDuration.startTimer();

  res.on('finish', () => {
    // `req.route` is only populated once routing has resolved; fall back to a
    // constant so unmatched paths cannot be used to inflate cardinality.
    const route = req.route ? `${req.baseUrl}${req.route.path}` : 'unmatched';
    const labels = {
      method: req.method,
      route,
      status_code: String(res.statusCode),
    };
    stop(labels);
    httpRequestsTotal.inc(labels);
  });

  next();
}

module.exports = {
  register,
  metricsMiddleware,
  ordersTotal,
};
