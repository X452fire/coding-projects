import sys
from brain import process_input

print("Starting Text-Based Debug Chat...")
print("Type 'exit' or 'quit' to stop.")

while True:
    try:
        user_input = input("\nYou: ")
        if user_input.lower() in ["exit", "quit"]:
            break
            
        if not user_input.strip():
            continue
            
        print("Sending to Jarvis Brain...")
        response = process_input(user_input)
        
        if response:
            print(f"Jarvis: {response.content}")
            if response.tool_calls:
                print(f"[Tool Calls]: {response.tool_calls}")
        else:
            print("Jarvis: (No response / Error)")
            
    except KeyboardInterrupt:
        print("\nExiting...")
        break
    except Exception as e:
        print(f"Error: {e}")
