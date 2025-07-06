# API Key Setup

This app requires an OpenAI API key for audio transcription functionality.

## Setup Instructions

1. **Get an OpenAI API Key**
   - Go to [OpenAI API Keys](https://platform.openai.com/api-keys)
   - Create a new API key
   - Copy the key (it starts with `sk-`)

2. **Configure the API Key**
   - Open `Whisper/Config.plist`
   - Replace `YOUR_API_KEY_HERE` with your actual API key
   - Save the file

3. **Build and Test**
   - Clean build folder in Xcode (Product → Clean Build Folder)
   - Build and run the app
   - Check console output for: `✅ API key loaded successfully`

## Security Features

- **Secure Storage**: API key is stored in `Config.plist` which is excluded from git
- **Fallback Mode**: If API key is missing, app uses local speech recognition
- **No Hardcoding**: API key is never hardcoded in source code
- **Environment Isolation**: Each developer can have their own API key

## Example Config.plist

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>OpenAIAPIKey</key>
    <string>sk-your-actual-api-key-here</string>
</dict>
</plist>
```

## Troubleshooting

### API Key Not Found
If you see: `❌ Config.plist not found in app bundle`
- Make sure `Config.plist` is added to Xcode project
- Clean and rebuild the project

### API Key Not Loading
If you see: `⚠️ API key not properly configured`
- Check that the API key in `Config.plist` is not `YOUR_API_KEY_HERE`
- Verify the API key starts with `sk-`
- Ensure no extra characters or spaces

### Fallback Mode
If API key is not configured, the app will:
- Use local speech recognition (SFSpeechRecognizer)
- Work offline but with lower accuracy
- Show warning messages in console

## Best Practices

- **Never commit API keys** to version control
- **Use different keys** for development and production
- **Rotate keys regularly** for security
- **Monitor usage** in OpenAI dashboard 