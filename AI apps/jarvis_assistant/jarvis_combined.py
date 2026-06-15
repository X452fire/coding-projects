import os
import json
import time
import threading
import base64
import subprocess
import webbrowser
import requests
from dotenv import load_dotenv
import speech_recognition as sr
import pyttsx3
import pyautogui
from openai import OpenAI

# ==========================================
# CONFIGURATION
# ==========================================
load_dotenv()

# API Configuration
OPENAI_API_BASE = os.getenv("OPENAI_API_BASE", "http://localhost:8080/v1")
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY", "sk-xxx")
MODEL_NAME = os.getenv("MODEL_NAME", "gpt-3.5-turbo")

# LocalAI Startup Command
LOCALAI_START_COMMAND = "docker run -d -p 8080:8080 --name local-ai -ti localai/localai:latest-aio-cpu"

# Voice Settings
VOICE_RATE = 175
VOICE_VOLUME = 1.0

# Paths
MEMORY_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "memory.json")
SCREENSHOT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "screenshot.png")

# ==========================================
# MEMORY MODULE
# ==========================================
def load_memory():
    """Loads memory from the JSON file."""
    if not os.path.exists(MEMORY_FILE):
        return {"history": [], "preferences": {}, "user_data": {}}
    
    try:
        with open(MEMORY_FILE, 'r') as f:
            return json.load(f)
    except json.JSONDecodeError:
        return {"history": [], "preferences": {}, "user_data": {}}

def save_memory(memory_data):
    """Saves memory to the JSON file."""
    with open(MEMORY_FILE, 'w') as f:
        json.dump(memory_data, f, indent=4)

def log_interaction(user_input, assistant_response):
    """Logs a turn of conversation to memory."""
    memory = load_memory()
    memory["history"].append({"user": user_input, "jarvis": assistant_response})
    if len(memory["history"]) > 50:
        memory["history"] = memory["history"][-50:]
    save_memory(memory)

def get_recent_history(limit=5):
    """Returns recent conversation history strings."""
    memory = load_memory()
    history = memory.get("history", [])
    if not history:
        return []
    
    formatted_history = []
    for turn in history[-limit:]:
        formatted_history.append(f"User: {turn['user']}")
        formatted_history.append(f"JARVIS: {turn['jarvis']}")
    return formatted_history

# ==========================================
# VOICE MODULE
# ==========================================
engine = pyttsx3.init()
engine.setProperty('rate', VOICE_RATE)
engine.setProperty('volume', VOICE_VOLUME)

voices = engine.getProperty('voices')
if voices:
    for voice in voices:
        if "david" in voice.name.lower() or "zira" in voice.name.lower():
            engine.setProperty('voice', voice.id)
            break

def speak(text):
    """Convert text to speech."""
    print(f"JARVIS: {text}")
    engine.say(text)
    engine.runAndWait()

def listen():
    """Listen to microphone input and return text."""
    r = sr.Recognizer()
    with sr.Microphone() as source:
        print("Listening...")
        r.adjust_for_ambient_noise(source, duration=0.5)
        try:
            audio = r.listen(source, timeout=5, phrase_time_limit=10)
            text = r.recognize_google(audio)
            print(f"User: {text}")
            return text
        except (sr.WaitTimeoutError, sr.UnknownValueError):
            return None
        except sr.RequestError as e:
            print(f"Could not request results; {e}")
            return None

# ==========================================
# VISION MODULE
# ==========================================
def take_screenshot():
    """Captures the screen and saves it."""
    screenshot = pyautogui.screenshot()
    screenshot.save(SCREENSHOT_PATH)
    return SCREENSHOT_PATH

def encode_image(image_path):
    """Encodes an image file to base64 string."""
    with open(image_path, "rb") as image_file:
        return base64.b64encode(image_file.read()).decode('utf-8')

# ==========================================
# ACTIONS MODULE
# ==========================================
def type_text(text):
    pyautogui.write(text, interval=0.05)

def press_key(key):
    pyautogui.press(key)

def click_mouse(x, y):
    pyautogui.click(x, y)

def open_url(url):
    webbrowser.open(url)

def open_app(app_name):
    pyautogui.press('win')
    time.sleep(0.5)
    pyautogui.write(app_name)
    time.sleep(1)
    pyautogui.press('enter')

def execute_command(action_type, payload):
    """Executes a command based on type and payload."""
    print(f"Executing: {action_type} with {payload}")
    
    if action_type == "type_text":
        type_text(payload.get("text"))
    elif action_type == "press_key":
        press_key(payload.get("key"))
    elif action_type == "click_mouse":
        x = payload.get("x")
        y = payload.get("y")
        if x and y:
            click_mouse(x, y)
    elif action_type == "open_url":
        open_url(payload.get("url"))
    elif action_type == "open_app":
        open_app(payload.get("app_name"))
    else:
        print(f"Unknown action: {action_type}")

# ==========================================
# BRAIN MODULE
# ==========================================
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
    """Process user input and return a response (text or tool calls)."""
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT}
    ]
    
    recent_history = get_recent_history(limit=3)
    for msg in recent_history:
        if msg.startswith("User: "):
            messages.append({"role": "user", "content": msg.replace("User: ", "")})
        elif msg.startswith("JARVIS: "):
             messages.append({"role": "assistant", "content": msg.replace("JARVIS: ", "")})

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
            model=MODEL_NAME,
            messages=messages,
            tools=TOOLS,
            tool_choice="auto", 
            max_tokens=300
        )
        return response.choices[0].message
    except Exception as e:
        print(f"Error calling OpenAI: {e}")
        return None

# ==========================================
# MAIN EXECUTION
# ==========================================
def check_localai():
    """Checks if LocalAI is running. If not, attempts to start it."""
    print("Checking LocalAI status...")
    try:
        requests.get(f"{OPENAI_API_BASE.replace('/v1', '')}/readyz", timeout=2)
        print("LocalAI is running.")
        return True
    except requests.exceptions.RequestException:
        print("LocalAI not found. Attempting to start...")
        try:
            subprocess.Popen(LOCALAI_START_COMMAND, shell=True)
            print(f"Executed: {LOCALAI_START_COMMAND}")
            print("Waiting 10s for startup...")
            time.sleep(10)
            return True
        except Exception as e:
            print(f"Failed to start LocalAI: {e}")
            return False

def main():
    check_localai()
    speak("JARVIS systems online. Waiting for instructions.")
    
    while True:
        user_text = listen()
        if not user_text:
            continue
            
        print(f"Processing: {user_text}")
        
        vision_triggers = ["screen", "look at this", "what do you see", "read this"]
        screenshot_b64 = None
        
        if any(trigger in user_text.lower() for trigger in vision_triggers):
            print("Capturing visual data...")
            screenshot_path = take_screenshot()
            screenshot_b64 = encode_image(screenshot_path)
            speak("I'm looking at your screen now.")

        response_message = process_input(user_text, screenshot_b64)
        
        if not response_message:
            speak("I'm sorry, I couldn't process that.")
            continue

        if response_message.tool_calls:
            for tool_call in response_message.tool_calls:
                function_name = tool_call.function.name
                function_args = json.loads(tool_call.function.arguments)
                
                speak(f"Executing {function_name}...")
                execute_command(function_name, function_args)
                log_interaction(user_text, f"Action Taken: {function_name}")
        
        if response_message.content:
            speak(response_message.content)
            log_interaction(user_text, response_message.content)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        speak("Shutting down systems.")
