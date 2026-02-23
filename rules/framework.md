# Framework Rules

## Entrypoints

- `{CONFIG_FILE}` - ILifeCycle
- `{BOOTSTRAP_FILE}` - Bootstrap entry
- `src/entity/` or `src/provider/factory.ts` - Business entry (entity-centric or provider factory)

## Test Patterns

| Pattern                               | Type        |
| ------------------------------------- | ----------- |
| `createApp()` / `createHttpRequest()` | Integration |
| `createBootstrap()` -> {BOOTSTRAP_FILE}   | E2E         |
| No app startup                        | Unit        |
