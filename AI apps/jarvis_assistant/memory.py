import json
import os
from config import MEMORY_FILE

def load_memory():
    """
    Loads memory from the JSON file.
    """
    default_memory = {"history": [], "preferences": {}, "user_data": {}}
    
    try:
        if os.path.exists(MEMORY_FILE):
            with open(MEMORY_FILE, 'r') as f:
                data = json.load(f)
                if isinstance(data, dict):
                    return data
                print("Memory file corrupted (not a dict), resetting.")
    except Exception as e:
        print(f"Error loading memory: {e}")
    
    return default_memory

def save_memory(memory_data):
    """
    Saves memory to the JSON file.
    """
    with open(MEMORY_FILE, 'w') as f:
        json.dump(memory_data, f, indent=4)

def log_interaction(user_input, assistant_response):
    """
    Logs a turn of conversation to memory.
    """
    memory = load_memory()
    memory["history"].append({"user": user_input, "jarvis": assistant_response})
    # Keep history manageable
    if len(memory["history"]) > 50:
        memory["history"] = memory["history"][-50:]
    save_memory(memory)

def get_recent_history(limit=5):
    """
    Returns recent conversation history strings.
    """
    memory = load_memory()
    history = memory.get("history", [])
    if not history:
        return []
    
    formatted_history = []
    for turn in history[-limit:]:
        formatted_history.append(f"User: {turn['user']}")
        formatted_history.append(f"JARVIS: {turn['jarvis']}")
    return formatted_history
