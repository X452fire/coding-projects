import os
import json
from openai import OpenAI
from config import OPENAI_API_KEY, OPENAI_API_BASE, MODEL_NAME
from memory import get_recent_history

# Initialize OpenAI Client (pointing to LocalAI)
client = OpenAI(
    api_key=OPENAI_API_KEY,
    base_url=OPENAI_API_BASE
)

SYSTEM_PROMPT = """
You are JARVIS, a highly advanced, capable, and helpful AI assistant. 
You have control over the user's computer via defined tools.
Your tone is professional, concise, and witty (like JARVIS from Iron Man).
Always prioritize user safety. If an action seems dangerous (like deleting files or system commands), ask for confirmation.
You can see the screen if the user provides a screenshot. 
Use the 'vision' capability to understand context when a screenshot is provided.
"""

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "type_text",
            "description": "Type text on the keyboard.",
            "parameters": {
                "type": "object",
                "properties": {
                    "text": {"type": "string", "description": "The text to type"}
                },
                "required": ["text"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "press_key",
            "description": "Press a specific key on the keyboard.",
            "parameters": {
                "type": "object",
                "properties": {
                    "key": {"type": "string", "description": "The key to press (e.g., 'enter', 'esc', 'win')"}
                },
                "required": ["key"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "open_url",
            "description": "Open a URL in the default web browser.",
            "parameters": {
                "type": "object",
                "properties": {
                    "url": {"type": "string", "description": "The URL to open"}
                },
                "required": ["url"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "open_app",
            "description": "Open a system application.",
            "parameters": {
                "type": "object",
                "properties": {
                    "app_name": {"type": "string", "description": "The name of the application to open"}
                },
                "required": ["app_name"]
            }
        }
    }
]

def process_input(text, screenshot_base64=None):
    """
    Process user input and return a response (text or tool calls).
    """
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT}
    ]
    
    # Add history
    recent_history = get_recent_history(limit=3)
    for msg in recent_history:
        if msg.startswith("User: "):
            messages.append({"role": "user", "content": msg.replace("User: ", "")})
        elif msg.startswith("JARVIS: "):
             messages.append({"role": "assistant", "content": msg.replace("JARVIS: ", "")})

    # Add current user input with optional image
    user_content = []
    user_content.append({"type": "text", "text": text})

    if screenshot_base64:
        user_content.append({
            "type": "image_url",
            "image_url": {
                "url": f"data:image/png;base64,{screenshot_base64}",
                "detail": "high"
            }
        })
    
    messages.append({"role": "user", "content": user_content})

    try:
        response = client.chat.completions.create(
            model=MODEL_NAME, # Use configured model (LocalAI)
            messages=messages,
            tools=TOOLS,
            tool_choice="auto", 
            max_tokens=300
        )
        return response.choices[0].message
    except Exception as e:
        print(f"Error calling OpenAI: {e}")
        return None
