# Dockerfile
# Use an official Python runtime as a parent image
FROM python:3.9-slim-buster

# Set environment variables for non-interactive pip
ENV PIP_NO_CACHE_DIR=off \
    PIP_DISABLE_PIP_VERSION_CHECK=on \
    PYTHONUNBUFFERED=1

# Set the working directory in the container
WORKDIR /app

# Copy the requirements file into the container
COPY app/requirements.txt .

# Install any needed packages specified in requirements.txt
RUN pip install -r requirements.txt

# Copy the rest of the application code into the container
COPY app/ .

# Make port 80 available for health checks
EXPOSE 80

# Run the application
CMD ["python", "app.py"]