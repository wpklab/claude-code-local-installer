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

**3.3** Paste the following configuration (replace `/home/YOURUSER` with your actual home directory path):

```json
{
  "LOG": true,
  "LOG_LEVEL": "info",
  "HOST": "127.0.0.1",
  "PORT": 3456,
  "transformers": [
    {
      "path": "/home/YOURUSER/.claude-code-router/plugins/auto-compact.js",
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

**Note:** The `path` in the transformers section should be the absolute path to your home directory. You can use `echo ~` or `echo $HOME` to find your home directory path. The one-line install script handles this automatically.

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
- **Auto-compact plugin:** `~/.claude-code-router/plugins/auto-compact.js` (or `/home/$USER/.claude-code-router/plugins/auto-compact.js`)
- **Debug logs:** `/tmp/auto-compact-debug.log`

**Note:** The plugin path in config.json must be an absolute path (e.g., `/home/username/.claude-code-router/plugins/auto-compact.js`). The one-line install script automatically detects and uses the correct path.

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
 *
 * Features:
 * - Accounts for output tokens when calculating limits
 * - Iteratively reduces messages until under limit
 * - Prevents context overflow errors
 */

class AutoCompactTransformer {
  constructor(options = {}) {
    this.name = 'auto-compact';
    this.endPoint = null; // Works on all endpoints
    this.enable = options.enable !== false;

    // Configuration - defaults for 200K models
    this.maxInputTokens = options.maxInputTokens || 160000;
    this.keepRecentMessages = options.keepRecentMessages || 20;
    this.maxContextTokens = options.maxContextTokens || 202752;
    this.maxOutputTokens = options.maxOutputTokens || 40000;
    this.safetyBuffer = options.safetyBuffer || 5000;

    // Token usage tracking
    this.totalPromptTokens = 0;
    this.totalCompletionTokens = 0;
    this.requestCount = 0;
  }

  /**
   * Estimate tokens using cl100k_base approximation
   * More accurate than raw char/4 for typical English text
   */
  estimateTokens(content) {
    if (!content) return 0;

    // Use rough estimation: ~3.5 chars per token for cl100k_base
    if (typeof content === 'string') {
      return Math.ceil(content.length / 3.5);
    }
    if (Array.isArray(content)) {
      return content.reduce((sum, item) => {
        if (item.type === 'text') {
          return sum + this.estimateTokens(item.text);
        }
        return sum + 100; // Estimate for non-text content
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
   * Log message with timestamp
   */
  log(message, level = 'info') {
    const timestamp = new Date().toISOString();
    const fullMessage = `[auto-compact] ${message}`;

    if (level === 'error') {
      console.error(fullMessage);
    } else if (level === 'warn') {
      console.warn(fullMessage);
    } else {
      console.log(fullMessage);
    }

    // Direct stderr write for reliable logging
    process.stderr.write(`${timestamp} ${level.toUpperCase()} ${fullMessage}\n`);
  }

  /**
   * Transform incoming request - AUTO-COMPACT
   */
  async transformRequestIn(request, provider) {
    const fs = require('fs');
    const logFile = '/tmp/auto-compact-debug.log';
    const timestamp = new Date().toISOString();

    fs.appendFileSync(logFile,
      `${timestamp} transformRequestIn called, enable=${this.enable}, messages=${request.messages ? request.messages.length : 'none'}\n`
    );

    if (!this.enable || !request.messages) {
      return {
        body: request,
        config: { headers: {} }
      };
    }

    const messages = request.messages;
    const totalTokens = this.countTokens(messages);

    // Calculate effective max input tokens based on output tokens and context limit
    const requestedOutput = request.max_tokens || this.maxOutputTokens;
    const effectiveMaxInput = Math.min(
      this.maxInputTokens,
      this.maxContextTokens - requestedOutput - this.safetyBuffer
    );

    // Check if compaction needed
    if (totalTokens <= effectiveMaxInput) {
      this.log(`Context OK: ${totalTokens} tokens (${messages.length} messages), limit=${effectiveMaxInput}`);
      fs.appendFileSync(logFile, `${timestamp} Context OK: ${totalTokens} tokens, limit=${effectiveMaxInput}\n`);
      return {
        body: request,
        config: { headers: {} }
      };
    }

    // Context exceeds threshold - compact it
    this.log(`Context too large: ${totalTokens} tokens (${messages.length} messages), compacting (limit=${effectiveMaxInput})...`, 'warn');
    fs.appendFileSync(logFile, `${timestamp} Context TOO LARGE: ${totalTokens} tokens, limit=${effectiveMaxInput}, compacting...\n`);

    // Keep system messages
    const systemMessages = messages.filter(m => m.role === 'system');
    const otherMessages = messages.filter(m => m.role !== 'system');

    // Progressively reduce messages until under limit
    let currentMessages = [...systemMessages, ...otherMessages];
    let currentTokens = totalTokens;
    let keepCount = Math.min(otherMessages.length, this.keepRecentMessages);
    let iterations = 0;
    const maxIterations = 10;

    while (currentTokens > effectiveMaxInput && iterations < maxIterations) {
      iterations++;

      // Keep system + last N non-system messages
      const recentMessages = otherMessages.slice(-keepCount);
      currentMessages = [...systemMessages, ...recentMessages];
      currentTokens = this.countTokens(currentMessages);

      if (currentTokens <= effectiveMaxInput) {
        break;
      }

      // Reduce by half each iteration, but keep at least 2 messages
      keepCount = Math.max(2, Math.floor(keepCount / 2));
    }

    request.messages = currentMessages;
    const newTokens = this.countTokens(request.messages);
    const reduction = Math.round((1 - newTokens / totalTokens) * 100);

    this.log(`Compacted: ${totalTokens} → ${newTokens} tokens (${reduction}% reduction, ${messages.length} → ${request.messages.length} messages, ${iterations} iterations)`, 'warn');
    fs.appendFileSync(logFile, `${timestamp} Compacted: ${totalTokens} → ${newTokens} tokens (${reduction}% reduction, ${iterations} iterations)\n`);

    // If still over limit, log error but proceed
    if (newTokens > effectiveMaxInput) {
      this.log(`WARNING: Still ${newTokens} tokens after compaction, may exceed limit`, 'error');
      fs.appendFileSync(logFile, `${timestamp} WARNING: Still ${newTokens} tokens after compaction\n`);
    }

    return {
      body: request,
      config: { headers: {} }
    };
  }

  /**
   * Transform outgoing request
   */
  async transformRequestOut(request, provider) {
    return {
      body: request,
      config: { headers: {} }
    };
  }

  /**
   * Transform incoming response
   */
  async transformResponseIn(response, provider) {
    return response;
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

  /**
   * Extract usage from response
   */
  async extractUsage(response) {
    try {
      if (!response.body) return null;

      const contentType = response.headers.get('content-type') || '';

      if (contentType.includes('application/json')) {
        const clone = response.clone();
        const data = await clone.json();
        return data.usage || null;
      }

      if (contentType.includes('text/event-stream') || contentType.includes('text/stream')) {
        return null;
      }
    } catch (error) {
      this.log(`Error extracting usage: ${error.message}`, 'error');
    }
    return null;
  }
}

// Export for CCR
module.exports = AutoCompactTransformer;
```