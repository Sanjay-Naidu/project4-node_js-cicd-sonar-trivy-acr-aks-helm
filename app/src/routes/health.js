'use strict';

/**
 * Kubernetes probe endpoints.
 *
 * Kept free of auth, rate limiting and logging middleware: the kubelet calls
 * these every few seconds and any dependency added here becomes a way to take
 * the whole Deployment down.
 */

const express = require('express');
const lifecycle = require('../lifecycle');
const config = require('../config');

const router = express.Router();

// Probe responses must never be cached by an intermediary.
router.use((req, res, next) => {
  res.setHeader('Cache-Control', 'no-store');
  next();
});

/** startupProbe - gates readiness/liveness until the boot sequence completes. */
router.get('/startup', (req, res) => {
  if (!lifecycle.isStarted()) {
    return res.status(503).json({ status: 'starting' });
  }
  return res.status(200).json({ status: 'started', uptimeSeconds: lifecycle.uptimeSeconds() });
});

/** livenessProbe - only fails if the process is unrecoverable. */
router.get('/live', (req, res) => {
  if (!lifecycle.isLive()) {
    return res.status(503).json({ status: 'dead' });
  }
  return res.status(200).json({ status: 'alive' });
});

/** readinessProbe - flips to 503 the instant SIGTERM lands, draining traffic. */
router.get('/ready', (req, res) => {
  if (!lifecycle.isReady()) {
    return res.status(503).json({
      status: lifecycle.isShuttingDown() ? 'draining' : 'not_ready',
    });
  }
  return res.status(200).json({ status: 'ready' });
});

/** Human/debug endpoint - which build am I actually looking at? */
router.get('/', (req, res) => {
  res.status(200).json({
    service: config.serviceName,
    version: config.version,
    gitSha: config.gitSha,
    env: config.env,
    pod: config.pod,
    uptimeSeconds: lifecycle.uptimeSeconds(),
    status: lifecycle.isReady() ? 'ready' : 'not_ready',
  });
});

module.exports = router;
