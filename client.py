#!/usr/bin/env python3
import json
import logging
import os
import sys
import requests

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)

# Constants (can be moved to config/env vars)
DEFAULT_INPUT_FILE = "example.json"
DEFAULT_BASE_URL = "https://example.com"
ENDPOINT = "/service/generate"


def load_and_validate_json(file_path: str) -> list:
    """Load JSON from file and validate it is a list of objects."""
    if not os.path.exists(file_path):
        logging.error("Input file does not exist: %s", file_path)
        sys.exit(1)

    try:
        with open(file_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        logging.error("Invalid JSON in %s: %s", file_path, e)
        sys.exit(1)
    except Exception as e:
        logging.error("Error reading %s: %s", file_path, e)
        sys.exit(1)

    if not isinstance(data, list):
        logging.error("Expected top-level JSON structure to be a list, got %s", type(data))
        sys.exit(1)

    return data


def filter_non_private(objects: list) -> list:
    """Filter JSON objects where 'private' is explicitly False."""
    filtered = [obj for obj in objects if isinstance(obj, dict) and obj.get("private") is False]
    logging.info("Filtered %d -> %d objects (private=false)", len(objects), len(filtered))
    return filtered


def post_to_service(base_url: str, endpoint: str, payload: list) -> dict:
    """Send POST request to the service endpoint with JSON payload."""
    url = f"{base_url}{endpoint}"
    logging.info("Posting data to %s", url)

    try:
        response = requests.post(url, json=payload, timeout=10)
        response.raise_for_status()
    except requests.exceptions.RequestException as e:
        logging.error("Request failed: %s", e)
        sys.exit(1)

    try:
        return response.json()
    except json.JSONDecodeError as e:
        logging.error("Invalid JSON in response: %s", e)
        sys.exit(1)


def print_valid_keys(response_json: dict):
    """Print keys where the object has 'valid' == True."""
    if not isinstance(response_json, dict):
        logging.error("Expected JSON response to be a dict, got %s", type(response_json))
        return

    for key, value in response_json.items():
        if isinstance(value, dict) and value.get("valid") is True:
            print(key)


def main():
    input_file = os.getenv("INPUT_FILE", DEFAULT_INPUT_FILE)
    base_url = os.getenv("BASE_URL", DEFAULT_BASE_URL)

    logging.info("Starting client with input=%s, base_url=%s", input_file, base_url)

    data = load_and_validate_json(input_file)
    filtered_data = filter_non_private(data)
    if not filtered_data:
        logging.warning("No objects to send after filtering, exiting.")
        sys.exit(0)

    response_json = post_to_service(base_url, ENDPOINT, filtered_data)
    print_valid_keys(response_json)


if __name__ == "__main__":
    main()
