import time
import json
from voice import speak, listen
from vision import take_screenshot, encode_image
from actions import execute_command
from brain import process_input
from memory import log_interaction

from config import LOCALAI_START_COMMAND, OPENAI_API_BASE
import requests
import subprocess
import threading

def check_localai():
    """
    Checks if LocalAI is running. If not, attempts to start it.
    Waits for the service to be fully ready (models loaded).
    """
    print("Checking LocalAI status...")
    
    # 1. Ensure Container is Running
    try:
        check_cmd = "docker inspect local-ai"
        if subprocess.run(check_cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            # Check if it's actually running
            state_cmd = "docker inspect -f '{{.State.Running}}' local-ai"
            result = subprocess.run(state_cmd, shell=True, capture_output=True, text=True)
            if result.stdout.strip() != 'true':
                print("Found existing 'local-ai' container. Starting it...")
                subprocess.run("docker start local-ai", shell=True, check=True)
            else:
                print("'local-ai' container is already running.")
        else:
            print("Creating new 'local-ai' container...")
            subprocess.Popen(LOCALAI_START_COMMAND, shell=True)
            print(f"Executed: {LOCALAI_START_COMMAND}")
            time.sleep(5) # Give docker a moment to register
            
    except Exception as e:
        print(f"Docker management failed: {e}")
        # We continue anyway, in case it's running via another method
    
    # 2. Wait for API to be Ready
    print("Waiting for LocalAI to be ready (this may take up to 20 minutes for first-time model download)...")
    speak("LocalAI is initializing. This may take a few minutes if I need to download new models.")
    
    max_retries = 120 # 20 minutes (10s * 120)
    for i in range(max_retries):
        try:
            requests.get(f"{OPENAI_API_BASE.replace('/v1', '')}/readyz", timeout=2)
            print("\nLocalAI is ready!")
            return True
        except requests.exceptions.RequestException:
            print(".", end="", flush=True)
            if i % 6 == 0 and i > 0: # Every minute
                speak("Still initializing...")
            time.sleep(10)
            
    print("\nLocalAI timed out.")
    speak("I'm sorry, I couldn't connect to my brain. Please check the logs.")
    return False

def main():
    check_localai()
    speak("JARVIS systems online. Waiting for instructions.")
    
    while True:
        # Listen for audio
        user_text = listen()
        if not user_text:
            continue
            
        print(f"Processing: {user_text}")
        
        # Check for specific "vision" triggers
        vision_triggers = ["screen", "look at this", "what do you see", "read this"]
        screenshot_b64 = None
        
        if any(trigger in user_text.lower() for trigger in vision_triggers):
            print("Capturing visual data...")
            screenshot_path = take_screenshot()
            screenshot_b64 = encode_image(screenshot_path)
            speak("I'm looking at your screen now.")

        # Process with Brain
        response_message = process_input(user_text, screenshot_b64)
        
        if not response_message:
            speak("I'm sorry, I couldn't process that.")
            continue

        # Handle Tool Calls (Actions)
        if response_message.tool_calls:
            for tool_call in response_message.tool_calls:
                function_name = tool_call.function.name
                function_args = json.loads(tool_call.function.arguments)
                
                # Verbal confirmation for action
                speak(f"Executing {function_name}...")
                
                execute_command(function_name, function_args)
                
                # Optional: Feed back result to brain (simplified here to just action done)
                log_interaction(user_text, f"Action Taken: {function_name}")
        
        # Handle Verbal Response
        if response_message.content:
            speak(response_message.content)
            log_interaction(user_text, response_message.content)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        speak("Shutting down systems.")
