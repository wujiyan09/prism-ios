# Prism

Native SwiftUI study app for iPad and iPhone, for HKDSE subjects (ICT, Mathematics, 中文).

- SwiftUI, iOS 17+, Liquid Glass on iOS 26
- Content is downloaded at runtime; no textbook material is stored in this repository
- Project generated with XcodeGen (`project.yml`)

## Building

1. `cp Secrets.example.swift Sources/Secrets.swift` and fill in the values (this file is gitignored).
2. `xcodegen generate`, then open `ICT.xcodeproj`.

CI builds on pushes to `main`. Build artifacts are not published from this repository.
