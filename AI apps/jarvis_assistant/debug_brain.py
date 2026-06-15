from brain import process_input
import traceback

print("Testing Brain Logic Locally...")
try:
    response = process_input("Hello, are you there?")
    print("Response:", response)
except:
    traceback.print_exc()
