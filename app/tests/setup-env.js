'use strict';

// Loaded by Jest before any module under test. config.js validates and freezes
// process.env at require-time, so these must be in place first.
process.env.NODE_ENV = 'test';
process.env.LOG_LEVEL = 'fatal';
process.env.APP_VERSION = '1.0.0-test';
process.env.GIT_SHA = 'testsha';
process.env.STARTUP_DELAY_MS = '0';
process.env.SHUTDOWN_DRAIN_MS = '0';
