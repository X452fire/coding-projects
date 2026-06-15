import io
import base64
import pyautogui
from flask import Flask, jsonify, request
from flask_cors import CORS

app = Flask(__name__)
# Enable CORS to allow the local HTML file to talk to this server
CORS(app)

@app.route('/health', methods=['GET'])
def health():
    return jsonify({"status": "ok", "mode": "silent_server"})

@app.route('/screenshot', methods=['GET'])
def screenshot():
    try:
        # Take screenshot using PyAutoGUI
        screenshot = pyautogui.screenshot()
        
        # Convert to JPEG in memory
        img_buffer = io.BytesIO()
        screenshot.save(img_buffer, format='JPEG', quality=85)
        img_buffer.seek(0)
        
        # Encode to Base64
        base64_str = base64.b64encode(img_buffer.getvalue()).decode('utf-8')
        
        # Return as data URI
        return jsonify({
            "status": "success",
            "image": f"data:image/jpeg;base64,{base64_str}"
        })
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

try:
    import speech_recognition as sr
except ImportError:
    sr = None

@app.route('/listen', methods=['POST'])
def listen_mic():
    if not sr:
        return jsonify({"status": "error", "message": "SpeechRecognition lib not installed. run: pip install SpeechRecognition pyaudio"}), 500
    
    r = sr.Recognizer()
    try:
        with sr.Microphone() as source:
            print("Python Listening...")
            # Adjust for ambient noise
            r.adjust_for_ambient_noise(source, duration=0.5)
            # Listen with a timeout
            audio = r.listen(source, timeout=5, phrase_time_limit=10)
            
            print("Processing Audio...")
            text = r.recognize_google(audio)
            return jsonify({"status": "success", "text": text})
            
    except sr.WaitTimeoutError:
        return jsonify({"status": "error", "message": "No speech detected (Timeout)"}), 400
    except sr.UnknownValueError:
        return jsonify({"status": "error", "message": "Could not understand audio"}), 400
    except Exception as e:
        print(f"Voice Error: {e}")
        return jsonify({"status": "error", "message": str(e)}), 500

import subprocess
import os

import os
import werkzeug

# Ensure shortcuts directory exists
SHORTCUTS_DIR = os.path.join(os.getcwd(), 'shortcuts')
if not os.path.exists(SHORTCUTS_DIR):
    os.makedirs(SHORTCUTS_DIR)

@app.route('/launch', methods=['POST'])
def launch_app():
    data = request.json
    path = data.get('path')
    
    if not path:
        return jsonify({"status": "error", "message": "Path required"}), 400
        
    try:
        # Popen is non-blocking so the server doesn't hang
        subprocess.Popen(path)
        return jsonify({"status": "success", "message": f"Launched {path}"})
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/upload', methods=['POST'])
def upload_file():
    if 'file' not in request.files:
        return jsonify({"status": "error", "message": "No file part"}), 400
    
    file = request.files['file']
    if file.filename == '':
        return jsonify({"status": "error", "message": "No selected file"}), 400
        
    if file:
        filename = werkzeug.utils.secure_filename(file.filename)
        save_path = os.path.join(SHORTCUTS_DIR, filename)
        file.save(save_path)
        return jsonify({"status": "success", "filename": filename})
    
    return jsonify({"status": "error", "message": "Upload failed"}), 500

@app.route('/launch-lnk', methods=['POST'])
def launch_lnk():
    data = request.json
    filename = data.get('filename')
    
    if not filename:
        return jsonify({"status": "error", "message": "Filename required"}), 400
        
    filepath = os.path.join(SHORTCUTS_DIR, filename)
    if not os.path.exists(filepath):
        return jsonify({"status": "error", "message": "Shortcut not found on server"}), 404
        
    try:
        # os.startfile is Windows only, which matches the user's OS
        os.startfile(filepath)
        return jsonify({"status": "success", "message": f"Launched {filename}"})
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500


@app.route('/shortcuts', methods=['GET'])
def list_shortcuts():
    try:
        files = [f for f in os.listdir(SHORTCUTS_DIR) if os.path.isfile(os.path.join(SHORTCUTS_DIR, f))]
        lnk_files = [f for f in files if f.lower().endswith('.lnk')]
        return jsonify({"status": "success", "shortcuts": lnk_files})
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/delete-shortcut', methods=['POST'])
def delete_shortcut_file():
    data = request.json
    filename = data.get('filename')
    
    if not filename:
        return jsonify({"status": "error", "message": "Filename required"}), 400
        
    filepath = os.path.join(SHORTCUTS_DIR, filename)
    if not os.path.exists(filepath):
        return jsonify({"status": "error", "message": "File not found"}), 404
        
    try:
        os.remove(filepath)
        return jsonify({"status": "success", "message": f"Deleted {filename}"})
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

if __name__ == '__main__':
    print("--------------------------------------------------")
    print(" Jarvis Silent Server Running on Port 5000")
    print(" Minimize this window and use the Dashboard.")
    print("--------------------------------------------------")
    app.run(port=5000, debug=False)
