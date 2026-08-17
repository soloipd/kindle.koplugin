# Kindle SDK compile stubs

These source files contain only the minimum public type and method signatures
needed to compile the reading-progress agent. They are compile-time inputs,
are reviewed with the plugin source, and are never packaged into the agent
JAR. At runtime the Kindle firmware supplies the real implementations.

Keeping these declarations in the repository makes the release build
reproducible and prevents mutable, locally extracted SDK JARs or annotation
processors from influencing shipped bytecode.
