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

3. **Important Security Notes**
   - The `Config.plist` file is already added to `.gitignore` to prevent it from being committed to version control
   - Never commit your actual API key to the repository
   - If you accidentally commit a secret, follow the instructions in the main README to remove it from git history

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

If you see a warning message about the API key not being found, make sure:
1. The `Config.plist` file exists in the `Whisper` folder
2. The API key is properly set in the file
3. The file is included in your Xcode project bundle 