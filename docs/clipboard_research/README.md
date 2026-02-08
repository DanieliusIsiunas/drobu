# Clipboard History App - Research Documentation

This directory contains comprehensive research on building a clipboard history application, inspired by Alfred's clipboard history feature.

## 📁 Directory Structure

```
clipboard_research/
├── README.md                                    # This file
├── clipboard_app_implementation_summary.md      # ⭐ Main document for Claude AI CLI
├── clipboard_app_technical_guide.md             # Comprehensive technical guide
├── clipboard_app_quick_reference.md             # Quick reference for developers
└── detailed_research/                           # Individual research documents
    ├── 1_*_maccy_research.md                    # Maccy (macOS) deep dive
    ├── 2_*_copyq_technical_details.md           # CopyQ (cross-platform) analysis
    ├── 3_*_ditto_technical_details.md           # Ditto (Windows) implementation
    ├── 4_*_pastebar_research.md                 # PasteBar (Rust/Tauri) study
    ├── 5_*_nspasteboard_technical_details.md    # macOS NSPasteboard API
    ├── 6_*_technical_details.md                 # Windows Clipboard API
    ├── 7_*_linux_clipboard_research.md          # Linux X11/Wayland clipboard
    ├── 8_*_technical_details.md                 # Data storage strategies
    ├── 9_*_clipboard_manager_research.md        # UI/UX patterns
    ├── 10_*_technical_details.md                # Security and privacy
    └── 11_*_clipboard_monitoring_research.md    # Performance optimization
```

## 📚 Document Guide

### 🎯 Start Here: Implementation Summary
**File:** `clipboard_app_implementation_summary.md`

This is the **primary document** designed to provide maximum context for Claude AI CLI. It includes:
- Executive summary of clipboard history apps
- Detailed analysis of 4 major open-source projects (Maccy, Ditto, CopyQ, PasteBar)
- Platform-specific API documentation (macOS, Windows, Linux)
- Complete code examples and patterns
- Database schema recommendations
- Security and privacy best practices
- UI/UX design patterns
- Performance optimization techniques
- Implementation roadmap
- Technology stack recommendations

**Use this document when:** You want comprehensive context for building the app from scratch.

### 📖 Technical Guide
**File:** `clipboard_app_technical_guide.md`

A well-structured technical guide covering:
- Core concepts and architecture
- Platform-specific implementations
- Data storage and management
- UI/UX best practices
- Security and privacy
- Performance optimization

**Use this document when:** You want a structured overview of the technical aspects.

### ⚡ Quick Reference
**File:** `clipboard_app_quick_reference.md`

A condensed reference guide with:
- Platform API code snippets
- Database schema
- Security checklist
- Performance best practices
- UI/UX essentials
- Common pitfalls
- MVP feature list

**Use this document when:** You need quick access to code examples and best practices during development.

### 🔬 Detailed Research
**Directory:** `detailed_research/`

Contains 11 individual research documents, each focusing on a specific aspect:
1. **Maccy** - macOS clipboard manager implementation
2. **CopyQ** - Cross-platform Qt-based implementation
3. **Ditto** - Windows C++ implementation
4. **PasteBar** - Modern Rust/Tauri implementation
5. **NSPasteboard** - macOS clipboard API
6. **Windows Clipboard API** - Win32 clipboard functions
7. **Linux Clipboard** - X11 and Wayland systems
8. **Data Storage** - Database choices and encryption
9. **UI/UX Patterns** - Interface design best practices
10. **Security & Privacy** - Data protection strategies
11. **Performance** - Monitoring and optimization

**Use these documents when:** You need deep technical details on a specific aspect.

## 🎓 Key Findings

### Open Source Projects Analyzed

| Project | Platform | Language | Stars | Key Strength |
|---------|----------|----------|-------|--------------|
| [Maccy](https://github.com/p0deje/Maccy) | macOS | Swift | 13k+ | Lightweight, privacy-focused |
| [Ditto](https://github.com/sabrogden/Ditto) | Windows | C++ | 5k+ | Network sync, mature |
| [CopyQ](https://github.com/hluk/CopyQ) | Cross-platform | C++/Qt | 8k+ | Scriptable, advanced features |
| [PasteBar](https://github.com/PasteBar/PasteBarApp) | Cross-platform | Rust/Tauri | 1k+ | Modern stack, cloud sync |

### Platform APIs

- **macOS:** NSPasteboard (polling-based, 500ms interval recommended)
- **Windows:** Win32 API (event-driven with `AddClipboardFormatListener`)
- **Linux:** X11 selections or Wayland compositor (complex, fragmented)

### Recommended Tech Stack

**For Cross-Platform App:**
- **Backend:** Rust with Tauri framework
- **Frontend:** React or Svelte
- **Clipboard:** `arboard` or `clipboard_master` crates
- **Database:** SQLite via `rusqlite`
- **Encryption:** AES-256-GCM (optional)

**For macOS-Only App:**
- **Language:** Swift
- **UI:** SwiftUI
- **Storage:** SwiftData (SQLite wrapper)
- **API:** NSPasteboard

### Critical Security Considerations

1. **Always ignore sensitive clipboard types:**
   - macOS: `ConcealedType`, `TransientType`, `AutoGeneratedType`
   - Windows: Check for "Clipboard Viewer Ignore" format

2. **Implement application filtering:**
   - Allow users to ignore password managers
   - Support whitelist/blacklist modes

3. **Data encryption:**
   - Use AES-256 for database encryption
   - Consider SQLCipher for encrypted SQLite

4. **Data retention:**
   - Configurable history limits
   - Automatic cleanup of old items

## 🚀 Getting Started

### Recommended Approach

1. **Read the Implementation Summary** (`clipboard_app_implementation_summary.md`)
2. **Choose your tech stack** based on target platform(s)
3. **Study the relevant open-source project:**
   - macOS → Maccy
   - Windows → Ditto
   - Cross-platform → CopyQ or PasteBar
4. **Use the Quick Reference** during development
5. **Refer to Detailed Research** for specific challenges

### MVP Development Steps

1. Set up project with chosen tech stack
2. Implement basic clipboard monitoring
3. Create SQLite database with schema
4. Store text clipboard items
5. Build simple UI to display history
6. Add search functionality
7. Implement global keyboard shortcut
8. Add sensitive data filtering
9. Implement paste functionality
10. Add settings/preferences

## 📊 Research Methodology

This research was conducted using **parallel processing (Wide Research)** across 12 different topics:

1. Alfred clipboard history feature
2. Maccy open source project
3. CopyQ cross-platform implementation
4. Ditto Windows implementation
5. PasteBar cross-platform app
6. macOS clipboard API (NSPasteboard)
7. Windows clipboard API
8. Linux clipboard systems
9. Data storage strategies
10. UI/UX patterns
11. Security and privacy
12. Performance optimization

Each topic was researched independently and in-depth, with findings synthesized into the comprehensive documents in this directory.

## 🔗 External Resources

### Official Documentation
- [NSPasteboard.org](http://nspasteboard.org/) - Essential macOS clipboard guidelines
- [Windows Clipboard API](https://learn.microsoft.com/en-us/windows/win32/dataxchg/clipboard)
- [Qt QClipboard](https://doc.qt.io/qt-6/qclipboard.html)
- [Arch Linux Clipboard Wiki](https://wiki.archlinux.org/title/Clipboard)

### Open Source Repositories
- [Maccy](https://github.com/p0deje/Maccy)
- [Ditto](https://github.com/sabrogden/Ditto)
- [CopyQ](https://github.com/hluk/CopyQ)
- [PasteBar](https://github.com/PasteBar/PasteBarApp)
- [wl-clipboard](https://github.com/bugaevc/wl-clipboard) (Wayland)

## 💡 Tips for Using This Research with Claude AI CLI

1. **Feed the Implementation Summary first** - It's designed to provide maximum context
2. **Reference specific sections** - Point Claude to relevant sections for focused help
3. **Include code examples** - The documents contain working code snippets
4. **Mention open-source projects** - Claude can help analyze and adapt their patterns
5. **Ask platform-specific questions** - The research covers macOS, Windows, and Linux

## 📝 Notes

- All code examples are taken from real open-source projects or official documentation
- Security best practices are based on industry standards and real-world implementations
- Performance recommendations are derived from mature, production-ready applications
- The research prioritizes privacy-respecting implementations

---

**Research Date:** February 8, 2026  
**Research Method:** Parallel Processing (Wide Research)  
**Total Research Topics:** 12  
**Open Source Projects Analyzed:** 4 major projects + multiple smaller utilities  
**Documentation Pages:** 11 detailed research documents + 3 synthesis documents
