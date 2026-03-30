# Connect Payload Type-Safety Design

Date: 2026-03-30  
Project: `socket.io-client-swift-concurrency`

## Summary

Replace `Any` in the public `connect(withPayload:)` API with `SocketData` while preserving existing async connect behavior and error contract.

Selected approach (approved): use `[String: SocketData]?` as the connect payload type.

## Problem

Current signature:

```swift
func connect(
    withPayload payload: [String: Any]? = nil,
    timeout: TimeInterval = 5
) async throws(SocketIOClient.Error)
```

`[String: Any]` weakens compile-time guarantees and conflicts with the package direction toward type-driven APIs.

## Goals

- Remove `Any` from the public `connect` payload signature.
- Keep support for both flat and nested payload structures.
- Preserve current connect/disconnect/error/cancellation semantics.
- Keep a single typed error contract: `SocketIOClient.Error`.

## Non-Goals

- No additional payload shape validation (flat vs nested).
- No behavior change in connection state lifecycle.
- No new domain model for connect payload beyond `SocketData`.

## Public API Changes

Replace the existing overload with:

```swift
func connect(
    withPayload payload: [String: SocketData]? = nil,
    timeout: TimeInterval = 5
) async throws(SocketIOClient.Error)
```

This is an intentional breaking change for callers currently using `[String: Any]`.

## Internal Design

### Data Flow

1. Accept `payload: [String: SocketData]?`.
2. Normalize payload to upstream-compatible `[String: Any]?` by calling `socketRepresentation()` for each value.
3. Recursively normalize container values (`[Any]`, `[String: Any]`, `NSArray`, `NSDictionary`) without shape constraints.
4. Call upstream `connect(withPayload:timeoutAfter:withHandler:)` with normalized payload.

### Error Mapping

- Conversion failures (including thrown `socketRepresentation()` and unsupported runtime payload values) map to:

```swift
SocketIOClient.Error.invalidSocketData(event: "connect", message: ...)
```

- Existing connect error paths remain unchanged:
  - `.connectTimedOut(timeout:)`
  - `.disconnected(event:reason:)`
  - normalized `.error` event mapping
  - `.cancelled`

## Testing Strategy

### New/Updated Unit Tests

- `connect` accepts `[String: SocketData]` payload with mixed and nested values.
- `connect` maps payload conversion failures to `.invalidSocketData(event: "connect", ...)`.

### Regression Coverage

Keep existing tests green for:

- connect success
- connect timeout
- connect cancellation
- temporary handler cleanup
- existing async event and ack behavior

## Documentation Updates

- Update README API table:
  - `connect(withPayload payload: [String: Any]? ...)`
  - to `connect(withPayload payload: [String: SocketData]? ...)`
- Clarify that nested payload structures are supported and not shape-validated.

## Risks and Mitigations

- Risk: caller migration friction from `[String: Any]`.
  - Mitigation: migration is straightforward for typical payloads; values usually already conform to `SocketData`.
- Risk: hidden runtime payload conversion edge cases.
  - Mitigation: strict conversion error mapping + explicit test for conversion failure.

## Acceptance Criteria

- Public `connect` signature contains no `Any`.
- No behavior regressions in connect lifecycle semantics.
- All tests pass.
- README reflects the new signature and behavior.
