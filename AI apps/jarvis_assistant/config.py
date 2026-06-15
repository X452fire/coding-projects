import os
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

# API Configuration
# LocalAI runs on port 8080 by default
OPENAI_API_BASE = os.getenv("OPENAI_API_BASE", "http://localhost:8080/v1")
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY", "sk-xxx") # Dummy key for LocalAI
MODEL_NAME = os.getenv("MODEL_NAME", "gpt-3.5-turbo") # Model name to use

# LocalAI Startup Command
# Adjust this command based on your installation (Docker, binary, etc.)
# Example Docker command:
LOCALAI_START_COMMAND = "docker run -d -p 8080:8080 --name local-ai -ti localai/localai:latest-aio-cpu"

# Voice Settings
VOICE_RATE = 175  # Words per minute
VOICE_VOLUME = 1.0 # 0.0 to 1.0

# Paths
MEMORY_FILE = os.path.join(os.path.dirname(__file__), "memory.json")
SCREENSHOT_PATH = os.path.join(os.path.dirname(__file__), "screenshot.png")
