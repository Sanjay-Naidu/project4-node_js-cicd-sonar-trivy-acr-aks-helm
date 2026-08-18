'use strict';

module.exports = {
  testEnvironment: 'node',
  // Config validation runs at require-time, so the env must be set before any
  // src module is loaded.
  setupFiles: ['<rootDir>/tests/setup-env.js'],
  testMatch: ['<rootDir>/tests/**/*.test.js'],
  collectCoverageFrom: ['src/**/*.js', '!src/index.js'],
  coverageDirectory: 'coverage',
  // `lcov` is what sonar.javascript.lcov.reportPaths consumes; `text-summary`
  // keeps the CI log readable.
  coverageReporters: ['lcov', 'text-summary', 'json-summary'],
  // A ratchet, not a target: the floor the build refuses to drop below, set
  // just under current actual coverage (97/86/98/97). Raise it as coverage
  // improves rather than picking an aspirational number everyone learns to
  // bypass. The gap between floor and actual absorbs normal churn without
  // letting a genuine regression through.
  coverageThreshold: {
    global: {
      statements: 90,
      branches: 80,
      functions: 90,
      lines: 90,
    },
  },
  clearMocks: true,
  restoreMocks: true,
  testTimeout: 10000,
  verbose: false,
};
