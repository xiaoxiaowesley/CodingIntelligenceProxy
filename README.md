# CodingIntelligenceProxy

> English | [中文](README_CN.md)

CodingIntelligenceProxy is a macOS app that acts as a proxy server, enabling Xcode's coding intelligence features (Apple Intelligence / Predictive Code Completion) to work with third-party AI model providers.

## Supported AI Providers

- ZhipuAI
- Kimi (Moonshot)
- Gemini
- Qwen (Tongyi Qianwen)
- Custom — any OpenAI API-compatible service

## Usage

### Step 1: Configure API and Start the Proxy Server

1. Open the CodingIntelligenceProxy app
2. Select an AI Provider
3. Enter your **API Key** and **API URL**
4. Click **Start Server** to launch the proxy server (default port: `1234`)

![Enter API Key, URL and start server](img/1.enter_key_url_and_start.png)

### Step 2: Add a Model Provider in Xcode

1. Open **Xcode → Settings → Intelligence**
2. Click **Add a Model Provider**
3. Select **Locally Hosted**
4. Enter the port number from Step 1 (default: `1234`)
5. Click **Add**

![Add a Provider in Xcode](img/2.add_a_provider.png)

### Step 3: Select a Model

In the Xcode editor, select the AI model you want to use.

![Select a model in Xcode](img/3.select-model-in-xcode.png)

### Step 4: Start Coding

You can now use Xcode's coding intelligence features as usual. The proxy server will forward Xcode's requests to your configured AI provider.

## Requirements

- macOS
- Xcode 14.6+
