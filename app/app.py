# app/app.py
from flask import Flask, request, jsonify
import os
import time
import json
from google.cloud import pubsub_v1

app = Flask(__name__)

# --- Configuration from Environment Variables ---
# These are injected via Kubernetes Deployment
GCP_PROJECT_ID = os.environ.get("GCP_PROJECT_ID")
PUBSUB_SUBSCRIPTION_ID = os.environ.get("PUBSUB_SUBSCRIPTION_ID")
# This env var tells google-cloud-python where to find credentials
GOOGLE_APPLICATION_CREDENTIALS_PATH = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")

# --- Pub/Sub Client Initialization ---
subscriber = None
subscription_path = None

def initialize_pubsub_client():
    global subscriber, subscription_path
    if not all([GCP_PROJECT_ID, PUBSUB_SUBSCRIPTION_ID, GOOGLE_APPLICATION_CREDENTIALS_PATH]):
        print("ERROR: Missing required environment variables for Pub/Sub client. Ensure GCP_PROJECT_ID, PUBSUB_SUBSCRIPTION_ID, and GOOGLE_APPLICATION_CREDENTIALS are set.")
        return False

    try:
        # Google Cloud client libraries automatically pick up GOOGLE_APPLICATION_CREDENTIALS
        subscriber = pubsub_v1.SubscriberClient()
        subscription_path = subscriber.subscription_path(GCP_PROJECT_ID, PUBSUB_SUBSCRIPTION_ID)
        print(f"Pub/Sub client initialized for subscription: {subscription_path}")
        return True
    except Exception as e:
        print(f"ERROR: Failed to initialize Pub/Sub client: {e}")
        return False

# --- Message Processing Callback ---
def callback(message):
    """
    Callback function to process Pub/Sub messages.
    This function is called for each message received.
    """
    try:
        message_data = message.data.decode('utf-8')
        # Identify which pod and which topic processed the message
        topic_identifier = os.environ.get("PUBSUB_SUBSCRIPTION_ID").replace("my-pubsub-subscription-", "") # For logging clarity
        print(f"[{os.uname()[1]} | {topic_identifier}] Received message ID: {message.message_id}, Data: {message_data}")

        # Simulate work/processing time
        processing_time = float(os.environ.get("PROCESSING_DELAY_SECONDS", 0.5))
        time.sleep(processing_time)

        # Acknowledge the message to remove it from the subscription backlog
        message.ack()
        print(f"[{os.uname()[1]} | {topic_identifier}] Acknowledged message ID: {message.message_id}")

    except Exception as e:
        print(f"ERROR: Failed to process message {message.message_id}: {e}")
        message.nack()


# --- Flask Health Check Endpoint ---
@app.route('/')
def health_check():
    """Simple health check endpoint."""
    subscription_id_status = os.environ.get("PUBSUB_SUBSCRIPTION_ID", "NOT_SET")
    return jsonify({"status": "ok", "message": f"Pub/Sub subscriber for {subscription_id_status} is running"}), 200

# --- Start Pub/Sub Listener in a separate thread/process if not using Flask for pulling ---
import threading

def start_listening():
    if initialize_pubsub_client():
        print(f"Starting Pub/Sub listener on {subscription_path}")
        streaming_pull_future = subscriber.subscribe(subscription_path, callback=callback)
        try:
            streaming_pull_future.result()
        except Exception as e:
            print(f"Pub/Sub streaming pull stopped due to error: {e}")
            streaming_pull_future.cancel()
        finally:
            if subscriber:
                subscriber.api.transport.close()
            print("Pub/Sub listener thread finished.")
    else:
        print("Pub/Sub client not initialized. Listener will not start.")

listener_thread = threading.Thread(target=start_listening)
listener_thread.daemon = True
listener_thread.start()


if __name__ == '__main__':
    print("Starting Flask application...")
    app.run(host='0.0.0.0', port=80)