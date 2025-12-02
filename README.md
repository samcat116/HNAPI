# HNAPI

A Swift package for interacting with Hacker News. Supports fetching stories, comments, searching, and authenticated actions like voting and commenting.

## Requirements

- Swift 6.2+
- macOS 15.0+ / iOS 18.0+

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/yourusername/HNAPI.git", from: "2.0.0")
]
```

## Usage

### Fetching Stories

```swift
let client = APIClient()

// Get top story IDs
let ids = try await client.itemIds(category: .top)

// Fetch story details
let stories = try await client.items(ids: Array(ids.prefix(20)))

for case .story(let story) in stories {
    print("\(story.title) - \(story.points) points")
}
```

### Searching

```swift
let results = try await client.items(query: "Swift concurrency")
```

### Fetching a Page with Comments

```swift
let page = try await client.page(item: story)

for comment in page.children {
    print("\(comment.author): \(comment.text)")
}
```

### Authentication

```swift
let token = try await client.login(userName: "user", password: "pass")

// Fetch page with auth to see available actions
let page = try await client.page(item: story, token: token)
```

### Voting and Actions

```swift
if let actions = page.actions[story.id],
   let upvote = actions.first(where: { if case .upvote = $0 { return true }; return false }) {
    let updatedPage = try await client.execute(action: upvote, token: token, page: page)
}
```

### Commenting

```swift
try await client.reply(to: story, text: "Great article!", token: token)
```

## Categories

- `.top` - Top stories
- `.new` - Newest stories
- `.best` - Best stories
- `.ask` - Ask HN
- `.show` - Show HN
- `.job` - Jobs

## License

MIT
