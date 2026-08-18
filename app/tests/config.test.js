'use strict';

describe('config validation', () => {
  const original = process.env;

  beforeEach(() => {
    jest.resetModules();
    process.env = { ...original };
  });

  afterAll(() => {
    process.env = original;
  });

  it('applies defaults when optional vars are absent', () => {
    delete process.env.PORT;
    delete process.env.SHUTDOWN_DRAIN_MS;

    const config = require('../src/config');

    expect(config.port).toBe(3000);
    expect(config.shutdown.drainMs).toBe(8000);
  });

  it('coerces numeric strings from the environment', () => {
    process.env.PORT = '8080';

    const config = require('../src/config');

    expect(config.port).toBe(8080);
  });

  it('fails fast on an out-of-range port rather than booting misconfigured', () => {
    process.env.PORT = '99999';

    expect(() => require('../src/config')).toThrow(/Invalid environment configuration/);
  });

  it('fails fast on an unknown log level', () => {
    process.env.LOG_LEVEL = 'chatty';

    expect(() => require('../src/config')).toThrow(/LOG_LEVEL/);
  });

  it('is frozen so nothing can mutate config at runtime', () => {
    const config = require('../src/config');

    expect(Object.isFrozen(config)).toBe(true);
    expect(Object.isFrozen(config.shutdown)).toBe(true);
  });
});
