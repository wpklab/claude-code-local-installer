#!/bin/bash

# Claude Code Local vLLM Installation Script
# For WSL or Linux systems
# Run with: bash install-claude-code-local.sh

set -e  # Exit on error

echo "=========================================="
echo "Claude Code Local vLLM Installer"
echo "=========================================="
echo ""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Step 1: Install nvm
echo "Step 1: Installing NVM (Node Version Manager)..."
if command -v nvm &> /dev/null; then
    print_status "NVM already installed"
else
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
    print_status "NVM installed"
fi

# Source nvm (it might not be available in current shell)
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

echo ""
print_warning "IMPORTANT: After this script completes, restart your terminal/WSL for NVM to be available"
echo ""

# Step 2: Install Node.js LTS
echo "Step 2: Installing Node.js LTS..."
if command -v node &> /dev/null; then
    NODE_VERSION=$(node --version)
    print_status "Node.js already installed: $NODE_VERSION"
else
    nvm install --lts
    print_status "Node.js LTS installed: $(node --version)"
fi

# Step 3: Install Claude Code and Router
echo ""
echo "Step 3: Installing Claude Code and Router..."
npm install -g @anthropic-ai/claude-code @musistudio/claude-code-router
print_status "Claude Code and Router installed"

# Step 4: Create directories
echo ""
echo "Step 4: Creating configuration directories..."
mkdir -p ~/.claude-code-router/plugins ~/.claude
print_status "Directories created"

# Step 5: Create config.json
echo ""
echo "Step 5: Creating router configuration..."
cat > ~/.claude-code-router/config.json << 'EOF'
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
EOF
print_status "Config created at ~/.claude-code-router/config.json"

# Step 6: Create auto-compact plugin
echo ""
echo "Step 6: Creating auto-compact plugin..."
cat > ~/.claude-code-router/plugins/auto-compact.js << 'EOF'
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
EOF
print_status "Auto-compact plugin created at ~/.claude-code-router/plugins/auto-compact.js"

# Step 7: Restart the router
echo ""
echo "Step 7: Starting Claude Code Router..."
ccr restart
print_status "Router started"

# Final instructions
echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo ""
echo "IMPORTANT: If this is your first time installing NVM,"
echo "restart your terminal/WSL now for the changes to take effect."
echo ""
echo "Usage:"
echo ""
echo "  Vanilla launch:"
echo "    ccr code"
echo ""
echo "  Skip permissions:"
echo "    ccr code --dangerously-skip-permissions"
echo ""
echo "  Agent mode with skip permissions:"
echo "    CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 ccr code --dangerously-skip-permissions"
echo ""
echo "Configuration files:"
echo "  Router config:  ~/.claude-code-router/config.json"
echo "  Auto-compact:   ~/.claude-code-router/plugins/auto-compact.js"
echo ""
echo "Note: Update the 'api_base_url' in ~/.claude-code-router/config.json"
echo "if your vLLM server is running on a different address."
echo ""
