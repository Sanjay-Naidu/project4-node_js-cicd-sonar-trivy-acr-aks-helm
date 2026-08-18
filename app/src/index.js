'use strict';

/**
 * Process entrypoint: boot sequence and graceful shutdown.
 *
 * The shutdown path is what makes `maxUnavailable: 0` rolling updates actually
 * zero-downtime. On SIGTERM the sequence is:
 *
 *   1. readiness flips to 503        -> endpoints controller removes this pod
 *   2. drain window (SHUTDOWN_DRAIN_MS) -> in-flight work finishes while
 *                                          kube-proxy/ingress converge; new
 *                                          requests are still served
 *   3. server.close()                -> stop accepting, finish keep-alives
 *   4. hard timeout                  -> force exit so a wedged socket cannot
 *                                       hold the pod past terminationGracePeriod
 */

const config = require('./config');
const logger = require('./logger');
const lifecycle = require('./lifecycle');
const { createApp } = require('./app');

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function warmUp() {
  // Stand-in for real boot work (cache priming, migrations, connection pools).
  // The startup probe covers this window, which is why liveness can stay tight.
  if (config.startupDelayMs > 0) {
    logger.info({ ms: config.startupDelayMs }, 'warm-up starting');
    await sleep(config.startupDelayMs);
  }
}

async function main() {
  const app = createApp();

  await warmUp();

  const server = app.listen(config.port, () => {
    lifecycle.markStarted();
    logger.info(
      { port: config.port, env: config.env, version: config.version, gitSha: config.gitSha },
      'orders-api listening',
    );
  });

  // Must exceed the ingress/LB idle timeout, otherwise the proxy can reuse a
  // connection the server is simultaneously closing -> sporadic 502s.
  server.keepAliveTimeout = 65_000;
  server.headersTimeout = 70_000;

  let shuttingDown = false;

  async function shutdown(signal) {
    if (shuttingDown) {
      logger.warn({ signal }, 'shutdown already in progress');
      return;
    }
    shuttingDown = true;

    logger.info({ signal, drainMs: config.shutdown.drainMs }, 'shutdown initiated, draining');
    lifecycle.beginShutdown();

    const forceExit = setTimeout(() => {
      logger.error('graceful shutdown timed out, forcing exit');
      process.exit(1);
    }, config.shutdown.timeoutMs);
    // Do not let this timer keep the event loop alive on a clean exit.
    forceExit.unref();

    await sleep(config.shutdown.drainMs);

    server.close((err) => {
      if (err) {
        logger.error({ err }, 'error while closing server');
        process.exit(1);
      }
      logger.info('shutdown complete');
      process.exit(0);
    });

    // Idle keep-alive sockets would otherwise hold server.close() open for the
    // full keepAliveTimeout.
    server.closeIdleConnections?.();
  }

  process.on('SIGTERM', () => void shutdown('SIGTERM'));
  process.on('SIGINT', () => void shutdown('SIGINT'));

  // An unhandled rejection or uncaught exception leaves the process in an
  // undefined state. Log it and let Kubernetes restart the pod rather than
  // limping along and serving corrupt responses.
  process.on('unhandledRejection', (reason) => {
    logger.fatal({ err: reason }, 'unhandled promise rejection');
    process.exit(1);
  });

  process.on('uncaughtException', (err) => {
    logger.fatal({ err }, 'uncaught exception');
    process.exit(1);
  });

  return server;
}

main().catch((err) => {
  logger.fatal({ err }, 'failed to start');
  process.exit(1);
});
