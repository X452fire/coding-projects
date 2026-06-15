import requests
import os
import sys

URL = "https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf?download=true"
DEST = r"c:\Users\jaigo\.gemini\antigravity\scratch\jarvis_assistant\models\tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf"

def download_file():
    print(f"Downloading model to {DEST}...")
    try:
        if os.path.exists(DEST):
            print("File exists, overwriting to ensure integrity...")
        
        with requests.get(URL, stream=True) as r:
            r.raise_for_status()
            total_length = r.headers.get('content-length')
            
            with open(DEST, 'wb') as f:
                if total_length is None: # no content length header
                    f.write(r.content)
                else:
                    dl = 0
                    total_length = int(total_length)
                    for chunk in r.iter_content(chunk_size=8192):
                        if chunk: 
                            dl += len(chunk)
                            f.write(chunk)
                            done = int(50 * dl / total_length)
                            sys.stdout.write(f"\r[{'=' * done}{' ' * (50-done)}] {dl/1024/1024:.2f} MB")
                            sys.stdout.flush()
    except Exception as e:
        print(f"\nError downloading: {e}")
        return False
        
    print("\nDownload complete!")
    return True

if __name__ == "__main__":
    download_file()
