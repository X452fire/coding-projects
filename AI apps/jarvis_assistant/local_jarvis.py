import time
import requests
import json
from voice import speak, listen
from vision import take_screenshot, encode_image
from actions import execute_command
import os

# Server URL (Docker Brain)
BRAIN_URL = "http://localhost:5000/process"
HEALTH_URL = "http://localhost:5000/health"

def wait_for_brain():
    """Waits for the Docker Brain to be online."""
    print("Waiting for JARVIS Brain to come online...")
    while True:
        try:
            resp = requests.get(HEALTH_URL, timeout=2)
            if resp.status_code == 200:
                print("Connected to Brain.")
                speak("Connection to server established.")
                break
        except requests.exceptions.ConnectionError:
            pass
        time.sleep(2)

def main():
    wait_for_brain()
    speak("JARVIS systems online. Waiting for instructions.")
    
    while True:
        # 1. Listen
        user_text = listen()
        if not user_text:
            continue
            
        print(f"Heard: {user_text}")
        
        # 2. Check for Vision Triggers locally to decide if we send image
        vision_triggers = ["screen", "look at this", "what do you see", "read this", "capture"]
        screenshot_b64 = None
        
        if any(trigger in user_text.lower() for trigger in vision_triggers):
            print("Capturing screen...")
            path = take_screenshot()
            screenshot_b64 = encode_image(path)
            speak("I'm analyzing the screen.")

        # 3. Send to Brain
        payload = {
            "text": user_text,
            "screenshot": screenshot_b64
        }
        
        try:
            # Increased timeout for local CPU inference
            response = requests.post(BRAIN_URL, json=payload, timeout=60)
            response.raise_for_status()
            data = response.json()
            
            content = data.get("content")
            tool_calls = data.get("tool_calls", [])
            
            # 4. Handle Tool Calls
            if tool_calls:
                for tool in tool_calls:
                    func_name = tool["name"]
                    args = tool["arguments"]
                    
                    speak(f"Executing {func_name}...")
                    execute_command(func_name, args)
                    # Note: In a complex agent, we would send the result back to brain here.
                    # For simplicity, we just proceed.
            
            # 5. Handle Verbal Response
            if content:
                speak(content)
                
        except Exception as e:
            print(f"Error communicating with Brain: {e}")
            speak("I lost connection to the server.")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        speak("Shutting down.")
