FROM swift:6.1-noble AS builder

WORKDIR /app

# Install zlib
RUN apt-get update && apt-get install -y --no-install-recommends \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy manifest for layer caching
COPY Package.swift ./

# Copy source and tests
COPY Sources/ Sources/
COPY Tests/ Tests/

# Patch for Swift 6.1 compatibility:
#  - downgrade swift-tools-version
#  - remove trailing commas in function calls (a 6.2 feature)
#  - set SwiftPDFTests to Swift 5 language mode (its DispatchQueue
#    closure pattern compiles on Apple's 6.2 but not Linux 6.1)
RUN sed -i 's/swift-tools-version: 6.2/swift-tools-version: 6.1/' Package.swift && \
    find Sources Tests -name '*.swift' -exec sed -i 's/withIntermediateDirectories: true,$/withIntermediateDirectories: true/' {} + && \
    sed -i 's|path: "Tests/SwiftPDFTests",|path: "Tests/SwiftPDFTests",\n      swiftSettings: [.swiftLanguageMode(.v5)],|' Package.swift

# Build everything and locate the binary
RUN swift build -c release --product SwiftPDFTests && \
    cp $(swift build -c release --show-bin-path)/SwiftPDFTests /usr/local/bin/swift-pdf-tests

# --- Runtime stage ---
FROM swift:6.1-noble-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    zlib1g \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bin/swift-pdf-tests /usr/local/bin/swift-pdf-tests

CMD ["swift-pdf-tests"]
