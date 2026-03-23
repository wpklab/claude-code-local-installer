# Claude Code Local vLLM Installation Guide

> **Quick Setup for WSL or Linux** - Connect Claude Code to your local vLLM server

## Prerequisites

- WSL or Linux system
- Internet connection
- The vLLM server running at `http://172.22.203.134:8000`

---

## Installation Steps

### Step 1: Install Node.js via NVM

**1.1** Install NVM (Node Version Manager):

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
```

**1.2** Restart your terminal or WSL, then install Node.js:

```bash
nvm install --lts
```

**Verify installation:**
```bash
node --version
npm --version
```

---

### Step 2: Install Claude Code and Router

```bash
npm install -g @anthropic-ai/claude-code @musistudio/claude-code-router
```

---

### Step 3: Configure Router

**3.1** Create required directories:

```bash
mkdir -p ~/.claude-code-router/plugins ~/.claude
```

**3.2** Create config file:

```bash
nano ~/.claude-code-router/config.json
```

**3.3** Paste the following configuration:

```json
{
  "LOG": true,
  "LOG_LEVEL": "info",
  "HOST": "127.0.0.1",
  "PORT": 3456,
  "transformers": [
    {
      "path": "~/.claude-code-router/plugins/auto-compact.js",
      "options": {
        "maxInputTokens": 140000,
        "keepRecentMessages": 20
      }
    }
  ],
  "Providers": [
    {
      "name": "king_local",
      "api_base_url": "http://172.22.203.134:8000/v1/chat/completions",
      "api_key": "not-needed",
      "models": ["king_local", "claude-sonnet-4-6"],
      "max_context_tokens": 140000,
      "max_output_tokens": 40000,
      "transformer": {
        "use": [
          "OpenAI",
          "auto-compact",
          "streamoptions"
        ],
        "tool_format": "none",
        "strip_tool_choice": true,
        "strip_reasoning_from_request": true
      }
    }
  ],
  "Router": {
    "default": "king_local",
    "strip_beta_headers": true,
    "mock_token_counting": false
  }
}
```

**Save and exit:** Press `Ctrl+X`, then `Y`, then `Enter`

---

### Step 4: Install Auto-Compact Plugin

**4.1** Create the plugin file:

```bash
nano ~/.claude-code-router/plugins/auto-compact.js
```

**4.2** Paste the plugin code (see [auto-compact.js](#auto-compactjs) below)

**Save and exit:** Press `Ctrl+X`, then `Y`, then `Enter`

---

### Step 5: Start the Router

```bash
ccr restart
```

**Verify it's running:**
```bash
ccr status
```

---

## Usage

You should not need to log in if everything is configured correctly.

### Basic Usage

**Vanilla launch:**
```bash
ccr code
```

**Skip permission prompts:**
```bash
ccr code --dangerously-skip-permissions
```

**Agent mode with skip permissions:**
```bash
CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 ccr code --dangerously-skip-permissions
```

---

## Configuration Files

- **Router config:** `~/.claude-code-router/config.json`
- **Auto-compact plugin:** `~/.claude-code-router/plugins/auto-compact.js`
- **Debug logs:** `/tmp/auto-compact-debug.log`

---

## Troubleshooting

### "nvm: command not found"

Restart your terminal or run:
```bash
source ~/.bashrc
```

### "ccr: command not found"

NPM global packages may not be in your PATH. Add to `~/.bashrc`:
```bash
echo 'export PATH="$(npm config get prefix)/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### Router won't start

Check if port 3456 is in use:
```bash
lsof -i :3456
```

### Can't connect to vLLM server

1. Verify vLLM is running: `curl http://172.22.203.134:8000/v1/models`
2. Check the `api_base_url` in your config.json

### Claude Code asks for login

Your router may not be running. Verify:
```bash
ccr status
curl http://127.0.0.1:3456/health
```

---

## One-Line Install Script

For automated installation, use our script:

```bash
curl -sL https://raw.githubusercontent.com/wpklab/claude-code-local-installer/main/install-claude-code-local.sh | bash
```

---

## auto-compact.js

<details>
<summary>Click to expand full plugin code</summary>

```javascript
/**
 * Auto-Compact Transformer for Claude Code Router
 * Automatically manages context to prevent overflow
 */

class AutoCompactTransformer {
  constructor(options = {}) {
    this.name = 'auto-compact';
    this.endPoint = null; // No endpoint, works on all
    this.enable = options.enable !== false;

    // Configuration
    this.maxInputTokens = options.maxInputTokens || 90000;
    this.keepRecentMessages = options.keepRecentMessages || 20;

    // Token usage tracking
    this.totalPromptTokens = 0;
    this.totalCompletionTokens = 0;
    this.requestCount = 0;
  }

  /**
   * Estimate tokens using cl100k_base approximation (OpenAI's encoding)
   * More accurate than raw char/4 for typical English text
   */
  estimateTokens(content) {
    if (!content) return 0;

    // Use rough estimation: ~3.5 chars per token for cl100k_base
    // This is more accurate for typical LLM prompts
    if (typeof content === 'string') {
      return Math.ceil(content.length / 3.5);
    }
    if (Array.isArray(content)) {
      return content.reduce((sum, item) => {
        if (item.type === 'text') {
          return sum + this.estimateTokens(item.text);
        }
        return sum + 100; // Estimate for non-text
      }, 0);
    }
    return 0;
  }

  /**
   * Count total tokens in messages
   */
  countTokens(messages) {
    if (!messages || !Array.isArray(messages)) return 0;
    return messages.reduce((sum, msg) => {
      return sum + this.estimateTokens(msg.content);
    }, 0);
  }

  /**
   * Log message using multiple methods for visibility
   */
  log(message, level = 'info') {
    const timestamp = new Date().toISOString();
    const fullMessage = `[auto-compact] ${message}`;

    // Console methods (may or may not be captured by CCR)
    if (level === 'error') {
      console.error(fullMessage);
    } else if (level === 'warn') {
      console.warn(fullMessage);
    } else {
      console.log(fullMessage);
    }

    // Direct stderr write (more reliable for logging)
    process.stderr.write(`${timestamp} ${level.toUpperCase()} ${fullMessage}\n`);
  }

  /**
   * Transform incoming request - AUTO-COMPACT
   */
  async transformRequestIn(request, provider) {
    // Write to file to verify transformer is being called
    const fs = require('fs');
    const logFile = '/tmp/auto-compact-debug.log';
    const timestamp = new Date().toISOString();
    fs.appendFileSync(logFile, `${timestamp} transformRequestIn called, enable=${this.enable}, messages=${request.messages ? request.messages.length : 'none'}\n`);

    if (!this.enable || !request.messages) {
      return {
        body: request,
        config: { headers: {} }
      };
    }

    const messages = request.messages;
    const totalTokens = this.countTokens(messages);

    // Check if compaction needed
    if (totalTokens <= this.maxInputTokens) {
      this.log(`Context OK: ${totalTokens} tokens (${messages.length} messages)`);
      fs.appendFileSync(logFile, `${timestamp} Context OK: ${totalTokens} tokens\n`);
      return {
        body: request,
        config: { headers: {} }
      };
    }

    this.log(`Context too large: ${totalTokens} tokens (${messages.length} messages), compacting...`, 'warn');
    fs.appendFileSync(logFile, `${timestamp} Context TOO LARGE: ${totalTokens} tokens, compacting...\n`);

    // Keep system messages + recent messages
    const systemMessages = messages.filter(m => m.role === 'system');
    const otherMessages = messages.filter(m => m.role !== 'system');

    // Keep last N messages
    const recentMessages = otherMessages.slice(-this.keepRecentMessages);

    // Combine
    request.messages = [...systemMessages, ...recentMessages];

    const newTokens = this.countTokens(request.messages);
    const reduction = Math.round((1 - newTokens / totalTokens) * 100);
    this.log(`Compacted: ${totalTokens} → ${newTokens} tokens (${reduction}% reduction, ${messages.length} → ${request.messages.length} messages)`, 'warn');
    fs.appendFileSync(logFile, `${timestamp} Compacted: ${totalTokens} → ${newTokens} tokens (${reduction}% reduction)\n`);

    return {
      body: request,
      config: { headers: {} }
    };
  }

  /**
   * Extract usage from response (streaming or non-streaming)
   */
  async extractUsage(response) {
    try {
      // For non-streaming responses
      if (!response.body) return null;

      const contentType = response.headers.get('content-type') || '';

      // Non-streaming JSON response
      if (contentType.includes('application/json')) {
        const clone = response.clone();
        const data = await clone.json();
        return data.usage || null;
      }

      // Streaming response - need to parse SSE for usage
      if (contentType.includes('text/event-stream') || contentType.includes('text/stream')) {
        // For streaming, usage comes at the end in a data: [DONE] or usage event
        // We'll need to track this differently - log it when we see it
        return null;
      }
    } catch (error) {
      this.log(`Error extracting usage: ${error.message}`, 'error');
    }
    return null;
  }

  /**
   * Transform outgoing response - track usage
   */
  async transformResponseOut(response, context) {
    try {
      const usage = await this.extractUsage(response);

      if (usage) {
        this.requestCount++;
        this.totalPromptTokens += usage.prompt_tokens || 0;
        this.totalCompletionTokens += usage.completion_tokens || 0;
        const totalTokens = this.totalPromptTokens + this.totalCompletionTokens;

        this.log(`Usage: ${usage.prompt_tokens} prompt + ${usage.completion_tokens} completion = ${usage.prompt_tokens + usage.completion_tokens} tokens (cumulative: ${totalTokens} total, ${this.requestCount} requests)`);
      }
    } catch (error) {
      this.log(`Error tracking usage: ${error.message}`, 'error');
    }

    return response;
  }
}

module.exports = AutoCompactTransformer;
```