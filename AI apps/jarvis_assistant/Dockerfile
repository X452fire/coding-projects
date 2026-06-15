# Use an official Python runtime as a parent image
FROM python:3.9-slim

# Set the working directory in the container
WORKDIR /app

# Install system dependencies if needed (e.g. for audio, though Brain shouldn't need audio)
# RUN apt-get update && apt-get install -y ...

# Copy the current directory contents into the container at /app
# We only COPY what we need to keep the image clean
COPY server_requirements.txt .

# Install any needed packages specified in requirements.txt
RUN pip install --no-cache-dir -r server_requirements.txt

# Copy the application code
COPY docker_jarvis.py .
COPY brain.py .
COPY memory.py .
COPY config.py .

# Make sure memory.json exists or can be created
# RUN touch memory.json

# Expose port 5000 for the Flask API
EXPOSE 5000

# Define environment variable
ENV PYTHONUNBUFFERED=1

# Run docker_jarvis.py when the container launches
CMD ["python", "docker_jarvis.py"]
