# Blog Composer

A native macOS app for composing blog posts and emails with images.

**[Privacy Policy](PRIVACY.md)**

## YouTube Uploads

Blog Composer can upload videos you drop into it to your own **YouTube** channel, then
embed them in your post. This feature uses YouTube API Services; by using it you agree to
the [YouTube Terms of Service](https://www.youtube.com/t/terms), and your use is covered by
the [Google Privacy Policy](https://policies.google.com/privacy). See the
[Blog Composer Privacy Policy](PRIVACY.md) for what the app accesses and stores, and how to
revoke its access.

## Features

- **Drag & Drop Images**: Drop images anywhere in your text to insert them
- **Smart Text Splitting**: When you drop images in text, it automatically splits at the end of the line
- **Auto Image Resizing**: Images are automatically resized to 640px in their largest dimension
- **Keyboard Navigation**: Use arrow keys to navigate between text and images
- **YouTube Video Support**: Add YouTube videos by pasting URLs
- **Clean Interface**: Minimal, focused writing environment

## Building

This is a Swift Package Manager project. To build and run:

```bash
swift build
swift run BlogComposer
```

Or open `Package.swift` in Xcode.

## Requirements

- macOS 13.0 or later
- Xcode 15.0 or later (for development)

## Usage

1. Start typing in the initial text area
2. Drag and drop images from Finder onto the text or between items
3. Use arrow keys to navigate between text areas and images
4. Press Delete when an image is selected to remove it

## Planned Features

- HTML export for blog posts
- Email integration with Mac Mail
- Blogger-specific HTML formatting
- Undo/redo support

## License

All rights reserved.
