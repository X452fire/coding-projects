import os
import json
from flask import Flask, request, jsonify
from brain import process_input, TOOLS
from memory import log_interaction
from config import OPENAI_API_BASE, OPENAI_API_KEY
import requests
import time

app = Flask(__name__)

# Health check logic from original main.py to ensure LocalAI is ready
def check_localai():
    print(f"Checking LocalAI at {OPENAI_API_BASE}...")
    # Clean URL for ready check (remove /v1 if present for some endpoints, or keep it)
    # LocalAI often has /readyz at root or under /v1 depending on version. 
    # We'll try a simple model list or just assume it's up if valid.
    # For now, we trust docker-compose healthchecks, but let's log.
    pass

@app.route('/health', methods=['GET'])
def health():
    return jsonify({"status": "active", "brain": "connected"}), 200

@app.route('/process', methods=['POST'])
def process():
    """
    Endpoint to process user input.
    Payload: {
        "text": "User spoken text",
        "screenshot": "Base64 string (optional)",
        "tool_result": "Result from previous tool call (optional)"
    }
    """
    data = request.json
    user_text = data.get("text")
    screenshot = data.get("screenshot")
    
    if not user_text:
        return jsonify({"error": "No text provided"}), 400

    print(f"Brain received: {user_text}")

    try:
        # Process input using brain.py logic
        response_message = process_input(user_text, screenshot)
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"CRITICAL ERROR in process_input: {e}")
        return jsonify({"error": str(e)}), 500
    
    if not response_message:
        return jsonify({"content": "I encountered an error processing that (Brain returned None).", "tool_calls": []})

    # Extract content and tool calls
    content = response_message.content
    tool_calls_data = []
    
    if response_message.tool_calls:
        for tc in response_message.tool_calls:
            tool_calls_data.append({
                "name": tc.function.name,
                "arguments": json.loads(tc.function.arguments)
            })

    # Log interaction
    log_interaction(user_text, content or "Tool Call")

    return jsonify({
        "content": content,
        "tool_calls": tool_calls_data
    })

if __name__ == "__main__":
    check_localai()
    print("Starting JARVIS Brain Server...")
    app.run(host='0.0.0.0', port=5000)
