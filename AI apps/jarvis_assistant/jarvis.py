import os
import time
import json
import base64
import io
import threading
import webbrowser
import platform
import subprocess
import pyautogui
import pygame
import speech_recognition as sr
import pyttsx3
from openai import OpenAI
import anthropic
from anthropic import Anthropic
from dotenv import load_dotenv
from PIL import Image
import traceback

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
load_dotenv()

# API Configuration
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY")
OPENAI_API_BASE = "https://api.openai.com/v1"
MODEL_NAME = "gpt-4o"
CLAUDE_MODEL = "claude-3-5-sonnet-20241022"

# Voice Settings
VOICE_RATE = 175
VOICE_VOLUME = 1.0

# Paths
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
MEMORY_FILE = os.path.join(BASE_DIR, "memory.json")
SCREENSHOT_PATH = os.path.join(BASE_DIR, "screenshot.png")

# System Prompt
SYSTEM_PROMPT = """
You are JARVIS, a highly advanced, capable, and helpful AI assistant. 
You have control over the user's computer via defined tools.
Your tone is professional, concise, and witty (like JARVIS from Iron Man).
Always prioritize user safety. If an action seems dangerous, ask for confirmation.

IMPORTANT - YOU MUST USE THESE TOOLS:

1. CLICKING: Use click_on to click on screen elements.
   - For taskbar icons: use descriptions like "Chrome icon in taskbar", "File Explorer in taskbar"
   - For buttons: use descriptions like "Submit button", "Close button"

2. TYPING: Use type_text to type text. ALWAYS call this tool when the user asks you to type!
   - If user says "type hello" → use type_text with text "hello"
   - If user says "type the definition of X" → use type_text with the definition
   - You MUST use type_text tool, do not just describe what you would type

3. KEYS: Use press_key for keyboard keys (enter, esc, tab, etc.)

MULTI-STEP ACTIONS:
When asked to type in a specific location, use BOTH tools:
1. First: click_on to position cursor
2. Then: type_text to type the content

CRITICAL: When the user asks you to "type" something, you MUST call the type_text tool!
Do NOT just respond with text - actually execute the type_text function.

You have a live view of the screen. You CAN see and interact with everything.
"""

# Tools Definition
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
    },
    {
        "type": "function",
        "function": {
            "name": "click_on",
            "description": "Click on a screen element by describing it. Example: 'Chrome icon', 'Submit button', 'Close window'. The assistant will analyze the screen and click on the described element.",
            "parameters": {
                "type": "object",
                "properties": {
                    "description": {"type": "string", "description": "Description of the element to click on"}
                },
                "required": ["description"]
            }
        }
    }
]

# -----------------------------------------------------------------------------
# MEMORY MODULE
# -----------------------------------------------------------------------------
def load_memory():
    default_memory = {"history": [], "preferences": {}, "user_data": {}}
    try:
        if os.path.exists(MEMORY_FILE):
            with open(MEMORY_FILE, 'r') as f:
                data = json.load(f)
                if isinstance(data, dict):
                    return data
    except Exception as e:
        print(f"Error loading memory: {e}")
    return default_memory

def save_memory(memory_data):
    with open(MEMORY_FILE, 'w') as f:
        json.dump(memory_data, f, indent=4)

def log_interaction(user_input, assistant_response):
    memory = load_memory()
    memory["history"].append({"user": user_input, "jarvis": assistant_response})
    if len(memory["history"]) > 50:
        memory["history"] = memory["history"][-50:]
    save_memory(memory)

def get_recent_history(limit=5):
    memory = load_memory()
    history = memory["history"]
    formatted_history = []
    for turn in history[-limit:]:
        formatted_history.append(f"User: {turn['user']}")
        formatted_history.append(f"JARVIS: {turn['jarvis']}")
    return formatted_history

# -----------------------------------------------------------------------------
# VOICE MODULE
# -----------------------------------------------------------------------------
# Global clients
CLIENT = None
CLAUDE_CLIENT = None
interrupt_speech = False
is_speaking = False
tts_lock = threading.Lock()

def speak(text):
    print(f"JARVIS: {text}")
    global interrupt_speech, is_speaking
    
    with tts_lock:
        interrupt_speech = False
        is_speaking = True
    
        # Initialize local TTS engine freshly
        try:
            engine = pyttsx3.init()
            engine.setProperty('rate', 175)
            engine.setProperty('volume', 1.0)
        except Exception as e:
            print(f"Failed to initialize TTS engine: {e}")
            is_speaking = False
            return
    
        # Start voice monitoring thread
        def monitor_voice(current_engine):
            global interrupt_speech, is_speaking
            r = sr.Recognizer()
            r.energy_threshold = 1000
            r.dynamic_energy_threshold = False
            
            while is_speaking and not interrupt_speech:
                try:
                    with sr.Microphone() as source:
                        r.adjust_for_ambient_noise(source, duration=0.1)
                        try:
                            audio = r.listen(source, timeout=0.3, phrase_time_limit=0.5)
                            try:
                                # Use a very fast local check if possible, but google is fine for now
                                r.recognize_google(audio)
                                with tts_lock:
                                    interrupt_speech = True
                                print("\n[Interrupted by voice]")
                                current_engine.stop()
                                return
                            except:
                                pass
                        except:
                            pass
                except:
                    pass
    
        # Keyboard interrupt monitor
        def monitor_keyboard(current_engine):
            global interrupt_speech, is_speaking
            try:
                import keyboard
                while is_speaking and not interrupt_speech:
                    if keyboard.is_pressed('!'):
                        with tts_lock:
                            interrupt_speech = True
                        print("\n[Interrupted by keyboard (!)]")
                        current_engine.stop()
                        return
                    time.sleep(0.05)
            except:
                pass
    
        # Use threads for the monitors
        v_thread = threading.Thread(target=monitor_voice, args=(engine,), daemon=True)
        k_thread = threading.Thread(target=monitor_keyboard, args=(engine,), daemon=True)
        v_thread.start()
        k_thread.start()
    
        try:
            engine.say(text)
            engine.runAndWait()
        except Exception as e:
            print(f"TTS Playback Error: {e}")
        finally:
            is_speaking = False
            try:
                engine.stop()
            except:
                pass

def listen():
    r = sr.Recognizer()
    # Set pause threshold to 1.5 seconds - how long to wait in silence before considering input complete
    r.pause_threshold = 1.5  # Default is 0.8 seconds
    try:
        with sr.Microphone() as source:
            print("Listening...")
            r.adjust_for_ambient_noise(source, duration=0.5)
            try:
                audio = r.listen(source, timeout=5, phrase_time_limit=10)
                text = r.recognize_google(audio)
                print(f"User: {text}")
                return text
            except sr.WaitTimeoutError:
                return None
            except sr.UnknownValueError:
                print("Debug: Silence / Unintelligible.")
                return None
            except sr.RequestError as e:
                print(f"Debug: API Connection Error: {e}")
                return None
    except Exception as e:
        print(f"Debug: Mic Error: {e}")
        return None

# -----------------------------------------------------------------------------
# VISION MODULE
# -----------------------------------------------------------------------------
# Background screenshot capture
latest_screenshot_b64 = None
latest_screenshot_dims = (1366, 768) # Default
screenshot_thread_running = False
screenshot_lock = threading.Lock()

def background_screenshot_capture():
    """Continuously capture screenshots in the background"""
    global latest_screenshot_b64, latest_screenshot_dims, screenshot_thread_running
    while screenshot_thread_running:
        try:
            # Capture screenshot
            screenshot = pyautogui.screenshot()
            
            # Convert to RGB if necessary
            if screenshot.mode != 'RGB':
                screenshot = screenshot.convert('RGB')
            
            w, h = screenshot.size
            
            # Save to BytesIO object for in-memory processing
            buffered = io.BytesIO()
            screenshot.save(buffered, format="JPEG", quality=85)
            
            # Update global variables with lock
            with screenshot_lock:
                latest_screenshot_b64 = base64.b64encode(buffered.getvalue()).decode('utf-8')
                latest_screenshot_dims = (w, h)
            
            # Update local file as well for debug/reference (optional, maybe less frequent?)
            # screenshot.save(SCREENSHOT_PATH)
            
        except Exception as e:
            print(f"Debug: Screen capture error: {e}")
            
        time.sleep(0.5)

def start_screenshot_thread():
    """Start the background screenshot capture thread"""
    global screenshot_thread_running
    screenshot_thread_running = True
    thread = threading.Thread(target=background_screenshot_capture, daemon=True)
    thread.start()
    print("Background screen capture started.")

def stop_screenshot_thread():
    """Stop the background screenshot capture thread"""
    global screenshot_thread_running
    screenshot_thread_running = False

def get_latest_screenshot_data():
    """Get the latest captured screenshot and its dimensions"""
    global latest_screenshot_b64, latest_screenshot_dims
    with screenshot_lock:
        if latest_screenshot_b64:
            return latest_screenshot_b64, latest_screenshot_dims
    
    # Fallback: take a fresh screenshot if none available
    try:
        screenshot = pyautogui.screenshot()
        w, h = screenshot.size
        buffered = io.BytesIO()
        screenshot.save(buffered, format="JPEG", quality=85)
        return base64.b64encode(buffered.getvalue()).decode('utf-8'), (w, h)
    except Exception as e:
        print(f"Debug: Fresh capture failed: {e}")
        return None, (1366, 768)

def take_screenshot():
    """Legacy function to maintain compatibility if needed elsewhere"""
    screenshot = pyautogui.screenshot()
    screenshot.save(SCREENSHOT_PATH)
    return SCREENSHOT_PATH

def encode_image(image_path):
    """Legacy function to maintain compatibility"""
    with open(image_path, "rb") as image_file:
        return base64.b64encode(image_file.read()).decode('utf-8')

# -----------------------------------------------------------------------------
# ACTIONS MODULE
# -----------------------------------------------------------------------------
def execute_command(action_type, payload):
    print(f"Executing: {action_type} with {payload}")
    global CLIENT
    try:
        if action_type == "type_text":
            pyautogui.write(payload.get("text"), interval=0.05)
        elif action_type == "press_key":
            pyautogui.press(payload.get("key"))
        elif action_type == "open_url":
            webbrowser.open(payload.get("url"))
        elif action_type == "open_app":
            app_name = payload.get("app_name")
            pyautogui.press('win')
            time.sleep(0.5)
            pyautogui.write(app_name)
            time.sleep(1)
            pyautogui.press('enter')
        elif action_type == "click_on":
            description = payload.get("description")
            print(f"Analyzing screen for: {description}")
            
            # Use the latest pre-captured screenshot data
            screenshot_b64, (screenshot_width, screenshot_height) = get_latest_screenshot_data()
            
            # Get screen dimensions
            screen_width, screen_height = pyautogui.size()
            
            # Get current mouse position for context
            mouse_x, mouse_y = pyautogui.position()
            print(f"Current mouse position: ({mouse_x}, {mouse_y})")
            
            # Calculate scaling factors
            scale_x = screen_width / screenshot_width
            scale_y = screen_height / screenshot_height
            
            # Convert mouse position to screenshot coordinates
            mouse_screenshot_x = int(mouse_x / scale_x)
            mouse_screenshot_y = int(mouse_y / scale_y)
            
            print(f"Screen: {screen_width}x{screen_height}, Screenshot: {screenshot_width}x{screenshot_height}")
            if scale_x != 1.0 or scale_y != 1.0:
                print(f"Scale factors: X={scale_x:.2f}, Y={scale_y:.2f}")
            
            # Ask Claude vision model to find coordinates
            global CLAUDE_CLIENT
            if not CLAUDE_CLIENT and ANTHROPIC_API_KEY:
                CLAUDE_CLIENT = Anthropic(api_key=ANTHROPIC_API_KEY)
            
            if not screenshot_b64:
                print("Error: No screenshot available for Claude.")
                speak("I don't have a view of the screen right now.")
                return

            print(f"DEBUG: Screenshot B64 Length: {len(screenshot_b64)}")
            
            try:
                try:
                    response = CLAUDE_CLIENT.messages.create(
                        model=CLAUDE_MODEL,
                        max_tokens=100,
                        system=f"""You are a precise computer vision assistant for screen automation.
Your ONLY job is to locate UI elements and return their CENTER pixel coordinates.

SCREEN INFO:
- Resolution: {screenshot_width}x{screenshot_height} pixels
- Valid X range: 0 to {screenshot_width-1}
- Valid Y range: 0 to {screenshot_height-1}

COMMON SCREEN REGIONS (for {screenshot_height}px height):
- Taskbar (bottom): Y is typically > {screenshot_height - 50}
- Title bars (top): Y is typically < 50

OUTPUT FORMAT:
Respond with EXACTLY two integers separated by a comma: x,y
Example: 127,744
NO other text, NO explanation, NO quotes.""",
                        messages=[
                            {
                                "role": "user",
                                "content": [
                                    {
                                        "type": "image",
                                        "source": {
                                            "type": "base64",
                                            "media_type": "image/jpeg",
                                            "data": screenshot_b64,
                                        },
                                    },
                                    {
                                        "type": "text",
                                        "text": f"Find the UI element: \"{description}\"\nCurrent mouse position: ({mouse_screenshot_x}, {mouse_screenshot_y})\nReturn the CENTER coordinates as: x,y"
                                    }
                                ],
                            }
                        ],
                    )
                except anthropic.AnthropicError as e:
                    print(f"Anthropic API Error: {e}")
                    if hasattr(e, 'response'):
                        print(f"Response data: {e.response}")
                    raise e
                
                coord_text = response.content[0].text.strip()
                print(f"Claude Vision response: {coord_text}")
                
                # Parse coordinates with better error handling
                try:
                    import re
                    # Try to extract numbers from response
                    coord_text = coord_text.replace(' ', '').strip()
                    
                    # Try regex to find coordinate pattern
                    match = re.search(r'(\d+),(\d+)', coord_text)
                    if match:
                        x = int(match.group(1))
                        y = int(match.group(2))
                    elif ',' in coord_text:
                        parts = coord_text.split(',')
                        x = int(parts[0])
                        y = int(parts[1])
                    else:
                        raise ValueError(f"Could not parse coordinates from: {coord_text}")
                    
                    print(f"Raw coordinates from Claude: ({x}, {y})")
                    
                    # Validate coordinates are reasonable
                    if y > screenshot_height * 2:
                        y = int(str(y)[:3]) if len(str(y)) > 3 else y
                    
                    # Apply scaling correction if needed
                    if scale_x != 1.0 or scale_y != 1.0:
                        x = int(x * scale_x)
                        y = int(y * scale_y)
                        print(f"Scaled coordinates: ({x}, {y})")
                    
                    # Clamp to screen bounds
                    x = max(0, min(x, screen_width - 1))
                    y = max(0, min(y, screen_height - 1))
                    
                    print(f"Internal Touch: Clicking at ({x}, {y})")
                    pyautogui.click(x, y)
                    
                except (ValueError, IndexError) as parse_error:
                    print(f"Failed to parse coordinates: '{coord_text}' - {parse_error}")
                    speak("I couldn't locate that element. Try describing it differently.")
                    return
                
            except Exception as e:
                print(f"Claude Vision analysis failed: {e}")
                print(traceback.format_exc())
                speak("Sorry, I couldn't analyze the screen with Claude.")
                
    except Exception as e:
        print(f"Action failed: {e}")

# -----------------------------------------------------------------------------
# BRAIN & MAIN LOGIC
# -----------------------------------------------------------------------------
def get_client():
    if not OPENAI_API_KEY:
        return None
    return OpenAI(api_key=OPENAI_API_KEY)

def process_input(client, text, screenshot_base64=None):
    messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    
    # History
    recent_history = get_recent_history(limit=5)
    for msg in recent_history:
        if msg.startswith("User: "):
            messages.append({"role": "user", "content": msg.replace("User: ", "")})
        elif msg.startswith("JARVIS: "):
             messages.append({"role": "assistant", "content": msg.replace("JARVIS: ", "")})

    # Current Input
    user_content = [{"type": "text", "text": text}]
    if screenshot_base64:
        user_content.append({
            "type": "image_url",
            "image_url": {"url": f"data:image/png;base64,{screenshot_base64}"}
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

def main():
    global OPENAI_API_KEY, ANTHROPIC_API_KEY
    print("Initializing JARVIS (Claude Edition)...")
    
    if not OPENAI_API_KEY:
        speak("I need your Open A.I. API key to proceed.")
        OPENAI_API_KEY = input("Enter OpenAI API Key: ").strip()
        if not OPENAI_API_KEY:
            print("No key provided. Exiting.")
            return

    if not ANTHROPIC_API_KEY:
        speak("I also need your Claude API key for vision integration.")
        ANTHROPIC_API_KEY = input("Enter Claude API Key: ").strip()
        if not ANTHROPIC_API_KEY:
            print("No Anthropic key provided. Exiting.")
            return

    # Start background screen capture
    start_screenshot_thread()
    
    client = get_client()
    speak("Systems online. Ready.")

    while True:
        user_text = listen()
        if not user_text:
            continue
            
        print(f"Processing: {user_text}")
        
        # Vision - always include latest screenshot for context
        screenshot_b64, _ = get_latest_screenshot_data()
        
        # Brain Processing
        response_message = process_input(client, user_text, screenshot_b64)
        
        if not response_message:
            speak("I couldn't get a response.")
            continue

        # Tool Execution
        if response_message.tool_calls:
            for tool_call in response_message.tool_calls:
                func_name = tool_call.function.name
                func_args = json.loads(tool_call.function.arguments)
                speak(f"Executing {func_name}...")
                try:
                    execute_command(func_name, func_args)
                except Exception as e:
                    print(f"Error executing {func_name}: {e}")
                    speak(f"Sorry, I encountered an error while executing that command.")

        # Verbal Response
        if response_message.content:
            speak(response_message.content)
            log_interaction(user_text, response_message.content)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        speak("Shutting down.")
