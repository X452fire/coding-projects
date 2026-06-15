import speech_recognition as sr
import time

def check_mics():
    print("Checking microphones...")
    mics = sr.Microphone.list_microphone_names()
    
    if not mics:
        print("No microphones found!")
        return

    print(f"Found {len(mics)} microphones:")
    for i, mic_name in enumerate(mics):
        print(f"Index {i}: {mic_name}")

    print("\n--- Testing Default Microphone ---")
    try:
        with sr.Microphone() as source:
            r = sr.Recognizer()
            print("Adjusting for ambient noise (please wait)...")
            r.adjust_for_ambient_noise(source, duration=1)
            print(f"Listening on default mic ({mics[0] if mics else 'Unknown'})... Say something!")
            audio = r.listen(source, timeout=5)
            print("Got audio! Recognizing...")
            try:
                text = r.recognize_google(audio)
                print(f"Success! Heard: '{text}'")
            except sr.UnknownValueError:
                print("Could not understand audio.")
            except sr.RequestError as e:
                print(f"API Error: {e}")
    except Exception as e:
        print(f"Error accessing default microphone: {e}")
        print("Try ensuring your preferred microphone is set as the 'Default Recording Device' in Windows Sound Settings.")

if __name__ == "__main__":
    check_mics()
    input("\nPress Enter to exit...")
