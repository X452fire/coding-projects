import pyautogui
import webbrowser
import os
import subprocess
import time

def type_text(text):
    pyautogui.write(text, interval=0.05)

def press_key(key):
    pyautogui.press(key)

def click_mouse(x, y):
    pyautogui.click(x, y)

def open_url(url):
    webbrowser.open(url)

def open_app(app_name):
    # This is a basic implementation. For Windows, we can use 'start' command or search.
    # More robust way is to just hit start and type the name.
    pyautogui.press('win')
    time.sleep(0.5)
    pyautogui.write(app_name)
    time.sleep(1)
    pyautogui.press('enter')

def execute_command(action_type, payload):
    """
    Executes a command based on type and payload.
    """
    print(f"Executing: {action_type} with {payload}")
    
    if action_type == "type":
        type_text(payload.get("text"))
    elif action_type == "press":
        press_key(payload.get("key"))
    elif action_type == "click":
        # Requires coordinates, which AI might not guess accurately without context,
        # but vision can provide them in advanced scenarios.
        x = payload.get("x")
        y = payload.get("y")
        if x and y:
            click_mouse(x, y)
    elif action_type == "open_url":
        open_url(payload.get("url"))
    elif action_type == "open_app":
        open_app(payload.get("app_name"))
    elif action_type == "cmd":
         # VERY DANGEROUS, keep guarded in main logic
         pass
    else:
        print(f"Unknown action: {action_type}")
