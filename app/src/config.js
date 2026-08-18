'use strict';

/**
 * Centralised, validated configuration.
 *
 * Everything is sourced from the environment so the same image can be promoted
 * unchanged across environments (12-factor). Invalid config fails fast at boot
 * rather than surfacing as a confusing runtime error later.
 */

const { z } = require('zod');

const schema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().int().min(1).max(65535).default(3000),
  LOG_LEVEL: z.enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace']).default('info'),
  SERVICE_NAME: z.string().min(1).default('orders-api'),

  // Injected by the Helm chart from the image tag / build metadata.
  APP_VERSION: z.string().min(1).default('0.0.0-dev'),
  GIT_SHA: z.string().min(1).default('unknown'),

  // Injected by the Kubernetes downward API.
  POD_NAME: z.string().default('local'),
  POD_NAMESPACE: z.string().default('local'),
  NODE_NAME: z.string().default('local'),

  /**
   * How long readiness reports "false" after SIGTERM before the HTTP server
   * stops accepting connections. This bridges the window where kube-proxy /
   * the ingress controller still hold stale endpoints, and is what makes a
   * rolling update genuinely zero-downtime.
   */
  SHUTDOWN_DRAIN_MS: z.coerce.number().int().min(0).default(8000),

  /** Hard ceiling on graceful shutdown before the process is forced down. */
  SHUTDOWN_TIMEOUT_MS: z.coerce.number().int().min(1000).default(20000),

  /** Simulated warm-up work, proving the startup probe does something real. */
  STARTUP_DELAY_MS: z.coerce.number().int().min(0).default(0),

  BODY_LIMIT: z.string().default('100kb'),
});

const parsed = schema.safeParse(process.env);

if (!parsed.success) {
  // Deliberately not using the logger: config is a dependency of the logger.
  const detail = parsed.error.issues
    .map((issue) => `  - ${issue.path.join('.')}: ${issue.message}`)
    .join('\n');
  throw new Error(`Invalid environment configuration:\n${detail}`);
}

const env = parsed.data;

module.exports = Object.freeze({
  env: env.NODE_ENV,
  isProduction: env.NODE_ENV === 'production',
  isTest: env.NODE_ENV === 'test',
  port: env.PORT,
  logLevel: env.LOG_LEVEL,
  serviceName: env.SERVICE_NAME,
  version: env.APP_VERSION,
  gitSha: env.GIT_SHA,
  bodyLimit: env.BODY_LIMIT,
  pod: Object.freeze({
    name: env.POD_NAME,
    namespace: env.POD_NAMESPACE,
    node: env.NODE_NAME,
  }),
  shutdown: Object.freeze({
    drainMs: env.SHUTDOWN_DRAIN_MS,
    timeoutMs: env.SHUTDOWN_TIMEOUT_MS,
  }),
  startupDelayMs: env.STARTUP_DELAY_MS,
});
