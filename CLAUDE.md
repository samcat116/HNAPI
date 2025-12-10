# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
swift build          # Build the package
swift build -c release  # Build for release
```

No test target is configured in this package.

## Architecture Overview

HNAPI is a Swift 6.2 package for interacting with Hacker News. It uses actor-based concurrency throughout.

### Core Components

**APIClient (Actor)** - `Sources/APIClient.swift`
Main public interface. Manages network operations, caching, and authentication. Entry points:
- `itemIds(category:)` - Get story/job IDs for a feed category
- `items(ids:)` / `items(query:)` - Fetch item details or search
- `page(item:token:)` - Load full page with comments and available actions
- `login(userName:password:)` - Authenticate and get token
- `execute(action:token:page:)` - Perform voting/flagging
- `reply(to:text:token:)` - Post comments

**Data Models**
- `TopLevelItem` (enum) - Union of `.story(Story)` or `.job(Job)` for feed items
- `Story` / `Job` / `Comment` / `User` - Core domain types
- `Page` - Combined view with item, comments tree, and available actions
- `Action` (enum) - Upvote/downvote/favorite/flag with associated URLs
- `Content` (enum) - `.text(String)` or `.url(URL)`

**Network Layer**
- `NetworkClient` (protocol) - Abstraction with URLSession conformance, built-in retry logic
- `Endpoint` - Routes to three backends: Algolia (search), Firebase (feeds), Hacker News HTML (actions)

**HTML Parsing** (using SwiftSoup)
- `StoryParser` - Extracts comment colors, voting links, and available actions from HN pages
- `CommentConfirmationParser` - Extracts HMAC token needed for posting comments

**Cache (Actor)** - `Sources/Cache.swift`
Thread-safe LRU cache with TTL (default 5 min). Caches items, pages, and users.

### Key Patterns

- All public types are `Sendable` for actor isolation safety
- Jobs use Firebase `/items/<id>` endpoint (not in Algolia search results)
- `TopLevelItem` and `Job` support dual JSON decoding for different API response formats
- Actions carry their target URL; `inverseSet` models state transitions (upvote ↔ unvote)
- Login requires a custom URLSession that blocks redirects
