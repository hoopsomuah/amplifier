FROM ubuntu:22.04

# Avoid prompts from apt
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    git \
    build-essential \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js (required for Claude Code)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs

# Install Python 3.11
RUN apt-get update && apt-get install -y python3.11 python3.11-venv python3.11-dev && rm -rf /var/lib/apt/lists/*

# Install uv (Python package manager)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:/root/.cargo/bin:$PATH"
ENV PNPM_HOME="/root/.local/share/pnpm"
ENV PATH="$PNPM_HOME:$PATH"

# Install Claude Code, pyright, and pnpm
ENV SHELL=/bin/bash
RUN npm install -g @anthropic-ai/claude-code pyright pnpm && \
    SHELL=/bin/bash pnpm setup && \
    echo 'export PNPM_HOME="/root/.local/share/pnpm"' >> ~/.bashrc && \
    echo 'export PATH="$PNPM_HOME:$PATH"' >> ~/.bashrc

# Pre-configure Claude Code to use environment variables
RUN mkdir -p /root/.config/claude-code

# Create working directory
WORKDIR /app

# Clone Amplifier repository
RUN git clone https://github.com/microsoft/amplifier.git /app/amplifier

# Set working directory to amplifier
WORKDIR /app/amplifier

# Initialize Python environment with uv and install dependencies
RUN uv venv --python python3.11 .venv && \
    uv sync && \
    . .venv/bin/activate && make install

# Create data directory for Amplifier and required subdirectories
RUN mkdir -p /app/amplifier-data && \
    mkdir -p /app/amplifier/.data

# Clone Amplifier to /root/amplifier where Claude Code will start
RUN git clone https://github.com/microsoft/amplifier.git /root/amplifier

# Build Amplifier in /root/amplifier
WORKDIR /root/amplifier
RUN uv venv --python python3.11 .venv && \
    uv sync && \
    . .venv/bin/activate && make install

# Create required .data directory structure
RUN mkdir -p /root/amplifier/.data/knowledge && \
    mkdir -p /root/amplifier/.data/indexes && \
    mkdir -p /root/amplifier/.data/state && \
    mkdir -p /root/amplifier/.data/memories && \
    mkdir -p /root/amplifier/.data/cache

# Create entrypoint script with comprehensive Claude Code configuration
RUN cat > /app/entrypoint.sh << 'EOF'
#!/bin/bash
set -e

# Logging function with timestamps
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Error handling function
error_exit() {
    log "ERROR: $1"
    exit 1
}

# Validate API key format
validate_api_key() {
    local api_key="$1"
    if [[ ! "$api_key" =~ ^sk-ant-[a-zA-Z0-9_-]+$ ]]; then
        log "WARNING: API key format may be invalid (should start with 'sk-ant-')"
        return 1
    fi
    return 0
}

# Create comprehensive Claude configuration file
create_claude_config() {
    local api_key="$1"
    local config_file="$HOME/.claude.json"

    log "Creating Claude configuration at: $config_file"

    # Extract last 20 characters for approved list
    local key_suffix="${api_key: -20}"

    # Create configuration directory
    mkdir -p "$(dirname "$config_file")"

    cat > "$config_file" << CONFIG_EOF
{
  "apiKey": "$api_key",
  "hasCompletedOnboarding": true,
  "projects": {},
  "customApiKeyResponses": {
    "approved": ["$key_suffix"],
    "rejected": []
  },
  "mcpServers": {}
}
CONFIG_EOF

    # Verify JSON validity using python (more reliable than jq)
    if ! python3 -m json.tool "$config_file" > /dev/null 2>&1; then
        error_exit "Generated configuration file contains invalid JSON"
    fi

    log "Configuration file created successfully"
}

# Set CLI configuration flags
configure_claude_cli() {
    log "Setting Claude CLI configuration flags..."

    # Set configuration flags to skip interactive prompts
    claude config set hasCompletedOnboarding true 2>/dev/null || log "WARNING: Failed to set hasCompletedOnboarding"
    claude config set hasTrustDialogAccepted true 2>/dev/null || log "WARNING: Failed to set hasTrustDialogAccepted"

    log "CLI configuration completed"
}

# Verify configuration
verify_configuration() {
    local config_file="$HOME/.claude.json"

    log "Verifying Claude configuration..."

    # Check file existence
    if [[ ! -f "$config_file" ]]; then
        error_exit "Configuration file not found: $config_file"
    fi

    # Validate JSON structure using python
    if ! python3 -m json.tool "$config_file" > /dev/null 2>&1; then
        error_exit "Configuration file contains invalid JSON"
    fi

    # Check required fields using python
    local api_key=$(python3 -c "import json; print(json.load(open('$config_file')).get('apiKey', ''))" 2>/dev/null || echo "")
    local onboarding=$(python3 -c "import json; print(json.load(open('$config_file')).get('hasCompletedOnboarding', False))" 2>/dev/null || echo "false")

    if [[ -z "$api_key" ]]; then
        error_exit "API key not found in configuration"
    fi

    if [[ "$onboarding" != "True" ]]; then
        error_exit "Onboarding not marked as complete"
    fi

    log "Configuration verification successful"
}

# Test Claude functionality
test_claude_functionality() {
    log "Testing Claude Code functionality..."

    # Test basic command
    if claude --version >/dev/null 2>&1; then
        local version=$(claude --version 2>/dev/null || echo "Unknown")
        log "Claude Code version check successful: $version"
    else
        log "WARNING: Claude Code version check failed"
    fi

    # Test configuration access
    if claude config show >/dev/null 2>&1; then
        log "Claude Code configuration accessible"
    else
        log "WARNING: Claude Code configuration not accessible"
    fi
}

# Main setup function
main() {
    # Default to /workspace if no target directory specified
    TARGET_DIR=${TARGET_DIR:-/workspace}
    AMPLIFIER_DATA_DIR=${AMPLIFIER_DATA_DIR:-/app/amplifier-data}

    log "🚀 Starting Amplifier Docker Container with Enhanced Claude Configuration"
    log "📁 Target project: $TARGET_DIR"
    log "📊 Amplifier data: $AMPLIFIER_DATA_DIR"

    # Comprehensive environment variable debugging
    log "🔍 Environment Variable Debug Information:"
    log "   HOME: $HOME"
    log "   USER: $(whoami)"
    log "   PWD: $PWD"

    # Debug API key availability (masked for security)
    if [ ! -z "$ANTHROPIC_API_KEY" ]; then
        local masked_key="sk-ant-****${ANTHROPIC_API_KEY: -4}"
        log "   ANTHROPIC_API_KEY: $masked_key (length: ${#ANTHROPIC_API_KEY})"
        validate_api_key "$ANTHROPIC_API_KEY" || log "   API key format validation failed"
    else
        log "   ANTHROPIC_API_KEY: (not set)"
    fi

    if [ ! -z "$AWS_ACCESS_KEY_ID" ]; then
        local masked_aws="****${AWS_ACCESS_KEY_ID: -4}"
        log "   AWS_ACCESS_KEY_ID: $masked_aws"
    else
        log "   AWS_ACCESS_KEY_ID: (not set)"
    fi

    # Validate target directory exists
    if [ -d "$TARGET_DIR" ]; then
        log "✅ Target directory found: $TARGET_DIR"
    else
        log "❌ Target directory not found: $TARGET_DIR"
        log "💡 Make sure you mounted your project directory to $TARGET_DIR"
        exit 1
    fi

    # Change to Amplifier directory and activate environment
    log "🔧 Setting up Amplifier environment..."
    cd /root/amplifier
    source .venv/bin/activate

    # Configure Amplifier data directory
    log "📂 Configuring Amplifier data directory..."
    export AMPLIFIER_DATA_DIR="$AMPLIFIER_DATA_DIR"

    # Check if API key is available
    if [ -z "$ANTHROPIC_API_KEY" ] && [ -z "$AWS_ACCESS_KEY_ID" ]; then
        error_exit "No API keys found! Please set ANTHROPIC_API_KEY or AWS credentials"
    fi

    # Configure Claude Code based on available credentials
    if [ ! -z "$ANTHROPIC_API_KEY" ]; then
        log "🔧 Configuring Claude Code with Anthropic API..."
        log "🌐 Backend: ANTHROPIC DIRECT API"

        # Create comprehensive Claude configuration
        create_claude_config "$ANTHROPIC_API_KEY"

        # Set CLI configuration flags
        configure_claude_cli

        # Verify configuration
        verify_configuration

        # Test basic functionality
        test_claude_functionality

        log "✅ Claude Code configuration completed successfully"
        log "📁 Adding target directory: $TARGET_DIR"
        log "🚀 Starting interactive Claude Code session..."
        log ""
        log "==============================================="
        log "📋 FIRST MESSAGE TO SEND TO CLAUDE:"
        log "I'm working in $TARGET_DIR which doesn't have Amplifier files."
        log "Please cd to that directory and work there."
        log "Do NOT update any issues or PRs in the Amplifier repo."
        log "==============================================="
        log ""

        # Start Claude with enhanced configuration and explicit API key
        claude --api-key "$ANTHROPIC_API_KEY" --add-dir "$TARGET_DIR" --permission-mode acceptEdits

    elif [ ! -z "$AWS_ACCESS_KEY_ID" ]; then
        log "🔧 Configuring Claude Code with AWS Bedrock..."
        log "🌐 Backend: AWS BEDROCK"
        log "🔑 Using provided AWS credentials"
        log "⚠️  Setting CLAUDE_CODE_USE_BEDROCK=1"
        export CLAUDE_CODE_USE_BEDROCK=1

        # Create basic config for Bedrock with comprehensive structure
        mkdir -p "$HOME/.claude"
        cat > "$HOME/.claude.json" << CONFIG_EOF
{
  "useBedrock": true,
  "hasCompletedOnboarding": true,
  "projects": {},
  "customApiKeyResponses": {
    "approved": [],
    "rejected": []
  },
  "mcpServers": {}
}
CONFIG_EOF

        # Set CLI configuration flags
        configure_claude_cli

        # Test basic functionality
        test_claude_functionality

        log "✅ Claude Code Bedrock configuration completed"
        log "📁 Adding target directory: $TARGET_DIR"
        log "🚀 Starting interactive Claude Code session..."
        log ""
        log "==============================================="
        log "📋 FIRST MESSAGE TO SEND TO CLAUDE:"
        log "I'm working in $TARGET_DIR which doesn't have Amplifier files."
        log "Please cd to that directory and work there."
        log "Do NOT update any issues or PRs in the Amplifier repo."
        log "==============================================="
        log ""

        # Start Claude with directory access and explicit permission mode
        claude --add-dir "$TARGET_DIR" --permission-mode acceptEdits
    else
        error_exit "No supported API configuration found!"
    fi
}

# Execute main function
main "$@"
EOF

RUN chmod +x /app/entrypoint.sh

# Set environment variables
ENV TARGET_DIR=/workspace
ENV AMPLIFIER_DATA_DIR=/app/amplifier-data
ENV PATH="/app/amplifier:$PATH"

# Create volumes for mounting
VOLUME ["/workspace", "/app/amplifier-data"]

# Set the working directory to Amplifier before entrypoint
WORKDIR /root/amplifier

# Set entrypoint
ENTRYPOINT ["/app/entrypoint.sh"]