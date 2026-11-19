# database/html/ — Web Platform Implementations & Stubs

These files provide the web (`dart.library.js_interop`) implementations and ObjectBox-free stubs matching the API surface of `lib/database/io/`.

All database model exports in `lib/database/models.dart` route to `io/` or `html/` at compile time using `if (dart.library.js_interop)`. Keep public APIs and signatures in 100% parity with `lib/database/io/` whenever entity models or DTOs change.
